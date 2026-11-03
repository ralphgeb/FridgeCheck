# Halo: handoff notes

Halo is a SwiftUI health tracker for iOS. It lives in `HaloApp/` in the `ralphgeb/FridgeCheck` repo.

- **Branch:** `claude/loving-carson-pfwq6a`. It is also the default branch and the Pages branch. Commit straight to it; don't open a PR unless asked.
- **Testing:** the owner tests through TestFlight only. There is no local Xcode, so CI is the compiler.

Last updated: 3 Nov 2026. The latest commit is `e4ad70c`, and it is on TestFlight (run 35, succeeded).

---

## Current goal

The owner is wearing **Fitbit Air, Whoop and an Apple Watch at the same time** to compare them.

- **Fitbit (Google Health)** is the main source. It drives the rings and every tab.
- **Compare page:** the test happens in **Settings › Testing › Compare bands**. It is a temporary page, deleted once testing ends.
- **Copy all data:** the page has a button that copies 14 days of all three bands as text. The owner will paste it back to us so we can tune Halo's scores against the bands.

The first things to look at are:
1. **Score gap:** the Compare data once it's pasted back (Halo's recovery from Whoop data was 62, Whoop's own was 18).
2. **Apple Watch recovery:** it should appear from the 3rd morning of watch data.
3. **First-sync speed:** check that a full year per source isn't too slow.

---

## How to ship (every change)

1. **Push:** commit and push to `claude/loving-carson-pfwq6a`.
2. **Build check:** `.github/workflows/halo-build.yml` runs on push. It is the compile check.
3. **Upload:** if the build is green, trigger `.github/workflows/halo-testflight.yml` with the GitHub MCP tool `actions_run_trigger` (`run_workflow`, `ref: claude/loving-carson-pfwq6a`).
4. **Check back:** schedule a check with `send_later`, about 8–10 minutes for TestFlight. Then tell the owner the result. macOS runners sometimes sit in the queue 10+ minutes; re-check rather than assume failure.
5. **If CI is red:** read the logs with `get_job_logs` (`run_id`, `failed_only: true`). Fix, push, and repeat.
6. **Mockup:** for UI changes, update `HaloApp/mockup/index.html` and republish it to https://claude.ai/artifact/1PRAJBLsGR1aXHY8gQ8m5s with the same file path.
   - Test it with Playwright. Launch with `executablePath: '/opt/pw-browsers/chromium'`; the default launch fails.
   - Another session republished it once. If the publish is refused, merge with the live version rather than resending.
7. **Algorithms doc:** when scoring logic changes, update https://claude.ai/artifact/QfDdoAZny7xmfcxPnyxMMW.
   - Source file: `/tmp/claude-0/-home-user-FridgeCheck/18944bde-f412-5762-a7b7-fb82f66974ce/scratchpad/halo-algorithms.html`.
   - The scratchpad may be gone in a new session. Read the artifact back first.

**Secrets:** `ASC_*`, `APPLE_TEAM_ID`, `CLOUDFLARE_*` and `WHOOP_*` live only in GitHub Actions secrets. Never print them or ask for them in chat.

**Commits:** no model names in commits. End each message with:

```
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01JPGcR1D6aQyKnogjAhebKj
```

---

## What's done (recent, newest first)

### Tidy-up: zones card, tab re-tap, sliding header, Face ID checkout (5c190fe)
- **Heart rate zones card with Whoop** (`Sources/Today/HeartZones.swift`): `hasZoneChart` is now
  true when there are readings, zone minutes, or the source is Whoop. An empty chart shows
  `NoHeartReadingsNote` (for Whoop: turn on Apple Health › Heart Rate in the Whoop app).
  `WhoopClient` asks for Apple Health once (`whoop.healthAsked`) if Whoop was connected without it.
- **Tab re-tap** (`HaloApp.swift` + `HaloPage.swift`): the TabView selection binding counts taps on
  the already-showing tab (`reselects`), passed down as `\.tabReselect`. `HaloPage.reselected`:
  closes the calendar / scrolls to `"halo.top"` first, then on the next tap `store.select(.now)`.
- **Sliding header** on titled pages (Fitness, Health, Sleep; not Today, not while editing):
  `headerShift` follows the scroll (quick return), `settleHeader()` snaps it on iOS 18, and a
  background strip keeps the status bar plain.
