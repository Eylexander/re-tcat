import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'gtfs.dart';
import 'realtime.dart';
import 'stops.dart';
import 'store.dart';
import 'widgets.dart';

const troyes = LatLng(48.2973, 4.0744);

/// The user's position, asking for the permission if needed; null if refused or unavailable.
Future<LatLng?> locate(BuildContext context) async {
  final android = Theme.of(context).platform == TargetPlatform.android;
  try {
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied || p == LocationPermission.deniedForever) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Localisation refusée')));
      }
      return null;
    }
    final pos = await Geolocator.getCurrentPosition(
      // No Google Play services: Android's own location manager (the app is on F-Droid).
      locationSettings: android
          ? AndroidSettings(forceLocationManager: true, timeLimit: const Duration(seconds: 20))
          : const LocationSettings(timeLimit: Duration(seconds: 20)),
    );
    return LatLng(pos.latitude, pos.longitude);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Position indisponible')));
    }
    return null;
  }
}

/// A map of Troyes with the live buses, the stops when zoomed in, and optional line [shapes].
class LiveMap extends StatefulWidget {
  const LiveMap({
    super.key,
    required this.controller,
    this.shapes = const [],
    this.shapeColor,
    this.routes,
    this.follow,
    this.onFollowLost,
    this.highlightStops = const [],
    this.initialCenter = troyes,
    this.initialZoom = 13,
    this.me,
    this.padding = EdgeInsets.zero,
  });

  final MapController controller;
  final List<List<(double, double)>> shapes;
  final Color? shapeColor;

  /// Only the buses of these lines (all when null).
  final Set<String>? routes;

  /// The vehicle id the camera follows; [onFollowLost] is called when the user pans away.
  final String? follow;
  final VoidCallback? onFollowLost;

  /// Stops drawn bigger, at any zoom (the followed trip's or the line's).
  final List<TripStop> highlightStops;
  final LatLng initialCenter;
  final double initialZoom;
  final LatLng? me;

  /// Room taken by overlays (sheet, chips), kept clear when following.
  final EdgeInsets padding;

  @override
  State<LiveMap> createState() => _LiveMapState();
}

