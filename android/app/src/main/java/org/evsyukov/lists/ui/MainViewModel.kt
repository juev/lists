package org.evsyukov.lists.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import org.evsyukov.lists.R
import org.evsyukov.lists.str
import org.evsyukov.lists.Repo
import org.evsyukov.lists.logError
import org.evsyukov.lists.logged
import org.evsyukov.lists.EntryPrefs
import org.evsyukov.lists.ListsApp
import org.evsyukov.lists.Secrets
import org.evsyukov.lists.dateLabel
import org.evsyukov.lists.dayHeading
import org.evsyukov.lists.dayOf
import org.evsyukov.lists.displayName
import org.evsyukov.lists.dueDayPassed
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
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
import uniffi.lists_core.SyncConfig
import uniffi.lists_core.SyncSide
import uniffi.lists_core.SyncStatus
import uniffi.lists_core.TagCount
import uniffi.lists_core.TaskItem
import uniffi.lists_core.TaskList

data class TaskSection(val key: String, val title: String?, val tasks: List<TaskItem>)

/** A task opened in the editor sheet together with what the sheet shows around it. */
data class Editing(val task: TaskItem, val subtasks: List<TaskItem>, val attachments: List<Attachment>)

/** A message at the bottom of the screen, optionally with a way back. */
data class Notice(val text: String, val undo: (suspend (Store) -> Unit)? = null)

/** R131: the way back from any action on a task: the last action of the history of undo. */
val UNDO: suspend (Store) -> Unit = { it.undo() }

