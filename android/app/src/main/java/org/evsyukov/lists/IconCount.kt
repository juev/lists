package org.evsyukov.lists

import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import kotlinx.coroutines.launch

/**
 * R106: the count on the launcher icon. A launcher takes the badge of an app
 * from its notifications only, and the count is carried by the notification
 * with the tasks of Today (R104): there is no notification that shows the
 * count alone. A setting of this device; not synced.
 */
object IconCount {
    /** The channel, the notification and the alarm of the builds that had a notification for the count alone. */
    private const val OLD_CHANNEL = "icon_count"
    private const val OLD_ID = 106
    private const val OLD_MIDNIGHT = "org.evsyukov.lists.ICON_COUNT.MIDNIGHT"

    /** What can be counted, in the order the settings offer it. */
    val choices = listOf("today", "overdue", "none")

    private fun prefs(context: Context) = context.getSharedPreferences("iconCount", Context.MODE_PRIVATE)
    fun choice(context: Context) = prefs(context).getString("choice", null)?.takeIf { it in choices } ?: "none"

    fun setChoice(context: Context, value: String) {
        prefs(context).edit().putString("choice", value).apply()
        Repo.scope.launch { TodayNotice.refresh(context.applicationContext) }
    }

    /** The number the icon carries; zero when there is nothing to show. */
    internal fun number(choice: String, today: UInt, overdue: UInt): Int = when (choice) {
        "today" -> today.toInt()
        "overdue" -> overdue.toInt()
        else -> 0
    }

    /**
     * Whether the update from a build with two notifications turns the notification with the tasks on:
     * once, for a person who had the count and not the list, so that the number does not go away.
     */
    internal fun turnsListOn(choice: String, listOn: Boolean, merged: Boolean): Boolean =
        !merged && choice != "none" && !listOn

    /**
     * Takes away what the builds with a notification for the count alone left, and carries the choice
     * of a person who had only the count over to the one notification. Run before that one is shown.
     */
    fun merge(context: Context) {
        val prefs = prefs(context)
        val merged = prefs.getBoolean("merged", false)
        if (turnsListOn(choice(context), TodayNotice.enabled(context), merged)) TodayNotice.turnOn(context)
        if (merged) return
        prefs.edit().putBoolean("merged", true).apply()
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.cancel(OLD_ID)
        manager.deleteNotificationChannel(OLD_CHANNEL)
        context.getSystemService(AlarmManager::class.java)?.cancel(
            PendingIntent.getBroadcast(
                context, 0, Intent(context, TodayNoticeReceiver::class.java).setAction(OLD_MIDNIGHT),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        )
    }
}
