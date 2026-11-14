package com.ralphgeb.halo.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.DonutLarge
import androidx.compose.material.icons.outlined.Insights
import androidx.compose.material.icons.outlined.Sensors
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ralphgeb.halo.core.Format
import com.ralphgeb.halo.core.HaloTime
import com.ralphgeb.halo.data.HaloState
import com.ralphgeb.halo.data.HaloStore
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/**
 * The first time Halo opens, as on the iPhone: the logo, then where your Fitbit data comes from,
 * a little about you and your targets, your sleep goal, your colours, and how Halo works. Once
 * connected, the first read runs behind these pages.
 */
@Composable
fun Onboarding(state: HaloState, store: HaloStore, connect: () -> Unit, @Suppress("UNUSED_PARAMETER") connectHealthConnect: () -> Unit) {
    var page by rememberSaveable { mutableIntStateOf(0) }
    var forward by remember { mutableStateOf(true) }
    fun go(p: Int) { forward = p > page; page = p }
    BackHandler(enabled = page > 0) { go(page - 1) }

    Column(Modifier.fillMaxSize().background(Halo.background).windowInsetsPadding(WindowInsets.statusBars).navigationBarsPadding()) {
        AnimatedContent(
            targetState = page,
            modifier = Modifier.weight(1f),
            transitionSpec = {
                val dir = if (forward) 1 else -1
                (slideInHorizontally(tween(380)) { it * dir / 3 } + fadeIn(tween(300)))
                    .togetherWith(slideOutHorizontally(tween(380)) { -it * dir / 3 } + fadeOut(tween(200)))
            },
            label = "setup",
        ) { p ->
            when (p) {
                0 -> WelcomePage { go(1) }
                1 -> DevicePage(state, store, connect) { go(2) }
                2 -> YouPage(store)
                3 -> SleepGoalPage(store)
                4 -> StylePage()
                else -> HowItWorksPage()
            }
        }
        if (page > 0) {
            Column(Modifier.padding(horizontal = 24.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Text("All your data stays on this phone.", Modifier.fillMaxWidth(),
                    style = TextStyle(fontSize = 12.sp, color = Halo.tertiary, textAlign = TextAlign.Center))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(42.dp).clip(CircleShape).background(Halo.card).clickable { go(page - 1) }, contentAlignment = Alignment.Center) {
                        Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back", tint = Halo.ink, modifier = Modifier.size(18.dp))
                    }
                    Spacer(Modifier.weight(1f))
                    PageDots(5, page - 1)
                    Spacer(Modifier.weight(1f))
                    val enabled = page != 1 || state.connected
                    Text(
                        if (page == 5) "Start" else "Next",
                        Modifier.clip(CircleShape).background(if (enabled) Halo.ink else Halo.track)
                            .clickable(enabled = enabled) { if (page == 5) store.finishOnboarding() else go(page + 1) }
                            .padding(horizontal = 26.dp, vertical = 11.dp),
                        style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = if (enabled) Halo.background else Halo.tertiary),
                    )
                }
            }
        }
    }
}

@Composable
private fun PageDots(count: Int, current: Int) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        repeat(count) { i ->
            Box(Modifier.height(6.dp).width(if (i == current) 18.dp else 6.dp).clip(CircleShape)
                .background(if (i == current) Halo.ink else Halo.ink.copy(alpha = 0.2f)))
        }
    }
}

/** A setup page: a title, a line under it, then the content, scrolling if it needs to. */
@Composable
private fun SetupPage(title: String, subtitle: String, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp)) {
        Spacer(Modifier.height(28.dp))
        Text(title, style = TextStyle(fontSize = 28.sp, fontWeight = FontWeight.Bold, color = Halo.text))
        Spacer(Modifier.height(6.dp))
        Text(subtitle, style = TextStyle(fontSize = 15.sp, color = Halo.secondary))
        Spacer(Modifier.height(24.dp))
        content()
        Spacer(Modifier.height(16.dp))
    }
}

