import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// TCAT's GTFS-RT feeds (transport.data.gouv.fr). The stable data.gouv.fr links redirect to the producer's server
/// (plain HTTP on an IP, hence the cleartext settings in the Android manifest and the iOS Info.plist).
const vehiclesUrl = 'https://www.data.gouv.fr/api/1/datasets/r/98230d13-cccb-4c27-b0bc-d1b9341ca77b';
const tripUpdatesUrl = 'https://www.data.gouv.fr/api/1/datasets/r/8dc66569-b744-4d22-95df-f8496e8eddb6';
const alertsUrl = 'https://www.data.gouv.fr/api/1/datasets/r/cab95ea5-0366-466f-a016-fda666083113';

final _resolved = <String, Uri>{};

/// Downloads a feed. The redirect is resolved once per run, so polling costs one request.
Future<Uint8List> fetchFeed(String url) async {
  final uri = _resolved[url] ??= await _resolve(Uri.parse(url));
  final res = await http.get(uri).timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) {
    _resolved.remove(url);
    throw http.ClientException('HTTP ${res.statusCode}', uri);
  }
  return res.bodyBytes;
}

Future<Uri> _resolve(Uri uri) async {
  final client = http.Client();
  try {
    final req = http.Request('HEAD', uri)..followRedirects = false;
    final res = await client.send(req).timeout(const Duration(seconds: 15));
    final loc = res.headers['location'];
    return loc == null ? uri : uri.resolve(loc);
  } finally {
    client.close();
  }
}

/// A protobuf message decoded into its fields: varints and fixed values as ints, length-delimited ones as bytes.
/// A minimal wire-format reader, enough for GTFS-RT (no generated code, no protobuf dependency).
class Msg {
  Msg(Uint8List b) {
    var pos = 0;
    int varint() {
      var r = 0, shift = 0;
      while (true) {
        final x = b[pos++];
        r |= (x & 0x7f) << shift;
        if (x < 0x80) return r;
        shift += 7;
      }
    }

    while (pos < b.length) {
      final key = varint();
      final Object v;
      switch (key & 7) {
        case 0:
          v = varint();
        case 1:
          v = ByteData.sublistView(b, pos, pos += 8).getInt64(0, Endian.little);
        case 2:
          final len = varint();
          v = Uint8List.sublistView(b, pos, pos += len);
        case 5:
          v = ByteData.sublistView(b, pos, pos += 4).getUint32(0, Endian.little);
        default:
          throw const FormatException('bad protobuf wire type');
      }
      (_f[key >> 3] ??= []).add(v);
    }
  }

  final _f = <int, List<Object>>{};

  Object? _first(int n) => _f[n]?.first;
  bool has(int n) => _f.containsKey(n);
  int integer(int n) => _first(n) is int ? _first(n) as int : 0;
  String str(int n) => _first(n) is Uint8List ? utf8.decode(_first(n) as Uint8List, allowMalformed: true) : '';
  double float(int n) => _first(n) is int ? (ByteData(4)..setUint32(0, _first(n) as int)).getFloat32(0) : 0;
  Msg msg(int n) => _first(n) is Uint8List ? Msg(_first(n) as Uint8List) : Msg(Uint8List(0));
  Iterable<Msg> all(int n) => (_f[n] ?? const []).whereType<Uint8List>().map(Msg.new);
}

enum Status { incoming, stopped, inTransit }

class Vehicle {
  Vehicle(Msg v)
    : trip = v.msg(1).str(1),
      route = v.msg(1).str(5),
      lat = v.msg(2).float(1),
      lon = v.msg(2).float(2),
      bearing = v.msg(2).float(3),
      speed = v.msg(2).float(5),
      seq = v.integer(3),
      status = Status.values[v.integer(4).clamp(0, 2)],
      time = v.integer(5),
      stopId = v.str(7),
      id = v.msg(8).str(1),
      label = v.msg(8).str(2);

  final String trip, route, stopId, id, label;

  /// Degrees, degrees clockwise from north, m/s.
  final double lat, lon, bearing, speed;
  final Status status;

  /// Current stop sequence (the stop it is at or heading to), and the position's epoch seconds.
  final int seq, time;
}

