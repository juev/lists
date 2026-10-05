package org.evsyukov.lists

import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.service.quicksettings.TileService
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
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
import org.evsyukov.lists.ui.QuickChips
import org.evsyukov.lists.ui.attach
import org.evsyukov.lists.ui.describe
import org.evsyukov.lists.ui.transparentField
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.lists_core.NewTask

/** What another app handed over, reduced to what a task can hold. */
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
                var listId by remember { mutableStateOf("inbox") }
                var listMenu by remember { mutableStateOf(false) }
                val focus = remember { FocusRequester() }
                LaunchedEffect(Unit) { focus.requestFocus() }
                fun submit() = save(text, listId, shared)

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
                            // Typed text is parsed for dates and tags; shared text is taken as is.
                            if (shared.title.isEmpty()) QuickChips(text, Modifier.padding(start = 16.dp, bottom = 4.dp))
                            val extra = listOfNotNull(
                                shared.notes.takeIf { it.isNotEmpty() },
                                shared.files.size.takeIf { it > 0 }?.let { str(R.string.files_count, it) },
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

    private fun save(text: String, listId: String, shared: Shared) {
        val line = text.trim()
        if (line.isEmpty()) return
        lifecycleScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val store = Repo.store
                    val task = if (shared.title.isEmpty()) {
                        store.quickAdd(line, listId)
                    } else {
                        store.createTask(NewTask(title = line, listId = listId, notes = shared.notes))
                    }
                    attach(applicationContext, store, task.id, shared.files)
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
