package org.evsyukov.lists.ui.theme

import android.os.Build
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext

/**
 * The theme of every screen (#369): the colour scheme of the look, Material type and shapes.
 * [dynamic] takes the palette of the wallpaper on Android 12 and later; without it, and before
 * Android 12, the Material baseline. Screenshot tests switch it off so that a picture does not
 * depend on the wallpaper of the machine.
 */
@Composable
fun ListsTheme(dark: Boolean, dynamic: Boolean = true, content: @Composable () -> Unit) {
    val context = LocalContext.current
    val colors = when {
        dynamic && Build.VERSION.SDK_INT >= 31 -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = colors, content = content)
}
