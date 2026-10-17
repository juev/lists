package org.evsyukov.lists.ui

import android.app.Activity
import android.content.ClipData
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.AttachFile
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Event
import androidx.compose.material.icons.outlined.Flag
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.Repeat
import androidx.compose.material.icons.outlined.Tag
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.InputChip
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.ProvideTextStyle
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.evsyukov.lists.Background
import org.evsyukov.lists.EntryPrefs
import org.evsyukov.lists.EventPrefs
import org.evsyukov.lists.IconCount
import org.evsyukov.lists.LookPrefs
import org.evsyukov.lists.NotifyPrefs
import org.evsyukov.lists.Push
import org.evsyukov.lists.R
import org.evsyukov.lists.Reminders
import org.evsyukov.lists.Repo
import org.evsyukov.lists.Secrets
import org.evsyukov.lists.SystemCalendars
import org.evsyukov.lists.TodayNotice
import org.evsyukov.lists.dateLabel
import org.evsyukov.lists.displayName
import org.evsyukov.lists.every
import org.evsyukov.lists.fromStore
import org.evsyukov.lists.isOverdue
import org.evsyukov.lists.listColors
import org.evsyukov.lists.logError
import org.evsyukov.lists.logged
import org.evsyukov.lists.ordinal
import org.evsyukov.lists.plusDays
import org.evsyukov.lists.presetName
import org.evsyukov.lists.priorities
import org.evsyukov.lists.repeatPresets
import org.evsyukov.lists.str
import org.evsyukov.lists.summary
import org.evsyukov.lists.title
import org.evsyukov.lists.today
import org.evsyukov.lists.weekdayNames
import uniffi.lists_core.Attachment
import uniffi.lists_core.ConnectionCheck
import uniffi.lists_core.DueWindow
import uniffi.lists_core.FilterSpec
import uniffi.lists_core.FilterStatus
import uniffi.lists_core.Freq
import uniffi.lists_core.KeepDone
import uniffi.lists_core.LogLevel
import uniffi.lists_core.Priority
import uniffi.lists_core.Repeat
import uniffi.lists_core.SavedFilter
import uniffi.lists_core.SortMode
import uniffi.lists_core.Store
import uniffi.lists_core.SyncConfig
import uniffi.lists_core.SyncSide
import uniffi.lists_core.TaskItem
import uniffi.lists_core.TaskList
import uniffi.lists_core.checkSyncConnection
import java.io.File

/** Copies what a content URI points at into a cache file named like the original; a file that does not come is logged (R102). */
fun copyToCache(context: Context, uri: Uri): File? = runCatching {
    val name = context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst()) cursor.getString(0) else null
    } ?: uri.lastPathSegment ?: "file"
    val dir = File(context.cacheDir, "incoming/${System.nanoTime()}").apply { mkdirs() }
    val target = File(dir, name.replace('/', '_'))
    context.contentResolver.openInputStream(uri)?.use { input -> target.outputStream().use(input::copyTo) }
        ?: run {
            logError("attachments", "a picked or shared file was not copied: the provider gave no content")
            return null
        }
    target
}.onFailure { logError("attachments", "a picked or shared file was not copied: ${logged(it)}") }.getOrNull()

/**
 * Attaches the files behind the URIs to a task; the temporary copies are removed afterwards.
 * Returns the names of the files that were not attached (R139): the core logs why (R102).
 */
fun attach(context: Context, store: Store, taskId: String, uris: List<Uri>): List<String> {
    val failed = mutableListOf<String>()
    for (uri in uris) {
        val file = copyToCache(context, uri)
        if (file == null) {
            failed += uri.lastPathSegment ?: str(R.string.file)
            continue
        }
        runCatching { store.addAttachment(taskId, file.absolutePath, file.name) }.onFailure { failed += file.name }
        file.parentFile?.deleteRecursively()
    }
    return failed
}

/** R139: files that did not become attachments; the message names them. */
class NotAttached(names: List<String>) : Exception(str(R.string.not_attached, names.joinToString(", ")))

/** Writes the content of an attachment to the place the user picked (R86). */
internal fun copyAttachment(context: Context, file: Attachment, target: Uri): Boolean = runCatching {
    val path = file.localPath ?: return false
    val out = context.contentResolver.openOutputStream(target, "w") ?: return false
    out.use { File(path).inputStream().use { input -> input.copyTo(out) } }
    true
}.getOrDefault(false)

/**
 * Lets the share sheet itself read the files, not only the app chosen in it: the sheet takes the permission from
 * the clip of the intent, and without it cannot ask for the name of a file and shows the hash it is stored under.
 */
private fun Intent.readable(uris: List<Uri>): Intent = apply {
    if (uris.isNotEmpty()) {
        clipData = ClipData.newRawUri(null, uris[0]).also { clip -> uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) } }
    }
    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
}

/** Hands the file to another app through the share sheet (R86). */
private fun shareAttachment(context: Context, file: Attachment) {
    val path = file.localPath ?: return
    runCatching {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", File(path), file.name)
        val intent = Intent(Intent.ACTION_SEND).setType(file.mime).putExtra(Intent.EXTRA_STREAM, uri).readable(listOf(uri))
        context.startActivity(Intent.createChooser(intent, file.name))
    }.onFailure { logError("attachments", "a file was not shared: ${logged(it)}") }
}

/** R91: fetches the content that has not arrived; gives the attachments that are here now and the names of those that are not. */
private fun withContent(files: List<Attachment>): Pair<List<Attachment>, List<String>> {
    val here = mutableListOf<Attachment>()
    val missing = mutableListOf<String>()
    for (file in files) {
        val got = if (file.localPath != null) file else runCatching { Repo.store.fetchAttachment(file.id) }.getOrNull()
        if (got?.localPath != null) here += got else missing += file.name
    }
    return here to missing
}

/**
 * Writes each attachment into the folder the user picked as a new document (R91) and gives the names of those
 * that could not be written. Nothing is replaced: the provider gives a document whose name is taken a name of its own.
 */
internal fun saveInto(context: Context, tree: Uri, files: List<Attachment>): List<String> {
    val resolver = context.contentResolver
    val folder = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
    return files.filterNot { file ->
        val target = runCatching { DocumentsContract.createDocument(resolver, folder, file.mime, file.name) }.getOrNull()
        val written = target != null && copyAttachment(context, file, target)
        // A document that was made and not filled is not left behind.
        if (target != null && !written) runCatching { DocumentsContract.deleteDocument(resolver, target) }
        written
    }.map { it.name }
}

/** The type a share sheet is asked for when it carries these files: theirs when they agree, the widest that covers them otherwise. */
internal fun shareType(mimes: List<String>): String {
    val all = mimes.distinct()
    val kinds = all.map { it.substringBefore('/') }.distinct()
    return when {
        all.size == 1 -> all[0]
        kinds.size == 1 && all.isNotEmpty() -> "${kinds[0]}/*"
        else -> "*/*"
    }
}

/** Hands every file to another app through one share sheet (R91). */
private fun shareAttachments(context: Context, files: List<Attachment>) {
    runCatching {
        val uris = ArrayList(files.mapNotNull { file ->
            file.localPath?.let { FileProvider.getUriForFile(context, "${context.packageName}.files", File(it), file.name) }
        })
        val intent = Intent(Intent.ACTION_SEND_MULTIPLE).setType(shareType(files.map { it.mime }))
            .putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris).readable(uris)
        context.startActivity(Intent.createChooser(intent, null))
    }.onFailure { logError("attachments", "files were not shared: ${logged(it)}") }
}

/**
 * R102: hands the files of the log to another app. They go as copies in the
 * cache: the folder they live in holds the database and is not opened to others.
 */
private fun shareLog(context: Context, files: List<String>) {
    runCatching {
        val out = File(context.cacheDir, "logs").apply { mkdirs() }
        val uris = ArrayList(files.map { path ->
            val copy = File(path).copyTo(File(out, File(path).name), overwrite = true)
            FileProvider.getUriForFile(context, "${context.packageName}.files", copy)
        })
        val intent = Intent(Intent.ACTION_SEND_MULTIPLE).setType("text/plain")
            .putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris).readable(uris)
        context.startActivity(Intent.createChooser(intent, null))
    }
}

private fun openAttachment(context: Context, file: Attachment) {
    val path = file.localPath ?: return
    runCatching {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", File(path), file.name)
        val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, file.mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        context.startActivity(Intent.createChooser(intent, file.name))
    }.onFailure { logError("attachments", "a file was not opened: ${logged(it)}") }
}

