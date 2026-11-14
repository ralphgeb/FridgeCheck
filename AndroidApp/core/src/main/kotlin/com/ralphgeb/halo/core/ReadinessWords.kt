package com.ralphgeb.halo.core

/** What readiness means, in ten ways per level (the same as the iPhone app). */
object ReadinessWords {
    /** The same day always reads the same; the next day at the same level reads differently. */
    fun words(readiness: Double?, day: java.time.LocalDate): Pair<String, String> {
        if (readiness == null) return "Waiting for last night" to "Wear your band to sleep and Halo will tell you how ready you are."
        val set = when {
            readiness >= 0.8 -> PEAK
            readiness >= 0.6 -> READY
            readiness >= 0.4 -> EASY
            else -> REST
        }
        // 7 shares nothing with 10, so neighbouring days never land on the same line
        val i = Math.floorMod(day.toEpochDay() * 7, set.size.toLong()).toInt()
        return set[i]
    }

    private val PEAK = listOf(
        "Go break something" to "Everything's in your favour. Push the pace, go long or lift heavy.",
        "Green light" to "Your body's fully charged. Today's the day for the session you've been putting off.",
        "Fully loaded" to "Recovered, rested and ready. Chase a personal best.",
        "Big day energy" to "Your numbers are as good as they get. Make the hard workout count.",
        "Primed" to "Heart, sleep and recovery all line up. Go for intervals, hills or heavy sets.",
        "All systems go" to "No reason to hold back. Go further or faster than usual.",
        "Peak form" to "This is what well rested looks like. Spend it on something tough.",
        "Let it rip" to "Your recovery has your back today. Race it, climb it, lift it.",
        "Ready to roar" to "Plenty in the tank. Try the effort you'd skip on a tired day.",
        "On fire" to "A rare top-score day. Don't waste it on the sofa.",
    )

    private val READY = listOf(
        "Ready for exercise" to "Train as planned. Save the all-out efforts for a fresher day.",
        "Good to go" to "Solid recovery. A normal training day suits you well.",
        "Steady and strong" to "Your body can take a proper workout. Keep the hardest efforts short.",
        "In good shape" to "Go for your usual session, and listen in if the legs feel heavy.",
        "Ready to roll" to "Enough in the tank for real work. Just don't empty it.",
        "Game on" to "A good day for a moderate run, ride or gym session.",
        "Solid footing" to "Recovered well. Build on it with a steady, honest effort.",
        "Warmed up" to "Your numbers say yes to training. Keep one gear in reserve.",
        "Cleared for takeoff" to "Train with intent today, finish feeling you could do a little more.",
        "Nicely charged" to "Good recovery. Tempo work or a strong steady session fits.",
    )

    private val EASY = listOf(
        "Keep it light" to "A walk, an easy spin or some mobility will do more good than a hard session.",
        "Easy does it" to "Your body's half way there. Move, but keep it conversational.",
        "Cruise control" to "Nothing hard today. An easy pace now means a better session tomorrow.",
        "Gentle day" to "Stretch, walk or do some yoga. Let recovery catch up.",
        "Ease off" to "Not a day for records. Light movement helps more than pushing.",
        "Take it slow" to "A relaxed session is fine. If it starts to hurt, call it.",
        "Half charge" to "Enough for a stroll or a light ride, not for intervals.",
        "Recharge mode" to "Keep your heart rate low today and you'll bounce back faster.",
        "Low gear" to "Easy movement, more water and an early night will pay off.",
        "Steady, not heavy" to "Skip the hard stuff. Technique, mobility or a long walk fit nicely.",
    )

    private val REST = listOf(
        "Take a day off" to "Your body is still catching up. Rest, eat well and get to bed early.",
        "Rest day" to "Recovery is training too. Today, let your body rebuild.",
        "Recharge" to "Running low. Put your feet up and give tonight's sleep a head start.",
        "Hit pause" to "Your numbers ask for a break. Tomorrow will thank you.",
        "Battery low" to "Skip the workout and focus on food, water and sleep.",
        "Sofa approved" to "A rest day now beats an injury later.",
        "Recover first" to "Your body's working hard behind the scenes. Let it.",
        "Slow it down" to "A short walk at most. The rest is up to sleep.",
        "Off duty" to "No training today. Fill up on rest and you'll come back stronger.",
        "Refuel" to "Eat well, drink plenty and get to bed early tonight.",
    )

}
