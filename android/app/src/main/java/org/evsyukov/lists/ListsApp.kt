package org.evsyukov.lists

import android.app.AlarmManager
import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.res.Configuration
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.compose.runtime.mutableStateOf
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import uniffi.lists_core.LogLevel
import uniffi.lists_core.finishPushes
import uniffi.lists_core.NotificationKind
import uniffi.lists_core.NotifySettings
import uniffi.lists_core.Store
import uniffi.lists_core.SyncConfig
import uniffi.lists_core.SyncReport
import java.io.File
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.concurrent.TimeUnit

class ListsApp : Application() {
    /** The database lives in the app's private storage; nothing else on the device can read it. */
    val store: Store by lazy {
        Store.open(File(filesDir, "lists").absolutePath).also {
            it.setSyncPassword(Secrets.load(this))
            it.setPushToken(Secrets.load(this, Secrets.PUSH_TOKEN))
            // R102: where a log of events begins for this run.
            val version = runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull() ?: "?"
            it.log(LogLevel.INFO, "app", "started $version on Android ${android.os.Build.VERSION.RELEASE}")
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        SyncWorker.schedule(this)
        Repo.scope.launch { Reminders.refresh(this@ListsApp) }
    }

    companion object {
        lateinit var instance: ListsApp
            private set
    }
}

/** One place every screen goes through to reach the core and to learn that data changed. */
object Repo {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    val store: Store get() = ListsApp.instance.store

    /** Bumped after every change, local or pulled; screens reload when it moves. */
    val revision = MutableStateFlow(0)
    val syncing = MutableStateFlow(false)

    private val syncMutex = Mutex()
    private var pending: Job? = null
    private var moving: Job? = null

    /**
     * Call after a local write: refreshes screens and reminders, syncs after two quiet seconds.
     * The sync is handed to the system, so it still happens when the process is gone by then
     * (a task shared into the app closes its window at once) or the network comes back later.
     */
    fun changed() {
        revision.update { it + 1 }
        pending?.cancel()
        pending = scope.launch { Reminders.refresh(ListsApp.instance) }
        SyncWorker.soon(ListsApp.instance)
    }

    suspend fun sync(): Result<SyncReport> = withContext(Dispatchers.IO) {
        // R88: the automatic backup is looked at with every run, with sync on or off.
        runCatching { store.backupIfDue() }
        if (store.syncConfig() is SyncConfig.Off) return@withContext Result.success(SyncReport(0u, 0u, 0u, 0u))
        val result = syncMutex.withLock {
            syncing.value = true
            val result = runCatching { store.syncNow() }
            syncing.value = false
            // The status changed either way; data only if something arrived.
            revision.update { it + 1 }
            if (result.getOrNull()?.pulled?.let { it > 0u } == true) Reminders.refresh(ListsApp.instance)
            result
        }
        if (result.isSuccess) moveAttachments()
        // S19: nudges leave after the run; a background worker must not report done, and be stopped, before they have gone.
        finishPushes()
        result
    }

    /**
     * S34: the content of attachments moves after the fields are on screen, and the next run
     * for the fields does not wait for it. One pass at a time; the screens reload when it ends.
     */
    @Synchronized
    private fun moveAttachments() {
        if (moving?.isActive == true) return
        moving = scope.launch {
            runCatching { store.syncAttachments() }
            revision.update { it + 1 }
        }
    }

    /** Waits for the pass over attachment content that is going, if one is. */
    suspend fun attachmentsMoved() {
        moving?.join()
    }
}

/**
 * Sync as a system job: every 15 minutes (the platform minimum) to pull what
 * was changed elsewhere while the app is closed, and once after a local write.
 */
class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val synced = Repo.sync().isSuccess
        // The job holds the process until the content of attachments has moved as well (S34).
        Repo.attachmentsMoved()
        return if (synced) Result.success() else Result.retry()
    }

    companion object {
        private val online = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

        /** One run at once, for a nudge from another device. The system lets it start even from the background. */
        fun now(context: Context) {
            val request = OneTimeWorkRequestBuilder<SyncWorker>()
                .setConstraints(online)
                // Before Android 12 an expedited job needs a foreground notification; a plain one will do there.
                .apply { if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST) }
                .build()
            WorkManager.getInstance(context)
                .enqueueUniqueWork("sync-now", ExistingWorkPolicy.REPLACE, request)
        }

        /** One run two seconds from now; a newer call replaces one still waiting. */
        fun soon(context: Context) {
            val request = OneTimeWorkRequestBuilder<SyncWorker>()
                .setInitialDelay(2, TimeUnit.SECONDS)
                .setConstraints(online)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .build()
            WorkManager.getInstance(context)
                .enqueueUniqueWork("sync-soon", ExistingWorkPolicy.REPLACE, request)
        }

        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<SyncWorker>(15, TimeUnit.MINUTES)
                .setConstraints(online)
                .build()
            WorkManager.getInstance(context)
                .enqueueUniquePeriodicWork("sync", ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}

