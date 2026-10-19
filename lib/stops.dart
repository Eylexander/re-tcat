import 'dart:io';

import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';
import 'package:latlong2/latlong.dart';

import 'gtfs.dart';
import 'map.dart';
import 'store.dart';
import 'widget.dart';
import 'widgets.dart';

void openStop(BuildContext context, String station) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => StopPage(station)));

void openDeparture(BuildContext context, Departure d) {
  final bus = store.vehicleOnTrip(d.trip);
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => FollowPage(trip: d.trip, vehicle: bus?.id),
    ),
  );
}

/// The "Arrêts" tab: favorite stops with their next buses, the nearest stops, and a search.
class StopsTab extends StatefulWidget {
  const StopsTab({super.key});

  @override
  State<StopsTab> createState() => _StopsTabState();
}

class _StopsTabState extends State<StopsTab> {
  final _search = TextEditingController();
  LatLng? _me;
  bool _locating = false;

  @override
  Widget build(BuildContext context) {
    final gtfs = store.gtfs!;
    final q = fold(_search.text.trim());
    final t = Theme.of(context).textTheme;
    const distance = Distance();

    return SafeArea(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: SearchBar(
                controller: _search,
                hintText: 'Rechercher un arrêt',
                leading: const Icon(Icons.search),
                trailing: [
                  if (q.isNotEmpty)
                    IconButton(
                      tooltip: 'Effacer',
                      onPressed: () => setState(_search.clear),
                      icon: const Icon(Icons.close),
                    ),
                ],
                onChanged: (_) => setState(() {}),
                elevation: const WidgetStatePropertyAll(0),
              ),
            ),
          ),
          if (q.isNotEmpty)
            SliverList.list(
              children: [
                for (final s in gtfs.stations.values.where((s) => fold(s.name).contains(q)).take(50))
                  _StationTile(s, me: _me),
              ],
            )
          else ...[
            if (store.favorites.isNotEmpty) _header(context, 'Favoris'),
            SliverList.list(
              children: [
                for (final id in store.favorites)
                  if (gtfs.stations[id] case final s?) _FavoriteCard(s),
              ],
            ),
            _header(context, 'À proximité'),
            if (_me == null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: OutlinedButton.icon(
                    onPressed: _locating
                        ? null
                        : () async {
                            setState(() => _locating = true);
                            final p = await locate(context);
                            if (mounted) {
                              setState(() {
                                _me = p;
                                _locating = false;
                              });
                            }
                          },
                    icon: _locating
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.near_me),
                    label: const Text('Arrêts autour de moi'),
                  ),
                ),
              )
            else
              SliverList.list(
                children: [
                  for (final s
                      in (gtfs.stations.values.toList()..sort(
                            (a, b) =>
                                distance(_me!, LatLng(a.lat, a.lon)).compareTo(distance(_me!, LatLng(b.lat, b.lon))),
                          ))
                          .take(10))
                    _StationTile(s, me: _me),
                ],
              ),
            if (store.favorites.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Ajoutez vos arrêts en favori (☆) pour voir leurs prochains bus ici, et en afficher un sur l\'écran '
                    'd\'accueil avec le widget.',
                    style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, String text) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    ),
  );
}

class _StationTile extends StatelessWidget {
  const _StationTile(this.s, {this.me});
  final Station s;
  final LatLng? me;

  @override
  Widget build(BuildContext context) {
    final routes = store.gtfs!.stationRoutes(s.id);
    final m = me == null ? null : const Distance()(me!, LatLng(s.lat, s.lon)).round();
    return ListTile(
      onTap: () => openStop(context, s.id),
      leading: Icon(store.isFavorite(s.id) ? Icons.star : Icons.signpost_outlined),
      title: Text(s.name),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(spacing: 4, runSpacing: 4, children: [for (final r in routes) LineBadge(r, size: 20)]),
      ),
      trailing: m == null ? null : Text(m < 1000 ? '$m m' : '${(m / 1000).toStringAsFixed(1)} km'),
    );
  }
}

