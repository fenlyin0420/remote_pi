package work.jacobmoura.remotepi

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
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
 *
 * It also hosts the two channels behind background delivery:
 *  - `background` — start/stop the foreground keeper ([ConnectionKeeperService]),
 *    report notification + battery-optimization state, and ask for the
 *    Android 13+ notification permission.
 *  - `notifications` — post a "turn finished" notification and hand a tapped
 *    one back to Dart with the session it belongs to.
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "work.jacobmoura.remotepi/update"

        /** Identity backup/restore — see [setUpIdentityTransferChannel]. */
        private const val IDENTITY_CHANNEL = "work.jacobmoura.remotepi/identity"

        /** Background keeper + notification plumbing. */
        private const val BACKGROUND_CHANNEL = "work.jacobmoura.remotepi/background"
        private const val NOTIFICATIONS_CHANNEL = "work.jacobmoura.remotepi/notifications"

        /** FileProvider authority declared in AndroidManifest.xml. */
        private val AUTHORITY_SUFFIX = ".fileprovider"

        /** Subdirectory of cacheDir the FileProvider exposes (see file_paths.xml). */
        private const val UPDATE_DIR = "updates"

        /** Request codes for the SAF pickers; must not collide. */
        private const val REQ_EXPORT = 4701
        private const val REQ_IMPORT = 4702
        private const val REQ_NOTIFICATIONS = 4703

        /**
         * True while this process owns a live [FlutterEngine].
         *
         * [ConnectionKeeperService] reads it to refuse a `START_STICKY`
         * restart with nothing behind it: after a low-memory kill the system
         * would otherwise resurrect the foreground notice with no Dart isolate
         * and no connection, which reads as "connected" while nothing is.
         */
        @Volatile
        var engineAttached: Boolean = false
            private set
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
    // Holds the payload *and* the result to resolve. The payload must be stored
    // here, not re-derived later: the system picker returns only a URI, so the
    // JSON is gone once this call returns.
    private var pendingExport: PendingExport? = null
    private var pendingImport: MethodChannel.Result? = null

    /** In-flight `requestNotificationPermission` call (see [onRequestPermissionsResult]). */
    private var pendingNotificationPermission: MethodChannel.Result? = null

    /**
     * Session carried by the notification the user tapped, waiting for the Dart
     * side to pull it via `pendingTap`. Kept in memory deliberately: a tap is
     * only meaningful for the launch it caused, and the pull happens within
     * milliseconds of the channel being ready.
     */
    private var pendingNotificationTap: Map<String, String>? = null

    /** Set while the notifications channel exists, so a warm tap can poke Dart. */
    private var notificationsChannel: MethodChannel? = null

    private data class PendingExport(
        val json: String,
        val fileName: String,
        val result: MethodChannel.Result,
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        engineAttached = true

        setUpUpdateChannel(flutterEngine)
        setUpIdentityTransferChannel(flutterEngine)
        setUpBackgroundChannel(flutterEngine)
        setUpNotificationsChannel(flutterEngine)
    }

    override fun onDestroy() {
        // `isFinishing` (not a config change): the engine dies with us, so any
        // sticky restart of the keeper has nothing to keep alive.
        if (isFinishing) {
            engineAttached = false
            notificationsChannel = null
        }
        super.onDestroy()
    }

    /**
     * A tapped message notification re-enters the (singleTop) activity instead
     * of creating a second one.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (captureNotificationTap(intent)) {
            // Signal only: Dart pulls the payload through `pendingTap`, so a tap
            // that lands before the router exists is never dropped.
            notificationsChannel?.invokeMethod("onNotificationTap", null)
        }
    }

    // -----------------------------------------------------------------------
    // Background connection + notifications
    // -----------------------------------------------------------------------

    /**
     * Backs the "keep connected in the background" switch.
     *
     *  - `start` / `stop` / `isRunning` — the foreground keeper. `isRunning`
     *    asks the service instead of caching a flag: the system can stop it
     *    behind our back, and a stale "on" would leave the UI lying.
     *  - `notificationsEnabled` — whether message notifications can be shown
     *    at all (permission granted AND not disabled per-app).
     *  - `requestNotificationPermission` — Android 13+ runtime prompt; resolves
     *    with whether it is granted now.
     *  - `openNotificationSettings` — system screen for the "blocked" case,
     *    where asking again is a no-op.
     *  - `isIgnoringBatteryOptimizations` / `requestIgnoreBatteryOptimizations`
     *    — Doze is not the main threat (a foreground service is exempt), but
     *    aggressive OEM battery managers are, and they only listen to this list.
     */
    private fun setUpBackgroundChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BACKGROUND_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        ConnectionKeeperService.start(this)
                        result.success(true)
                    }

                    "stop" -> {
                        ConnectionKeeperService.stop(this)
                        result.success(true)
                    }

                    "isRunning" -> {
                        result.success(ConnectionKeeperService.running)
                    }

                    "notificationsEnabled" -> {
                        result.success(notificationsEnabled())
                    }

                    "requestNotificationPermission" -> {
                        requestNotificationPermission(result)
                    }

                    "openNotificationSettings" -> {
                        openNotificationSettings()
                        result.success(null)
                    }

                    "isIgnoringBatteryOptimizations" -> {
                        result.success(isIgnoringBatteryOptimizations())
                    }

                    "requestIgnoreBatteryOptimizations" -> {
                        openBatteryOptimizationSettings()
                        result.success(null)
                    }

                    else -> {
                        result.notImplemented()
                    }
                }
            }
    }

    /**
     * Backs message notifications.
     *
     *  - `show` — post/replace one room's notification (id derived from the
     *    session, so a busy room collapses onto a single entry).
     *  - `pendingTap` — consume the session of a tapped notification.
     *  - `cancelAll` — used when the user turns notifications off.
     *
     * Native → Dart: `onNotificationTap` is a bare wake-up; the payload always
     * comes from `pendingTap`, which keeps cold-start and warm taps on one path.
     */
    private fun setUpNotificationsChannel(flutterEngine: FlutterEngine) {
        // Cold start: the launch intent already carries the tapped session.
        captureNotificationTap(intent)

        val channel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIFICATIONS_CHANNEL)
        notificationsChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "show" -> {
                    val title = call.argument<String>("title")
                    val body = call.argument<String>("body")
                    val epk = call.argument<String>("epk")
                    val room = call.argument<String>("room")
                    if (title == null || body == null || epk == null || room == null) {
                        result.error("bad_args", "title, body, epk and room are required", null)
                        return@setMethodCallHandler
                    }
                    AppNotifications.showMessage(
                        this,
                        title = title,
                        body = body,
                        device = call.argument<String>("device") ?: "",
                        epk = epk,
                        room = room,
                    )
                    result.success(null)
                }

                "pendingTap" -> {
                    val tap = pendingNotificationTap
                    pendingNotificationTap = null
                    result.success(tap)
                }

                "cancel" -> {
                    val epk = call.argument<String>("epk")
                    val room = call.argument<String>("room")
                    if (epk == null || room == null) {
                        result.error("bad_args", "epk and room are required", null)
                        return@setMethodCallHandler
                    }
                    AppNotifications.cancel(this, epk, room)
                    result.success(null)
                }

                "showTest" -> {
                    AppNotifications.showTest(this)
                    result.success(null)
                }

                "cancelAll" -> {
                    AppNotifications.cancelAll(this)
                    result.success(null)
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    /**
     * Parks the session id carried by [intent] when it came from a notification.
     * Returns true when there was one. The extras are consumed so a recreated
     * activity does not replay the same tap.
     */
    private fun captureNotificationTap(intent: Intent?): Boolean {
        val epk = intent?.getStringExtra(AppNotifications.EXTRA_EPK) ?: return false
        val room = intent.getStringExtra(AppNotifications.EXTRA_ROOM) ?: return false
        pendingNotificationTap = mapOf("epk" to epk, "room" to room)
        intent.removeExtra(AppNotifications.EXTRA_EPK)
        intent.removeExtra(AppNotifications.EXTRA_ROOM)
        return true
    }

    private fun notificationsEnabled(): Boolean {
        val nm = getSystemService(NotificationManager::class.java) ?: return false
        return nm.areNotificationsEnabled()
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        // Pre-33 has no such permission, and a granted one can still be blocked
        // per-app — that case is `notificationsEnabled` + the settings link, not
        // a re-prompt (which Android ignores anyway).
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        val granted =
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        if (granted) {
            result.success(true)
            return
        }
        if (pendingNotificationPermission != null) {
            result.error("busy", "A permission request is already open", null)
            return
        }
        pendingNotificationPermission = result
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFICATIONS)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_NOTIFICATIONS) return
        val result = pendingNotificationPermission ?: return
        pendingNotificationPermission = null
        result.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
    }

    /**
     * Opens this app's notification settings.
     *
     * Two routes because OEM builds drop the per-app screen: the dedicated
     * notification page first, then the app's own system page (which every ROM
     * keeps and which links to notifications).
     */
    private fun openNotificationSettings() {
        startFirstAvailable(
            listOf(
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName),
                appDetailsIntent(),
            ),
        )
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val pm = getSystemService(PowerManager::class.java) ?: return false
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    /**
     * Asks the system to exempt this app from battery optimization.
     *
     * Three routes, most specific first: the one-tap per-app exemption dialog,
     * the system's exemption list (some builds drop the dialog), and finally our
     * own app page — on several Chinese builds the exemption list is hidden
     * entirely, and "battery → unrestricted" on the app page is the only way in.
     * Whichever route lands, the row re-reads the real state afterwards.
     */
    private fun openBatteryOptimizationSettings() {
        startFirstAvailable(
            listOf(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(Uri.parse("package:$packageName")),
                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
                appDetailsIntent(),
            ),
        )
    }

    private fun appDetailsIntent(): Intent =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            .setData(Uri.parse("package:$packageName"))

    /**
     * Starts the first of [intents] this device accepts. OEM builds silently
     * lack settings screens, and an unhandled `ActivityNotFoundException` here
     * would take the app down over a settings shortcut.
     */
    private fun startFirstAvailable(intents: List<Intent>): Boolean {
        for (intent in intents) {
            try {
                startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (_: Exception) {
                // No activity for this route — try the next one.
            }
        }
        return false
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
        pendingExport = PendingExport(json, fileName, result)
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
                val json = pending.json
                val fileName = pending.fileName
                val result = pending.result
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
                    result.success(uri.lastPathSegment ?: fileName)
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
