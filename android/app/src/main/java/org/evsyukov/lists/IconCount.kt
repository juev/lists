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
import java.time.LocalDate
import java.time.ZoneId

/**
 * R106: the count on the launcher icon. A launcher takes the badge of an app
 * from its notifications only, so the count is carried by a silent
 * notification of its own. A setting of this device; not synced.
 */
object IconCount {
    private const val CHANNEL = "icon_count"
    private const val ID = 106
    private const val MIDNIGHT = "org.evsyukov.lists.ICON_COUNT.MIDNIGHT"

    /** What can be counted, in the order the settings offer it. */
    val choices = listOf("today", "overdue", "none")

    private fun prefs(context: Context) = context.getSharedPreferences("iconCount", Context.MODE_PRIVATE)
    fun choice(context: Context) = prefs(context).getString("choice", null)?.takeIf { it in choices } ?: "none"

    fun setChoice(context: Context, value: String) {
        prefs(context).edit().putString("choice", value).apply()
        Repo.scope.launch { refresh(context.applicationContext) }
    }

    /** The number the icon carries; zero when there is nothing to show. */
    internal fun number(choice: String, today: UInt, overdue: UInt): Int = when (choice) {
        "today" -> today.toInt()
        "overdue" -> overdue.toInt()
        else -> 0
    }

    /**
     * Shows the notification with the count as it is now, or takes it away
     * when there is nothing to count. Reads the store: call it off the main thread.
     */
    @Synchronized
    fun refresh(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val alarms = context.getSystemService(AlarmManager::class.java)
        val midnight = PendingIntent.getBroadcast(
            context, 0, Intent(context, IconCountReceiver::class.java).setAction(MIDNIGHT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val choice = choice(context)
        if (choice == "none") {
            manager.cancel(ID)
            alarms?.cancel(midnight)
            return
        }
        // What is due today and what is overdue change with the day, not with a change of the data.
        val nextDay = LocalDate.now().plusDays(1).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
        alarms?.let { Reminders.atDayChange(context, it, nextDay + 1000, midnight) }
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        val counts = runCatching { Repo.store.counts() }.getOrElse { return }
        val number = number(choice, counts.today, counts.overdue)
        if (number == 0) {
            manager.cancel(ID)
            return
        }
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, context.getString(R.string.icon_count), NotificationManager.IMPORTANCE_LOW)
        )
        val app = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java).setAction("today"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        // Since Android 14 an ongoing notification can be swiped away: it is put back at once.
        val swiped = PendingIntent.getBroadcast(
            context, 0, Intent(context, IconCountReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val title = if (choice == "overdue") R.string.icon_count_overdue else R.string.today_notice_title
        manager.notify(
            ID,
            Notification.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_check)
                .setContentTitle(context.getString(title, number.toString()))
                .setNumber(number)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setContentIntent(app)
                .setDeleteIntent(swiped)
                .build(),
        )
    }
}

/** Puts the notification back after a swipe and renews it when the day changes (R106). */
class IconCountReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val result = goAsync()
        Repo.scope.launch {
            IconCount.refresh(context.applicationContext)
            result.finish()
        }
    }
}
