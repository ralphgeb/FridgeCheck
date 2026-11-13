
## App Store tidy
- Sources settings: only what a user needs (source, account, Sync now, Disconnect, Whoop's Apple Health toggle, what the last sync found). Captions, Copy sync details and the Whoop debug screen are gone.
- New TestFlight section at the bottom of Settings (Compare bands, Replay the setup, Reset Halo Plus), shown only in TestFlight installs (sandbox receipt); hidden in App Store downloads.
- Pull to refresh: Fitness, Health and Sleep sync on a long pull (arrow turns, "Release to refresh"). Today: pull opens the calendar as before; pull again with the calendar out to sync (hint at the bottom of the calendar with the last update time).
- Vitals widget redesigned: status seal, a tile per vital with a 7-night sparkline and range ticks. Heart today shows yesterday early in the morning, hour labels on medium. Widget gallery and placeholders show your own data.
- Notifications: morning summary once last night's sleep is in, evening wrap-up 45 min before your usual bedtime; real numbers, 10 lines per level each, never the same twice in a row. Toggles in Settings › Notifications.
- Readiness card: 10 titles and lines per level, changing by day.

## iPhone Duo, first pass
- Opened up (regular width), Halo shows Today on the left all the time and Fitness, Health or Sleep on the right, switched from a slim vertical rail down the right edge under the clock and camera. Folded, it's the usual tab bar.
- Portrait stays locked on ordinary iPhones; the big screen may turn (app delegate decides by screen size), so Halo fills it.
- Vitals widget: the little line charts are replaced by an upright range bar per vital (normal band in the middle, a marker for last night).

## Xcode Cloud (for the iOS 27 SDK / iPhone Duo full screen)
- GitHub's Mac runners stop at Xcode 26.6; Xcode Cloud has Xcode 27.
- HaloApp/ci_scripts/ci_post_clone.sh: Xcode Cloud regenerates the project with XcodeGen before
  each build, sets the build number to 1000 + Xcode Cloud's, and the team from the workflow's
  secret APPLE_TEAM_ID.
- .github/workflows/halo-generate-project.yml (by hand) commits the generated project so it opens
  in Xcode straight from a clone.
