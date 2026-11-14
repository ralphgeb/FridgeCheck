package com.ralphgeb.halo.core

import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.temporal.TemporalAdjusters

/**
 * Halo's clock. Times are epoch milliseconds (as the iPhone app's Dates are seconds since 1970);
 * days are the local calendar day you woke up on. The zone is the phone's, swappable for tests.
 */
object HaloTime {
    var zone: ZoneId = ZoneId.systemDefault()

    /** Whether weeks start on Monday (else Sunday), for cardio load and the calendar. */
    var weekStartsOnMonday: Boolean = true

    fun now(): Long = System.currentTimeMillis()

    fun today(): LocalDate = LocalDate.now(zone)

    fun dayOf(millis: Long): LocalDate = Instant.ofEpochMilli(millis).atZone(zone).toLocalDate()

    fun startOf(day: LocalDate): Long = day.atStartOfDay(zone).toInstant().toEpochMilli()

    fun zoned(millis: Long): ZonedDateTime = Instant.ofEpochMilli(millis).atZone(zone)

    /** Minutes since the start of the day `millis` falls on. */
    fun minuteOfDay(millis: Long): Int = zoned(millis).let { it.hour * 60 + it.minute }

    fun hourOf(millis: Long): Int = zoned(millis).hour

    /** The first day of the week that contains `day`. */
    fun weekStart(day: LocalDate): LocalDate {
        val first = if (weekStartsOnMonday) DayOfWeek.MONDAY else DayOfWeek.SUNDAY
        return day.with(TemporalAdjusters.previousOrSame(first))
    }

    /** A clock time on `day`, as epoch millis. */
    fun at(day: LocalDate, hour: Int, minute: Int = 0): Long =
        day.atTime(hour, minute).atZone(zone).toInstant().toEpochMilli()
}

const val MINUTE_MS = 60_000L
const val HOUR_MS = 3_600_000L
const val DAY_MS = 86_400_000L