data class UiState(
    val lists: List<TaskList> = emptyList(),
    val tags: List<TagCount> = emptyList(),
    val projects: List<TaskItem> = emptyList(),
    val filters: List<SavedFilter> = emptyList(),
    val counts: Counts = Counts(0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u),
    val scope: Scope = Scope.Today,
    val search: String? = null,
    val sections: List<TaskSection> = emptyList(),
    /** R22: the subtasks a search found a task by, shown as lines under its row. */
    val found: Map<String, List<TaskItem>> = emptyMap(),
    val editing: Editing? = null,
    val sync: SyncStatus = SyncStatus(false, 0u, 0u, null, null),
    val notice: Notice? = null,
    /** How long a completed task stays in its view; shared by all devices (R68). */
    val keepDone: KeepDone = KeepDone.Seconds(5u),
    /** Where a new task goes when the view does not say: `inbox`, `last` or a list id (R40); synced. */
    val newTaskList: String = "inbox",
    /** Inbox has no row while it holds no open tasks (R121); synced. */
    val inboxHidden: Boolean = false,
    val loaded: Boolean = false,
    /** The list a task entered where no list is implied goes to (R40, R121); read with the rest, off the main thread. */
    val defaultListId: String = "inbox",
    /** R109: the tasks selected for an action on several at once; null while the selection mode is off. */
    val selection: Set<String>? = null,
    /** R131: whether the menu of the bar offers Undo. */
    val canUndo: Boolean = false,
) {
    val effectiveScope: Scope get() = search?.takeIf { it.isNotBlank() }?.let { Scope.Search(it) } ?: scope

    fun list(id: String): TaskList? = lists.firstOrNull { it.id == id }

    /** Whether the panel with the lists shows Inbox: hidden, it still does while it holds open tasks (R121). */
    val showsInbox: Boolean get() = !inboxHidden || counts.inbox > 0u

    /** The lists Inbox can be hidden in favour of (R121). */
    val listsForHiddenInbox: List<TaskList> get() = lists.filter { !it.archived && it.id != "inbox" }

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

    /** R127: the list a new project goes to: that of the open project, otherwise the one a new task would take. */
    fun newProjectListId(): String? = newTaskListId()

    /** The list a task added in the current view goes to; under a project, the project's list. */
    fun newTaskListId(): String? = when (val s = scope) {
        is Scope.Project -> projects.firstOrNull { it.id == s.id }?.listId
        Scope.Inbox -> "inbox"
        is Scope.List -> s.id
        else -> defaultListId
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
    is AppException.TooLarge -> error.msg
    else -> error.message ?: error.toString()
}

/** What the settings of sync keep outside the database: the password of the storage and the sign-in for sending nudges. */
data class SyncSecrets(val password: String?, val pushServer: String?, val pushToken: String?)

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
                val tasks = store.tasks(base.effectiveScope)
                base.copy(
                    counts = store.counts(),
                    sections = group(base, tasks),
                    found = found(store, base.effectiveScope, tasks),
                    editing = editingId?.let { id -> load(store, id) },
                    sync = store.syncStatus(),
                    keepDone = store.keepDone(),
                    newTaskList = store.newTaskList(),
                    inboxHidden = store.inboxHidden(),
                    defaultListId = EntryPrefs.defaultListId(ListsApp.instance),
                    canUndo = store.canUndo(),
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
    }.onFailure { logError("app", "a task card did not open: ${logged(it)}") }.getOrNull()

    /** R22: for each task of the results of a search, the subtasks whose title holds the text. */
    private fun found(store: Store, scope: Scope, tasks: List<TaskItem>): Map<String, List<TaskItem>> {
        if (scope !is Scope.Search) return emptyMap()
        return tasks.filter { it.subtasksTotal > 0u }
            .associate { it.id to store.foundSubtasks(it.id, scope.text) }
            .filterValues { it.isNotEmpty() }
    }

    private fun group(state: UiState, tasks: List<TaskItem>): List<TaskSection> = when (state.effectiveScope) {
        Scope.Today -> {
            // R125: a task of a project goes by the project's due date when it has none of its own.
            val (overdue, rest) = tasks.partition { dueDayPassed(it.effectiveDue) }
            if (overdue.isEmpty()) listOf(TaskSection("today", null, rest))
            else listOf(TaskSection("overdue", str(R.string.overdue), overdue), TaskSection("today", str(R.string.today), rest)).filter { it.tasks.isNotEmpty() }
        }
        Scope.Upcoming -> runs(tasks, { dayOf(it.effectiveDue ?: it.effectiveStart ?: "") }, ::dayHeading)
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

    /**
     * R131: a change of a task, with the bar that takes it back. An edit of the title or the notes goes
     * through [act]: it is in the history as well, but brings no bar.
     */
    fun change(text: String = str(R.string.changed_notice), change: suspend (Store) -> Unit) =
        act(Notice(text, UNDO), change)

    /** R131: Undo in the menu of the bar, for when the bar is gone. */
    fun undoLast() = act { it.undo() }

    fun select(scope: Scope) {
        _state.update { it.copy(scope = scope, search = null, selection = null) }
        viewModelScope.launch { reload() }
    }

    /**
     * R136: Inbox opens in place of the list. The view switches without a reload of its own: one started
     * before the list is gone could land after the reload that follows the change and bring the list back.
     */
    fun deleteList(id: String) {
        _state.update { it.copy(scope = Scope.Inbox, search = null, selection = null) }
        act { it.deleteList(id) }
    }

    fun search(text: String?) {
        _state.update { it.copy(search = text, selection = null) }
        viewModelScope.launch { reload() }
    }

    fun dismissNotice() = _state.update { it.copy(notice = null) }

    /** R121: hides Inbox, moving its open tasks to the list when asked; the notice takes it all back. */
    fun hideInbox(listId: String, moveTasks: Boolean) {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { Repo.store.hideInbox(listId, moveTasks) } }
            result.onSuccess { hiding ->
                EntryPrefs.noteUsedList(ListsApp.instance, listId)
                _state.update {
                    it.copy(
                        scope = if (it.scope == Scope.Inbox) Scope.List(listId) else it.scope,
                        notice = Notice(str(R.string.inbox_hidden_notice)) { store -> store.undoHideInbox(hiding) },
                    )
                }
            }.onFailure { e -> _state.update { it.copy(notice = Notice(describe(e))) } }
            Repo.changed()
        }
    }

    fun undo(notice: Notice) {
        val back = notice.undo ?: return
        act { back(it) }
    }

    fun open(id: String?) {
        editingId = id
        if (id == null) _state.update { it.copy(editing = null) } else viewModelScope.launch { reload() }
    }

    /**
     * Adds what the new-task card collected. The view gives the task its place and nothing else (R75).
     * R139: true once the task is created; the save goes on when the card that waits for it is closed.
     */
    suspend fun add(draft: TaskDraft): Boolean {
        if (draft.title.isBlank()) return false
        return viewModelScope.async {
            val context = ListsApp.instance
            val result = withContext(Dispatchers.IO) { runCatching { Repo.store.saveDraft(context, draft) } }
            result.onSuccess { if (draft.parentId == null) EntryPrefs.noteUsedList(context, it.task.listId) }
            val notice = result.fold(
                { saved ->
                    val text = if (saved.unattached.isEmpty()) str(R.string.created_notice)
                    else str(R.string.created_not_attached, saved.unattached.joinToString(", "))
                    Notice(text, UNDO)
                },
                { Notice(describe(it)) },
            )
            _state.update { it.copy(notice = notice) }
            Repo.changed()
            result.isSuccess
        }.await()
    }

    fun addSubtask(parent: String, title: String) {
        if (title.isBlank()) return
        change(str(R.string.created_notice)) { it.createTask(NewTask(title = title.trim(), parentId = parent)) }
    }

    fun toggleDone(task: TaskItem) {
        // R133: a record whose completion can no longer be taken back is history.
        if (task.markState() == MarkState.History) return
        if (task.done != null) return change { it.reopenTask(task.id) }
        // The bar comes whatever R68 says (R131); a repeating task moves on and says so (R128).
        change(str(if (task.repeat != null) R.string.moved_to_next else R.string.done_notice)) { it.completeTask(task.id) }
    }

    /**
     * R126: completes the project whatever the state of its tasks; its open tasks close with it (R11).
     */
    fun completeProject(project: TaskItem) {
        if (project.done != null) return
        change(str(R.string.project_done_notice)) { it.completeTask(project.id) }
    }

    /**
     * R127: creates an empty project and opens its view. It goes to the list on screen, to the list of the
     * open project, or where the view has no list, to the default one (R40).
     */
    fun createProject(title: String) {
        val list = _state.value.newProjectListId()
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { Repo.store.createProject(title, list) } }
            val notice = result.exceptionOrNull()?.let { e -> Notice(describe(e)) } ?: Notice(str(R.string.created_notice), UNDO)
            _state.update { it.copy(notice = notice) }
            Repo.changed()
            result.getOrNull()?.let { select(Scope.Project(it.id)) }
        }
    }

    /** Closes the task as "won't do" (R69); what follows is the same as after completing it. */
    fun wontDo(task: TaskItem) {
        if (task.done != null) return
        change(str(if (task.repeat != null) R.string.moved_to_next else R.string.wont_do_notice)) { it.wontDoTask(task.id) }
    }

    fun delete(task: TaskItem) {
        if (editingId == task.id) open(task.parentId)
        change(str(R.string.deleted)) { it.deleteTask(task.id) }
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
     * mode closes, and one bar takes the whole batch back (R131).
     */
    fun batch(action: BatchAction) {
        val state = _state.value
        val selected = state.selection ?: return
        val ids = state.shownIds.filter { it in selected }
        endSelection()
        viewModelScope.launch {
            var changed = 0
            val result = withContext(Dispatchers.IO) {
                val store = Repo.store
                store.beginGroup()
                try {
                    runCatching {
                        for (id in ids) {
                            // Read anew: an action on a task may have changed its subtask that is selected too.
                            if (!action.appliesTo(store.task(id))) continue
                            action.run(store, id)
                            changed++
                        }
                    }
                } finally {
                    store.endGroup()
                }
            }
            val text = result.exceptionOrNull()?.let(::describe) ?: str(action.done(), changed.toString())
            _state.update { it.copy(notice = if (changed == 0 && result.isSuccess) null else Notice(text, UNDO.takeIf { changed > 0 })) }
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

    /** S52: the save of the settings of sync under way; a second one does not start meanwhile. */
    private var joining: Job? = null

    /**
     * S52: stores where to sync and which side to keep there (S36) in the scope of the model, so that
     * closing the settings does not cut it short half way. The password and the token go in before the
     * data of this device is replaced, and the former ones come back when the storage is not saved.
     */
    suspend fun joinStorage(config: SyncConfig, side: SyncSide, secrets: SyncSecrets): Result<Unit> {
        if (joining?.isActive == true) return Result.failure(IllegalStateException(str(R.string.sync_still_saving)))
        val job = viewModelScope.async(Dispatchers.IO) {
            val context = ListsApp.instance
            val store = Repo.store
            val before = SyncSecrets(Secrets.load(context), runCatching { store.pushSendServer() }.getOrNull(), Secrets.load(context, Secrets.PUSH_TOKEN))
            fun keep(s: SyncSecrets) {
                Secrets.save(context, s.password)
                store.setSyncPassword(s.password)
                store.setPushSendServer(s.pushServer)
                Secrets.save(context, s.pushToken, Secrets.PUSH_TOKEN)
                store.setPushToken(s.pushToken)
            }
            // Replacing a side waits for a run that is under way: not on the main thread.
            runCatching {
                keep(secrets)
                store.joinStorage(config, side)
                // With sync switched off nothing runs, so the main screen would keep its icon and the pull (R67).
                Repo.revision.update { it + 1 }
                sync()
            }.onFailure {
                // A storage stored before the failure goes with the new sign-in.
                if (runCatching { store.syncConfig() }.getOrNull() != config) runCatching { keep(before) }
            }
        }
        joining = job
        return job.await()
    }
}
