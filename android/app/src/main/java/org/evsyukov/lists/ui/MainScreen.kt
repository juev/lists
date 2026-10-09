package org.evsyukov.lists.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.List
import androidx.compose.material.icons.automirrored.outlined.Notes
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DisabledByDefault
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.AttachFile
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.CloudDone
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material.icons.outlined.CloudSync
import androidx.compose.material.icons.outlined.FilterList
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Inventory2
import androidx.compose.material.icons.outlined.Menu
import androidx.compose.material.icons.outlined.Repeat
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Tag
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Surface
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshDefaults
import androidx.compose.material3.pulltorefresh.pullToRefresh
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.material3.rememberDrawerState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.graphics.toColorInt
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.evsyukov.lists.R
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.DisposableEffect
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import org.evsyukov.lists.DayEvent
import org.evsyukov.lists.SystemCalendars
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import java.time.Duration
import java.time.LocalDateTime
import org.evsyukov.lists.EntryPrefs
import org.evsyukov.lists.str
import org.evsyukov.lists.Repo
import org.evsyukov.lists.dateLabel
import org.evsyukov.lists.dayOf
import org.evsyukov.lists.displayName
import org.evsyukov.lists.marks
import org.evsyukov.lists.plusDays
import org.evsyukov.lists.priorities
import org.evsyukov.lists.rowDate
import org.evsyukov.lists.title
import org.evsyukov.lists.today
import kotlinx.coroutines.launch
import kotlin.math.abs
import uniffi.lists_core.Priority
import uniffi.lists_core.QuickParse
import uniffi.lists_core.SavedFilter
import uniffi.lists_core.Scope
import uniffi.lists_core.TaskItem
import uniffi.lists_core.TaskList

fun parseColor(hex: String): Color? = runCatching { Color(hex.toColorInt()) }.getOrNull()

