#!/usr/bin/env bash
# Runs on the emulator (android-screens.yml): pictures of the setup, every tab, a graph, the
# calendar and each widget, plus any widget errors from the log. Run from AndroidApp/.
set -x
OUT=screens
rm -rf "$OUT"; mkdir -p "$OUT"
PKG=com.ralphgeb.halo
shot() { sleep "${2:-3}"; adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null; sleep 0.5; adb exec-out screencap -p > "$OUT/$1.png"; }
swipe_up() { adb shell input swipe 540 1700 540 700 400; }

adb install -r app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb shell settings put system screen_off_timeout 1800000
adb shell svc power stayon true
# the emulator's launcher is slow to start and pops "isn't responding" over everything: no error dialogs
adb shell settings put global hide_error_dialogs 1
sleep 20
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS
adb logcat -c

# first launch: the setup pages
adb shell am start -W -n $PKG/.MainActivity
shot setup-1-welcome 6
adb shell input tap 540 2150
shot setup-2-device 3

# the app on sample data, tab by tab
adb shell am force-stop $PKG
adb shell am start -W -n $PKG/.MainActivity --ez haloSkipSetup true --ei tab 0
shot today-1 8
swipe_up; shot today-2
swipe_up; shot today-3
swipe_up; shot today-4
swipe_up; shot today-5
adb shell am start -W -n $PKG/.MainActivity --ei tab 0
sleep 2
adb shell input swipe 540 500 540 1500 900
shot today-calendar 3
for t in 1 2 3; do
  name=$([ $t = 1 ] && echo fitness || ([ $t = 2 ] && echo health || echo sleep))
  adb shell am start -W -n $PKG/.MainActivity --ei tab $t
  shot $name-1 3
  swipe_up; shot $name-2
  swipe_up; shot $name-3
  swipe_up; shot $name-4
done
adb shell am start -W -n $PKG/.MainActivity --ei tab 2 --es metric HRV
shot graph-hrv 3
adb shell am start -W -n $PKG/.MainActivity --ei tab 2 --es metric VO2_MAX
shot graph-vo2 3

# the widgets, each on a real widget host
adb shell appwidget grantbind --package $PKG --user 0
adb shell am instrument -w -e class $PKG.WidgetShots $PKG.test/androidx.test.runner.AndroidJUnitRunner > "$OUT/widget-test.txt" 2>&1
adb pull /sdcard/Android/data/$PKG/files/widgets "$OUT/widgets" || true
adb logcat -d | grep -iE "glance|appwidget|AndroidRuntime|FATAL|ralphgeb|RemoteViews" | tail -400 > "$OUT/logcat.txt"
ls -la "$OUT" "$OUT/widgets" || true