- **Halo Plus checkout** (`Sources/Common/Purchase.swift`): `PlusPurchase` tries StoreKit product
  `com.ralphgeb.halo.plus.monthly`; if it exists (needs creating in App Store Connect) it's a real
  App Store / sandbox purchase. Otherwise `TestCheckoutSheet` (App Store-like sheet, TEST badge)
  confirms with `LAContext` Face ID / passcode, nothing charged. `plus.store` marks a store
  purchase; Settings shows Manage subscription for it, End test subscription otherwise. Restore
  in the Plus sheet. `NSFaceIDUsageDescription` added to project.yml. Use `StoreKit.Transaction`
  (SwiftUI has its own `Transaction`).

### Sources and sync
- **Sources:**
  - Fitbit via Google Health API v4 (`GoogleHealthClient`).
  - Apple Health via HealthKit (`HealthKitClient`).
  - Whoop via API v2 (`WhoopClient`). Its sign-in goes through the Cloudflare Worker `halo-whoop.ralph-gebara.workers.dev`, which holds the client secret.
- **One cache per source:** each source has `Application Support/days-<source>.json`. Switching source shows the saved days straight away, then catches up.
  - The old shared `days.json` moves to the current source on first launch.
  - Sync keys are per source too: `lastSync.<source>` and `lastFullSync.<source>`.
- **History:** `HealthStore.historyDays = 365`.
  - A full sync runs at most every 20 hours. Other syncs read the last 10 days.
  - Fitbit heart rate is fetched only after the last stored minute, at most 2 days back.
  - Minute heart rate (`minuteHeartRate`, 1440 Ints per day) is kept for 14 days.
- **Sample data never mixes in** (`showingSample`).
  - A sync starts from empty when the screen is showing sample data.
  - A banner sits at the top of Today while sample data shows.
  - Sample SpO₂ was 9.x because of a bug; it's fixed.
- **Sync retries:**
  - Every 20 seconds while no real data has come in yet, otherwise every 4 minutes while the app is open.
  - On app open, and on background refresh (about every 15 minutes, best effort).
  - Apple Health background delivery when Apple Health is the main source.
- **Fresh install:** starts signed out. iOS keeps the keychain after an app is deleted, so on first launch with `installed` unset and `onboarded` false, Halo disconnects Google and Whoop.

### Whoop
- **Ledger:** every record (cycles, sleep, recovery, workouts) is kept in `whoop.json` (`WhoopLedger`).
- **Reading:**
  - Each sync reads from the newest record minus 2 days; a twice-daily pass reads 14 days.
  - It re-reads everything if the newest record is more than 14 days old.
  - It reads up to `WhoopClient.monthsKept = 365` days.
  - One-time re-read flags force the ledger to be read again: `hasSteps`, `hasScores` and `hasFullRange`.
- **Requests send both `start` and `end`:** with only `start`, Whoop returned a few days after the start. This was the long "Whoop shows nothing" bug. In the Compare screenshot from 3 Nov, Whoop returned 247 days.
- **Whoop's own scores are used:**
  - Recovery is `recovery_score` and sleep is `sleep_performance_percentage`, stored as `DayMetrics.bandRecovery` and `bandSleepScore`.
  - Hours of sleep = time in bed minus time awake, as the Whoop app counts it.
  - Each night's sleep need is Whoop's (`sleepNeedMinutes`).
- **"Halo thinks":** the factor list shows Halo's own recovery and sleep under Whoop's numbers (`ScoreEngine.factors`).
- **Cardio load:**
  - Each workout's time in Whoop's zones (shares of max heart rate) is converted to Halo's heart-rate-reserve zones (`CardioLoad.fromWhoopZones`).
  - Strain outside workouts adds load, at most 60 a day (`whoopStrainScale` and `loadFromStrain`).
- **Steps and heart rate:**
  - Steps come from cycle `step_count`.
  - Heart rate comes only through Apple Health, filtered to sources whose name or bundle contains "whoop". The `whoop.appleHealth` setting defaults to on, and Halo asks for HealthKit steps and heart rate when Whoop connects.
- **Debugging:**
  - Settings › Sources › **Whoop debug** shows the raw API answers (`WhoopDebugView`).
  - The sync report has per-collection "detail" lines and a "Copy sync details" button.

### Apple Health
- **Watch only in Compare:** `HealthKitClient(watchOnly: true)` filters by `HKDevicePropertyKeyModel == "Watch"`. Google Health and Whoop also write into Apple Health and must not be counted as the watch.
- **Resting heart rate fallback:** if Apple hasn't recorded one, it's the lowest 10-minute average of the night's heart rate.
- **HRV:** Apple gives SDNN, while Fitbit and Whoop give RMSSD, so the numbers aren't directly comparable.

