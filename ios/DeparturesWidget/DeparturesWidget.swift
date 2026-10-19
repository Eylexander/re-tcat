import SwiftUI
import WidgetKit

// Next buses at the stop chosen in the app. It only draws the `data` JSON that lib/widget.dart writes to the App
// Group (format documented there). The timeline has an entry at each departure, so buses drop off when they leave.
// ponytail: no live refresh while the app is closed (Android has a refresh button); the times are updated each time
// the app polls. Add an iOS 17 AppIntent with home_widget's HomeWidgetBackgroundWorker if that matters.

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

struct Entry: TimelineEntry {
  let date: Date
  let data: WidgetData?
}

struct Provider: TimelineProvider {
  private func load() -> WidgetData? {
    guard let json = UserDefaults(suiteName: appGroup)?.string(forKey: "data") else { return nil }
    return try? JSONDecoder().decode(WidgetData.self, from: Data(json.utf8))
  }

  private var sample: WidgetData {
    let now = Date().timeIntervalSince1970
    return WidgetData(
      stop: "GARE JARDINS", station: "", updated: now,
      deps: [
        Departure(l: "D5", c: "#00509D", t: "#FFFFFF", h: "CHANTEREIGNE", at: now + 180, rt: true),
        Departure(l: "D6", c: "#009036", t: "#FFFFFF", h: "PRES DE LYON", at: now + 600, rt: true),
        Departure(l: "N", c: "#CDDE8D", t: "#000000", h: "GARE JARDINS", at: now + 1500, rt: false),
      ])
  }

  func placeholder(in context: Context) -> Entry { Entry(date: Date(), data: sample) }

  func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
    completion(Entry(date: Date(), data: load() ?? (context.isPreview ? sample : nil)))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
    let data = load()
    let now = Date()
    var dates = [now]
    for d in data?.deps ?? [] {
      let left = Date(timeIntervalSince1970: d.at + 30)
      if left > now { dates.append(left) }
    }
    completion(Timeline(entries: dates.map { Entry(date: $0, data: data) }, policy: .atEnd))
  }
}

extension Color {
  init(hex: String) {
    let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x1F6FB2
    self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
  }
}

struct DeparturesView: View {
  let entry: Entry
  @Environment(\.widgetFamily) private var family

  private var rows: Int { family == .systemSmall ? 3 : family == .systemLarge ? 9 : 4 }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let data = entry.data {
        Text(data.stop).font(.headline).lineLimit(1)
        let deps = data.deps.filter { $0.at >= entry.date.timeIntervalSince1970 - 30 }.prefix(rows)
        if deps.isEmpty {
          Text("Pas de bus dans les prochaines heures").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(Array(deps.enumerated()), id: \.offset) { _, d in
          HStack(spacing: 8) {
            Text(d.l)
              .font(.caption.weight(.heavy))
              .foregroundColor(Color(hex: d.t))
              .frame(minWidth: 30)
              .padding(.vertical, 3)
              .padding(.horizontal, 3)
              .background(Color(hex: d.c), in: RoundedRectangle(cornerRadius: 5))
            if family != .systemSmall {
              Text(d.h).font(.subheadline).lineLimit(1)
            }
            Spacer(minLength: 2)
            if d.rt {
              Image(systemName: "dot.radiowaves.left.and.right").font(.caption2).foregroundColor(.accentColor)
                .accessibilityLabel("temps réel")
            }
            Text(Date(timeIntervalSince1970: d.at), style: .time).font(.subheadline.bold()).monospacedDigit()
          }
        }
        Spacer(minLength: 0)
      } else {
        Text("Re-TCAT").font(.headline)
        Text("Dans l'app, ouvrez un arrêt puis ⋮ → Afficher sur le widget").font(.caption).foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // `homeWidget` marks the URL for home_widget, which hands it to the app (lib/main.dart opens the stop).
    .widgetURL(URL(string: entry.data.map { "retcat://stop?station=\(Self.query($0.station))&homeWidget" } ?? "retcat://open?homeWidget"))
    .widgetBackground()
  }

  static func query(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
  }
}

extension View {
  @ViewBuilder func widgetBackground() -> some View {
    if #available(iOS 17.0, *) {
      containerBackground(.background, for: .widget)
    } else {
      padding().background(Color(.systemBackground))
    }
  }
}

@main
struct DeparturesWidget: Widget {
  var body: some WidgetConfiguration {
    // The kind must match `widgetName` in lib/widget.dart.
    StaticConfiguration(kind: "DeparturesWidget", provider: Provider()) { DeparturesView(entry: $0) }
      .configurationDisplayName("Prochains bus")
      .description("Les prochains bus à un arrêt, en temps réel")
      .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}
