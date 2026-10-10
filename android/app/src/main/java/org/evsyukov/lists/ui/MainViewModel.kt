package org.evsyukov.lists.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import org.evsyukov.lists.R
import org.evsyukov.lists.str
import org.evsyukov.lists.Repo
import org.evsyukov.lists.EntryPrefs
import org.evsyukov.lists.ListsApp
import org.evsyukov.lists.dateLabel
import org.evsyukov.lists.dayHeading
import org.evsyukov.lists.dayOf
import org.evsyukov.lists.displayName
import org.evsyukov.lists.dueDayPassed
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.lists_core.Attachment
import uniffi.lists_core.Counts
import uniffi.lists_core.AppException
import uniffi.lists_core.KeepDone
import uniffi.lists_core.NewTask
import uniffi.lists_core.SavedFilter
import uniffi.lists_core.Scope
import uniffi.lists_core.Store
import uniffi.lists_core.SyncStatus
import uniffi.lists_core.TagCount
import uniffi.lists_core.TaskItem
import uniffi.lists_core.TaskList

data class TaskSection(val key: String, val title: String?, val tasks: List<TaskItem>)

/** A task opened in the editor sheet together with what the sheet shows around it. */
data class Editing(val task: TaskItem, val subtasks: List<TaskItem>, val attachments: List<Attachment>)

/** A message at the bottom of the screen, optionally with a way back. */
data class Notice(val text: String, val undo: (suspend (Store) -> Unit)? = null)

data class UiState(
    val lists: List<TaskList> = emptyList(),
    val tags: List<TagCount> = emptyList(),
    val projects: List<TaskItem> = emptyList(),
    val filters: List<SavedFilter> = emptyList(),
    val counts: Counts = Counts(0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u),
    val scope: Scope = Scope.Today,
    val search: String? = null,
    val sections: List<TaskSection> = emptyList(),
    val editing: Editing? = null,
    val sync: SyncStatus = SyncStatus(false, 0u, 0u, null, null),
    val notice: Notice? = null,
    /** How long a completed task stays in its view; shared by all devices (R68). */
    val keepDone: KeepDone = KeepDone.Seconds(5u),
    val loaded: Boolean = false,
    /** R109: the tasks selected for an action on several at once; null while the selection mode is off. */
    val selection: Set<String>? = null,
) {
    val effectiveScope: Scope get() = search?.takeIf { it.isNotBlank() }?.let { Scope.Search(it) } ?: scope

    fun list(id: String): TaskList? = lists.firstOrNull { it.id == id }

    /** The tasks of the view in the order of their rows. */
    val shownIds: List<String> get() = sections.flatMap { section -> section.tasks.map { it.id } }

    val title: String
        get() = when (val s = scope) {
            Scope.Inbox -> str(R.string.inbox)
            Scope.Today -> str(R.string.today)
            Scope.Upcoming -> str(R.string.upcoming)
            Scope.All -> str(R.string.all)
            Scope.Completed -> str(R.string.completed)
            Scope.WontDo -> str(R.string.wont_do)
            Scope.Trash -> str(R.string.trash)
            is Scope.List -> list(s.id)?.displayName() ?: str(R.string.list)
            is Scope.Tag -> "#${s.name}"
            is Scope.Search -> str(R.string.search)
            is Scope.Project -> projects.firstOrNull { it.id == s.id }?.title ?: str(R.string.project)
            is Scope.Filter -> filters.firstOrNull { it.id == s.id }?.name ?: str(R.string.filter)
        }

    /** The list a task added in the current view goes to; null under a project, where the parent decides. */
    fun newTaskListId(): String? = when (val s = scope) {
        is Scope.Project -> null
        Scope.Inbox -> "inbox"
        is Scope.List -> s.id
        else -> EntryPrefs.defaultListId(ListsApp.instance, lists)
    }

    val readOnly: Boolean
        get() = when (effectiveScope) {
            Scope.Completed, Scope.WontDo, Scope.Trash, is Scope.Search -> true
            else -> false
        }

    /** R105: what Configure in the menu of the bar opens; null where the view has no settings and while the search is open. */
    val configured: Configured?
        get() = if (search != null) null else when (val s = scope) {
            Scope.Inbox -> list("inbox")?.let { Configured.OfList(it) }
            is Scope.List -> list(s.id)?.let { Configured.OfList(it) }
            is Scope.Filter -> filters.firstOrNull { it.id == s.id }?.let { Configured.OfFilter(it) }
            else -> null
        }
}

/** The open view as something with settings of its own: a list or a saved filter (R105). */
sealed interface Configured {
    data class OfList(val list: TaskList) : Configured
    data class OfFilter(val filter: SavedFilter) : Configured
}

fun describe(error: Throwable): String = when (error) {
    is AppException.NotFound -> str(R.string.err_not_found)
    is AppException.Invalid -> error.msg
    is AppException.Storage -> str(R.string.err_storage, error.msg)
    is AppException.Sync -> error.msg
    else -> error.message ?: error.toString()
}