/** The logo draws itself: the circle grows, the ring fills to the mark, then the name. */
@Composable
private fun WelcomePage(next: () -> Unit) {
    val grow = remember { Animatable(0.18f) }
    val drawn = remember { Animatable(0f) }
    val named = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        launch { grow.animateTo(1f, spring(dampingRatio = 0.75f, stiffness = Spring.StiffnessLow)) }
        delay(350)
        launch { drawn.animateTo(0.8f, tween(1100)) }
        delay(900)
        named.animateTo(1f, tween(500))
    }
    Column(Modifier.fillMaxSize().padding(horizontal = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Spacer(Modifier.weight(1f))
        LogoMark(drawn.value, Modifier.size(118.dp).scale(grow.value).alpha(((grow.value - 0.18f) / 0.82f).coerceIn(0f, 1f)))
        Spacer(Modifier.height(26.dp))
        Column(Modifier.alpha(named.value), horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Halo", style = TextStyle(fontSize = 31.sp, fontWeight = FontWeight.SemiBold, color = Halo.text))
            Spacer(Modifier.height(6.dp))
            Text("Your health app simplified", style = TextStyle(fontSize = 14.sp, color = Halo.secondary))
        }
        Spacer(Modifier.weight(1f))
        Text(
            "Get started",
            Modifier.alpha(named.value).fillMaxWidth().clip(CircleShape).background(Halo.ink)
                .clickable(enabled = named.value > 0.5f, onClick = next).padding(vertical = 15.dp),
            style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = Halo.background, textAlign = TextAlign.Center),
        )
        Spacer(Modifier.height(28.dp))
    }
}

/** Halo's mark: a ring drawn to `progress`, with the accent dot at its tip. */
@Composable
fun LogoMark(progress: Float, modifier: Modifier = Modifier) {
    val ink = Halo.ink
    val accent = Halo.accent
    val card = Halo.card
    Canvas(modifier) {
        drawCircle(card)
        val w = size.minDimension * 0.09f
        val inset = size.minDimension * 0.22f
        val d = size.minDimension - 2 * inset
        drawArc(ink.copy(alpha = 0.1f), 0f, 360f, false, Offset(inset, inset), Size(d, d), style = Stroke(w))
        if (progress > 0.01f) {
            drawArc(ink, -90f, 360f * progress, false, Offset(inset, inset), Size(d, d), style = Stroke(w, cap = StrokeCap.Round))
            val a = Math.toRadians(-90.0 + 360 * progress)
            drawCircle(accent, w * 0.32f, Offset(center.x + (d / 2 * cos(a)).toFloat(), center.y + (d / 2 * sin(a)).toFloat()))
        }
    }
}

@Composable
private fun DevicePage(state: HaloState, store: HaloStore, connect: () -> Unit, skip: () -> Unit) {
    SetupPage("Connect your Fitbit", "Pick where Halo reads your data from, and connect. Halo only reads.") {
        SourcePicker(state, store, connect)
        if (state.connected) {
            Spacer(Modifier.height(12.dp))
            Text(if (state.syncing) "Connected. Reading your data while you set up…" else "Connected.",
                Modifier.padding(horizontal = 4.dp), style = Halo.small)
        } else {
            Spacer(Modifier.height(18.dp))
            Text("Not now, look around with sample data", Modifier.fillMaxWidth().clickable(onClick = skip).padding(vertical = 8.dp),
                style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium, color = Halo.secondary, textAlign = TextAlign.Center))
        }
    }
}

/** About you and your targets, on one page. */
@Composable
private fun YouPage(store: HaloStore) {
    var profile by remember { mutableStateOf(store.loadProfile()) }
    var targets by remember { mutableStateOf(store.loadTargets()) }
    var weekMonday by remember { mutableStateOf(HaloTime.weekStartsOnMonday) }
    fun setProfile(p: com.ralphgeb.halo.core.Profile) { profile = p; store.setProfile(p) }
    fun setTargets(t: com.ralphgeb.halo.core.Targets) { targets = t; store.setTargets(t) }
    SetupPage("You and your targets", "For your heart-rate zones, and what a good day looks like.") {
        PaddedLabel("About you")
        Spacer(Modifier.height(8.dp))
        HaloCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Sex", Modifier.weight(1f), style = Halo.body)
                SpanSwitch(listOf("Male", "Female"), if (profile.male) 0 else 1) { setProfile(profile.copy(male = it == 0)) }
            }
            Stepper("Born", "${profile.birthYear}", { setProfile(profile.copy(birthYear = (profile.birthYear - 1).coerceAtLeast(1930))) },
                { setProfile(profile.copy(birthYear = (profile.birthYear + 1).coerceAtMost(2012))) })
            Stepper("Height", "${profile.heightCm.toInt()} cm", { setProfile(profile.copy(heightCm = (profile.heightCm - 1).coerceAtLeast(120.0))) },
                { setProfile(profile.copy(heightCm = (profile.heightCm + 1).coerceAtMost(220.0))) })
            Stepper("Weight", "%.1f kg".format(profile.weightKg), { setProfile(profile.copy(weightKg = (profile.weightKg - 0.5).coerceAtLeast(35.0))) },
                { setProfile(profile.copy(weightKg = (profile.weightKg + 0.5).coerceAtMost(200.0))) })
        }
        Spacer(Modifier.height(20.dp))
        PaddedLabel("Your targets")
        Spacer(Modifier.height(8.dp))
        HaloCard {
            Stepper("Steps", Format.thousands(targets.steps.toLong()), { setTargets(targets.copy(steps = (targets.steps - 500).coerceAtLeast(2_000.0))) },
                { setTargets(targets.copy(steps = (targets.steps + 500).coerceAtMost(30_000.0))) })
            Stepper("Active minutes", "${targets.zoneMinutes.toInt()} a day", { setTargets(targets.copy(zoneMinutes = (targets.zoneMinutes - 5).coerceAtLeast(10.0))) },
                { setTargets(targets.copy(zoneMinutes = (targets.zoneMinutes + 5).coerceAtMost(120.0))) })
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Week starts", Modifier.weight(1f), style = Halo.body)
                SpanSwitch(listOf("Mon", "Sun"), if (weekMonday) 0 else 1) { weekMonday = it == 0; store.setWeekStartsOnMonday(weekMonday) }
            }
        }
        Spacer(Modifier.height(10.dp))
        Text("You can change all of these later in Settings.", Modifier.padding(horizontal = 4.dp), style = TextStyle(fontSize = 12.sp, color = Halo.tertiary))
    }
}

