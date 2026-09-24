package work.jacobmoura.remotepi

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
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
    const val CHANNEL_MESSAGES = "messages"

    /** Ongoing foreground-service notice. Never reused for messages. */
    const val ONGOING_ID = 1

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
    }

    /** The (silent, ongoing) foreground-service notice. */
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
            .setContentText("Connected — keeping the background connection alive")
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

    fun cancelAll(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        nm.cancelAll()
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
