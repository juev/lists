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
 * button for quick entry. It is the only ongoing notification of the app and
 * carries the count on the launcher icon as well (R106). A setting of this
 * device; not synced.
 */
object TodayNotice {
    /**
     * Whether a channel badges the icon is fixed when the channel is made, and a notification in a
     * channel with a badge marks the icon whatever its number. So there are two: the notification
     * stands in the first while there is a number for the icon and in the second otherwise.
     */
    private const val COUNTED = "today_counted"
    private const val PLAIN = "today_plain"

    /** The channels of earlier builds: one badged the icon always and one never. */
    private val OLD_CHANNELS = listOf("quick_add", "today_notice")
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

    /** The switch alone, for the update that carries the count over (R106); the caller shows the notification. */
    internal fun turnOn(context: Context) = prefs(context).edit().putBoolean("enabled", true).apply()

    /** What the heading says: nothing for today, the overdue tasks when they are what the icon counts, or the tasks of Today. */
    internal enum class Heading { EMPTY, OVERDUE, TODAY }

    /** R104, R106: the heading and the number on the icon agree. With "overdue" chosen both say how many are overdue. */
    internal fun heading(choice: String, open: Int, overdue: Int): Heading = when {
        open == 0 -> Heading.EMPTY
        choice == "overdue" && overdue > 0 -> Heading.OVERDUE
        else -> Heading.TODAY
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
        OLD_CHANNELS.forEach(manager::deleteNotificationChannel)
        IconCount.merge(context)
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
        alarms?.let { Reminders.atDayChange(context, it, nextDay + 1000, midnight) }
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        // The view keeps completed tasks for a while (R68); the notification does not.
        val open = runCatching { Repo.store.tasks(Scope.Today) }.getOrElse { return }.filter { it.done == null }
        val (overdue, rest) = open.partition { dueDayPassed(it.due) }
        val (titles, more) = listed((overdue + rest).map { it.title })
        // R106: the number of the icon, and the channel that goes with having one.
        val choice = IconCount.choice(context)
        val number = IconCount.number(choice, open.size.toUInt(), overdue.size.toUInt())
        manager.createNotificationChannel(
            NotificationChannel(COUNTED, context.getString(R.string.quick_add_counted_channel), NotificationManager.IMPORTANCE_LOW)
                .apply { setShowBadge(true) }
        )
        manager.createNotificationChannel(
            NotificationChannel(PLAIN, context.getString(R.string.quick_add_channel), NotificationManager.IMPORTANCE_LOW)
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
        val builder = Notification.Builder(context, if (number > 0) COUNTED else PLAIN)
            .setSmallIcon(R.drawable.ic_check)
            .setContentTitle(
                when (heading(choice, open.size, overdue.size)) {
                    Heading.EMPTY -> context.getString(R.string.today_notice_empty)
                    Heading.OVERDUE -> context.getString(R.string.icon_count_overdue, overdue.size.toString())
                    Heading.TODAY -> context.getString(R.string.today_notice_title, open.size.toString())
                }
            )
            .setNumber(number)
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
