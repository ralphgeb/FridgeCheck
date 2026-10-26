# Halo

A minimal, customisable health tracker for iPhone that reads your Fitbit data.

- Three rings (Recovery, Effort, Sleep) that uncurl into bars as you scroll.
- A pinned date header on every tab. Tap it, or pull the page down, for a month calendar where each day wears its three rings.
- A graph page for every metric, with 1W, 1M, 3M and 6M. Longer spans show one line per week, from the low to the high.
- Cardio load from time in heart-rate zones, with a weekly target that follows your last four weeks (Maintain, Build or Recover).
- Active, resting and total calories. Resting calories come from your height, weight, age and sex.
- A Balance radar of the week: sleep, HRV, recovery, steps, weekly cardio load and resting heart rate. Tap a spoke to highlight it.
- Cards on Today can be rearranged: hold one and drag it.
- Sleep stages, heart rate by stage, sleep debt against your need, and a suggested bedtime.
- Three widgets (rings, Balance radar, Lock Screen).

One main colour and one accent. Settings has six presets, your own colours for Light and Dark mode, and four number typefaces. SwiftUI, iOS 17+, no third-party libraries.

## Project layout

```
HaloApp/
  project.yml            XcodeGen project (app + widget extension)
  Sources/               the app
    HaloApp.swift          entry point, tabs, background refresh
    HealthStore.swift      data, scores, sync, widget snapshot
    Common/HaloPage.swift  pinned date header, month calendar, scroll tracking
    Metrics/               every metric and its 1W–6M graph page
    Today/                 dials, tiles, trend chart, cardio, calories, Balance
    Health/                vitals monitor and grouped metrics
    Sleep/                 stage graph, sleep debt, bedtime
    Settings/              connect Fitbit, appearance, body, targets
    Sync/                  Google sign-in (PKCE), Keychain, Google Health API client
  Shared/                compiled into the app and the widget
    Appearance.swift       colour presets and custom palettes (shared with widgets)
    Theme.swift            colours and type, read from the current appearance
    Graphics.swift         triple ring and radar chart
    ScoreEngine.swift      how the three scores are calculated
    SampleData.swift       realistic sample data until Fitbit is connected
  Widget/                rings, Balance radar, Lock Screen gauges
  mockup/index.html      clickable HTML mockup of the design
```

## Build

On a Mac with Xcode 16 or later:

```
brew install xcodegen
cd HaloApp
xcodegen generate
open Halo.xcodeproj
```

Pick your team under Signing & Capabilities for both targets, then run. The app opens on sample data.

GitHub Actions runs `Halo – build check` on every push (simulator build, no signing). `Halo – upload to TestFlight` is manual and needs the same four secrets as your calendar app: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY`, `APPLE_TEAM_ID`. Register the bundle IDs `com.ralphgeb.halo` and `com.ralphgeb.halo.widget` and the App Group `group.com.ralphgeb.halo` first.

## Connect Fitbit

Google turned off the old Fitbit Web API at the end of October 2026. Fitbit data is now read through the **Google Health API** with a Google sign-in.

1. In Google Cloud console, create a project and enable **Google Health API**.
2. OAuth consent screen: External, add the three scopes below, and add your Google account as a test user.
3. Credentials → Create OAuth client ID → **iOS**, bundle ID `com.ralphgeb.halo`.
4. Put the client ID in `project.yml` (`GOOGLE_CLIENT_ID`, and the reversed form in `GOOGLE_REVERSED_CLIENT_ID`), regenerate, run, and tap Settings → Connect Fitbit.

Scopes (read-only):

```
https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly
https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly
https://www.googleapis.com/auth/googlehealth.sleep.readonly
```

Things to know:

- While the consent screen is in "Testing", Google expires refresh tokens after 7 days, so you'll need to reconnect weekly until the app is verified.
- Google has said it isn't onboarding every new project yet. If enabling the API is refused, the app keeps working on sample data.
- The daily HRV, SpO₂, breathing and temperature responses are parsed loosely because their field names aren't fully documented yet. Check them against your first real sync.

## Scores

All three compare you with your own last 30 days.

- **Recovery**: HRV vs baseline (50%), resting heart rate vs baseline (30%), sleep score (20%).
- **Effort**: Active Zone Minutes vs target (65%), steps vs target (35%).
- **Sleep**: time asleep vs need (55%), deep + REM share (20%), efficiency (15%), bedtime consistency (10%).

The weights live in `Shared/ScoreEngine.swift`.
