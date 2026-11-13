
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

## Xcode 27 builds (for the iPhone Duo's full screen)
- GitHub's macos-latest/macos-26 runners stop at Xcode 26.6. The `xcode-27` runner label (macOS 27,
  Xcode 27.0–27.2) has the iOS 27 SDK; halo-build and halo-testflight now run there and pick the
  newest Xcode by its version number. No Mac or Xcode Cloud needed.
- Duo, round 2: the right-hand column (clock, camera, battery at its top) holds the tabs, stacked
  in its bottom corner. Closed (outside screen, nearly square): one page at a time with Today,
  Fitness, Health and Sleep in that column. Open: Today on the left, the chosen page on the right,
  Fitness/Health/Sleep in the column. Ordinary iPhones keep the bottom tab bar.
