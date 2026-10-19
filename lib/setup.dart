import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';

import 'gtfs.dart';
import 'store.dart';
import 'widget.dart';
import 'widgets.dart';

/// Android's widget setup (WidgetConfigActivity), shown when a widget is added, reconfigured, or tapped before it has
/// a stop: the stop, and optionally one line and one direction; two of them for NextBus2Widget. Saved in the widget's
/// `config_<id>` (lib/widget.dart).
class WidgetSetup extends StatefulWidget {
  const WidgetSetup(this.id, {super.key});
  final int id;

  @override
  State<WidgetSetup> createState() => _WidgetSetupState();
}

class _WidgetSetupState extends State<WidgetSetup> {
  /// Station, route and direction of each stop of the widget, empty for "all".
  List<List<String>>? _picks;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final w = (await HomeWidget.getInstalledWidgets()).where((w) => w.androidWidgetId == widget.id).firstOrNull;
    final count = (w?.androidClassName ?? '').endsWith('NextBus2Widget') ? 2 : 1;
    final saved = await HomeWidget.getWidgetData<String>('config_${widget.id}');
    final old = saved == null ? <String>[] : (jsonDecode(saved) as List).cast<String>();
    setState(
      () => _picks = [
        for (var i = 0; i < count; i++) i < old.length ? old[i].split('|') : ['', '', ''],
      ],
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await HomeWidget.saveWidgetData(
      'config_${widget.id}',
      jsonEncode([for (final p in _picks!) pickKey(p[0], p[1], p[2])]),
    );
    await updateHomeWidget(store.gtfs!, store.live, store.dbPath, favorites: store.favorites);
    await HomeWidget.finishHomeWidgetConfigure(); // closes this screen
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final gtfs = store.gtfs, picks = _picks;
      if (gtfs == null || picks == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
      final ready = picks.every((p) => gtfs.stations.containsKey(p[0]));
      return Scaffold(
        appBar: AppBar(title: Text(picks.length > 1 ? 'Widget à 2 arrêts' : 'Widget Re-TCAT')),
        body: ListView(
          children: [
            for (final (i, p) in picks.indexed) ...[
              if (picks.length > 1)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Text('Arrêt ${i + 1}', style: Theme.of(context).textTheme.titleSmall),
                ),
              ..._editor(gtfs, p),
            ],
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(onPressed: ready && !_saving ? _save : null, child: const Text('Valider')),
          ),
        ),
      );
    },
  );

  /// One stop of the widget: [p] is changed in place.
  List<Widget> _editor(Gtfs gtfs, List<String> p) {
    final station = gtfs.stations[p[0]];
    final lines = station == null ? null : groupDirections(gtfs.stationDirections(station.id))[station.id];
    final dirs = lines?[p[1]];
    return [
      ListTile(
        leading: const Icon(Icons.signpost_outlined),
        title: Text(station?.name ?? 'Choisir l\'arrêt'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          final id = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const StationSearch()));
          if (id != null) setState(() => p.setAll(0, [id, '', '']));
        },
      ),
      if (lines != null)
        _choices('Ligne', [
          ('Toutes', null, p[1] == '', () => p.setAll(1, ['', ''])),
          for (final r in gtfs.routes.values)
            if (lines.containsKey(r.id)) (r.short, Color(r.color), p[1] == r.id, () => p.setAll(1, [r.id, ''])),
        ]),
      if (dirs != null && dirs.length > 1)
        _choices('Sens', [
          ('Les deux', null, p[2] == '', () => p[2] = ''),
          for (final MapEntry(key: dir, value: termini) in dirs.entries)
            (directionLabel(termini), null, p[2] == dir, () => p[2] = dir),
        ]),
    ];
  }

  Widget _choices(String title, List<(String, Color?, bool, VoidCallback)> options) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(title, style: Theme.of(context).textTheme.labelLarge),
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (label, color, selected, onTap) in options)
              ChoiceChip(
                label: Text(label),
                avatar: color == null ? null : CircleAvatar(backgroundColor: color, radius: 6),
                showCheckmark: false,
                selected: selected,
                onSelected: (_) => setState(onTap),
              ),
          ],
        ),
      ],
    ),
  );
}

/// Picks a station: favorites first, then by name; returns its id.
class StationSearch extends StatefulWidget {
  const StationSearch({super.key});

  @override
  State<StationSearch> createState() => _StationSearchState();
}

class _StationSearchState extends State<StationSearch> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final gtfs = store.gtfs!;
    final q = fold(_q.trim());
    final all = gtfs.stations.values;
    final shown = q.isEmpty
        ? [...store.favorites.map((id) => gtfs.stations[id]).nonNulls, ...all.where((s) => !store.isFavorite(s.id))]
        : all.where((s) => fold(s.name).contains(q)).toList();
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Rechercher un arrêt', border: InputBorder.none),
          onChanged: (v) => setState(() => _q = v),
        ),
      ),
      body: ListView.builder(
        itemCount: shown.length,
        itemBuilder: (context, i) {
          final s = shown[i];
          return ListTile(
            leading: Icon(store.isFavorite(s.id) ? Icons.star : Icons.signpost_outlined),
            title: Text(s.name),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [for (final r in gtfs.stationRoutes(s.id)) LineBadge(r, size: 20)],
              ),
            ),
            onTap: () => Navigator.of(context).pop(s.id),
          );
        },
      ),
    );
  }
}
