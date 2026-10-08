package org.evsyukov.lists

import android.app.Activity
import android.content.Intent
import android.content.pm.ActivityInfo
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import org.evsyukov.lists.ui.MainScreen
import org.evsyukov.lists.ui.MainViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import uniffi.lists_core.SyncConfig

/** [bars] is set by a screen that draws under the system bars: their icons then follow the look of the app. */
@Composable
fun AppTheme(bars: Boolean = false, content: @Composable () -> Unit) {
    val context = LocalContext.current
    val dark = when (LookPrefs.appearance(context)) {
        "light" -> false
        "dark" -> true
        else -> isSystemInDarkTheme()
    }
    if (bars) {
        val view = LocalView.current
        SideEffect {
            (view.context as? Activity)?.window?.let { window ->
                WindowCompat.getInsetsController(window, view).run {
                    isAppearanceLightStatusBars = !dark
                    isAppearanceLightNavigationBars = !dark
                }
            }
        }
    }
    val colors = when {
        Build.VERSION.SDK_INT >= 31 -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = colors, content = content)
}

class MainActivity : ComponentActivity() {
    private val model: MainViewModel by viewModels()
    private val askNotifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // R77: the portrait lock of the manifest is for phones; Android 16 lifts it on a wide display itself.
        if (resources.configuration.smallestScreenWidthDp >= 600) {
            requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
        enableEdgeToEdge()
        setContent { AppTheme(bars = true) { MainScreen(model, onReminderSet = ::ensureNotifications) } }
        openFromIntent(intent)
        // S31: who had sync on before the request existed is asked here, once.
        if (savedInstanceState == null && runCatching { Repo.store.syncConfig() !is SyncConfig.Off }.getOrDefault(false)) {
            Background.askOnce(this)
        }

        // Sync when the app comes forward and once a minute while it stays there.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.RESUMED) {
                while (true) {
                    Repo.sync()
                    delay(60_000)
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        openFromIntent(intent)
    }

    private fun openFromIntent(intent: Intent?) {
        intent?.getStringExtra(EXTRA_TASK)?.let(model::open)
    }

    /** Asked only when the first reminder is set: without one the permission is of no use. */
    private fun ensureNotifications() {
        if (Build.VERSION.SDK_INT >= 33) askNotifications.launch(android.Manifest.permission.POST_NOTIFICATIONS)
    }

    companion object {
        const val EXTRA_TASK = "task"
    }
}
