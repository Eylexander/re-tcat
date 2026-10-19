import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

import 'realtime.dart';

/// TCAT's GTFS timetable on transport.data.gouv.fr; always redirects to the current file. TCAT publishes a new one
/// every couple of weeks, each valid for a few weeks only, so it is downloaded by the app instead of bundled.
const gtfsUrl = 'https://transport.data.gouv.fr/resources/79847/download';

/// TCAT's internal routes (relief buses, workshop...).
const _hiddenAgency = 'MASQUE';

/// A live update only applies to the run of a trip nearest to now: the feed has no start_date.
const _rtMatch = 3 * 3600;

class Line {
  Line(Row r)
    : id = r['id'],
      short = r['short'],
      long = r['long'],
      color = r['color'],
      text = r['text'],
      onDemand = r['desc'].toString().contains('demande');

  final String id, short, long;

  /// ARGB colors of the line's badge and its text.
  final int color, text;

  /// Transport à la demande: runs only when booked.
  final bool onDemand;
}

class Station {
  Station(Row r) : id = r['id'], name = r['name'], lat = r['lat'], lon = r['lon'];
  final String id, name;
  final double lat, lon;
}

/// A stop of a trip, with its scheduled time in seconds after the service day's start (can exceed 24 h).
class TripStop {
  TripStop(Row r)
    : seq = r['seq'],
      stopId = r['stop'],
      station = r['station'],
      name = r['name'],
      lat = r['lat'],
      lon = r['lon'],
      secs = r['secs'];
  final int seq, secs;
  final String stopId, station, name;
  final double lat, lon;
}

class Trip {
  Trip(Row r) : id = r['id'], route = r['route'], service = r['service'], shape = r['shape'], terminus = r['terminus'];
  final String id, route, service, shape, terminus;
}

class Departure {
  Departure({
    required this.route,
    required this.trip,
    required this.terminus,
    required this.seq,
    required this.scheduled,
    this.delay,
  });

  final Line route;
  final String trip, terminus;
  final int seq;

  /// Epoch seconds; [delay] in seconds when the bus is followed live.
  final int scheduled;
  final int? delay;

  bool get realtime => delay != null;
  int get time => scheduled + (delay ?? 0);
}

class Gtfs {
  Gtfs._(this.db) {
    for (final r in db.select('SELECT * FROM routes ORDER BY sort')) {
      routes[r['id']] = Line(r);
    }
    for (final r in db.select('SELECT * FROM stations ORDER BY name')) {
      stations[r['id']] = Station(r);
    }
    calendar = db.select('SELECT * FROM calendar').toList();
    for (final r in db.select('SELECT * FROM calendar_dates')) {
      (exceptions[r['date']] ??= []).add(r);
    }
    final m = {for (final r in db.select('SELECT key, value FROM meta')) r['key'] as String: r['value'] as String};
    source = m['source'] ?? '';
    validFrom = m['from'] ?? '';
    validTo = m['to'] ?? '';
  }

  final Database db;
  final routes = <String, Line>{};
  final stations = <String, Station>{};
  late final List<Row> calendar;
  final exceptions = <String, List<Row>>{};

  /// The file the data came from (the redirect target of [gtfsUrl]) and its validity, as YYYYMMDD.
  late final String source, validFrom, validTo;

  static Gtfs? open(String path) =>
      File(path).existsSync() ? Gtfs._(sqlite3.open(path, mode: OpenMode.readOnly)) : null;

  void close() => db.close();

  /// Service day start ("noon minus 12 h", as GTFS defines it, so DST days work) in epoch seconds.
  /// ponytail: device time zone, assumed to be Europe/Paris like TCAT's agency_timezone.
  static int base(DateTime day) =>
      DateTime(day.year, day.month, day.day, 12).millisecondsSinceEpoch ~/ 1000 - 12 * 3600;

  Set<String> services(DateTime day) {
    final ymd = _ymd(day);
    final on = {
      for (final c in calendar)
        if ((c['start'] as String).compareTo(ymd) <= 0 &&
            ymd.compareTo(c['end'] as String) <= 0 &&
            (c['days'] as String)[day.weekday - 1] == '1')
          c['service'] as String,
    };
    for (final e in exceptions[ymd] ?? const <Row>[]) {
      e['type'] == 1 ? on.add(e['service']) : on.remove(e['service']);
    }
    return on;
  }

