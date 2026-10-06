package org.evsyukov.lists

import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.service.quicksettings.TileService
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
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
import androidx.lifecycle.lifecycleScope
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.AssistChip
import org.evsyukov.lists.ui.ChoiceDialog
import org.evsyukov.lists.ui.MomentDialog
import org.evsyukov.lists.ui.QuickChips
import org.evsyukov.lists.ui.RepeatDialog
import uniffi.lists_core.Priority
import org.evsyukov.lists.ui.attach
import org.evsyukov.lists.ui.describe
import org.evsyukov.lists.ui.transparentField
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.lists_core.NewTask
import uniffi.lists_core.Repeat

/** What another app handed over, reduced to what a task can hold. */
/** What the quick-entry window collected. */
private data class Entry(
    val title: String,
    val notes: String,
    val start: String?,
    val due: String?,
    val repeat: Repeat?,
    val priority: Priority,
    val listId: String,
    val parse: Boolean,
)

private data class Shared(val title: String = "", val notes: String = "", val files: List<Uri> = emptyList())

/**
 * Quick entry over whatever is on screen. Reached from "Share", from the
 * text-selection menu, from the launcher shortcut and from the quick settings
 * tile; the main screen is never started.
 */
class QuickAddActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val shared = read(intent)
        val lists = runCatching { Repo.store.lists().filter { !it.archived } }.getOrDefault(emptyList())

        setContent {
            AppTheme {
                var text by remember { mutableStateOf(shared.title) }
                var notes by remember { mutableStateOf(shared.notes) }
                var start by remember { mutableStateOf<String?>(null) }
                var due by remember { mutableStateOf<String?>(null) }
                var repeat by remember { mutableStateOf<Repeat?>(null) }
                var priority by remember { mutableStateOf(Priority.NONE) }
                var listId by remember { mutableStateOf(EntryPrefs.defaultListId(this, lists)) }
                var listMenu by remember { mutableStateOf(false) }
                var dialog by remember { mutableStateOf<String?>(null) }
                // Files picked here join the ones that came through Share.
                var picked by remember { mutableStateOf(emptyList<Uri>()) }
                val pickFiles = rememberLauncherForActivityResult(ActivityResultContracts.GetMultipleContents()) { uris ->
                    picked = (picked + uris).distinct()
                }
                val files = shared.files + picked
                // Typed text is parsed for dates and tags, unless that is turned off; shared text is taken as is.
                val parse = shared.title.isEmpty() && EntryPrefs.parse(this)
                val focus = remember { FocusRequester() }
                LaunchedEffect(Unit) { focus.requestFocus() }
                fun submit() = save(Entry(text, notes, start, due, repeat, priority, listId, parse), files)

                // Tapping outside the card closes the window, as with any dialog.
                Box(
                    Modifier.fillMaxSize().systemBarsPadding().imePadding()
                        .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { finish() },
                    contentAlignment = Alignment.BottomCenter,
                ) {
                    Surface(
                        shape = RoundedCornerShape(20.dp),
                        tonalElevation = 6.dp,
                        modifier = Modifier.fillMaxWidth().padding(12.dp)
                            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {},
                    ) {
                        Column(Modifier.padding(horizontal = 8.dp, vertical = 8.dp)) {
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
                                value = notes,
                                onValueChange = { notes = it },
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
                            val extra = listOfNotNull(
                                files.size.takeIf { it > 0 }?.let { str(R.string.files_count, it) },
                            ).joinToString(" · ")
                            if (extra.isNotEmpty()) {
                                Text(
                                    extra,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(horizontal = 16.dp),
                                )
                            }
                            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                                Box {
                                    TextButton(onClick = { listMenu = true }) {
                                        Text(lists.firstOrNull { it.id == listId }?.displayName() ?: str(R.string.inbox))
                                    }
                                    DropdownMenu(expanded = listMenu, onDismissRequest = { listMenu = false }) {
                                        for (list in lists) {
                                            DropdownMenuItem(text = { Text(list.displayName()) }, onClick = { listId = list.id; listMenu = false })
                                        }
                                    }
                                }
                                Row {
                                    TextButton(onClick = { finish() }) { Text(str(R.string.cancel)) }
                                    TextButton(onClick = { submit() }, enabled = text.isNotBlank()) { Text(str(R.string.add)) }
                                }
                            }
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
        }
    }

    private fun read(intent: Intent): Shared = when (intent.action) {
        Intent.ACTION_PROCESS_TEXT -> fromText(intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString().orEmpty(), null)
        Intent.ACTION_SEND -> fromText(
            intent.getStringExtra(Intent.EXTRA_TEXT).orEmpty(),
            intent.getStringExtra(Intent.EXTRA_SUBJECT),
        ).copy(files = listOfNotNull(stream(intent)))
        Intent.ACTION_SEND_MULTIPLE -> Shared(files = streams(intent))
        else -> Shared()
    }.let { shared ->
        if (shared.title.isEmpty() && shared.files.isNotEmpty()) shared.copy(title = str(R.string.file)) else shared
    }

    /** The subject or the first line becomes the title; a longer text stays whole in the note. */
    private fun fromText(text: String, subject: String?): Shared {
        val body = text.trim()
        val title = subject?.trim()?.takeIf { it.isNotEmpty() } ?: body.lineSequence().firstOrNull().orEmpty().take(120)
        return Shared(title = title, notes = if (body == title) "" else body)
    }

    @Suppress("DEPRECATION")
    private fun stream(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableExtra(Intent.EXTRA_STREAM)

    @Suppress("DEPRECATION")
    private fun streams(intent: Intent): List<Uri> =
        (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)).orEmpty()

    private fun save(entry: Entry, files: List<Uri>) {
        val line = entry.title.trim()
        if (line.isEmpty()) return
        lifecycleScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val store = Repo.store
                    // What the fields say wins over what the title says.
                    val task = if (entry.parse) {
                        store.quickAdd(line, entry.listId)
                    } else {
                        store.createTask(NewTask(title = line, listId = entry.listId))
                    }
                    val notes = entry.notes.trim()
                    if (notes.isNotEmpty()) store.setNotes(task.id, notes)
                    entry.start?.let { store.setStart(task.id, it) }
                    entry.due?.let { store.setDue(task.id, it) }
                    // After the dates: the rule is counted from them.
                    entry.repeat?.let { store.setRepeat(task.id, it) }
                    if (entry.priority != Priority.NONE) store.setPriority(task.id, entry.priority)
                    EntryPrefs.noteUsedList(applicationContext, store.task(task.id).listId)
                    attach(applicationContext, store, task.id, files)
                }
            }
            Repo.changed()
            val message = result.exceptionOrNull()?.let(::describe) ?: str(R.string.added)
            Toast.makeText(applicationContext, message, Toast.LENGTH_SHORT).show()
            if (result.isSuccess) finish()
        }
    }
}

/** Quick settings tile: one tap from anywhere opens the quick-entry window. */
class QuickTileService : TileService() {
    override fun onClick() {
        val intent = Intent(this, QuickAddActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
            startActivityAndCollapse(intent)
        }
    }
}
