package work.jacobmoura.remotepi

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Hosts the in-app update channel.
 *
 * Flutter downloads the release APK and calls [CHANNEL]; the platform side
 * hands it to the system installer. Android has no silent-install API for
 * ordinary apps, so this is always a user-confirmed flow:
 *
 *  - `canInstall`  — is this app allowed to install packages yet? When false
 *                    the caller sends the user to the "install unknown apps"
 *                    screen via `openInstallSettings`.
 *  - `install`     — launch the installer for an APK already on disk.
 *  - `openInstallSettings` — deep-link to this app's unknown-sources toggle.
 *
 * The APK path is confined to the app's own cache dir before use, so a bad
 * argument cannot turn this into "install a file from anywhere".
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "work.jacobmoura.remotepi/update"

        /** Identity backup/restore — see [setUpIdentityTransferChannel]. */
        private const val IDENTITY_CHANNEL = "work.jacobmoura.remotepi/identity"

        /** FileProvider authority declared in AndroidManifest.xml. */
        private val AUTHORITY_SUFFIX = ".fileprovider"

        /** Subdirectory of cacheDir the FileProvider exposes (see file_paths.xml). */
        private const val UPDATE_DIR = "updates"

        /** Request codes for the SAF pickers; must not collide. */
        private const val REQ_EXPORT = 4701
        private const val REQ_IMPORT = 4702
    }

    /**
     * Pending result for an in-flight SAF picker. SAF is asynchronous — the
     * user may take arbitrarily long in the system UI — so the Dart future is
     * resolved from [onActivityResult] instead of the method call.
     *
     * Only one picker can be open at a time (it is a full-screen system
     * activity), so a single slot is enough. A second call while one is
     * pending is rejected rather than silently clobbering the first.
     */
    private var pendingExport: Pair<String, MethodChannel.Result>? = null
    private var pendingImport: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        setUpUpdateChannel(flutterEngine)
        setUpIdentityTransferChannel(flutterEngine)
    }

    // -----------------------------------------------------------------------
    // Identity backup / restore
    // -----------------------------------------------------------------------

    /**
     * Channel backing the "export / import my identity" feature.
     *
     * Uses the Storage Access Framework rather than a fixed path: the user
     * picks the destination (and the source) themselves, which means the app
     * needs no storage permission at all and never guesses at a location that
     * may not exist on a given OEM build. It also keeps the key file out of
     * app-private storage, which is the entire point — it has to survive the
     * phone being replaced.
     *
     *  - `exportIdentity(json, fileName)` — writes [json] to a user-chosen
     *    location; resolves with the display path, or null when cancelled.
     *  - `importIdentity()` — reads a user-chosen file; resolves with its
     *    contents, or null when cancelled.
     */
    private fun setUpIdentityTransferChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, IDENTITY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "exportIdentity" -> {
                        val json = call.argument<String>("json")
                        val fileName = call.argument<String>("fileName")
                        if (json == null || fileName.isNullOrBlank()) {
                            result.error("bad_args", "json and fileName are required", null)
                            return@setMethodCallHandler
                        }
                        if (pendingExport != null) {
                            result.error("busy", "A file picker is already open", null)
                            return@setMethodCallHandler
                        }
                        startExport(json, fileName, result)
                    }

                    "importIdentity" -> {
                        if (pendingImport != null) {
                            result.error("busy", "A file picker is already open", null)
                            return@setMethodCallHandler
                        }
                        startImport(result)
                    }

                    else -> {
                        result.notImplemented()
                    }
                }
            }
    }

    private fun startExport(
        json: String,
        fileName: String,
        result: MethodChannel.Result,
    ) {
        pendingExport = fileName to result
        try {
            startActivityForResult(
                Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "application/json"
                    putExtra(Intent.EXTRA_TITLE, fileName)
                    addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                },
                REQ_EXPORT,
            )
        } catch (e: Exception) {
            pendingExport = null
            result.error("picker_unavailable", e.message ?: "No file picker available", null)
        }
    }

    private fun startImport(result: MethodChannel.Result) {
        pendingImport = result
        try {
            startActivityForResult(
                Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    // Deliberately not constrained to application/json: some
                    // providers report backups as octet-stream or plain text,
                    // and a wrong pick is rejected by the bundle parser anyway.
                    type = "*/*"
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                },
                REQ_IMPORT,
            )
        } catch (e: Exception) {
            pendingImport = null
            result.error("picker_unavailable", e.message ?: "No file picker available", null)
        }
    }

    @Deprecated("FlutterActivity lifecycle; startActivityForResult is the API the SAF flow needs")
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        super.onActivityResult(requestCode, resultCode, data)

        when (requestCode) {
            REQ_EXPORT -> {
                val pending = pendingExport ?: return
                pendingExport = null
                val (json, result) = pending
                if (resultCode != Activity.RESULT_OK) {
                    // Cancelled — not an error, the Dart side treats null as such.
                    result.success(null)
                    return
                }
                val uri = data?.data
                if (uri == null) {
                    result.error("no_uri", "The file picker returned no location", null)
                    return
                }
                try {
                    contentResolver.openOutputStream(uri)?.use { out ->
                        out.write(json.toByteArray(Charsets.UTF_8))
                        out.flush()
                    } ?: run {
                        result.error("write_failed", "Could not open the selected file", null)
                        return
                    }
                    result.success(uri.lastPathSegment ?: json.hashCode().toString())
                } catch (e: Exception) {
                    result.error("write_failed", e.message ?: "Could not write the file", null)
                }
            }

            REQ_IMPORT -> {
                val result = pendingImport ?: return
                pendingImport = null
                if (resultCode != Activity.RESULT_OK) {
                    result.success(null)
                    return
                }
                val uri = data?.data
                if (uri == null) {
                    result.error("no_uri", "The file picker returned no file", null)
                    return
                }
                try {
                    val text =
                        contentResolver.openInputStream(uri)?.use { input ->
                            input.readBytes().toString(Charsets.UTF_8)
                        }
                    if (text == null) {
                        result.error("read_failed", "Could not open the selected file", null)
                        return
                    }
                    result.success(text)
                } catch (e: Exception) {
                    result.error("read_failed", e.message ?: "Could not read the file", null)
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // In-app update
    // -----------------------------------------------------------------------

    private fun setUpUpdateChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "updateDownloadsDir" -> {
                        // The installer only accepts files under this dir, so the
                        // Dart side asks for the path instead of guessing it.
                        val dir = File(cacheDir, UPDATE_DIR)
                        if (!dir.exists()) dir.mkdirs()
                        result.success(dir.absolutePath)
                    }

                    "canInstall" -> {
                        result.success(canInstallPackages())
                    }

                    "install" -> {
                        handleInstall(call.argument<String>("path"), result)
                    }

                    "openInstallSettings" -> {
                        openInstallSettings()
                        result.success(null)
                    }

                    else -> {
                        result.notImplemented()
                    }
                }
            }
    }

    /** True from API 26 once the user granted this app's unknown-sources toggle. */
    private fun canInstallPackages(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    private fun handleInstall(
        rawPath: String?,
        result: MethodChannel.Result,
    ) {
        if (rawPath.isNullOrBlank()) {
            result.error("bad_args", "APK path is required", null)
            return
        }

        val apk = File(rawPath)
        // Confine to the app's own cache: a caller must not be able to point
        // the installer at an arbitrary location.
        val allowedRoot = File(cacheDir, UPDATE_DIR).canonicalFile
        val target =
            try {
                apk.canonicalFile
            } catch (e: Exception) {
                result.error("bad_path", "Cannot resolve path: ${e.message}", null)
                return
            }
        if (!target.path.startsWith(allowedRoot.path + File.separator)) {
            result.error("bad_path", "APK must live under ${allowedRoot.path}", null)
            return
        }
        if (!target.isFile || target.length() == 0L) {
            result.error("missing_apk", "APK not found or empty", null)
            return
        }

        if (!canInstallPackages()) {
            // Distinct code so the app can offer the settings shortcut rather
            // than a dead end.
            result.error("no_permission", "Install permission not granted", null)
            return
        }

        try {
            val uri: Uri =
                FileProvider.getUriForFile(
                    this,
                    "$packageName$AUTHORITY_SUFFIX",
                    target,
                )
            val intent =
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            startActivity(intent)
            result.success(null)
        } catch (e: Exception) {
            result.error("install_failed", e.message ?: "Unknown install error", null)
        }
    }

    /** Deep-link to this app's "install unknown apps" row. */
    private fun openInstallSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                    data = Uri.parse("package:$packageName")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                },
            )
        } catch (_: Exception) {
            // Some OEM builds lack the per-app screen; fall back to the list.
            try {
                startActivity(
                    Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            } catch (_: Exception) {
                // Nothing actionable — the Dart side surfaces a generic hint.
            }
        }
    }
}