/** The sleep you want each night: the sleep score, sleep bank and recovery all measure against it. */
@Composable
private fun SleepGoalPage(store: HaloStore) {
    var targets by remember { mutableStateOf(store.loadTargets()) }
    fun set(h: Double) { targets = targets.copy(sleepNeedHours = h); store.setTargets(targets) }
    val choices = listOf(6.5, 7.0, 7.5, 8.0, 8.5, 9.0)
    SetupPage("How much sleep do you want?", "Your sleep score, sleep bank and recovery all measure against this, so pick what you really feel good on.") {
        choices.chunked(2).forEach { row ->
            Row(Modifier.fillMaxWidth().padding(bottom = 10.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                row.forEach { h ->
                    val on = abs(targets.sleepNeedHours - h) < 0.01
                    Column(
                        Modifier.weight(1f).height(72.dp).clip(RoundedCornerShape(18.dp)).background(if (on) Halo.ink else Halo.card).clickable { set(h) },
                        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
                    ) {
                        Text(Format.duration(h * 60), style = Halo.number(22.sp).copy(color = if (on) Halo.background else Halo.text))
                        Text(if (h < 7) "Short" else if (h < 8) "Most people" else if (h < 8.5) "Plenty" else "Long",
                            style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium, color = (if (on) Halo.background else Halo.text).copy(alpha = 0.7f)))
                    }
                }
            }
        }
        HaloCard {
            Stepper("Or exactly", Format.duration(targets.sleepNeedHours * 60), { set((targets.sleepNeedHours - 0.25).coerceAtLeast(5.0)) },
                { set((targets.sleepNeedHours + 0.25).coerceAtMost(11.0)) })
        }
        Spacer(Modifier.height(10.dp))
        Text("Change it any time in Settings › Targets.", Modifier.padding(horizontal = 4.dp), style = TextStyle(fontSize = 12.sp, color = Halo.tertiary))
    }
}

/** Pick your look: a little Today in the colours you tap. Every look is yours to use. */
@Composable
private fun StylePage() {
    SetupPage("Pick your look", "Tap a colour set to try it. You can change it any time in Settings.") {
        LookPreview()
        Spacer(Modifier.height(20.dp))
        LookPicker()
    }
}

/** What Halo does, in four short lines. */
@Composable
private fun HowItWorksPage() {
    val points: List<Triple<ImageVector, String, String>> = listOf(
        Triple(Icons.Outlined.Sensors, "Your data, read directly",
            "Halo reads what your Fitbit already measures: sleep, heart rate, HRV, vitals and activity. It never writes or shares anything."),
        Triple(Icons.Outlined.DonutLarge, "Three clear scores",
            "Recovery, Effort and Sleep, each measured against your own last 30 days, not against anyone else."),
        Triple(Icons.Outlined.Insights, "Only what matters",
            "No AI summaries, no coaching scripts, no filler. Just the numbers and graphs that tell you how you're doing."),
        Triple(Icons.Outlined.Tune, "Made to fit you",
            "Set your own targets and choose your colours. Everything stays on this phone, and nothing is behind a paywall."),
    )
    SetupPage("How Halo works", "Your health data, without the noise.") {
        Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
            points.forEach { (icon, title, text) ->
                Row(verticalAlignment = Alignment.Top) {
                    Box(Modifier.size(40.dp).clip(RoundedCornerShape(11.dp)).background(Halo.card), contentAlignment = Alignment.Center) {
                        Icon(icon, null, tint = Halo.ink, modifier = Modifier.size(20.dp))
                    }
                    Spacer(Modifier.width(14.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(title, style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = Halo.text))
                        Text(text, style = TextStyle(fontSize = 14.sp, color = Halo.secondary))
                    }
                }
            }
        }
    }
}