/**
 * The task editor: a sheet over the list. Title, note and one row of fields:
 * a chip for each field that is set, a light icon for each that is not (R96).
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun EditorSheet(editing: Editing, state: UiState, model: MainViewModel, onReminderSet: () -> Unit) {
    val task = editing.task
    val locked = task.deleted || task.isLog
    val context = LocalContext.current
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    // R99: stretched to the whole screen with the handle; the next task opens at the height of its content.
    var tall by rememberSaveable(task.id) { mutableStateOf(false) }
    var dialog by rememberSaveable(task.id) { mutableStateOf<String?>(null) }
    var menu by remember { mutableStateOf(false) }
    // Subtasks are not mentioned until the task has one or the user asks for the field.
    var subtaskField by remember(task.id) { mutableStateOf(false) }
    // R38: the subtask whose title is edited in its line.
    var renaming by remember(task.id) { mutableStateOf<String?>(null) }
    // The attachment shown over the screen; it closes by itself when the file is removed elsewhere.
    var viewing by remember(task.id) { mutableStateOf<String?>(null) }
    // Attachments being downloaded on request, and those the last request did not get (R76).
    var fetching by remember(task.id) { mutableStateOf(setOf<String>()) }
    var fetchFailed by remember(task.id) { mutableStateOf(setOf<String>()) }
    val fetchScope = rememberCoroutineScope()
    val pickFiles = rememberLauncherForActivityResult(ActivityResultContracts.GetMultipleContents()) { uris ->
        if (uris.isNotEmpty()) {
            model.change { store -> attach(context, store, task.id, uris).takeIf { it.isNotEmpty() }?.let { throw NotAttached(it) } }
        }
    }
    // R86: the attachment waiting for the place the system picker returns, and the row whose menu is open.
    var saving by remember(task.id) { mutableStateOf<Attachment?>(null) }
    var fileMenu by remember(task.id) { mutableStateOf<String?>(null) }
    val saveFile = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("*/*")) { uri ->
        val file = saving
        saving = null
        if (uri != null && file != null) {
            fetchScope.launch {
                val saved = withContext(Dispatchers.IO) { copyAttachment(context, file, uri) }
                Toast.makeText(context, if (saved) R.string.file_saved else R.string.file_not_saved, Toast.LENGTH_SHORT).show()
            }
        }
    }
    fun save(file: Attachment) {
        saving = file
        saveFile.launch(file.name)
    }
    // R91: every file of the task in one action. Those still to arrive are fetched first and their rows show it.
    var gathering by remember(task.id) { mutableStateOf(false) }
    val several = editing.attachments.size > 1
    // The work outlives the card: closing it does not leave a part of the files unsaved.
    fun withAll(then: (List<Attachment>) -> List<String>, done: Int?, failed: Int) {
        val files = editing.attachments
        gathering = true
        Repo.scope.launch {
            val (here, missing) = withContent(files)
            if (here.any { now -> files.any { it.id == now.id && it.localPath == null } }) Repo.revision.update { it + 1 }
            val lost = missing + then(here)
            withContext(Dispatchers.Main) {
                gathering = false
                if (lost.isNotEmpty()) {
                    Toast.makeText(context, context.getString(failed, lost.joinToString(", ")), Toast.LENGTH_LONG).show()
                } else if (done != null) {
                    Toast.makeText(context, done, Toast.LENGTH_SHORT).show()
                }
            }
        }
    }
    val saveAll = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { tree ->
        if (tree != null) withAll({ saveInto(context, tree, it) }, R.string.file_saved, R.string.files_not_saved)
    }
    fun shareAll() = withAll({ if (it.isNotEmpty()) shareAttachments(context, it); emptyList() }, null, R.string.files_not_downloaded)

    ModalBottomSheet(
        onDismissRequest = { model.open(null) },
        sheetState = sheet,
        dragHandle = { CardHandle(tall, { tall = it }, if (tall) Modifier.statusBarsPadding() else Modifier) },
    ) {
        Column((if (tall) Modifier.fillMaxHeight() else Modifier).verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 16.dp)) {
            // A task with a card and a parent is a task of a project (R10): the way back to the project.
            task.parentId?.let { parent ->
                TextButton(onClick = { model.open(parent) }, modifier = Modifier.padding(start = 8.dp)) {
                    Icon(Icons.AutoMirrored.Outlined.ArrowBack, null, Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(task.parentTitle.orEmpty(), maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(start = 4.dp, end = 4.dp)) {
                IconButton(onClick = { model.toggleDone(task) }, enabled = !locked) {
                    Mark(task.markState(), if (task.done != null) str(R.string.reopen) else str(R.string.complete))
                }
                CommittedField(
                    key = task.id,
                    value = task.title,
                    placeholder = str(R.string.title),
                    enabled = !locked,
                    singleLine = true,
                    wraps = true,
                    textStyle = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.weight(1f),
                ) { value -> if (value.isNotBlank()) model.act { it.setTitle(task.id, value) } }
                Box {
                    IconButton(onClick = { menu = true }) { Icon(Icons.Outlined.MoreVert, str(R.string.more)) }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        if (task.deleted) {
                            DropdownMenuItem(text = { Text(str(R.string.restore)) }, onClick = { menu = false; model.change { it.restoreTask(task.id) } })
                        } else {
                            DropdownMenuItem(text = { Text(str(R.string.move_to_list)) }, onClick = { menu = false; dialog = "list" })
                            DropdownMenuItem(text = { Text(str(R.string.duplicate)) }, onClick = { menu = false; model.change(str(R.string.created_notice)) { it.duplicateTask(task.id) } })
                            if (several) {
                                DropdownMenuItem(text = { Text(str(R.string.save_all_to)) }, onClick = { menu = false; saveAll.launch(null) })
                                DropdownMenuItem(text = { Text(str(R.string.share_all)) }, onClick = { menu = false; shareAll() })
                            }
                            DropdownMenuItem(
                                text = { Text(str(R.string.delete), color = MaterialTheme.colorScheme.error) },
                                onClick = { menu = false; model.delete(task) },
                            )
                        }
                    }
                }
            }
            MarkdownField(
                key = task.id,
                value = task.notes,
                placeholder = str(R.string.notes),
                enabled = !locked,
                textStyle = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.fillMaxWidth().padding(start = 36.dp, end = 8.dp),
            ) { value -> model.act { it.setNotes(task.id, value) } }

            if (!locked) {
                // R96: what is set stands at the left with its value, what is not at the right as a light icon.
                FieldsRow(
                    Modifier.fillMaxWidth().padding(start = 52.dp, end = 8.dp, top = 4.dp, bottom = 4.dp),
                    chips = {
                        task.start?.let { ValueChip(dateLabel(it), Icons.Outlined.PlayArrow, str(R.string.start)) { dialog = "start" } }
                        task.due?.let {
                            val overdue = isOverdue(it) && task.done == null
                            ValueChip(dateLabel(it), Icons.Outlined.Event, str(R.string.due), color = if (overdue) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface) { dialog = "due" }
                        }
                        task.repeat?.let { ValueChip(it.summary(), Icons.Outlined.Repeat, str(R.string.repeat)) { dialog = "repeat" } }
                        task.remind?.let { ValueChip(dateLabel(it), Icons.Outlined.Notifications, str(R.string.reminder)) { dialog = "remind" } }
                        if (task.priority != Priority.NONE) {
                            ValueChip(task.priority.title(), Icons.Outlined.Flag, str(R.string.priority), color = PriorityColor) { dialog = "priority" }
                        }
                        for (tag in task.tags) {
                            ValueChip("#$tag", trailing = Icons.Outlined.Close, trailingLabel = str(R.string.remove_tag)) { model.change { it.removeTag(task.id, tag) } }
                        }
                    },
                    icons = {
                        if (task.start == null) LightIcon(Icons.Outlined.PlayArrow, str(R.string.start)) { dialog = "start" }
                        if (task.due == null) LightIcon(Icons.Outlined.Event, str(R.string.due)) { dialog = "due" }
                        if (task.repeat == null) LightIcon(Icons.Outlined.Repeat, str(R.string.repeat)) { dialog = "repeat" }
                        if (task.remind == null) LightIcon(Icons.Outlined.Notifications, str(R.string.reminder)) { dialog = "remind" }
                        if (task.priority == Priority.NONE) LightIcon(Icons.Outlined.Flag, str(R.string.priority)) { dialog = "priority" }
                        LightIcon(Icons.Outlined.Tag, str(R.string.tag)) { dialog = "tag" }
                        if (editing.subtasks.isEmpty() && !subtaskField) LightIcon(Icons.Outlined.Checklist, str(R.string.subtask)) { subtaskField = true }
                        LightIcon(Icons.Outlined.AttachFile, str(R.string.file_or_image)) { pickFiles.launch("*/*") }
                    },
                )
            }

            for (file in editing.attachments) {
                Row(
                    Modifier.fillMaxWidth()
                        .clickable(enabled = file.id !in fetching && !(gathering && file.localPath == null)) {
                            // An image or a PDF is shown here (R54); the rest is for another app.
                            fun show(file: Attachment) {
                                if (previewKind(file.mime) != null) viewing = file.id else openAttachment(context, file)
                            }
                            if (file.localPath != null) {
                                show(file)
                            } else {
                                // R76: a file that has not arrived is downloaded ahead of the others and shown.
                                fetching = fetching + file.id
                                fetchFailed = fetchFailed - file.id
                                fetchScope.launch {
                                    val got = withContext(Dispatchers.IO) { runCatching { Repo.store.fetchAttachment(file.id) }.getOrNull() }
                                    fetching = fetching - file.id
                                    if (got?.localPath == null) {
                                        fetchFailed = fetchFailed + file.id
                                    } else {
                                        Repo.revision.update { it + 1 }
                                        show(got)
                                    }
                                }
                            }
                        }
                        .padding(start = 16.dp, end = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    AttachmentIcon(file)
                    Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                        Text(file.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(
                            when {
                                file.localPath != null -> android.text.format.Formatter.formatShortFileSize(context, file.size.toLong())
                                file.id in fetching || gathering -> str(R.string.downloading)
                                file.id in fetchFailed -> str(R.string.download_failed)
                                else -> str(R.string.not_downloaded)
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    if (file.localPath != null) {
                        Box {
                            IconButton(onClick = { fileMenu = file.id }) { Icon(Icons.Outlined.MoreVert, str(R.string.more)) }
                            DropdownMenu(expanded = fileMenu == file.id, onDismissRequest = { fileMenu = null }) {
                                DropdownMenuItem(text = { Text(str(R.string.save_to)) }, onClick = { fileMenu = null; save(file) })
                                DropdownMenuItem(text = { Text(str(R.string.share)) }, onClick = { fileMenu = null; shareAttachment(context, file) })
                                DropdownMenuItem(text = { Text(str(R.string.open_in_another_app)) }, onClick = { fileMenu = null; openAttachment(context, file) })
                                if (several) {
                                    DropdownMenuItem(text = { Text(str(R.string.save_all_to)) }, onClick = { fileMenu = null; saveAll.launch(null) })
                                    DropdownMenuItem(text = { Text(str(R.string.share_all)) }, onClick = { fileMenu = null; shareAll() })
                                }
                            }
                        }
                    }
                    if (!locked) {
                        IconButton(onClick = { model.change { it.removeAttachment(file.id) } }) { Icon(Icons.Outlined.Close, str(R.string.detach)) }
                    }
                }
            }

            val showSubtasks = editing.subtasks.isNotEmpty() || subtaskField
            // R96: thin lines between the subtasks, none before the first of them.
            val line = @Composable { HorizontalDivider(Modifier.padding(start = 52.dp, end = 16.dp), color = MaterialTheme.colorScheme.outlineVariant) }
            editing.subtasks.forEachIndexed { index, sub ->
                if (index > 0) line()
                // The tasks of a project are full tasks with a card; a subtask is a line (R10).
                if (task.isProject) {
                    TaskRow(sub, state, onToggle = { model.toggleDone(sub) }, onOpen = { model.open(sub.id) }, model = model, showOrigin = false, subtask = true)
                } else key(sub.id) {
                    SubtaskLine(sub, renaming == sub.id, model) { on ->
                        // The line that gives the edit up may already have lost it to another line.
                        if (on) renaming = sub.id else if (renaming == sub.id) renaming = null
                    }
                }
            }
            if (showSubtasks && !locked) {
                if (editing.subtasks.isNotEmpty()) line()
                SubtaskField { model.addSubtask(task.id, it) }
            }
        }
    }

    editing.attachments.firstOrNull { it.id == viewing }?.let { file ->
        previewKind(file.mime)?.let { kind ->
            AttachmentViewer(file, kind, onOpenOutside = { openAttachment(context, file) }, onSave = { save(file) }, onShare = { shareAttachment(context, file) }) { viewing = null }
        }
    }

    when (dialog) {
        "due" -> MomentDialog(str(R.string.due), task.due, onPick = { v -> model.change { it.setDue(task.id, v) } }) { dialog = null }
        "start" -> MomentDialog(str(R.string.start_title), task.start, onPick = { v -> model.change { it.setStart(task.id, v) } }) { dialog = null }
        "remind" -> MomentDialog(str(R.string.remind), task.remind, timeRequired = true, onPick = { v ->
            if (v != null) onReminderSet()
            model.change { it.setRemind(task.id, v) }
        }) { dialog = null }
        "repeat" -> RepeatDialog(task.repeat, onPick = { rule -> model.change { it.setRepeat(task.id, rule) } }) { dialog = null }
        "priority" -> ChoiceDialog(str(R.string.priority), priorities.map { it.title() }, priorities.indexOf(task.priority), { dialog = null }) { index ->
            model.change { it.setPriority(task.id, priorities[index]) }
        }
        "list" -> DestinationDialog(
            str(R.string.move_to_list),
            state.lists.filter { !it.archived },
            state.projects,
            task.parentId ?: task.listId,
            { dialog = null },
            projectEnabled = { task.goesInto(it.id) },
        ) { to ->
            when (to) {
                is Destination.ToList -> model.change { it.moveToList(task.id, to.id) }
                is Destination.ToProject -> model.change { it.moveToProject(task.id, to.id) }
            }
        }
        "tag" -> TagDialog(state.tags.map { it.name }.filter { it !in task.tags }, { dialog = null }) { tag -> model.change { it.addTag(task.id, tag) } }
    }
}

/**
 * A text field that saves when focus leaves it or the sheet closes, not on
 * every keystroke: each save is a change that syncs.
 */
@Composable
private fun CommittedField(
    key: String,
    value: String,
    placeholder: String,
    enabled: Boolean,
    singleLine: Boolean,
    textStyle: androidx.compose.ui.text.TextStyle,
    modifier: Modifier,
    // A one-line value shown over as many lines as it needs (R73): it wraps, and holds no line break.
    wraps: Boolean = false,
    onCommit: (String) -> Unit,
) {
    var text by remember(key) { mutableStateOf(value) }
    var focused by remember(key) { mutableStateOf(false) }
    // R143: the text the field held when the cursor went in; only what was typed since is written.
    var shown by remember(key) { mutableStateOf(value) }
    val saved by rememberUpdatedState(value)
    val commit by rememberUpdatedState(onCommit)
    // An edit arriving from another device replaces the text unless the user is typing here.
    LaunchedEffect(value) {
        if (focused) return@LaunchedEffect
        shown = value
        text = value
    }
    fun save() {
        val typed = typedEdit(text, shown, saved)
        if (typed != null) {
            commit(typed)
            shown = typed
        } else if (text.trim() == shown.trim()) {
            // Nothing was typed: what arrived meanwhile is shown now.
            text = saved
            shown = saved
        }
    }
    DisposableEffect(key) { onDispose { if (focused) save() } }
    // R83: an app left in the background may be killed there, and the field never loses the keyboard then.
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) { if (focused) save() }
    TextField(
        value = text,
        onValueChange = {
            // Enter in a wrapping field finishes the edit, as Done does; pasted lines become one line.
            if (singleLine && '\n' in it) {
                text = oneLine(text, it)
                save()
            } else {
                text = it
            }
        },
        placeholder = { Text(placeholder) },
        enabled = enabled,
        singleLine = singleLine && !wraps,
        textStyle = textStyle,
        colors = transparentField(),
        keyboardOptions = if (singleLine) SentenceKeyboard.copy(imeAction = ImeAction.Done) else SentenceKeyboard,
        keyboardActions = KeyboardActions(onDone = { save() }),
        modifier = modifier.onFocusChanged {
            if (focused && !it.isFocused) save()
            if (!focused && it.isFocused) shown = text
            focused = it.isFocused
        },
    )
}

/**
 * R143: what a field that loses the cursor writes: the trimmed text when it differs from what the field
 * showed when the cursor went in (`shown`) and from what is stored now (`stored`), which a sync may have
 * changed meanwhile; null when nothing was typed, so that a synced edit is not written over.
 */
internal fun typedEdit(text: String, shown: String, stored: String): String? {
    val trimmed = text.trim()
    return trimmed.takeIf { it != shown.trim() && it != stored }
}

// The text of a one-line field after an edit that brought line breaks (R73). Enter alone leaves the
// text as it was; pasted lines are joined with spaces.
internal fun oneLine(before: String, after: String): String =
    if (after.replace("\n", "") == before) before
    else after.lines().map(String::trim).filter(String::isNotEmpty).joinToString(" ")

@Composable
private fun SubtaskField(onAdd: (String) -> Unit) {
    var text by remember { mutableStateOf("") }
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(start = 4.dp)) {
        IconButton(onClick = { onAdd(text); text = "" }, enabled = text.isNotBlank()) { Icon(Icons.Outlined.Add, str(R.string.add_subtask)) }
        TextField(
            value = text,
            onValueChange = { text = it },
            placeholder = { Text(str(R.string.subtask)) },
            singleLine = true,
            colors = transparentField(),
            keyboardOptions = SentenceKeyboard.copy(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { onAdd(text); text = "" }),
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
fun ChoiceDialog(title: String, options: List<String>, selected: Int, onDismiss: () -> Unit, onPick: (Int) -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                options.forEachIndexed { index, option ->
                    Text(
                        option,
                        fontWeight = if (index == selected) FontWeight.Bold else null,
                        modifier = Modifier.fillMaxWidth().clickable { onPick(index); onDismiss() }.padding(vertical = 12.dp),
                    )
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text(str(R.string.cancel)) } },
    )
}

/** Where a task goes (R129): a list, or a project and with it the project's list. */
sealed interface Destination {
    data class ToList(val id: String) : Destination
    data class ToProject(val id: String, val listId: String) : Destination
}

/**
 * R129: the lists and, under them as a group of their own, the projects a task goes to. [selected] is the id of the
 * list or the project shown in bold; an option that is not enabled is shown dimmed and does nothing.
 */
@Composable
fun DestinationDialog(
    title: String,
    lists: List<TaskList>,
    projects: List<TaskItem>,
    selected: String?,
    onDismiss: () -> Unit,
    listEnabled: (TaskList) -> Boolean = { true },
    projectEnabled: (TaskItem) -> Boolean = { true },
    onPick: (Destination) -> Unit,
) {
    @Composable
    fun Option(text: String, on: Boolean, enabled: Boolean, pick: Destination) = Text(
        text,
        fontWeight = if (on) FontWeight.Bold else null,
        color = if (enabled) Color.Unspecified else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f),
        modifier = Modifier.fillMaxWidth().clickable(enabled = enabled) { onPick(pick); onDismiss() }.padding(vertical = 12.dp),
    )
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                lists.forEach { Option(it.displayName(), it.id == selected, listEnabled(it), Destination.ToList(it.id)) }
                if (projects.isNotEmpty()) {
                    HorizontalDivider(Modifier.padding(vertical = 4.dp))
                    Text(
                        str(R.string.projects),
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(vertical = 8.dp),
                    )
                    projects.forEach { Option(it.title, it.id == selected, projectEnabled(it), Destination.ToProject(it.id, it.listId)) }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text(str(R.string.cancel)) } },
    )
}

