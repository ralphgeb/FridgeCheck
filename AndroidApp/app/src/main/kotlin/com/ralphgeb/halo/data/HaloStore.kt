package com.ralphgeb.halo.data

import android.app.Application
import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ralphgeb.halo.core.CardioLoad
import com.ralphgeb.halo.core.DayMetrics
import com.ralphgeb.halo.core.HaloTime
import com.ralphgeb.halo.core.HeartMinutes
import com.ralphgeb.halo.core.Profile
import com.ralphgeb.halo.core.SampleData
import com.ralphgeb.halo.core.Snapshot
import com.ralphgeb.halo.core.Targets
import com.ralphgeb.halo.widget.Widgets
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.ObjectInputStream
import java.io.ObjectOutputStream
import java.time.LocalDate

/** Where Halo reads your Fitbit data from. */
enum class DataSource(val title: String, val detail: String) {
    /** Straight from your Fitbit account (Google Health API): everything the iPhone app shows. */
    FITBIT("Fitbit account", "Sign in with Google. Everything Fitbit measures, including skin temperature and heart-rate zones."),
    /** What the Fitbit app copies into Health Connect on this phone: less, but no sign-in. */
    HEALTH_CONNECT("Health Connect", "What the Fitbit app shares with Health Connect on this phone. Less detail, no sign-in."),
}

/** Everything the screens show. */
data class HaloState(
    val snapshot: Snapshot,
    val selected: LocalDate = HaloTime.today(),
    val syncing: Boolean = false,
    val lastSync: Long? = null,
    val error: String? = null,
    /** HealthConnectClient.SDK_AVAILABLE and friends. */
    val healthConnect: Int = HealthConnectClient.SDK_UNAVAILABLE,
    val connected: Boolean = false,
    val report: List<SyncLine> = emptyList(),
    val source: DataSource = DataSource.FITBIT,
    val google: GoogleAuth.State = GoogleAuth.State(),
    val onboarded: Boolean = true,
    /** The band's battery (Fitbit, through your account), read after each sync. */
    val battery: GoogleHealthClient.Battery? = null,
    /** Signed in to Fitbit before Halo asked to see your devices: allow it once for the battery. */
    val batteryNeedsPermission: Boolean = false,
) {
    val isToday: Boolean get() = selected == HaloTime.today()
}

/**
 * The app's single source of truth, as HealthStore is on the iPhone: a year of days kept on the
 * phone, synced from Health Connect (only what's new each time), and their scores.
 */
class HaloStore(app: Application) : AndroidViewModel(app) {
    private val prefs = app.getSharedPreferences("halo", Context.MODE_PRIVATE)
    private val healthConnect = HealthConnectSource(app)
    private val fitbit = GoogleHealthClient { GoogleAuth.accessToken() }
    private val cacheFile = File(app.filesDir, "days.bin")

    private val _state = MutableStateFlow(HaloState(Snapshot(emptyList(), loadTargets(), loadProfile(), isSample = true)))
    val state: StateFlow<HaloState> = _state.asStateFlow()

    companion object {
        const val HISTORY_DAYS = 365L
        const val RECENT_DAYS = 10
        private const val STAGES_FIX_KEY = "readAgain.sleepStages"

        fun targets(prefs: android.content.SharedPreferences) = Targets(
            sleepNeedHours = prefs.getFloat("sleepNeedHours", 7.5f).toDouble(),
            steps = prefs.getFloat("steps", 10_000f).toDouble(),
            zoneMinutes = prefs.getFloat("zoneMinutes", 30f).toDouble(),
        )

        fun profile(prefs: android.content.SharedPreferences) = Profile(
            male = prefs.getBoolean("male", true),
            birthYear = prefs.getInt("birthYear", 1990),
            heightCm = prefs.getFloat("heightCm", 178f).toDouble(),
            weightKg = prefs.getFloat("weightKg", 78f).toDouble(),
        )

        /** The days kept on the phone (empty if there are none, or they can't be read). */
        @Suppress("UNCHECKED_CAST")
        fun readCache(file: File): List<DayMetrics> = runCatching {
            if (!file.exists()) return emptyList()
            ObjectInputStream(file.inputStream().buffered()).use { it.readObject() as ArrayList<DayMetrics> }
        }.getOrDefault(emptyList())
    }