@Composable
fun TaskList.tint(): Color = parseColor(color) ?: MaterialTheme.colorScheme.primary

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(model: MainViewModel, onReminderSet: () -> Unit) {
    val state by model.state.collectAsStateWithLifecycle()
    val syncing by Repo.syncing.collectAsStateWithLifecycle()
    val events by SystemCalendars.events.collectAsStateWithLifecycle()
    WatchCalendars()
    val drawer = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    val pull = rememberPullToRefreshState()
    // Only a sync asked for by the pull shows the indicator; the ones that run by themselves stay quiet (R27).
    var pulled by remember { mutableStateOf(false) }
    var editingList by remember { mutableStateOf<TaskList?>(null) }
    var creatingList by remember { mutableStateOf(false) }
    var editingFilter by remember { mutableStateOf<SavedFilter?>(null) }
    var creatingFilter by remember { mutableStateOf(false) }
    var settings by remember { mutableStateOf(false) }
    var confirmEmptyTrash by remember { mutableStateOf(false) }
    var clearMenu by remember { mutableStateOf(false) }
    var clearCompleted by remember { mutableStateOf<ClearCompleted?>(null) }
    var duePickerFor by remember { mutableStateOf<TaskItem?>(null) }
    var adding by rememberSaveable { mutableStateOf(false) }
    // R97: what the card held when it was closed, once the person asks for it back.
    var restored by remember { mutableStateOf<NewTaskEntry?>(null) }
    // The bar that offers it; a new card takes the offer away.
    var restoreOffer by remember { mutableStateOf<Job?>(null) }

    LaunchedEffect(state.notice) {
        val notice = state.notice ?: return@LaunchedEffect
        val result = snackbar.showSnackbar(
            notice.text,
            actionLabel = if (notice.undo != null) str(R.string.undo) else null,
            duration = SnackbarDuration.Short,
        )
        if (result == SnackbarResult.ActionPerformed) model.undo(notice)
        model.dismissNotice()
    }

    ModalNavigationDrawer(
        drawerState = drawer,
        drawerContent = {
            Drawer(
                state = state,
                onSelect = { model.select(it); scope.launch { drawer.close() } },
                onEditList = { editingList = it },
                onNewList = { creatingList = true },
                onEditFilter = { editingFilter = it },
                onNewFilter = { creatingFilter = true },
                onSettings = { settings = true; scope.launch { drawer.close() } },
            )
        },
    ) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = {
                        val query = state.search
                        // R95: the title of the view stands at the top of the content; the bar holds the search field only.
                        if (query != null) SearchField(query, model::search)
                    },
                    navigationIcon = {
                        IconButton(onClick = { scope.launch { drawer.open() } }) { Icon(Icons.Outlined.Menu, str(R.string.lists)) }
                    },
                    actions = {
                        if (state.search == null) {
                            IconButton(onClick = { model.search("") }) { Icon(Icons.Outlined.Search, str(R.string.search)) }
                        } else {
                            IconButton(onClick = { model.search(null) }) { Icon(Icons.Outlined.Close, str(R.string.close_search)) }
                        }
                        SyncIcon(state, syncing, model::sync)
                    },
                )
            },
            snackbarHost = { SnackbarHost(snackbar) },
            bottomBar = {
                when {
                    state.effectiveScope == Scope.Trash && state.sections.any { it.tasks.isNotEmpty() } ->
                        Row(Modifier.fillMaxWidth().navigationBarsPadding().padding(8.dp), horizontalArrangement = Arrangement.End) {
                            TextButton(onClick = { confirmEmptyTrash = true }) { Text(str(R.string.empty_trash), color = MaterialTheme.colorScheme.error) }
                        }
                    state.effectiveScope == Scope.Completed && state.sections.any { it.tasks.isNotEmpty() } ->
                        Row(Modifier.fillMaxWidth().navigationBarsPadding().padding(8.dp), horizontalArrangement = Arrangement.End) {
                            Box {
                                TextButton(onClick = { clearMenu = true }) { Text(str(R.string.clear_more), color = MaterialTheme.colorScheme.error) }
                                DropdownMenu(expanded = clearMenu, onDismissRequest = { clearMenu = false }) {
                                    ClearCompleted.entries.forEach { choice ->
                                        DropdownMenuItem(text = { Text(str(choice.title)) }, onClick = { clearMenu = false; clearCompleted = choice })
                                    }
                                }
                            }
                        }
                }
            },
            floatingActionButton = {
                if (!state.readOnly) {
                    FloatingActionButton(
                        onClick = { restoreOffer?.cancel(); restored = null; adding = true },
                        shape = CircleShape,
                        containerColor = viewTint(ViewTint.Blue),
                        contentColor = Color.White,
                    ) { Icon(Icons.Outlined.Add, str(R.string.new_task)) }
                }
            },
        ) { padding ->
            Box(
                Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .pullToRefresh(isRefreshing = pulled, state = pull, enabled = state.sync.configured) {
                        scope.launch {
                            pulled = true
                            Repo.sync()
                            pulled = false
                        }
                    }
                    .edgeSwipe { scope.launch { drawer.open() } },
            ) {
                // R78: the block stands in Today only, and only while there is an event to show.
                val eventsShown = state.effectiveScope == Scope.Today && events.isNotEmpty()
                if (state.loaded && state.sections.all { it.tasks.isEmpty() }) {
                    Column(Modifier.fillMaxSize()) {
                        if (state.search == null) ViewTitle(state)
                        // R78: the events of the day are shown on a day without tasks as well.
                        if (eventsShown) EventsBlock(events)
                        EmptyState(state.effectiveScope)
                    }
                } else {
                    // Room below the last row, so that the add button does not cover it.
                    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 88.dp)) {
                        if (state.search == null) item(key = "title") { ViewTitle(state) }
                        if (eventsShown) item(key = "events") { EventsBlock(events) }
                        for (section in state.sections) {
                            section.title?.let { title ->
                                item(key = "h:${section.key}") {
                                    GroupHeading(title)
                                }
                            }
                            items(section.tasks, key = { "${section.key}:${it.id}" }) { task ->
                                SwipeRow(
                                    task = task,
                                    state = state,
                                    onToggle = { model.toggleDone(task) },
                                    onOpen = { model.open(task.id) },
                                    onPickDue = { duePickerFor = task },
                                    model = model,
                                )
                            }
                        }
                    }
                }
                PullToRefreshDefaults.Indicator(state = pull, isRefreshing = pulled, modifier = Modifier.align(Alignment.TopCenter))
            }
        }
    }

    state.editing?.let { EditorSheet(it, state, model, onReminderSet) }
    if (adding) {
        NewTaskSheet(state, restored, onAdd = model::add) { entry ->
            adding = false
            restored = null
            // R97: closing discards what was entered; for a moment it can be brought back.
            if (entry.hasContent) {
                restoreOffer = scope.launch {
                    if (snackbar.offerRestore()) {
                        restored = entry
                        adding = true
                    }
                }
            }
        }
    }

    duePickerFor?.let { task ->
        MomentDialog(
            title = str(R.string.due),
            value = task.due,
            onPick = { value -> model.act { it.setDue(task.id, value) } },
            onDismiss = { duePickerFor = null },
        )
    }
    editingList?.let { ListDialog(it, model) { editingList = null } }
    if (creatingList) ListDialog(null, model) { creatingList = false }
    editingFilter?.let { FilterDialog(it, state, model) { editingFilter = null } }
    if (creatingFilter) FilterDialog(null, state, model) { creatingFilter = false }
    if (settings) SettingsDialog(model, onReminderSet) { settings = false }
    if (confirmEmptyTrash) {
        AlertDialog(
            onDismissRequest = { confirmEmptyTrash = false },
            title = { Text(str(R.string.empty_trash_question)) },
            text = { Text(str(R.string.cannot_undo)) },
            confirmButton = {
                TextButton(onClick = { confirmEmptyTrash = false; model.act { it.emptyTrash() } }) {
                    Text(str(R.string.empty), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { confirmEmptyTrash = false }) { Text(str(R.string.cancel)) } },
        )
    }
    // Clearing bypasses the trash, so it is confirmed like emptying the trash (R46).
    clearCompleted?.let { choice ->
        AlertDialog(
            onDismissRequest = { clearCompleted = null },
            title = { Text(str(choice.question)) },
            text = { Text(str(R.string.cannot_undo)) },
            confirmButton = {
                TextButton(onClick = { clearCompleted = null; model.act { it.clearCompleted(choice.before()) } }) {
                    Text(str(R.string.clear), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { clearCompleted = null }) { Text(str(R.string.cancel)) } },
        )
    }
}

/** What "Clear…" in Completed removes. */
private enum class ClearCompleted(val title: Int, val question: Int, private val months: Long?) {
    OlderThanMonth(R.string.older_than_month, R.string.clear_month_question, 1),
    OlderThanYear(R.string.older_than_year, R.string.clear_year_question, 12),
    Everything(R.string.everything, R.string.clear_all_question, null);

    /** Tasks completed before this day go; null removes all of them. */
    fun before(): String? = months?.let { java.time.LocalDate.now().minusMonths(it).toString() }
}

@Composable
private fun SearchField(query: String, onChange: (String) -> Unit) {
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    TextField(
        value = query,
        onValueChange = onChange,
        placeholder = { Text(str(R.string.search)) },
        singleLine = true,
        colors = transparentField(),
        modifier = Modifier.fillMaxWidth().focusRequester(focus),
    )
}

/**
 * Free text, a title or a note: the keyboard starts a sentence with a capital
 * when its own setting allows it (R70). A tag and a search leave it out.
 */
val SentenceKeyboard = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences)