### Scores (`Shared/ScoreEngine.swift`)
- **Sleep:** 40% duration, 25% deep and REM (targets 20% and 23% of the night), 15% efficiency, 10% calm night, 10% steady bedtime. The total is raised to the power 1.8, so a full, steady night lands in the 80s.
- **Recovery:**
  - HRV (70%) and resting heart rate (30%) are compared as z-scores against your own 30 days. HRV uses a log scale.
  - The combined z goes through a logistic curve centred so a usual morning is about 67.
  - The final score is 75% that body score and 25% sleep.
  - It needs at least 3 mornings of a source's data.
- **Band scores:** when a band has its own score (Whoop), the ring uses it.

### Compare (testing only)
- **Files:** `Sources/Compare/CompareStore.swift` and `Sources/Compare/CompareView.swift`, opened from Settings › Testing.
- **Storage:** its own caches, `compare-<device>.json`.
- **Contents:** each band's own score next to Halo's recovery, sleep and effort, plus the numbers grid and a heart-rate overlay chart.
- **Copy all data:** 14 days as text.

### App
- **Today:** the old "Today/insight" card is removed and Balance sits under the four key-number cards. The card-order storage key is `today.cards.v4`.
- **Welcome screens** (`Sources/Onboarding/OnboardingView.swift`):
  - Logo animation, then the device page, the You and targets page, then How Halo works.
  - They are the root view until finished, so nothing flashes behind them.
  - The launch background is dark.
