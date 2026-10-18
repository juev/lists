package org.evsyukov.lists.ui

import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animate
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.DriveFileMove
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
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
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.FilterList
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Inventory2
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.Menu
import androidx.compose.material.icons.outlined.MoreHoriz
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Repeat
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Tag
import androidx.compose.material3.AlertDialog
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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.onLongClick
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import androidx.core.graphics.toColorInt
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import org.evsyukov.lists.DayEvent
import org.evsyukov.lists.EntryPrefs
import org.evsyukov.lists.LookPrefs
import org.evsyukov.lists.R
import org.evsyukov.lists.Repo
import org.evsyukov.lists.SystemCalendars
import org.evsyukov.lists.dateLabel
import org.evsyukov.lists.dayOf
import org.evsyukov.lists.displayName
import org.evsyukov.lists.fromStore
import org.evsyukov.lists.marks
import org.evsyukov.lists.plusDays
import org.evsyukov.lists.priorities
import org.evsyukov.lists.rowDate
import org.evsyukov.lists.str
import org.evsyukov.lists.title
import org.evsyukov.lists.today
import org.evsyukov.lists.ui.theme.Corners
import org.evsyukov.lists.ui.theme.Sizes
import org.evsyukov.lists.ui.theme.Space
import org.evsyukov.lists.ui.theme.ViewTint
import org.evsyukov.lists.ui.theme.groupHeading
import org.evsyukov.lists.ui.theme.label
import org.evsyukov.lists.ui.theme.pill
import org.evsyukov.lists.ui.theme.rowMeta
import org.evsyukov.lists.ui.theme.sectionHeading
import org.evsyukov.lists.ui.theme.viewTint
import org.evsyukov.lists.ui.theme.viewTitle
import uniffi.lists_core.Priority
import uniffi.lists_core.QuickParse
import uniffi.lists_core.SavedFilter
import uniffi.lists_core.Scope
import uniffi.lists_core.TaskItem
import uniffi.lists_core.TaskList
import java.time.Duration
import java.time.LocalDateTime
import kotlin.math.abs
import kotlin.math.roundToInt

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
    var creatingProject by remember { mutableStateOf(false) }
    // Saved: choosing a text size rebuilds the activity, and the settings stay open over it (R100).
    var settings by rememberSaveable { mutableStateOf(false) }
    var confirmEmptyTrash by remember { mutableStateOf(false) }
    var clearMenu by remember { mutableStateOf(false) }
    var clearCompleted by remember { mutableStateOf<ClearCompleted?>(null) }
    var duePickerFor by remember { mutableStateOf<TaskItem?>(null) }
    // R109: the selection mode and the dialog of the action that asks for a value.
    val selection = state.selection
    val selecting = selection != null
    var batchDialog by remember { mutableStateOf<String?>(null) }
    val rows = rememberLazyListState()
    // R157: the row being dragged; a view of its own starts with none.
    val reorder = remember(state.scope) { Reorder() }
    BackHandler(enabled = selecting) { model.endSelection() }
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
        gesturesEnabled = !selecting,
        drawerContent = {
            Drawer(
                state = state,
                onSelect = { model.select(it); scope.launch { drawer.close() } },
                onEditList = { editingList = it },
                onMoveList = model::moveList,
                onNewList = { creatingList = true },
                onEditFilter = { editingFilter = it },
                onNewFilter = { creatingFilter = true },
                onNewProject = { creatingProject = true },
                onProjectOff = { project -> model.change { it.setProject(project.id, false) } },
                // The drawer closes so that the bar with Undo is in reach (R126).
                onProjectDone = { project -> model.completeProject(project); scope.launch { drawer.close() } },
                onSettings = { settings = true; scope.launch { drawer.close() } },
            )
        },
    ) {
        Scaffold(
            topBar = {
                if (selection != null) {
                    TopAppBar(
                        title = { Text(str(R.string.selected_count, selection.size.toString()), style = MaterialTheme.typography.titleMedium) },
                        navigationIcon = {
                            IconButton(onClick = model::endSelection) { Icon(Icons.Outlined.Close, str(R.string.close)) }
                        },
                        actions = { TextButton(onClick = model::endSelection) { Text(str(R.string.done)) } },
                    )
                } else TopAppBar(
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
                        val configured = state.configured
                        // R131: Undo stays in the menu while there is something to take back, after the bar is gone.
                        if (configured != null || state.canUndo) {
                            ViewMenu(
                                onUndo = model::undoLast.takeIf { state.canUndo },
                                onConfigure = configured?.let {
                                    {
                                        when (it) {
                                            is Configured.OfList -> editingList = it.list
                                            is Configured.OfFilter -> editingFilter = it.filter
                                        }
                                    }
                                },
                            )
                        }
                    },
                )
            },
            snackbarHost = { SnackbarHost(snackbar) },
            bottomBar = {
                when {
                    selection != null -> SelectionBar(
                        enabled = selection.isNotEmpty(),
                        actions = selectionActions(state.sections.flatMap { it.tasks }.filter { it.id in selection }),
                    ) { action ->
                        when (action) {
                            "complete" -> model.batch(BatchAction.Complete)
                            "restore" -> model.batch(BatchAction.Restore)
                            "delete" -> model.batch(BatchAction.Delete)
                            "wont" -> model.batch(BatchAction.WontDo)
                            else -> batchDialog = action
                        }
                    }
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
                if (!state.readOnly && !selecting) {
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
                    .pullToRefresh(isRefreshing = pulled, state = pull, enabled = state.sync.configured && !selecting) {
                        scope.launch {
                            pulled = true
                            Repo.sync()
                            pulled = false
                        }
                    }
                    .then(
                        if (selecting) Modifier.dragSelect(rows, model::startDrag, model::dragSelection)
                        else Modifier.edgeSwipe { scope.launch { drawer.open() } }
                    ),
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
                    // R157: a row of a view sorted by hand is dragged to its place; the store learns the place when it is let go.
                    val reorderable = state.reorderable()
                    LaunchedEffect(state.sections) { reorder.forget() }
                    // While a row is dragged, a row held at an edge scrolls the column, frame by frame.
                    LaunchedEffect(reorder.dragging) {
                        val section = state.sections.firstOrNull() ?: return@LaunchedEffect
                        while (reorder.dragging != null) {
                            withFrameNanos {}
                            reorder.autoscroll(rows) { rowKey(section.key, it) }
                        }
                    }
                    LazyColumn(Modifier.fillMaxSize(), state = rows, contentPadding = PaddingValues(bottom = 88.dp)) {
                        if (state.search == null) item(key = "title") { ViewTitle(state) }
                        if (eventsShown) item(key = "events") { EventsBlock(events) }
                        for (section in state.sections) {
                            section.title?.let { title ->
                                item(key = "h:${section.key}") {
                                    GroupHeading(title)
                                }
                            }
                            val shown = reorder.order?.takeIf { reorderable }
                                ?.mapNotNull { id -> section.tasks.firstOrNull { it.id == id } }
                                ?.takeIf { it.size == section.tasks.size } ?: section.tasks
                            items(shown, key = { rowKey(section.key, it.id) }) { task ->
                                val drag = if (reorderable) {
                                    RowDrag(
                                        onStart = { reorder.start(task.id, section.tasks.map { it.id }) },
                                        onDrag = { dy -> reorder.drag(dy, rows) { rowKey(section.key, it) } },
                                        onEnd = { slop -> reorder.drop(slop).also { if (it is Dropped.Moved) model.moveTask(it.id, it.after) } },
                                        onCancel = reorder::cancel,
                                    )
                                } else null
                                val lifted = reorder.dragging == task.id
                                // One item for the row and its lines: the drag over the circles reads the task from the item (R109).
                                Column(
                                    if (lifted) Modifier.zIndex(1f).graphicsLayer { translationY = reorder.offset; shadowElevation = 8f }
                                    else Modifier.animateItem(),
                                ) {
                                    if (selection != null) {
                                        Surface {
                                            TaskRow(
                                                task, state, onToggle = {}, onOpen = {}, menu = {}, showOrigin = state.showsOrigin(),
                                                selected = task.id in selection, onSelect = { model.toggleSelected(task.id) },
                                            )
                                        }
                                    } else SwipeRow(
                                        task = task,
                                        state = state,
                                        onToggle = { model.toggleDone(task) },
                                        onOpen = { model.open(task.id) },
                                        onPickDue = { duePickerFor = task },
                                        model = model,
                                        drag = drag,
                                    )
                                    // R22: the subtasks the search found the task by.
                                    state.found[task.id]?.forEach { FoundSubtask(it) }
                                }
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
            onPick = { value -> model.change { it.setDue(task.id, value) } },
            onDismiss = { duePickerFor = null },
        )
    }
    when (batchDialog) {
        "due" -> MomentDialog(str(R.string.due), null, onPick = { value -> value?.let { model.batch(BatchAction.Due(it)) } }) { batchDialog = null }
        "start" -> MomentDialog(str(R.string.start_title), null, onPick = { value -> value?.let { model.batch(BatchAction.Start(it)) } }) { batchDialog = null }
        "list" -> DestinationDialog(str(R.string.move_to_list), state.lists.filter { !it.archived }, state.projects, null, { batchDialog = null }) { to ->
            when (to) {
                is Destination.ToList -> model.batch(BatchAction.MoveTo(to.id))
                is Destination.ToProject -> model.batch(BatchAction.MoveToProject(to.id))
            }
        }
        "priority" -> ChoiceDialog(str(R.string.priority), priorities.map { it.title() }, -1, { batchDialog = null }) {
            model.batch(BatchAction.SetPriority(priorities[it]))
        }
        "tag" -> TagDialog(state.tags.map { it.name }, { batchDialog = null }) { model.batch(BatchAction.Tag(it)) }
    }
    editingList?.let { ListDialog(it, model) { editingList = null } }
    if (creatingList) ListDialog(null, model) { creatingList = false }
    editingFilter?.let { FilterDialog(it, state, model) { editingFilter = null } }
    if (creatingFilter) FilterDialog(null, state, model) { creatingFilter = false }
    // R127: the view of the new project opens, so the drawer makes way for it.
    if (creatingProject) ProjectDialog({ creatingProject = false }) { model.createProject(it); scope.launch { drawer.close() } }
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

/** R105: the menu of the open view; Configure opens the settings a long press on its row in the panel opens (R95). Undo takes back the last action (R131). */
@Composable
private fun ViewMenu(onUndo: (() -> Unit)?, onConfigure: (() -> Unit)?) {
    var menu by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { menu = true }) { Icon(Icons.Outlined.MoreVert, str(R.string.more)) }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (onUndo != null) DropdownMenuItem(text = { Text(str(R.string.undo)) }, onClick = { menu = false; onUndo() })
            if (onConfigure != null) DropdownMenuItem(text = { Text(str(R.string.configure)) }, onClick = { menu = false; onConfigure() })
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
private fun NewTaskSheet(state: UiState, restored: NewTaskEntry?, onAdd: suspend (TaskDraft) -> Boolean, onDismiss: (NewTaskEntry) -> Unit) {
    val context = LocalContext.current
    val entry = rememberSaveable(saver = NewTaskEntry.Saver) { restored ?: NewTaskEntry(listId = state.newTaskListId()).apply { projectId = (state.scope as? Scope.Project)?.id } }
    // No width limit: expanded, the card takes the whole screen (R64).
    ModalBottomSheet(
        onDismissRequest = { onDismiss(entry) },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        sheetMaxWidth = Dp.Unspecified,
        dragHandle = {
            CardHandle(entry.expanded, { entry.expanded = it }, if (entry.expanded) Modifier.statusBarsPadding() else Modifier)
        },
    ) {
        NewTaskCard(
            lists = state.lists.filter { !it.archived },
            listId = entry.listId,
            projects = state.projects,
            parse = EntryPrefs.parse(context),
            onSubmit = onAdd,
            modifier = Modifier.navigationBarsPadding().padding(start = 8.dp, end = 8.dp, bottom = 8.dp),
            keepOpen = true,
            entry = entry,
        )
    }
}

/** What the quick-entry parser recognised in the line being typed. */
@Composable
fun QuickChips(text: String, modifier: Modifier = Modifier) {
    if (text.isBlank() || !EntryPrefs.parse(LocalContext.current)) return
    val parsed: QuickParse = fromStore(text) { it.parseQuick(text) } ?: return
    val parts = buildList {
        parsed.due?.let { add(dateLabel(it)) }
        if (parsed.priority != Priority.NONE) add(parsed.priority.marks())
        parsed.tags.forEach { add("#$it") }
        parsed.listName?.let { add("@$it") }
    }
    if (parts.isEmpty()) return
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
        for (part in parts) Pill(part)
    }
}

@Composable
fun Pill(text: String, color: Color = MaterialTheme.colorScheme.primary) {
    Text(
        text,
        style = MaterialTheme.typography.pill,
        color = color,
        maxLines = 1,
        modifier = Modifier.clip(Corners.round).background(color.copy(alpha = 0.12f)).padding(horizontal = Space.m, vertical = 2.dp),
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

/** What letting go of a swipe does (R132): it acts only past the threshold, however fast the finger moved. */
enum class Swipe { Complete, Due }

/** The share of the width of the row a swipe has to pass to act (R132). */
const val SWIPE_THRESHOLD = 0.4f

fun swipeAction(offset: Float, width: Float): Swipe? = when {
    width <= 0f -> null
    offset >= width * SWIPE_THRESHOLD -> Swipe.Complete
    offset <= -width * SWIPE_THRESHOLD -> Swipe.Due
    else -> null
}

/**
 * Swipe right to complete, left to set the due date. Neither removes the row by itself. R132: the icon under the row
 * grows pale with the finger and turns bright with a vibration at the threshold; only letting go past it acts.
 */
@Composable
private fun SwipeRow(task: TaskItem, state: UiState, onToggle: () -> Unit, onOpen: () -> Unit, onPickDue: () -> Unit, model: MainViewModel, drag: RowDrag? = null) {
    val locked = task.deleted || task.isLog
    // The drag keeps the callback it was made with: it must reach the task as it is now, not as it was then.
    val toggle by rememberUpdatedState(onToggle)
    val pickDue by rememberUpdatedState(onPickDue)
    var width by remember { mutableIntStateOf(0) }
    var offset by remember { mutableFloatStateOf(0f) }
    val armed = swipeAction(offset, width.toFloat()) != null
    val haptic = LocalHapticFeedback.current
    LaunchedEffect(armed) { if (armed) haptic.performHapticFeedback(HapticFeedbackType.GestureThresholdActivate) }
    Box(Modifier.fillMaxWidth().onSizeChanged { width = it.width }.clipToBounds()) {
        if (offset != 0f) {
            val toEnd = offset > 0
            val progress = if (width > 0) (abs(offset) / (width * SWIPE_THRESHOLD)).coerceIn(0f, 1f) else 0f
            // R95: a coloured tile with the icon of the action, pale until the swipe would act.
            Row(
                Modifier.matchParentSize()
                    .background(viewTint(if (toEnd) ViewTint.Green else ViewTint.Yellow).copy(alpha = if (armed) 1f else 0.25f))
                    .padding(horizontal = 20.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = if (toEnd) Arrangement.Start else Arrangement.End,
            ) {
                Icon(
                    if (toEnd) Icons.Outlined.Check else Icons.Outlined.CalendarMonth,
                    null,
                    tint = (if (toEnd && armed) Color.White else Color.Black).copy(alpha = if (armed) 1f else 0.2f + 0.5f * progress),
                    modifier = Modifier.scale(if (armed) 1.3f else 0.6f + 0.4f * progress),
                )
            }
        }
        Surface(
            Modifier
                .offset { IntOffset(offset.roundToInt(), 0) }
                .then(
                    if (locked) Modifier
                    else Modifier.draggable(
                        orientation = Orientation.Horizontal,
                        state = rememberDraggableState { delta -> offset += delta },
                        onDragStopped = {
                            when (swipeAction(offset, width.toFloat())) {
                                Swipe.Complete -> toggle()
                                Swipe.Due -> pickDue()
                                null -> {}
                            }
                            animate(offset, 0f) { value, _ -> offset = value }
                        },
                    )
                ),
        ) {
            TaskRow(
                task, state, onToggle, onOpen,
                menu = { close -> TaskMenu(task, state, model, onOpen, selectable = true, close = close) },
                showOrigin = state.showsOrigin(), drag = drag,
            )
        }
    }
}

private fun UiState.showsOrigin(): Boolean = when (effectiveScope) {
    Scope.Today, Scope.Upcoming, Scope.All, Scope.Completed, Scope.WontDo, Scope.Trash, is Scope.Tag, is Scope.Search, is Scope.Filter -> true
    else -> false
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TaskRow(
    task: TaskItem,
    state: UiState,
    onToggle: () -> Unit,
    onOpen: () -> Unit,
    // The items of the long-press menu; they close it with the function they are given.
    menu: @Composable (close: () -> Unit) -> Unit,
    showOrigin: Boolean,
    // A subtask in the card of its task (R96): a round mark, and grey without a strike when it is done.
    subtask: Boolean = false,
    // R109: set in the selection mode, where the whole row only selects.
    selected: Boolean? = null,
    onSelect: () -> Unit = {},
    // R157: in a view sorted by hand the long press drags the row; let go in place, it opens the menu.
    drag: RowDrag? = null,
) {
    var menuOpen by remember { mutableStateOf(false) }
    val haptic = LocalHapticFeedback.current
    val menuLabel = str(R.string.more)
    // The gesture outlives a recomposition: it reaches the drag of the row as it is now.
    val currentDrag by rememberUpdatedState(drag)
    val done = task.done != null
    // R122: the spacing chosen in the settings; a subtask in a card keeps its own.
    val padding = if (subtask) 6.dp else LookPrefs.rowPadding(LookPrefs.rowSpacing(LocalContext.current)).dp
    Row(
        Modifier
            .fillMaxWidth()
            .then(
                if (selected == null && drag != null) {
                    Modifier
                        .combinedClickable(onClick = onOpen)
                        // A screen reader has no drag: its long press still opens the menu.
                        .semantics { onLongClick(menuLabel) { menuOpen = true; true } }
                        .pointerInput(task.id) {
                            detectDragGesturesAfterLongPress(
                                onDragStart = {
                                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                    currentDrag?.onStart?.invoke()
                                },
                                onDrag = { change, amount ->
                                    change.consume()
                                    currentDrag?.onDrag?.invoke(amount.y)
                                },
                                onDragEnd = { if (currentDrag?.onEnd?.invoke(viewConfiguration.touchSlop) == Dropped.Still) menuOpen = true },
                                onDragCancel = { currentDrag?.onCancel?.invoke() },
                            )
                        }
                } else if (selected == null) Modifier.combinedClickable(onClick = onOpen, onLongClick = { menuOpen = true })
                else Modifier
                    .background(if (selected) viewTint(ViewTint.Blue).copy(alpha = 0.12f) else Color.Transparent)
                    .toggleable(value = selected, role = Role.Checkbox, onValueChange = { onSelect() })
            )
            .padding(start = Space.xs, end = Space.xl, top = padding, bottom = padding),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // The mark of a record of a repeat takes its completion back while it can (R128, R133); after that it is a repeat icon.
        val history = task.markState() == MarkState.History
        IconButton(onClick = if (selected == null) onToggle else onSelect, enabled = selected != null || (!task.deleted && !history)) {
            // In the selection mode the mark selects like the rest of the row, and says nothing else.
            Mark(
                task.markState(),
                if (selected != null) null else if (history) str(R.string.repeat) else if (done) str(R.string.reopen) else str(R.string.complete),
                round = subtask,
            )
        }
        if (task.isProject) {
            Icon(Icons.Outlined.Folder, str(R.string.project), Modifier.padding(end = Space.s).size(Sizes.rowIcon), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        val origin = if (showOrigin) rowOrigin(task, state.lists, str(R.string.inbox)) else null
        // R72: the priority is a thin bar after the mark; its place is kept, so every title starts at one line.
        // A subtask in a card has no priority (R10).
        if (!subtask) PriorityBar(task.priority, tall = origin != null)
        // The title gives way to the marks and the date: it is what gets the ellipsis (R73).
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
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
                Marks(task)
            }
            // R72: under the title, the list of the task in its colour and the project of a task of a project.
            // Only a task of a project is a row with a parent: a subtask is never a row of a view (R12).
            if (origin != null) {
                Text(
                    buildAnnotatedString {
                        origin.list?.let { name ->
                            withStyle(SpanStyle(color = origin.color?.let(::parseColor) ?: MaterialTheme.colorScheme.primary)) { append(name) }
                        }
                        origin.project?.let { append(if (origin.list == null) it else " – $it") }
                    },
                    style = MaterialTheme.typography.rowMeta,
                    color = MaterialTheme.colorScheme.outline,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        val scope = state.effectiveScope
        val dayInHeading = scope == Scope.Upcoming || (scope == Scope.Today && task.effectiveDue?.let(::dayOf) == today())
        rowDate(task.effectiveDue, open = !done, dayInHeading = dayInHeading)?.let { (text, late) ->
            // R125: a due date taken from the project is muted, with the project's mark before it.
            val inherited = task.due == null
            val color = when {
                late -> MaterialTheme.colorScheme.error
                inherited -> MaterialTheme.colorScheme.outline
                else -> MaterialTheme.colorScheme.onSurfaceVariant
            }
            Row(Modifier.padding(start = Space.m), verticalAlignment = Alignment.CenterVertically) {
                if (inherited) Icon(Icons.Outlined.Folder, str(R.string.project), Modifier.padding(end = Space.xxs).size(Sizes.metaIcon), tint = color)
                Text(text, style = MaterialTheme.typography.rowMeta, color = color, maxLines = 1)
            }
        }
        if (selected != null) SelectCircle(selected)
        Box {
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                menu { menuOpen = false }
            }
        }
    }
}

/** R109: the circle at the right edge of a row in the selection mode. */
@Composable
private fun SelectCircle(selected: Boolean) {
    val blue = viewTint(ViewTint.Blue)
    Box(
        Modifier
            .padding(start = Space.l)
            .size(Sizes.selectCircle)
            .then(if (selected) Modifier.background(blue, Corners.round) else Modifier.border(Sizes.stroke, MaterialTheme.colorScheme.outline, Corners.round)),
        contentAlignment = Alignment.Center,
    ) {
        if (selected) Icon(Icons.Outlined.Check, null, Modifier.size(Sizes.metaIcon), tint = Color.White)
    }
}

/** The key of a task row in the list of a view; [taskOfRow] reads the task back from it. */
private fun rowKey(section: String, id: String) = "t:$section:$id"

private fun taskOfRow(key: Any): String? = (key as? String)?.takeIf { it.startsWith("t:") }?.substringAfterLast(':')

/**
 * R109: a drag that starts on the circles at the right edge selects the rows
 * the finger passes. The movement is taken before the list sees it, so the
 * list does not scroll; a tap passes through to the row.
 */
private fun Modifier.dragSelect(rows: LazyListState, onStart: () -> Unit, onDrag: (from: String, to: String) -> Unit) = pointerInput(Unit) {
    val strip = 56.dp.toPx()
    fun rowAt(y: Float): String? = rows.layoutInfo.visibleItemsInfo
        .firstOrNull { y >= it.offset && y < it.offset + it.size }
        ?.let { taskOfRow(it.key) }
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
        if (down.position.x < size.width - strip) return@awaitEachGesture
        val from = rowAt(down.position.y) ?: return@awaitEachGesture
        var dy = 0f
        var taken = false
        while (true) {
            val change = awaitPointerEvent(PointerEventPass.Initial).changes.firstOrNull { it.id == down.id } ?: break
            if (!change.pressed) break
            dy += change.positionChange().y
            if (!taken && abs(dy) > viewConfiguration.touchSlop) {
                taken = true
                onStart()
            }
            if (taken) {
                change.consume()
                rowAt(change.position.y)?.let { onDrag(from, it) }
            }
        }
    }
}

/** R109: the actions on the selected tasks, in a bar that floats over the bottom of the list. */
@Composable
private fun SelectionBar(enabled: Boolean, actions: SelectionActions, onAction: (String) -> Unit) {
    var more by remember { mutableStateOf(false) }
    Box(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 24.dp, vertical = 12.dp), contentAlignment = Alignment.Center) {
        Surface(shape = RoundedCornerShape(28.dp), tonalElevation = 3.dp, shadowElevation = 6.dp) {
            // Tasks in the trash are only restored, and records of completed occurrences only deleted: one button.
            if (actions == SelectionActions.Restore) {
                TextButton(onClick = { onAction("restore") }, modifier = Modifier.padding(horizontal = 8.dp)) { Text(str(R.string.restore)) }
            } else if (actions == SelectionActions.DeleteRecords) {
                TextButton(onClick = { onAction("delete") }, modifier = Modifier.padding(horizontal = 8.dp)) { Text(str(R.string.delete), color = MaterialTheme.colorScheme.error) }
            } else
                Row(Modifier.padding(horizontal = 12.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    IconButton(enabled = enabled, onClick = { onAction("complete") }) { Icon(Icons.Outlined.Check, str(R.string.complete)) }
                    IconButton(enabled = enabled, onClick = { onAction("due") }) { Icon(Icons.Outlined.CalendarMonth, str(R.string.due)) }
                    IconButton(enabled = enabled, onClick = { onAction("list") }) { Icon(Icons.AutoMirrored.Outlined.DriveFileMove, str(R.string.move_to_list)) }
                    IconButton(enabled = enabled, onClick = { onAction("delete") }) { Icon(Icons.Outlined.Delete, str(R.string.delete)) }
                    Box {
                        IconButton(enabled = enabled, onClick = { more = true }) { Icon(Icons.Outlined.MoreHoriz, str(R.string.more)) }
                        DropdownMenu(expanded = more, onDismissRequest = { more = false }) {
                            for ((action, title) in listOf("start" to R.string.start, "priority" to R.string.priority, "tag" to R.string.tag, "wont" to R.string.wont_do)) {
                                DropdownMenuItem(text = { Text(str(title)) }, onClick = { more = false; onAction(action) })
                            }
                        }
                    }
                }
        }
    }
}

fun TaskItem.markState(): MarkState = when {
    isLog && !undoable -> MarkState.History
    wont -> MarkState.Wont
    done != null -> MarkState.Done
    else -> MarkState.Open
}

/**
 * R72: what a row says about where its task lives in a view that mixes lists: the list, the Inbox
 * among them, and the project of a task of a project (R31).
 */
data class RowOrigin(val list: String?, val color: String?, val project: String?) {
    val label: String get() = listOfNotNull(list, project).joinToString(" – ")
}

fun rowOrigin(task: TaskItem, lists: List<TaskList>, inbox: String): RowOrigin? {
    val list = lists.firstOrNull { it.id == task.listId }
    // The Inbox has no name of its own in the data: the app names it.
    return rowOrigin(if (task.listId == "inbox") inbox else list?.name, list?.color, task.parentTitle)
}

/** The same from its parts: the name and the colour of the list, when it is known, and the project. */
fun rowOrigin(listName: String?, listColor: String?, project: String?): RowOrigin? {
    val named = listName?.takeIf { it.isNotEmpty() }
    if (named == null && project == null) return null
    return RowOrigin(named, listColor?.takeIf { named != null && it.isNotEmpty() }, project)
}

/** Marks after the title, only for what is set, without text or numbers (R72). */
@Composable
private fun Marks(task: TaskItem) {
    val muted = MaterialTheme.colorScheme.outline
    val marks = buildList {
        if (task.repeat != null) add(Icons.Outlined.Repeat to str(R.string.repeat))
        if (task.notes.isNotEmpty()) add(Icons.AutoMirrored.Outlined.Notes to str(R.string.notes))
        if (task.attachments > 0u) add(Icons.Outlined.AttachFile to str(R.string.attachments))
        if (task.subtasksTotal > 0u) add(Icons.Outlined.Checklist to str(R.string.subtasks))
    }
    for ((icon, name) in marks) Icon(icon, name, Modifier.padding(start = Space.s).size(Sizes.mark), tint = muted)
}

/** The whole context menu: six actions, the rest lives in the editor. */
@Composable
internal fun TaskMenu(task: TaskItem, state: UiState, model: MainViewModel, onOpen: () -> Unit, selectable: Boolean, close: () -> Unit) {
    var sub by remember { mutableStateOf<String?>(null) }
    fun run(action: () -> Unit) {
        close()
        action()
    }
    when {
        task.deleted -> {
            if (selectable) DropdownMenuItem(text = { Text(str(R.string.select)) }, onClick = { run { model.startSelection(task.id) } })
            DropdownMenuItem(text = { Text(str(R.string.restore)) }, onClick = { run { model.change { it.restoreTask(task.id) } } })
        }
        task.isLog -> {
            if (selectable) DropdownMenuItem(text = { Text(str(R.string.select)) }, onClick = { run { model.startSelection(task.id) } })
            DropdownMenuItem(text = { Text(str(R.string.delete_record)) }, onClick = { run { model.delete(task) } })
        }
        sub == "due" -> {
            DropdownMenuItem(text = { Text(str(R.string.today)) }, onClick = { run { model.change { it.setDue(task.id, today()) } } })
            DropdownMenuItem(text = { Text(str(R.string.tomorrow)) }, onClick = { run { model.change { it.setDue(task.id, plusDays(1)) } } })
            DropdownMenuItem(text = { Text(str(R.string.in_a_week)) }, onClick = { run { model.change { it.setDue(task.id, plusDays(7)) } } })
            if (task.due != null) DropdownMenuItem(text = { Text(str(R.string.clear_due)) }, onClick = { run { model.change { it.setDue(task.id, null) } } })
        }
        sub == "priority" -> priorities.forEach { priority ->
            DropdownMenuItem(
                text = { Text(priority.title(), fontWeight = if (priority == task.priority) FontWeight.Bold else null) },
                onClick = { run { model.change { it.setPriority(task.id, priority) } } },
            )
        }
        sub == "list" -> {
            state.lists.filter { !it.archived }.forEach { list ->
                DropdownMenuItem(
                    text = { Text(list.displayName()) },
                    enabled = !(task.parentId == null && task.listId == list.id),
                    onClick = { run { model.change { it.moveToList(task.id, list.id) } } },
                )
            }
            // R129: the projects, as a group of their own under the lists.
            if (state.projects.isNotEmpty()) {
                HorizontalDivider()
                Text(
                    str(R.string.projects),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                )
                state.projects.forEach { project ->
                    DropdownMenuItem(
                        text = { Text(project.title) },
                        enabled = task.goesInto(project.id),
                        onClick = { run { model.change { it.moveToProject(task.id, project.id) } } },
                    )
                }
            }
        }
        else -> {
            // R109: the way into the selection mode, with this task selected.
            if (selectable) DropdownMenuItem(text = { Text(str(R.string.select)) }, onClick = { run { model.startSelection(task.id) } })
            DropdownMenuItem(text = { Text(str(R.string.due)) }, onClick = { sub = "due" })
            DropdownMenuItem(text = { Text(str(R.string.priority)) }, onClick = { sub = "priority" })
            DropdownMenuItem(text = { Text(str(R.string.move_to_list)) }, onClick = { sub = "list" })
            DropdownMenuItem(text = { Text(str(R.string.add_subtask)) }, onClick = { run(onOpen) })
            if (task.offersProjectSwitch()) {
                DropdownMenuItem(
                    text = { Text(str(if (task.isProject) R.string.project_off else R.string.project_on)) },
                    onClick = { run { model.change { it.setProject(task.id, !task.isProject) } } },
                )
            }
            DropdownMenuItem(text = { Text(str(R.string.duplicate)) }, onClick = { run { model.change(str(R.string.created_notice)) { it.duplicateTask(task.id) } } })
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
internal fun Drawer(
    state: UiState,
    onSelect: (Scope) -> Unit,
    onEditList: (TaskList) -> Unit,
    onMoveList: (id: String, after: String?) -> Unit,
    onNewList: () -> Unit,
    onEditFilter: (SavedFilter) -> Unit,
    onNewFilter: () -> Unit,
    onNewProject: () -> Unit,
    onProjectOff: (TaskItem) -> Unit,
    onProjectDone: (TaskItem) -> Unit,
    onSettings: () -> Unit,
) {
    ModalDrawerSheet {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = Space.l, vertical = Space.m)) {
            val inbox = state.list("inbox")
            if (state.showsInbox) {
                DrawerItem(str(R.string.inbox), Icons.Filled.Inbox, state.counts.inbox, state.scope == Scope.Inbox, tint = viewTint(ViewTint.Blue), onLong = inbox?.let { { onEditList(it) } }) { onSelect(Scope.Inbox) }
            }
            DrawerItem(str(R.string.today), Icons.Filled.Star, state.counts.today, state.scope == Scope.Today, alert = state.counts.overdue > 0u, tint = viewTint(ViewTint.Yellow)) { onSelect(Scope.Today) }
            DrawerItem(str(R.string.upcoming), Icons.Filled.CalendarMonth, state.counts.upcoming, state.scope == Scope.Upcoming, tint = viewTint(ViewTint.Pink)) { onSelect(Scope.Upcoming) }
            DrawerItem(str(R.string.all), Icons.Filled.Layers, 0u, state.scope == Scope.All, tint = viewTint(ViewTint.Teal)) { onSelect(Scope.All) }
            DrawerItem(str(R.string.completed), Icons.Filled.CheckBox, 0u, state.scope == Scope.Completed, tint = viewTint(ViewTint.Green)) { onSelect(Scope.Completed) }
            DrawerItem(str(R.string.wont_do), Icons.Filled.DisabledByDefault, 0u, state.scope == Scope.WontDo, tint = viewTint(ViewTint.Gray)) { onSelect(Scope.WontDo) }
            if (state.counts.trash > 0u) {
                DrawerItem(str(R.string.trash), Icons.Filled.Delete, state.counts.trash, state.scope == Scope.Trash, tint = viewTint(ViewTint.Gray)) { onSelect(Scope.Trash) }
            }

            // R158: a section folds with a tap on its heading; folded, it keeps only the row of the open view.
            val context = LocalContext.current
            val folded = LookPrefs.folded(context)
            val fold = { section: String -> { LookPrefs.setFolded(context, section, section !in folded) } }
            DrawerHeading(str(R.string.lists), folded = "lists" in folded, onToggle = fold("lists"))
            // R157: a list is dragged to its place; its rows are of one height, so the place is counted in rows.
            // A folded section is not put in order.
            val listsFolded = "lists" in folded
            val shownLists = shownRows(state.lists.filter { it.id != "inbox" && !it.archived }, listsFolded) { state.scope == Scope.List(it.id) }
            var draggedList by remember { mutableStateOf<String?>(null) }
            var listOffset by remember { mutableFloatStateOf(0f) }
            val rowHeight = with(LocalDensity.current) { drawerRowHeight().toPx() }
            val from = shownLists.indexOfFirst { it.id == draggedList }
            val to = if (from < 0) -1 else landing(from, listOffset, rowHeight, shownLists.size)
            for ((index, list) in shownLists.withIndex()) {
                val scope = Scope.List(list.id)
                val lifted = list.id == draggedList
                val drag = RowDrag(
                    onStart = { draggedList = list.id; listOffset = 0f },
                    onDrag = { dy -> listOffset += dy },
                    onEnd = { slop ->
                        val start = shownLists.indexOfFirst { it.id == list.id }
                        val end = landing(start, listOffset, rowHeight, shownLists.size)
                        val travelled = abs(listOffset)
                        draggedList = null
                        listOffset = 0f
                        when {
                            end != start -> {
                                val order = shownLists.map { it.id }.moved(start, end)
                                onMoveList(list.id, placedAfter(order, list.id))
                                Dropped.Moved(list.id, placedAfter(order, list.id))
                            }
                            travelled < slop -> Dropped.Still
                            else -> Dropped.Kept
                        }
                    },
                    onCancel = { draggedList = null; listOffset = 0f },
                )
                Box(
                    if (lifted) Modifier.zIndex(1f).graphicsLayer { translationY = listOffset; shadowElevation = 8f }
                    else Modifier.graphicsLayer { translationY = shiftOf(index, from, to) * rowHeight },
                ) {
                    DrawerItem(list.name, Icons.AutoMirrored.Outlined.List, list.openCount, state.scope == scope, tint = list.tint(), onLong = { onEditList(list) }, drag = drag.takeUnless { listsFolded }) { onSelect(scope) }
                }
            }
            if (!listsFolded) DrawerItem(str(R.string.new_list), Icons.Outlined.Add, 0u, false, onClick = onNewList)

            // R127: shown without projects as well, since a project is made here.
            DrawerHeading(str(R.string.projects), folded = "projects" in folded, onToggle = fold("projects"))
            for (project in shownRows(state.projects, "projects" in folded) { state.scope == Scope.Project(it.id) }) {
                val scope = Scope.Project(project.id)
                var menu by remember(project.id) { mutableStateOf(false) }
                Box {
                    // R126: the row is a large task, its mark completes the project. A project is not a row of its list (R120).
                    DrawerItem(
                        project.title, Icons.Outlined.Folder, 0u, state.scope == scope,
                        counter = projectCounter(project.subtasksDone, project.subtasksTotal),
                        onLong = { menu = true },
                        leading = {
                            ProjectMark(project.subtasksDone, project.subtasksTotal, state.list(project.listId)?.tint() ?: MaterialTheme.colorScheme.primary) {
                                onProjectDone(project)
                            }
                        },
                    ) { onSelect(scope) }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(text = { Text(str(R.string.complete_project)) }, onClick = { menu = false; onProjectDone(project) })
                        // R32: only an empty project turns back into a task.
                        if (project.offersProjectSwitch()) {
                            DropdownMenuItem(text = { Text(str(R.string.project_off)) }, onClick = { menu = false; onProjectOff(project) })
                        }
                    }
                }
            }
            if ("projects" !in folded) DrawerItem(str(R.string.new_project), Icons.Outlined.Add, 0u, false, onClick = onNewProject)
            DrawerHeading(str(R.string.filters), folded = "filters" in folded, onToggle = fold("filters"))
            for (filter in shownRows(state.filters, "filters" in folded) { state.scope == Scope.Filter(it.id) }) {
                val scope = Scope.Filter(filter.id)
                DrawerItem(filter.name, Icons.Outlined.FilterList, filter.openCount, state.scope == scope, onLong = { onEditFilter(filter) }) { onSelect(scope) }
            }
            if ("filters" !in folded) DrawerItem(str(R.string.new_filter), Icons.Outlined.Add, 0u, false, onClick = onNewFilter)

            if (state.tags.isNotEmpty()) {
                DrawerHeading(str(R.string.tags), folded = "tags" in folded, onToggle = fold("tags"))
                for (tag in shownRows(state.tags, "tags" in folded) { state.scope == Scope.Tag(it.name) }) {
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
            HorizontalDivider(Modifier.padding(vertical = Space.m))
            DrawerItem(str(R.string.settings), Icons.Outlined.Settings, 0u, false, onClick = onSettings)
        }
    }
}

/** The heading of a section of the panel; with [onToggle] it folds and unfolds the section (R158). */
@Composable
private fun DrawerHeading(text: String, folded: Boolean = false, onToggle: (() -> Unit)? = null) {
    if (onToggle == null) {
        Text(text, Modifier.padding(start = Space.xl, top = Space.xl, bottom = Space.xs), style = MaterialTheme.typography.sectionHeading, color = MaterialTheme.colorScheme.onSurfaceVariant)
        return
    }
    val state = str(if (folded) R.string.collapsed else R.string.expanded)
    Row(
        Modifier
            .fillMaxWidth()
            .padding(top = Space.m)
            .clip(Corners.round)
            .clickable(role = Role.Button, onClick = onToggle)
            .semantics { stateDescription = state }
            .heightIn(min = Sizes.touch)
            .padding(start = Space.xl, end = Space.xxxl),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text, Modifier.weight(1f), style = MaterialTheme.typography.sectionHeading, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Icon(
            if (folded) Icons.AutoMirrored.Outlined.KeyboardArrowRight else Icons.Outlined.KeyboardArrowDown,
            null,
            Modifier.size(Sizes.lightIcon),
            tint = MaterialTheme.colorScheme.outline,
        )
    }
}

/** R158: the height of a row of the panel, after the spacing of R122. */
@Composable
private fun drawerRowHeight() = LookPrefs.drawerRowHeight(LookPrefs.rowSpacing(LocalContext.current)).dp

/** R158: the rows a section shows: all of them, or, folded, only the row of the open view. */
internal fun <T> shownRows(rows: List<T>, folded: Boolean, isOpen: (T) -> Boolean): List<T> = if (folded) rows.filter(isOpen) else rows

/** R30: the counter of a project in the drawer, "done/total", shown for an empty project as well (R127). */
internal fun projectCounter(done: UInt, total: UInt): String = "$done/$total"

/**
 * A row of the panel of lists. A long press opens the settings of what it shows; there is no gear at the row (R95).
 * [counter] replaces [count] when the row shows a text of its own, as a project does.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DrawerItem(
    label: String,
    icon: ImageVector,
    count: UInt,
    selected: Boolean,
    alert: Boolean = false,
    tint: Color? = null,
    counter: String? = null,
    onLong: (() -> Unit)? = null,
    leading: (@Composable () -> Unit)? = null,
    // R157: a row that is put in order by hand: the long press drags it, let go in place it does [onLong].
    drag: RowDrag? = null,
    onClick: () -> Unit,
) {
    val configure = str(R.string.configure)
    val haptic = LocalHapticFeedback.current
    // The gesture outlives a recomposition: it reaches the drag and the settings of the row as they are now.
    val currentDrag by rememberUpdatedState(drag)
    val currentLong by rememberUpdatedState(onLong)
    Row(
        Modifier
            .fillMaxWidth()
            .height(drawerRowHeight())
            .clip(CircleShape)
            .background(if (selected) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent)
            .then(
                if (drag == null) {
                    Modifier.combinedClickable(
                        role = Role.Tab,
                        onLongClickLabel = if (onLong != null) configure else null,
                        onLongClick = onLong,
                        onClick = onClick,
                    )
                } else {
                    Modifier
                        .combinedClickable(role = Role.Tab, onClick = onClick)
                        // A screen reader has no drag: its long press still opens the settings.
                        .semantics { if (onLong != null) onLongClick(configure) { onLong(); true } }
                        .pointerInput(Unit) {
                            detectDragGesturesAfterLongPress(
                                onDragStart = {
                                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                    currentDrag?.onStart?.invoke()
                                },
                                onDrag = { change, amount ->
                                    change.consume()
                                    currentDrag?.onDrag?.invoke(amount.y)
                                },
                                onDragEnd = { if (currentDrag?.onEnd?.invoke(viewConfiguration.touchSlop) == Dropped.Still) currentLong?.invoke() },
                                onDragCancel = { currentDrag?.onCancel?.invoke() },
                            )
                        }
                },
            )
            .semantics { this.selected = selected }
            .padding(start = Space.xl, end = Space.xxxl),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (leading != null) leading() else Icon(icon, null, tint = tint ?: MaterialTheme.colorScheme.onSurfaceVariant)
        Text(
            label,
            Modifier.weight(1f).padding(horizontal = Space.l),
            style = MaterialTheme.typography.label,
            color = if (selected) MaterialTheme.colorScheme.onSecondaryContainer else MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        val shown = counter ?: if (count > 0u) "$count" else null
        if (shown != null) {
            Text(shown, style = MaterialTheme.typography.label, color = if (alert) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** R126: the mark of a project in the drawer, a circle filled by the share of its done tasks; a tap completes the project. */
@Composable
private fun ProjectMark(done: UInt, total: UInt, tint: Color, onComplete: () -> Unit) {
    val description = str(R.string.complete_project)
    Canvas(
        Modifier
            .size(Sizes.projectMark)
            .clip(Corners.round)
            .clickable(role = Role.Checkbox, onClick = onComplete)
            .semantics { contentDescription = description }
            .padding(Space.xxs),
    ) {
        val stroke = Sizes.stroke.toPx()
        drawCircle(tint, radius = size.minDimension / 2 - stroke / 2, style = Stroke(stroke))
        val fraction = if (total == 0u) 0f else done.toFloat() / total.toFloat()
        if (fraction > 0f) {
            val inset = Space.xxs.toPx()
            drawArc(tint, -90f, 360f * fraction.coerceAtMost(1f), useCenter = true, topLeft = Offset(inset, inset), size = Size(size.width - 2 * inset, size.height - 2 * inset))
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
    Row(Modifier.fillMaxWidth().padding(start = Space.xl, end = Space.xl, bottom = Space.m), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(Sizes.viewIcon), tint = tint)
        Text(
            state.title,
            Modifier.padding(start = Space.chipInset).semantics { heading() },
            style = MaterialTheme.typography.viewTitle,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** R95: the heading of a group, in the colour of text with a thin line under it. */
@Composable
private fun GroupHeading(title: String) {
    Column(Modifier.fillMaxWidth().padding(start = Space.xl, end = Space.xl, top = Space.xxl, bottom = Space.xs)) {
        Text(title, Modifier.semantics { heading() }, style = MaterialTheme.typography.groupHeading)
        HorizontalDivider(Modifier.padding(top = Space.s), color = MaterialTheme.colorScheme.outlineVariant)
    }
}