@Composable
fun transparentField() = TextFieldDefaults.colors(
    focusedContainerColor = Color.Transparent,
    unfocusedContainerColor = Color.Transparent,
    disabledContainerColor = Color.Transparent,
    focusedIndicatorColor = Color.Transparent,
    unfocusedIndicatorColor = Color.Transparent,
    disabledIndicatorColor = Color.Transparent,
)

/** One quiet icon: nothing when sync is off, a spinner while running, a warning after a failure. */
@Composable
private fun SyncIcon(state: UiState, syncing: Boolean, onSync: () -> Unit) {
    if (!state.sync.configured) return
    IconButton(onClick = onSync) {
        when {
            syncing -> CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
            state.sync.lastError != null -> Icon(Icons.Outlined.CloudOff, str(R.string.sync_failed), tint = MaterialTheme.colorScheme.error)
            state.sync.pending > 0u -> Icon(Icons.Outlined.CloudSync, str(R.string.has_pending))
            state.sync.attachmentsWaiting > 0u -> Icon(Icons.Outlined.CloudSync, str(R.string.attachments_waiting, state.sync.attachmentsWaiting.toString()))
            else -> Icon(Icons.Outlined.CloudDone, str(R.string.synced), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** R78: reads the events again when the app comes back, when the calendars change and when the next day begins. */
@Composable
private fun WatchCalendars() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { scope.launch { SystemCalendars.refresh(context) } }
    LaunchedEffect(Unit) {
        while (true) {
            val now = LocalDateTime.now()
            delay(Duration.between(now, now.toLocalDate().plusDays(1).atStartOfDay()).toMillis() + 1000)
            SystemCalendars.refresh(context)
        }
    }
    val enabled by SystemCalendars.readable.collectAsStateWithLifecycle()
    DisposableEffect(enabled) {
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) { scope.launch { SystemCalendars.refresh(context) } }
        }
        // Without the permission the provider refuses an observer.
        if (enabled) runCatching { context.contentResolver.registerContentObserver(CalendarContract.CONTENT_URI, true, observer) }
        onDispose { context.contentResolver.unregisterContentObserver(observer) }
    }
}

/** The events of the day above the tasks of Today (R78): muted, without a mark, because an event is not a task. */
@Composable
private fun EventsBlock(events: List<DayEvent>) {
    val context = LocalContext.current
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
            .padding(vertical = 4.dp),
    ) {
        for (event in events) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .clickable { runCatching { context.startActivity(SystemCalendars.view(event)) } }
                    .padding(horizontal = 12.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.width(3.dp).height(16.dp).background(Color(event.color), RoundedCornerShape(2.dp)))
                event.time?.let {
                    Text(it, Modifier.padding(start = 8.dp), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Text(
                    event.title,
                    Modifier.padding(start = 8.dp),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun EmptyState(scope: Scope) {
    val (title, text) = when (scope) {
        Scope.Today -> str(R.string.empty_today) to str(R.string.empty_today_hint)
        Scope.Inbox -> str(R.string.empty_inbox) to str(R.string.empty_inbox_hint)
        Scope.Upcoming -> str(R.string.empty_upcoming) to str(R.string.empty_upcoming_hint)
        Scope.Completed -> str(R.string.empty_completed) to ""
        Scope.WontDo -> str(R.string.empty_wont_do) to ""
        Scope.Trash -> str(R.string.empty_trash_view) to ""
        is Scope.Search -> str(R.string.empty_search) to ""
        else -> str(R.string.empty_list) to str(R.string.empty_list_hint)
    }
    // Scrollable, so that the pull to sync has something to pull in an empty view (R67).
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        if (text.isNotEmpty()) {
            Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 4.dp))
        }
    }
}

/** R97: how long the bar that brings a closed card back stays. */
const val RESTORE_MILLIS = 3000L

/** Shows "Draft discarded" with "Restore" for [RESTORE_MILLIS] and says whether the person asked for the card back. */
private suspend fun SnackbarHostState.offerRestore(): Boolean = coroutineScope {
    val message = str(R.string.draft_discarded)
    // Counted from the moment the bar is on screen: another one may be showing before it.
    val timer = launch {
        snapshotFlow { currentSnackbarData?.visuals?.message }.first { it == message }
        delay(RESTORE_MILLIS)
        currentSnackbarData?.dismiss()
    }
    val result = showSnackbar(message, actionLabel = str(R.string.restore), duration = SnackbarDuration.Indefinite)
    timer.cancel()
    result == SnackbarResult.ActionPerformed
}

/**
 * The new-task card over the list. It stays open after a task is added, for
 * the next one; back, a tap outside or a drag down closes it and hands over
 * what it held (R97).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NewTaskSheet(state: UiState, restored: NewTaskEntry?, onAdd: (TaskDraft) -> Unit, onDismiss: (NewTaskEntry) -> Unit) {
    val context = LocalContext.current
    val entry = rememberSaveable(saver = NewTaskEntry.Saver) { restored ?: NewTaskEntry(listId = state.newTaskListId()) }
    // No width limit: expanded, the card takes the whole screen (R64).
    ModalBottomSheet(
        onDismissRequest = { onDismiss(entry) },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        sheetMaxWidth = Dp.Unspecified,
        dragHandle = { CardHandle(entry) },
    ) {
        NewTaskCard(
            lists = state.lists.filter { !it.archived },
            listId = entry.listId,
            parse = EntryPrefs.parse(context),
            onSubmit = onAdd,
            modifier = Modifier.navigationBarsPadding().padding(start = 8.dp, end = 8.dp, bottom = 8.dp),
            keepOpen = true,
            entry = entry,
        )
    }
}

/**
 * The handle of the new-task card (R97): a drag up expands the card, a drag
 * down collapses an expanded one. A drag down on a compact card is left to
 * the sheet, which closes.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CardHandle(entry: NewTaskEntry) {
    Box(
        Modifier.fillMaxWidth().pointerInput(entry) {
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false)
                val wasExpanded = entry.expanded
                var dy = 0f
                var decided = false
                while (true) {
                    val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                    if (!change.pressed) break
                    dy += change.positionChange().y
                    if (!decided && abs(dy) > viewConfiguration.touchSlop) {
                        decided = true
                        if (dy < 0) entry.expanded = true else if (wasExpanded) entry.expanded = false
                    }
                    // Kept from the sheet, or it would follow the finger and close a card that only changes its size.
                    if (dy < 0 || wasExpanded) change.consume()
                }
            }
        },
        contentAlignment = Alignment.Center,
    ) {
        // Expanded, the card reaches the top of the screen: the handle stays below the status bar,
        // where a drag belongs to the system.
        BottomSheetDefaults.DragHandle(if (entry.expanded) Modifier.statusBarsPadding() else Modifier)
    }
}

/** What the quick-entry parser recognised in the line being typed. */
@Composable
fun QuickChips(text: String, modifier: Modifier = Modifier) {
    if (text.isBlank() || !EntryPrefs.parse(LocalContext.current)) return
    val parsed: QuickParse = remember(text) { Repo.store.parseQuick(text) }
    val parts = buildList {
        parsed.due?.let { add(dateLabel(it)) }
        if (parsed.priority != Priority.NONE) add(parsed.priority.marks())
        parsed.tags.forEach { add("#$it") }
        parsed.listName?.let { add("@$it") }
    }
    if (parts.isEmpty()) return
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        for (part in parts) Pill(part)
    }
}

@Composable
fun Pill(text: String, color: Color = MaterialTheme.colorScheme.primary) {
    Text(
        text,
        style = MaterialTheme.typography.labelMedium,
        color = color,
        maxLines = 1,
        modifier = Modifier.clip(CircleShape).background(color.copy(alpha = 0.12f)).padding(horizontal = 8.dp, vertical = 2.dp),
    )
}

/**
 * R65: a swipe to the right that starts in the strip at the left edge opens
 * the list panel. The rows would take it as "complete" otherwise, so the
 * movement is watched before they see it and kept from them once it is a swipe.
 * Taps, long presses, scrolling and swipes to the left pass through untouched.
 */
private fun Modifier.edgeSwipe(onSwipe: () -> Unit) = pointerInput(Unit) {
    val strip = 56.dp.toPx()
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
        if (down.position.x > strip) return@awaitEachGesture
        var dx = 0f
        var dy = 0f
        var taken = false
        while (true) {
            val change = awaitPointerEvent(PointerEventPass.Initial).changes.firstOrNull { it.id == down.id } ?: break
            if (!change.pressed) break
            dx += change.positionChange().x
            dy += change.positionChange().y
            if (!taken) {
                // The list scrolls: the gesture is not ours.
                if (abs(dy) > viewConfiguration.touchSlop && abs(dy) > abs(dx)) break
                if (dx > viewConfiguration.touchSlop) {
                    taken = true
                    onSwipe()
                }
            }
            if (taken) change.consume()
        }
    }
}