class _LiveMapState extends State<LiveMap> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..addListener(_tick);
  var _from = <String, LatLng>{}, _to = <String, LatLng>{};
  List<Vehicle>? _shown;
  double _zoom = 13;

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  LatLng _at(String id) {
    final a = _from[id], b = _to[id]!;
    if (a == null) return b;
    final t = Curves.easeInOut.transform(_anim.value);
    return LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);
  }

  /// New positions glide from where the buses are drawn, so they move instead of jumping every 15 s.
  void _sync() {
    if (identical(_shown, store.vehicles)) return;
    _shown = store.vehicles;
    _from = {for (final id in _to.keys) id: _at(id)};
    _to = {for (final v in store.vehicles) v.id: LatLng(v.lat, v.lon)};
    _anim.forward(from: 0);
  }

  void _tick() {
    final f = widget.follow;
    if (f != null && _to.containsKey(f)) _center(_at(f));
  }

  void _center(LatLng p) {
    try {
      final cam = widget.controller.camera;
      // Keep the bus in the middle of the visible part of the map (above the sheet).
      final offset = (widget.padding.bottom - widget.padding.top) / 2;
      final pt = cam.projectAtZoom(p, cam.zoom) + Offset(0, offset);
      widget.controller.move(cam.unprojectAtZoom(pt, cam.zoom), cam.zoom);
    } catch (_) {
      // Not laid out yet.
    }
  }

  @override
  void didUpdateWidget(LiveMap old) {
    super.didUpdateWidget(old);
    if (widget.follow != null && widget.follow != old.follow && _to.containsKey(widget.follow)) {
      _center(_to[widget.follow]!);
    }
  }

  @override
  Widget build(BuildContext context) {
    _sync();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    final gtfs = store.gtfs!;
    final vehicles = [
      for (final v in store.vehicles)
        if (widget.routes == null || widget.routes!.contains(v.route)) v,
    ]..sort((a, b) => (a.id == widget.follow ? 1 : 0) - (b.id == widget.follow ? 1 : 0));

    return FlutterMap(
      mapController: widget.controller,
      options: MapOptions(
        initialCenter: widget.initialCenter,
        initialZoom: widget.initialZoom,
        minZoom: 10,
        maxZoom: 19,
        interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
        onPositionChanged: (cam, gesture) {
          if (gesture && widget.follow != null) widget.onFollowLost?.call();
          if ((cam.zoom >= 15) != (_zoom >= 15)) setState(() => _zoom = cam.zoom);
          _zoom = cam.zoom;
        },
      ),
      children: [
        TileLayer(
          // OpenStreetMap's own tiles (usage policy: identify the app, no bulk downloads), inverted in dark mode.
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.eylexander.retcat',
          tileBuilder: dark ? darkModeTileBuilder : null,
        ),
        PolylineLayer(
          polylines: [
            for (final s in widget.shapes)
              Polyline(
                points: [for (final (lat, lon) in s) LatLng(lat, lon)],
                color: widget.shapeColor ?? cs.primary,
                strokeWidth: 5,
                borderColor: cs.surface,
                borderStrokeWidth: 1.5,
              ),
          ],
        ),
        if (_zoom >= 15)
          MarkerLayer(
            markers: [
              for (final s in gtfs.stations.values)
                Marker(
                  point: LatLng(s.lat, s.lon),
                  width: 36,
                  height: 36,
                  // Opaque: the whole marker takes the tap, not only the 10 px dot.
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => openStop(context, s.id),
                    child: Center(
                      child: _Dot(size: 10, color: cs.onSurfaceVariant, label: s.name),
                    ),
                  ),
                ),
            ],
          ),
        MarkerLayer(
          markers: [
            for (final s in widget.highlightStops)
              Marker(
                point: LatLng(s.lat, s.lon),
                width: 36,
                height: 36,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => openStop(context, s.station),
                  child: Center(
                    child: _Dot(size: 13, color: widget.shapeColor ?? cs.primary, label: s.name),
                  ),
                ),
              ),
            if (widget.me != null)
              Marker(
                point: widget.me!,
                width: 22,
                height: 22,
                child: _Dot(size: 18, color: Colors.blue, label: 'Ma position'),
              ),
          ],
        ),
        AnimatedBuilder(
          animation: _anim,
          builder: (context, _) => MarkerLayer(
            markers: [
              for (final v in vehicles)
                if (_to.containsKey(v.id))
                  Marker(
                    point: _at(v.id),
                    width: 52,
                    height: 52,
                    child: BusMarker(v, selected: v.id == widget.follow),
                  ),
            ],
          ),
        ),
        RichAttributionWidget(
          alignment: AttributionAlignment.bottomLeft,
          attributions: [
            const TextSourceAttribution('© les contributeurs d\'OpenStreetMap'),
            const TextSourceAttribution('Données TCAT (ODbL)'),
          ],
        ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.size, required this.color, required this.label});
  final double size;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        shape: BoxShape.circle,
        border: Border.all(color: color, width: size / 4),
      ),
    ),
  );
}

