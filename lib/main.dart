import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:home_widget/home_widget.dart';

import 'lines.dart';
import 'map.dart';
import 'stops.dart';
import 'store.dart';
import 'theme.dart';
import 'widget.dart';
import 'widgets.dart';

final navigator = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await setupHomeWidget();
  await store.init();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) => DynamicColorBuilder(
    builder: (light, dark) => MaterialApp(
      title: 'Re-TCAT',
      navigatorKey: navigator,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(light ?? ColorScheme.fromSeed(seedColor: seed)),
      darkTheme: buildTheme(dark ?? ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark)),
      locale: const Locale('fr'),
      supportedLocales: const [Locale('fr')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: const Shell(),
    ),
  );
}

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;
  StreamSubscription<Uri?>? _clicks;

  @override
  void initState() {
    super.initState();
    // Tapping the home screen widget opens its stop.
    HomeWidget.initiallyLaunchedFromHomeWidget().then(_fromWidget);
    _clicks = HomeWidget.widgetClicked.listen(_fromWidget);
  }

  @override
  void dispose() {
    _clicks?.cancel();
    super.dispose();
  }

  void _fromWidget(Uri? uri) {
    final id = uri?.queryParameters['station'];
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = navigator.currentContext;
      if (c != null && store.gtfs?.stations[id] != null) openStop(c, id);
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      if (store.gtfs == null) return const _Loading();
      return Scaffold(
        appBar: _tab == 0
            ? null
            : AppBar(
                title: Text(_tab == 1 ? 'Arrêts' : 'Lignes'),
                actions: [IconButton(tooltip: 'À propos', onPressed: _about, icon: const Icon(Icons.info_outline))],
              ),
        // Not const: they read `store`, and Flutter skips rebuilding an identical const widget.
        body: switch (_tab) {
          0 => MapTab(),
          1 => StopsTab(),
          _ => Column(
            children: [
              for (final a in store.alerts) AlertCard(a),
              Expanded(child: LinesTab()),
            ],
          ),
        },
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: [
            const NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Carte'),
            const NavigationDestination(
              icon: Icon(Icons.signpost_outlined),
              selectedIcon: Icon(Icons.signpost),
              label: 'Arrêts',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: store.alerts.isNotEmpty,
                label: Text('${store.alerts.length}'),
                child: const Icon(Icons.route_outlined),
              ),
              selectedIcon: const Icon(Icons.route),
              label: 'Lignes',
            ),
          ],
        ),
      );
    },
  );

  void _about() {
    final g = store.gtfs!;
    String date(String ymd) =>
        ymd.length == 8 ? '${ymd.substring(6)}/${ymd.substring(4, 6)}/${ymd.substring(0, 4)}' : '?';
    showAboutDialog(
      context: context,
      applicationName: 'Re-TCAT',
      applicationLegalese: 'Application non officielle, sans lien avec TCAT ni Troyes Champagne Métropole.',
      children: [
        const SizedBox(height: 16),
        Text('Horaires valables du ${date(g.validFrom)} au ${date(g.validTo)}.'),
        const SizedBox(height: 8),
        const Text(
          'Données : TCAT / Troyes Champagne Métropole sur transport.data.gouv.fr (ODbL). '
          'Fond de carte : © les contributeurs d\'OpenStreetMap (ODbL).',
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () {
            Navigator.pop(context);
            store.checkTimetable(force: true);
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mise à jour des horaires…')));
          },
          icon: const Icon(Icons.refresh),
          label: const Text('Retélécharger les horaires'),
        ),
      ],
    );
  }
}

/// First launch: the timetable is downloading (or failed to).
class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (store.loadError == null) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text(store.loading ?? 'Préparation…'),
            ] else ...[
              const Icon(Icons.cloud_off, size: 48),
              const SizedBox(height: 16),
              const Text('Impossible de télécharger les horaires. Vérifiez la connexion.', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: () => store.checkTimetable(force: true), child: const Text('Réessayer')),
            ],
          ],
        ),
      ),
    ),
  );
}
