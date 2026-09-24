package work.jacobmoura.remotepi

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

        /** FileProvider authority declared in AndroidManifest.xml. */
        private val AUTHORITY_SUFFIX = ".fileprovider"

        /** Subdirectory of cacheDir the FileProvider exposes (see file_paths.xml). */
        private const val UPDATE_DIR = "updates"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