  Trip? trip(String id) {
    final r = db.select('SELECT * FROM trips WHERE id = ?', [id]);
    return r.isEmpty ? null : Trip(r.first);
  }

  List<TripStop> tripStops(String trip) => db
      .select(
        'SELECT st.seq, st.stop, st.secs, s.station, s.name, s.lat, s.lon FROM stop_times st '
        'JOIN stops s ON s.id = st.stop WHERE st.trip = ? ORDER BY st.seq',
        [trip],
      )
      .map(TripStop.new)
      .toList();

  /// The service day start of the run of [trip] nearest to [now] (yesterday's late trips, today, tomorrow).
  int? tripBase(Trip trip, List<TripStop> stops, DateTime now) {
    if (stops.isEmpty) return null;
    final mid = now.millisecondsSinceEpoch ~/ 1000 - (stops.first.secs + stops.last.secs) ~/ 2;
    final bases = [
      for (final offset in const [-1, 0, 1])
        if (services(DateTime(now.year, now.month, now.day + offset)).contains(trip.service))
          base(DateTime(now.year, now.month, now.day + offset)),
    ]..sort((a, b) => (a - mid).abs().compareTo((b - mid).abs()));
    return bases.firstOrNull;
  }

  /// A line's direction: GTFS's direction_id, else the terminus.
  static String dirKey(String dir, String terminus) => dir.isEmpty ? terminus : dir;

