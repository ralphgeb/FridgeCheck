package com.ralphgeb.halo.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ralphgeb.halo.core.HaloTime
import com.ralphgeb.halo.core.ScoreKind
import com.ralphgeb.halo.core.Snapshot
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle as DayStyle
import java.util.Locale
import kotlin.math.abs

/** A score this high counts as the day's target met. */
private const val TARGET_MET = 0.85

/**
 * The month under Today's date, as on the iPhone: each day with three dots for Recovery, Effort and
 * Sleep (light far from target, darker closer, the accent once it's met). Swipe sideways or use the
 * arrows for other months; tap a day to show it.
 */
@Composable
fun MonthCalendar(s: Snapshot, selected: LocalDate, modifier: Modifier = Modifier, onPick: (LocalDate) -> Unit) {
    val today = HaloTime.today()
    var month by remember { mutableStateOf(selected.withDayOfMonth(1)) }
    LaunchedEffect(selected) { month = selected.withDayOfMonth(1) }
    var forward by remember { mutableStateOf(true) }
    val first = s.firstDate.withDayOfMonth(1)
    val last = today.withDayOfMonth(1)
    fun shift(d: Long) {
        val next = month.plusMonths(d)
        if (next.isBefore(first) || next.isAfter(last)) return
        forward = d > 0
        month = next
    }
    Column(modifier.fillMaxWidth().padding(bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(month.format(DateTimeFormatter.ofPattern("MMMM yyyy", Locale.getDefault())), Modifier.weight(1f),
                style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Halo.text))
            MonthArrow(Icons.AutoMirrored.Outlined.KeyboardArrowLeft, month.isAfter(first)) { shift(-1) }
            Spacer(Modifier.width(8.dp))
            MonthArrow(Icons.AutoMirrored.Outlined.KeyboardArrowRight, month.isBefore(last)) { shift(1) }
        }
        val firstDay = if (HaloTime.weekStartsOnMonday) DayOfWeek.MONDAY else DayOfWeek.SUNDAY
        Row {
            (0L..6L).forEach { i ->
                Text(firstDay.plus(i).getDisplayName(DayStyle.NARROW, Locale.getDefault()), Modifier.weight(1f),
                    style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = Halo.tertiary, textAlign = TextAlign.Center))
            }
        }
        var drag by remember { mutableFloatStateOf(0f) }
        AnimatedContent(
            targetState = month,
            modifier = Modifier.pointerInput(Unit) {
                detectHorizontalDragGestures(
                    onDragStart = { drag = 0f },
                    onDragEnd = { if (abs(drag) > 60) shift(if (drag < 0) 1 else -1) },
                ) { _, amount -> drag += amount }
            },
            transitionSpec = {
                val dir = if (forward) 1 else -1
                (slideInHorizontally(tween(260)) { it * dir } + fadeIn()) togetherWith (slideOutHorizontally(tween(260)) { -it * dir } + fadeOut())
            },
            label = "month",
        ) { m -> MonthGrid(s, m, selected, today, firstDay, onPick) }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(5.dp).clip(CircleShape).background(Halo.ink.copy(alpha = 0.18f)))
            Spacer(Modifier.width(3.dp))
            Box(Modifier.size(5.dp).clip(CircleShape).background(Halo.ink.copy(alpha = 0.6f)))
            Spacer(Modifier.width(3.dp))
            Box(Modifier.size(5.dp).clip(CircleShape).background(Halo.accent))
            Spacer(Modifier.width(8.dp))
            Text("Recovery · Effort · Sleep. Darker is closer; accent is target met.",
                style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium, color = Halo.secondary))
        }
    }
}

@Composable
private fun MonthArrow(icon: androidx.compose.ui.graphics.vector.ImageVector, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(34.dp).alpha(if (enabled) 1f else 0.3f).clip(CircleShape).background(Halo.card).clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, null, tint = Halo.ink, modifier = Modifier.size(20.dp)) }
}

@Composable
private fun MonthGrid(s: Snapshot, month: LocalDate, selected: LocalDate, today: LocalDate, firstDay: DayOfWeek, onPick: (LocalDate) -> Unit) {
    val lead = ((month.dayOfWeek.value - firstDay.value) + 7) % 7
    val days = month.lengthOfMonth()
    val cells = lead + days
    Column(Modifier.height((6 * 52).dp)) {
        (0 until (cells + 6) / 7).forEach { row ->
            Row(Modifier.fillMaxWidth().height(52.dp)) {
                (0 until 7).forEach { col ->
                    val i = row * 7 + col
                    if (i < lead || i >= cells) {
                        Spacer(Modifier.weight(1f))
                    } else {
                        val date = month.plusDays((i - lead).toLong())
                        DayCell(s, date, selected, today, Modifier.weight(1f), onPick)
                    }
                }
            }
        }
    }
}

@Composable
private fun DayCell(s: Snapshot, date: LocalDate, selected: LocalDate, today: LocalDate, modifier: Modifier, onPick: (LocalDate) -> Unit) {
    val future = date.isAfter(today)
    val on = date == selected
    val hasData = s.day(date) != null
    val scores = s.scores(date)
    Column(
        modifier.height(52.dp).clip(androidx.compose.foundation.shape.RoundedCornerShape(12.dp))
            .clickable(enabled = !future && hasData) { onPick(date) },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(
            Modifier.size(34.dp).clip(CircleShape)
                .background(if (on) Halo.ink else Color.Transparent)
                .then(if (date == today && !on) Modifier.border(1.5.dp, Halo.accent, CircleShape) else Modifier),
            contentAlignment = Alignment.Center,
        ) {
            Text("${date.dayOfMonth}", style = TextStyle(
                fontSize = 15.sp, fontWeight = if (on || date == today) FontWeight.SemiBold else FontWeight.Normal,
                color = when {
                    on -> Halo.background
                    hasData -> Halo.text
                    else -> Halo.text.copy(alpha = if (future) 0.45f else 0.55f)
                },
                fontFeatureSettings = "tnum",
            ))
        }
        Spacer(Modifier.height(4.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            ScoreKind.entries.forEach { k ->
                val v = (k.value(scores) ?: 0.0).coerceIn(0.0, 1.0)
                val c = when {
                    !hasData -> Color.Transparent
                    v >= TARGET_MET -> Halo.accent
                    else -> Halo.ink.copy(alpha = (0.12 + 0.6 * v).toFloat())
                }
                Box(Modifier.size(5.dp).clip(CircleShape).background(c))
            }
        }
    }
}
