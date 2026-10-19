import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:home_widget/home_widget.dart';

import 'gtfs.dart';
import 'realtime.dart';

/// The home screen widgets: the next buses at one stop (DeparturesWidget), the next bus at one stop (NextBusWidget)
/// or at two (NextBus2Widget). Each widget follows its own "picks", chosen when it is added: a stop, and optionally
/// one line and one direction, as `station|route|dir` ([pickKey]). Android widgets keep theirs in `config_<widget
/// id>` (a JSON list, written by lib/setup.dart); iOS widgets have them in their AppIntent settings and note them in
/// `seen` (pick → epoch s), since the app cannot read those settings.
///
/// For each pick in use, the app writes the next buses as JSON in `dep_<pick>`, and the native widgets
/// (android/.../DeparturesWidget.kt, ios/DeparturesWidget/DeparturesWidget.swift) only draw them:
/// `{"stop": name, "station": id, "updated": epoch s, "deps": [{"l", "c", "t", "h", "at", "rt"}]}`
/// (line, badge color, text color, terminus, epoch s, live). For the iOS settings, `picks` lists every possible pick
/// as `[[pick, label], ...]`. Keep both sides in sync with these formats.
const appGroup = 'group.com.eylexander.retcat';

/// The iOS widget kinds, and the Android provider classes.
const widgetNames = ['DeparturesWidget', 'NextBusWidget', 'NextBus2Widget'];

/// An Android provider's class, qualified: debug builds have another package name (`.debug`).
String androidWidget(String name) => 'com.eylexander.retcat.$name';

/// What a widget follows at a stop; an empty [route] or [dir] means all of them.
String pickKey(String station, [String route = '', String dir = '']) => '$station|$route|$dir';

/// [Gtfs.stationDirections] grouped: station → line → direction → termini.
Map<String, Map<String, Map<String, List<String>>>> groupDirections(
  Iterable<({String station, String route, String dir, String terminus})> rows,
) {
  final out = <String, Map<String, Map<String, List<String>>>>{};
  for (final r in rows) {
    ((out[r.station] ??= {})[r.route] ??= {})[r.dir] ??= [];
    out[r.station]![r.route]![r.dir]!.add(r.terminus);
  }
  return out;
}

String directionLabel(List<String> termini) => '→ ${termini.join(' / ')}';

/// The App Group the iOS app was signed with. Re-signing tools (xtool, AltStore, SideStore) rename it, so it is read
/// from the provisioning profile in the app bundle, as the widget does (DeparturesWidget.swift); [appGroup] otherwise.
String iosAppGroup() {
  try {
    final profile = File('${File(Platform.resolvedExecutable).parent.path}/embedded.mobileprovision');
    return groupFromProfile(latin1.decode(profile.readAsBytesSync())) ?? appGroup;
  } catch (_) {
    return appGroup; // simulator or unsigned build: no profile
  }
}

/// The first App Group in a provisioning profile (a signed plist, its XML readable as is).
String? groupFromProfile(String profile) =>
    RegExp(r'<key>com\.apple\.security\.application-groups</key>\s*<array>\s*<string>([^<]+)</string>')
        .firstMatch(profile)
        ?.group(1);

Future<void> setupHomeWidget() async {
  if (Platform.isIOS) await HomeWidget.setAppGroupId(iosAppGroup());
  await HomeWidget.registerInteractivityCallback(widgetCallback);
}

String _hex(int argb) => '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// The picks of the widgets on the home screen.
Future<Set<String>> _picksInUse() async {
  if (Platform.isAndroid) {
    return {
      for (final w in await HomeWidget.getInstalledWidgets())
        if (await HomeWidget.getWidgetData<String>('config_${w.androidWidgetId}') case final config?)
          ...(jsonDecode(config) as List).cast<String>(),
    };
  }
  // iOS widgets note their picks each time they reload: forget those not seen for two days (widget removed).
  final seen = jsonDecode(await HomeWidget.getWidgetData<String>('seen') ?? '{}') as Map<String, dynamic>;
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return {
    for (final MapEntry(:key, :value) in seen.entries)
      if (now - (value as num) < 2 * 86400) key,
  };
}