class MainViewModel : ViewModel() {
    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state
    private var editingId: String? = null

    /** Waits for the first of the kept completed tasks to be due to leave its view (R68). */
    private var kept: Job? = null

    init {
        viewModelScope.launch { Repo.revision.collectLatest { reload() } }
    }

    private suspend fun reload() {
        val current = _state.value
        val next = withContext(Dispatchers.IO) {
            runCatching {
                val store = Repo.store
                val lists = store.lists()
                val tags = store.tags()
                // The list or tag on screen may have been removed on another device.
                val shown = current.scope
                val projects = store.projects()
                val filters = store.filters()
                val scope = when {
                    shown is Scope.Project && projects.none { it.id == shown.id } -> Scope.Inbox
                    shown is Scope.Filter && filters.none { it.id == shown.id } -> Scope.Inbox
                    shown is Scope.List && lists.none { it.id == shown.id } -> Scope.Inbox
                    shown is Scope.Tag && tags.none { it.name == shown.name } -> Scope.Inbox
                    else -> shown
                }
                val base = current.copy(lists = lists, tags = tags, projects = projects, filters = filters, scope = scope)
                base.copy(
                    counts = store.counts(),
                    sections = group(base, store.tasks(base.effectiveScope)),
                    editing = editingId?.let { id -> load(store, id) },
                    sync = store.syncStatus(),
                    keepDone = store.keepDone(),
                    loaded = true,
                )
            }
        }
        // A view chosen while this was read stays: the reload started by that choice brings its tasks.
        next.onSuccess { fresh ->
            _state.update {
                if (it.scope != current.scope) it
                // R109: a task that a sync took out of the view drops out of the selection.
                else fresh.copy(notice = it.notice, search = it.search, selection = it.selection?.kept(fresh.shownIds))
            }
        }
            .onFailure { error -> _state.update { it.copy(notice = Notice(describe(error)), loaded = true) } }
        // Kept rows leave by the clock, not by a change: look again when the first one is due.
        val wait = withContext(Dispatchers.IO) { runCatching { Repo.store.secondsUntilKeptLeaves() }.getOrNull() }
        kept?.cancel()
        kept = wait?.let { seconds ->
            viewModelScope.launch {
                delay(seconds.toLong() * 1000)
                // Not this job any more: the reload that follows must not cancel itself.
                kept = null
                reload()
            }
        }
    }

    private fun load(store: Store, id: String): Editing? = runCatching {
        Editing(store.task(id), store.subtasks(id), store.attachments(id))
    }.getOrNull()

    private fun group(state: UiState, tasks: List<TaskItem>): List<TaskSection> = when (state.effectiveScope) {
        Scope.Today -> {
            val (overdue, rest) = tasks.partition { dueDayPassed(it.due) }
            if (overdue.isEmpty()) listOf(TaskSection("today", null, rest))
            else listOf(TaskSection("overdue", str(R.string.overdue), overdue), TaskSection("today", str(R.string.today), rest)).filter { it.tasks.isNotEmpty() }
        }
        Scope.Upcoming -> runs(tasks, { dayOf(it.due ?: it.start ?: "") }, ::dayHeading)
        Scope.All -> runs(tasks, { it.listId }, { id -> state.list(id)?.displayName().orEmpty() })
        Scope.Completed, Scope.WontDo -> runs(tasks, { dayOf(it.done ?: "") }, ::dateLabel)
        else -> listOf(TaskSection("all", null, tasks))
    }

    /** Splits an already ordered list into runs with the same key. */
    private fun runs(tasks: List<TaskItem>, key: (TaskItem) -> String, title: (String) -> String): List<TaskSection> {
        val out = mutableListOf<TaskSection>()
        for (task in tasks) {
            val k = key(task)
            val last = out.lastOrNull()
            if (last?.key == k) out[out.lastIndex] = last.copy(tasks = last.tasks + task)
            else out += TaskSection(k, title(k), listOf(task))
        }
        return out
    }

