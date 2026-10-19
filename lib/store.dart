import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gtfs.dart';
import 'realtime.dart';
import 'widget.dart';

final store = Store();

/// App state: the timetable, the live feeds (polled while the app is in the foreground) and the user's choices.
class Store extends ChangeNotifier {
  Gtfs? gtfs;
  late String dbPath;
  late SharedPreferences _prefs;

  /// Shown instead of the app while the first timetable downloads, or when it failed.
  String? loading;
  Object? loadError;

  List<Vehicle> vehicles = [];
  Map<String, TripUpdate> live = {};
  List<Alert> alerts = [];

  /// Epoch seconds of the last good realtime fetch, and whether the last one failed.
  int liveTime = 0;
  bool offline = false;

  List<String> favorites = [];
  String? widgetStation;

  Timer? _timer;
  int _lastGtfsCheck = 0, _lastAlerts = 0;
  bool _busy = false;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    favorites = _prefs.getStringList('favorites') ?? [];
    widgetStation = _prefs.getString('widgetStation');
    dbPath = '${(await getApplicationSupportDirectory()).path}/gtfs.db';
    try {
      gtfs = Gtfs.open(dbPath);
    } catch (_) {
      gtfs = null; // a corrupt file: download it again
    }
    AppLifecycleListener(onResume: start, onPause: stop);
    start();
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => refresh());
    refresh();
    checkTimetable();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Fetches the live positions and predictions (and the alerts every 2 minutes).
  Future<void> refresh() async {
    if (_busy) return;
    _busy = true;
    try {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final (v, t) = await (fetchFeed(vehiclesUrl), fetchFeed(tripUpdatesUrl)).wait;
      vehicles = parseVehicles(v).where((v) => gtfs?.routes.containsKey(v.route) ?? true).toList();
      live = parseTripUpdates(t);
      if (now - _lastAlerts > 120) {
        alerts = parseAlerts(await fetchFeed(alertsUrl)).where((a) => a.activeAt(now)).toList();
        _lastAlerts = now;
      }
      liveTime = now;
      offline = false;
      if (gtfs != null && widgetStation != null) await updateHomeWidget(gtfs!, widgetStation!, live, dbPath);
    } catch (e) {
      debugPrint('realtime: $e');
      offline = true;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Downloads the timetable if there is none, or if TCAT published a new one (checked every 6 hours, as ha-tcat).
  Future<void> checkTimetable({bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (!force && gtfs != null && now - _lastGtfsCheck < 6 * 3600) return;
    _lastGtfsCheck = now;
    try {
      final source = await currentGtfsSource();
      if (!force && gtfs != null && gtfs!.source == source) return;
      if (gtfs == null) {
        loading = 'Téléchargement des horaires…';
        loadError = null;
        notifyListeners();
      }
      await downloadGtfs(dbPath, source);
      gtfs?.close();
      gtfs = Gtfs.open(dbPath);
      loading = null;
    } catch (e) {
      if (gtfs == null) loadError = e;
      loading = null;
    }
    notifyListeners();
  }

  bool isFavorite(String station) => favorites.contains(station);

  void toggleFavorite(String station) {
    isFavorite(station) ? favorites.remove(station) : favorites.add(station);
    _prefs.setStringList('favorites', favorites);
    notifyListeners();
  }

  Future<void> setWidgetStation(String? station) async {
    widgetStation = station;
    station == null ? await _prefs.remove('widgetStation') : await _prefs.setString('widgetStation', station);
    notifyListeners();
    if (gtfs != null) await updateHomeWidget(gtfs!, station, live, dbPath);
  }

  Vehicle? vehicleOnTrip(String trip) => vehicles.where((v) => v.trip == trip).firstOrNull;

  /// Seconds since the last live update.
  int get liveAge => DateTime.now().millisecondsSinceEpoch ~/ 1000 - liveTime;
}
