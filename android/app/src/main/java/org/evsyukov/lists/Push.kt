package org.evsyukov.lists

import android.app.Activity
import android.content.Context
import org.unifiedpush.android.connector.FailedReason
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.UnifiedPush
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage

/**
 * Other devices ask this one to sync at once (S18–S21, S24 in docs/specs/sync.md).
 * The request comes through a UnifiedPush distributor, an app such as ntfy that
 * keeps the one connection to a push server for every app on the device.
 */
object Push {
    /** Whether a distributor was chosen; the address arrives from it a moment later. */
    fun enabled(context: Context) = UnifiedPush.getSavedDistributor(context) != null

    /** Picks the distributor, asking the user when several are installed. `done(false)`: none is. */
    fun enable(activity: Activity, done: (Boolean) -> Unit) {
        UnifiedPush.tryUseCurrentOrDefaultDistributor(activity) { found ->
            if (found) UnifiedPush.register(activity, messageForDistributor = activity.getString(R.string.app_name))
            done(found)
        }
    }

    fun disable(context: Context) {
        UnifiedPush.unregister(context)
        forget(context)
    }

    /** Takes the address out of the storage, so that nobody keeps sending to it. */
    internal fun forget(context: Context) {
        runCatching { Repo.store.setPushEndpoint(null) }
        SyncWorker.soon(context)
    }
}

class PushReceiver : PushService() {
    override fun onNewEndpoint(endpoint: PushEndpoint, instance: String) {
        runCatching { Repo.store.setPushEndpoint(endpoint.url) }
        // The next run publishes the address for the other devices.
        SyncWorker.soon(this)
    }

    /** The message says nothing but "sync": whatever it carries is not read. */
    override fun onMessage(message: PushMessage, instance: String) = SyncWorker.now(this)

    override fun onRegistrationFailed(reason: FailedReason, instance: String) = Push.forget(this)

    override fun onUnregistered(instance: String) = Push.forget(this)
}