/** Several options can be on at once; each tap is applied right away. */
@Composable
fun MultiChoiceDialog(title: String, options: List<String>, selected: List<Boolean>, onDismiss: () -> Unit, onToggle: (Int, Boolean) -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                options.forEachIndexed { index, option ->
                    Row(
                        Modifier.fillMaxWidth().clickable { onToggle(index, !selected[index]) },
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Checkbox(checked = selected[index], onCheckedChange = { onToggle(index, it) })
                        Text(option)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(str(R.string.done)) } },
    )
}

@Composable
internal fun TagDialog(known: List<String>, onDismiss: () -> Unit, onAdd: (String) -> Unit) {
    var text by rememberSaveable { mutableStateOf("") }
    FormDialog(
        title = str(R.string.tag),
        onDismiss = onDismiss,
        content = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                OutlinedTextField(text, { text = it.replace(" ", "") }, singleLine = true, placeholder = { Text(str(R.string.one_word)) })
                for (tag in known.take(6)) {
                    Text("#$tag", Modifier.fillMaxWidth().clickable { onAdd(tag); onDismiss() }.padding(vertical = 10.dp))
                }
            }
        },
        confirmButton = { TextButton(enabled = text.isNotBlank(), onClick = { onAdd(text); onDismiss() }) { Text(str(R.string.add)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(str(R.string.cancel)) } },
    )
}