/// A bus: its line number in the line's colors, with an arrow pointing where it heads.
class BusMarker extends StatelessWidget {
  const BusMarker(this.v, {super.key, this.selected = false});
  final Vehicle v;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final route = store.gtfs!.routes[v.route];
    final color = route == null ? Theme.of(context).colorScheme.primary : Color(route.color);
    final text = route == null ? Colors.white : Color(route.text);
    final size = selected ? 40.0 : 32.0;
    return GestureDetector(
      onTap: () => openBus(context, v),
      child: Semantics(
        button: true,
        label: 'Bus ligne ${route?.short ?? v.route}',
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (v.status == Status.inTransit || v.speed > 0)
              Transform.rotate(
                angle: v.bearing * math.pi / 180,
                child: SizedBox(
                  width: size + 18,
                  height: size + 18,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Icon(Icons.navigation, size: 14, color: color),
                  ),
                ),
              ),
            Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: selected ? 3 : 2),
                boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black38)],
              ),
              child: Text(
                route?.short ?? '?',
                style: TextStyle(color: text, fontWeight: FontWeight.w800, fontSize: size * 0.36, height: 1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void openBus(BuildContext context, Vehicle v) => Navigator.of(context).push(
  MaterialPageRoute(
    builder: (_) => FollowPage(trip: v.trip, vehicle: v.id),
  ),
);

/// The "Carte" tab: every bus in service, filtered by line.
class MapTab extends StatefulWidget {
  const MapTab({super.key});

  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> {
  final _map = MapController();
  final _lines = <String>{};
  LatLng? _me;

  @override
  Widget build(BuildContext context) {
    final gtfs = store.gtfs!;
    final running = {for (final v in store.vehicles) v.route};
    final routes = gtfs.routes.values.where((r) => running.contains(r.id) || _lines.contains(r.id)).toList();
    final shapes = [for (final id in _lines) ...gtfs.lineShapes(id)];
    final cs = Theme.of(context).colorScheme;
    final count = store.vehicles.where((v) => _lines.isEmpty || _lines.contains(v.route)).length;

    return Stack(
      children: [
        LiveMap(
          controller: _map,
          routes: _lines.isEmpty ? null : _lines,
          shapes: shapes,
          shapeColor: _lines.length == 1 ? Color(gtfs.routes[_lines.first]!.color) : null,
          me: _me,
        ),
        SafeArea(
          child: SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (final r in routes)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text(r.short),
                      selected: _lines.contains(r.id),
                      showCheckmark: false,
                      avatar: CircleAvatar(backgroundColor: Color(r.color), radius: 6),
                      backgroundColor: cs.surfaceContainer,
                      onSelected: (on) => setState(() => on ? _lines.add(r.id) : _lines.remove(r.id)),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 12,
          bottom: 64,
          child: Card(
            color: cs.surfaceContainerHigh,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                '$count bus en service · ${liveStatus()}',
                style: TextStyle(color: store.offline ? cs.error : cs.onSurface),
              ),
            ),
          ),
        ),
        Positioned(
          right: 16,
          bottom: 64,
          child: FloatingActionButton(
            tooltip: 'Ma position',
            onPressed: () async {
              final p = await locate(context);
              if (p == null) return;
              setState(() => _me = p);
              _map.move(p, 16);
            },
            child: const Icon(Icons.my_location),
          ),
        ),
      ],
    );
  }
}

/// Following one trip: its bus on the map (the camera tracks it) and its stops with live times. [vehicle] is the bus
/// running it, when there is one in the feed; without it, the trip's timetable.
class FollowPage extends StatefulWidget {
  const FollowPage({super.key, required this.trip, this.vehicle});
  final String trip;
  final String? vehicle;

  @override
  State<FollowPage> createState() => _FollowPageState();
}

class _FollowPageState extends State<FollowPage> {
  final _map = MapController();
  final _list = ScrollController();
  bool _following = true, _scrolled = false;
  late final Trip? _trip = store.gtfs!.trip(widget.trip);
  late final List<TripStop> _stops = store.gtfs!.tripStops(widget.trip);
  late final _shape = _trip == null || _trip.shape.isEmpty ? <(double, double)>[] : store.gtfs!.shape(_trip.shape);

  @override
  void initState() {
    super.initState();
    store.addListener(_changed);
  }

  @override
  void dispose() {
    store.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  Vehicle? get _bus =>
      store.vehicles.where((v) => v.id == widget.vehicle).firstOrNull ?? store.vehicleOnTrip(widget.trip);

  @override
  Widget build(BuildContext context) {
    final trip = _trip;
    final gtfs = store.gtfs!;
    if (trip == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Course inconnue')),
      );
    }
    final route = gtfs.routes[trip.route]!;
    final bus = _bus?.trip == trip.id ? _bus : null;
    final base = gtfs.tripBase(trip, _stops, DateTime.now()) ?? Gtfs.base(DateTime.now());
    final times = {for (final s in _stops) s.seq: base + s.secs};
    final update = store.live[trip.id];
    final now = nowSecs();
    // Index of the next stop: from the bus position, else from the (live) times.
    int? delayAt(TripStop s) {
      final d = update?.delayAt(s.seq, times);
      return d == TripUpdate.gone ? null : d;
    }

    var next = bus == null
        ? _stops.indexWhere((s) => times[s.seq]! + (delayAt(s) ?? 0) >= now)
        : _stops.indexWhere((s) => s.seq >= bus.seq && (bus.seq > 0 || s.stopId == bus.stopId));
    if (next < 0) next = bus == null ? _stops.length : 0;
    final cs = Theme.of(context).colorScheme;
    final height = MediaQuery.sizeOf(context).height;

    if (!_scrolled && next > 1) {
      _scrolled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_list.hasClients) _list.jumpTo(((next - 1) * 64.0).clamp(0, _list.position.maxScrollExtent));
      });
    }

    final status = bus == null
        ? (update == null ? 'Bus non localisé · horaires théoriques' : 'Bus non localisé · temps réel')
        : switch (bus.status) {
            Status.stopped => 'À l\'arrêt ${_name(bus.stopId)}',
            Status.incoming => 'Arrive à ${_name(bus.stopId)}',
            Status.inTransit => 'Vers ${_name(bus.stopId)}',
          };
    final delay = next < _stops.length ? delayAt(_stops[next]) : null;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            LineBadge(route),
            const SizedBox(width: 12),
            Expanded(child: Text(trip.terminus, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
      body: Stack(
        children: [
          LiveMap(
            controller: _map,
            shapes: [_shape],
            shapeColor: Color(route.color),
            highlightStops: _stops,
            routes: {route.id},
            follow: _following ? bus?.id : null,
            onFollowLost: () => setState(() => _following = false),
            initialCenter: bus != null
                ? LatLng(bus.lat, bus.lon)
                : (_stops.isEmpty ? troyes : LatLng(_stops.first.lat, _stops.first.lon)),
            initialZoom: 15,
            padding: EdgeInsets.only(bottom: height * 0.45),
          ),
          if (bus != null && !_following)
            Positioned(
              right: 16,
              top: 16,
              child: FloatingActionButton.small(
                tooltip: 'Suivre le bus',
                onPressed: () => setState(() => _following = true),
                child: const Icon(Icons.center_focus_strong),
              ),
            ),
          DraggableScrollableSheet(
            initialChildSize: 0.45,
            minChildSize: 0.2,
            maxChildSize: 0.9,
            builder: (context, sheet) => Material(
              color: cs.surfaceContainerLow,
              elevation: 3,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              clipBehavior: Clip.antiAlias,
              child: CustomScrollView(
                controller: sheet,
                slivers: [
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 12),
                            width: 32,
                            height: 4,
                            decoration: BoxDecoration(
                              color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        ListTile(
                          leading: Icon(bus == null ? Icons.schedule : Icons.directions_bus, color: Color(route.color)),
                          title: Text(status),
                          subtitle: Text(
                            [
                              if (bus != null) 'Bus ${bus.label.isEmpty ? bus.id : bus.label}',
                              if (bus != null && bus.speed > 0) '${(bus.speed * 3.6).round()} km/h',
                              ?delayText(delay),
                              if (update?.canceled ?? false) 'Course supprimée',
                              liveStatus(),
                            ].join(' · '),
                          ),
                        ),
                        AlertCards(routes: {route.id}),
                        const Divider(),
                      ],
                    ),
                  ),
                  SliverList.builder(
                    itemCount: _stops.length,
                    itemBuilder: (context, i) {
                      final s = _stops[i];
                      final d = update?.delayAt(s.seq, times);
                      final skipped = d == TripUpdate.gone && i >= next;
                      final live = d != null && d != TripUpdate.gone;
                      final at = times[s.seq]! + (live ? d : 0);
                      return _StopRow(
                        stop: s,
                        color: Color(route.color),
                        passed: i < next,
                        current: i == next,
                        first: i == 0,
                        last: i == _stops.length - 1,
                        time: skipped ? 'non desservi' : (i < next ? clock(at) : until(at)),
                        live: live && i >= next,
                        skipped: skipped,
                        onTap: () => openStop(context, s.station),
                      );
                    },
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _name(String stopId) => _stops.where((s) => s.stopId == stopId).firstOrNull?.name ?? stopId;
}

/// A stop on the trip's timeline: the line's colored track, a dot, the name and the time.
class _StopRow extends StatelessWidget {
  const _StopRow({
    required this.stop,
    required this.color,
    required this.passed,
    required this.current,
    required this.first,
    required this.last,
    required this.time,
    required this.live,
    required this.skipped,
    required this.onTap,
  });
  final TripStop stop;
  final Color color;
  final bool passed, current, first, last, live, skipped;
  final String time;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final track = passed ? color.withValues(alpha: 0.35) : color;
    final fg = passed ? cs.onSurfaceVariant : cs.onSurface;
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 64,
        child: Row(
          children: [
            const SizedBox(width: 24),
            SizedBox(
              width: 24,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Column(
                    children: [
                      Expanded(child: Container(width: 6, color: first ? Colors.transparent : track)),
                      Expanded(child: Container(width: 6, color: last ? Colors.transparent : track)),
                    ],
                  ),
                  Container(
                    width: current ? 20 : 14,
                    height: current ? 20 : 14,
                    decoration: BoxDecoration(
                      color: current ? color : cs.surface,
                      shape: BoxShape.circle,
                      border: Border.all(color: track, width: 3),
                    ),
                    child: current ? Icon(Icons.directions_bus, size: 11, color: cs.surface) : null,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                stop.name,
                style: TextStyle(
                  color: fg,
                  fontWeight: current ? FontWeight.w700 : FontWeight.normal,
                  decoration: skipped ? TextDecoration.lineThrough : null,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (live) const LiveIcon(),
            const SizedBox(width: 4),
            Text(
              time,
              style: TextStyle(color: fg, fontWeight: passed ? FontWeight.normal : FontWeight.w600),
            ),
            const SizedBox(width: 20),
          ],
        ),
      ),
    );
  }
}