    init {
        HaloTime.weekStartsOnMonday = prefs.getBoolean("weekStartsOnMonday", true)
        GoogleAuth.init(app)
        val source = runCatching { DataSource.valueOf(prefs.getString("source", null) ?: "FITBIT") }.getOrDefault(DataSource.FITBIT)
        _state.update { it.copy(source = source, onboarded = prefs.getBoolean("onboarded", false)) }
        // signing in to (or out of) the Fitbit account: read straight away
        _state.update { it.copy(google = GoogleAuth.state.value) }
        viewModelScope.launch {
            GoogleAuth.state.drop(1).collect { g ->
                val before = _state.value.google
                _state.update { it.copy(google = g) }
                // signed in or out, or signed in again (to allow the battery): read straight away
                val signedInAgain = before.busy && !g.busy && g.connected
                if (_state.value.source == DataSource.FITBIT && (g.connected != before.connected || signedInAgain)) {
                    refreshConnection()
                    sync()
                }
            }
        }
        viewModelScope.launch {
            val cached = withContext(Dispatchers.IO) { loadCache() }
            val lastSync = prefs.getLong("lastSync", 0L).takeIf { it > 0 }
            _state.update { it.copy(lastSync = lastSync) }
            if (cached.isNotEmpty()) publish(cached, sample = false) else publish(emptyList(), sample = true)
            refreshConnection()
            sync()
        }
    }

    /** Checks whether the chosen source is there and what Halo may read. */
    suspend fun refreshConnection() {
        val status = healthConnect.status()
        val connected = when (_state.value.source) {
            DataSource.FITBIT -> GoogleAuth.isConnected
            DataSource.HEALTH_CONNECT -> runCatching { healthConnect.isConnected() }.getOrDefault(false)
        }
        _state.update { it.copy(healthConnect = status, connected = connected) }
    }

    /** Reads from somewhere else: the days kept so far are from the old source, so they go. */
    fun setSource(s: DataSource) {
        if (s == _state.value.source) return
        prefs.edit().putString("source", s.name).remove("lastSync").apply()
        _state.update { it.copy(source = s, report = emptyList(), error = null, lastSync = null) }
        viewModelScope.launch {
            withContext(Dispatchers.IO) { cacheFile.delete() }
            publish(emptyList(), sample = true)
            refreshConnection()
            sync()
        }
    }

    fun finishOnboarding() {
        prefs.edit().putBoolean("onboarded", true).apply()
        _state.update { it.copy(onboarded = true) }
    }

    /** Shows the setup pages again (from Settings). */
    fun replayOnboarding() = _state.update { it.copy(onboarded = false) }

    /** After the permission screen. */
    fun onPermissionsResult() {
        viewModelScope.launch {
            refreshConnection()
            sync()
        }
    }

    fun select(date: LocalDate) = _state.update { it.copy(selected = date) }

    /**
     * Reads what's new: the whole year the first time, then the last ten days (all that changes).
     * Merging and the heart-rate figures are worked out away from the main thread.
     */
    fun sync() {
        if (_state.value.syncing) return
        if (!_state.value.connected) {
            if (!_state.value.snapshot.isSample) viewModelScope.launch { publish(emptyList(), sample = true) }
            return
        }
        _state.update { it.copy(syncing = true, error = null) }
        viewModelScope.launch {
            try {
                val stored = if (_state.value.snapshot.isSample) emptyList() else _state.value.snapshot.days
                // the whole year the first time, and once more after the sleep-stages fix (nights read
                // before it may hold Fitbit's quick classic version, with no deep or REM)
                val fullRead = stored.isEmpty() || !prefs.getBoolean(STAGES_FIX_KEY, false)
                val count = if (fullRead) HISTORY_DAYS.toInt() else RECENT_DAYS
                val (fresh, report) = withContext(Dispatchers.IO) {
                    when (_state.value.source) {
                        DataSource.FITBIT -> fitbit.fetchDays(count)
                        DataSource.HEALTH_CONNECT -> healthConnect.fetchDays(count)
                    }
                }
                val merged = withContext(Dispatchers.Default) { merge(stored, fresh, loadProfile()) }
                withContext(Dispatchers.IO) { saveCache(merged) }
                val now = System.currentTimeMillis()
                prefs.edit().putLong("lastSync", now).putBoolean(STAGES_FIX_KEY, true).apply()
                publish(merged, sample = merged.isEmpty())
                // the band's charge, where the band shares it (your Fitbit account)
                var needsPermission = false
                val battery = if (_state.value.source == DataSource.FITBIT) {
                    try { withContext(Dispatchers.IO) { fitbit.battery() } } catch (e: GoogleHealthClient.NeedsPermission) { needsPermission = true; null }
                } else null
                val lines = when {
                    battery != null -> report + SyncLine("Battery", listOfNotNull(battery.device, battery.text).joinToString(" · "), true)
                    needsPermission -> report + SyncLine("Battery", "Allow Halo to see your devices in Settings", false)
                    else -> report
                }
                _state.update { it.copy(lastSync = now, report = lines, battery = battery, batteryNeedsPermission = needsPermission) }
            } catch (e: Exception) {
                _state.update { it.copy(error = e.message ?: "Couldn't sync") }
            } finally {
                _state.update { it.copy(syncing = false) }
            }
        }
    }