/** Notification settings of this device; not synced. */
object NotifyPrefs {
    private const val PREFS = "notify"
    val times = listOf("07:00", "08:00", "09:00", "10:00", "12:00", "18:00", "20:00")
    val leads = listOf(0, 5, 15, 30, 60, 120, 1440)

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    fun enabled(context: Context) = prefs(context).getBoolean("enabled", true)
    /**
     * Minutes before a timed due date, one notification for each; empty turns
     * these reminders off. Before several were allowed there was one, kept
     * under `lead`, with -1 for off.
     */
    fun leads(context: Context): List<Int> {
        val prefs = prefs(context)
        prefs.getString("leads", null)?.let { saved -> return saved.split(',').mapNotNull { it.toIntOrNull() }.sorted() }
        return listOf(prefs.getInt("lead", 15)).filter { it >= 0 }
    }
    /** `HH:MM`, empty for off. */
    fun allDay(context: Context) = prefs(context).getString("allDay", "09:00").orEmpty()
    fun summary(context: Context) = prefs(context).getString("summary", "").orEmpty()

    fun save(context: Context, enabled: Boolean, leads: List<Int>, allDay: String, summary: String) {
        prefs(context).edit().putBoolean("enabled", enabled).putString("leads", leads.sorted().joinToString(",")).putString("allDay", allDay).putString("summary", summary).apply()
    }

    fun settings(context: Context) = NotifySettings(
        enabled = enabled(context),
        leadMinutes = leads(context).map { it.toUInt() },
        allDayAt = allDay(context).ifEmpty { null },
        summaryAt = summary(context).ifEmpty { null },
    )
}

/** The look of the app on this device (R61); not synced. */
object LookPrefs {
    val choices = listOf("system", "light", "dark")

    private fun prefs(context: Context) = context.getSharedPreferences("look", Context.MODE_PRIVATE)

    /** Set once the look is chosen; the theme reads it, so the screen is repainted at once. */
    private val chosen = mutableStateOf<String?>(null)

    /** `system`, `light` or `dark`. */
    fun appearance(context: Context): String =
        chosen.value ?: prefs(context).getString("appearance", null).takeIf { it in choices } ?: "system"

    fun setAppearance(context: Context, value: String) {
        prefs(context).edit().putString("appearance", value).apply()
        chosen.value = value
    }

    /** R100: the steps of the text size, the same as on macOS; the second is the default. */
    val textScales = listOf(0.9f, 1f, 1.15f, 1.3f, 1.5f)

    /** The step a saved value stands for; a value that is not a step is the default. */
    internal fun textScaleFrom(saved: Float?): Float = saved?.takeIf { it in textScales } ?: 1f

    /** What the font size of the system is multiplied by in the app. */
    fun textScale(context: Context): Float =
        textScaleFrom(prefs(context).takeIf { it.contains("textScale") }?.getFloat("textScale", 1f))

    /** Written at once: the activity that is rebuilt to show the new size reads it back. */
    fun setTextScale(context: Context, value: Float) {
        prefs(context).edit().putFloat("textScale", value).commit()
    }

    /**
     * What an activity lays over its configuration to show the chosen size:
     * the font scale of the system times the step. Set on the context and not
     * in the theme, because a dialog and a sheet are windows of their own and
     * take the scale from the context.
     */
    fun textConfiguration(base: Context) = Configuration().apply {
        fontScale = base.resources.configuration.fontScale * textScale(base)
    }
}

/** How new tasks are entered on this device; not synced. */
object EntryPrefs {
    private fun prefs(context: Context) = context.getSharedPreferences("entry", Context.MODE_PRIVATE)

    /** `inbox`, `last` or a list id. */
    fun newTaskList(context: Context) = prefs(context).getString("newTaskList", "inbox") ?: "inbox"
    fun setNewTaskList(context: Context, value: String) = prefs(context).edit().putString("newTaskList", value).apply()
    fun noteUsedList(context: Context, id: String) = prefs(context).edit().putString("lastUsedList", id).apply()

    /** Whether dates, priority, tags and a list are picked out of the typed title. */
    fun parse(context: Context) = prefs(context).getBoolean("parse", true)
    fun setParse(context: Context, value: Boolean) = prefs(context).edit().putBoolean("parse", value).apply()

    /** Whether quick entry starts the note with what is on the clipboard (R58). */
    fun clipboard(context: Context) = prefs(context).getBoolean("clipboard", true)
    fun setClipboard(context: Context, value: Boolean) = prefs(context).edit().putBoolean("clipboard", value).apply()

