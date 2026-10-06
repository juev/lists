package org.evsyukov.lists

import android.app.AlarmManager
import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
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
        Store.open(File(filesDir, "lists").absolutePath).also { it.setSyncPassword(Secrets.load(this)) }
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
        if (store.syncConfig() is SyncConfig.Off) return@withContext Result.success(SyncReport(0u, 0u, 0u, 0u))
        syncMutex.withLock {
            syncing.value = true
            val result = runCatching { store.syncNow() }
            syncing.value = false
            // The status changed either way; data only if something arrived.
            revision.update { it + 1 }
            if (result.getOrNull()?.pulled?.let { it > 0u } == true) Reminders.refresh(ListsApp.instance)
            result
        }
    }
}

/**
 * Sync as a system job: every 15 minutes (the platform minimum) to pull what
 * was changed elsewhere while the app is closed, and once after a local write.
 */
class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result =
        if (Repo.sync().isSuccess) Result.success() else Result.retry()

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

    fun refresh(context: Context) {
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
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
            // Inexact on purpose: exact alarms need a special permission a to-do list should not ask for.
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending(context, item.taskId ?: item.key, title, body))
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

    fun notify(context: Context, id: String, title: String, body: String) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, context.getString(R.string.reminders_channel), NotificationManager.IMPORTANCE_HIGH)
        )
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

/** Alarms do not survive a reboot. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
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