/** Presets first; the custom controls appear only when asked for. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun RepeatDialog(value: Repeat?, onPick: (Repeat?) -> Unit, onDismiss: () -> Unit) {
    var custom by rememberSaveable { mutableStateOf(value != null && value.presetName() == null) }
    var freq by rememberSaveable { mutableStateOf(value?.freq ?: Freq.WEEKLY) }
    var interval by rememberSaveable { mutableIntStateOf(value?.interval?.toInt() ?: 1) }
    // Plain integers: a saved state does not hold unsigned ones.
    var weekdays by rememberSaveable { mutableStateOf(value?.weekdays?.map { it.toInt() }?.toSet() ?: emptySet()) }
    var byWeekday by rememberSaveable { mutableStateOf(value?.nth != null) }
    var nth by rememberSaveable { mutableIntStateOf(value?.nth ?: 1) }
    var nthWeekday by rememberSaveable { mutableIntStateOf(value?.nthWeekday?.toInt() ?: 1) }
    var fromDone by rememberSaveable { mutableStateOf(value?.fromDone ?: false) }
    var count by rememberSaveable { mutableStateOf(value?.count?.toString().orEmpty()) }

    FormDialog(
        title = str(R.string.repeat),
        onDismiss = onDismiss,
        content = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                if (!custom) {
                    for ((name, rule) in repeatPresets) {
                        Text(
                            name,
                            fontWeight = if (value?.presetName() == name) FontWeight.Bold else null,
                            modifier = Modifier.fillMaxWidth().clickable { onPick(rule); onDismiss() }.padding(vertical = 12.dp),
                        )
                    }
                    Text(str(R.string.custom), Modifier.fillMaxWidth().clickable { custom = true }.padding(vertical = 12.dp))
                    if (value != null) {
                        Text(str(R.string.no_repeat), Modifier.fillMaxWidth().clickable { onPick(null); onDismiss() }.padding(vertical = 12.dp), color = MaterialTheme.colorScheme.error)
                    }
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(str(R.string.every))
                        IconButton(onClick = { if (interval > 1) interval-- }) { Text("−") }
                        Text("$interval")
                        IconButton(onClick = { if (interval < 999) interval++ }) { Text("+") }
                    }
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        for ((unit, label) in listOf(Freq.DAILY to str(R.string.unit_days), Freq.WEEKLY to str(R.string.unit_weeks), Freq.MONTHLY to str(R.string.unit_months), Freq.YEARLY to str(R.string.unit_years))) {
                            FilterChip(selected = freq == unit, onClick = { freq = unit }, label = { Text(label) })
                        }
                    }
                    if (freq == Freq.WEEKLY) {
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            weekdayNames.forEachIndexed { index, name ->
                                val day = index + 1
                                FilterChip(
                                    selected = day in weekdays,
                                    onClick = { weekdays = if (day in weekdays) weekdays - day else weekdays + day },
                                    label = { Text(name) },
                                )
                            }
                        }
                    }
                    if (freq == Freq.MONTHLY) {
                        SwitchRow(str(R.string.by_weekday_switch), byWeekday) { byWeekday = it }
                        if (byWeekday) {
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                for (n in listOf(1, 2, 3, 4, 5, -1)) {
                                    FilterChip(selected = nth == n, onClick = { nth = n }, label = { Text(if (n < 0) str(R.string.last) else ordinal(n)) })
                                }
                            }
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                weekdayNames.forEachIndexed { index, name ->
                                    FilterChip(selected = nthWeekday == index + 1, onClick = { nthWeekday = index + 1 }, label = { Text(name) })
                                }
                            }
                        }
                    }
                    SwitchRow(str(R.string.from_completion), fromDone) { fromDone = it }
                    OutlinedTextField(
                        value = count,
                        onValueChange = { count = it.filter(Char::isDigit).take(2) },
                        label = { Text(str(R.string.repeats_field)) },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.padding(top = 8.dp),
                    )
                }
            }
        },
        confirmButton = {
            if (custom) {
                TextButton(onClick = {
                    val monthlyByWeekday = freq == Freq.MONTHLY && byWeekday
                    onPick(
                        every(freq, interval.toUInt(), if (freq == Freq.WEEKLY) weekdays.sorted().map { it.toUInt() } else emptyList()).copy(
                            nth = if (monthlyByWeekday) nth else null,
                            nthWeekday = if (monthlyByWeekday) nthWeekday.toUInt() else null,
                            fromDone = fromDone,
                            count = count.toUIntOrNull()?.takeIf { it > 0u },
                            // The end date is set on the desktop; it is kept here, not edited.
                            until = value?.until,
                        ),
                    )
                    onDismiss()
                }) { Text(str(R.string.done)) }
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(str(R.string.cancel)) } },
    )
}

/**
 * A dialog with text fields; [content] scrolls itself.
 *
 * The padding keeps the dialog above the keyboard: without it the dialog keeps
 * its height, and its lower fields and buttons end up underneath.
 *
 * In a low window (a phone on its side) even that is not enough: the title, one
 * field and the buttons of a dialog are taller than what the keyboard leaves.
 * There the dialog takes the whole window, with the title and the buttons in
 * one row. The choice follows the window and not the keyboard, so the dialog
 * is not rebuilt, and the field does not lose the cursor, when the keyboard opens.
 */
@Composable
internal fun FormDialog(
    title: String,
    onDismiss: () -> Unit,
    confirmButton: @Composable () -> Unit,
    dismissButton: @Composable () -> Unit,
    /** Takes the whole window whatever its height: the settings, which are a screen and not a question (R101). */
    fullScreen: Boolean = false,
    /** Stands before the title of a dialog that takes the whole window. */
    navigation: (@Composable () -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    if (!fullScreen && LocalConfiguration.current.screenHeightDp >= LOW_WINDOW_DP) {
        AlertDialog(
            modifier = Modifier.windowInsetsPadding(WindowInsets.safeDrawing),
            onDismissRequest = onDismiss,
            title = { Text(title) },
            text = content,
            confirmButton = confirmButton,
            dismissButton = dismissButton,
        )
        return
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize()) {
            Column(Modifier.windowInsetsPadding(WindowInsets.safeDrawing)) {
                Row(Modifier.fillMaxWidth().padding(start = if (navigation != null) 8.dp else 24.dp, end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    navigation?.invoke()
                    Text(title, Modifier.weight(1f), style = MaterialTheme.typography.titleLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    dismissButton()
                    confirmButton()
                }
                // The colour and the size of the text of an AlertDialog.
                CompositionLocalProvider(LocalContentColor provides MaterialTheme.colorScheme.onSurfaceVariant) {
                    ProvideTextStyle(MaterialTheme.typography.bodyMedium) {
                        Box(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 24.dp)) { content() }
                    }
                }
            }
        }
    }
}

/** Below this height a window is low: the compact height class of Material. */
private const val LOW_WINDOW_DP = 480

@Composable
internal fun SwitchRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        Switch(checked, onChange)
    }
}

