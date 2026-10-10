package org.evsyukov.lists.ui

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import android.content.res.Configuration
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
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
import androidx.compose.material.icons.outlined.Event
import androidx.compose.material.icons.outlined.Flag
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.Repeat
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import org.evsyukov.lists.R
import org.evsyukov.lists.Repo
import org.evsyukov.lists.dateLabel
import org.evsyukov.lists.displayName
import org.evsyukov.lists.priorities
import org.evsyukov.lists.str
import org.evsyukov.lists.summary
import org.evsyukov.lists.title
import org.evsyukov.lists.today
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
    /** What stood next to the due icon. */
    val due: String?,
    /** The list put the date there, the person did not pick it: a date in the title wins over it (R41). */
    val dueIsPreset: Boolean,
    /** The person took the date away in the card: the task gets none from the list (R75). */
    val dueRemoved: Boolean,
    val repeat: Repeat?,
    /** What was chosen next to the flag; null while the field is untouched, and the title or the list decides (R75). */
    val priority: Priority?,
    /** Null where the place the task goes to decides the list, as under a project. */
    val listId: String?,
    /** Whether dates, priority, tags and a list are picked out of the title. */
    val parse: Boolean,
    val files: List<Uri>,
)

/**
 * Creates the task a draft describes, as a subtask when a parent is given.
 * What the fields say wins over what the title says; a due date the card only
 * preset yields to both.
 */
fun Store.createFrom(context: Context, draft: TaskDraft, parentId: String? = null): TaskItem {
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
    // The list gives its date only to a task without a start date, and this one was created before its start was written.
    val bare = draft.dueRemoved || draft.start != null
    val typed = if (bare && draft.parse) parseQuick(line).due else null
    val due = finalDue(draft.due, draft.dueIsPreset, bare, task.due, typed)
    if (due != task.due) setDue(task.id, due)
    // After the dates: the rule is counted from them.
    draft.repeat?.let { setRepeat(task.id, it) }
    val typedPriority = if (draft.priority == Priority.NONE && draft.parse) parseQuick(line).priority else Priority.NONE
    val priority = finalPriority(draft.priority, task.priority, typedPriority)
    if (priority != task.priority) setPriority(task.id, priority)
    attach(context, this, task.id, draft.files)
    return task(task.id)
}

/** The most lines the note of the compact card takes before it scrolls inside itself (R64). */
const val COMPACT_NOTE_LINES = 5

/**
 * The least and the most lines of the note (R64). Compact, it grows with its
 * text up to a bound, so that the title and the icons stay above the keyboard.
 * Expanded, it has no bound and the card scrolls; in landscape the keyboard
 * leaves a strip, and a tall empty note would push the fields far down.
 */
internal fun noteLines(full: Boolean, landscape: Boolean): IntRange = when {
    !full -> 1..COMPACT_NOTE_LINES
    landscape -> 2..Int.MAX_VALUE
    else -> 4..Int.MAX_VALUE
}

/** A repeat rule as plain values: the record the core hands over is not something a saved state can hold. */
private fun Repeat.toSaved(): ArrayList<Any?> = arrayListOf(
    freq.name, interval.toInt(), ArrayList(weekdays.map { it.toInt() }), monthday?.toInt(),
    nth, nthWeekday?.toInt(), fromDone, count?.toInt(), until,
)