  /// The next [count] buses leaving [station] (any of its stops), within [hours], with live delays from [live];
  /// only those of [onlyRoutes], and of [direction] ([dirKey]) when given.
  /// A bus that is canceled, skips the stop or has already passed it is left out.
  List<Departure> departures(
    String station,
    DateTime now,
    Map<String, TripUpdate> live, {
    int count = 20,
    int hours = 4,
    Set<String>? onlyRoutes,
    String? direction,
  }) {
    final t = now.millisecondsSinceEpoch ~/ 1000;
    final out = <Departure>[];
    final timesCache = <String, Map<int, int>>{};
    for (final offset in const [-1, 0, 1]) {
      final day = DateTime(now.year, now.month, now.day + offset);
      final b = base(day), services = this.services(day);
      final rows = db.select(
        'SELECT st.trip, st.seq, st.secs, t.route, t.service, t.dir, t.terminus FROM stop_times st '
        'JOIN stops s ON s.id = st.stop JOIN trips t ON t.id = st.trip '
        'WHERE s.station = ? AND st.last = 0 AND st.secs BETWEEN ? AND ?',
        [station, t - b - _rtMatch, t - b + hours * 3600],
      );
      for (final r in rows) {
        if (!services.contains(r['service'])) continue;
        final route = routes[r['route']];
        if (route == null || (onlyRoutes != null && !onlyRoutes.contains(route.id))) continue;
        if (direction != null && dirKey(r['dir'], r['terminus']) != direction) continue;
        final planned = b + (r['secs'] as int);
        int? delay;
        final u = live[r['trip']];
        if (u != null && (planned - t).abs() < _rtMatch) {
          final times = timesCache[r['trip']] ??= {
            for (final s in db.select('SELECT seq, secs FROM stop_times WHERE trip = ?', [r['trip']]))
              s['seq'] as int: b + (s['secs'] as int),
          };
          delay = u.delayAt(r['seq'], times);
          if (delay == TripUpdate.gone) continue;
        }
        final d = Departure(
          route: route,
          trip: r['trip'],
          terminus: r['terminus'],
          seq: r['seq'],
          scheduled: planned,
          delay: delay,
        );
        if (d.time >= t - 30 && d.time <= t + hours * 3600) out.add(d);
      }
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out.take(count).toList();
  }

  /// Distinct shapes of a line, as [lat, lon] lists. Cached: the map asks again at every poll.
  final _lineShapes = <String, List<List<(double, double)>>>{};
  List<List<(double, double)>> lineShapes(String route) => _lineShapes[route] ??= [
    for (final s in db.select('SELECT DISTINCT shape FROM trips WHERE route = ? AND shape != ?', [route, '']))
      shape(s['shape']),
  ];

  List<(double, double)> shape(String id) => [
    for (final p in db.select('SELECT lat, lon FROM shapes WHERE id = ? ORDER BY seq', [id]))
      (p['lat'] as double, p['lon'] as double),
  ];

  /// For each direction of a line, the stops of its longest trip, with the terminus.
  List<({String terminus, List<TripStop> stops})> lineStops(String route) {
    final out = <({String terminus, List<TripStop> stops})>[];
    final longest = db.select(
      'SELECT t.id, t.terminus, t.dir, COUNT(*) n FROM trips t JOIN stop_times st ON st.trip = t.id '
      'WHERE t.route = ? GROUP BY t.id ORDER BY n DESC',
      [route],
    );
    final seen = <String>{};
    for (final r in longest) {
      if (seen.add(dirKey(r['dir'], r['terminus']))) out.add((terminus: r['terminus'], stops: tripStops(r['id'])));
    }
    return out;
  }

  String? stationOf(String stopId) =>
      db.select('SELECT station FROM stops WHERE id = ?', [stopId]).firstOrNull?['station'];

  Set<String> stopIds(String station) => {
    for (final r in db.select('SELECT id FROM stops WHERE station = ?', [station])) r['id'] as String,
  };

  /// The buses leaving [station] (every station when null): line, direction ([dirKey]) and terminus.
  List<({String station, String route, String dir, String terminus})> stationDirections([String? station]) => [
    for (final r in db.select(
      'SELECT DISTINCT s.station, t.route, t.dir, t.terminus FROM stop_times st JOIN stops s ON s.id = st.stop '
      'JOIN trips t ON t.id = st.trip WHERE st.last = 0 ${station == null ? '' : 'AND s.station = ?'} '
      'ORDER BY t.terminus',
      [?station],
    ))
      (station: r['station'], route: r['route'], dir: dirKey(r['dir'], r['terminus']), terminus: r['terminus']),
  ];

  /// Lines serving a station. Cached: a join over stop_times, asked by every stop tile at each poll and keystroke.
  final _stationRoutes = <String, List<Line>>{};
  List<Line> stationRoutes(String station) => _stationRoutes[station] ??= [
    for (final r in db.select(
      'SELECT DISTINCT t.route FROM stop_times st JOIN stops s ON s.id = st.stop JOIN trips t ON t.id = st.trip '
      'JOIN routes r ON r.id = t.route WHERE s.station = ? AND st.last = 0 ORDER BY r.sort',
      [station],
    ))
      ?routes[r['route']],
  ];
}

String _ymd(DateTime d) => '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

/// The file [gtfsUrl] currently redirects to, without downloading it.
Future<String> currentGtfsSource() async {
  final client = http.Client();
  try {
    final req = http.Request('HEAD', Uri.parse(gtfsUrl))..followRedirects = false;
    final res = await client.send(req).timeout(const Duration(seconds: 20));
    return res.headers['location'] ?? gtfsUrl;
  } finally {
    client.close();
  }
}

/// Downloads the timetable and imports it into [path] (written aside, then swapped in).
Future<void> downloadGtfs(String path, String source) async {
  final res = await http.get(Uri.parse(source)).timeout(const Duration(minutes: 2));
  if (res.statusCode != 200) throw http.ClientException('HTTP ${res.statusCode}', Uri.parse(source));
  final bytes = res.bodyBytes;
  await Isolate.run(() => importGtfs(bytes, path, source));
}

/// Imports a GTFS zip into a new SQLite database at [path]. Keeps TCAT's public lines only, and flags each trip's
/// last stop, where nobody boards.
void importGtfs(Uint8List zip, String path, String source) {
  final files = {for (final f in ZipDecoder().decodeBytes(zip)) f.name.split('/').last: f};
  Iterable<Map<String, String>> rows(String name) {
    final f = files[name];
    return f == null ? const [] : _csv(f.content);
  }

  final tmp = '$path.tmp';
  if (File(tmp).existsSync()) File(tmp).deleteSync();
  final db = sqlite3.open(tmp);
  db.execute('''
    PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF;
    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE routes(id TEXT PRIMARY KEY, short TEXT, long TEXT, desc TEXT, color INT, text INT, sort INT);
    CREATE TABLE stations(id TEXT PRIMARY KEY, name TEXT, lat REAL, lon REAL);
    CREATE TABLE stops(id TEXT PRIMARY KEY, name TEXT, lat REAL, lon REAL, station TEXT);
    CREATE TABLE trips(id TEXT PRIMARY KEY, route TEXT, service TEXT, dir TEXT, shape TEXT, terminus TEXT);
    CREATE TABLE stop_times(trip TEXT, seq INT, stop TEXT, secs INT, last INT);
    CREATE TABLE shapes(id TEXT, seq INT, lat REAL, lon REAL);
    CREATE TABLE calendar(service TEXT, days TEXT, start TEXT, "end" TEXT);
    CREATE TABLE calendar_dates(service TEXT, date TEXT, type INT);
    BEGIN;
  ''');

  int color(String? hex, int fallback) {
    final c = int.tryParse(hex ?? '', radix: 16);
    return c == null ? fallback : 0xFF000000 | c;
  }

  final routeRows = rows('routes.txt').where((r) => r['agency_id'] != _hiddenAgency).toList();
  final routeIds = {for (final r in routeRows) r['route_id']!};

  final trips = [
    for (final t in rows('trips.txt'))
      if (routeIds.contains(t['route_id'])) t,
  ];
  final tripIds = {for (final t in trips) t['trip_id']!};

  // stop_times: keep each trip's rows to find its last stop, the terminus.
  final times = <String, List<(int, String, int, bool)>>{};
  for (final r in rows('stop_times.txt')) {
    final trip = r['trip_id']!;
    if (!tripIds.contains(trip)) continue;
    final hms = (r['departure_time']?.isNotEmpty ?? false) ? r['departure_time']! : r['arrival_time']!;
    (times[trip] ??= []).add((int.parse(r['stop_sequence']!), r['stop_id']!, _secs(hms), r['pickup_type'] == '1'));
  }

  final stopRows = {for (final s in rows('stops.txt')) s['stop_id']!: s};
  final stopTimes = db.prepare('INSERT INTO stop_times VALUES (?, ?, ?, ?, ?)');
  final servedStops = <String>{}, terminus = <String, String>{}, usedRoutes = <String>{};
  for (final MapEntry(key: trip, value: st) in times.entries) {
    st.sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 0; i < st.length; i++) {
      final (seq, stop, secs, noPickup) = st[i];
      stopTimes.execute([trip, seq, stop, secs, i == st.length - 1 || noPickup ? 1 : 0]);
      servedStops.add(stop);
    }
    terminus[trip] = stopRows[st.last.$2]?['stop_name'] ?? '';
  }
  stopTimes.close();

