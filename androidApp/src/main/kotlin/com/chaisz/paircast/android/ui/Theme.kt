package com.chaisz.paircast.android.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** iOS system palette so both apps feel like the same product. */
object PaircastColors {
    val blue = Color(0xFF007AFF)
    val blueDark = Color(0xFF0A84FF)
    val danger = Color(0xFFFF3B30)
    val green = Color(0xFF34C759)
    val groupedLight = Color(0xFFF2F2F7)
    val groupedDark = Color(0xFF000000)
    val cardLight = Color(0xFFFFFFFF)
    val cardDark = Color(0xFF1C1C1E)
}

@Composable
fun PaircastTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val colors = if (dark) {
        darkColorScheme(
            primary = PaircastColors.blueDark,
            onPrimary = Color.White,
            background = PaircastColors.groupedDark,
            surface = PaircastColors.cardDark,
            surfaceVariant = Color(0xFF2C2C2E),
            surfaceContainer = PaircastColors.cardDark,
            surfaceContainerHigh = Color(0xFF2C2C2E),
            surfaceContainerLow = PaircastColors.cardDark,
            error = PaircastColors.danger,
        )
    } else {
        lightColorScheme(
            primary = PaircastColors.blue,
            onPrimary = Color.White,
            background = PaircastColors.groupedLight,
            surface = PaircastColors.cardLight,
            surfaceVariant = Color(0xFFE5E5EA),
            surfaceContainer = PaircastColors.cardLight,
            surfaceContainerHigh = PaircastColors.cardLight,
            surfaceContainerLow = PaircastColors.cardLight,
            error = PaircastColors.danger,
        )
    }
    MaterialTheme(colorScheme = colors, content = content)
}
