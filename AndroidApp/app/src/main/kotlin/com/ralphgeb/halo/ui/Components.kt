package com.ralphgeb.halo.ui

import androidx.compose.foundation.Canvas
import kotlin.math.atan2
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ralphgeb.halo.core.BalanceAxis
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * Halo's palette: one main colour (ink) and one accent, from the look chosen in setup or Settings.
 * Everything else is ink at a lower opacity, so any look stays coherent in light and dark.
 */
object Halo {
    val background: Color get() = Looks.colors.background
    val card: Color get() = Looks.colors.card
    val ink: Color get() = Looks.colors.ink
    val accent: Color get() = Looks.preset.accent
    val text: Color get() = ink
    val secondary: Color get() = ink.copy(alpha = 0.5f)
    val tertiary: Color get() = ink.copy(alpha = 0.28f)
    val track: Color get() = ink.copy(alpha = 0.08f)
    val hairline: Color get() = ink.copy(alpha = 0.08f)

    /** Big numbers, with fixed-width digits so counters don't wobble. */
    fun number(size: TextUnit, weight: FontWeight = FontWeight.SemiBold) =
        TextStyle(fontSize = size, fontWeight = weight, color = text, fontFeatureSettings = "tnum")

    val label: TextStyle get() = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.1.sp, color = secondary)
    val body: TextStyle get() = TextStyle(fontSize = 15.sp, color = text)
    val small: TextStyle get() = TextStyle(fontSize = 13.sp, color = secondary)
}

/** The single card surface. */
@Composable
fun HaloCard(modifier: Modifier = Modifier, padding: Dp = 18.dp, onClick: (() -> Unit)? = null, content: @Composable ColumnScope.() -> Unit) {
    val shape = RoundedCornerShape(22.dp)
    Column(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Halo.card, shape)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(padding),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        content = content,
    )
}

/** Small uppercase label used across the app. */
@Composable
fun HaloLabel(text: String, modifier: Modifier = Modifier, color: Color = Halo.secondary) {
    Text(text.uppercase(), modifier, style = Halo.label.copy(color = color))
}

/** A progress ring: a faint track, a round-capped arc from 12 o'clock and the accent dot on its end. */
@Composable
fun Ring(progress: Double, modifier: Modifier = Modifier, stroke: Dp = 8.dp, showsTip: Boolean = true) {
    Canvas(modifier) {
        val w = stroke.toPx()
        val d = min(size.width, size.height) - w
        val topLeft = Offset((size.width - d) / 2, (size.height - d) / 2)
        drawArc(Halo.track, 0f, 360f, false, topLeft, Size(d, d), style = Stroke(w))
        val p = progress.coerceIn(0.0, 1.0).toFloat()
        if (p > 0.001f) {
            drawArc(Halo.ink, -90f, 360f * p, false, topLeft, Size(d, d), style = Stroke(w, cap = StrokeCap.Round))
            if (showsTip && p > 0.02f) {
                val a = (-90 + 360 * p) * PI / 180
                val r = d / 2
                val c = Offset(size.width / 2 + (r * cos(a)).toFloat(), size.height / 2 + (r * sin(a)).toFloat())
                drawCircle(Halo.accent, w * 0.28f, c)
            }
        }
    }
}

