# Halo for Android

Native Android version of Halo (Kotlin, Jetpack Compose). Reads Fitbit data through
**Health Connect**, where the Fitbit app keeps it on Android. Read only.

- `core/` — plain Kotlin: models, scores (recovery, effort, sleep), cardio load, balance,
  readiness, sample data. A line-for-line port of the iPhone app's `HaloApp/Shared`, with tests.
- `app/` — the Android app: Today, Fitness, Health and Sleep tabs, Settings, Health Connect sync.

Builds on GitHub (`.github/workflows/android-build.yml`): runs the score tests and builds the
app; the APK is in the run's artifacts. The iPhone app and its workflows are separate and untouched.
