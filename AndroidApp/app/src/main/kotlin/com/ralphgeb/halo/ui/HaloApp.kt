package com.ralphgeb.halo.ui

import android.app.Activity
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.background
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.layout.layout
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.draw.alpha
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.animate
import androidx.compose.animation.fadeOut
import androidx.compose.animation.fadeIn
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.expandVertically
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
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
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Bedtime
import androidx.compose.material.icons.outlined.BatteryStd
import androidx.compose.material.icons.automirrored.outlined.DirectionsRun
import androidx.compose.material.icons.outlined.MonitorHeart
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.TrackChanges
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DatePickerDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SelectableDates
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ralphgeb.halo.core.HaloTime
import com.ralphgeb.halo.core.Metric
import com.ralphgeb.halo.data.HaloState
import com.ralphgeb.halo.data.HaloStore
import com.ralphgeb.halo.data.DataSource
import com.ralphgeb.halo.data.GoogleAuth
import com.ralphgeb.halo.data.HealthConnectSource
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

/** What every page needs from the app. */
class PageActions(
    val openSettings: () -> Unit,
    val connect: () -> Unit,
    val select: (LocalDate) -> Unit,
    val sync: () -> Unit,
    /** Opens a metric's graphs. */
    val openMetric: (Metric) -> Unit,
)

@Composable
fun HaloApp(store: HaloStore, openTab: MutableState<Int?>, openMetric: MutableState<String?>) {
    val state by store.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var settings by rememberSaveable { mutableStateOf(false) }
    var metric by rememberSaveable { mutableStateOf<String?>(null) }

    // a widget asked for a tab
    LaunchedEffect(openTab.value) {
        openTab.value?.let { tab = it; settings = false; metric = null; openTab.value = null }
    }
    LaunchedEffect(openMetric.value) {
        openMetric.value?.let { name -> if (Metric.entries.any { it.name == name }) metric = name; openMetric.value = null }
    }
    // the phone's light or dark, for Automatic; and status-bar icons that read on the background
    val systemDark = isSystemInDarkTheme()
    LaunchedEffect(systemDark) { Looks.systemDark = systemDark }
    val view = LocalView.current
    val dark = Looks.dark
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as? Activity)?.window ?: return@SideEffect
            WindowCompat.getInsetsController(window, view).apply {
                isAppearanceLightStatusBars = !dark
                isAppearanceLightNavigationBars = !dark
            }
        }
    }

    val permissions = rememberLauncherForActivityResult(PermissionController.createRequestPermissionResultContract()) {
        store.onPermissionsResult()
    }
    val connectHealthConnect: () -> Unit = {
        if (state.healthConnect == HealthConnectClient.SDK_AVAILABLE) {
            permissions.launch(HealthConnectSource.permissions)
        } else {
            // Health Connect missing or out of date: its page in the Play Store
            val uri = Uri.parse("market://details?id=${HealthConnectSource.PROVIDER}&url=healthconnect%3A%2F%2Fonboarding")
            runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, uri).setPackage("com.android.vending")) }
        }
    }
    // the morning and evening notes are on from the start: ask once, when setup is done
    val notificationAsk = rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.RequestPermission()) { }
    LaunchedEffect(state.onboarded) {
        val prefs = context.getSharedPreferences("halo", android.content.Context.MODE_PRIVATE)
        if (state.onboarded && android.os.Build.VERSION.SDK_INT >= 33 && !prefs.getBoolean("notifyAsked", false)) {
            prefs.edit().putBoolean("notifyAsked", true).apply()
            notificationAsk.launch(android.Manifest.permission.POST_NOTIFICATIONS)
        }
    }
    // the chosen source's connect: the Fitbit sign-in, or Health Connect's permission screen
    val connect: () -> Unit = {
        when (state.source) {
            DataSource.FITBIT -> GoogleAuth.connect(context)
            DataSource.HEALTH_CONNECT -> connectHealthConnect()
        }
    }
    // back in front: check what Halo may read, and catch up
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        GoogleAuth.onResume()
        scope.launch {
            store.refreshConnection()
            store.sync()
        }
    }
    val actions = PageActions(openSettings = { settings = true }, connect = connect, select = store::select, sync = store::sync,
        openMetric = { metric = it.name })

    val scheme = if (dark) darkColorScheme(background = Halo.background, surface = Halo.card, primary = Halo.ink, secondary = Halo.accent)
    else lightColorScheme(background = Halo.background, surface = Halo.card, primary = Halo.ink, secondary = Halo.accent)
    MaterialTheme(colorScheme = scheme) {
        if (!state.onboarded) {
            Onboarding(state, store, connect, connectHealthConnect)
        } else Box(Modifier.fillMaxSize().background(Halo.background)) {
            when (tab) {
                0 -> TodayScreen(state, actions)
                1 -> FitnessScreen(state, actions)
                2 -> HealthScreen(state, actions)
                else -> SleepScreen(state, actions)
            }
            TabBar(tab, Modifier.align(Alignment.BottomCenter)) { tab = it }
            metric?.let { name -> MetricDetail(state.snapshot, Metric.valueOf(name), state.selected) { metric = null } }
            if (settings) SettingsScreen(state, store, connect, connectHealthConnect) { settings = false }
        }
    }
}

