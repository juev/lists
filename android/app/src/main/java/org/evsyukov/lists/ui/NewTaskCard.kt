package org.evsyukov.lists.ui

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import android.content.res.Configuration
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.List
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.AttachFile
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.CloseFullscreen
import androidx.compose.material.icons.outlined.Event
import androidx.compose.material.icons.outlined.Flag
import androidx.compose.material.icons.outlined.OpenInFull
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.Repeat
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import org.evsyukov.lists.R
import org.evsyukov.lists.dateLabel
import org.evsyukov.lists.displayName
import org.evsyukov.lists.marks
import org.evsyukov.lists.priorities
import org.evsyukov.lists.str
import org.evsyukov.lists.summary
import org.evsyukov.lists.title
import uniffi.lists_core.Freq
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

/** A repeat rule as plain values: the record the core hands over is not something a saved state can hold. */
private val repeatSaver = listSaver<Repeat?, Any?>(
    save = { rule ->
        if (rule == null) emptyList()
        else listOf(
            rule.freq.name, rule.interval.toInt(), ArrayList(rule.weekdays.map { it.toInt() }), rule.monthday?.toInt(),
            rule.nth, rule.nthWeekday?.toInt(), rule.fromDone, rule.count?.toInt(), rule.until,
        )
    },
    restore = { saved ->
        @Suppress("UNCHECKED_CAST")
        Repeat(
            freq = Freq.valueOf(saved[0] as String),
            interval = (saved[1] as Int).toUInt(),
            weekdays = (saved[2] as List<Int>).map { it.toUInt() },
            monthday = (saved[3] as Int?)?.toUInt(),
            nth = saved[4] as Int?,
            nthWeekday = (saved[5] as Int?)?.toUInt(),
            fromDone = saved[6] as Boolean,
            count = (saved[7] as Int?)?.toUInt(),
            until = saved[8] as String?,
        )
    },
)

private val urisSaver = listSaver<List<Uri>, String>(save = { uris -> uris.map(Uri::toString) }, restore = { saved -> saved.map(Uri::parse) })

/**
 * The new-task card: title, note, dates, repeat, priority, files and the list.
 * The same card sits in the sheet over the main screen and in the quick-entry
 * window. With `keepOpen` it empties itself after each task and waits for the
 * next one; the list and the size stay as chosen.
 *
 * It has two sizes (R64). Compact shows the fields as one row of icons;
 * expanded takes the height it is given and shows them as labelled rows that
 * scroll under the title. In landscape it is always expanded: the compact one
 * has no room above the keyboard.
 */