- **Settings:**
  - Cards for Sources, You (About you, Health targets) and Appearance (laid out like Scout's).
  - App icon section, Help, and Testing (Compare bands, Paywall toggle).
  - Delete all data from this iPhone, with two choices: re-read, or start over.
- **Halo Plus paywall** (`Sources/Common/Paywall.swift`):
  - A test purchase at £0.99 or $0.99 a month; no StoreKit product exists.
  - **Off by default.** `plus.paywall` must be turned on.
  - When on, it locks: earlier days, Today cards below Balance, Fitness cardio load, custom colours and alternate icons.
  - Colour sets can be previewed for 10 seconds.
- **App icons:** alternate icons are drawn by `tools/make_icon.py` (Ocean, Forest, Mono, Dusk, Sand, Light) and registered in `project.yml` (`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`).
- **Sleep tab:**
  - The sleep bank card is a 7-night rolling balance; tapping it opens `SleepBankView` with 1W, 1M and 1Y.
  - The overnight heart card shows when there's no heart rate; the heart chart works without a stage timeline.
- **Defaults:**
  - Dark by default; a mode saved as Automatic flips to Dark once.
  - Numbers use the regular system font.
  - High SpO₂ is never flagged; only low is.

---

## What's left / open issues

1. **Tune scores from the three-band test.** Wait for the owner's "Copy all data" paste.
   - Compare Halo's recovery from Whoop data (62) with Whoop's own (18). Expect Halo to be generous until 30 days of baseline exist. Consider weighting the latest days or a smaller window early on.
   - Check Halo sleep against Whoop's and Fitbit's.
2. **Apple Watch recovery:** confirm it appears after 3 mornings and that the resting heart rate fallback is sensible.
3. **Apple Health incremental heart rate:** `HealthKitClient` still re-reads 35 days of heart rate every sync. Move it to an anchored or incremental read like Fitbit's.
4. **Remove the Compare page after testing:**
   - Delete `Sources/Compare/`.
   - Remove the `CompareStore` StateObject and `.environmentObject(compare)` in `Sources/HaloApp.swift`.
   - Remove the "Compare bands" row in `SettingsView`.
   - Optionally delete the `compare-*.json` files.
5. **Mockup and docs are behind:**
   - The mockup lacks Compare-in-Settings, the Whoop debug page, the sleep bank 1W/1M/1Y page, and the paywall default-off.
   - The algorithms doc lacks the year history, per-source caches, Whoop start/end, Halo thinks, and the Apple resting heart rate fallback.
6. **Real in-app purchase (later):** a StoreKit 2 product, mirroring Scout's `PlusStore` in `ralphgeb/NewsiOS`. That repo is read-only reference; **never push to it**.
7. **Fitbit SpO₂ caveat:** Google's `daily-oxygen-saturation` is parsed by picking keys containing "average" or "percentage". It once looked wrong, but that turned out to be sample data. The owner said **don't change the Google conversion**.

---

## Key decisions and why

- **Fitbit conversion is off limits.** The owner said explicitly: don't touch the Google conversion. All Whoop work stays in Whoop files plus the shared store and scoring.
- **Whoop's own scores on the rings.** The owner wants Halo to match the Whoop app; Halo's own view is shown underneath as "Halo thinks".
- **Separate caches per source.** Switching must be instant, and bands measure differently, so their baselines never mix.
- **Whoop is always linked to Apple Health.** Whoop's API has no continuous heart rate; Apple Health is the only route.
- **Paywall off by default.** The owner wants the whole app open, with the paywall testable from Settings.
- **Never push to other repos from this session.** The owner said so; Scout (`NewsiOS`) is handled by another session.

---

## Gotchas

- **No compiler locally.** Push and let `halo-build.yml` compile. Avoid risky Swift:
  - tuple key paths in `ForEach` (use indices)
  - tuple destructuring in view builders
  - `if`/`else` inside `AxisMarks` builders (use one `AxisMarks` with computed values)
- **Whoop API v2:**
  - Collections need `start` and `end`, `limit` of 25 at most, and `nextToken` (the response key is `next_token`; both are accepted).
  - Records come newest first. Cycle `end` is null while the cycle is open.
- **Whoop accounts and refresh tokens:**
  - A Whoop account can look empty if the wrong account is signed in. The sync report and Sources show the account name and email.
  - Whoop rotates refresh tokens, so token refresh is shared (`WhoopAuth`).
- **HealthKit:**
  - It never says which permissions were denied; missing types just show "No data".
  - Watch filtering uses the device model "Watch".
- **Deleting the app keeps the keychain.** Hence the `installed` / `onboarded` sign-out logic in `HaloApp.init`.
- **`.id(look.appearance)` rebuilds pages** on look change. A colour-set preview without Plus isn't saved; it only sets `Appearance.current`.
- **Repeated "changed on disk" warnings** for `WhoopLedger.swift` and `Paywall.swift` have shown up with a clean `git status`. Treat what's on disk as current.

---

## File map (touched recently)

- **Store:** `HaloApp/Sources/HealthStore.swift` (sync, per-source cache, sample guard, Plus gating of dates, delete all data).
- **Sync:**
  - `HaloApp/Sources/Sync/WhoopClient.swift`, `WhoopLedger.swift`, `WhoopAuth.swift`
  - `HaloApp/Sources/Sync/HealthKitClient.swift`, `HealthSource.swift`
  - `GoogleHealthClient.swift` is unchanged since 85e3747; leave it.
- **Shared:** `HaloApp/Shared/ScoreEngine.swift`, `Models.swift` (`DayMetrics` band fields, `sleepNeedMinutes`), `CardioLoad.swift`, `Appearance.swift`, `SampleData.swift`.
- **App:** `HaloApp/Sources/HaloApp.swift` (root and onboarding, retries, Plus sheet, Compare environment object).
- **Settings:** `HaloApp/Sources/Settings/SettingsView.swift`, `WhoopDebugView.swift`.
- **Screens:**
  - `HaloApp/Sources/Onboarding/OnboardingView.swift`
  - `HaloApp/Sources/Compare/CompareStore.swift`, `CompareView.swift`
  - `HaloApp/Sources/Common/Paywall.swift`
  - `HaloApp/Sources/Today/TodayView.swift`, `HeartZones.swift`
  - `HaloApp/Sources/Fitness/FitnessView.swift`
  - `HaloApp/Sources/Sleep/SleepView.swift`
  - `HaloApp/Sources/Health/HealthView.swift`
  - `HaloApp/Sources/Metrics/Metric.swift`
- **Assets and config:** `HaloApp/tools/make_icon.py`, `HaloApp/Sources/Assets.xcassets/` (AppIcon-*, IconPreview-*, LaunchBackground), `HaloApp/project.yml`.
- **Mockup:** `HaloApp/mockup/index.html`.

---

## Exact next steps

1. **When the owner pastes "Copy all data":** compare the three bands day by day. Look at recovery, sleep, sleep duration and stages, HRV, resting heart rate, steps and cardio load. Then propose concrete scoring tweaks, before changing code.
2. **If Whoop's column is empty or stuck again:** ask for the Settings › Sources › Whoop debug paste and the sync report.
3. **Next code task, if asked:** incremental Apple Health heart rate reads (`HKAnchoredObjectQuery`, or a start date from the last stored minute, as the Fitbit path does).
4. **After testing ends:** remove Compare (see "What's left" item 4), ship, and update the mockup and algorithms doc.
