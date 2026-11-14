package com.ralphgeb.halo.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.LinearProgressIndicator
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.ralphgeb.halo.MainActivity
import com.ralphgeb.halo.core.Scores

/** Today's Recovery, Effort and Sleep on the home screen. Tapping it opens Halo. */
class ScoresWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val saved = WidgetData.load(context)
        provideContent { Content(saved) }
    }

    @Composable
    private fun Content(saved: WidgetData) {
        Column(
            GlanceModifier.fillMaxSize().cornerRadius(24.dp).background(BG)
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .clickable(actionStartActivity<MainActivity>()),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("HALO", style = TextStyle(color = ColorProvider(ACCENT), fontSize = 11.sp, fontWeight = FontWeight.Bold))
                Spacer(GlanceModifier.defaultWeight())
                Text(saved.note, style = TextStyle(color = ColorProvider(TERTIARY), fontSize = 11.sp))
            }
            Spacer(GlanceModifier.height(10.dp))
            Row(GlanceModifier.fillMaxWidth()) {
                Score("Recovery", saved.scores.recovery, GlanceModifier.defaultWeight())
                Spacer(GlanceModifier.width(12.dp))
                Score("Effort", saved.scores.effort, GlanceModifier.defaultWeight())
                Spacer(GlanceModifier.width(12.dp))
                Score("Sleep", saved.scores.sleep, GlanceModifier.defaultWeight())
            }
        }
    }

    @Composable
    private fun Score(title: String, value: Double?, modifier: GlanceModifier) {
        Column(modifier) {
            Text(
                value?.let { "${Math.round(it * 100)}" } ?: "–",
                style = TextStyle(color = ColorProvider(INK), fontSize = 26.sp, fontWeight = FontWeight.Bold),
            )
            Spacer(GlanceModifier.height(4.dp))
            LinearProgressIndicator(
                progress = (value ?: 0.0).toFloat().coerceIn(0f, 1f),
                modifier = GlanceModifier.fillMaxWidth().height(4.dp),
                color = ColorProvider(ACCENT),
                backgroundColor = ColorProvider(TRACK),
            )
            Spacer(GlanceModifier.height(6.dp))
            Text(title.uppercase(), style = TextStyle(color = ColorProvider(SECONDARY), fontSize = 10.sp, fontWeight = FontWeight.Medium))
        }
    }

    companion object {
        private val BG = Color(0xFF171717)
        private val INK = Color(0xFFF2F2ED)
        private val ACCENT = Color(0xFFFF6129)
        private val TRACK = Color(0xFF2A2A2A)
        private val SECONDARY = Color(0xFF9A9A95)
        private val TERTIARY = Color(0xFF6A6A66)
    }
}

class ScoresWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = ScoresWidget()
}

/** What the widget shows, saved by the app after each sync so the widget never reads Health Connect itself. */
data class WidgetData(val scores: Scores, val note: String) {
    companion object {
        private const val PREFS = "halo_widget"

        fun load(context: Context): WidgetData {
            val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            fun get(key: String) = if (p.contains(key)) p.getFloat(key, 0f).toDouble() else null
            return WidgetData(
                Scores(recovery = get("recovery"), effort = get("effort"), sleep = get("sleep")),
                p.getString("note", null) ?: "Open Halo to sync",
            )
        }

        /** Saves today's scores and redraws every Halo widget. */
        suspend fun save(context: Context, scores: Scores, note: String) {
            val e = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear()
            scores.recovery?.let { e.putFloat("recovery", it.toFloat()) }
            scores.effort?.let { e.putFloat("effort", it.toFloat()) }
            scores.sleep?.let { e.putFloat("sleep", it.toFloat()) }
            e.putString("note", note).apply()
            runCatching { ScoresWidget().updateAll(context) }
        }
    }
}
