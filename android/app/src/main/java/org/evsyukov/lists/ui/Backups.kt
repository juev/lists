package org.evsyukov.lists.ui

import android.net.Uri
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.evsyukov.lists.R
import org.evsyukov.lists.Repo
import org.evsyukov.lists.dateLabel
import org.evsyukov.lists.str
import uniffi.lists_core.Backup
import uniffi.lists_core.BackupSettings
import uniffi.lists_core.SyncConfig
import java.io.File

private val everyChoices = listOf(0u, 24u, 48u)
private val keepChoices = listOf(5u, 10u, 20u, 30u)

private fun everyLabel(hours: UInt) = when (hours) {
    0u -> str(R.string.backups_never)
    24u -> str(R.string.backups_every_24)
    else -> str(R.string.backups_every_48)
}

/** What is to be restored: a backup of the list, or a file picked outside the app. */
private data class Restore(val path: String, val label: String, val temporary: File? = null)

/**
 * The backups of this device (R88–R90): the schedule, the number to keep, the
 * backups themselves and restoring from one of them or from a file.
 */
@Composable
fun BackupsDialog(model: MainViewModel, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var settings by remember { mutableStateOf(Repo.store.backupSettings()) }
    var backups by remember { mutableStateOf(runCatching { Repo.store.backups() }.getOrDefault(emptyList())) }
    var choosing by remember { mutableStateOf<String?>(null) }
    var chosen by remember { mutableStateOf<Backup?>(null) }
    var restoring by remember { mutableStateOf<Restore?>(null) }
    var saving by remember { mutableStateOf<Backup?>(null) }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var failed by remember { mutableStateOf(false) }
    val synced = remember { runCatching { Repo.store.syncConfig() }.getOrNull() !is SyncConfig.Off }

    fun label(backup: Backup) = dateLabel(backup.created)

    /** Runs `work` off the main thread and shows what came of it. */
    fun run(done: String?, work: () -> Unit) {
        busy = true
        scope.launch {
            val result = withContext(Dispatchers.IO) { runCatching(work) }
            busy = false
            failed = result.isFailure
            message = result.fold({ done }, { describe(it) })
            backups = runCatching { Repo.store.backups() }.getOrDefault(emptyList())
        }
    }

    fun setSettings(changed: BackupSettings) {
        runCatching { Repo.store.setBackupSettings(changed) }
            .onSuccess { settings = changed }
            .onFailure { failed = true; message = describe(it) }
    }

    fun restore(what: Restore, overStorage: Boolean) {
        restoring = null
        busy = true
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { Repo.store.restoreBackup(what.path, overStorage) }
                    .also { what.temporary?.parentFile?.deleteRecursively() }
            }
            busy = false
            failed = result.isFailure
            message = result.fold({ str(R.string.backups_restored, what.label) }, { describe(it) })
            backups = runCatching { Repo.store.backups() }.getOrDefault(emptyList())
            // The lists, the reminders and the next sync all start from the restored data.
            if (result.isSuccess) Repo.changed()
        }
    }

    val saveCopy = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        val backup = saving
        saving = null
        if (uri != null && backup != null) {
            run(str(R.string.backups_copy_saved)) {
                context.contentResolver.openOutputStream(uri)?.use { out -> File(backup.path).inputStream().use { it.copyTo(out) } }
                    ?: error("cannot write the file")
            }
        }
    }
    val pickFile = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri != null) {
            scope.launch {
                val file = withContext(Dispatchers.IO) { copyToCache(context, uri) }
                if (file == null) {
                    failed = true
                    message = str(R.string.backups_cannot_read)
                } else {
                    restoring = Restore(file.absolutePath, file.name, file)
                }
            }
        }
    }

    FormDialog(
        title = str(R.string.backups),
        onDismiss = onDismiss,
        confirmButton = { TextButton(onClick = onDismiss) { Text(str(R.string.close)) } },
        dismissButton = {},
        content = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                SettingRow(str(R.string.backups_create), everyLabel(settings.everyHours)) { choosing = "every" }
                SettingRow(str(R.string.backups_keep), settings.keep.toString()) { choosing = "keep" }
                Text(str(R.string.backups_hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Row {
                    TextButton(enabled = !busy, onClick = { run(null) { Repo.store.createBackup() } }) { Text(str(R.string.backups_now)) }
                    TextButton(enabled = !busy, onClick = { pickFile.launch(arrayOf("*/*")) }) { Text(str(R.string.backups_from_file)) }
                }
                (if (busy) str(R.string.backups_working) else message)?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = if (failed && !busy) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                }
                HorizontalDivider(Modifier.padding(vertical = 8.dp))
                if (backups.isEmpty()) {
                    Text(str(R.string.backups_none), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                for (backup in backups) {
                    Row(
                        Modifier.fillMaxWidth().clickable(enabled = !busy, role = Role.Button) { chosen = backup }.padding(vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(label(backup), Modifier.weight(1f))
                        Text(Formatter.formatShortFileSize(context, backup.size.toLong()), color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        },
    )

    when (choosing) {
        "every" -> ChoiceDialog(str(R.string.backups_create), everyChoices.map(::everyLabel), everyChoices.indexOf(settings.everyHours), { choosing = null }) {
            setSettings(settings.copy(everyHours = everyChoices[it]))
        }
        "keep" -> ChoiceDialog(str(R.string.backups_keep), keepChoices.map { it.toString() }, keepChoices.indexOf(settings.keep), { choosing = null }) {
            setSettings(settings.copy(keep = keepChoices[it]))
        }
    }
    chosen?.let { backup ->
        ChoiceDialog(
            label(backup),
            listOf(str(R.string.backups_restore), str(R.string.backups_save_copy), str(R.string.delete)),
            -1,
            { chosen = null },
        ) {
            when (it) {
                0 -> restoring = Restore(backup.path, label(backup))
                1 -> { saving = backup; saveCopy.launch(backup.name) }
                else -> run(null) { Repo.store.deleteBackup(backup.name) }
            }
        }
    }
    restoring?.let { what ->
        val dismiss = { what.temporary?.parentFile?.deleteRecursively(); restoring = null }
        AlertDialog(
            onDismissRequest = dismiss,
            title = { Text(str(R.string.backups_restore_title)) },
            text = {
                Column {
                    Text(str(R.string.backups_restore_text, what.label))
                    if (synced) {
                        // S40: with sync on, what the storage holds has to be settled as well.
                        Text(str(R.string.backups_restore_sync), Modifier.padding(top = 12.dp))
                        @Composable
                        fun option(text: String, action: () -> Unit) =
                            Text(text, Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = action).padding(vertical = 12.dp), color = MaterialTheme.colorScheme.error)
                        option(str(R.string.backups_restore_merge)) { restore(what, false) }
                        option(str(R.string.backups_restore_replace)) { restore(what, true) }
                    }
                }
            },
            confirmButton = {
                if (!synced) {
                    TextButton(onClick = { restore(what, false) }) { Text(str(R.string.backups_restore_confirm), color = MaterialTheme.colorScheme.error) }
                }
            },
            dismissButton = { TextButton(onClick = dismiss) { Text(str(R.string.cancel)) } },
        )
    }
}
