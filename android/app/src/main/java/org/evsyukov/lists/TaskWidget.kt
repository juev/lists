package org.evsyukov.lists

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.RemoteViews
import kotlinx.coroutines.launch
import uniffi.lists_core.Scope

/** What a widget shows (R107); chosen when the widget is placed. */
sealed interface WidgetView {
    data object Today : WidgetView
    data object Inbox : WidgetView
    data class OfList(val id: String) : WidgetView

    val scope: Scope
        get() = when (this) {
            Today -> Scope.Today
            Inbox -> Scope.Inbox
            is OfList -> Scope.List(id)
        }

    /** The form kept in the preferences and carried by an intent. */
    fun encode(): String = when (this) {
        Today -> "today"
        Inbox -> "inbox"
        is OfList -> "list:$id"
    }

    companion object {
        fun decode(value: String?): WidgetView? = when {
            value == "today" -> Today
            value == "inbox" -> Inbox
            value != null && value.startsWith("list:") && value.length > 5 -> OfList(value.drop(5))
            else -> null
        }
    }
}

/**
 * R107: the widgets with tasks on the home screen. Each one shows the open
 * tasks of the view chosen for it; R108 puts the button of quick entry in its
 * header. The choice belongs to this device and is not synced.
 */
object TaskWidgets {
    const val COMPLETE = "org.evsyukov.lists.WIDGET.COMPLETE"

    // The heights of the layouts in res/layout/widget_*.xml, in dp.
    private const val HEADER = 40
    private const val PADDING = 16
    private const val ROW = 32

    private fun prefs(context: Context) = context.getSharedPreferences("widgets", Context.MODE_PRIVATE)
    fun view(context: Context, id: Int): WidgetView? = WidgetView.decode(prefs(context).getString("view_$id", null))

    fun setView(context: Context, id: Int, view: WidgetView) {
        prefs(context).edit().putString("view_$id", view.encode()).apply()
    }

    fun forget(context: Context, ids: IntArray) {
        prefs(context).edit().also { edit -> ids.forEach { edit.remove("view_$it") } }.apply()
    }

    /** How many rows fit under the header of a widget of this height, in dp. */
    internal fun rowsThatFit(height: Int): Int = ((height - HEADER - PADDING) / ROW).coerceAtLeast(1)

    /** The tasks that get a row and how many are left out; the line that counts those takes a row itself. */
    internal fun <T> shown(tasks: List<T>, rows: Int): Pair<List<T>, Int> =
        if (tasks.size <= rows) tasks to 0 else tasks.take(rows - 1).let { it to tasks.size - it.size }

    /** The order of Today: the tasks whose due day has passed come first (R84). */
    internal fun <T> overdueFirst(tasks: List<T>, due: (T) -> String?, today: String = today()): List<T> =
        tasks.partition { dueDayPassed(due(it), today) }.let { (overdue, rest) -> overdue + rest }

    /** Draws every widget anew. Reads the store when there is a widget: call it off the main thread. */
    @Synchronized
    fun refresh(context: Context) {
        val manager = AppWidgetManager.getInstance(context) ?: return
        for (provider in listOf(SmallTaskWidget::class.java, LargeTaskWidget::class.java)) {
            for (id in manager.getAppWidgetIds(ComponentName(context, provider))) draw(context, manager, id)
        }
    }

    @Synchronized
    fun draw(context: Context, manager: AppWidgetManager, id: Int) {
        // Not chosen yet: the widget is being placed.
        val view = view(context, id) ?: return
        val lists = runCatching { Repo.store.lists() }.getOrElse { return }
        val list = (view as? WidgetView.OfList)?.let { of -> lists.firstOrNull { it.id == of.id } }
        val title = when (view) {
            WidgetView.Today -> context.getString(R.string.today)
            WidgetView.Inbox -> context.getString(R.string.inbox)
            is WidgetView.OfList -> list?.name ?: context.getString(R.string.list)
        }
        // The view keeps completed tasks for a while (R68); the widget does not.
        val open = if (view is WidgetView.OfList && list == null) emptyList()
        else runCatching { Repo.store.tasks(view.scope) }.getOrElse { return }.filter { it.done == null }
            .let { tasks -> if (view == WidgetView.Today) overdueFirst(tasks, { it.due }) else tasks }

        // In portrait the widget is as high as the largest height the launcher reports.
        val height = manager.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT)
        val (tasks, more) = shown(open, rowsThatFit(if (height > 0) height else 110))

        val app = PendingIntent.getActivity(
            context, 0,
            // The screen that is open takes the view; a second one is not put over it.
            Intent(context, MainActivity::class.java).setAction("view.${view.encode()}").putExtra(MainActivity.EXTRA_VIEW, view.encode())
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val add = PendingIntent.getActivity(
            context, 0, Intent(context, QuickAddActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val views = RemoteViews(context.packageName, R.layout.widget_tasks)
        views.setTextViewText(R.id.widget_title, title)
        views.setOnClickPendingIntent(R.id.widget_title, app)
        views.setOnClickPendingIntent(R.id.widget_add, add)
        views.removeAllViews(R.id.widget_rows)
        for (task in tasks) {
            val complete = PendingIntent.getBroadcast(
                context, 0,
                Intent(context, TaskWidgetReceiver::class.java).setAction(COMPLETE).setData(Uri.fromParts("task", task.id, null)),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val row = RemoteViews(context.packageName, R.layout.widget_task_row)
            row.setTextViewText(R.id.widget_task_title, task.title)
            row.setOnClickPendingIntent(R.id.widget_task_title, app)
            row.setOnClickPendingIntent(R.id.widget_task_mark, complete)
            views.addView(R.id.widget_rows, row)
        }
        val note = when {
            more > 0 -> context.getString(R.string.today_notice_more, more.toString())
            open.isEmpty() -> context.getString(R.string.widget_empty)
            else -> null
        }
        if (note != null) {
            val row = RemoteViews(context.packageName, R.layout.widget_note_row)
            row.setTextViewText(R.id.widget_note, note)
            row.setOnClickPendingIntent(R.id.widget_note, app)
            views.addView(R.id.widget_rows, row)
        }
        manager.updateAppWidget(id, views)
    }
}

/** Both widgets are drawn the same way; they differ in the size they are offered in (R107). */
abstract class TaskWidgetProvider : AppWidgetProvider() {
    // Also the half-hourly update of the system, which takes Today into the next day.
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) = redraw(context)

    // The number of rows follows the height.
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) = redraw(context)

    override fun onDeleted(context: Context, ids: IntArray) = TaskWidgets.forget(context, ids)

    private fun redraw(context: Context) {
        val result = goAsync()
        Repo.scope.launch {
            TaskWidgets.refresh(context.applicationContext)
            result.finish()
        }
    }
}

class SmallTaskWidget : TaskWidgetProvider()
class LargeTaskWidget : TaskWidgetProvider()

/** The mark of a row: completes the task, as the mark in the app does (R107). */
class TaskWidgetReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != TaskWidgets.COMPLETE) return
        val id = intent.data?.schemeSpecificPart ?: return
        val result = goAsync()
        Repo.scope.launch {
            runCatching { Repo.store.completeTask(id) }
            Repo.changed()
            // Drawn here as well: what Repo.changed() starts is not waited for.
            TaskWidgets.refresh(context.applicationContext)
            result.finish()
        }
    }
}
