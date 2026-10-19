import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retcat/gtfs.dart';
import 'package:retcat/realtime.dart';
import 'package:retcat/widget.dart';

/// Protobuf encoding, just enough to build TripUpdates: fields are (number, int | String | List of fields).
Uint8List pb(List<(int, Object)> fields) {
  final out = BytesBuilder();
  void varint(int v) {
    while (v >= 0x80 || v < 0) {
      out.addByte(v & 0x7f | 0x80);
      v = v >>> 7;
    }
    out.addByte(v);
  }

  for (final (n, v) in fields) {
    if (v is int) {
      varint(n << 3);
      varint(v);
    } else {
      final bytes = v is String ? Uint8List.fromList(v.codeUnits) : pb(v as List<(int, Object)>);
      varint(n << 3 | 2);
      varint(bytes.length);
      out.add(bytes);
    }
  }
  return out.toBytes();
}

/// A TripUpdate for trip T with stop updates (seq, time or null, delay or null, skipped).
TripUpdate update(List<(int, int?, int?, bool)> stops, {bool canceled = false}) => TripUpdate(
  Msg(
    pb([
      (1, [(1, 'T'), if (canceled) (4, 3)]),
      for (final (seq, time, delay, skipped) in stops)
        (
          2,
          [
            (1, seq),
            (3, [?(time == null ? null : (2, time)), ?(delay == null ? null : (1, delay))]),
            if (skipped) (5, 1),
          ],
        ),
    ]),
  ),
);