private data class TabItem(val title: String, val icon: ImageVector)

private val tabs = listOf(
    TabItem("Today", Icons.Outlined.TrackChanges),
    TabItem("Fitness", Icons.AutoMirrored.Outlined.DirectionsRun),
    TabItem("Health", Icons.Outlined.MonitorHeart),
    TabItem("Sleep", Icons.Outlined.Bedtime),
)

/** The floating tab bar, as on the iPhone: a rounded strip with the chosen tab in a pill. */
@Composable
private fun TabBar(selected: Int, modifier: Modifier, onSelect: (Int) -> Unit) {
    Row(
        modifier
            .navigationBarsPadding()
            .padding(horizontal = 18.dp, vertical = 8.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(32.dp))
            .background(Halo.card.copy(alpha = 0.96f))
            .padding(6.dp),
        horizontalArrangement = Arrangement.SpaceEvenly,
    ) {
        tabs.forEachIndexed { i, t ->
            val on = i == selected
            Column(
                Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(26.dp))
                    .background(if (on) Halo.ink.copy(alpha = 0.1f) else androidx.compose.ui.graphics.Color.Transparent)
                    .clickable { onSelect(i) }
                    .padding(vertical = 8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(t.icon, t.title, tint = if (on) Halo.ink else Halo.secondary, modifier = Modifier.size(22.dp))
                Text(t.title, style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = if (on) Halo.ink else Halo.secondary))
            }
        }
    }
}

