# Re-TCAT

**English** · [Français](README.fr.md)

Live [TCAT](https://www.tcat.fr/) buses in Troyes (France), on Android and iPhone. Free and open source, no account,
no ads, no trackers. The app itself is in French.

<p>
  <img src="docs/screenshots/1-map.png" width="19%" alt="Map of every bus in service">
  <img src="docs/screenshots/2-follow.png" width="19%" alt="Following a bus along its stops">
  <img src="docs/screenshots/3-stop.png" width="19%" alt="Next buses at a stop">
  <img src="docs/screenshots/4-favorites.png" width="19%" alt="Favorite stops">
  <img src="docs/screenshots/5-lines.png" width="19%" alt="Lines in service">
</p>

## Features

- **Map**: every bus in service, in its line's color, with an arrow showing where it's heading. Filter by line.
- **Follow a bus**: the map tracks it as it drives. Its stops list shows predicted times, how late or early it runs,
  and any skipped stops.
- **Stops**: search by name, find stops around you, and keep favorites with their next buses (live when the bus
  reports its position, scheduled otherwise).
- **Lines**: route, stops in each direction, buses in service, service alerts.
- **Widget**: the next buses at a stop on your home screen (Android and iOS).

## Install

**Android** (8.0 or later): from [my F-Droid repo](https://eylexander.github.io/fdroid/) (add it to F-Droid, Droid-ify
or Neo Store to get updates), or the APK from the [releases](https://github.com/Eylexander/re-tcat/releases).

**iPhone**: there is no App Store build. Take the `.ipa` from the
[releases](https://github.com/Eylexander/re-tcat/releases) and install it with a sideloading tool that signs it with
your Apple ID: [xtool](https://github.com/xtool-org/xtool) (works from Linux: `xtool install re-tcat-vX-unsigned.ipa`),
AltStore, SideStore or Sideloadly. The home screen widget needs a paid Apple developer account (App Groups); the app
itself doesn't.

## How it works

The same data and rules as [ha-tcat](https://github.com/Eylexander/ha-tcat), its Home Assistant counterpart:

- **Timetable**: TCAT's GTFS on
  [transport.data.gouv.fr](https://transport.data.gouv.fr/datasets/donnees-tcat-troyes-champagne-metropole-1). Each
  file is only valid for a few weeks, so the app downloads it (2.5 MB) at first launch and again whenever TCAT
  publishes a new one, instead of bundling it.
- **Live data**: TCAT's GTFS-Realtime feeds (vehicle positions, trip updates, service alerts), polled every 15 seconds
  while the app is open.

The app talks to these public feeds directly. There is no server in between, and nothing about you is sent anywhere.
Location is optional, only used on demand for "stops around me", and stays on the phone.

## Building

You need [Flutter](https://docs.flutter.dev/get-started/install) 3.47 (Dart 3.13).

```sh
flutter pub get
flutter test
flutter run                                                  # on a connected phone or emulator
flutter build apk --release --target-platform android-arm64 # build/app/outputs/flutter-apk/app-release.apk
```

Debug builds install as a separate app (`com.eylexander.retcat.debug`, "Re-TCAT (dev)"). iOS builds need macOS;
the release workflow builds the `.ipa` on GitHub Actions. [CLAUDE.md](CLAUDE.md) has the architecture, data
quirks and release notes in more detail.

## Contributing

Bug reports and pull requests are welcome. Please run `flutter analyze`, `flutter test` and
`dart format -l 120 lib test` before sending a change. If you notice a wrong delay or a bus that doesn't show up,
include the stop, line and time: TCAT's realtime feed has quirks, and that's what it takes to reproduce them.

## License

[MIT](LICENSE) for the code.

Data: TCAT / Troyes Champagne Métropole, under the
[ODbL](https://opendatacommons.org/licenses/odbl/). Map: © [OpenStreetMap](https://www.openstreetmap.org/copyright)
contributors.

This is an unofficial app, not affiliated with TCAT or Troyes Champagne Métropole.
