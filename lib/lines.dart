import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'gtfs.dart';
import 'map.dart';
import 'stops.dart';
import 'store.dart';
import 'widgets.dart';

/// The "Lignes" tab: every line, with how many of its buses are running.
class LinesTab extends StatelessWidget {
  const LinesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final routes = store.gtfs!.routes.values.toList();
    final running = {for (final v in store.vehicles) v.route};
    final live = routes.where((r) => running.contains(r.id)).toList();
    final regular = routes.where((r) => !r.onDemand && !running.contains(r.id));
    final onDemand = routes.where((r) => r.onDemand && !running.contains(r.id));
    return SafeArea(
      child: ListView(
        children: [
          if (live.isNotEmpty) _header(context, 'En service'),
          for (final r in live) _LineTile(r),
          if (live.isNotEmpty) _header(context, 'Toutes les lignes'),
          for (final r in regular) _LineTile(r),
          if (onDemand.isNotEmpty) _header(context, 'Transport à la demande (sur réservation)'),
          for (final r in onDemand) _LineTile(r),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _LineTile extends StatelessWidget {
  const _LineTile(this.r);
  final Line r;

  @override
  Widget build(BuildContext context) {
    final n = store.vehicles.where((v) => v.route == r.id).length;
    return ListTile(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => LinePage(r.id))),
      leading: LineBadge(r),
      title: Text(r.long, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: n == 0
          ? null
          : Chip(
              avatar: const Icon(Icons.directions_bus, size: 16),
              label: Text('$n'),
              visualDensity: VisualDensity.compact,
            ),
    );
  }
}

/// A line: its route and live buses on the map, and its stops in each direction.
class LinePage extends StatefulWidget {
  const LinePage(this.route, {super.key});
  final String route;

  @override
  State<LinePage> createState() => _LinePageState();
}

class _LinePageState extends State<LinePage> {
  final _map = MapController();
  late final _shapes = store.gtfs!.lineShapes(widget.route);
  late final _directions = store.gtfs!.lineStops(widget.route);

  @override
  Widget build(BuildContext context) {
    final route = store.gtfs!.routes[widget.route]!;
    final points = [
      for (final s in _shapes)
        for (final (lat, lon) in s) LatLng(lat, lon),
    ];
    return DefaultTabController(
      length: _directions.length,
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Row(
            children: [
              LineBadge(route),
              const SizedBox(width: 12),
              Expanded(child: Text(route.long, overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
        body: ListenableBuilder(
          listenable: store,
          builder: (context, _) {
            // Stations where a bus of this line is (or is heading to), to mark them in the lists.
            final busAt = <String>{
              for (final v in store.vehicles)
                if (v.route == route.id) ?store.gtfs!.stationOf(v.stopId),
            };
            return Column(
              children: [
                SizedBox(
                  height: MediaQuery.sizeOf(context).height * 0.38,
                  child: LiveMap(
                    controller: _map,
                    shapes: _shapes,
                    shapeColor: Color(route.color),
                    routes: {route.id},
                    highlightStops: [for (final d in _directions) ...d.stops],
                    initialCenter: points.isEmpty ? troyes : LatLngBounds.fromPoints(points).center,
                    initialZoom: 12.5,
                  ),
                ),
                AlertCards(routes: {route.id}),
                if (_directions.length > 1)
                  TabBar(isScrollable: true, tabs: [for (final d in _directions) Tab(text: '→ ${d.terminus}')]),
                Expanded(
                  child: TabBarView(
                    children: [
                      for (final d in _directions)
                        ListView(
                          children: [
                            for (final s in d.stops)
                              ListTile(
                                onTap: () => openStop(context, s.station),
                                leading: Icon(
                                  busAt.contains(s.station) ? Icons.directions_bus : Icons.circle_outlined,
                                  color: Color(route.color),
                                  size: busAt.contains(s.station) ? 24 : 14,
                                ),
                                title: Text(s.name),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
