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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.ObjectInputStream
import java.io.ObjectOutputStream
import java.time.LocalDate

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
) {
    val isToday: Boolean get() = selected == HaloTime.today()
}

/**
 * The app's single source of truth, as HealthStore is on the iPhone: a year of days kept on the
 * phone, synced from Health Connect (only what's new each time), and their scores.
 */
class HaloStore(app: Application) : AndroidViewModel(app) {
    private val prefs = app.getSharedPreferences("halo", Context.MODE_PRIVATE)
    private val source = HealthConnectSource(app)
    private val cacheFile = File(app.filesDir, "days.bin")

    private val _state = MutableStateFlow(HaloState(Snapshot(emptyList(), loadTargets(), loadProfile(), isSample = true)))
    val state: StateFlow<HaloState> = _state.asStateFlow()

    companion object {
        const val HISTORY_DAYS = 365L
        const val RECENT_DAYS = 10
    }

    init {
        HaloTime.weekStartsOnMonday = prefs.getBoolean("weekStartsOnMonday", true)
        viewModelScope.launch {
            val cached = withContext(Dispatchers.IO) { loadCache() }
            val lastSync = prefs.getLong("lastSync", 0L).takeIf { it > 0 }
            _state.update { it.copy(lastSync = lastSync) }
            if (cached.isNotEmpty()) publish(cached, sample = false) else publish(emptyList(), sample = true)
            refreshConnection()
            sync()
        }
    }

    /** Checks whether Health Connect is there and what Halo may read. */
    suspend fun refreshConnection() {
        val status = source.status()
        val connected = runCatching { source.isConnected() }.getOrDefault(false)
        _state.update { it.copy(healthConnect = status, connected = connected) }
    }

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
        viewModelScope.launch {
            if (!_state.value.connected) {
                if (!_state.value.snapshot.isSample) publish(emptyList(), sample = true)
                return@launch
            }
            _state.update { it.copy(syncing = true, error = null) }
            try {
                val stored = if (_state.value.snapshot.isSample) emptyList() else _state.value.snapshot.days
                val count = if (stored.isEmpty()) HISTORY_DAYS.toInt() else RECENT_DAYS
                val (fresh, report) = withContext(Dispatchers.IO) { source.fetchDays(count) }
                val merged = withContext(Dispatchers.Default) { merge(stored, fresh, loadProfile()) }
                withContext(Dispatchers.IO) { saveCache(merged) }
                val now = System.currentTimeMillis()
                prefs.edit().putLong("lastSync", now).apply()
                publish(merged, sample = merged.isEmpty())
                _state.update { it.copy(lastSync = now, report = report) }
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

    fun loadTargets(): Targets = Targets(
        sleepNeedHours = prefs.getFloat("sleepNeedHours", 7.5f).toDouble(),
        steps = prefs.getFloat("steps", 10_000f).toDouble(),
        zoneMinutes = prefs.getFloat("zoneMinutes", 30f).toDouble(),
    )

    fun loadProfile(): Profile = Profile(
        male = prefs.getBoolean("male", true),
        birthYear = prefs.getInt("birthYear", 1990),
        heightCm = prefs.getFloat("heightCm", 178f).toDouble(),
        weightKg = prefs.getFloat("weightKg", 78f).toDouble(),
    )

    // ---- Cache

    @Suppress("UNCHECKED_CAST")
    private fun loadCache(): List<DayMetrics> = runCatching {
        if (!cacheFile.exists()) return emptyList()
        ObjectInputStream(cacheFile.inputStream().buffered()).use { it.readObject() as ArrayList<DayMetrics> }
    }.getOrDefault(emptyList())

    private fun saveCache(days: List<DayMetrics>) {
        val tmp = File(cacheFile.parentFile, "days.tmp")
        ObjectOutputStream(tmp.outputStream().buffered()).use { it.writeObject(ArrayList(days)) }
        tmp.renameTo(cacheFile)
    }
}
