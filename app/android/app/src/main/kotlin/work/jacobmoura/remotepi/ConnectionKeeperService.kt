package work.jacobmoura.remotepi

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.util.Log

/**
 * Keeps the app process alive so the relay WebSocket owned by the Dart isolate
 * survives backgrounding.
 *
 * This is the whole mechanism behind "notifications arrive like a chat app":
 * the WebSocket, its 25s protocol ping, the 15s watchdog and the reconnect
 * backoff all live in Dart and keep running as long as the process does — and
 * Android only spares a backgrounded process if something puts it in the
 * foreground. So the service does nothing but hold that slot and show the
 * notice Android requires; it never touches the connection itself.
 *
 * `foregroundServiceType="specialUse"` (declared in the manifest) rather than
 * `dataSync`: from Android 15 (API 35) a `dataSync` service is capped at six
 * hours per day and then stopped, which would silently break the feature on a
 * long-running session. `specialUse` has no such timeout; the manifest carries
 * the required `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` justification.
 *
 * Lifecycle choices:
 *  - `START_STICKY`, but `onStartCommand` with a null intent (the system
 *    restarting us after a kill) stops self when the Flutter engine is not
 *    attached — otherwise the user would get a "connected" notice with nothing
 *    behind it.
 *  - `onTaskRemoved` stops the service: swiping the app out of recents is the
 *    user saying "stop", and a Zombie notification would be worse than the
 *    lost connection.
 */
class ConnectionKeeperService : Service() {
    companion object {
        private const val TAG = "ConnectionKeeper"

        private const val ACTION_STOP = "work.jacobmoura.remotepi.STOP_KEEPER"

        /** Process-local truth for the MethodChannel's `isRunning`. The system
         *  can kill the service behind our back, so asking here (instead of
         *  caching on the Dart side) is the only answer that stays honest. */
        @Volatile
        var running: Boolean = false
            private set

        fun start(ctx: Context) {
            AppNotifications.ensureChannels(ctx)
            val intent = Intent(ctx, ConnectionKeeperService::class.java)
            try {
                ctx.startForegroundService(intent)
            } catch (e: Exception) {
                // Android 12+ refuses a foreground-service start from the
                // background. Everything that asks for the keeper here is a user
                // action or a boot, so this is a guard against an edge case (a
                // storage change landing while backgrounded) — swallowing it
                // keeps a notification concern from crashing the app. The
                // settings screen reports the real state either way.
                Log.w(TAG, "foreground service start refused", e)
            }
        }

        fun stop(ctx: Context) {
            // Deliver the stop intent only to an instance that exists. Starting
            // a fresh one just to kill it would flash a notice and, on Android
            // 12+, is exactly the background start the platform refuses.
            if (running) {
                val intent =
                    Intent(ctx, ConnectionKeeperService::class.java).apply {
                        action = ACTION_STOP
                    }
                try {
                    ctx.startService(intent)
                } catch (e: Exception) {
                    Log.w(TAG, "stop intent refused; falling back to stopService", e)
                }
            }
            ctx.stopService(Intent(ctx, ConnectionKeeperService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        AppNotifications.ensureChannels(this)
        running = true
    }

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int,
    ): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        // Restarted by the system after a kill (no intent) with no Dart isolate
        // to serve: there is nothing to keep alive, so don't fake it.
        if (intent == null && !MainActivity.engineAttached) {
            stopSelf()
            return START_NOT_STICKY
        }
        startForeground(
            AppNotifications.ONGOING_ID,
            AppNotifications.connectionNotification(this),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
        )
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiping the app out of Recents is the user saying "stop": honour it
        // instead of resurrecting the notice, which is what a sticky restart of
        // an engine-less process would do.
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }
}

