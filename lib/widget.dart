import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:home_widget/home_widget.dart';

import 'gtfs.dart';
import 'realtime.dart';

/// The home screen widget: the next buses at one stop. The app writes them as JSON (`data`), and the native widgets
/// (android/.../DeparturesWidget.kt, ios/DeparturesWidget/DeparturesWidget.swift) only draw them:
/// `{"stop": name, "station": id, "updated": epoch s, "deps": [{"l", "c", "t", "h", "at", "rt"}]}`
/// (line, badge color, text color, terminus, epoch s, live). Keep both sides in sync with this format.
const appGroup = 'group.com.eylexander.retcat';
const widgetName = 'DeparturesWidget';

/// The Android provider's class: qualified, since debug builds have another package name (`.debug`).
const androidWidget = 'com.eylexander.retcat.DeparturesWidget';

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

Future<void> updateHomeWidget(Gtfs gtfs, String? station, Map<String, TripUpdate> live, String dbPath) async {
  final now = DateTime.now();
  final s = station == null ? null : gtfs.stations[station];
  final deps = s == null ? <Departure>[] : gtfs.departures(s.id, now, live, count: 8, hours: 6);
  await HomeWidget.saveWidgetData('dbPath', dbPath);
  await HomeWidget.saveWidgetData(
    'data',
    s == null
        ? null
        : jsonEncode({
            'stop': s.name,
            'station': s.id,
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
  await HomeWidget.updateWidget(qualifiedAndroidName: androidWidget, iOSName: widgetName);
  // Redraw when each bus leaves, so it drops off the list (iOS builds its own timeline from the times).
  if (Platform.isAndroid) {
    await HomeWidget.scheduleWidgetUpdates([
      for (final d in deps) DateTime.fromMillisecondsSinceEpoch(d.time * 1000 + 1000),
    ], qualifiedAndroidName: androidWidget);
  }
}

/// Runs in the background when the widget's refresh button is tapped, or when the Android widget finds its data older
/// than 10 minutes: fetches the live predictions and rewrites the widget's data.
@pragma('vm:entry-point')
Future<void> widgetCallback(Uri? uri) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isIOS) await HomeWidget.setAppGroupId(iosAppGroup());
  final dbPath = await HomeWidget.getWidgetData<String>('dbPath');
  final data = await HomeWidget.getWidgetData<String>('data');
  if (dbPath == null || data == null) return;
  final gtfs = Gtfs.open(dbPath);
  if (gtfs == null) return;
  try {
    Map<String, TripUpdate> live = {};
    try {
      live = parseTripUpdates(await fetchFeed(tripUpdatesUrl));
    } catch (_) {
      // Offline: the timetable alone.
    }
    await updateHomeWidget(gtfs, jsonDecode(data)['station'], live, dbPath);
  } finally {
    gtfs.close();
  }
}