    /** Runs a change off the main thread, then lets every screen know. */
    fun act(notice: Notice? = null, change: suspend (Store) -> Unit) {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { change(Repo.store) } }
            _state.update { it.copy(notice = result.exceptionOrNull()?.let { e -> Notice(describe(e)) } ?: notice) }
            Repo.changed()
        }
    }

    fun select(scope: Scope) {
        _state.update { it.copy(scope = scope, search = null, selection = null) }
        viewModelScope.launch { reload() }
    }

    fun search(text: String?) {
        _state.update { it.copy(search = text, selection = null) }
        viewModelScope.launch { reload() }
    }

    fun dismissNotice() = _state.update { it.copy(notice = null) }

    fun undo(notice: Notice) {
        val back = notice.undo ?: return
        act { back(it) }
    }

    fun open(id: String?) {
        editingId = id
        if (id == null) _state.update { it.copy(editing = null) } else viewModelScope.launch { reload() }
    }

    /** Adds what the new-task card collected. The view gives the task its place and nothing else (R75). */
    fun add(draft: TaskDraft) {
        if (draft.title.isBlank()) return
        val scope = _state.value.scope
        act { store ->
            val context = ListsApp.instance
            val task = store.createFrom(context, draft, parentId = (scope as? Scope.Project)?.id)
            if (scope !is Scope.Project) EntryPrefs.noteUsedList(context, task.listId)
        }
    }

    fun addSubtask(parent: String, title: String) {
        if (title.isBlank()) return
        act { it.createTask(NewTask(title = title.trim(), parentId = parent)) }
    }

    fun toggleDone(task: TaskItem) {
        if (task.done != null) return act { it.reopenTask(task.id) }
        val notice = when {
            // A repeating task moves on instead of closing; reopening would not bring the date back.
            task.repeat != null -> Notice(str(R.string.moved_to_next))
            // The task leaves at once, so the bar is the way back: for it and for the subtasks closed with it.
            _state.value.keepDone == KeepDone.Seconds(0u) -> Notice(str(R.string.done_notice)) { it.undoCloseTask(task.id) }
            // It stays in view, and its mark takes it back (R68).
            else -> null
        }
        act(notice) { it.completeTask(task.id) }
    }

    /** Closes the task as "won't do" (R69); what follows is the same as after completing it. */
    fun wontDo(task: TaskItem) {
        if (task.done != null) return
        val notice = when {
            task.repeat != null -> Notice(str(R.string.moved_to_next))
            _state.value.keepDone == KeepDone.Seconds(0u) -> Notice(str(R.string.wont_do_notice)) { it.undoCloseTask(task.id) }
            else -> null
        }
        act(notice) { it.wontDoTask(task.id) }
    }

    fun delete(task: TaskItem) {
        if (editingId == task.id) open(task.parentId)
        act(Notice(str(R.string.deleted)) { it.restoreTask(task.id) }) { it.deleteTask(task.id) }
    }

    /** R109: turns the selection mode on with this task selected. */
    fun startSelection(id: String) = _state.update { it.copy(selection = setOf(id)) }

    fun endSelection() {
        dragBase = null
        _state.update { it.copy(selection = null) }
    }

    fun toggleSelected(id: String) = _state.update { state ->
        state.copy(selection = state.selection?.let { if (id in it) it - id else it + id })
    }

    /** What was selected when the drag over the circles began. */
    private var dragBase: Set<String>? = null

    fun startDrag() {
        dragBase = _state.value.selection
    }

    /** R109: the drag over the circles has gone from one row to another. */
    fun dragSelection(from: String, to: String) {
        val base = dragBase ?: return
        _state.update { state -> if (state.selection == null) state else state.copy(selection = dragged(base, state.shownIds, from, to)) }
    }

    /**
     * R109: one action on every selected task, in the order of the rows. The
     * mode closes, and one bar takes the whole batch back.
     */
    fun batch(action: BatchAction) {
        val state = _state.value
        val selected = state.selection ?: return
        val ids = state.shownIds.filter { it in selected }
        endSelection()
        viewModelScope.launch {
            val backs = mutableListOf<Pair<String, Back>>()
            var changed = 0
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val store = Repo.store
                    for (id in ids) {
                        // Read anew: an action on a task may have changed its subtask that is selected too.
                        val step = action.on(store.task(id)) ?: continue
                        action.run(store, id)
                        changed++
                        step.back?.let { backs += id to it }
                    }
                }
            }
            val undo: (suspend (Store) -> Unit)? =
                if (backs.isEmpty()) null else { store -> backs.asReversed().forEach { (id, back) -> back.run(store, id) } }
            val text = result.exceptionOrNull()?.let(::describe) ?: str(action.done(), changed.toString())
            _state.update { it.copy(notice = if (changed == 0 && result.isSuccess) null else Notice(text, undo)) }
            Repo.changed()
        }
    }

    /** Imports a file exported from another task manager and reports what came of it. */
    fun importFrom(context: android.content.Context, uri: android.net.Uri) {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val file = copyToCache(context, uri) ?: error("cannot read the file")
                    try {
                        Repo.store.importFile(file.absolutePath)
                    } finally {
                        file.parentFile?.deleteRecursively()
                    }
                }
            }
            val text = result.fold(
                { r -> (listOf(str(R.string.imported, r.source, r.lists.toString(), r.tasks.toString(), r.attachments.toString())) + r.notes).joinToString(" ") },
                { e -> describe(e) },
            )
            _state.update { it.copy(notice = Notice(text)) }
            Repo.changed()
        }
    }

    fun sync() {
        viewModelScope.launch { Repo.sync() }
    }
}
