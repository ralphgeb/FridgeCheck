package com.ralphgeb.halo.notify

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.ralphgeb.halo.MainActivity
import com.ralphgeb.halo.R
import com.ralphgeb.halo.core.Format
import com.ralphgeb.halo.core.HaloTime
import com.ralphgeb.halo.core.Snapshot
import kotlin.math.max
import kotlin.math.min

/**
 * Two notes a day, as on the iPhone, both off your own data: one in the morning about last night
 * once you're up and about (a few hundred steps since you woke), and one in the evening as the day
 * winds down (your steps slow after 8 pm, or 45 minutes before your usual bedtime, by 10 pm at the
 * latest) saying when to aim for bed. Once a day each; the words change and match the day.
 */
object Notifier {
    private const val CHANNEL = "halo.daily"
    private const val PREFS = "halo"
    const val MORNING_KEY = "notifyMorning"
    const val EVENING_KEY = "notifyEvening"
    private const val MORNING_ID = 101
    private const val EVENING_ID = 102

    /** True while Halo is on screen (set by MainActivity): you've seen your night already. */
    @Volatile var appVisible = false

    fun morningOn(context: Context) = prefs(context).getBoolean(MORNING_KEY, true)
    fun eveningOn(context: Context) = prefs(context).getBoolean(EVENING_KEY, true)
    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun canPost(context: Context): Boolean =
        (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
            NotificationManagerCompat.from(context).areNotificationsEnabled()

    /** After a sync (the app's, or the hourly one in the background). */
    fun afterSync(context: Context, s: Snapshot) {
        if (s.isSample || s.days.isEmpty() || !canPost(context)) return
        ensureChannel(context)
        runCatching { morning(context, s) }
        runCatching { evening(context, s) }
    }

    private fun stamp() = HaloTime.today().toString()

    private fun morning(context: Context, s: Snapshot) {
        val p = prefs(context)
        if (!morningOn(context) || p.getString("notifyMorningSent", null) == stamp()) return
        val now = System.currentTimeMillis()
        val hour = HaloTime.hourOf(now)
        if (hour !in 4..12) return
        val today = HaloTime.today()
        val day = s.day(today) ?: return
        val sleep = day.sleep ?: return
        if (now - sleep.end > 6 * 3_600_000L) return
        // wait until you're up and about: a few hundred steps since you woke, or 2½ hours after
        val wakeHour = HaloTime.hourOf(sleep.end)
        val sinceWake = day.hourlySteps?.let { h -> (wakeHour..max(wakeHour, hour)).sumOf { h.getOrElse(it) { 0.0 } } } ?: (day.steps ?: 0).toDouble()
        if (sinceWake < 250 && now - sleep.end < 2.5 * 3_600_000) return
        val sc = s.scores(today)
        val recovery = sc.recovery?.let { Math.round(it * 100) }
        val score = sc.sleep?.let { Math.round(it * 100) }
        if (recovery == null && score == null) return
        val asleep = Format.duration(sleep.minutesAsleep)
        val level = recovery?.let { if (it >= 67) 2 else if (it >= 34) 1 else 0 } ?: score?.let { if (it >= 80) 2 else if (it >= 60) 1 else 0 } ?: 1
        val r = recovery?.let { "$it%" } ?: "–"
        val lines = when (level) {
            2 -> listOf(
                "Recovery $r. You're charged up" to "$asleep of sleep did its job. Today's a day to go for it.",
                "Green light this morning" to "Recovery $r after $asleep asleep. Plan something you'll enjoy pushing.",
                "Well slept, well recovered" to "Sleep score ${score ?: "–"}, recovery $r. Make the most of it.",
                "Strong start" to "Recovery $r, sleep score ${score ?: "–"}. The rest of the day is yours.",
            )
            1 -> listOf(
                "Recovery $r. A steady day" to "$asleep asleep. Train as usual, keep the hardest efforts short.",
                "Morning check-in" to "Sleep score ${score ?: "–"}, recovery $r. See what pulled it either way.",
                "Your night in numbers" to "$asleep asleep, woke at ${Format.time(sleep.end)}, recovery $r.",
                "A solid, ordinary night" to "$asleep and recovery $r. Normal day, normal plans.",
            )
            else -> listOf(
                "Recovery $r. Go easy today" to "$asleep of sleep wasn't quite enough. Your body's still catching up.",
                "Take it gently this morning" to "Recovery $r. A walk beats a hard workout today.",
                "Low battery" to "Recovery $r. Water, good food and an early night will turn it around.",
                "Recharge day" to "Sleep score ${score ?: "–"}, recovery $r. Plan for an early night.",
            )
        }
        // looking at the app already: nothing to tell you
        val (title, body) = lines.random()
        if (!appVisible) post(context, MORNING_ID, title, body, tab = 3)
        p.edit().putString("notifyMorningSent", stamp()).apply()
    }

    private fun evening(context: Context, s: Snapshot) {
        val p = prefs(context)
        if (!eveningOn(context) || p.getString("notifyEveningSent", null) == stamp()) return
        val now = System.currentTimeMillis()
        val today = HaloTime.today()
        // 45 minutes before your usual bedtime (the last two weeks), between 8 pm and 10 pm
        val starts = s.days.takeLast(14).mapNotNull { d -> d.sleep?.let { (it.start - (HaloTime.startOf(d.date) - 6 * 3_600_000L)) / 60_000.0 } }
        val usual = if (starts.isEmpty()) 270.0 else starts.sorted()[starts.size / 2]
        val sendMinutes = min(240.0, max(120.0, usual - 45))
        val latest = HaloTime.startOf(today) + ((18 * 60 + sendMinutes) * 60_000).toLong()
        val eight = HaloTime.startOf(today) + 20 * 3_600_000L
        val hour = HaloTime.hourOf(now)
        val day = s.day(today)
        val quiet = now >= eight && day?.hourlySteps?.let { h -> h.getOrElse(hour) { 0.0 } < 150 && h.getOrElse(hour - 1) { 0.0 } < 150 } == true
        when {
            now >= latest + 90 * 60_000L -> { p.edit().putString("notifyEveningSent", stamp()).apply(); return }   // too late tonight
            now >= latest || quiet -> Unit
            else -> return
        }
        val bed = Format.time(latest + 45 * 60_000L)
        val need = Format.duration(s.targets.sleepNeedHours * 60)
        val steps = day?.steps?.let { "${Format.thousands(it.toLong())} steps" } ?: "your day"
        val effort = s.scores(today).effort?.let { Math.round(it * 100) }
        val level = effort?.let { if (it >= 70) 2 else if (it >= 35) 1 else 0 } ?: 1
        val lines = when (level) {
            2 -> listOf(
                "Time to wind down" to "$steps done. Lights out by $bed and you're up fully charged.",
                "Hard work, now rest" to "Effort $effort today. Recovery happens tonight: bed by $bed.",
                "Day done, and done well" to "$steps. Bed by $bed for a good recovery tomorrow.",
            )
            1 -> listOf(
                "Nearly bedtime" to "$steps today. In bed by $bed gets you your $need.",
                "Time to slow down" to "Dim the lights, park the screen, aim for $bed.",
                "Wind-down time" to "A steady day. Same bedtime as usual makes for better sleep: $bed.",
            )
            else -> listOf(
                "Quiet day today" to "$steps. Keep the evening calm and aim for $need of sleep, bed by $bed.",
                "Recharge night" to "A light day. Sleep well and tomorrow could be a good one. Bed by $bed.",
                "Lights out soon?" to "A rest day is only as good as the sleep after it. Aim for $bed.",
            )
        }
        val (title, body) = lines.random()
        post(context, EVENING_ID, title, body, tab = 0)
        p.edit().putString("notifyEveningSent", stamp()).apply()
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val m = context.getSystemService(NotificationManager::class.java)
        if (m.getNotificationChannel(CHANNEL) == null) {
            m.createNotificationChannel(NotificationChannel(CHANNEL, "Morning and evening", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "How you slept, once you're up, and when to aim for bed"
            })
        }
    }

    @android.annotation.SuppressLint("MissingPermission")
    private fun post(context: Context, id: Int, title: String, body: String, tab: Int) {
        val open = PendingIntent.getActivity(
            context, id,
            Intent(context, MainActivity::class.java).putExtra(MainActivity.EXTRA_TAB, tab).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val n = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        if (canPost(context)) NotificationManagerCompat.from(context).notify(id, n)
    }
}