void main() {
  test('decodes the vehicle positions feed', () {
    final v = parseVehicles(File('test/fixtures/vp.pb').readAsBytesSync());
    expect(v, hasLength(11));
    expect((v.first.id, v.first.route, v.first.trip, v.first.stopId), ('347', 'N', 'DF16C2024156', '0:GAR01'));
    expect(v.first.status, Status.stopped);
    expect(v.first.lat, closeTo(48.2966, 1e-3));
    expect(v.first.lon, closeTo(4.0670, 1e-3));
    expect(v[1].bearing, 86);
  });

  test('decodes the trip updates feed', () {
    final t = parseTripUpdates(File('test/fixtures/tu.pb').readAsBytesSync());
    expect(t, hasLength(11));
    final s = t['DF16C2026288']!.stops.first;
    expect((s.seq, s.stopId, s.time), (20, '0:BEU01', 1792325977));
    expect(parseAlerts(File('test/fixtures/al.pb').readAsBytesSync()), isEmpty);
  });

  test('live delays follow ha-tcat rules', () {
    final times = {1: 1000, 2: 1100, 3: 1200, 4: 1300};
    expect(update([(2, 1160, null, false)]).delayAt(2, times), 60); // own predicted time
    expect(update([(2, null, -30, false)]).delayAt(2, times), -30); // own delay, negative
    expect(update([(2, 1160, null, false)]).delayAt(4, times), 60); // carried forward
    expect(update([(3, 1260, null, false)]).delayAt(2, times), TripUpdate.gone); // only later stops: passed
    expect(update([(2, null, null, true)]).delayAt(2, times), TripUpdate.gone); // skipped
    expect(update([(2, 1160, null, false)], canceled: true).delayAt(4, times), TripUpdate.gone);
    expect(update([]).delayAt(2, times), isNull);
  });

  test('reads the App Group renamed by a re-signing tool', () {
    const profile =
        '\x30\x82garbage<?xml version="1.0"?><plist><dict><key>Entitlements</key><dict>'
        '<key>com.apple.security.application-groups</key>\n\t<array>\n\t\t<string>group.XTL-AB12.com.eylexander.retcat'
        '</string>\n\t</array></dict></dict></plist>\x00sig';
    expect(groupFromProfile(profile), 'group.XTL-AB12.com.eylexander.retcat');
    expect(groupFromProfile('<plist></plist>'), isNull);
  });

  test('splits quoted CSV', () {
    expect(parseCsvLine('a,"b, c",,"d ""e"""'), ['a', 'b, c', '', 'd "e"']);
  });

  test('imports a GTFS and lists departures', () {
    final now = DateTime.now();
    String ymd(DateTime d) => '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
    String hms(int s) => [s ~/ 3600, s ~/ 60 % 60, s % 60].map((x) => x.toString().padLeft(2, '0')).join(':');
    final t = now.difference(DateTime(now.year, now.month, now.day, 12)).inSeconds + 12 * 3600;
    final files = {
      'routes.txt':
          'route_id,agency_id,route_short_name,route_long_name,route_desc,route_type,route_color,route_text_color\n'
          '3,TCAT,3,ST JULIEN>BARBEREY,,3,A85F3E,FFFFFF\n'
          'X,MASQUE,X,Atelier,,3,000000,FFFFFF\n',
      'stops.txt':
          '﻿stop_id,stop_name,stop_lat,stop_lon,location_type,parent_station\n'
          '1:A,HOCHE,48.29,4.07,1,\n0:A1,HOCHE,48.29,4.07,0,1:A\n0:A2,HOCHE,48.29,4.07,0,1:A\n'
          '0:B1,GARE,48.30,4.06,0,\n0:C1,BARBEREY,48.31,4.05,0,\n',
      'trips.txt':
          'route_id,service_id,trip_id,trip_headsign,direction_id,shape_id\n3,S,T1,,0,SH\n3,S,T2,,1,\nX,S,T3,,0,\n',
      'stop_times.txt':
          'trip_id,arrival_time,departure_time,stop_id,stop_sequence\n'
          'T1,${hms(t + 600)},${hms(t + 600)},0:A1,1\nT1,${hms(t + 900)},${hms(t + 900)},0:B1,2\n'
          'T1,${hms(t + 1200)},${hms(t + 1200)},0:C1,3\n'
          'T2,${hms(t + 300)},${hms(t + 300)},0:C1,1\nT2,${hms(t + 700)},${hms(t + 700)},0:A2,2\n'
          'T3,${hms(t + 100)},${hms(t + 100)},0:A1,1\nT3,${hms(t + 200)},${hms(t + 200)},0:B1,2\n',
      'calendar.txt': 'service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n',
      'calendar_dates.txt': 'service_id,date,exception_type\nS,${ymd(now)},1\n',
      'shapes.txt': 'shape_id,shape_pt_lat,shape_pt_lon,shape_pt_sequence\nSH,48.29,4.07,0\nSH,48.31,4.05,1\n',
    };
    final archive = Archive();
    for (final MapEntry(:key, :value) in files.entries) {
      archive.addFile(ArchiveFile.string(key, value));
    }
    final dir = Directory.systemTemp.createTempSync('retcat');
    final path = '${dir.path}/gtfs.db';
    importGtfs(Uint8List.fromList(ZipEncoder().encode(archive)), path, 'src');
    final g = Gtfs.open(path)!;
    addTearDown(() {
      g.close();
      dir.deleteSync(recursive: true);
    });

    expect(g.routes.keys, ['3']); // MASQUE hidden
    expect(g.stations.keys.toSet(), {'1:A', '0:B1', '0:C1'});
    expect(g.validTo, ymd(now));
    // T2 ends at HOCHE: nobody boards there, so only T1 leaves.
    final live = {
      'T1': update([(1, null, 120, false)]),
    };
    final deps = g.departures('1:A', now, live);
    expect(deps.map((d) => (d.trip, d.terminus, d.delay)), [('T1', 'BARBEREY', 120)]);
    expect(deps.single.time, Gtfs.base(now) + t + 600 + 120);
    expect(g.departures('0:C1', now, {}).map((d) => d.trip), ['T2']);
    expect(g.lineStops('3').map((d) => d.terminus), ['BARBEREY', 'HOCHE']);
    expect(g.shape('SH'), hasLength(2));
  });
}
