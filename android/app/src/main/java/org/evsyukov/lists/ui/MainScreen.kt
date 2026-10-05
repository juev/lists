package org.evsyukov.lists.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.List
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.CloudDone
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material.icons.outlined.CloudSync
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.FilterList
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.Inventory2
import androidx.compose.material.icons.outlined.Layers
import androidx.compose.material.icons.outlined.Menu
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.StarOutline
import androidx.compose.material.icons.outlined.Tag
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.NavigationDrawerItem
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
import androidx.compose.material3.rememberDrawerState
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.graphics.toColorInt
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.evsyukov.lists.R
import org.evsyukov.lists.str
import org.evsyukov.lists.Repo
import org.evsyukov.lists.dateLabel
import org.evsyukov.lists.displayName
import org.evsyukov.lists.isOverdue
import org.evsyukov.lists.marks
import org.evsyukov.lists.plusDays
import org.evsyukov.lists.priorities
import org.evsyukov.lists.title
import org.evsyukov.lists.today
import kotlinx.coroutines.launch
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
    val drawer = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    var editingList by remember { mutableStateOf<TaskList?>(null) }
    var creatingList by remember { mutableStateOf(false) }
    var editingFilter by remember { mutableStateOf<SavedFilter?>(null) }
    var creatingFilter by remember { mutableStateOf(false) }
    var settings by remember { mutableStateOf(false) }
    var confirmEmptyTrash by remember { mutableStateOf(false) }
    var duePickerFor by remember { mutableStateOf<TaskItem?>(null) }

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
                        if (query == null) Text(state.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        else SearchField(query, model::search)
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
                    !state.readOnly -> AddBar(onAdd = model::add)
                }
            },
        ) { padding ->
            Box(Modifier.fillMaxSize().padding(padding)) {
                if (state.loaded && state.sections.all { it.tasks.isEmpty() }) {
                    EmptyState(state.effectiveScope)
                } else {
                    LazyColumn(Modifier.fillMaxSize()) {
                        for (section in state.sections) {
                            section.title?.let { title ->
                                item(key = "h:${section.key}") {
                                    Text(
                                        title,
                                        Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp),
                                        style = MaterialTheme.typography.labelLarge,
                                        color = if (section.key == "overdue") MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary,
                                    )
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
            }
        }
    }

    state.editing?.let { EditorSheet(it, state, model, onReminderSet) }

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
            else -> Icon(Icons.Outlined.CloudDone, str(R.string.synced), tint = MaterialTheme.colorScheme.onSurfaceVariant)
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
        Scope.Trash -> str(R.string.empty_trash_view) to ""
        is Scope.Search -> str(R.string.empty_search) to ""
        else -> str(R.string.empty_list) to str(R.string.empty_list_hint)
    }
    Column(Modifier.fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        if (text.isNotEmpty()) {
            Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 4.dp))
        }
    }
}

/** The quick-entry line: always at hand, above the keyboard. */
@Composable
private fun AddBar(onAdd: (String) -> Unit) {
    var text by remember { mutableStateOf("") }
    Surface(tonalElevation = 3.dp, modifier = Modifier.imePadding()) {
        Column(Modifier.navigationBarsPadding()) {
            QuickChips(text, Modifier.padding(start = 16.dp, top = 6.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextField(
                    value = text,
                    onValueChange = { text = it },
                    placeholder = { Text(str(R.string.new_task)) },
                    singleLine = true,
                    colors = transparentField(),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { onAdd(text); text = "" }),
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = { onAdd(text); text = "" }, enabled = text.isNotBlank()) {
                    Icon(Icons.Outlined.Add, str(R.string.add))
                }
            }
        }
    }
}

/** What the quick-entry parser recognised in the line being typed. */
@Composable
fun QuickChips(text: String, modifier: Modifier = Modifier) {
    if (text.isBlank()) return
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
            Row(
                Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surfaceVariant).padding(horizontal = 20.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = if (toEnd) Arrangement.Start else Arrangement.End,
            ) {
                Icon(if (toEnd) Icons.Outlined.CheckCircle else Icons.Outlined.CalendarMonth, null)
            }
        },
    ) {
        Surface { TaskRow(task, state, onToggle, onOpen, model, showOrigin = state.showsOrigin()) }
    }
}