  final tripStmt = db.prepare('INSERT INTO trips VALUES (?, ?, ?, ?, ?, ?)');
  for (final t in trips) {
    if (!times.containsKey(t['trip_id'])) continue;
    usedRoutes.add(t['route_id']!);
    tripStmt.execute([
      t['trip_id'],
      t['route_id'],
      t['service_id'],
      t['direction_id'] ?? '',
      t['shape_id'] ?? '',
      terminus[t['trip_id']],
    ]);
  }
  tripStmt.close();

  // Lines in TCAT's order: numbers, then letters (D1-D7 Sundays, N, ZI...), then on-demand lines.
  final ordered = routeRows.where((r) => usedRoutes.contains(r['route_id'])).toList()
    ..sort((a, b) {
      (int, int, String) key(Map<String, String> r) {
        final n = r['route_short_name'] ?? '';
        return ((r['route_desc'] ?? '').contains('demande') ? 1 : 0, int.tryParse(n) ?? 1 << 20, n);
      }

      final ka = key(a), kb = key(b);
      return ka.$1 != kb.$1 ? ka.$1 - kb.$1 : (ka.$2 != kb.$2 ? ka.$2 - kb.$2 : ka.$3.compareTo(kb.$3));
    });
  final routeStmt = db.prepare('INSERT INTO routes VALUES (?, ?, ?, ?, ?, ?, ?)');
  for (final (i, r) in ordered.indexed) {
    routeStmt.execute([
      r['route_id'],
      r['route_short_name'] ?? '',
      r['route_long_name'] ?? '',
      r['route_desc'] ?? '',
      color(r['route_color'], 0xFF1F6FB2),
      color(r['route_text_color'], 0xFFFFFFFF),
      i,
    ]);
  }
  routeStmt.close();