@Suppress("UNCHECKED_CAST")
private fun repeatFromSaved(saved: List<Any?>) = Repeat(
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

/**
 * What is entered in the new-task card. The card keeps one of its own; the
 * main screen holds it outside the card, so that a card closed by mistake can
 * be brought back with everything in it (R97).
 */
@Stable
class NewTaskEntry(title: String = "", notes: String = "", listId: String? = null) {
    var text by mutableStateOf(title)
    var note by mutableStateOf(notes)
    /** The note as taken from the clipboard (R58), to tell it from one the person typed. */
    var taken by mutableStateOf<String?>(null)
    var start by mutableStateOf<String?>(null)
    var due by mutableStateOf<String?>(null)
    var dueRemoved by mutableStateOf(false)
    var repeat by mutableStateOf<Repeat?>(null)
    /** Null until the person chooses: the default of the list shows through and follows the chosen list. */
    var priority by mutableStateOf<Priority?>(null)
    var listId by mutableStateOf(listId)
    /** Files picked in the card; they join the ones it was opened with. */
    var picked by mutableStateOf(emptyList<Uri>())
    /** The size chosen in portrait (R64). */
    var expanded by mutableStateOf(false)

    /** Whether closing the card would lose something (R97). The list and the size alone are not an entry. */
    val hasContent: Boolean get() = hasContent(text, note, start, due, repeat != null, priority, picked.size)

    internal fun toSaved(): ArrayList<Any?> = arrayListOf(
        text, note, taken, start, due, dueRemoved, repeat?.toSaved(), priority?.name, listId,
        ArrayList(picked.map(Uri::toString)), expanded,
    )

    companion object {
        @Suppress("UNCHECKED_CAST")
        internal fun fromSaved(saved: List<Any?>) = NewTaskEntry(saved[0] as String, saved[1] as String, saved[8] as String?).apply {
            taken = saved[2] as String?
            start = saved[3] as String?
            due = saved[4] as String?
            dueRemoved = saved[5] as Boolean
            repeat = (saved[6] as List<Any?>?)?.let(::repeatFromSaved)
            priority = (saved[7] as String?)?.let(Priority::valueOf)
            picked = (saved[9] as List<String>).map(Uri::parse)
            expanded = saved[10] as Boolean
        }

        /** Saved, not just remembered: the card keeps what was entered when the screen is turned (R63). */
        val Saver = listSaver<NewTaskEntry, Any?>(save = { it.toSaved() }, restore = { fromSaved(it) })
    }
}

/** Whether a new-task card holds something the person entered (R97). A priority chosen as "none" is a choice too. */
internal fun hasContent(text: String, note: String, start: String?, due: String?, repeats: Boolean, priority: Priority?, files: Int): Boolean =
    text.isNotBlank() || note.isNotBlank() || start != null || due != null || repeats || priority != null || files > 0

/**
 * The new-task card: title, note, dates, repeat, priority, files and the list.
 * The same card sits in the sheet over the main screen and in the quick-entry
 * window. With `keepOpen` it empties itself after each task and waits for the
 * next one; the list and the size stay as chosen.
 *
 * It has two sizes (R64). Compact shows the fields as one row, a chip for
 * what is set and a light icon for what is not, and ends with a strip that
 * holds the list and "Save"; expanded takes the height it is given and shows them as labelled rows that
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
    /** What is entered. Given from outside where the card can be closed and brought back (R97). */
    entry: NewTaskEntry = rememberSaveable(saver = NewTaskEntry.Saver) { NewTaskEntry(title, notes, listId) },
) {
    var text by entry::text
    var note by entry::note
    // Kept apart from `pastedNotes`: a window rebuilt on rotation is not handed the same clipboard again.
    var taken by entry::taken
    LaunchedEffect(pastedNotes) {
        if (pastedNotes != null && note.isEmpty()) {
            note = pastedNotes
            taken = pastedNotes
        }
    }
    var start by entry::start
    var due by entry::due
    var dueRemoved by entry::dueRemoved
    var repeat by entry::repeat
    var priority by entry::priority
    var chosenList by entry::listId
    var dialog by rememberSaveable { mutableStateOf<String?>(null) }
    var picked by entry::picked
    val pickFiles = rememberLauncherForActivityResult(ActivityResultContracts.GetMultipleContents()) { uris ->
        picked = (picked + uris).distinct()
    }
    val attached = files + picked
    // What the user chose in portrait; it comes back when the screen is turned upright again.
    val expanded = entry.expanded
    val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    val full = expanded || landscape
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }

    // What the task gets from its list unless the person chooses; shown like a chosen value, so that it can be changed or removed (R75).
    val chosen = lists.firstOrNull { it.id == chosenList }
    val preset = presetDue(chosen?.defaultDueToday == true, start, today()).takeIf { due == null && !dueRemoved }
    val presetPriority = chosen?.defaultPriority?.takeIf { priority == null && it != Priority.NONE }
    // What the title says wins over an untouched preset (R41), and the icon says so.
    val typed = remember(text, parse) { if (parse && text.isNotBlank()) Repo.store.parseQuick(text) else null }
    // Shown as the value of the field, whichever of the three it comes from: the card, the title, the list.
    val shownDue = shownDue(due, typed?.due, preset)
    val shownPriority = shownPriority(priority, typed?.priority ?: Priority.NONE, presetPriority)

    fun submit() {
        if (text.isBlank()) return
        onSubmit(TaskDraft(text, note, start, due ?: preset, due == null && preset != null, dueRemoved, repeat, priority, chosenList, parse, attached))
        if (!keepOpen) return
        text = ""
        note = ""
        start = null
        due = null
        dueRemoved = false
        repeat = null
        priority = null
        picked = emptyList()
        focus.requestFocus()
    }

    val listName = chosenList?.let { id -> lists.firstOrNull { it.id == id }?.displayName() ?: str(R.string.inbox) }

    // One tree for both sizes: the title and the note stay the same fields, so the cursor stays where it was.
    Column(if (full) modifier.fillMaxHeight() else modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (!full) Mark(MarkState.Open, null, Modifier.padding(start = 16.dp))
            TextField(
                value = text,
                onValueChange = { text = it },
                placeholder = { Text(str(R.string.new_task)) },
                singleLine = true,
                colors = transparentField(),
                keyboardOptions = SentenceKeyboard.copy(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { submit() }),
                modifier = Modifier.weight(1f).focusRequester(focus),
            )
            // Compact, the card is saved from the strip at its bottom.
            if (full) {
                IconButton(onClick = { submit() }, enabled = text.isNotBlank()) {
                    Icon(Icons.AutoMirrored.Outlined.Send, str(R.string.add))
                }
            }
        }
        Column(if (full) Modifier.weight(1f).verticalScroll(rememberScrollState()) else Modifier) {
            if (parse && full) QuickChips(text, Modifier.padding(start = 16.dp, bottom = 4.dp))
            TextField(
                value = note,
                onValueChange = { note = it },
                placeholder = { Text(str(R.string.notes)) },
                // The text taken from the clipboard goes in one tap while it is untouched.
                trailingIcon = if (taken != null && note == taken) {
                    { IconButton(onClick = { note = "" }) { Icon(Icons.Outlined.Close, str(R.string.remove_clipboard_note)) } }
                } else null,
                minLines = noteLines(full, landscape).first,
                maxLines = noteLines(full, landscape).last,
                textStyle = MaterialTheme.typography.bodyMedium,
                colors = transparentField(),
                keyboardOptions = SentenceKeyboard,
                // Compact, the note begins under the title, past the mark.
                modifier = Modifier.fillMaxWidth().padding(start = if (full) 0.dp else 34.dp),
            )
            // The same fields as in the editor, so that nothing has to be typed as text.
            val startText = start?.let { dateLabel(it).lowercase() }
            val dueText = shownDue?.let { dateLabel(it).lowercase() }
            val filesText = attached.size.takeIf { it > 0 }?.toString()
            if (full) {
                FieldRow(Icons.Outlined.PlayArrow, str(R.string.start), startText) { dialog = "start" }
                FieldRow(Icons.Outlined.Event, str(R.string.due), dueText) { dialog = "due" }
                FieldRow(Icons.Outlined.Repeat, str(R.string.repeat), repeat?.summary()) { dialog = "repeat" }
                FieldRow(Icons.Outlined.Flag, str(R.string.priority), shownPriority.takeIf { it != Priority.NONE }?.title()) { dialog = "priority" }
                FieldRow(Icons.Outlined.AttachFile, str(R.string.file_or_image), filesText) { pickFiles.launch("*/*") }
                // Under a project there is nothing to choose: the parent decides the list.
                if (listName != null) FieldRow(Icons.AutoMirrored.Outlined.List, str(R.string.list), listName) { dialog = "list" }
            } else {
                FieldsRow(
                    Modifier.fillMaxWidth().padding(start = 50.dp, end = 8.dp),
                    chips = {
                        start?.let { ValueChip(dateLabel(it), Icons.Outlined.PlayArrow, str(R.string.start)) { dialog = "start" } }
                        shownDue?.let { ValueChip(dateLabel(it), Icons.Outlined.Event, str(R.string.due)) { dialog = "due" } }
                        repeat?.let { ValueChip(it.summary(), Icons.Outlined.Repeat, str(R.string.repeat)) { dialog = "repeat" } }
                        if (shownPriority != Priority.NONE) {
                            ValueChip(shownPriority.title(), Icons.Outlined.Flag, str(R.string.priority), color = PriorityColor) { dialog = "priority" }
                        }
                        filesText?.let { ValueChip(it, Icons.Outlined.AttachFile, str(R.string.file_or_image)) { pickFiles.launch("*/*") } }
                        // Read from the title and changed there (R41).
                        for (tag in typed?.tags.orEmpty()) ValueChip("#$tag", onClick = null)
                        typed?.listName?.let { ValueChip("@$it", onClick = null) }
                    },
                    icons = {
                        if (startText == null) LightIcon(Icons.Outlined.PlayArrow, str(R.string.start)) { dialog = "start" }
                        if (dueText == null) LightIcon(Icons.Outlined.Event, str(R.string.due)) { dialog = "due" }
                        if (repeat == null) LightIcon(Icons.Outlined.Repeat, str(R.string.repeat)) { dialog = "repeat" }
                        if (shownPriority == Priority.NONE) LightIcon(Icons.Outlined.Flag, str(R.string.priority)) { dialog = "priority" }
                        LightIcon(Icons.Outlined.AttachFile, str(R.string.file_or_image)) { pickFiles.launch("*/*") }
                    },
                )
            }
        }
        if (!full) {
            HorizontalDivider(Modifier.padding(top = 6.dp), color = MaterialTheme.colorScheme.outlineVariant)
            Row(
                Modifier.fillMaxWidth().padding(start = 8.dp, end = 8.dp, top = 6.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // Under a project there is nothing to choose: the parent decides the list.
                if (listName != null) {
                    Row(
                        Modifier.weight(1f, fill = false).clip(CircleShape).clickable(role = Role.Button) { dialog = "list" }.heightIn(min = 40.dp).padding(horizontal = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.AutoMirrored.Outlined.List, str(R.string.list), Modifier.size(18.dp), tint = chosen?.tint() ?: MaterialTheme.colorScheme.onSurfaceVariant)
                        Spacer(Modifier.width(6.dp))
                        Text(listName, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                } else {
                    Spacer(Modifier.weight(1f))
                }
                Button(
                    onClick = { submit() },
                    enabled = text.isNotBlank(),
                    shape = CircleShape,
                    colors = ButtonDefaults.buttonColors(containerColor = viewTint(ViewTint.Blue), contentColor = Color.White),
                    contentPadding = PaddingValues(horizontal = 18.dp),
                ) { Text(str(R.string.save)) }
            }
        }
    }
    when (dialog) {
        "start" -> MomentDialog(str(R.string.start_title), start, onPick = { start = it }) { dialog = null }
        "due" -> MomentDialog(str(R.string.due), shownDue, onPick = { due = it; dueRemoved = it == null }) { dialog = null }
        "repeat" -> RepeatDialog(repeat, onPick = { repeat = it }) { dialog = null }
        "priority" -> ChoiceDialog(str(R.string.priority), priorities.map { it.title() }, priorities.indexOf(shownPriority), { dialog = null }) { priority = priorities[it] }
        "list" -> ChoiceDialog(str(R.string.list), lists.map { it.displayName() }, lists.indexOfFirst { it.id == chosenList }, { dialog = null }) { chosenList = lists[it].id }
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
