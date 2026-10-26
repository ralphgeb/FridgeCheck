import Foundation

/// The kinds of workout Halo knows, each with a name and a symbol. Fitbit's own names are mapped
/// onto these, and you can change any workout's type by hand.
enum ActivityType: String, CaseIterable, Identifiable, Codable {
    case running, walking, hiking, cycling, indoorCycling, swimming, rowing, elliptical, stairs
    case strength, functional, hiit, crossTraining, core, yoga, pilates, stretching, mindAndBody, cooldown
    case dance, boxing, martialArts, jumpRope, climbing
    case tennis, padel, badminton, squash, tableTennis, football, basketball, volleyball, golf
    case skiing, snowboarding, skating, surfing, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .running: return "Run"
        case .walking: return "Walk"
        case .hiking: return "Hike"
        case .cycling: return "Ride"
        case .indoorCycling: return "Indoor cycling"
        case .swimming: return "Swim"
        case .rowing: return "Rowing"
        case .elliptical: return "Elliptical"
        case .stairs: return "Stair climber"
        case .strength: return "Strength training"
        case .functional: return "Functional training"
        case .hiit: return "HIIT"
        case .crossTraining: return "Cross training"
        case .core: return "Core"
        case .yoga: return "Yoga"
        case .pilates: return "Pilates"
        case .stretching: return "Stretching"
        case .mindAndBody: return "Mind and body"
        case .cooldown: return "Cooldown"
        case .dance: return "Dance"
        case .boxing: return "Boxing"
        case .martialArts: return "Martial arts"
        case .jumpRope: return "Jump rope"
        case .climbing: return "Climbing"
        case .tennis: return "Tennis"
        case .padel: return "Padel"
        case .badminton: return "Badminton"
        case .squash: return "Squash"
        case .tableTennis: return "Table tennis"
        case .football: return "Football"
        case .basketball: return "Basketball"
        case .volleyball: return "Volleyball"
        case .golf: return "Golf"
        case .skiing: return "Skiing"
        case .snowboarding: return "Snowboarding"
        case .skating: return "Skating"
        case .surfing: return "Surfing"
        case .other: return "Workout"
        }
    }

    var symbol: String {
        switch self {
        case .running: return "figure.run"
        case .walking: return "figure.walk"
        case .hiking: return "figure.hiking"
        case .cycling: return "figure.outdoor.cycle"
        case .indoorCycling: return "figure.indoor.cycle"
        case .swimming: return "figure.pool.swim"
        case .rowing: return "figure.rower"
        case .elliptical: return "figure.elliptical"
        case .stairs: return "figure.stair.stepper"
        case .strength: return "figure.strengthtraining.traditional"
        case .functional: return "figure.strengthtraining.functional"
        case .hiit: return "figure.highintensity.intervaltraining"
        case .crossTraining: return "figure.cross.training"
        case .core: return "figure.core.training"
        case .yoga: return "figure.yoga"
        case .pilates: return "figure.pilates"
        case .stretching: return "figure.flexibility"
        case .mindAndBody: return "figure.mind.and.body"
        case .cooldown: return "figure.cooldown"
        case .dance: return "figure.dance"
        case .boxing: return "figure.boxing"
        case .martialArts: return "figure.martial.arts"
        case .jumpRope: return "figure.jumprope"
        case .climbing: return "figure.climbing"
        case .tennis: return "figure.tennis"
        case .padel: return "figure.racquetball"
        case .badminton: return "figure.badminton"
        case .squash: return "figure.squash"
        case .tableTennis: return "figure.table.tennis"
        case .football: return "figure.soccer"
        case .basketball: return "figure.basketball"
        case .volleyball: return "figure.volleyball"
        case .golf: return "figure.golf"
        case .skiing: return "figure.skiing.downhill"
        case .snowboarding: return "figure.snowboarding"
        case .skating: return "figure.skating"
        case .surfing: return "figure.surfing"
        case .other: return "figure.mixed.cardio"
        }
    }

    /// Best match for the name Fitbit gives an exercise ("RUNNING", "Weight training", "Spinning"…).
    init(fitbit raw: String) {
        let s = raw.lowercased().replacingOccurrences(of: "_", with: " ")
        let rules: [(ActivityType, [String])] = [
            (.indoorCycling, ["spin", "indoor cycl", "stationary", "indoor bike"]),
            (.cycling, ["cycl", "bike", "biking", "ride"]),
            (.hiking, ["hike", "hiking"]),
            (.running, ["run", "jog", "treadmill"]),
            (.walking, ["walk"]),
            (.swimming, ["swim"]),
            (.rowing, ["row"]),
            (.elliptical, ["elliptical"]),
            (.stairs, ["stair", "step"]),
            (.hiit, ["hiit", "interval"]),
            (.crossTraining, ["crossfit", "cross train", "bootcamp", "circuit"]),
            (.functional, ["functional", "kettlebell"]),
            (.strength, ["strength", "weight", "lifting", "resistance"]),
            (.core, ["core", "abs"]),
            (.yoga, ["yoga"]),
            (.pilates, ["pilates"]),
            (.stretching, ["stretch", "flexib", "mobility"]),
            (.mindAndBody, ["meditat", "breath", "mind", "tai chi"]),
            (.dance, ["dance", "zumba"]),
            (.boxing, ["box", "kickbox"]),
            (.martialArts, ["martial", "karate", "judo", "jiu", "taekwondo", "mma"]),
            (.jumpRope, ["rope", "skipping"]),
            (.climbing, ["climb", "boulder"]),
            (.padel, ["padel", "racquetball"]),
            (.tableTennis, ["table tennis", "ping pong"]),
            (.tennis, ["tennis"]),
            (.badminton, ["badminton"]),
            (.squash, ["squash"]),
            (.football, ["soccer", "football", "futsal"]),
            (.basketball, ["basketball"]),
            (.volleyball, ["volleyball"]),
            (.golf, ["golf"]),
            (.snowboarding, ["snowboard"]),
            (.skiing, ["ski"]),
            (.skating, ["skat"]),
            (.surfing, ["surf", "paddle"]),
        ]
        self = rules.first { _, words in words.contains { s.contains($0) } }?.0 ?? .other
    }
}