/** A short line of recent values, the last one a dot. */
@Composable
fun Sparkline(values: List<Double>, modifier: Modifier = Modifier, color: Color = Halo.ink, dot: Color = Halo.accent) {
    Canvas(modifier) {
        if (values.size == 1) { drawCircle(dot, 2.6.dp.toPx(), Offset(size.width - 3.dp.toPx(), size.height / 2)); return@Canvas }
        if (values.size < 2) return@Canvas
        val lo = values.min()
        val hi = values.max()
        val span = max(hi - lo, 0.0001)
        val pad = 3.dp.toPx()
        val h = size.height - 2 * pad
        val step = size.width / (values.size - 1)
        val pts = values.mapIndexed { i, v -> Offset(i * step, (pad + h - h * ((v - lo) / span)).toFloat()) }
        val path = Path().apply { pts.forEachIndexed { i, p -> if (i == 0) moveTo(p.x, p.y) else lineTo(p.x, p.y) } }
        drawPath(path, color.copy(alpha = 0.75f), style = Stroke(1.5.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
        drawCircle(dot, 2.6.dp.toPx(), pts.last())
    }
}

/**
 * The Balance radar: the shape of your scores, the marked spoke (picked, else the weakest) lit
 * with an accent glow, and the period before as a dotted outline. Tap near a spoke to pick it.
 */
@Composable
fun Radar(
    axes: List<BalanceAxis>,
    modifier: Modifier = Modifier,
    highlight: String? = null,
    previous: List<BalanceAxis>? = null,
    onPick: ((String) -> Unit)? = null,
) {
    val ink = Halo.ink
    val accent = Halo.accent
    val card = Halo.card
    val n = axes.size
    val marked = axes.indexOfFirst { it.name == highlight }.takeIf { it >= 0 }
        ?: axes.indices.minByOrNull { axes[it].value }
    Canvas(
        modifier.then(
            if (onPick != null && n >= 3) Modifier.pointerInput(axes.map { it.name }) {
                detectTapGestures { o ->
                    val a = atan2((o.y - size.height / 2).toDouble(), (o.x - size.width / 2).toDouble())
                    // spokes start at the top and go clockwise
                    val turn = ((a + PI / 2) / (2 * PI) * n + n + 0.5).toInt() % n
                    onPick(axes[turn].name)
                }
            } else Modifier
        )
    ) {
        if (n < 3) return@Canvas
        val c = Offset(size.width / 2, size.height / 2)
        val r = min(size.width, size.height) / 2 * 0.9f
        fun point(i: Int, v: Double): Offset {
            val a = -PI / 2 + 2 * PI * i / n
            return Offset(c.x + (r * v * cos(a)).toFloat(), c.y + (r * v * sin(a)).toFloat())
        }
        fun polygon(values: List<Double>) = Path().apply {
            values.forEachIndexed { i, v -> point(i, v).let { if (i == 0) moveTo(it.x, it.y) else lineTo(it.x, it.y) } }
            close()
        }
        for (level in listOf(0.25, 0.5, 0.75, 1.0)) {
            drawPath(polygon(List(n) { level }), ink.copy(alpha = if (level == 1.0) 0.16f else 0.07f), style = Stroke(1.dp.toPx()))
        }
        for (i in 0 until n) drawLine(ink.copy(alpha = 0.07f), c, point(i, 1.0), 1.dp.toPx())
        val values = axes.map { it.value.coerceIn(0.04, 1.0) }
        val shape = polygon(values)
        drawPath(shape, ink.copy(alpha = 0.1f))
        if (previous != null && previous.size == n) {
            drawPath(polygon(previous.map { it.value.coerceIn(0.04, 1.0) }), ink.copy(alpha = 0.55f),
                style = Stroke(1.2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round,
                    pathEffect = androidx.compose.ui.graphics.PathEffect.dashPathEffect(floatArrayOf(2f, 9f))))
        }
        marked?.let { m ->
            val p = point(m, values[m])
            drawPath(shape, Brush.radialGradient(listOf(accent.copy(alpha = 0.55f), accent.copy(alpha = 0f)), center = p, radius = r * 1.25f))
        }
        drawPath(shape, ink, style = Stroke(1.5.dp.toPx(), join = StrokeJoin.Round))
        values.forEachIndexed { i, v -> if (i != marked) drawCircle(ink, 2.25.dp.toPx(), point(i, v)) }
        marked?.let { m ->
            val p = point(m, values[m])
            drawCircle(card, 6.dp.toPx(), p)
            drawCircle(accent, 4.dp.toPx(), p)
        }
    }
}

/** A two-way 1W / 2W style switch. */
@Composable
fun SpanSwitch(labels: List<String>, selected: Int, onSelect: (Int) -> Unit) {
    Row(
        Modifier.clip(CircleShape).background(Halo.track).padding(2.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        labels.forEachIndexed { i, l ->
            Box(
                Modifier
                    .clip(CircleShape)
                    .background(if (i == selected) Halo.ink else Color.Transparent)
                    .clickable { onSelect(i) }
                    .padding(horizontal = 10.dp, vertical = 4.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(l, style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = if (i == selected) Halo.background else Halo.secondary))
            }
        }
    }
}

/** A thin bar of how far something got, 0..1. */
@Composable
fun ProgressBar(value: Double, modifier: Modifier = Modifier, color: Color = Halo.ink) {
    Canvas(modifier.fillMaxWidth().height(4.dp)) {
        val h = size.height
        drawRoundRect(Halo.track, size = size, cornerRadius = androidx.compose.ui.geometry.CornerRadius(h / 2))
        val w = size.width * value.coerceIn(0.0, 1.0).toFloat()
        if (w > 0) drawRoundRect(color, size = Size(w, h), cornerRadius = androidx.compose.ui.geometry.CornerRadius(h / 2))
    }
}

/** A gap between paragraphs of a card, matching the iPhone app. */
val CardGap = 14.dp

@Composable
fun Dot(color: Color, size: Dp = 6.dp) {
    Box(Modifier.size(size).clip(CircleShape).background(color))
}

@Composable
fun PaddedLabel(text: String) {
    HaloLabel(text, Modifier.padding(start = 4.dp, top = 6.dp))
}