private fun UiState.showsOrigin(): Boolean = when (effectiveScope) {
    Scope.Today, Scope.Upcoming, Scope.Completed, Scope.Trash, is Scope.Tag, is Scope.Search, is Scope.Filter -> true
    else -> false
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TaskRow(task: TaskItem, state: UiState, onToggle: () -> Unit, onOpen: () -> Unit, model: MainViewModel, showOrigin: Boolean) {
    var menu by remember { mutableStateOf(false) }
    val done = task.done != null
    Row(
        Modifier
            .fillMaxWidth()
            .combinedClickable(onClick = onOpen, onLongClick = { menu = true })
            .padding(start = 4.dp, end = 16.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onToggle, enabled = !task.deleted && !task.isLog) {
            Icon(
                if (done) Icons.Outlined.CheckCircle else Icons.Outlined.RadioButtonUnchecked,
                contentDescription = if (done) str(R.string.reopen) else str(R.string.complete),
                tint = if (done) MaterialTheme.colorScheme.onSurfaceVariant else state.list(task.listId)?.tint() ?: MaterialTheme.colorScheme.primary,
            )
        }
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (task.isProject) {
                    Icon(Icons.Outlined.Folder, str(R.string.project), Modifier.padding(end = 6.dp).size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (task.priority != Priority.NONE) {
                    Text(
                        task.priority.marks(),
                        color = Color(0xFFE8890C),
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(end = 6.dp).semantics { contentDescription = task.priority.title() },
                    )
                }
                Text(
                    task.title,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    textDecoration = if (done) TextDecoration.LineThrough else null,
                    color = if (done) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
                )
            }
            Summary(task, state, showOrigin)
        }
        Box {
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                TaskMenu(task, state, model, onOpen) { menu = false }
            }
        }
    }
}

/** One line under the title: only what is set. */
@Composable
private fun Summary(task: TaskItem, state: UiState, showOrigin: Boolean) {
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    val parts = buildList {
        task.due?.let { add(dateLabel(it) to (if (task.done == null && isOverdue(it)) MaterialTheme.colorScheme.error else muted)) }
            ?: task.start?.let { add(str(R.string.from_date, dateLabel(it).lowercase()) to muted) }
        if (task.repeat != null) add("↻" to muted)
        if (task.subtasksTotal > 0u) add("☑ ${task.subtasksDone}/${task.subtasksTotal}" to muted)
        if (task.attachments > 0u) add("📎 ${task.attachments}" to muted)
        task.tags.forEach { add("#$it" to muted) }
        if (showOrigin) {
            val list = state.list(task.listId)?.displayName().orEmpty()
            add((task.parentTitle?.let { "$list › $it" } ?: list) to muted)
        }
    }
    if (parts.isEmpty()) return
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        for ((text, color) in parts) {
            Text(text, style = MaterialTheme.typography.bodySmall, color = color, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
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
            DrawerItem(str(R.string.inbox), Icons.Outlined.Inbox, state.counts.inbox, state.scope == Scope.Inbox, onLong = inbox?.let { { onEditList(it) } }) { onSelect(Scope.Inbox) }
            DrawerItem(str(R.string.today), Icons.Outlined.StarOutline, state.counts.today, state.scope == Scope.Today, alert = state.counts.overdue > 0u) { onSelect(Scope.Today) }
            DrawerItem(str(R.string.upcoming), Icons.Outlined.CalendarMonth, state.counts.upcoming, state.scope == Scope.Upcoming) { onSelect(Scope.Upcoming) }
            DrawerItem(str(R.string.all), Icons.Outlined.Layers, 0u, state.scope == Scope.All) { onSelect(Scope.All) }
            DrawerItem(str(R.string.completed), Icons.Outlined.CheckCircle, 0u, state.scope == Scope.Completed) { onSelect(Scope.Completed) }
            if (state.counts.trash > 0u) {
                DrawerItem(str(R.string.trash), Icons.Outlined.Delete, state.counts.trash, state.scope == Scope.Trash) { onSelect(Scope.Trash) }
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
    NavigationDrawerItem(
        label = { Text(label, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        icon = { Icon(icon, null, tint = tint ?: MaterialTheme.colorScheme.onSurfaceVariant) },
        badge = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (count > 0u) Text("$count", color = if (alert) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                if (onLong != null) {
                    Spacer(Modifier.width(8.dp))
                    Icon(Icons.Outlined.Settings, str(R.string.configure), Modifier.size(18.dp).clip(CircleShape).clickable(onClick = onLong), tint = MaterialTheme.colorScheme.outline)
                }
            }
        },
        selected = selected,
        onClick = onClick,
    )
}