/// The settings' list of picks for iOS (written once per run and timetable), [favorites] first.
String? _catalogFor;
Future<void> _saveCatalog(Gtfs gtfs, List<String> favorites) async {
  final version = '${gtfs.source} $favorites';
  if (_catalogFor == version) return;
  final lines = groupDirections(gtfs.stationDirections());
  final stations = [
    ...favorites.map((id) => gtfs.stations[id]).nonNulls,
    ...gtfs.stations.values.where((s) => !favorites.contains(s.id)),
  ];
  await HomeWidget.saveWidgetData(
    'picks',
    jsonEncode([
      for (final s in stations) ...[
        [pickKey(s.id), '${s.name} · toutes les lignes'],
        for (final r in gtfs.routes.values)
          if (lines[s.id]?[r.id] case final dirs?) ...[
            for (final MapEntry(key: dir, value: termini) in dirs.entries)
              [pickKey(s.id, r.id, dir), '${s.name} · ${r.short} ${directionLabel(termini)}'],
            if (dirs.length > 1) [pickKey(s.id, r.id), '${s.name} · ${r.short} (les deux sens)'],
          ],
      ],
    ]),
  );
  _catalogFor = version;
}

/// Writes the next buses of every pick in use and redraws the widgets. [favorites] orders the iOS settings' list
/// (left as is when null, in the background).
Future<void> updateHomeWidget(Gtfs gtfs, Map<String, TripUpdate> live, String dbPath, {List<String>? favorites}) async {
  final now = DateTime.now();
  final times = <int>{};
  await HomeWidget.saveWidgetData('dbPath', dbPath);
  if (Platform.isIOS && favorites != null) await _saveCatalog(gtfs, favorites);
  for (final pick in await _picksInUse()) {
    if (pick.split('|') case [final station, final route, final dir]) {
      // A stop gone from a new timetable still gets (empty) data: Android widgets ask again while theirs is missing.
      final s = gtfs.stations[station];
      final deps = s == null
          ? <Departure>[]
          : gtfs.departures(
              station,
              now,
              live,
              count: 8,
              hours: 6,
              onlyRoutes: route.isEmpty ? null : {route},
              direction: dir.isEmpty ? null : dir,
            );
      times.addAll(deps.map((d) => d.time));
      await HomeWidget.saveWidgetData(
        'dep_$pick',
        jsonEncode({
          'stop': s?.name ?? 'Arrêt inconnu',
          'station': station,
          'updated': now.millisecondsSinceEpoch ~/ 1000,
          'deps': [
            for (final d in deps)
              {
                'l': d.route.short,
                'c': _hex(d.route.color),
                't': _hex(d.route.text),
                'h': d.terminus,
                'at': d.time,
                'rt': d.realtime,
              },
          ],
        }),
      );
    }
  }
  for (final name in widgetNames) {
    await HomeWidget.updateWidget(qualifiedAndroidName: androidWidget(name), iOSName: name);
    // Redraw when each bus leaves, so it drops off the list (iOS builds its own timeline from the times).
    if (Platform.isAndroid) {
      await HomeWidget.scheduleWidgetUpdates([
        for (final t in times) DateTime.fromMillisecondsSinceEpoch(t * 1000 + 1000),
      ], qualifiedAndroidName: androidWidget(name));
    }
  }
}

/// Before widgets had their own settings, the app showed one stop, chosen in the app, on the Android widget: the
/// widgets already on the home screen keep it.
Future<void> migrateWidgetStation(String station) async {
  if (!Platform.isAndroid) return;
  for (final w in await HomeWidget.getInstalledWidgets()) {
    final key = 'config_${w.androidWidgetId}';
    if (await HomeWidget.getWidgetData<String>(key) == null) {
      await HomeWidget.saveWidgetData(key, jsonEncode([pickKey(station)]));
    }
  }
}

/// Runs in the background when the widget's refresh button is tapped, or when an Android widget finds its data older
/// than 10 minutes or missing: fetches the live predictions and rewrites the widgets' data.
@pragma('vm:entry-point')
Future<void> widgetCallback(Uri? uri) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isIOS) await HomeWidget.setAppGroupId(iosAppGroup());
  final dbPath = await HomeWidget.getWidgetData<String>('dbPath');
  if (dbPath == null) return;
  final gtfs = Gtfs.open(dbPath);
  if (gtfs == null) return;
  try {
    Map<String, TripUpdate> live = {};
    try {
      live = parseTripUpdates(await fetchFeed(tripUpdatesUrl));
    } catch (_) {
      // Offline: the timetable alone.
    }
    await updateHomeWidget(gtfs, live, dbPath);
  } finally {
    gtfs.close();
  }
}
