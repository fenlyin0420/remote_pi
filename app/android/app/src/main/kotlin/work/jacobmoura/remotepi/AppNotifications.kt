package work.jacobmoura.remotepi

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.RingtoneManager


/**
 * Notification channels + posting for background delivery.
 *
 * Two channels, deliberately different in weight:
 *
 *  - [CHANNEL_CONNECTION] — the foreground-service notice. Silent, no badge,
 *    IMPORTANCE_LOW: it exists because Android requires a foreground service
 *    to show one, not to get the user's attention.
 *  - [CHANNEL_MESSAGES] — "the agent finished a turn". IMPORTANCE_HIGH so it
 *    heads-up, with the default notification sound so it behaves like a chat
 *    app (the entire point of the feature).
 *
 * Notifications are built with the platform `Notification.Builder` (API 26+
 * channel constructor). We deliberately avoid NotificationCompat /
 * flutter_local_notifications: minSdk is 34, so the platform API is enough and
 * the app stays free of a new dependency + desugaring requirements.
 */
object AppNotifications {
    const val CHANNEL_CONNECTION = "connection"

    /**
     * Message channel — `_v2` on purpose.
     *
     * A channel's configuration is **immutable** once created: the OS keeps the
     * first definition forever and silently ignores later code changes. v1 was
     * created with `enableVibration(true)` and no vibration pattern, which on
     * Android O+ means "vibrate enabled, nothing to play" — the notifications
     * arrived silently and without a buzz. Fixing that in place would have been
     * invisible to every device that had already created the channel, so the fix
     * has to arrive under a new id (and the old one is deleted below, to keep
     * one entry in the system's channel list instead of two).
     */
    const val CHANNEL_MESSAGES = "messages_v2"

    /** The v1 channel, retired above. Deleted once, then never referenced. */
    private const val CHANNEL_MESSAGES_LEGACY = "messages"

    /** Ongoing foreground-service notice. Never reused for messages. */
    const val ONGOING_ID = 1

    /** Id for the Settings "send a test notification" post. */
    private const val TEST_ID = 2

    /**
     * Buzz pattern for message notifications: wait, buzz, pause, buzz. Written
     * explicitly because a channel's `enableVibration(true)` alone leaves the
     * pattern null — see [CHANNEL_MESSAGES].
     */
    private val VIBRATION_PATTERN = longArrayOf(0, 250, 200, 250)

    /** Notification ids for messages start here (see [messageId]). */
    private const val MESSAGE_ID_BASE = 100

    /** Extras read back by MainActivity to route a tapped notification. */
    const val EXTRA_EPK = "work.jacobmoura.remotepi.epk"
    const val EXTRA_ROOM = "work.jacobmoura.remotepi.room"

