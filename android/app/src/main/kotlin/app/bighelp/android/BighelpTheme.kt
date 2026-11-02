package app.bighelp.android

import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

val Ember = Color(0xFFFF8A7A)

private val LightInk = lightColorScheme(
    primary = Color.Black,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFF0F0F2),
    onPrimaryContainer = Color.Black,
    secondary = Color(0xFF5C5C63),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFEAEAED),
    onSecondaryContainer = Color.Black,
    tertiary = Color.Black,
    onTertiary = Color.White,
    background = Color.White,
    onBackground = Color(0xFF151518),
    surface = Color.White,
    onSurface = Color(0xFF151518),
    surfaceVariant = Color(0xFFF3F3F5),
    onSurfaceVariant = Color(0xFF606068),
    outline = Color(0xFF777780),
    outlineVariant = Color(0xFFDEDEE3),
    surfaceTint = Color.Black,
    surfaceContainerLowest = Color.White,
    surfaceContainerLow = Color(0xFFF8F8FA),
    surfaceContainer = Color(0xFFF3F3F5),
    surfaceContainerHigh = Color(0xFFEEEEF0),
    surfaceContainerHighest = Color(0xFFE8E8EC),
)

private val DarkInk = darkColorScheme(
    primary = Color.White,
    onPrimary = Color.Black,
    primaryContainer = Color(0xFF303035),
    onPrimaryContainer = Color.White,
    secondary = Color(0xFFB7B7C0),
    onSecondary = Color.Black,
    secondaryContainer = Color(0xFF303035),
    onSecondaryContainer = Color.White,
    tertiary = Color.White,
    onTertiary = Color.Black,
    background = Color.Black,
    onBackground = Color(0xFFF5F5F7),
    surface = Color.Black,
    onSurface = Color(0xFFF5F5F7),
    surfaceVariant = Color(0xFF202024),
    onSurfaceVariant = Color(0xFFB7B7C0),
    outline = Color(0xFF92929B),
    outlineVariant = Color(0xFF3A3A3F),
    surfaceTint = Color.White,
    surfaceContainerLowest = Color.Black,
    surfaceContainerLow = Color(0xFF141418),
    surfaceContainer = Color(0xFF202024),
    surfaceContainerHigh = Color(0xFF2B2B30),
    surfaceContainerHighest = Color(0xFF36363C),
)

/** Colors Material has no slot for: the Ink look's black bubbles (dark gray after dark) and its green switches. */
@Immutable
class BighelpColors(val userBubble: Color, val onUserBubble: Color, val switchOn: Color)

private val LightBighelpColors = BighelpColors(Color.Black, Color.White, Color(0xFF34C759))
private val DarkBighelpColors = BighelpColors(Color(0xFF3A3A3F), Color.White, Color(0xFF30D158))

private val LocalBighelpColors = staticCompositionLocalOf { LightBighelpColors }

object Bighelp {
    val colors: BighelpColors
        @Composable @ReadOnlyComposable get() = LocalBighelpColors.current
}

@Composable
fun BighelpTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            (view.context as? Activity)?.window?.let { window ->
                WindowCompat.getInsetsController(window, view).apply {
                    isAppearanceLightStatusBars = !darkTheme
                    isAppearanceLightNavigationBars = !darkTheme
                }
            }
        }
    }
    CompositionLocalProvider(LocalBighelpColors provides if (darkTheme) DarkBighelpColors else LightBighelpColors) {
        MaterialTheme(colorScheme = if (darkTheme) DarkInk else LightInk, content = content)
    }
}
