package org.evsyukov.lists.ui

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AssistChip
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.evsyukov.lists.R
import org.evsyukov.lists.dateLabel
import org.evsyukov.lists.displayName
import org.evsyukov.lists.priorities
import org.evsyukov.lists.str
import org.evsyukov.lists.summary
import org.evsyukov.lists.title
import uniffi.lists_core.NewTask
import uniffi.lists_core.Priority
import uniffi.lists_core.Repeat
import uniffi.lists_core.Store
import uniffi.lists_core.TaskItem
import uniffi.lists_core.TaskList

/** What the new-task card collected. */
data class TaskDraft(
    val title: String,
    val notes: String,
    val start: String?,
    val due: String?,
    val repeat: Repeat?,
    val priority: Priority,
    /** Null where the place the task goes to decides the list, as under a project. */
    val listId: String?,
    /** Whether dates, priority, tags and a list are picked out of the title. */
    val parse: Boolean,
    val files: List<Uri>,
)

/**
 * Creates the task a draft describes, as a subtask when a parent is given.
 * What the fields say wins over what the title says; `dueIfNone` is the date
 * the view implies, and it yields to both.
 */
fun Store.createFrom(context: Context, draft: TaskDraft, parentId: String? = null, dueIfNone: String? = null): TaskItem {
    val line = draft.title.trim()
    val task = when {
        parentId != null && draft.parse -> quickAddUnder(line, parentId)
        parentId != null -> createTask(NewTask(title = line, parentId = parentId))
        draft.parse -> quickAdd(line, draft.listId)
        else -> createTask(NewTask(title = line, listId = draft.listId))
    }
    val notes = draft.notes.trim()
    if (notes.isNotEmpty()) setNotes(task.id, notes)
    draft.start?.let { setStart(task.id, it) }
    (draft.due ?: dueIfNone.takeIf { task.due == null })?.let { setDue(task.id, it) }
    // After the dates: the rule is counted from them.
    draft.repeat?.let { setRepeat(task.id, it) }
    if (draft.priority != Priority.NONE) setPriority(task.id, draft.priority)
    attach(context, this, task.id, draft.files)
    return task(task.id)
}

/**
 * The new-task card: title, note, dates, repeat, priority, files and the list.
 * The same card sits in the sheet over the main screen and in the quick-entry
 * window. With `keepOpen` it empties itself after each task and waits for the
 * next one; the list stays as chosen.
 */
@Composable
fun NewTaskCard(
    lists: List<TaskList>,
    listId: String?,
    parse: Boolean,
    onCancel: () -> Unit,
    onSubmit: (TaskDraft) -> Unit,
    modifier: Modifier = Modifier,
    title: String = "",
    notes: String = "",
    files: List<Uri> = emptyList(),
    keepOpen: Boolean = false,
) {
    var text by remember { mutableStateOf(title) }
    var note by remember { mutableStateOf(notes) }
    var start by remember { mutableStateOf<String?>(null) }
    var due by remember { mutableStateOf<String?>(null) }
    var repeat by remember { mutableStateOf<Repeat?>(null) }
    var priority by remember { mutableStateOf(Priority.NONE) }
    var chosenList by remember { mutableStateOf(listId) }
    var listMenu by remember { mutableStateOf(false) }
    var dialog by remember { mutableStateOf<String?>(null) }
    // Files picked here join the ones the card was opened with.
    var picked by remember { mutableStateOf(emptyList<Uri>()) }
    val pickFiles = rememberLauncherForActivityResult(ActivityResultContracts.GetMultipleContents()) { uris ->
        picked = (picked + uris).distinct()
    }
    val attached = files + picked
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }

    fun submit() {
        if (text.isBlank()) return
        onSubmit(TaskDraft(text, note, start, due, repeat, priority, chosenList, parse, attached))
        if (!keepOpen) return
        text = ""
        note = ""
        start = null
        due = null
        repeat = null
        priority = Priority.NONE
        picked = emptyList()
        focus.requestFocus()
    }

    Column(modifier) {
        TextField(
            value = text,
            onValueChange = { text = it },
            placeholder = { Text(str(R.string.new_task)) },
            singleLine = true,
            colors = transparentField(),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { submit() }),
            modifier = Modifier.fillMaxWidth().focusRequester(focus),
        )
        if (parse) QuickChips(text, Modifier.padding(start = 16.dp, bottom = 4.dp))
        TextField(
            value = note,
            onValueChange = { note = it },
            placeholder = { Text(str(R.string.notes)) },
            maxLines = 4,
            textStyle = MaterialTheme.typography.bodyMedium,
            colors = transparentField(),
            modifier = Modifier.fillMaxWidth(),
        )
        // The same fields as in the editor, so that nothing has to be typed as text.
        Row(
            Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            AssistChip(onClick = { dialog = "start" }, label = { Text(start?.let { str(R.string.start_at, dateLabel(it).lowercase()) } ?: str(R.string.start)) })
            AssistChip(onClick = { dialog = "due" }, label = { Text(due?.let { str(R.string.due_at, dateLabel(it).lowercase()) } ?: str(R.string.due)) })
            AssistChip(onClick = { dialog = "repeat" }, label = { Text(repeat?.summary() ?: str(R.string.repeat)) })
            AssistChip(onClick = { dialog = "priority" }, label = { Text(if (priority == Priority.NONE) str(R.string.priority) else priority.title()) })
            AssistChip(onClick = { pickFiles.launch("*/*") }, label = { Text(str(R.string.file_or_image)) })
        }
        if (attached.isNotEmpty()) {
            Text(
                str(R.string.files_count, attached.size),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Box {
                // Under a project there is nothing to choose: the parent decides the list.
                if (chosenList != null) {
                    TextButton(onClick = { listMenu = true }) {
                        Text(lists.firstOrNull { it.id == chosenList }?.displayName() ?: str(R.string.inbox))
                    }
                    DropdownMenu(expanded = listMenu, onDismissRequest = { listMenu = false }) {
                        for (list in lists) {
                            DropdownMenuItem(text = { Text(list.displayName()) }, onClick = { chosenList = list.id; listMenu = false })
                        }
                    }
                }
            }
            Row {
                TextButton(onClick = onCancel) { Text(str(R.string.cancel)) }
                TextButton(onClick = { submit() }, enabled = text.isNotBlank()) { Text(str(R.string.add)) }
            }
        }
    }
    when (dialog) {
        "start" -> MomentDialog(str(R.string.start_title), start, onPick = { start = it }) { dialog = null }
        "due" -> MomentDialog(str(R.string.due), due, onPick = { due = it }) { dialog = null }
        "repeat" -> RepeatDialog(repeat, onPick = { repeat = it }) { dialog = null }
        "priority" -> ChoiceDialog(str(R.string.priority), priorities.map { it.title() }, priorities.indexOf(priority), { dialog = null }) { priority = priorities[it] }
    }
}
