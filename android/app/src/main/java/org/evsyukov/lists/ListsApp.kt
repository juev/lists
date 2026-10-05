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
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
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

    /** Call after a local write: refreshes screens and reminders, syncs after two quiet seconds. */
    fun changed() {
        revision.update { it + 1 }
        pending?.cancel()
        pending = scope.launch {
            Reminders.refresh(ListsApp.instance)
            delay(2000)
            sync()
        }
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

/** Keeps the device in step while the app is closed. The interval is the platform minimum. */
class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result =
        if (Repo.sync().isSuccess) Result.success() else Result.retry()

    companion object {
        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<SyncWorker>(15, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(context)
                .enqueueUniquePeriodicWork("sync", ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}

/** Mirrors reminders of open tasks into alarms that post a notification. */
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
        val tasks = runCatching { Repo.store.reminders() }.getOrDefault(emptyList())
        val now = System.currentTimeMillis()
        val scheduled = mutableSetOf<String>()
        for (task in tasks) {
            val at = task.remind?.let(::parseMoment)?.atZone(ZoneId.systemDefault())?.toInstant()?.toEpochMilli() ?: continue
            if (at <= now) continue
            val body = task.due?.let { str(R.string.due_at, dateLabel(it).lowercase()) }.orEmpty()
            // Inexact on purpose: exact alarms need a special permission a to-do list should not ask for.
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending(context, task.id, task.title, body))
            scheduled += task.id
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