/** Name, colour, order and defaults of a list; also used to create one. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ListDialog(list: TaskList?, model: MainViewModel, onDismiss: () -> Unit) {
    val inbox = list?.id == "inbox"
    var name by remember { mutableStateOf(list?.name.orEmpty()) }
    var color by remember { mutableStateOf(list?.color.orEmpty()) }
    var sort by remember { mutableStateOf(list?.sort ?: SortMode.MANUAL) }
    var showDone by remember { mutableStateOf(list?.showDone ?: false) }
    var priority by remember { mutableStateOf(list?.defaultPriority ?: Priority.NONE) }
    var dueToday by remember { mutableStateOf(list?.defaultDueToday ?: false) }
    var archived by remember { mutableStateOf(list?.archived ?: false) }
    var confirmDelete by remember { mutableStateOf(false) }
    val sorts = listOf(SortMode.MANUAL to str(R.string.sort_manual), SortMode.DUE to str(R.string.sort_due), SortMode.PRIORITY to str(R.string.sort_priority), SortMode.TITLE to str(R.string.sort_title))

    FormDialog(
        title = if (list == null) str(R.string.new_list) else list.displayName(),
        onDismiss = onDismiss,
        content = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                if (!inbox) OutlinedTextField(name, { name = it }, singleLine = true, label = { Text(str(R.string.title)) }, keyboardOptions = SentenceKeyboard)
                Row(Modifier.padding(vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (hex in listColors) {
                        val shown = parseColor(hex) ?: MaterialTheme.colorScheme.primary
                        Box(
                            Modifier.size(24.dp).clip(CircleShape).background(shown)
                                .border(if (hex == color) 3.dp else 0.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = if (hex == color) 0.7f else 0f), CircleShape)
                                .clickable { color = hex },
                        )
                    }
                }
                Text(str(R.string.sorting), style = MaterialTheme.typography.labelLarge)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    for ((mode, label) in sorts) FilterChip(selected = sort == mode, onClick = { sort = mode }, label = { Text(label) })
                }
                SwitchRow(str(R.string.show_completed), showDone) { showDone = it }
                Text(str(R.string.new_tasks), style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(top = 8.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    for (p in priorities) FilterChip(selected = priority == p, onClick = { priority = p }, label = { Text(p.title()) })
                }
                SwitchRow(str(R.string.due_today), dueToday) { dueToday = it }
                if (list != null && !inbox) {
                    SwitchRow(str(R.string.archived_switch), archived) { archived = it }
                    TextButton(onClick = { confirmDelete = true }) {
                        Text(str(R.string.delete_list), color = MaterialTheme.colorScheme.error)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = inbox || name.isNotBlank(),
                onClick = {
                    onDismiss()
                    model.act { store ->
                        val id = list?.id ?: store.createList(name).id
                        if (list != null && !inbox && list.name != name) store.renameList(id, name)
                        if (list?.color != color) store.setListColor(id, color)
                        if (list?.sort != sort) store.setListSort(id, sort)
                        if (list?.showDone != showDone) store.setListShowDone(id, showDone)
                        if (list?.defaultPriority != priority || list.defaultDueToday != dueToday) store.setListDefaults(id, priority, dueToday)
                        if (list != null && !inbox && list.archived != archived) store.setListArchived(id, archived)
                    }
                },
            ) { Text(if (list == null) str(R.string.create) else str(R.string.done)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(str(R.string.cancel)) } },
    )
    // R136: a list goes only once the user agrees, since undo does not bring it back (R131).
    if (confirmDelete && list != null) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            text = { Text(str(R.string.delete_list_question, list.displayName())) },
            confirmButton = {
                TextButton(onClick = { confirmDelete = false; onDismiss(); model.deleteList(list.id) }) {
                    Text(str(R.string.delete), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(str(R.string.cancel)) } },
        )
    }
}

/** R127: a new project, its title only; the list is taken from the view. */
@Composable
fun ProjectDialog(onDismiss: () -> Unit, onCreate: (String) -> Unit) {
    var title by remember { mutableStateOf("") }
    FormDialog(
        title = str(R.string.new_project),
        onDismiss = onDismiss,
        content = {
            OutlinedTextField(title, { title = it }, singleLine = true, label = { Text(str(R.string.title)) }, keyboardOptions = SentenceKeyboard)
        },
        confirmButton = {
            TextButton(enabled = title.isNotBlank(), onClick = { onDismiss(); onCreate(title) }) { Text(str(R.string.create)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(str(R.string.cancel)) } },
    )
}

/** The activity a composable is shown in, when there is one. */
private tailrec fun Context.activity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.activity()
    else -> null
}

/** What the settings open with (#320). */
private class SettingsStart(val sync: SyncConfig?, val pushServer: String, val logLevel: LogLevel, val logFiles: List<String>)

