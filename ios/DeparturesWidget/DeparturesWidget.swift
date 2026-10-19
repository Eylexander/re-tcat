import AppIntents
import SwiftUI
import WidgetKit

// The next buses at a stop, or the next bus at one or two stops. Each widget's stops are in its settings (long press →
// Modifier le widget, iOS 17), picked from the `picks` list the app writes to the App Group; the widget only draws the
// `dep_<pick>` JSON the app writes for them (lib/widget.dart documents both). The app can't read the settings, so the
// widget notes its picks in `seen`, and the app writes their data at its next poll. The timeline has an entry at each
// departure, so buses drop off when they leave.
// ponytail: no live refresh while the app is closed (Android has a refresh button); the times are updated each time
// the app polls. Add an AppIntent with home_widget's HomeWidgetBackgroundWorker if that matters.

/// The App Group from this extension's provisioning profile: re-signing tools (xtool, AltStore, SideStore) rename it.
/// Same lookup as `iosAppGroup` in lib/widget.dart.
private let appGroup: String = {
  let fallback = "group.com.eylexander.retcat"
  guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
    let raw = try? Data(contentsOf: url),
    let start = raw.range(of: Data("<?xml".utf8)),
    let end = raw.range(of: Data("</plist>".utf8), in: start.lowerBound..<raw.endIndex),
    let plist = try? PropertyListSerialization.propertyList(
      from: raw.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
    let entitlements = plist["Entitlements"] as? [String: Any],
    let group = (entitlements["com.apple.security.application-groups"] as? [String])?.first
  else { return fallback }
  return group
}()

private var shared: UserDefaults? { UserDefaults(suiteName: appGroup) }

private let choose = "Appui long → Modifier le widget pour choisir l'arrêt"
private let loading = "Ouvrez Re-TCAT pour charger les horaires"

struct Departure: Decodable {
  let l: String  // line
  let c: String  // badge color
  let t: String  // badge text color
  let h: String  // terminus
  let at: Double  // epoch seconds
  let rt: Bool  // live prediction
}

struct WidgetData: Decodable {
  let stop: String
  let station: String
  let updated: Double
  let deps: [Departure]
}

// MARK: Settings

/// A pick: a stop, and maybe one line and one direction (`station|route|dir`), with its label.
struct PickEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation = "Arrêt"
  static var defaultQuery = PickQuery()
  let id: String
  let name: String
  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

/// Every pick, from the app's `picks` (favorite stops first): empty until the app has run once.
struct PickQuery: EntityStringQuery {
  private func catalog() -> [PickEntity] {
    guard let json = shared?.string(forKey: "picks"),
      let rows = try? JSONDecoder().decode([[String]].self, from: Data(json.utf8))
    else { return [] }
    return rows.compactMap { $0.count == 2 ? PickEntity(id: $0[0], name: $0[1]) : nil }
  }

  func entities(for identifiers: [String]) async throws -> [PickEntity] {
    let all = catalog()
    return identifiers.compactMap { id in all.first { $0.id == id } }
  }

  func entities(matching string: String) async throws -> [PickEntity] {
    catalog().filter { $0.name.localizedStandardContains(string) }
  }

  func suggestedEntities() async throws -> [PickEntity] { catalog() }
}

/// The widget's picks, in order.
protocol PicksIntent {
  var picks: [String] { get }
}

// Conforming to WidgetConfigurationIntent directly: Xcode extracts the intents' metadata from the declarations.
struct StopIntent: WidgetConfigurationIntent, PicksIntent {
  static var title: LocalizedStringResource = "Arrêt"
  static var description = IntentDescription("L'arrêt, et au besoin la ligne et le sens.")
  @Parameter(title: "Arrêt") var stop: PickEntity?
  var picks: [String] { [stop?.id].compactMap { $0 } }
}

struct TwoStopsIntent: WidgetConfigurationIntent, PicksIntent {
  static var title: LocalizedStringResource = "Arrêts"
  static var description = IntentDescription("Les deux arrêts, et au besoin la ligne et le sens de chacun.")
  @Parameter(title: "Arrêt 1") var stop: PickEntity?
  @Parameter(title: "Arrêt 2") var stop2: PickEntity?
  var picks: [String] { [stop?.id, stop2?.id].compactMap { $0 } }
}

// MARK: Timeline

struct Entry: TimelineEntry {
  let date: Date
  let picks: [String]  // empty before the widget's setup
  let stops: [WidgetData?]  // each pick's data, nil until the app has written it
}

private let sample: WidgetData = {
  let now = Date().timeIntervalSince1970
  return WidgetData(
    stop: "GARE JARDINS", station: "", updated: now,
    deps: [
      Departure(l: "D5", c: "#00509D", t: "#FFFFFF", h: "CHANTEREIGNE", at: now + 180, rt: true),
      Departure(l: "D6", c: "#009036", t: "#FFFFFF", h: "PRES DE LYON", at: now + 600, rt: true),
      Departure(l: "N", c: "#CDDE8D", t: "#000000", h: "GARE JARDINS", at: now + 1500, rt: false),
    ])
}()

struct Provider<I: WidgetConfigurationIntent & PicksIntent>: AppIntentTimelineProvider {
  typealias Intent = I

  private func load(_ pick: String) -> WidgetData? {
    guard let json = shared?.string(forKey: "dep_\(pick)") else { return nil }
    return try? JSONDecoder().decode(WidgetData.self, from: Data(json.utf8))
  }

  private func entry(_ picks: [String], at date: Date) -> Entry {
    Entry(date: date, picks: picks, stops: picks.map(load))
  }

  /// Notes the picks, and when, so the app writes their data (it forgets those not seen for two days).
  private func note(_ picks: [String]) {
    guard let defaults = shared else { return }
    let old = defaults.string(forKey: "seen").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
    var seen = old as? [String: Double] ?? [:]
    for p in picks { seen[p] = Date().timeIntervalSince1970 }
    if let json = try? JSONSerialization.data(withJSONObject: seen) {
      defaults.set(String(decoding: json, as: UTF8.self), forKey: "seen")
    }
  }

  func placeholder(in context: Context) -> Entry {
    Entry(date: Date(), picks: ["", ""], stops: [sample, sample])
  }

  func snapshot(for configuration: I, in context: Context) async -> Entry {
    configuration.picks.isEmpty && context.isPreview
      ? placeholder(in: context) : entry(configuration.picks, at: Date())
  }

  func timeline(for configuration: I, in context: Context) async -> Timeline<Entry> {
    note(configuration.picks)
    let now = Date()
    let first = entry(configuration.picks, at: now)
    var dates: Set<Date> = [now]
    for d in first.stops.compactMap({ $0 }).flatMap(\.deps) {
      let left = Date(timeIntervalSince1970: d.at + 30)
      if left > now { dates.insert(left) }
    }
    return Timeline(
      entries: dates.sorted().map { Entry(date: $0, picks: first.picks, stops: first.stops) }, policy: .atEnd)
  }
}

// MARK: Views

extension Color {
  init(hex: String) {
    let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x1F6FB2
    self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
  }
}

/// Opens the app at the stop (home_widget hands URLs marked `homeWidget` to the app, lib/main.dart opens the stop).
private func stopURL(_ data: WidgetData?) -> URL? {
  guard let station = data?.station else { return URL(string: "retcat://open?homeWidget") }
  let query = station.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? station
  return URL(string: "retcat://stop?station=\(query)&homeWidget")
}

private func upcoming(_ data: WidgetData, at date: Date) -> [Departure] {
  data.deps.filter { $0.at >= date.timeIntervalSince1970 - 30 }
}

struct LineBadge: View {
  let d: Departure

  var body: some View {
    Text(d.l)
      .font(.caption.weight(.heavy))
      .foregroundColor(Color(hex: d.t))
      .frame(minWidth: 30)
      .padding(.vertical, 3)
      .padding(.horizontal, 3)
      .background(Color(hex: d.c), in: RoundedRectangle(cornerRadius: 5))
  }
}

struct LiveMark: View {
  var body: some View {
    Image(systemName: "dot.radiowaves.left.and.right").font(.caption2).foregroundColor(.accentColor)
      .accessibilityLabel("temps réel")
  }
}

/// The next buses at the widget's stop.
struct DeparturesView: View {
  let entry: Entry
  @Environment(\.widgetFamily) private var family

  private var rows: Int { family == .systemSmall ? 3 : family == .systemLarge ? 9 : 4 }

  var body: some View {
    let data = entry.stops.first.flatMap { $0 }
    VStack(alignment: .leading, spacing: 6) {
      if let data {
        Text(data.stop).font(.headline).lineLimit(1)
        let deps = upcoming(data, at: entry.date).prefix(rows)
        if deps.isEmpty {
          Text("Pas de bus dans les prochaines heures").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(Array(deps.enumerated()), id: \.offset) { _, d in
          HStack(spacing: 8) {
            LineBadge(d: d)
            if family != .systemSmall {
              Text(d.h).font(.subheadline).lineLimit(1)
            }
            Spacer(minLength: 2)
            if d.rt { LiveMark() }
            Text(Date(timeIntervalSince1970: d.at), style: .time).font(.subheadline.bold()).monospacedDigit()
          }
        }
      } else {
        Text("Re-TCAT").font(.headline)
        Text(entry.picks.isEmpty ? choose : loading).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .widgetURL(stopURL(data))
    .containerBackground(.background, for: .widget)
  }
}

/// The next bus at each of the widget's stops. Small widgets have a single tap target: the first stop.
struct NextBusView: View {
  let entry: Entry

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if entry.picks.isEmpty {
        Text("Re-TCAT").font(.headline)
        Text(choose).font(.caption2).foregroundStyle(.secondary)
      }
      ForEach(Array(entry.stops.enumerated()), id: \.offset) { _, data in
        VStack(alignment: .leading, spacing: 3) {
          Text(data?.stop ?? "Re-TCAT").font(.caption.bold()).foregroundStyle(.secondary).lineLimit(1)
          if let data, let d = upcoming(data, at: entry.date).first {
            HStack(spacing: 6) {
              LineBadge(d: d)
              Spacer(minLength: 2)
              if d.rt { LiveMark() }
              Text(Date(timeIntervalSince1970: d.at), style: .time).font(.headline).monospacedDigit()
            }
            Text(d.h).font(.caption).lineLimit(1)
          } else {
            Text(data == nil ? loading : "Pas de bus dans les prochaines heures").font(.caption)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .widgetURL(stopURL(entry.stops.first.flatMap { $0 }))
    .containerBackground(.background, for: .widget)
  }
}

// MARK: Widgets

@main
struct Widgets: WidgetBundle {
  var body: some Widget {
    DeparturesWidget()
    NextBusWidget()
    NextBus2Widget()
  }
}

// The kinds must match `widgetNames` in lib/widget.dart.
struct DeparturesWidget: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(kind: "DeparturesWidget", intent: StopIntent.self, provider: Provider<StopIntent>()) {
      DeparturesView(entry: $0)
    }
    .configurationDisplayName("Prochains bus")
    .description("Les prochains bus à un arrêt, en temps réel")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}

struct NextBusWidget: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(kind: "NextBusWidget", intent: StopIntent.self, provider: Provider<StopIntent>()) {
      NextBusView(entry: $0)
    }
    .configurationDisplayName("Prochain bus")
    .description("Le prochain bus à un arrêt")
    .supportedFamilies([.systemSmall])
  }
}

struct NextBus2Widget: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(kind: "NextBus2Widget", intent: TwoStopsIntent.self, provider: Provider<TwoStopsIntent>()) {
      NextBusView(entry: $0)
    }
    .configurationDisplayName("Prochain bus · 2 arrêts")
    .description("Le prochain bus à deux arrêts")
    .supportedFamilies([.systemSmall])
  }
}
