package org.evsyukov.lists

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

/** R107: asks what a widget shows when it is placed, and again when the home screen offers to reconfigure it. */
class TaskWidgetConfigActivity : ComponentActivity() {
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        applyOverrideConfiguration(LookPrefs.textConfiguration(base))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Leaving without a choice takes the widget back off the home screen.
        setResult(RESULT_CANCELED)
        val id = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        if (id == AppWidgetManager.INVALID_APPWIDGET_ID) return finish()
        val lists = runCatching { Repo.store.lists().filter { !it.archived && it.id != "inbox" } }.getOrDefault(emptyList())
        val choices = listOf(WidgetView.Today to getString(R.string.today), WidgetView.Inbox to getString(R.string.inbox)) +
            lists.map { WidgetView.OfList(it.id) to it.name }

        setContent {
            AppTheme {
                // Tapping outside the card closes the window, as with any dialog.
                Box(
                    Modifier.fillMaxSize().systemBarsPadding()
                        .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { finish() },
                    contentAlignment = Alignment.Center,
                ) {
                    Surface(
                        shape = RoundedCornerShape(20.dp),
                        tonalElevation = 6.dp,
                        modifier = Modifier.fillMaxWidth().padding(24.dp)
                            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {},
                    ) {
                        Column(Modifier.verticalScroll(rememberScrollState()).padding(vertical = 16.dp)) {
                            Text(
                                getString(R.string.widget_choose),
                                Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
                                style = MaterialTheme.typography.titleMedium,
                            )
                            for ((view, name) in choices) {
                                Text(
                                    name,
                                    Modifier.fillMaxWidth().clickable { choose(id, view) }.padding(horizontal = 24.dp, vertical = 14.dp),
                                    style = MaterialTheme.typography.bodyLarge,
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private fun choose(id: Int, view: WidgetView) {
        TaskWidgets.setView(this, id, view)
        val context = applicationContext
        Repo.scope.launch { TaskWidgets.draw(context, AppWidgetManager.getInstance(context), id) }
        setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id))
        finish()
    }
}
