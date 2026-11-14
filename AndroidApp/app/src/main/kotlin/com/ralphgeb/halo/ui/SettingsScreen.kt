package com.ralphgeb.halo.ui

import android.content.Intent
import android.net.Uri
import android.text.format.DateUtils
import androidx.compose.foundation.background
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.health.connect.client.HealthConnectClient
import com.ralphgeb.halo.core.HaloTime
import com.ralphgeb.halo.data.HaloState
import com.ralphgeb.halo.data.HaloStore
import com.ralphgeb.halo.data.DataSource
import com.ralphgeb.halo.data.GoogleAuth

@Composable
fun SettingsScreen(state: HaloState, store: HaloStore, connect: () -> Unit, connectHealthConnect: () -> Unit, onClose: () -> Unit) {
    val context = LocalContext.current
    var targets by remember { mutableStateOf(store.loadTargets()) }
    var profile by remember { mutableStateOf(store.loadProfile()) }
    var weekMonday by remember { mutableStateOf(HaloTime.weekStartsOnMonday) }
    var confirmDelete by remember { mutableStateOf(false) }

    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Column(Modifier.fillMaxSize().background(Halo.background).windowInsetsPadding(WindowInsets.statusBars)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Settings", Modifier.weight(1f), style = TextStyle(fontSize = 28.sp, fontWeight = FontWeight.Bold, color = Halo.ink))
                Text("Done", Modifier.clip(CircleShape).background(Halo.card).clickable(onClick = onClose).padding(horizontal = 14.dp, vertical = 8.dp),
                    style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Halo.ink))
            }
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).navigationBarsPadding(),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                // Source
                PaddedLabel("Source")
                SourcePicker(state, store, connect)
                if (state.connected) {
                    HaloCard {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("Sync now", Modifier.weight(1f).clickable { store.sync() }, style = Halo.body)
                            Text(
                                if (state.syncing) "Syncing…" else state.lastSync?.let { DateUtils.getRelativeTimeSpanString(it).toString() } ?: "Never",
                                style = Halo.small,
                            )
                        }
                        if (state.source == DataSource.FITBIT) {
                            Text("Sign out of your Fitbit account", Modifier.clickable { GoogleAuth.disconnect() }, style = Halo.body)
                        } else {
                            Text("Choose what Halo can read", Modifier.clickable {
                                runCatching { context.startActivity(Intent(HealthConnectClient.ACTION_HEALTH_CONNECT_SETTINGS)) }
                            }, style = Halo.body)
                            Text("In the Fitbit app, turn on Health Connect (You › Settings › Health Connect) so your data reaches Halo. " +
                                "For skin temperature, heart-rate zones and everything else, read from your Fitbit account instead.", style = Halo.small)
                        }
                        state.error?.let { Text(it, style = Halo.small.copy(color = Halo.accent)) }
                    }
                }

                // Look
                PaddedLabel("Look")
                HaloCard { LookPicker() }

                if (state.report.isNotEmpty()) {
                    PaddedLabel("What the last sync found")
                    HaloCard {
                        state.report.forEach { line ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Dot(if (line.ok) Halo.ink.copy(alpha = 0.5f) else Halo.accent)
                                Spacer(Modifier.width(10.dp))
                                Text(line.name, Modifier.weight(1f), style = Halo.body.copy(fontSize = 14.sp))
                                Text(line.result, style = Halo.small.copy(fontSize = 12.sp, textAlign = TextAlign.End))
                            }
                        }
                    }
                }

                // About you
                PaddedLabel("About you")
                HaloCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Sex", Modifier.weight(1f), style = Halo.body)
                        SpanSwitch(listOf("Male", "Female"), if (profile.male) 0 else 1) { profile = profile.copy(male = it == 0); store.setProfile(profile) }
                    }
                    Stepper("Born", "${profile.birthYear}", { profile = profile.copy(birthYear = (profile.birthYear - 1).coerceAtLeast(1930)); store.setProfile(profile) },
                        { profile = profile.copy(birthYear = (profile.birthYear + 1).coerceAtMost(2012)); store.setProfile(profile) })
                    Stepper("Height", "${profile.heightCm.toInt()} cm", { profile = profile.copy(heightCm = (profile.heightCm - 1).coerceAtLeast(120.0)); store.setProfile(profile) },
                        { profile = profile.copy(heightCm = (profile.heightCm + 1).coerceAtMost(220.0)); store.setProfile(profile) })
                    Stepper("Weight", "%.1f kg".format(profile.weightKg), { profile = profile.copy(weightKg = (profile.weightKg - 0.5).coerceAtLeast(35.0)); store.setProfile(profile) },
                        { profile = profile.copy(weightKg = (profile.weightKg + 0.5).coerceAtMost(200.0)); store.setProfile(profile) })
                    Text("Used for the top of your heart-rate zones (your maximum heart rate comes from your age).", style = Halo.small.copy(fontSize = 12.sp))
                }

                // Targets
                PaddedLabel("Targets")
                HaloCard {
                    Stepper("Sleep need", com.ralphgeb.halo.core.Format.duration(targets.sleepNeedHours * 60),
                        { targets = targets.copy(sleepNeedHours = (targets.sleepNeedHours - 0.25).coerceAtLeast(5.0)); store.setTargets(targets) },
                        { targets = targets.copy(sleepNeedHours = (targets.sleepNeedHours + 0.25).coerceAtMost(10.0)); store.setTargets(targets) })
                    Stepper("Steps", com.ralphgeb.halo.core.Format.thousands(targets.steps.toLong()),
                        { targets = targets.copy(steps = (targets.steps - 500).coerceAtLeast(2_000.0)); store.setTargets(targets) },
                        { targets = targets.copy(steps = (targets.steps + 500).coerceAtMost(30_000.0)); store.setTargets(targets) })
                    Stepper("Active minutes", "${targets.zoneMinutes.toInt()} a day",
                        { targets = targets.copy(zoneMinutes = (targets.zoneMinutes - 5).coerceAtLeast(10.0)); store.setTargets(targets) },
                        { targets = targets.copy(zoneMinutes = (targets.zoneMinutes + 5).coerceAtMost(120.0)); store.setTargets(targets) })
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Weeks start on Monday", Modifier.weight(1f), style = Halo.body)
                        Switch(weekMonday, { weekMonday = it; store.setWeekStartsOnMonday(it) },
                            colors = SwitchDefaults.colors(checkedThumbColor = Halo.background, checkedTrackColor = Halo.accent))
                    }
                }

                // Privacy
                PaddedLabel("Privacy")
                HaloCard {
                    Text("Your data stays on this phone. Halo reads from your Fitbit account or Health Connect, never writes, and never sends your health data anywhere else. Halo isn't a medical device.", style = Halo.small)
                    Text("Privacy policy", Modifier.clickable {
                        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://halopro.xyz/privacy/"))) }
                    }, style = Halo.body)
                    Text("Delete all data from this phone", Modifier.clickable { confirmDelete = true }, style = Halo.body.copy(color = Halo.accent))
                }
                HaloCard {
                    Text("Show the setup pages again", Modifier.clickable { onClose(); store.replayOnboarding() }, style = Halo.body)
                }
                Text("Halo for Android · ${versionName(context)}", Modifier.fillMaxWidth().padding(bottom = 40.dp),
                    style = TextStyle(fontSize = 12.sp, color = Halo.tertiary, textAlign = TextAlign.Center))
            }
        }
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete all data from this phone?") },
            text = { Text("Removes the days Halo keeps on this phone, then reads them again. Nothing in your Fitbit account, Health Connect or the Fitbit app is touched.") },
            confirmButton = { TextButton({ store.deleteData(); confirmDelete = false }) { Text("Delete", color = Halo.accent) } },
            dismissButton = { TextButton({ confirmDelete = false }) { Text("Cancel", color = Halo.ink) } },
            containerColor = Halo.card,
        )
    }
}