/** Swipe right to complete, left to set the due date. Neither removes the row by itself. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SwipeRow(task: TaskItem, state: UiState, onToggle: () -> Unit, onOpen: () -> Unit, onPickDue: () -> Unit, model: MainViewModel) {
    val locked = task.deleted || task.isLog
    val swipe = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            when (value) {
                SwipeToDismissBoxValue.StartToEnd -> onToggle()
                SwipeToDismissBoxValue.EndToStart -> onPickDue()
                SwipeToDismissBoxValue.Settled -> {}
            }
            false
        },
    )
    SwipeToDismissBox(
        state = swipe,
        enableDismissFromStartToEnd = !locked,
        enableDismissFromEndToStart = !locked,
        backgroundContent = {
            val toEnd = swipe.dismissDirection == SwipeToDismissBoxValue.StartToEnd
            // R95: a coloured tile with the icon of the action.
            Row(
                Modifier.fillMaxSize().background(viewTint(if (toEnd) ViewTint.Green else ViewTint.Yellow)).padding(horizontal = 20.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = if (toEnd) Arrangement.Start else Arrangement.End,
            ) {
                Icon(if (toEnd) Icons.Outlined.Check else Icons.Outlined.CalendarMonth, null, tint = if (toEnd) Color.White else Color.Black)
            }
        },
    ) {
        Surface { TaskRow(task, state, onToggle, onOpen, model, showOrigin = state.showsOrigin()) }
    }
}

private fun UiState.showsOrigin(): Boolean = when (effectiveScope) {
    Scope.Today, Scope.Upcoming, Scope.Completed, Scope.WontDo, Scope.Trash, is Scope.Tag, is Scope.Search, is Scope.Filter -> true
    else -> false
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TaskRow(
    task: TaskItem,
    state: UiState,
    onToggle: () -> Unit,
    onOpen: () -> Unit,
    model: MainViewModel,
    showOrigin: Boolean,
    // A subtask in the card of its task (R96): a round mark, and grey without a strike when it is done.
    subtask: Boolean = false,
) {
    var menu by remember { mutableStateOf(false) }
    val done = task.done != null
    Row(
        Modifier
            .fillMaxWidth()
            .combinedClickable(onClick = onOpen, onLongClick = { menu = true })
            .padding(start = 4.dp, end = 16.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onToggle, enabled = !task.deleted && !task.isLog) {
            Mark(task.markState(), if (done) str(R.string.reopen) else str(R.string.complete), round = subtask)
        }
        if (task.isProject) {
            Icon(Icons.Outlined.Folder, str(R.string.project), Modifier.padding(end = 6.dp).size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (task.priority != Priority.NONE) {
            Text(
                task.priority.marks(),
                color = PriorityColor,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(end = 6.dp).semantics { contentDescription = task.priority.title() },
            )
        }
        // The title gives way to the marks and the date: it is what gets the ellipsis (R73).
        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
            Text(
                task.title,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textDecoration = if (done && !subtask) TextDecoration.LineThrough else null,
                color = when {
                    !done -> MaterialTheme.colorScheme.onSurface
                    subtask -> MaterialTheme.colorScheme.outline
                    else -> MaterialTheme.colorScheme.onSurfaceVariant
                },
                modifier = Modifier.weight(1f, fill = false),
            )
            Marks(task, parent = task.parentTitle.takeIf { showOrigin })
        }
        val scope = state.effectiveScope
        val dayInHeading = scope == Scope.Upcoming || (scope == Scope.Today && task.due?.let(::dayOf) == today())
        rowDate(task.due, open = !done, dayInHeading = dayInHeading)?.let { (text, late) ->
            Text(
                text,
                style = MaterialTheme.typography.bodySmall,
                color = if (late) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                modifier = Modifier.padding(start = 8.dp),
            )
        }
        Box {
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                TaskMenu(task, state, model, onOpen) { menu = false }
            }
        }
    }
}

fun TaskItem.markState(): MarkState = when {
    wont -> MarkState.Wont
    done != null -> MarkState.Done
    else -> MarkState.Open
}

/** Marks after the title, only for what is set, without text or numbers (R72); then the parent of a subtask shown on its own (R12). */
@Composable
private fun Marks(task: TaskItem, parent: String?) {
    val muted = MaterialTheme.colorScheme.outline
    val marks = buildList {
        if (task.repeat != null) add(Icons.Outlined.Repeat to str(R.string.repeat))
        if (task.notes.isNotEmpty()) add(Icons.AutoMirrored.Outlined.Notes to str(R.string.notes))
        if (task.attachments > 0u) add(Icons.Outlined.AttachFile to str(R.string.attachments))
        if (task.subtasksTotal > 0u) add(Icons.Outlined.Checklist to str(R.string.subtasks))
    }
    for ((icon, name) in marks) Icon(icon, name, Modifier.padding(start = 6.dp).size(16.dp), tint = muted)
    if (parent != null) {
        Text(parent, Modifier.padding(start = 8.dp).widthIn(max = 120.dp), style = MaterialTheme.typography.bodySmall, color = muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** The whole context menu: six actions, the rest lives in the editor. */
@Composable
private fun TaskMenu(task: TaskItem, state: UiState, model: MainViewModel, onOpen: () -> Unit, close: () -> Unit) {
    var sub by remember { mutableStateOf<String?>(null) }
    fun run(action: () -> Unit) {
        close()
        action()
    }
    when {
        task.deleted -> DropdownMenuItem(text = { Text(str(R.string.restore)) }, onClick = { run { model.act { it.restoreTask(task.id) } } })
        task.isLog -> DropdownMenuItem(text = { Text(str(R.string.delete_record)) }, onClick = { run { model.delete(task) } })
        sub == "due" -> {
            DropdownMenuItem(text = { Text(str(R.string.today)) }, onClick = { run { model.act { it.setDue(task.id, today()) } } })
            DropdownMenuItem(text = { Text(str(R.string.tomorrow)) }, onClick = { run { model.act { it.setDue(task.id, plusDays(1)) } } })
            DropdownMenuItem(text = { Text(str(R.string.in_a_week)) }, onClick = { run { model.act { it.setDue(task.id, plusDays(7)) } } })
            if (task.due != null) DropdownMenuItem(text = { Text(str(R.string.clear_due)) }, onClick = { run { model.act { it.setDue(task.id, null) } } })
        }
        sub == "priority" -> priorities.forEach { priority ->
            DropdownMenuItem(
                text = { Text(priority.title(), fontWeight = if (priority == task.priority) FontWeight.Bold else null) },
                onClick = { run { model.act { it.setPriority(task.id, priority) } } },
            )
        }
        sub == "list" -> state.lists.filter { !it.archived }.forEach { list ->
            DropdownMenuItem(
                text = { Text(list.displayName()) },
                enabled = !(task.parentId == null && task.listId == list.id),
                onClick = { run { model.act { it.moveToList(task.id, list.id) } } },
            )
        }
        else -> {
            DropdownMenuItem(text = { Text(str(R.string.due)) }, onClick = { sub = "due" })
            DropdownMenuItem(text = { Text(str(R.string.priority)) }, onClick = { sub = "priority" })
            DropdownMenuItem(text = { Text(str(R.string.move_to_list)) }, onClick = { sub = "list" })
            DropdownMenuItem(text = { Text(str(R.string.add_subtask)) }, onClick = { run(onOpen) })
            if (task.parentId == null) {
                DropdownMenuItem(
                    text = { Text(str(if (task.isProject) R.string.project_off else R.string.project_on)) },
                    onClick = { run { model.act { it.setProject(task.id, !task.isProject) } } },
                )
            }
            DropdownMenuItem(text = { Text(str(R.string.duplicate)) }, onClick = { run { model.act { it.duplicateTask(task.id) } } })
            if (task.done == null) {
                DropdownMenuItem(text = { Text(str(R.string.wont_do)) }, onClick = { run { model.wontDo(task) } })
            }
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text(str(R.string.delete), color = MaterialTheme.colorScheme.error) },
                onClick = { run { model.delete(task) } },
            )
        }
    }
}

@Composable
private fun Drawer(
    state: UiState,
    onSelect: (Scope) -> Unit,
    onEditList: (TaskList) -> Unit,
    onNewList: () -> Unit,
    onEditFilter: (SavedFilter) -> Unit,
    onNewFilter: () -> Unit,
    onSettings: () -> Unit,
) {
    ModalDrawerSheet {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 8.dp)) {
            val inbox = state.list("inbox")
            DrawerItem(str(R.string.inbox), Icons.Filled.Inbox, state.counts.inbox, state.scope == Scope.Inbox, tint = viewTint(ViewTint.Blue), onLong = inbox?.let { { onEditList(it) } }) { onSelect(Scope.Inbox) }
            DrawerItem(str(R.string.today), Icons.Filled.Star, state.counts.today, state.scope == Scope.Today, alert = state.counts.overdue > 0u, tint = viewTint(ViewTint.Yellow)) { onSelect(Scope.Today) }
            DrawerItem(str(R.string.upcoming), Icons.Filled.CalendarMonth, state.counts.upcoming, state.scope == Scope.Upcoming, tint = viewTint(ViewTint.Pink)) { onSelect(Scope.Upcoming) }
            DrawerItem(str(R.string.all), Icons.Filled.Layers, 0u, state.scope == Scope.All, tint = viewTint(ViewTint.Teal)) { onSelect(Scope.All) }
            DrawerItem(str(R.string.completed), Icons.Filled.CheckBox, 0u, state.scope == Scope.Completed, tint = viewTint(ViewTint.Green)) { onSelect(Scope.Completed) }
            DrawerItem(str(R.string.wont_do), Icons.Filled.DisabledByDefault, 0u, state.scope == Scope.WontDo, tint = viewTint(ViewTint.Gray)) { onSelect(Scope.WontDo) }
            if (state.counts.trash > 0u) {
                DrawerItem(str(R.string.trash), Icons.Filled.Delete, state.counts.trash, state.scope == Scope.Trash, tint = viewTint(ViewTint.Gray)) { onSelect(Scope.Trash) }
            }

            DrawerHeading(str(R.string.lists))
            for (list in state.lists.filter { it.id != "inbox" && !it.archived }) {
                val scope = Scope.List(list.id)
                DrawerItem(list.name, Icons.AutoMirrored.Outlined.List, list.openCount, state.scope == scope, tint = list.tint(), onLong = { onEditList(list) }) { onSelect(scope) }
            }
            DrawerItem(str(R.string.new_list), Icons.Outlined.Add, 0u, false, onClick = onNewList)

            if (state.projects.isNotEmpty()) {
                DrawerHeading(str(R.string.projects))
                for (project in state.projects) {
                    val scope = Scope.Project(project.id)
                    DrawerItem(
                        project.title, Icons.Outlined.Folder, project.subtasksTotal - project.subtasksDone, state.scope == scope,
                        tint = state.list(project.listId)?.tint(),
                    ) { onSelect(scope) }
                }
            }
            DrawerHeading(str(R.string.filters))
            for (filter in state.filters) {
                val scope = Scope.Filter(filter.id)
                DrawerItem(filter.name, Icons.Outlined.FilterList, filter.openCount, state.scope == scope, onLong = { onEditFilter(filter) }) { onSelect(scope) }
            }
            DrawerItem(str(R.string.new_filter), Icons.Outlined.Add, 0u, false, onClick = onNewFilter)

            if (state.tags.isNotEmpty()) {
                DrawerHeading(str(R.string.tags))
                for (tag in state.tags) {
                    val scope = Scope.Tag(tag.name)
                    DrawerItem(tag.name, Icons.Outlined.Tag, tag.openCount, state.scope == scope) { onSelect(scope) }
                }
            }
            val archived = state.lists.filter { it.archived }
            if (archived.isNotEmpty()) {
                DrawerHeading(str(R.string.archive))
                for (list in archived) {
                    DrawerItem(list.name, Icons.Outlined.Inventory2, 0u, false, onLong = { onEditList(list) }) { onEditList(list) }
                }
            }
            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            DrawerItem(str(R.string.settings), Icons.Outlined.Settings, 0u, false, onClick = onSettings)
        }
    }
}

