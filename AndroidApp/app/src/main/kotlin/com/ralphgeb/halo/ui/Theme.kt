package com.ralphgeb.halo.ui

import android.content.Context
import android.content.res.Configuration
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color

/** The surface colours for one appearance (light or dark). The accent is shared. */
data class PaletteColors(val ink: Color, val background: Color, val card: Color)

/** A ready-made look, the same six as on the iPhone. Every one is free. */
data class Preset(
    val id: String,
    val name: String,
    val light: PaletteColors,
    val dark: PaletteColors,
    val accent: Color,
    /** Made for light mode: choosing it switches Halo to Light. */
    val prefersLight: Boolean = false,
) {
    companion object {
        private fun c(hex: Long) = Color(0xFF000000 or hex)
        private fun p(ink: Long, bg: Long, card: Long) = PaletteColors(c(ink), c(bg), c(card))

        val all = listOf(
            Preset("graphite", "Original", p(0x121214, 0xF9F9F7, 0xFFFFFF), p(0xF2F2ED, 0x090909, 0x171717), c(0xFF6129)),
            Preset("ocean", "Ocean", p(0x0E2A47, 0xF4F7FA, 0xFFFFFF), p(0xE4EEF7, 0x07111C, 0x0F1C2B), c(0x1FC8B4)),
            Preset("sky", "Sky", p(0x33557A, 0xEEF6FD, 0xFFFFFF), p(0xDCEBFA, 0x0A1320, 0x13203A), c(0x6FB6F2), prefersLight = true),
            Preset("blush", "Blush", p(0x6B3A50, 0xFDF2F6, 0xFFFFFF), p(0xF9E4EC, 0x170C11, 0x25161D), c(0xF08BB0), prefersLight = true),
            Preset("forest", "Forest", p(0x1C3324, 0xF5F7F3, 0xFFFFFF), p(0xE5EFE6, 0x08100B, 0x111C15), c(0xE8B04A)),
            Preset("mono", "Mono", p(0x000000, 0xFFFFFF, 0xF3F3F3), p(0xFFFFFF, 0x000000, 0x141414), c(0xE5484D)),
        )

        fun byId(id: String?) = all.firstOrNull { it.id == id } ?: all[0]
    }
}

/** Light, dark, or following the phone. */
enum class LookMode(val title: String) { SYSTEM("Automatic"), LIGHT("Light"), DARK("Dark") }

/**
 * The look of the app and the widgets: a preset and a mode, kept in the app's settings. The
 * screens read the colours through [Halo], so choosing a new look redraws everything at once.
 */
object Looks {
    private const val PREFS = "halo"

    var preset by mutableStateOf(Preset.all[0])
        private set
    var mode by mutableStateOf(LookMode.DARK)
        private set
    /** The phone's own light or dark, for Automatic. */
    var systemDark by mutableStateOf(true)

    val dark: Boolean get() = isDark(mode, systemDark)
    val colors: PaletteColors get() = if (dark) preset.dark else preset.light

    fun isDark(mode: LookMode, systemDark: Boolean) = when (mode) {
        LookMode.SYSTEM -> systemDark
        LookMode.LIGHT -> false
        LookMode.DARK -> true
    }

    fun systemDark(context: Context) =
        (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

    fun load(context: Context) {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        preset = Preset.byId(p.getString("lookPreset", null))
        mode = runCatching { LookMode.valueOf(p.getString("lookMode", null) ?: "DARK") }.getOrDefault(LookMode.DARK)
        systemDark = systemDark(context)
    }

    /** A preset made for light mode switches to Light; the others keep the mode you had. */
    fun choose(context: Context, p: Preset) {
        preset = p
        if (p.prefersLight) mode = LookMode.LIGHT
        save(context)
    }

    fun choose(context: Context, m: LookMode) {
        mode = m
        save(context)
    }

    private fun save(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("lookPreset", preset.id).putString("lookMode", mode.name).apply()
        com.ralphgeb.halo.widget.Widgets.refresh(context)
    }

    /** The colours a widget should use, read straight from the settings. */
    data class WidgetColors(val ink: Color, val background: Color, val card: Color, val accent: Color)

    fun forWidget(context: Context): WidgetColors {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val preset = Preset.byId(p.getString("lookPreset", null))
        val mode = runCatching { LookMode.valueOf(p.getString("lookMode", null) ?: "DARK") }.getOrDefault(LookMode.DARK)
        val c = if (isDark(mode, systemDark(context))) preset.dark else preset.light
        return WidgetColors(c.ink, c.background, c.card, preset.accent)
    }
}