/// A favorite stop and its next three buses.
class _FavoriteCard extends StatelessWidget {
  const _FavoriteCard(this.s);
  final Station s;

  @override
  Widget build(BuildContext context) {
    final deps = store.gtfs!.departures(s.id, DateTime.now(), store.live, count: 3);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              onTap: () => openStop(context, s.id),
              title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              trailing: store.widgetStation == s.id ? const Icon(Icons.widgets_outlined, size: 18) : null,
            ),
            if (deps.isEmpty)
              const Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 16), child: Text('Pas de bus dans les 4 heures'))
            else
              for (final d in deps) DepartureTile(d, onTap: () => openDeparture(context, d)),
          ],
        ),
      ),
    );
  }
}

/// A stop (both sides of the street): its next buses, live when the bus is followed.
class StopPage extends StatefulWidget {
  const StopPage(this.station, {super.key});
  final String station;

  @override
  State<StopPage> createState() => _StopPageState();
}

class _StopPageState extends State<StopPage> {
  final _lines = <String>{};

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final gtfs = store.gtfs!;
      final s = gtfs.stations[widget.station];
      if (s == null) {
        return Scaffold(
          appBar: AppBar(),
          body: const Center(child: Text('Arrêt inconnu')),
        );
      }
      final routes = gtfs.stationRoutes(s.id);
      final deps = gtfs.departures(s.id, DateTime.now(), store.live, onlyRoutes: _lines.isEmpty ? null : _lines);
      final fav = store.isFavorite(s.id);
      return Scaffold(
        appBar: AppBar(
          title: Text(s.name),
          actions: [
            IconButton(
              tooltip: fav ? 'Retirer des favoris' : 'Ajouter aux favoris',
              onPressed: () => store.toggleFavorite(s.id),
              icon: Icon(fav ? Icons.star : Icons.star_border),
            ),
            PopupMenuButton(
              itemBuilder: (_) => [
                PopupMenuItem(
                  onTap: () => _pinWidget(context, s),
                  child: ListTile(
                    leading: const Icon(Icons.widgets_outlined),
                    title: Text(store.widgetStation == s.id ? 'Retirer du widget' : 'Afficher sur le widget'),
                  ),
                ),
              ],
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: store.refresh,
          child: ListView(
            children: [
              if (routes.length > 1)
                SizedBox(
                  height: 52,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    children: [
                      for (final r in routes)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: FilterChip(
                            label: Text(r.short),
                            showCheckmark: false,
                            avatar: CircleAvatar(backgroundColor: Color(r.color), radius: 6),
                            selected: _lines.contains(r.id),
                            onSelected: (on) => setState(() => on ? _lines.add(r.id) : _lines.remove(r.id)),
                          ),
                        ),
                    ],
                  ),
                ),
              AlertCards(routes: {for (final r in routes) r.id}, station: s.id),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Text(
                  liveStatus(),
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
                ),
              ),
              if (deps.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('Aucun bus dans les 4 prochaines heures', textAlign: TextAlign.center),
                ),
              for (final d in deps) DepartureTile(d, onTap: () => openDeparture(context, d)),
              const SizedBox(height: 24),
            ],
          ),
        ),
      );
    },
  );

  Future<void> _pinWidget(BuildContext context, Station s) async {
    final remove = store.widgetStation == s.id;
    await store.setWidgetStation(remove ? null : s.id);
    if (remove || !context.mounted) return;
    // Android launchers can add the widget from here, if it isn't on the home screen yet; elsewhere, say how.
    if (Platform.isAndroid &&
        (await HomeWidget.getInstalledWidgets()).isEmpty &&
        (await HomeWidget.isRequestPinWidgetSupported() ?? false)) {
      await HomeWidget.requestPinWidget(qualifiedAndroidName: androidWidget);
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            Platform.isIOS
                ? '${s.name} s\'affichera dans le widget Re-TCAT : appui long sur l\'écran d\'accueil → +'
                : '${s.name} s\'affichera dans le widget Re-TCAT',
          ),
        ),
      );
    }
  }
}
