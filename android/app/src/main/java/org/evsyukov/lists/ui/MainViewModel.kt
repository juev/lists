package org.evsyukov.lists.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import org.evsyukov.lists.R
import org.evsyukov.lists.str
import org.evsyukov.lists.Repo
import org.evsyukov.lists.dateLabel
import org.evsyukov.lists.dayHeading
import org.evsyukov.lists.dayOf
import org.evsyukov.lists.displayName
import org.evsyukov.lists.today
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.lists_core.Attachment
import uniffi.lists_core.Counts
import uniffi.lists_core.AppException
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
    val counts: Counts = Counts(0u, 0u, 0u, 0u, 0u),
    val scope: Scope = Scope.Today,
    val search: String? = null,
    val sections: List<TaskSection> = emptyList(),
    val editing: Editing? = null,
    val sync: SyncStatus = SyncStatus(false, 0u, null, null),
    val notice: Notice? = null,
    val loaded: Boolean = false,
) {
    val effectiveScope: Scope get() = search?.takeIf { it.isNotBlank() }?.let { Scope.Search(it) } ?: scope

    fun list(id: String): TaskList? = lists.firstOrNull { it.id == id }

    val title: String
        get() = when (val s = scope) {
            Scope.Inbox -> str(R.string.inbox)
            Scope.Today -> str(R.string.today)
            Scope.Upcoming -> str(R.string.upcoming)
            Scope.All -> str(R.string.all)
            Scope.Completed -> str(R.string.completed)
            Scope.Trash -> str(R.string.trash)
            is Scope.List -> list(s.id)?.displayName() ?: str(R.string.list)
            is Scope.Tag -> "#${s.name}"
            is Scope.Search -> str(R.string.search)
            is Scope.Project -> projects.firstOrNull { it.id == s.id }?.title ?: str(R.string.project)
            is Scope.Filter -> filters.firstOrNull { it.id == s.id }?.name ?: str(R.string.filter)
        }

    /** Where a task typed into the current view goes. */
    val targetListId: String? get() = (scope as? Scope.List)?.id

    val readOnly: Boolean
        get() = when (effectiveScope) {
            Scope.Completed, Scope.Trash, is Scope.Search -> true
            else -> false
        }
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
                    loaded = true,
                )
            }
        }
        next.onSuccess { fresh -> _state.update { fresh.copy(notice = it.notice, search = it.search) } }
            .onFailure { error -> _state.update { it.copy(notice = Notice(describe(error)), loaded = true) } }
    }

    private fun load(store: Store, id: String): Editing? = runCatching {
        Editing(store.task(id), store.subtasks(id), store.attachments(id))
    }.getOrNull()

    private fun group(state: UiState, tasks: List<TaskItem>): List<TaskSection> = when (state.effectiveScope) {
        Scope.Today -> {
            val now = today()
            val (overdue, rest) = tasks.partition { dayOf(it.due ?: it.start ?: now) < now }
            if (overdue.isEmpty()) listOf(TaskSection("today", null, rest))
            else listOf(TaskSection("overdue", str(R.string.overdue), overdue), TaskSection("today", str(R.string.today), rest)).filter { it.tasks.isNotEmpty() }
        }
        Scope.Upcoming -> runs(tasks, { dayOf(it.due ?: it.start ?: "") }, ::dayHeading)
        Scope.All -> runs(tasks, { it.listId }, { id -> state.list(id)?.displayName().orEmpty() })
        Scope.Completed -> runs(tasks, { dayOf(it.done ?: "") }, ::dateLabel)
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
        _state.update { it.copy(scope = scope, search = null) }
        viewModelScope.launch { reload() }
    }

    fun search(text: String?) {
        _state.update { it.copy(search = text) }
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

    fun add(text: String) {
        val line = text.trim()
        if (line.isEmpty()) return
        val state = _state.value
        act { store ->
            (state.scope as? Scope.Project)?.let {
                store.quickAddUnder(line, it.id)
                return@act
            }
            val task = store.quickAdd(line, state.targetListId)
            // A task typed into Today belongs to today unless the line says otherwise.
            if (state.scope == Scope.Today && task.due == null) store.setDue(task.id, today())
            (state.scope as? Scope.Tag)?.let { store.addTag(task.id, it.name) }
        }
    }

    fun addSubtask(parent: String, title: String) {
        if (title.isBlank()) return
        act { it.createTask(NewTask(title = title.trim(), parentId = parent)) }
    }

    fun toggleDone(task: TaskItem) {
        if (task.done != null) return act { it.reopenTask(task.id) }
        // A repeating task moves on instead of closing; reopening would not bring the date back.
        val notice = if (task.repeat == null) Notice(str(R.string.done_notice)) { it.reopenTask(task.id) } else Notice(str(R.string.moved_to_next))
        act(notice) { it.completeTask(task.id) }
    }

    fun delete(task: TaskItem) {
        if (editingId == task.id) open(task.parentId)
        act(Notice(str(R.string.deleted)) { it.restoreTask(task.id) }) { it.deleteTask(task.id) }
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