    /** Lays the sync's days over the stored ones and works out each recent day's load and zones. */
    private fun merge(stored: List<DayMetrics>, fresh: List<DayMetrics>, profile: Profile): List<DayMetrics> {
        val byDate = stored.associateBy { it.date }.toMutableMap()
        fresh.forEach { f -> byDate[f.date] = f.filling(byDate[f.date]) }
        val today = HaloTime.today()
        val keepFrom = today.minusDays(HealthConnectSource.HEART_RATE_DAYS.toLong() - 1)
        val all = byDate.values.sortedBy { it.date }
        val out = all.map { d ->
            if (d.date.isBefore(keepFrom)) return@map if (d.minuteHeartRate != null) d.copy(minuteHeartRate = null) else d
            val minutes = d.minuteHeartRate
            if (minutes == null || minutes.none { it > 0 }) return@map d
            // resting heart rate: the day's, or the latest one before it
            val resting = d.restingHeartRate ?: all.lastOrNull { it.date < d.date && it.restingHeartRate != null }?.restingHeartRate ?: 60.0
            val samples = HeartMinutes.samples(minutes, d.date)
            val (load, zones) = CardioLoad.fromHeartRate(samples, resting, profile.maxHeartRate)
            d.copy(heartLoad = load, heartZones = zones, heartRate = HeartMinutes.fiveMinuteAverages(samples))
        }
        val cutoff = today.minusDays(HISTORY_DAYS - 1)
        return out.filter { !it.date.isBefore(cutoff) }
    }

    private suspend fun publish(days: List<DayMetrics>, sample: Boolean) {
        val targets = loadTargets()
        val profile = loadProfile()
        val snapshot = withContext(Dispatchers.Default) {
            if (sample) Snapshot(SampleData.days(), targets, profile, isSample = true)
            else Snapshot(days, targets, profile, isSample = false)
        }
        _state.update { it.copy(snapshot = snapshot) }
        // the home-screen widgets show today's scores and vitals; the notes go out when it's time
        Widgets.save(getApplication(), snapshot)
        Notifier.afterSync(getApplication(), snapshot)
    }

    // ---- Settings

    fun setTargets(t: Targets) {
        prefs.edit()
            .putFloat("sleepNeedHours", t.sleepNeedHours.toFloat())
            .putFloat("steps", t.steps.toFloat())
            .putFloat("zoneMinutes", t.zoneMinutes.toFloat())
            .apply()
        republish()
    }

    fun setProfile(p: Profile) {
        prefs.edit()
            .putBoolean("male", p.male)
            .putInt("birthYear", p.birthYear)
            .putFloat("heightCm", p.heightCm.toFloat())
            .putFloat("weightKg", p.weightKg.toFloat())
            .apply()
        republish()
    }

    fun setWeekStartsOnMonday(on: Boolean) {
        prefs.edit().putBoolean("weekStartsOnMonday", on).apply()
        HaloTime.weekStartsOnMonday = on
        republish()
    }

    /** Deletes the days kept on this phone and reads them again. */
    fun deleteData() {
        viewModelScope.launch {
            withContext(Dispatchers.IO) { cacheFile.delete() }
            publish(emptyList(), sample = true)
            sync()
        }
    }

    private fun republish() {
        viewModelScope.launch {
            val s = _state.value.snapshot
            publish(s.days, s.isSample)
        }
    }

    fun loadTargets(): Targets = targets(prefs)

    fun loadProfile(): Profile = profile(prefs)

    // ---- Cache

    private fun loadCache(): List<DayMetrics> = readCache(cacheFile)

    private fun saveCache(days: List<DayMetrics>) {
        val tmp = File(cacheFile.parentFile, "days.tmp")
        ObjectOutputStream(tmp.outputStream().buffered()).use { it.writeObject(ArrayList(days)) }
        tmp.renameTo(cacheFile)
    }
}