@Composable
fun SettingsDialog(model: MainViewModel, onNotifications: () -> Unit, onDismiss: () -> Unit) {
    // #320: what the settings start from, read off the main thread; they open when it has come.
    val start = fromStore { store ->
        SettingsStart(
            runCatching { store.syncConfig() }.getOrNull(), runCatching { store.pushSendServer() }.getOrNull().orEmpty(),
            runCatching { store.logLevel() }.getOrDefault(LogLevel.ERROR), runCatching { store.logFiles() }.getOrDefault(emptyList()),
        )
    } ?: return
    val state by model.state.collectAsStateWithLifecycle()
    val syncing by Repo.syncing.collectAsStateWithLifecycle()
    val saved = start.sync
    // "off", "webdav" or "caldav"; a folder cannot be chosen on Android.
    var kind by remember { mutableStateOf(if (saved is SyncConfig.WebDav) "webdav" else if (saved is SyncConfig.CalDav) "caldav" else "off") }
    val enabled = kind != "off"
    var url by remember { mutableStateOf((saved as? SyncConfig.WebDav)?.url ?: (saved as? SyncConfig.CalDav)?.url ?: "") }
    var user by remember { mutableStateOf((saved as? SyncConfig.WebDav)?.user ?: (saved as? SyncConfig.CalDav)?.user ?: "") }
    val context = LocalContext.current
    var password by remember { mutableStateOf(if (enabled) Secrets.load(context).orEmpty() else "") }
    var passphrase by remember { mutableStateOf(if (saved is SyncConfig.WebDav) Secrets.load(context, Secrets.PASSPHRASE).orEmpty() else "") }
    // R145: the storage that is saved, which encrypting acts on; the window that sets a passphrase (true: encrypt,
    // false: change) and the one of the two under way.
    var stored by remember { mutableStateOf(saved) }
    var sealing by remember { mutableStateOf<Boolean?>(null) }
    var sealingBusy by remember { mutableStateOf<Boolean?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    // What the last connection test found and whether that was a failure; shown under its button.
    var tested by remember { mutableStateOf<String?>(null) }
    var testFailed by remember { mutableStateOf(false) }
    var testing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    var push by remember { mutableStateOf(Push.enabled(context)) }
    // S29: receiving is the distributor's; these two serve sending to a server that requires sign-in.
    var pushServer by remember { mutableStateOf(start.pushServer) }
    var pushToken by remember { mutableStateOf(if (enabled) Secrets.load(context, Secrets.PUSH_TOKEN).orEmpty() else "") }
    // Off until a server is set: a public ntfy server needs neither field.
    var pushSignIn by remember { mutableStateOf(pushServer.isNotEmpty()) }
    var pushRefused by remember { mutableStateOf(false) }
    // S30: nudges go out with sync runs, so the answer comes later than the save.
    LaunchedEffect(Unit) {
        while (true) {
            pushRefused = withContext(Dispatchers.IO) { runCatching { Repo.store.pushRefused() }.getOrDefault(false) }
            delay(2000)
        }
    }
    var notifyOn by remember { mutableStateOf(NotifyPrefs.enabled(context)) }
    var todayNotice by remember { mutableStateOf(TodayNotice.enabled(context)) }
    var iconCount by remember { mutableStateOf(IconCount.choice(context)) }
    val iconCountLabels = listOf(str(R.string.today), str(R.string.icon_count_overdue_choice), str(R.string.icon_count_none))
    // R66: asked again on the way back from the system screen where the leave is given.
    var exactAlarms by remember { mutableStateOf(Reminders.exact(context)) }
    var asAlarmClock by remember { mutableStateOf(NotifyPrefs.asAlarmClock(context)) }
    // S31: the same on the way back from the system dialog about the battery.
    var unrestricted by remember { mutableStateOf(Background.unrestricted(context)) }
    // R78: the same on the way back from the system screen of the calendar permission.
    var eventsOn by remember { mutableStateOf(EventPrefs.enabled(context)) }
    var calendarGranted by remember { mutableStateOf(SystemCalendars.granted(context)) }
    var hiddenCalendars by remember { mutableStateOf(EventPrefs.hidden(context)) }
    val askCalendar = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        calendarGranted = granted
        scope.launch { SystemCalendars.refresh(context) }
    }
    val calendars = remember(eventsOn, calendarGranted) { if (eventsOn) SystemCalendars.calendars(context) else emptyList() }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        exactAlarms = Reminders.exact(context)
        unrestricted = Background.unrestricted(context)
        calendarGranted = SystemCalendars.granted(context)
    }
    var leads by remember { mutableStateOf(NotifyPrefs.leads(context)) }
    val newTaskList = state.newTaskList
    var parse by remember { mutableStateOf(EntryPrefs.parse(context)) }
    var clipboard by remember { mutableStateOf(EntryPrefs.clipboard(context)) }
    val lookLabels = listOf(str(R.string.appearance_system), str(R.string.appearance_light), str(R.string.appearance_dark))
    val sizeLabels = listOf(
        str(R.string.text_size_small), str(R.string.text_size_default), str(R.string.text_size_large),
        str(R.string.text_size_larger), str(R.string.text_size_largest),
    )
    val spacingLabels = listOf(str(R.string.row_spacing_compact), str(R.string.row_spacing_normal), str(R.string.row_spacing_relaxed))
    var allDay by remember { mutableStateOf(NotifyPrefs.allDay(context)) }
    var summary by remember { mutableStateOf(NotifyPrefs.summary(context)) }
    var choosing by remember { mutableStateOf<String?>(null) }
    val logLevels = listOf(LogLevel.OFF, LogLevel.ERROR, LogLevel.INFO, LogLevel.DEBUG)
    val logLabels = listOf(str(R.string.log_off), str(R.string.log_errors), str(R.string.log_events), str(R.string.log_detailed))
    var logLevel by remember { mutableStateOf(start.logLevel) }
    var logFiles by remember { mutableStateOf(start.logFiles) }
    // R101: the section on screen, none for the list of sections. Saved: a new text size rebuilds the activity (R100).
    var section by rememberSaveable { mutableStateOf<String?>(null) }
    val sections = listOf(
        "general" to str(R.string.settings_general), "tasks" to str(R.string.settings_tasks),
        "notifications" to str(R.string.notifications), "sync" to str(R.string.sync), "backups" to str(R.string.backups),
    )
    fun saveNotify() {
        NotifyPrefs.save(context, notifyOn, leads, allDay, summary)
        if (notifyOn) onNotifications()
        Repo.changed()
    }
    fun leadLabel(minutes: Int) = when {
        minutes == 0 -> str(R.string.at_due_time)
        minutes < 60 -> str(R.string.min_before, minutes.toString())
        minutes == 1440 -> str(R.string.day_before)
        else -> str(R.string.h_before, (minutes / 60).toString())
    }
    fun timeLabel(time: String) = if (time.isEmpty()) str(R.string.sync_off) else str(R.string.at_time, time)
    val pickImport = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            onDismiss()
            model.importFrom(context, uri)
        }
    }

    // S36: the storage being joined while the person chooses a side, and the side that waits for a confirmation.
    var joining by remember { mutableStateOf<SyncConfig?>(null) }
    var replacing by remember { mutableStateOf<SyncSide?>(null) }

    fun save(config: SyncConfig, side: SyncSide) {
        testing = true
        scope.launch {
            val sender = enabled && pushSignIn && pushServer.isNotEmpty()
            // S53: the model carries it to the end when the settings are closed meanwhile.
            val joined = model.joinStorage(
                config,
                side,
                SyncSecrets(password.takeIf { enabled }, pushServer.takeIf { sender }, pushToken.takeIf { sender }, passphrase.takeIf { kind == "webdav" }),
            )
            testing = false
            joined
                .onSuccess {
                    stored = config
                    error = null
                    tested = null
                    pushRefused = false
                    if (enabled) Background.askOnce(context)
                }
                .onFailure { error = describe(it) }
        }
    }

    FormDialog(
        title = sections.firstOrNull { it.first == section }?.second ?: str(R.string.settings),
        // "Back" in a section leads to the list of sections, in the list it closes the settings.
        onDismiss = { if (section != null) section = null else onDismiss() },
        fullScreen = true,
        navigation = if (section == null) null else {
            { IconButton(onClick = { section = null }) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, str(R.string.back)) } }
        },
        content = {
            // R101: a list of sections, each opened on its own. Scrolling starts anew in each.
            key(section) {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    when (section) {
                        null -> {
                            for ((id, title) in sections) {
                                SettingRow(title, "") { if (id == "backups") choosing = "backups" else section = id }
                            }
                            HorizontalDivider(Modifier.padding(vertical = 8.dp))
                            SettingRow(str(R.string.import_file), "") { pickImport.launch(arrayOf("*/*")) }
                        }
                        "general" -> {
                            SettingRow(str(R.string.appearance), lookLabels[LookPrefs.choices.indexOf(LookPrefs.appearance(context))]) { choosing = "appearance" }
                            SettingRow(str(R.string.text_size), sizeLabels[LookPrefs.textScales.indexOf(LookPrefs.textScale(context))]) { choosing = "textSize" }
                            SettingRow(str(R.string.row_spacing), spacingLabels[LookPrefs.rowSpacings.indexOf(LookPrefs.rowSpacing(context))]) { choosing = "rowSpacing" }
                            SettingRow(str(R.string.completed_leave), keepDoneLabel(state.keepDone)) { choosing = "keepDone" }
                            // R121: one switch for all devices; turning it off asks where the tasks of Inbox go.
                            SwitchRow(str(R.string.show_inbox), !state.inboxHidden) { on ->
                                choosing = when {
                                    on -> { model.act { store -> store.showInbox() }; null }
                                    state.listsForHiddenInbox.isEmpty() -> "noListForInbox"
                                    else -> "hideInbox"
                                }
                            }
                            HorizontalDivider(Modifier.padding(vertical = 8.dp))
                            // R102: the level of the log and the way to its files.
                            Text(str(R.string.log), style = MaterialTheme.typography.labelLarge)
                            SettingRow(str(R.string.log_level), logLabels[logLevels.indexOf(logLevel)]) { choosing = "logLevel" }
                            if (logFiles.isNotEmpty()) {
                                SettingRow(str(R.string.share_log), "") { shareLog(context, logFiles) }
                                SettingRow(str(R.string.clear_log), "") {
                                    scope.launch {
                                        logFiles = withContext(Dispatchers.IO) {
                                            runCatching { Repo.store.clearLog() }
                                            runCatching { Repo.store.logFiles() }.getOrDefault(emptyList())
                                        }
                                    }
                                }
                            }
                            Text(str(R.string.log_hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        "tasks" -> {
                            Text(str(R.string.new_tasks_setting), style = MaterialTheme.typography.labelLarge)
                            val listChoices = state.lists.filter { !it.archived && it.id != "inbox" }
                            SettingRow(
                                str(R.string.default_list),
                                when (newTaskList) {
                                    "inbox" -> str(R.string.inbox)
                                    "last" -> str(R.string.last_used_list)
                                    else -> listChoices.firstOrNull { it.id == newTaskList }?.name ?: str(R.string.inbox)
                                },
                            ) { choosing = "newTaskList" }
                            SwitchRow(str(R.string.parse_title), parse) { parse = it; EntryPrefs.setParse(context, it) }
                            SwitchRow(str(R.string.clipboard_note), clipboard) { clipboard = it; EntryPrefs.setClipboard(context, it) }
                            HorizontalDivider(Modifier.padding(vertical = 8.dp))
                            Text(str(R.string.calendar_events), style = MaterialTheme.typography.labelLarge)
                            SwitchRow(str(R.string.show_calendar_events), eventsOn) {
                                eventsOn = it
                                EventPrefs.setEnabled(context, it)
                                // R78: the permission is asked when the setting is turned on, not before.
                                if (it && !calendarGranted) askCalendar.launch(android.Manifest.permission.READ_CALENDAR)
                                scope.launch { SystemCalendars.refresh(context) }
                            }
                            if (eventsOn && !calendarGranted) {
                                // After a refusal the system shows its dialog no more: the way is through its settings.
                                SettingRow(str(R.string.calendar_no_access), str(R.string.allow)) {
                                    context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
                                }
                            }
                            // R78: the system gives all the calendars at once, the choice among them is made here.
                            for (calendar in calendars) {
                                val shown = calendar.id !in hiddenCalendars
                                Row(
                                    Modifier.fillMaxWidth().toggleable(shown, role = Role.Checkbox) { show ->
                                        hiddenCalendars = if (show) hiddenCalendars - calendar.id else hiddenCalendars + calendar.id
                                        EventPrefs.setHidden(context, hiddenCalendars)
                                        scope.launch { SystemCalendars.refresh(context) }
                                    },
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Box(Modifier.size(10.dp).background(Color(calendar.color), CircleShape))
                                    Column(Modifier.weight(1f).padding(start = 10.dp)) {
                                        Text(calendar.name)
                                        if (calendar.account.isNotEmpty() && calendar.account != calendar.name) {
                                            Text(calendar.account, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                        }
                                    }
                                    Checkbox(checked = shown, onCheckedChange = null, modifier = Modifier.padding(12.dp))
                                }
                            }
                            Text(str(R.string.calendar_events_hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        "notifications" -> {
                            SwitchRow(str(R.string.show_notifications), notifyOn) { notifyOn = it; saveNotify() }
                            if (notifyOn) {
                                SettingRow(
                                    str(R.string.due_at_time_setting),
                                    if (leads.isEmpty()) str(R.string.sync_off) else leads.joinToString(", ") { leadLabel(it) },
                                ) { choosing = "lead" }
                                SettingRow(str(R.string.due_on_day_setting), timeLabel(allDay)) { choosing = "allDay" }
                                SettingRow(str(R.string.summary_setting), timeLabel(summary)) { choosing = "summary" }
                                SettingRow(str(R.string.notification_sound), str(R.string.choose)) {
                                    context.startActivity(Reminders.channelSettings(context))
                                }
                                // R119: the alarms are set anew at once, the other way.
                                SwitchRow(str(R.string.as_alarm_clock), asAlarmClock) {
                                    asAlarmClock = it
                                    NotifyPrefs.setAsAlarmClock(context, it)
                                    Repo.scope.launch { Reminders.refresh(context.applicationContext) }
                                }
                                Text(str(R.string.as_alarm_clock_hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                if (!exactAlarms && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
                                    SettingRow(str(R.string.exact_alarms), str(R.string.allow)) {
                                        context.startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:${context.packageName}")))
                                    }
                                    Text(str(R.string.exact_alarms_hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                            // R104: apart from the reminders, and so not under their switch.
                            SwitchRow(str(R.string.today_notice_setting), todayNotice) {
                                todayNotice = it
                                TodayNotice.setEnabled(context, it)
                                if (it) onNotifications()
                            }
                            Text(str(R.string.today_notice_hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            // R106: like R104, not under the switch of the reminders. The number is carried by the notification above.
                            SettingRow(str(R.string.icon_count), iconCountLabels[IconCount.choices.indexOf(iconCount)]) { choosing = "iconCount" }
                            Text(str(if (todayNotice || iconCount == "none") R.string.icon_count_hint else R.string.icon_count_needs_notice), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        "sync" -> {
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                for ((value, label) in listOf("off" to str(R.string.sync_off), "webdav" to "WebDAV", "caldav" to "CalDAV")) {
                                    FilterChip(selected = kind == value, onClick = { kind = value }, label = { Text(label) })
                                }
                            }
                            if (enabled) {
                                OutlinedTextField(url, { url = it.trim() }, singleLine = true, label = { Text(str(R.string.address)) }, placeholder = { Text("https://…/dav/files/me") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false))
                                OutlinedTextField(user, { user = it }, singleLine = true, label = { Text(str(R.string.user)) }, keyboardOptions = KeyboardOptions(autoCorrectEnabled = false))
                                OutlinedTextField(password, { password = it }, singleLine = true, label = { Text(str(R.string.password)) }, visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false))
                                Text(
                                    str(if (kind == "caldav") R.string.caldav_hint else R.string.webdav_hint),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(top = 8.dp),
                                )
                                if (kind == "webdav") {
                                    OutlinedTextField(passphrase, { passphrase = it }, singleLine = true, label = { Text(str(R.string.storage_passphrase)) }, visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false))
                                    Text(str(R.string.storage_passphrase_hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 8.dp))
                                }
                                // R145: the storage that is saved, not the one being typed, is encrypted.
                                if (stored is SyncConfig.WebDav) {
                                    TextButton(enabled = sealingBusy == null, onClick = { sealing = !state.sync.encrypted }) {
                                        Text(str(if (state.sync.encrypted) R.string.change_passphrase else R.string.encrypt_storage))
                                    }
                                    sealingBusy?.let { encrypting ->
                                        Text(str(if (encrypting) R.string.encrypting_storage else R.string.changing_passphrase), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    }
                                }
                                // Asks the server with what the fields hold now; nothing is saved (S26).
                                TextButton(enabled = !testing, onClick = {
                                    val config = if (kind == "caldav") SyncConfig.CalDav(url, user) else SyncConfig.WebDav(url, user)
                                    val secret = password
                                    tested = null
                                    testing = true
                                    scope.launch {
                                        val result = withContext(Dispatchers.IO) { runCatching { checkSyncConnection(config, secret) } }
                                        testing = false
                                        testFailed = result.isFailure
                                        tested = result.fold(
                                            { str(if (it == ConnectionCheck.WILL_CREATE) R.string.connected_will_create else R.string.connected) },
                                            { str(R.string.no_connection, describe(it)) },
                                        )
                                    }
                                }) { Text(str(R.string.test_connection)) }
                                (if (testing) str(R.string.testing_connection) else tested)?.let {
                                    Text(it, style = MaterialTheme.typography.bodySmall, color = if (testFailed && !testing) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                                val noDistributor = str(R.string.push_no_distributor)
                                SwitchRow(str(R.string.push_switch), push) { on ->
                                    val activity = context.activity()
                                    if (!on) {
                                        Push.disable(context)
                                        push = false
                                    } else if (activity != null) {
                                        Push.enable(activity) { found ->
                                            push = found
                                            if (found) Background.askOnce(activity)
                                            error = if (found) null else noDistributor
                                        }
                                    }
                                }
                                Text(str(R.string.push_hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                SwitchRow(str(R.string.push_sign_in), pushSignIn) { pushSignIn = it }
                                if (pushSignIn) {
                                    OutlinedTextField(pushServer, { pushServer = it.trim() }, singleLine = true, label = { Text(str(R.string.push_server)) }, placeholder = { Text("https://ntfy.example.org") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false))
                                    OutlinedTextField(pushToken, { pushToken = it.trim() }, singleLine = true, label = { Text(str(R.string.push_token)) }, placeholder = { Text("tk_…") }, visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false))
                                    Text(str(R.string.push_token_hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 8.dp))
                                    if (pushRefused) {
                                        Text(str(R.string.push_refused), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                                    }
                                }
                                SettingRow(str(R.string.background_work), str(if (unrestricted) R.string.background_unrestricted else R.string.background_restricted)) { Background.open(context) }
                                Text(str(R.string.background_hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            } else {
                                Text(str(R.string.local_only), color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            val waiting = state.sync.attachmentsWaiting.takeIf { it > 0u }?.let { str(R.string.attachments_waiting, it.toString()) }
                            val status = error
                                ?: state.sync.lastError?.let { str(R.string.last_sync_failed, it) }
                                ?: listOfNotNull(state.sync.lastOk?.let { str(R.string.synced_at, dateLabel(it).lowercase()) }, waiting).joinToString("\n").ifEmpty { null }
                            if (syncing) Text(str(R.string.syncing), Modifier.padding(top = 8.dp), style = MaterialTheme.typography.bodySmall)
                            else if (status != null) Text(status, Modifier.padding(top = 8.dp), style = MaterialTheme.typography.bodySmall, color = if (error != null || state.sync.lastError != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        },
        confirmButton = {
            if (section == "sync") TextButton(onClick = {
                val config = when (kind) {
                    "webdav" -> SyncConfig.WebDav(url, user)
                    "caldav" -> SyncConfig.CalDav(url, user)
                    else -> SyncConfig.Off
                }
                val secret = password
                error = null
                testing = true
                scope.launch {
                    // S36: a storage that is new to this device may hold data of its own.
                    val same = config == SyncConfig.Off ||
                        withContext(Dispatchers.IO) { runCatching { Repo.store.syncConfig() }.getOrNull() } == config
                    if (same) return@launch save(config, SyncSide.MERGE)
                    val both = withContext(Dispatchers.IO) { runCatching { Repo.store.syncConflict(config, secret) } }
                    testing = false
                    both.fold(
                        { if (it) joining = config else save(config, SyncSide.MERGE) },
                        { error = str(R.string.no_connection, describe(it)) },
                    )
                }
            }, enabled = !testing) { Text(str(R.string.save_and_sync)) }
        },
        dismissButton = {
            if (section == null) TextButton(onClick = onDismiss) { Text(str(R.string.close)) }
        },
    )
    sealing?.let { encrypt ->
        PassphraseDialog(encrypt, onDismiss = { sealing = null }) { chosen ->
            sealing = null
            sealingBusy = encrypt
            error = null
            scope.launch {
                model.sealStorage(encrypt, chosen)
                    .onSuccess { passphrase = chosen }
                    .onFailure { error = describe(it) }
                sealingBusy = null
            }
        }
    }
    joining?.let { config ->
        when (val side = replacing) {
            null -> AlertDialog(
                onDismissRequest = { joining = null },
                title = { Text(str(R.string.sync_both_title)) },
                text = {
                    Column {
                        Text(str(R.string.sync_both_hint), style = MaterialTheme.typography.bodyMedium)
                        @Composable
                        fun option(label: String, action: () -> Unit) =
                            Text(label, Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = action).padding(vertical = 12.dp))
                        option(str(R.string.sync_merge)) { joining = null; save(config, SyncSide.MERGE) }
                        option(str(R.string.sync_take_storage)) { replacing = SyncSide.STORAGE }
                        option(str(R.string.sync_send_device)) { replacing = SyncSide.DEVICE }
                    }
                },
                confirmButton = {},
                dismissButton = { TextButton(onClick = { joining = null }) { Text(str(R.string.cancel)) } },
            )
            else -> AlertDialog(
                onDismissRequest = { joining = null; replacing = null },
                title = { Text(str(if (side == SyncSide.STORAGE) R.string.sync_replace_device_title else R.string.sync_replace_storage_title)) },
                text = { Text(str(if (side == SyncSide.STORAGE) R.string.sync_replace_device_text else R.string.sync_replace_storage_text)) },
                confirmButton = {
                    TextButton(onClick = { joining = null; replacing = null; save(config, side) }) {
                        Text(str(R.string.sync_replace), color = MaterialTheme.colorScheme.error)
                    }
                },
                dismissButton = { TextButton(onClick = { joining = null; replacing = null }) { Text(str(R.string.cancel)) } },
            )
        }
    }
    when (choosing) {
        "backups" -> BackupsDialog(model) { choosing = null }
        "appearance" -> ChoiceDialog(str(R.string.appearance), lookLabels, LookPrefs.choices.indexOf(LookPrefs.appearance(context)), { choosing = null }) {
            LookPrefs.setAppearance(context, LookPrefs.choices[it])
        }
        "textSize" -> ChoiceDialog(str(R.string.text_size), sizeLabels, LookPrefs.textScales.indexOf(LookPrefs.textScale(context)), { choosing = null }) {
            LookPrefs.setTextScale(context, LookPrefs.textScales[it])
            // The size is part of the configuration of the activity: it is rebuilt, and the settings stay open.
            (context as? Activity)?.recreate()
        }
        "rowSpacing" -> ChoiceDialog(str(R.string.row_spacing), spacingLabels, LookPrefs.rowSpacings.indexOf(LookPrefs.rowSpacing(context)), { choosing = null }) {
            LookPrefs.setRowSpacing(context, LookPrefs.rowSpacings[it])
        }
        "lead" -> MultiChoiceDialog(str(R.string.due_at_time_setting), NotifyPrefs.leads.map(::leadLabel), NotifyPrefs.leads.map { it in leads }, { choosing = null }) { index, on ->
            leads = if (on) (leads + NotifyPrefs.leads[index]).distinct().sorted() else leads - NotifyPrefs.leads[index]
            saveNotify()
        }
        "iconCount" -> ChoiceDialog(str(R.string.icon_count), iconCountLabels, IconCount.choices.indexOf(iconCount), { choosing = null }) {
            iconCount = IconCount.choices[it]
            IconCount.setChoice(context, iconCount)
            if (iconCount != "none") onNotifications()
        }
        "logLevel" -> ChoiceDialog(str(R.string.log_level), logLabels, logLevels.indexOf(logLevel), { choosing = null }) {
            logLevel = logLevels[it]
            val level = logLevel
            scope.launch {
                logFiles = withContext(Dispatchers.IO) {
                    runCatching { Repo.store.setLogLevel(level) }
                    runCatching { Repo.store.logFiles() }.getOrDefault(emptyList())
                }
            }
        }
        "keepDone" -> {
            // What R68 offers, and the value in force when another device set something else.
            val values = keepDoneChoices(state.keepDone)
            ChoiceDialog(str(R.string.completed_leave), values.map(::keepDoneLabel), values.indexOf(state.keepDone), { choosing = null }) {
                model.act { store -> store.setKeepDone(values[it]) }
            }
        }
        "newTaskList" -> {
            val lists = state.lists.filter { !it.archived && it.id != "inbox" }
            // R121: hidden, Inbox is not offered; a choice made before stays readable.
            val inbox = if (!state.inboxHidden || newTaskList == "inbox") listOf("inbox") else emptyList()
            val values = inbox + "last" + lists.map { it.id }
            val labels = inbox.map { str(R.string.inbox) } + str(R.string.last_used_list) + lists.map { it.name }
            ChoiceDialog(str(R.string.default_list), labels, values.indexOf(newTaskList), { choosing = null }) {
                model.act { store -> store.setNewTaskList(values[it]) }
            }
        }
        // The notice that takes hiding back is shown on the main screen: settings close for it.
        "hideInbox" -> HideInboxDialog(state, onDismiss = { choosing = null }) { listId, move ->
            model.hideInbox(listId, move)
            onDismiss()
        }
        "noListForInbox" -> AlertDialog(
            onDismissRequest = { choosing = null },
            text = { Text(str(R.string.inbox_needs_list)) },
            confirmButton = { TextButton(onClick = { choosing = null }) { Text(str(R.string.ok)) } },
        )
        "allDay" -> ChoiceDialog(str(R.string.due_on_day_setting), (listOf("") + NotifyPrefs.times).map(::timeLabel), (listOf("") + NotifyPrefs.times).indexOf(allDay), { choosing = null }) { allDay = (listOf("") + NotifyPrefs.times)[it]; saveNotify() }
        "summary" -> ChoiceDialog(str(R.string.summary_setting), (listOf("") + NotifyPrefs.times).map(::timeLabel), (listOf("") + NotifyPrefs.times).indexOf(summary), { choosing = null }) { summary = (listOf("") + NotifyPrefs.times)[it]; saveNotify() }
    }
}

/** R121: where the open tasks of Inbox go when it is hidden, and the list new tasks start from. */
@Composable
private fun HideInboxDialog(state: UiState, onDismiss: () -> Unit, onHide: (String, Boolean) -> Unit) {
    val lists = state.listsForHiddenInbox
    var listId by remember { mutableStateOf(lists.firstOrNull()?.id ?: "") }
    val open = state.counts.inbox.toInt()
    val hide = { move: Boolean -> if (listId.isNotEmpty()) onHide(listId, move); onDismiss() }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(str(R.string.hide_inbox_question)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                if (open > 0) Text(str(R.string.inbox_open_tasks, open))
                lists.forEach { list ->
                    Text(
                        list.name,
                        fontWeight = if (list.id == listId) FontWeight.Bold else null,
                        modifier = Modifier.fillMaxWidth().clickable { listId = list.id }.padding(vertical = 12.dp),
                    )
                }
                Text(str(R.string.hide_inbox_hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        confirmButton = {
            TextButton(onClick = { hide(open > 0) }) { Text(str(if (open > 0) R.string.move_and_hide else R.string.hide)) }
        },
        dismissButton = {
            Row {
                TextButton(onClick = onDismiss) { Text(str(R.string.cancel)) }
                if (open > 0) TextButton(onClick = { hide(false) }) { Text(str(R.string.hide_without_moving)) }
            }
        },
    )
}

internal fun keepDoneChoices(current: KeepDone): List<KeepDone> {
    val seconds = (listOf(0u, 5u, 15u) + listOfNotNull((current as? KeepDone.Seconds)?.seconds)).distinct().sorted()
    return seconds.map { KeepDone.Seconds(it) } + KeepDone.EndOfDay
}

/** A whole number of minutes is what an earlier version offered. */
private fun keepDoneLabel(keep: KeepDone): String = when (keep) {
    KeepDone.EndOfDay -> str(R.string.leave_at_end_of_day)
    is KeepDone.Seconds -> when {
        keep.seconds == 0u -> str(R.string.leave_at_once)
        keep.seconds == 3600u -> str(R.string.leave_after_hour)
        keep.seconds % 60u == 0u -> str(R.string.leave_after_minutes, (keep.seconds / 60u).toInt())
        else -> str(R.string.leave_after_seconds, keep.seconds.toInt())
    }
}

@Composable
internal fun SettingRow(label: String, value: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        Text(value, color = MaterialTheme.colorScheme.primary)
    }
}

/** A saved view: which dates, lists, tags, priority and status it lets through. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun FilterDialog(filter: SavedFilter?, state: UiState, model: MainViewModel, onDismiss: () -> Unit) {
    val old = filter?.spec
    var name by remember { mutableStateOf(filter?.name.orEmpty()) }
    // "any", "overdue", "today", "next", "none"
    var window by remember {
        mutableStateOf(
            when (old?.due) {
                is DueWindow.Overdue -> "overdue"
                is DueWindow.Today -> "today"
                is DueWindow.Next -> "next"
                is DueWindow.NoDate -> "none"
                else -> "any"
            },
        )
    }
    var days by remember { mutableStateOf(((old?.due as? DueWindow.Next)?.days ?: 7u).toString()) }
    var lists by remember { mutableStateOf(old?.listIds?.toSet() ?: emptySet()) }
    var tags by remember { mutableStateOf(old?.tags?.joinToString(" ").orEmpty()) }
    var priority by remember { mutableStateOf(old?.minPriority ?: Priority.NONE) }
    var status by remember { mutableStateOf(old?.status ?: FilterStatus.OPEN) }
    var text by remember { mutableStateOf(old?.text.orEmpty()) }

    val spec = FilterSpec(
        due = when (window) {
            "overdue" -> DueWindow.Overdue
            "today" -> DueWindow.Today
            "next" -> DueWindow.Next((days.toUIntOrNull() ?: 7u).coerceIn(1u, 365u))
            "none" -> DueWindow.NoDate
            else -> DueWindow.Any
        },
        listIds = lists.sorted(),
        tags = tags.split(' ', ',').filter { it.isNotBlank() },
        minPriority = priority,
        status = status,
        text = text,
    )
    val matching = fromStore(spec) { it.previewFilter(spec).size } ?: 0

    FormDialog(
        title = filter?.name ?: str(R.string.new_filter),
        onDismiss = onDismiss,
        content = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                OutlinedTextField(name, { name = it }, singleLine = true, label = { Text(str(R.string.title)) }, keyboardOptions = SentenceKeyboard)
                if (filter == null) {
                    FlowRow(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        AssistChip(onClick = { name = str(R.string.next_7_days); window = "next"; days = "7" }, label = { Text(str(R.string.next_7_days)) })
                        AssistChip(onClick = { name = str(R.string.overdue); window = "overdue" }, label = { Text(str(R.string.overdue)) })
                        AssistChip(onClick = { name = str(R.string.high_priority); window = "any"; priority = Priority.HIGH }, label = { Text(str(R.string.high_priority)) })
                        AssistChip(onClick = { name = str(R.string.no_date); window = "none" }, label = { Text(str(R.string.no_date)) })
                    }
                }
                Text(str(R.string.date), style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(top = 12.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    for ((value, label) in listOf("any" to R.string.any, "overdue" to R.string.overdue, "today" to R.string.today, "next" to R.string.coming_days, "none" to R.string.no_date)) {
                        FilterChip(selected = window == value, onClick = { window = value }, label = { Text(str(label)) })
                    }
                }
                if (window == "next") {
                    OutlinedTextField(days, { days = it.filter(Char::isDigit).take(3) }, singleLine = true, label = { Text(str(R.string.days)) }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                }
                Text(str(R.string.lists), style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(top = 12.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    for (list in state.lists.filter { !it.archived }) {
                        FilterChip(selected = list.id in lists, onClick = { lists = if (list.id in lists) lists - list.id else lists + list.id }, label = { Text(list.displayName()) })
                    }
                }
                OutlinedTextField(tags, { tags = it }, singleLine = true, label = { Text(str(R.string.tags)) }, modifier = Modifier.padding(top = 8.dp))
                Text(str(R.string.priority_at_least), style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(top = 12.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    for (p in priorities) FilterChip(selected = priority == p, onClick = { priority = p }, label = { Text(if (p == Priority.NONE) str(R.string.any) else p.title()) })
                }
                Text(str(R.string.status), style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(top = 12.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    for ((value, label) in listOf(FilterStatus.OPEN to R.string.status_open, FilterStatus.DONE to R.string.completed, FilterStatus.WONT to R.string.wont_do, FilterStatus.ALL to R.string.all)) {
                        FilterChip(selected = status == value, onClick = { status = value }, label = { Text(str(label)) })
                    }
                }
                OutlinedTextField(text, { text = it }, singleLine = true, label = { Text(str(R.string.contains)) }, modifier = Modifier.padding(top = 8.dp))
                Text(str(R.string.matching_now, matching), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 8.dp))
                if (filter != null) {
                    TextButton(onClick = { onDismiss(); model.act { it.deleteFilter(filter.id) } }) {
                        Text(str(R.string.delete_filter), color = MaterialTheme.colorScheme.error)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(enabled = name.isNotBlank(), onClick = {
                onDismiss()
                model.act { store -> if (filter == null) store.createFilter(name, spec) else store.updateFilter(filter.id, name, spec) }
            }) { Text(str(if (filter == null) R.string.create else R.string.done)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(str(R.string.cancel)) } },
    )
}

/** R145: a new passphrase, typed twice, with the warning that a forgotten one loses the storage. */
@Composable
private fun PassphraseDialog(encrypt: Boolean, onDismiss: () -> Unit, onConfirm: (String) -> Unit) {
    var first by remember { mutableStateOf("") }
    var second by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(str(if (encrypt) R.string.encrypt_storage_title else R.string.change_passphrase_title)) },
        text = {
            Column {
                Text(str(if (encrypt) R.string.encrypt_storage_text else R.string.change_passphrase_text), style = MaterialTheme.typography.bodyMedium)
                OutlinedTextField(first, { first = it }, singleLine = true, label = { Text(str(R.string.passphrase)) }, visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false))
                OutlinedTextField(second, { second = it }, singleLine = true, label = { Text(str(R.string.passphrase_again)) }, visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false))
                Text(str(R.string.passphrase_warning), Modifier.padding(top = 8.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
            }
        },
        confirmButton = {
            TextButton(enabled = first.isNotEmpty() && first == second, onClick = { onConfirm(first) }) {
                Text(str(if (encrypt) R.string.encrypt else R.string.change))
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(str(R.string.cancel)) } },
    )
}
