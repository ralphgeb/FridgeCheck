package com.ralphgeb.halo.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.PhoneAndroid
import androidx.compose.material.icons.outlined.Watch
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.health.connect.client.HealthConnectClient
import com.ralphgeb.halo.data.DataSource
import com.ralphgeb.halo.data.HaloState
import com.ralphgeb.halo.data.HaloStore
import kotlin.math.exp
import kotlin.math.pow
import kotlin.math.sin

/**
 * Where Halo reads your Fitbit from: your Fitbit account (everything, recommended) or Health
 * Connect (what the Fitbit app shares there). The chosen one has a Connect button until it's connected.
 */
@Composable
fun SourcePicker(state: HaloState, store: HaloStore, connect: () -> Unit) {
    HaloCard(padding = 6.dp) {
        DataSource.entries.forEachIndexed { i, s ->
            if (i > 0) Box(Modifier.padding(start = 56.dp).fillMaxWidth().height(0.5.dp).background(Halo.hairline))
            val selected = state.source == s
            val connected = selected && state.connected
            Row(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).clickable(enabled = !selected) { store.setSource(s) }
                    .padding(horizontal = 10.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier.size(36.dp).clip(RoundedCornerShape(10.dp)).background(if (selected) Halo.ink else Halo.track),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(if (s == DataSource.FITBIT) Icons.Outlined.Watch else Icons.Outlined.PhoneAndroid, null,
                        tint = if (selected) Halo.background else Halo.ink, modifier = Modifier.size(19.dp))
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(s.title, style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Halo.text))
                        if (s == DataSource.FITBIT) {
                            Spacer(Modifier.width(6.dp))
                            Text("MORE DATA", Modifier.clip(CircleShape).background(Halo.accent.copy(alpha = 0.16f)).padding(horizontal = 6.dp, vertical = 2.dp),
                                style = TextStyle(fontSize = 9.sp, fontWeight = FontWeight.Bold, color = Halo.accent, letterSpacing = 0.6.sp))
                        }
                    }
                    Text(s.detail, style = Halo.small.copy(fontSize = 12.sp))
                }
                Spacer(Modifier.width(8.dp))
                when {
                    connected -> Icon(Icons.Outlined.CheckCircle, "Connected", tint = Halo.accent, modifier = Modifier.size(22.dp))
                    selected && s == DataSource.FITBIT && state.google.busy ->
                        CircularProgressIndicator(Modifier.size(18.dp), color = Halo.ink, strokeWidth = 2.dp)
                    selected -> Text(
                        if (s == DataSource.HEALTH_CONNECT && state.healthConnect != HealthConnectClient.SDK_AVAILABLE) "Get" else "Connect",
                        Modifier.clip(CircleShape).background(Halo.ink).clickable(onClick = connect).padding(horizontal = 12.dp, vertical = 6.dp),
                        style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Halo.background),
                    )
                    else -> Box(Modifier.size(18.dp).border(1.5.dp, Halo.tertiary, CircleShape))
                }
            }
        }
    }
    val problem = when {
        state.source == DataSource.FITBIT -> state.google.error
        state.healthConnect != HealthConnectClient.SDK_AVAILABLE -> "Health Connect needs installing or updating from the Play Store."
        else -> null
    }
    problem?.let { Text(it, Modifier.padding(horizontal = 4.dp), style = Halo.small.copy(color = Halo.accent)) }
}

/** The six looks as swatches, then Automatic / Light / Dark. All free. */
@Composable
fun LookPicker() {
    val context = LocalContext.current
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Preset.all.chunked(3).forEach { row ->
            Row(Modifier.fillMaxWidth()) {
                row.forEach { p ->
                    val on = Looks.preset.id == p.id
                    val colors = if (Looks.dark) p.dark else p.light
                    Column(
                        Modifier.weight(1f).clip(RoundedCornerShape(16.dp)).clickable { Looks.choose(context, p) }.padding(vertical = 6.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Box(
                            Modifier.size(66.dp).border(if (on) 2.5.dp else 1.dp, if (on) Halo.accent else Halo.hairline, CircleShape).padding(3.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Canvas(Modifier.size(60.dp)) {
                                drawCircle(colors.background)
                                val w = 5.dp.toPx()
                                val inset = 8.dp.toPx() + w / 2
                                drawArc(colors.ink, -90f, 260f, false, Offset(inset, inset), Size(size.width - 2 * inset, size.height - 2 * inset),
                                    style = Stroke(w, cap = StrokeCap.Round))
                                drawCircle(p.accent, 4.5.dp.toPx())
                            }
                        }
                        Spacer(Modifier.height(6.dp))
                        Text(p.name, style = TextStyle(fontSize = 12.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Medium,
                            color = if (on) Halo.text else Halo.secondary))
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Mode", Modifier.weight(1f), style = Halo.body)
            SpanSwitch(LookMode.entries.map { it.title }, Looks.mode.ordinal) { Looks.choose(context, LookMode.entries[it]) }
        }
    }
}

/** A little Today in the colours on show: three rings and a day of heart rate. */
@Composable
fun LookPreview(modifier: Modifier = Modifier) {
    Column(
        modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(Halo.background)
            .border(1.dp, Halo.hairline, RoundedCornerShape(24.dp)).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(Modifier.fillMaxWidth()) {
            listOf("Recovery" to 0.72, "Effort" to 0.46, "Sleep" to 0.88).forEach { (name, v) ->
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Box(Modifier.size(70.dp), contentAlignment = Alignment.Center) {
                        Ring(v, Modifier.size(70.dp), stroke = 7.dp)
                        Text("${Math.round(v * 100)}", style = Halo.number(20.sp))
                    }
                    Spacer(Modifier.height(8.dp))
                    HaloLabel(name)
                }
            }
        }
        Column(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Halo.card).padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            HaloLabel("Heart rate · today")
            val ink = Halo.ink
            val accent = Halo.accent
            Canvas(Modifier.fillMaxWidth().height(64.dp)) {
                val line = Path()
                val area = Path()
                val n = 60
                for (i in 0..n) {
                    val t = i.toDouble() / n
                    val v = 0.35 + 0.18 * sin(t * 9) + 0.22 * exp(-((t - 0.62) * 9).pow(2)) + 0.05 * sin(t * 31)
                    val p = Offset((size.width * t).toFloat(), (size.height * (1 - v)).toFloat())
                    if (i == 0) { line.moveTo(p.x, p.y); area.moveTo(0f, size.height); area.lineTo(p.x, p.y) }
                    else { line.lineTo(p.x, p.y); area.lineTo(p.x, p.y) }
                }
                area.lineTo(size.width, size.height)
                area.close()
                drawPath(area, Brush.verticalGradient(listOf(accent.copy(alpha = 0.35f), Color.Transparent)))
                drawPath(line, ink, style = Stroke(1.8.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
            }
        }
    }
}
