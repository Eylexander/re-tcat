# CLAUDE.md

Re-TCAT: a Flutter app (Android + iOS) to follow the buses of TCAT, the Troyes Champagne Métropole bus network, live.
Unofficial. The UI is in French. Same data and rules as the user's Home Assistant integration
[Eylexander/ha-tcat](https://github.com/Eylexander/ha-tcat) (`custom_components/tcat/tcat.py`): keep them in agreement.

## Toolchain

Flutter 3.47.7 (Dart 3.13). On the Linux PC: Flutter in `~/.bin/flutter`, Android SDK in `~/development/android-sdk`
(adb in `platform-tools`, AVD `ytdlp_api36`, x86_64). There is no Mac: iOS only builds in CI.

```sh
flutter analyze
flutter test                                       # test/feed_test.dart: protobuf, delay rules, CSV, GTFS import
dart format -l 120 lib test                        # 120-col lines
flutter build apk --debug --target-platform android-x64     # emulator
flutter build apk --release --target-platform android-arm64 # → build/app/outputs/flutter-apk/app-release.apk
```

## Releasing (same scheme as LLLearner and Audio Cutter)

- Package / bundle id `com.eylexander.retcat`, distributed through the user's F-Droid repo (`../fdroid`, GitHub
  `Eylexander/fdroid`), listing in `../fdroid/metadata/com.eylexander.retcat/{fr-FR,en-US}/`.