@Composable
private fun DrawerHeading(text: String) {
    Text(text, Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** A row of the panel of lists. A long press opens the settings of what it shows; there is no gear at the row (R95). */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DrawerItem(
    label: String,
    icon: ImageVector,
    count: UInt,
    selected: Boolean,
    alert: Boolean = false,
    tint: Color? = null,
    onLong: (() -> Unit)? = null,
    onClick: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .height(56.dp)
            .clip(CircleShape)
            .background(if (selected) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent)
            .combinedClickable(
                role = Role.Tab,
                onLongClickLabel = if (onLong != null) str(R.string.configure) else null,
                onLongClick = onLong,
                onClick = onClick,
            )
            .semantics { this.selected = selected }
            .padding(start = 16.dp, end = 24.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = tint ?: MaterialTheme.colorScheme.onSurfaceVariant)
        Text(
            label,
            Modifier.weight(1f).padding(horizontal = 12.dp),
            style = MaterialTheme.typography.labelLarge,
            color = if (selected) MaterialTheme.colorScheme.onSecondaryContainer else MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (count > 0u) {
            Text("$count", style = MaterialTheme.typography.labelLarge, color = if (alert) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** R95: the large title of the view with its icon, at the top of the content. */
@Composable
private fun ViewTitle(state: UiState) {
    val plain = MaterialTheme.colorScheme.onSurfaceVariant
    val (icon, tint) = when (val scope = state.scope) {
        Scope.Inbox -> Icons.Filled.Inbox to viewTint(ViewTint.Blue)
        Scope.Today -> Icons.Filled.Star to viewTint(ViewTint.Yellow)
        Scope.Upcoming -> Icons.Filled.CalendarMonth to viewTint(ViewTint.Pink)
        Scope.All -> Icons.Filled.Layers to viewTint(ViewTint.Teal)
        Scope.Completed -> Icons.Filled.CheckBox to viewTint(ViewTint.Green)
        Scope.WontDo -> Icons.Filled.DisabledByDefault to viewTint(ViewTint.Gray)
        Scope.Trash -> Icons.Filled.Delete to viewTint(ViewTint.Gray)
        is Scope.List -> Icons.AutoMirrored.Outlined.List to (state.list(scope.id)?.tint() ?: plain)
        is Scope.Project -> Icons.Outlined.Folder to (state.projects.firstOrNull { it.id == scope.id }?.let { state.list(it.listId)?.tint() } ?: plain)
        is Scope.Filter -> Icons.Outlined.FilterList to plain
        is Scope.Tag -> Icons.Outlined.Tag to plain
        is Scope.Search -> Icons.Outlined.Search to plain
    }
    Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(28.dp), tint = tint)
        Text(
            state.title,
            Modifier.padding(start = 10.dp).semantics { heading() },
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.Bold,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** R95: the heading of a group, in the colour of text with a thin line under it. */
@Composable
private fun GroupHeading(title: String) {
    Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 4.dp)) {
        Text(title, Modifier.semantics { heading() }, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
        HorizontalDivider(Modifier.padding(top = 6.dp), color = MaterialTheme.colorScheme.outlineVariant)
    }
}