    fun ensureChannels(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return

        if (nm.getNotificationChannel(CHANNEL_CONNECTION) == null) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_CONNECTION,
                    "Background connection",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Keeps the connection to your Pi alive in the background."
                    setShowBadge(false)
                    enableVibration(false)
                    setSound(null, null)
                },
            )
        }

        if (nm.getNotificationChannel(CHANNEL_MESSAGES) == null) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_MESSAGES,
                    "Messages",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Notifies you when the agent finishes a turn."
                    enableVibration(true)
                    vibrationPattern = VIBRATION_PATTERN
                    setSound(
                        RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
                        AudioAttributes
                            .Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                            .build(),
                    )
                },
            )
        }

        // Retire v1 so the settings list shows one "Messages" entry. Safe: the
        // only notifications it ever carried are transient turn banners.
        if (nm.getNotificationChannel(CHANNEL_MESSAGES_LEGACY) != null) {
            nm.deleteNotificationChannel(CHANNEL_MESSAGES_LEGACY)
        }
    }

    /**
     * The foreground-service notice.
     *
     * Deliberately terse ("Connected") and silent: Android requires *a*
     * notification for any foreground service, so this one is built to be the
     * least intrusive thing that satisfies that. On Android 13+ the user can
     * swipe it away — the service keeps running, and
     * [ConnectionKeeperService.start] refuses to re-post it for as long as the
     * keeper lives.
     */
    fun connectionNotification(ctx: Context): Notification {
        val tap =
            PendingIntent.getActivity(
                ctx,
                0,
                Intent(ctx, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        return Notification
            .Builder(ctx, CHANNEL_CONNECTION)
            .setSmallIcon(R.drawable.ic_stat_remote_pi)
            .setContentTitle("Remote Pi")
            .setContentText("Connected")
            .setContentIntent(tap)
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    /**
     * Posts (or replaces) the message notification for one room.
     *
     * The id is derived from `(epk, room)` so a busy room collapses onto one
     * notification instead of stacking a wall of them; two different rooms
     * stay separate, which is exactly how the user distinguishes work streams.
     */
    fun showMessage(
        ctx: Context,
        title: String,
        body: String,
        device: String,
        epk: String,
        room: String,
    ) {
        ensureChannels(ctx)
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return

        val tap =
            PendingIntent.getActivity(
                ctx,
                messageId(epk, room),
                Intent(ctx, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                    putExtra(EXTRA_EPK, epk)
                    putExtra(EXTRA_ROOM, room)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        val builder =
            Notification
                .Builder(ctx, CHANNEL_MESSAGES)
                .setSmallIcon(R.drawable.ic_stat_remote_pi)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setContentIntent(tap)
                .setAutoCancel(true)
                .setCategory(Notification.CATEGORY_MESSAGE)
                .setWhen(System.currentTimeMillis())
                .setShowWhen(true)
        if (device.isNotEmpty()) builder.setSubText(device)

        nm.notify(messageId(epk, room), builder.build())
    }

    /**
     * Posts a sample turn notification, so the user can check sound + vibration
     * in two seconds instead of waiting for the agent to finish something.
     *
     * One shot, deliberately. It briefly fired twice — immediately and again
     * after eight seconds, to leave a window for backgrounding the app — and the
     * second one reliably arrived silent on Android 15+, which "notification
     * cooldown" answers by damping successive alerts from the same app. A test
     * whose failure mode is the system doing its job is worse than no test: it
     * reads as a bug in the app and sends everyone looking for one.
     *
     * Carries no session extras: tapping it just opens the app, because there is
     * no session behind it to open.
     */
    fun showTest(ctx: Context) {
        ensureChannels(ctx)
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        val tap =
            PendingIntent.getActivity(
                ctx,
                TEST_ID,
                Intent(ctx, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val detail =
            """
            Test notification. If you saw this but felt nothing, check this app's
            notification settings: the "Messages" channel must allow sound,
            vibration and popups, and the phone must not be in silent mode or Do
            Not Disturb. Settings -> Background shows what this phone reports.
            """.trimIndent().replace('\n', ' ')
        nm.notify(
            TEST_ID,
            Notification
                .Builder(ctx, CHANNEL_MESSAGES)
                .setSmallIcon(R.drawable.ic_stat_remote_pi)
                .setContentTitle("Remote Pi")
                .setContentText("Test notification — a finished turn looks like this.")
                .setStyle(Notification.BigTextStyle().bigText(detail))
                .setContentIntent(tap)
                .setAutoCancel(true)
                .setCategory(Notification.CATEGORY_MESSAGE)
                .setShowWhen(true)
                .build(),
        )
    }

    fun cancelAll(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        nm.cancelAll()
    }

    /**
     * What the OS actually thinks about this app's notifications.
     *
     * Exists because every way a notification can be silent lives outside the
     * app: the channel's importance can be lowered (by the user or a ROM), its
     * sound or vibration pattern can be missing, the phone can be in silent mode,
     * or Do Not Disturb can be swallowing the alert. All of those produce the
     * same symptom — "it never bangs" — and none of them can be read from the
     * app's own state. Reading them back turns a guessing loop into one look.
     *
     * `channelId` doubles as a version check: it names the channel actually in
     * use, so a device still on the retired one is obvious at a glance.
     */
    fun diagnostics(ctx: Context): Map<String, Any?> {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        val audio = ctx.getSystemService(AudioManager::class.java)
        val messages = nm?.getNotificationChannel(CHANNEL_MESSAGES)
        return mapOf(
            "appNotificationsEnabled" to (nm?.areNotificationsEnabled() ?: false),
            "channelId" to (messages?.id ?: ""),
            "channelImportance" to (messages?.importance ?: -1),
            "channelHasSound" to (messages?.sound != null),
            "channelVibration" to (messages?.vibrationPattern?.joinToString(",") ?: ""),
            "ringerMode" to
                when (audio?.ringerMode) {
                    AudioManager.RINGER_MODE_SILENT -> "silent"
                    AudioManager.RINGER_MODE_VIBRATE -> "vibrate"
                    AudioManager.RINGER_MODE_NORMAL -> "normal"
                    else -> "unknown"
                },
            "interruptionFilter" to
                when (nm?.currentInterruptionFilter) {
                    NotificationManager.INTERRUPTION_FILTER_ALL -> "all"
                    NotificationManager.INTERRUPTION_FILTER_PRIORITY -> "priority"
                    NotificationManager.INTERRUPTION_FILTER_NONE -> "none"
                    NotificationManager.INTERRUPTION_FILTER_ALARMS -> "alarms"
                    else -> "unknown"
                },
        )
    }

    /** Dismisses one session's notification (see [showMessage] for the id). */
    fun cancel(
        ctx: Context,
        epk: String,
        room: String,
    ) {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        nm.cancel(messageId(epk, room))
    }

    private fun messageId(
        epk: String,
        room: String,
    ): Int = MESSAGE_ID_BASE + (("$epk|$room").hashCode() and 0xFFFF)
}
