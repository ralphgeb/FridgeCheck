package com.ralphgeb.halo.core

import java.text.NumberFormat
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

object Format {
    /** 442 -> "7h 22m" */
    fun duration(minutes: Double): String {
        val m = Math.round(minutes).toInt()
        return if (m >= 60) "${m / 60}h ${"%02d".format(m % 60)}m" else "${m}m"
    }

    /** "Today", "Yesterday", or "Mon 20 Oct" */
    fun dayTitle(date: LocalDate): String {
        val today = HaloTime.today()
        return when (date) {
            today -> "Today"
            today.minusDays(1) -> "Yesterday"
            else -> date.format(DateTimeFormatter.ofPattern("EEE d MMM", Locale.getDefault()))
        }
    }

    fun time(millis: Long): String =
        HaloTime.zoned(millis).format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(Locale.getDefault()))

    fun thousands(n: Long): String = NumberFormat.getIntegerInstance(Locale.getDefault()).format(n)

    /** 0.823 -> "82" */
    fun percent(v: Double): String = Math.round(v * 100).toString()
}
