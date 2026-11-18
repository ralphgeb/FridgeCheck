package com.ralphgeb.halo.notify

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.ralphgeb.halo.core.HaloTime
import com.ralphgeb.halo.core.Snapshot
import com.ralphgeb.halo.data.DataSource
import com.ralphgeb.halo.data.GoogleAuth
import com.ralphgeb.halo.data.GoogleHealthClient
import com.ralphgeb.halo.data.HaloStore
import com.ralphgeb.halo.data.HealthConnectSource
import com.ralphgeb.halo.widget.Widgets
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * About once an hour with the app closed: reads today (and yesterday) from your Fitbit account or
 * Health Connect, lays it over the days kept on the phone, and sends the morning or evening note
 * when it's time, and keeps the widgets fresh. It only reads: the app's own sync keeps the days.
 */
class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val ctx = applicationContext
        val prefs = ctx.getSharedPreferences("halo", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("onboarded", false)) return Result.success()
        HaloTime.weekStartsOnMonday = prefs.getBoolean("weekStartsOnMonday", true)
        val cached = HaloStore.readCache(File(ctx.filesDir, "days.bin"))
        if (cached.isEmpty()) return Result.success()
        GoogleAuth.init(ctx)
        val source = runCatching { DataSource.valueOf(prefs.getString("source", null) ?: "FITBIT") }.getOrDefault(DataSource.FITBIT)
        val fresh = runCatching {
            when (source) {
                DataSource.FITBIT -> if (GoogleAuth.isConnected) GoogleHealthClient { GoogleAuth.accessToken() }.fetchDays(2).first else emptyList()
                DataSource.HEALTH_CONNECT -> HealthConnectSource(ctx).fetchDays(2).first
            }
        }.getOrDefault(emptyList())
        val byDate = cached.associateBy { it.date }.toMutableMap()
        fresh.forEach { f -> byDate[f.date] = f.filling(byDate[f.date]) }
        val snapshot = Snapshot(byDate.values.sortedBy { it.date }, HaloStore.targets(prefs), HaloStore.profile(prefs), isSample = false)
        runCatching { Widgets.save(ctx, snapshot) }
        Notifier.afterSync(ctx, snapshot)
        return Result.success()
    }

    companion object {
        /** Starts the hourly check (kept if it's already set up). */
        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<SyncWorker>(1, TimeUnit.HOURS)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork("halo.hourly", ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}
