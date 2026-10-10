package org.evsyukov.lists

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.service.quicksettings.TileService
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import org.evsyukov.lists.ui.CardHandle
import org.evsyukov.lists.ui.NewTaskCard
import org.evsyukov.lists.ui.NewTaskEntry
import org.evsyukov.lists.ui.TaskDraft
import org.evsyukov.lists.ui.createFrom
import org.evsyukov.lists.ui.describe
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** What another app handed over, reduced to what a task can hold. */
private data class Shared(val title: String = "", val notes: String = "", val files: List<Uri> = emptyList())

/**
 * Quick entry over whatever is on screen. Reached from "Share", from the
 * text-selection menu, from the launcher shortcut and from the quick settings
 * tile; the main screen is never started.
 */
class QuickAddActivity : ComponentActivity() {
    /** R58: the note a window opened empty takes from the clipboard. */
    private var pasted by mutableStateOf<String?>(null)
    private var readsClipboard = false

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        applyOverrideConfiguration(LookPrefs.textConfiguration(base))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val shared = read(intent)
        // What was shared or selected carries its own text.
        readsClipboard = shared == Shared() && EntryPrefs.clipboard(this)
        val lists = runCatching { Repo.store.lists().filter { !it.archived } }.getOrDefault(emptyList())

        setContent {
            AppTheme {
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
                        val listId = EntryPrefs.defaultListId(this@QuickAddActivity, lists)
                        val entry = rememberSaveable(saver = NewTaskEntry.Saver) { NewTaskEntry(shared.title, shared.notes, listId) }
                        val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
                        Column {
                            // R97: the same handle as in the main window. In landscape the card has one size.
                            if (!landscape) CardHandle(entry.expanded, { entry.expanded = it }, onClose = ::finish)
                            NewTaskCard(
                                lists = lists,
                                listId = listId,
                                // Typed text is parsed for dates and tags, unless that is turned off; shared text is taken as is.
                                parse = shared.title.isEmpty() && EntryPrefs.parse(this@QuickAddActivity),
                                onSubmit = ::save,
                                modifier = Modifier.padding(8.dp),
                                title = shared.title,
                                notes = shared.notes,
                                files = shared.files,
                                pastedNotes = pasted,
                                entry = entry,
                            )
                        }
                    }
                }
            }
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Not in onCreate: the system hands the clipboard only to the window that has the focus.
        if (!hasFocus || !readsClipboard) return
        readsClipboard = false
        pasted = EntryPrefs.clipboardNote(this)
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

    private fun save(draft: TaskDraft) {
        lifecycleScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val task = Repo.store.createFrom(applicationContext, draft)
                    EntryPrefs.noteUsedList(applicationContext, task.listId)
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