/**
 * One page: the header (a title, or on Today the date, which opens the calendar), a syncing pill,
 * a Today button when another day is shown, settings; then the cards. Sample data is labelled.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Page(state: HaloState, actions: PageActions, title: String?, content: LazyListScope.() -> Unit) {
    var calendar by rememberSaveable { mutableStateOf(false) }
    val list = rememberLazyListState()
    LaunchedEffect(state.selected) { if (list.firstVisibleItemIndex > 3) list.scrollToItem(0) }
    // On Today the month sits under the date and follows your finger: pull the page down past the
    // top and it slides out; push up and it slides away. Let go and it settles open or closed.
    var reveal by remember { mutableFloatStateOf(if (calendar) Float.MAX_VALUE else 0f) }
    var full by remember { mutableFloatStateOf(0f) }
    val hasCalendar = title == null
    val scope = rememberCoroutineScope()
    fun settle(open: Boolean) {
        scope.launch {
            val target = if (open) full else 0f
            animate(reveal.coerceAtMost(full), target, animationSpec = tween(260)) { v, _ -> reveal = v }
            calendar = open
        }
    }
    val connection = remember(hasCalendar) {
        object : NestedScrollConnection {
            val atTop get() = list.firstVisibleItemIndex == 0 && list.firstVisibleItemScrollOffset == 0

            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                if (!hasCalendar || available.y >= 0 || reveal <= 0f || !atTop) return Offset.Zero
                // pushing up: the month goes back first, with your finger
                val shown = reveal.coerceAtMost(full)
                val used = maxOf(available.y, -shown)
                reveal = shown + used
                return Offset(0f, used)
            }

            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                if (!hasCalendar || available.y <= 0 || source != NestedScrollSource.UserInput) return Offset.Zero
                if (full > 0f && reveal >= full) return Offset.Zero
                // pulling down past the top: the month comes out, with your finger
                reveal = if (full > 0f) (reveal + available.y).coerceAtMost(full) else reveal + available.y
                return Offset(0f, available.y)
            }

            override suspend fun onPreFling(available: Velocity): Velocity {
                if (!hasCalendar || full <= 0f || reveal <= 0f || reveal >= full) {
                    if (reveal >= full && full > 0f) calendar = true
                    if (reveal <= 0f) calendar = false
                    return Velocity.Zero
                }
                val open = when {
                    available.y > 600f -> true
                    available.y < -600f -> false
                    else -> reveal > full * (if (calendar) 0.7f else 0.3f)
                }
                animate(reveal, if (open) full else 0f, initialVelocity = available.y, animationSpec = tween(240)) { v, _ -> reveal = v }
                calendar = open
                return available
            }
        }
    }
    LazyColumn(
        Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.statusBars).nestedScroll(connection),
        state = list,
        contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 4.dp, bottom = 120.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item("header") {
            Column {
            Row(Modifier.fillMaxWidth().height(72.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f).then(if (title == null) Modifier.clickable {
                    if (full <= 0f) { reveal = Float.MAX_VALUE; calendar = true } else settle(!calendar)
                } else Modifier)) {
                    if (title != null) {
                        Text(title, style = TextStyle(fontSize = 30.sp, fontWeight = FontWeight.Bold, color = Halo.ink))
                        Text(com.ralphgeb.halo.core.Format.dayTitle(state.selected), style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Halo.secondary))
                    } else {
                        Text(state.selected.format(DateTimeFormatter.ofPattern("EEEE", Locale.getDefault())) + if (calendar) "  ▴" else "  ▾",
                            style = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.Bold, color = Halo.ink))
                        Text(state.selected.format(DateTimeFormatter.ofPattern("d MMMM", Locale.getDefault())),
                            style = TextStyle(fontSize = 30.sp, fontWeight = FontWeight.Light, color = Halo.ink))
                    }
                }
                if (state.syncing) {
                    Row(
                        Modifier.clip(CircleShape).background(Halo.card).padding(horizontal = 10.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        CircularProgressIndicator(Modifier.size(12.dp), color = Halo.secondary, strokeWidth = 1.5.dp)
                        Spacer(Modifier.width(6.dp))
                        Text("Syncing", style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Halo.secondary))
                    }
                    Spacer(Modifier.width(8.dp))
                }
                if (!state.isToday) {
                    Text("Today", Modifier.clip(CircleShape).background(Halo.card).clickable { actions.select(HaloTime.today()) }
                        .padding(horizontal = 12.dp, vertical = 7.dp),
                        style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Halo.ink))
                    Spacer(Modifier.width(8.dp))
                }
                // the band's battery, where it shares it (Fitbit), on Today
                if (title == null) state.battery?.let { b ->
                    val low = (b.level ?: 100) <= 20 || b.status == "Low" || b.status == "Empty"
                    Row(
                        Modifier.clip(CircleShape).background(Halo.card).clickable { actions.openSettings() }.padding(horizontal = 10.dp, vertical = 7.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Outlined.BatteryStd, "Band battery", tint = if (low) Halo.accent else Halo.secondary, modifier = Modifier.size(15.dp))
                        Spacer(Modifier.width(3.dp))
                        Text(b.text, style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = if (low) Halo.accent else Halo.secondary))
                    }
                    Spacer(Modifier.width(8.dp))
                }
                Box(Modifier.size(38.dp).clip(CircleShape).background(Halo.card).clickable { actions.openSettings() }, contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.Settings, "Settings", tint = Halo.ink, modifier = Modifier.size(20.dp))
                }
            }
            if (hasCalendar && reveal > 0f) {
                // the month, as much of it as the pull has shown: its bottom edge leads, so it
                // slides down out from under the date, fading in as it comes
                Box(
                    Modifier.fillMaxWidth().clipToBounds()
                        .layout { measurable, constraints ->
                            val p = measurable.measure(constraints.copy(minHeight = 0, maxHeight = Constraints.Infinity))
                            if (full != p.height.toFloat()) full = p.height.toFloat()
                            val h = reveal.coerceIn(0f, p.height.toFloat()).toInt()
                            layout(p.width, h) { p.place(0, h - p.height) }
                        }
                        .graphicsLayer { alpha = if (full > 0f) (reveal / full).coerceIn(0f, 1f) else 0f },
                ) {
                    MonthCalendar(state.snapshot, state.selected, Modifier.padding(top = 4.dp)) { d -> actions.select(d); settle(false) }
                }
            }
            }
        }
        if (state.snapshot.isSample) item("sample") { SampleBanner(state, actions) }
        content()
    }

}

/** Over the sample data: what it is, and how to see your own. */
@Composable
private fun SampleBanner(state: HaloState, actions: PageActions) {
    HaloCard {
        HaloLabel("Sample data", color = Halo.accent)
        val fitbit = state.source == DataSource.FITBIT
        Text(
            when {
                fitbit -> "These are made-up days. Sign in to your Fitbit account to see your own sleep, heart rate, vitals and workouts."
                state.healthConnect == HealthConnectClient.SDK_AVAILABLE -> "These are made-up days. Connect Health Connect, where the Fitbit app keeps your sleep, heart rate and steps, to see your own."
                else -> "These are made-up days. Halo reads your Fitbit through Health Connect, which needs installing or updating first."
            },
            style = Halo.small,
        )
        state.google.error?.takeIf { fitbit }?.let { Text(it, style = Halo.small.copy(color = Halo.accent)) }
        Text(
            when {
                fitbit -> if (state.google.busy) "Signing in…" else "Connect your Fitbit account"
                state.healthConnect == HealthConnectClient.SDK_AVAILABLE -> "Connect Health Connect"
                else -> "Get Health Connect"
            },
            Modifier.fillMaxWidth().clip(CircleShape).background(Halo.ink).clickable { actions.connect() }.padding(vertical = 12.dp),
            style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Halo.background, textAlign = androidx.compose.ui.text.style.TextAlign.Center),
        )
    }
}