- Push a `v*` tag. `.github/workflows/release.yml` runs the shared `Eylexander/fdroid/.github/workflows/flutter-apk.yml`
  (analyze, test, arm64 APK, GitHub release; versionCode = run number, so keep the file's name) and an `ios` job on
  macOS that builds the app unsigned (`--no-codesign`), checks the widget extension is embedded, and attaches
  `re-tcat-vX-unsigned.ipa` for sideloading.
- Release key: `.secrets/release.p12` + `.secrets/password.txt` (git-ignored), or `RELEASE_KEYSTORE` /
  `RELEASE_KEYSTORE_PASS` in CI (secrets `RELEASE_KEYSTORE_BASE64` / `RELEASE_KEYSTORE_PASS`). Same key as LLLearner
  (`../LLLearner/.secrets/`, SHA-256 `db171ead…`). **Never regenerate or lose it.** Debug builds are
  `com.eylexander.retcat.debug` ("Re-TCAT (dev)").
- The launcher icon is an adaptive vector only (`res/drawable/ic_launcher_*.xml`), hence `minSdk = 26`.
  `tool/icon.svg` has the same paths and the commands for the iOS and F-Droid PNGs.
- geolocator bundles the Play services location client (`NonFreeDep` in the listing). It is never called:
  `locate()` forces Android's `LocationManager`.

## Data

- **Timetable**: TCAT's GTFS (`gtfsUrl`, transport.data.gouv.fr, ODbL). Each file is valid a few weeks only, so the
  app downloads it (2.5 MB) instead of bundling it: at first launch, then when the redirect target changes (checked
  every 6 hours, `Store.checkTimetable`). `importGtfs` (in an isolate) writes `gtfs.db` aside, then renames it over.
  - Agency `MASQUE` (internal routes) is dropped. Stops are grouped into **stations** by `parent_station` (both sides
    of the street); a trip's last stop (and `pickup_type = 1`) has `last = 1`: nobody boards there.
  - Service days start at "noon minus 12 h" (`Gtfs.base`), times can exceed 24 h, so departures look at yesterday,
    today and tomorrow. The device time zone is assumed to be Europe/Paris.
  - CSV: UTF-8 with BOM, else Latin-1 (TCAT's export used cp1252); quotes are handled (`parseCsvLine`).
- **Realtime**: three GTFS-RT feeds (`lib/realtime.dart`), polled every 15 s while the app is in the foreground
  (`Store.refresh`, alerts every 2 min). The data.gouv.fr links redirect to `http://94.143.218.42:13486/…`: plain HTTP
  on an IP, hence `usesCleartextTraffic` (Android) and `NSAllowsArbitraryLoads` (iOS). The redirect is resolved once
  per run. `Msg` is a small protobuf wire reader (no protobuf dependency); field numbers are from gtfs-realtime.proto.
  - Vehicle positions: `current_stop_sequence` is always 0 in TCAT's feed, so the bus's place on its trip comes from
    `stop_id` + `current_status`.
  - Trip updates have no `start_date`: an update only applies to the run of the trip within ±3 h (`_rtMatch`).
    `TripUpdate.delayAt` follows ha-tcat's `live_delay`: own time or delay, else the closest earlier stop's delay,
    `gone` when canceled, skipped (TCAT marks detoured stops), or when the update only lists later stops (passed).
  - Live updates sometimes list extra stops with `stop_sequence = 0` (detours): they match no GTFS stop and are ignored.

## Architecture

- **State**: one global `store` (`ChangeNotifier`, `lib/store.dart`). `Shell` (`main.dart`) rebuilds the tabs in a
  `ListenableBuilder`; the tab widgets there must **not be const**, or they never redraw (that bug happened). Pushed
  pages (`StopPage`, `LinePage`, `FollowPage`) listen to `store` themselves. Favorites and the widget's stop are in
  SharedPreferences.
- **Map** (`lib/map.dart`): `LiveMap` (flutter_map, OSM tiles, inverted in dark mode; CARTO now needs an API key).
  Buses glide between positions (1.5 s animation per update); with `follow`, the camera tracks the animated
  position, kept above the bottom sheet (`padding`). A drag stops following. Stations show from zoom 15.
  - Tabs: Carte (all buses, line filter chips), Arrêts (search, favorites with next buses, nearby), Lignes (running
    lines first, then all, then on-demand). `FollowPage` = map + the trip's stops timeline with live times.
- **Widget** (`lib/widget.dart`): the app writes the next 8 departures of `store.widgetStation` as JSON (format in the
  file's doc comment) at every poll; native widgets only draw it.
  - Android: `DeparturesWidget.kt` (RemoteViews, rows added per available height). The app schedules a redraw at each
    departure (`scheduleWidgetUpdates`, `HomeWidgetScheduledUpdateReceiver`) so buses that left drop off; a redraw of
    data older than 10 min, or the refresh button, runs `widgetCallback` in a background Dart isolate (fetches the trip
    updates, recomputes from `gtfs.db`). Use `qualifiedAndroidName` (debug builds have another package).
  - iOS: `ios/DeparturesWidget/` (WidgetKit extension, App Group `group.com.eylexander.retcat`, timeline entry at each
    departure). It has no live refresh while the app is closed. The extension target was added to
    `Runner.xcodeproj` with the `xcodeproj` gem; it uses `DeparturesWidget/Widget.xcconfig` (Flutter's version numbers
    without CocoaPods settings) and its embed phase must stay before "Thin Binary".
  - App Group: re-signing tools rename it (xtool: `group.XTL-<id>.…`), so the app (`iosAppGroup`) and the widget read
    the real one from their `embedded.mobileprovision`. CI ad-hoc signs the `.ipa` with the entitlements because
    xtool takes them from the existing signature. xtool strips App Groups on free Apple IDs (`isFree: false` in its
    source): there the app works but the widget stays empty; a paid account is needed for the widget.
- **iPhone from Linux**: the `.ipa` comes from CI (Flutter can't build iOS without macOS), then
  `~/.local/bin/xtool install re-tcat-vX-unsigned.ipa` signs it with the user's Apple ID and installs it over USB
  (needs `usbmuxd` and a one-time `xtool auth login`).
  - Tapping a widget opens `retcat://stop?station=…` (`&homeWidget` on iOS, for home_widget), handled in `_ShellState`.
- **Theme** (`lib/theme.dart`): Material 3 seeded by the wallpaper (`dynamic_color` 1.x: 2.x targets the separate
  `material_ui` package and its types don't match `flutter/material.dart`), else `seed`. Line colors come from GTFS.
