package org.evsyukov.lists.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import org.evsyukov.lists.R
import org.evsyukov.lists.str
import uniffi.lists_core.TaskItem

/** What the menu of a subtask can hold. */
enum class SubtaskAction { Rename, Complete, Reopen, WontDo, Delete, Restore, DeleteRecord }

/** R38: the menu of a subtask holds only what applies to a line with a mark and a title (R10). */
fun subtaskMenu(task: TaskItem): List<SubtaskAction> = when {
    task.deleted -> listOf(SubtaskAction.Restore)
    task.isLog -> listOf(SubtaskAction.DeleteRecord)
    task.done != null -> listOf(SubtaskAction.Rename, SubtaskAction.Reopen, SubtaskAction.Delete)
    else -> listOf(SubtaskAction.Rename, SubtaskAction.Complete, SubtaskAction.WontDo, SubtaskAction.Delete)
}

/**
 * R32: whether the menu of a task offers to make it a project or to turn it back.
 * The tasks of a project would become subtasks and lose their fields, so a project that has them stays one.
 */
fun TaskItem.offersProjectSwitch(): Boolean = parentId == null && !(isProject && subtasksTotal > 0u)

/**
 * R38: the title an edit in the line of a subtask saves, or null when there is nothing to save:
 * an empty title is not saved, and neither is one that did not change. Pasted lines become one line.
 */
fun renamed(before: String, typed: String): String? =
    typed.lines().map(String::trim).filter(String::isNotEmpty).joinToString(" ").takeIf { it.isNotEmpty() && it != before }

/**
 * A subtask in the card of its task (R10, R38): a mark and a title, without a card of its own.
 * A tap edits the title in the line, a long press opens the menu of the subtask.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SubtaskLine(task: TaskItem, renaming: Boolean, model: MainViewModel, onRename: (Boolean) -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val done = task.done != null
    val fixed = task.deleted || task.isLog
    Row(
        Modifier
            .fillMaxWidth()
            .combinedClickable(
                enabled = !renaming,
                onClickLabel = if (fixed) null else str(R.string.rename),
                onClick = { if (!fixed) onRename(true) },
                onLongClick = { menu = true },
            )
            .padding(start = 4.dp, end = 16.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = { model.toggleDone(task) }, enabled = !fixed) {
            Mark(task.markState(), if (done) str(R.string.reopen) else str(R.string.complete), small = true)
        }
        if (renaming) {
            SubtaskTitleField(task.title, Modifier.weight(1f), onCommit = { title -> model.act { it.setTitle(task.id, title) } }) { onRename(false) }
        } else {
            // R96: a subtask that is done is grey, without a strike.
            Text(
                task.title,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                color = if (done) MaterialTheme.colorScheme.outline else MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.weight(1f),
            )
        }
        Box {
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                for (action in subtaskMenu(task)) {
                    val (title, run) = when (action) {
                        SubtaskAction.Rename -> R.string.rename to { onRename(true) }
                        SubtaskAction.Complete -> R.string.complete to { model.toggleDone(task) }
                        SubtaskAction.Reopen -> R.string.reopen to { model.toggleDone(task) }
                        SubtaskAction.WontDo -> R.string.wont_do to { model.wontDo(task) }
                        SubtaskAction.Delete -> R.string.delete to { model.delete(task) }
                        SubtaskAction.Restore -> R.string.restore to { model.change { it.restoreTask(task.id) } }
                        SubtaskAction.DeleteRecord -> R.string.delete_record to { model.delete(task) }
                    }
                    DropdownMenuItem(
                        text = { Text(str(title), color = if (action == SubtaskAction.Delete) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface) },
                        onClick = { menu = false; run() },
                    )
                }
            }
        }
    }
}

/**
 * The title of a subtask while it is edited in its line (R38). Done on the keyboard saves it, and so
 * does leaving the field, by a tap on another field or by closing the card.
 */
@Composable
private fun SubtaskTitleField(title: String, modifier: Modifier, onCommit: (String) -> Unit, onDone: () -> Unit) {
    // The cursor stands after the title: the usual edit adds to it or fixes its end.
    var field by remember { mutableStateOf(TextFieldValue(title, TextRange(title.length))) }
    var focused by remember { mutableStateOf(false) }
    // Done is followed by the field going away: the title is saved once.
    var saved by remember { mutableStateOf(false) }
    val focus = remember { FocusRequester() }
    val commit by rememberUpdatedState(onCommit)
    fun save() {
        if (saved) return
        saved = true
        renamed(title, field.text)?.let(commit)
    }
    fun finish() {
        save()
        onDone()
    }
    LaunchedEffect(Unit) { focus.requestFocus() }
    // The card closed, or another subtask took the edit over.
    DisposableEffect(Unit) { onDispose { save() } }
    // R83: an app left in the background may be killed there, and the field never loses the keyboard then.
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) { finish() }
    BasicTextField(
        value = field,
        onValueChange = { field = it },
        singleLine = true,
        textStyle = LocalTextStyle.current.copy(color = MaterialTheme.colorScheme.onSurface),
        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
        keyboardOptions = SentenceKeyboard.copy(imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { finish() }),
        modifier = modifier.focusRequester(focus).onFocusChanged {
            if (focused && !it.isFocused) finish()
            focused = it.isFocused
        },
    )
}

/** R22: a subtask a search found its task by, under the row of the task: a mark and a title, nothing to press. */
@Composable
fun FoundSubtask(task: TaskItem) {
    val done = task.done != null
    Row(Modifier.fillMaxWidth().padding(start = 52.dp, end = 16.dp, top = 4.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Mark(task.markState(), str(if (done) R.string.completed else R.string.subtask), small = true)
        Text(
            task.title,
            Modifier.padding(start = 10.dp),
            style = MaterialTheme.typography.bodyMedium,
            color = if (done) MaterialTheme.colorScheme.outline else MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