@Composable
fun Stepper(title: String, value: String, minus: () -> Unit, plus: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f), style = Halo.body)
        Text(value, style = Halo.number(15.sp).copy(color = Halo.secondary))
        Spacer(Modifier.width(12.dp))
        StepButton("−", minus)
        Spacer(Modifier.width(6.dp))
        StepButton("+", plus)
    }
}

@Composable
fun StepButton(label: String, onClick: () -> Unit) {
    Box(Modifier.size(34.dp).clip(CircleShape).background(Halo.track).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Text(label, style = TextStyle(fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = Halo.ink))
    }
}

@Composable
fun PillButton(title: String, onClick: () -> Unit) {
    Text(
        title,
        Modifier.fillMaxWidth().clip(CircleShape).background(Halo.ink).clickable(onClick = onClick).padding(vertical = 12.dp),
        style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Halo.background, textAlign = TextAlign.Center),
    )
}

private fun versionName(context: android.content.Context): String =
    runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: ""

/** Why Halo asks for health data, shown from Health Connect's permission screens. */
@Composable
fun PrivacyScreen(onClose: () -> Unit) {
    Column(
        Modifier.fillMaxSize().background(Halo.background).windowInsetsPadding(WindowInsets.statusBars).padding(20.dp)
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text("Halo and your health data", style = TextStyle(fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Halo.ink))
        listOf(
            "Halo reads your sleep, heart rate, heart rate variability, resting heart rate, steps, active calories, workouts, distance, blood oxygen, breathing rate, skin temperature, weight and VO₂ max from Health Connect or your Fitbit account.",
            "It uses them to work out your recovery, effort and sleep scores and to show your trends. It never writes to Health Connect.",
            "Everything stays on this phone. Halo has no account and no server, and doesn't share or sell your data.",
            "You can change what Halo can read at any time in Health Connect, and delete what Halo keeps in Settings.",
        ).forEach { Text(it, style = Halo.body.copy(color = Halo.secondary)) }
        Spacer(Modifier.height(8.dp))
        PillButton("Done", onClose)
    }
}