  // Stops are grouped by their parent station (both sides of the street), or stand alone.
  final stopStmt = db.prepare('INSERT INTO stops VALUES (?, ?, ?, ?, ?)');
  final stations = <String>{};
  for (final s in stopRows.values) {
    if (!servedStops.contains(s['stop_id'])) continue;
    final parent = s['parent_station'] ?? '';
    final station = parent.isNotEmpty && stopRows.containsKey(parent) ? parent : s['stop_id']!;
    stations.add(station);
    stopStmt.execute([s['stop_id'], s['stop_name'], _d(s['stop_lat']), _d(s['stop_lon']), station]);
  }
  stopStmt.close();
  final stationStmt = db.prepare('INSERT INTO stations VALUES (?, ?, ?, ?)');
  for (final id in stations) {
    final s = stopRows[id]!;
    stationStmt.execute([id, s['stop_name'], _d(s['stop_lat']), _d(s['stop_lon'])]);
  }
  stationStmt.close();

  final usedShapes = {for (final t in trips) t['shape_id'] ?? ''};
  final shapeStmt = db.prepare('INSERT INTO shapes VALUES (?, ?, ?, ?)');
  for (final p in rows('shapes.txt')) {
    if (!usedShapes.contains(p['shape_id'])) continue;
    shapeStmt.execute([
      p['shape_id'],
      int.parse(p['shape_pt_sequence']!),
      _d(p['shape_pt_lat']),
      _d(p['shape_pt_lon']),
    ]);
  }
  shapeStmt.close();

  const days = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
  var from = '99999999', to = '';
  final calStmt = db.prepare('INSERT INTO calendar VALUES (?, ?, ?, ?)');
  for (final c in rows('calendar.txt')) {
    calStmt.execute([c['service_id'], days.map((d) => c[d] ?? '0').join(), c['start_date'], c['end_date']]);
    if (c['start_date']!.compareTo(from) < 0) from = c['start_date']!;
    if (c['end_date']!.compareTo(to) > 0) to = c['end_date']!;
  }
  calStmt.close();
  final datesStmt = db.prepare('INSERT INTO calendar_dates VALUES (?, ?, ?)');
  for (final d in rows('calendar_dates.txt')) {
    datesStmt.execute([d['service_id'], d['date'], int.parse(d['exception_type']!)]);
    if (d['exception_type'] == '1' && d['date']!.compareTo(from) < 0) from = d['date']!;
    if (d['exception_type'] == '1' && d['date']!.compareTo(to) > 0) to = d['date']!;
  }
  datesStmt.close();

  db.execute('INSERT INTO meta VALUES (?, ?), (?, ?), (?, ?)', ['source', source, 'from', from, 'to', to]);
  db.execute('''
    COMMIT;
    CREATE INDEX st_stop ON stop_times(stop, secs);
    CREATE INDEX st_trip ON stop_times(trip, seq);
    CREATE INDEX stops_station ON stops(station);
    CREATE INDEX trips_route ON trips(route);
    CREATE INDEX shapes_id ON shapes(id, seq);
  ''');
  db.close();
  File(tmp).renameSync(path);
}

int _secs(String hms) {
  final p = hms.trim().split(':');
  return int.parse(p[0]) * 3600 + int.parse(p[1]) * 60 + int.parse(p[2]);
}

double _d(String? s) => double.tryParse(s ?? '') ?? 0;

/// CSV rows as maps keyed by the header. UTF-8 (BOM allowed), else Windows-1252-ish, which TCAT's export used to be.
Iterable<Map<String, String>> _csv(List<int> bytes) sync* {
  String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    text = latin1.decode(bytes);
  }
  if (text.startsWith('﻿')) text = text.substring(1);
  List<String>? header;
  for (final line in const LineSplitter().convert(text)) {
    if (line.isEmpty) continue;
    final cells = parseCsvLine(line);
    if (header == null) {
      header = cells.map((h) => h.trim()).toList();
      continue;
    }
    yield {for (var i = 0; i < header.length && i < cells.length; i++) header[i]: cells[i]};
  }
}

/// Splits a CSV line, with RFC 4180 quotes ("a, b" and "" inside quotes). Quoted line breaks aren't supported:
/// none of TCAT's files have any.
List<String> parseCsvLine(String line) {
  final out = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quoted) {
      if (c == '"' && i + 1 < line.length && line[i + 1] == '"') {
        cell.write('"');
        i++;
      } else if (c == '"') {
        quoted = false;
      } else {
        cell.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == ',') {
      out.add(cell.toString());
      cell.clear();
    } else {
      cell.write(c);
    }
  }
  out.add(cell.toString());
  return out;
}