@Composable
fun NewTaskCard(
    lists: List<TaskList>,
    listId: String?,
    parse: Boolean,
    onSubmit: (TaskDraft) -> Unit,
    modifier: Modifier = Modifier,
    title: String = "",
    notes: String = "",
    files: List<Uri> = emptyList(),
    keepOpen: Boolean = false,
    /** The note taken from the clipboard (R58); it may arrive after the card is shown. */
    pastedNotes: String? = null,
) {
    // Saved, not just remembered: the card keeps what was entered when the screen is turned (R63).
    var text by rememberSaveable { mutableStateOf(title) }
    var note by rememberSaveable { mutableStateOf(notes) }
    // Kept apart from `pastedNotes`: a window rebuilt on rotation is not handed the same clipboard again.
    var taken by rememberSaveable { mutableStateOf<String?>(null) }
    LaunchedEffect(pastedNotes) {
        if (pastedNotes != null && note.isEmpty()) {
            note = pastedNotes
            taken = pastedNotes
        }
    }
    var start by rememberSaveable { mutableStateOf<String?>(null) }
    var due by rememberSaveable { mutableStateOf<String?>(null) }
    var repeat by rememberSaveable(stateSaver = repeatSaver) { mutableStateOf<Repeat?>(null) }
    var priority by rememberSaveable { mutableStateOf(Priority.NONE) }
    var chosenList by rememberSaveable { mutableStateOf(listId) }
    var dialog by rememberSaveable { mutableStateOf<String?>(null) }
    // Files picked here join the ones the card was opened with.
    var picked by rememberSaveable(stateSaver = urisSaver) { mutableStateOf(emptyList<Uri>()) }
    val pickFiles = rememberLauncherForActivityResult(ActivityResultContracts.GetMultipleContents()) { uris ->
        picked = (picked + uris).distinct()
    }
    val attached = files + picked
    // What the user chose in portrait; it comes back when the screen is turned upright again.
    var expanded by rememberSaveable { mutableStateOf(false) }
    val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    val full = expanded || landscape
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

    val listName = chosenList?.let { id -> lists.firstOrNull { it.id == id }?.displayName() ?: str(R.string.inbox) }

    // One tree for both sizes: the title and the note stay the same fields, so the cursor stays where it was.
    Column(if (full) modifier.fillMaxHeight() else modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextField(
                value = text,
                onValueChange = { text = it },
                placeholder = { Text(str(R.string.new_task)) },
                singleLine = true,
                colors = transparentField(),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { submit() }),
                modifier = Modifier.weight(1f).focusRequester(focus),
            )
            if (!landscape) {
                IconButton(onClick = { expanded = !expanded }) {
                    if (expanded) Icon(Icons.Outlined.CloseFullscreen, str(R.string.collapse_card))
                    else Icon(Icons.Outlined.OpenInFull, str(R.string.expand_card))
                }
            }
            IconButton(onClick = { submit() }, enabled = text.isNotBlank()) {
                Icon(Icons.AutoMirrored.Outlined.Send, str(R.string.add))
            }
        }
        Column(if (full) Modifier.weight(1f).verticalScroll(rememberScrollState()) else Modifier) {
            if (parse) QuickChips(text, Modifier.padding(start = 16.dp, bottom = 4.dp))
            TextField(
                value = note,
                onValueChange = { note = it },
                placeholder = { Text(str(R.string.notes)) },
                // The text taken from the clipboard goes in one tap while it is untouched.
                trailingIcon = if (taken != null && note == taken) {
                    { IconButton(onClick = { note = "" }) { Icon(Icons.Outlined.Close, str(R.string.remove_clipboard_note)) } }
                } else null,
                // In landscape the keyboard leaves a strip: a tall note would push the fields far down.
                minLines = if (!full) 1 else if (landscape) 2 else 4,
                maxLines = if (full) Int.MAX_VALUE else 1,
                textStyle = MaterialTheme.typography.bodyMedium,
                colors = transparentField(),
                modifier = Modifier.fillMaxWidth(),
            )
            // The same fields as in the editor, so that nothing has to be typed as text.
            val startText = start?.let { dateLabel(it).lowercase() }
            val dueText = due?.let { dateLabel(it).lowercase() }
            val filesText = attached.size.takeIf { it > 0 }?.toString()
            if (full) {
                FieldRow(Icons.Outlined.PlayArrow, str(R.string.start), startText) { dialog = "start" }
                FieldRow(Icons.Outlined.Event, str(R.string.due), dueText) { dialog = "due" }
                FieldRow(Icons.Outlined.Repeat, str(R.string.repeat), repeat?.summary()) { dialog = "repeat" }
                FieldRow(Icons.Outlined.Flag, str(R.string.priority), priority.takeIf { it != Priority.NONE }?.title()) { dialog = "priority" }
                FieldRow(Icons.Outlined.AttachFile, str(R.string.file_or_image), filesText) { pickFiles.launch("*/*") }
                // Under a project there is nothing to choose: the parent decides the list.
                if (listName != null) FieldRow(Icons.AutoMirrored.Outlined.List, str(R.string.list), listName) { dialog = "list" }
            } else {
                FittedRow(Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
                    FieldIcon(Icons.Outlined.PlayArrow, str(R.string.start), startText) { dialog = "start" }
                    FieldIcon(Icons.Outlined.Event, str(R.string.due), dueText) { dialog = "due" }
                    FieldIcon(Icons.Outlined.Repeat, str(R.string.repeat), repeat?.summary()) { dialog = "repeat" }
                    FieldIcon(Icons.Outlined.Flag, str(R.string.priority), priority.marks().ifEmpty { null }) { dialog = "priority" }
                    FieldIcon(Icons.Outlined.AttachFile, str(R.string.file_or_image), filesText) { pickFiles.launch("*/*") }
                    if (listName != null) FieldIcon(Icons.AutoMirrored.Outlined.List, str(R.string.list), listName) { dialog = "list" }
                }
            }
        }
    }
    when (dialog) {
        "start" -> MomentDialog(str(R.string.start_title), start, onPick = { start = it }) { dialog = null }
        "due" -> MomentDialog(str(R.string.due), due, onPick = { due = it }) { dialog = null }
        "repeat" -> RepeatDialog(repeat, onPick = { repeat = it }) { dialog = null }
        "priority" -> ChoiceDialog(str(R.string.priority), priorities.map { it.title() }, priorities.indexOf(priority), { dialog = null }) { priority = priorities[it] }
        "list" -> ChoiceDialog(str(R.string.list), lists.map { it.displayName() }, lists.indexOfFirst { it.id == chosenList }, { dialog = null }) { chosenList = lists[it].id }
    }
}

