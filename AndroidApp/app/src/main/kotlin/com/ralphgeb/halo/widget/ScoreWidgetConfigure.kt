package com.ralphgeb.halo.widget

import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.state.getAppWidgetState
import androidx.glance.appwidget.state.updateAppWidgetState
import androidx.glance.state.PreferencesGlanceStateDefinition
import androidx.lifecycle.lifecycleScope
import com.ralphgeb.halo.ui.Halo
import com.ralphgeb.halo.ui.Looks
import com.ralphgeb.halo.ui.Ring
import kotlinx.coroutines.launch

/** Picks which score a one-ring widget shows: when it's added, and again from the widget's settings. */
class ScoreWidgetConfigure : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        Looks.load(this)
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val widgetId = intent?.extras?.getInt(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        // backing out leaves no widget behind
        setResult(RESULT_CANCELED, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) { finish(); return }
        val data = Widgets.load(this)
        var current = "RECOVERY"
        lifecycleScope.launch {
            runCatching {
                val glanceId = GlanceAppWidgetManager(this@ScoreWidgetConfigure).getGlanceIdBy(widgetId)
                current = getAppWidgetState(this@ScoreWidgetConfigure, PreferencesGlanceStateDefinition, glanceId)[Widgets.SCORE] ?: "RECOVERY"
            }
            setContent { Picker(data, current) { choose(widgetId, it) } }
        }
    }

    private fun choose(widgetId: Int, kind: String) {
        lifecycleScope.launch {
            runCatching {
                val glanceId = GlanceAppWidgetManager(this@ScoreWidgetConfigure).getGlanceIdBy(widgetId)
                updateAppWidgetState(this@ScoreWidgetConfigure, glanceId) { it[Widgets.SCORE] = kind }
                ScoreWidget().update(this@ScoreWidgetConfigure, glanceId)
            }
            setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
            finish()
        }
    }
}

@androidx.compose.runtime.Composable
private fun Picker(data: Widgets.Data, current: String, onPick: (String) -> Unit) {
    Column(
        Modifier.fillMaxSize().background(Halo.background).windowInsetsPadding(WindowInsets.statusBars).navigationBarsPadding().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Spacer(Modifier.height(12.dp))
        Text("Which score?", style = TextStyle(fontSize = 28.sp, fontWeight = FontWeight.Bold, color = Halo.text))
        Text("The widget shows it as one big ring. Change it any time from the widget's settings.",
            style = TextStyle(fontSize = 15.sp, color = Halo.secondary))
        Spacer(Modifier.height(8.dp))
        listOf("RECOVERY" to "Recovery", "EFFORT" to "Effort", "SLEEP" to "Sleep").forEach { (kind, title) ->
            val on = kind == current
            val v = data.score(kind)
            Row(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).background(Halo.card)
                    .border(if (on) 2.dp else 0.dp, if (on) Halo.accent else Halo.card, RoundedCornerShape(22.dp))
                    .clickable { onPick(kind) }.padding(16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.size(64.dp), contentAlignment = Alignment.Center) {
                    Ring(v ?: 0.0, Modifier.size(64.dp), stroke = 6.dp)
                    Text(v?.let { "${Math.round(it * 100)}" } ?: "–", style = Halo.number(20.sp))
                }
                Spacer(Modifier.width(16.dp))
                Column(Modifier.weight(1f)) {
                    Text(title, style = TextStyle(fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = Halo.text))
                    Text(when (kind) {
                        "EFFORT" -> "How much you've done today"
                        "SLEEP" -> "How well last night restored you"
                        else -> "How ready your body is today"
                    }, style = TextStyle(fontSize = 13.sp, color = Halo.secondary))
                }
            }
        }
    }
}