class StopUpdate {
  StopUpdate(Msg s)
    : seq = s.integer(1),
      stopId = s.str(4),
      skipped = s.integer(5) == 1,
      time = _time(s.msg(3)) ?? _time(s.msg(2)),
      delay = _delay(s.msg(3)) ?? _delay(s.msg(2));

  final int seq;
  final String stopId;
  final bool skipped;

  /// Predicted epoch seconds (departure, else arrival), or the delay in seconds, when given.
  final int? time, delay;

  static int? _time(Msg e) => e.has(2) ? e.integer(2) : null;
  static int? _delay(Msg e) => e.has(1) ? e.integer(1).toSigned(32) : null;
}

class TripUpdate {
  TripUpdate(Msg t)
    : trip = t.msg(1).str(1),
      canceled = t.msg(1).integer(4) == 3,
      delay = t.has(5) ? t.integer(5).toSigned(32) : null,
      stops = t.all(2).map(StopUpdate.new).toList();

  final String trip;
  final bool canceled;
  final int? delay;
  final List<StopUpdate> stops;

  /// Before a trip starts, TCAT gives many of its stops the feed's timestamp as their time: a time shared by several
  /// stops of the update is a placeholder, not a prediction (it would show "à l'arrêt, -14 min").
  late final _placeholders = () {
    final seen = <int>{};
    return {
      for (final s in stops)
        if (s.time != null && !seen.add(s.time!)) s.time!,
    };
  }();

  /// Seconds late (negative: early) at stop [seq] of this trip, null if the update says nothing about it, or [gone]
  /// if the bus won't stop there (canceled, stop skipped, already passed). [times] are the trip's scheduled epoch
  /// seconds by stop_sequence: a stop without its own update takes the delay of the closest earlier one (GTFS-RT).
  /// Same rules as `live_delay` in Eylexander/ha-tcat, so the app and Home Assistant agree.
  int? delayAt(int seq, Map<int, int> times) {
    if (canceled) return gone;
    int? before;
    for (final s in stops) {
      final at = s.time == null || _placeholders.contains(s.time)
          ? s.delay
          : (times[s.seq] == null ? null : s.time! - times[s.seq]!);
      if (s.seq == seq) {
        if (s.skipped) return gone;
        if (at != null) return at;
      }
      if (s.seq < seq && at != null) before = at;
    }
    if (before != null) return before;
    if (stops.isNotEmpty && stops.every((s) => s.seq > seq)) return gone;
    return delay;
  }

  static const gone = -1 << 40;
}

class Alert {
  Alert(Msg a)
    : header = _text(a.msg(10)),
      description = _text(a.msg(11)),
      url = _text(a.msg(8)),
      routes = {for (final e in a.all(5)) e.str(2)}..remove(''),
      stops = {for (final e in a.all(5)) e.str(5)}..remove(''),
      periods = [for (final p in a.all(1)) (start: p.integer(1), end: p.integer(2))];

  final String header, description, url;
  final Set<String> routes, stops;
  final List<({int start, int end})> periods;

  bool activeAt(int now) => periods.isEmpty || periods.any((p) => p.start <= now && (p.end == 0 || now <= p.end));

  /// French translation if there is one, else the first.
  static String _text(Msg t) {
    final all = t.all(1).toList();
    if (all.isEmpty) return '';
    return all.firstWhere((x) => x.str(2).startsWith('fr'), orElse: () => all.first).str(1);
  }
}

/// A decoded feed: its timestamp (epoch seconds) and entities.
({int time, Iterable<Msg> entities}) _feed(Uint8List bytes) {
  final m = Msg(bytes);
  return (time: m.msg(1).integer(3), entities: m.all(2).where((e) => e.integer(2) == 0));
}

List<Vehicle> parseVehicles(Uint8List bytes) => [
  for (final e in _feed(bytes).entities)
    if (e.has(4) && e.msg(4).has(2)) Vehicle(e.msg(4)),
];

Map<String, TripUpdate> parseTripUpdates(Uint8List bytes) => {
  for (final e in _feed(bytes).entities)
    if (e.has(3)) e.msg(3).msg(1).str(1): TripUpdate(e.msg(3)),
};

List<Alert> parseAlerts(Uint8List bytes) => [
  for (final e in _feed(bytes).entities)
    if (e.has(5)) Alert(e.msg(5)),
];
