package org.evsyukov.lists

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import kotlinx.coroutines.launch
import uniffi.lists_core.Scope
import java.time.LocalDate
import java.time.ZoneId

/**
 * R104: an ongoing notification that lists the tasks of Today and has a
 * button for quick entry. A setting of this device; not synced.
 */
object TodayNotice {
    private const val CHANNEL = "today_notice"

    /** The channel of the builds before R106. It badged the icon, and an app cannot take that back from a channel that exists. */
    private const val OLD_CHANNEL = "quick_add"
    private const val ID = 104
    private const val MIDNIGHT = "org.evsyukov.lists.TODAY_NOTICE.MIDNIGHT"

    /** How many titles are listed; the rest are counted. */
    const val LIMIT = 5

    private fun prefs(context: Context) = context.getSharedPreferences("todayNotice", Context.MODE_PRIVATE)
    fun enabled(context: Context) = prefs(context).getBoolean("enabled", false)

    fun setEnabled(context: Context, value: Boolean) {
        prefs(context).edit().putBoolean("enabled", value).apply()
        Repo.scope.launch { refresh(context.applicationContext) }
    }

    /** The titles that are listed and how many are left out. */
    internal fun listed(titles: List<String>, limit: Int = LIMIT): Pair<List<String>, Int> =
        titles.take(limit) to (titles.size - limit).coerceAtLeast(0)

    /**
     * Shows the notification with what Today holds now, or takes it away when
     * the setting is off. Reads the store: call it off the main thread.
     */
    @Synchronized
    fun refresh(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.deleteNotificationChannel(OLD_CHANNEL)
        val alarms = context.getSystemService(AlarmManager::class.java)
        val midnight = PendingIntent.getBroadcast(
            context, 0, Intent(context, TodayNoticeReceiver::class.java).setAction(MIDNIGHT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        if (!enabled(context)) {
            manager.cancel(ID)
            alarms?.cancel(midnight)
            return
        }
        // What is due today changes with the day, not with a change of the data.
        val nextDay = LocalDate.now().plusDays(1).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
        alarms?.setAndAllowWhileIdle(AlarmManager.RTC, nextDay + 1000, midnight)
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        // The view keeps completed tasks for a while (R68); the notification does not.
        val open = runCatching { Repo.store.tasks(Scope.Today) }.getOrElse { return }.filter { it.done == null }
        val (overdue, rest) = open.partition { dueDayPassed(it.due) }
        val (titles, more) = listed((overdue + rest).map { it.title })
        // R106: the count on the icon has a notification of its own; this one is not counted.
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, context.getString(R.string.quick_add_channel), NotificationManager.IMPORTANCE_LOW)
                .apply { setShowBadge(false) }
        )
        val app = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java).setAction("today"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val add = PendingIntent.getActivity(
            context, 0, Intent(context, QuickAddActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        // Since Android 14 an ongoing notification can be swiped away: it is put back at once.
        val swiped = PendingIntent.getBroadcast(
            context, 0, Intent(context, TodayNoticeReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val lines = if (more > 0) titles + context.getString(R.string.today_notice_more, more.toString()) else titles
        val builder = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_check)
            .setContentTitle(
                if (open.isEmpty()) context.getString(R.string.today_notice_empty)
                else context.getString(R.string.today_notice_title, open.size.toString())
            )
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(app)
            .setDeleteIntent(swiped)
            .addAction(Notification.Action.Builder(null, context.getString(R.string.quick_add), add).build())
        if (lines.isNotEmpty()) {
            builder.setContentText(lines.joinToString(", "))
            builder.setStyle(Notification.InboxStyle().also { style -> lines.forEach(style::addLine) })
        }
        manager.notify(ID, builder.build())
    }
}

/** Puts the notification back after a swipe and renews it when the day changes (R104). */
class TodayNoticeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val result = goAsync()
        Repo.scope.launch {
            TodayNotice.refresh(context.applicationContext)
            // R107: a widget with Today turns to the new day with it.
            TaskWidgets.refresh(context.applicationContext)
            result.finish()
        }
    }
}
