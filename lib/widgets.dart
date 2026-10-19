import 'package:flutter/material.dart';

import 'gtfs.dart';
import 'realtime.dart';
import 'store.dart';

/// A line's number in its TCAT colors.
class LineBadge extends StatelessWidget {
  const LineBadge(this.route, {super.key, this.size = 32});
  final Line route;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    constraints: BoxConstraints(minWidth: size * 1.3, minHeight: size),
    padding: EdgeInsets.symmetric(horizontal: size / 5),
    decoration: BoxDecoration(color: Color(route.color), borderRadius: BorderRadius.circular(size / 4)),
    // Factors of 1: as wide as the number, not as the parent (a Container with an alignment would fill it).
    child: Center(
      widthFactor: 1,
      heightFactor: 1,
      child: Text(
        route.short,
        style: TextStyle(color: Color(route.text), fontWeight: FontWeight.w800, fontSize: size * 0.45, height: 1),
      ),
    ),
  );
}

int nowSecs() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

String clock(int epoch) {
  final t = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// "à l'arrêt", "3 min", or the clock time after an hour.
String until(int epoch) {
  final s = epoch - nowSecs();
  if (s < 60) return 'à l\'arrêt';
  if (s < 3600) return '${s ~/ 60} min';
  return clock(epoch);
}

/// "+3 min", "-1 min", "à l'heure", or null without live data.
String? delayText(int? delay) {
  if (delay == null) return null;
  final m = (delay / 60).round();
  return m == 0 ? 'à l\'heure' : (m > 0 ? '+$m min' : '$m min');
}

Color delayColor(BuildContext context, int? delay) {
  final cs = Theme.of(context).colorScheme;
  if (delay == null) return cs.onSurfaceVariant;
  final m = (delay / 60).round();
  return m >= 3 ? cs.error : (m < 0 ? cs.tertiary : cs.primary);
}

/// The "live" mark next to a predicted time.
class LiveIcon extends StatelessWidget {
  const LiveIcon({super.key, this.size = 14});
  final double size;

  @override
  Widget build(BuildContext context) =>
      Icon(Icons.sensors, size: size, color: Theme.of(context).colorScheme.primary, semanticLabel: 'temps réel');
}

/// One bus leaving a stop.
class DepartureTile extends StatelessWidget {
  const DepartureTile(this.d, {super.key, this.onTap});
  final Departure d;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final late = delayText(d.delay);
    final hasBus = store.vehicleOnTrip(d.trip) != null;
    return ListTile(
      onTap: onTap,
      leading: LineBadge(d.route),
      title: Text(d.terminus, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text.rich(
        TextSpan(
          children: [
            if (hasBus) const WidgetSpan(child: Icon(Icons.directions_bus, size: 14)),
            if (hasBus) const TextSpan(text: ' '),
            TextSpan(text: d.realtime ? 'prévu ${clock(d.scheduled)}' : 'horaire théorique'),
            if (late != null)
              TextSpan(
                text: ' · $late',
                style: TextStyle(color: delayColor(context, d.delay)),
              ),
          ],
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (d.realtime) const LiveIcon(),
          const SizedBox(width: 4),
          Text(until(d.time), style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

/// Live-data status, for the bottom of the map and the stop pages.
String liveStatus() {
  if (store.liveTime == 0) return store.offline ? 'Temps réel indisponible' : 'Connexion au temps réel…';
  final age = store.liveAge;
  final when = age < 60 ? 'il y a $age s' : 'il y a ${age ~/ 60} min';
  return store.offline ? 'Hors ligne · màj $when' : 'Temps réel · $when';
}

/// Alerts about a stop or some lines, as cards.
class AlertCards extends StatelessWidget {
  const AlertCards({super.key, this.routes = const {}, this.station});
  final Set<String> routes;
  final String? station;

  @override
  Widget build(BuildContext context) {
    final stops = station == null ? <String>{} : store.gtfs!.stopIds(station!);
    final shown = store.alerts.where(
      (a) => a.routes.any(routes.contains) || a.stops.any(stops.contains) || (a.routes.isEmpty && a.stops.isEmpty),
    );
    return Column(children: [for (final a in shown) AlertCard(a)]);
  }
}

class AlertCard extends StatelessWidget {
  const AlertCard(this.a, {super.key});
  final Alert a;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card(
        color: cs.errorContainer,
        child: ListTile(
          leading: Icon(Icons.warning_amber, color: cs.onErrorContainer),
          title: Text(a.header.isEmpty ? 'Perturbation' : a.header, style: TextStyle(color: cs.onErrorContainer)),
          subtitle: a.description.isEmpty ? null : Text(a.description, style: TextStyle(color: cs.onErrorContainer)),
        ),
      ),
    );
  }
}

/// Lowercase without accents, for searching stop names.
String fold(String s) {
  const from = 'àâäéèêëîïôöùûüÿç', to = 'aaaeeeeiioouuuyc';
  final l = s.toLowerCase();
  final b = StringBuffer();
  for (final c in l.split('')) {
    final i = from.indexOf(c);
    b.write(i < 0 ? c : to[i]);
  }
  return b.toString();
}