/** A field of the compact card: its icon, and the value next to it once one is set. */
@Composable
private fun FieldIcon(icon: ImageVector, label: String, value: String?, onClick: () -> Unit) {
    Row(
        Modifier.clip(CircleShape).clickable(role = Role.Button, onClick = onClick).heightIn(min = 40.dp).widthIn(min = 36.dp).padding(horizontal = 6.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            icon,
            label,
            Modifier.size(18.dp),
            tint = if (value != null) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (value != null) {
            Spacer(Modifier.width(3.dp))
            Text(value, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelMedium)
        }
    }
}

/** A field of the expanded card: icon, name, and the value at the end of the row. */
@Composable
private fun FieldRow(icon: ImageVector, label: String, value: String?, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onClick).heightIn(min = 48.dp).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(16.dp))
        Text(label)
        Text(
            value.orEmpty(),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.End,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f).padding(start = 16.dp),
        )
    }
}

/**
 * A row that never runs past its width. Children that fit keep their size;
 * when they do not, the widest are narrowed first and cut their text short.
 */
@Composable
private fun FittedRow(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Layout(content, modifier) { measurables, constraints ->
        val wanted = measurables.map { it.maxIntrinsicWidth(constraints.maxHeight) }
        val widths = fitWidths(wanted, constraints.maxWidth)
        val placeables = measurables.mapIndexed { index, measurable ->
            measurable.measure(Constraints(maxWidth = widths[index], maxHeight = constraints.maxHeight))
        }
        val height = placeables.maxOfOrNull { it.height } ?: 0
        layout(constraints.maxWidth, height.coerceAtLeast(constraints.minHeight)) {
            var x = 0
            for (placeable in placeables) {
                placeable.placeRelative(x, (height - placeable.height) / 2)
                x += placeable.width
            }
        }
    }
}

/** Shares `total` among children that want `wanted`: the narrow ones get what they ask for, the rest split what is left evenly. */
internal fun fitWidths(wanted: List<Int>, total: Int): List<Int> {
    if (wanted.sum() <= total) return wanted
    val widths = IntArray(wanted.size)
    var left = total
    var waiting = wanted.size
    for (index in wanted.indices.sortedBy { wanted[it] }) {
        widths[index] = minOf(wanted[index], left / waiting)
        left -= widths[index]
        waiting--
    }
    return widths.toList()
}