    /**
     * The text on the clipboard as the note of a new task, or null when there
     * is none or it was offered before. Call it while the window has the
     * focus: the system hands the clipboard to nobody else. What the clip is
     * and when it was copied is told by its description, which the system
     * gives without its notice of a paste; the text itself is read only for a
     * clip not seen before.
     */
    fun clipboardNote(context: Context): String? {
        val clipboard = context.getSystemService(android.content.ClipboardManager::class.java) ?: return null
        val description = runCatching { clipboard.primaryClipDescription }.getOrNull() ?: return null
        if (description.extras?.getBoolean("android.content.extra.IS_SENSITIVE") == true) return null
        if (listOf("text/plain", "text/html", "text/uri-list").none(description::hasMimeType)) return null
        if (description.timestamp == prefs(context).getLong("clipboardUsed", 0)) return null
        val item = runCatching { clipboard.primaryClip?.getItemAt(0) }.getOrNull()
        // A copied link may come as an address without text; an address of a file is not a note.
        val text = (item?.text?.toString() ?: item?.uri?.takeIf { it.scheme == "http" || it.scheme == "https" }?.toString())?.trim()
        prefs(context).edit().putLong("clipboardUsed", description.timestamp).apply()
        return text?.takeIf { it.isNotEmpty() && it.length <= CLIPBOARD_NOTE_LIMIT }
    }

    /** A longer text is left alone: it is not cut to fit. */
    private const val CLIPBOARD_NOTE_LIMIT = 2000

    /** The list for a task entered where no list is implied. */
    fun defaultListId(context: Context, lists: List<uniffi.lists_core.TaskList>): String {
        val choice = newTaskList(context)
        val id = if (choice == "last") prefs(context).getString("lastUsedList", "inbox") ?: "inbox" else choice
        return if (lists.any { it.id == id && !it.archived }) id else "inbox"
    }
}

/** Turns the core's notification plan into alarms that post a notification. */
object Reminders {
    private const val CHANNEL = "reminders"
    private const val PREFS = "reminders"
    private const val KEY = "ids"

    /** R66: always before Android 12, by the user's leave since. */
    fun exact(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            context.getSystemService(AlarmManager::class.java)?.canScheduleExactAlarms() == true

    fun refresh(context: Context) {
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        val exact = exact(context)
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        for (id in prefs.getStringSet(KEY, emptySet()).orEmpty()) {
            alarms.cancel(pending(context, id, "", ""))
        }
        val plan = runCatching { Repo.store.plannedNotifications(NotifyPrefs.settings(context)) }.getOrDefault(emptyList())
        val scheduled = mutableSetOf<String>()
        for (item in plan) {
            val at = parseMoment(item.at)?.atZone(ZoneId.systemDefault())?.toInstant()?.toEpochMilli() ?: continue
            val (title, body) = when (item.kind) {
                NotificationKind.SUMMARY -> context.getString(R.string.app_name) to str(R.string.summary_body, item.count.toString())
                else -> item.title to item.due?.let { str(R.string.due_at, dateLabel(it).lowercase()) }.orEmpty()
            }
            val alarm = pending(context, item.taskId ?: item.key, title, body)
            // Without the permission the system may deliver the alarm late, within a window of up to an hour.
            if (exact) alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, alarm)
            else alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, alarm)
            scheduled += item.taskId ?: item.key
        }
        prefs.edit().putStringSet(KEY, scheduled).apply()
    }

    private fun pending(context: Context, id: String, title: String, body: String): PendingIntent {
        val intent = Intent(context, ReminderReceiver::class.java)
            .setAction("org.evsyukov.lists.REMIND.$id")
            .putExtra("id", id).putExtra("title", title).putExtra("body", body)
        return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** Creating a channel that exists changes nothing in it: its sound stays the one the user chose. */
    private fun ensureChannel(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.createNotificationChannel(
            NotificationChannel(CHANNEL, context.getString(R.string.reminders_channel), NotificationManager.IMPORTANCE_HIGH)
        )
    }

    /**
     * R36: the system screen of the channel, where its sound is chosen. The
     * channel is created first: before the first notification there is none,
     * and the screen has nothing to show.
     */
    fun channelSettings(context: Context): Intent {
        ensureChannel(context)
        return Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            .putExtra(Settings.EXTRA_CHANNEL_ID, CHANNEL)
    }

    fun notify(context: Context, id: String, title: String, body: String) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        ensureChannel(context)
        val open = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java).putExtra(MainActivity.EXTRA_TASK, id).setAction("open.$id"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = android.app.Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_check)
            .setContentTitle(title)
            .setContentText(body.ifEmpty { null })
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        manager.notify(id.hashCode(), notification)
    }
}

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Reminders.notify(
            context,
            intent.getStringExtra("id") ?: return,
            intent.getStringExtra("title").orEmpty(),
            intent.getStringExtra("body").orEmpty(),
        )
    }
}

/** Alarms do not survive a reboot, and they are set anew when the leave for exact ones is given (R66). */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED
        ) {
            val result = goAsync()
            Repo.scope.launch {
                Reminders.refresh(context.applicationContext)
                result.finish()
            }
        }
    }
}

fun parseMoment(value: String): LocalDateTime? = runCatching {
    if (value.length > 10) LocalDateTime.parse(value) else java.time.LocalDate.parse(value).atStartOfDay()
}.getOrNull()
