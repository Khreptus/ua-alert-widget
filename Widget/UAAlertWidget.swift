import AppIntents
import SwiftUI
import WidgetKit

// MARK: - City selection (widget configuration)

struct CityEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Місто"
    static var defaultQuery = CityQuery()

    var id: String
    var name: String
    var raion: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(raion)")
    }

    init(_ h: Hromada) { id = h.id; name = h.displayName; raion = h.raion }
}

struct CityQuery: EntityStringQuery {
    func entities(for identifiers: [CityEntity.ID]) async throws -> [CityEntity] {
        identifiers.compactMap { GeoStore.shared.hromada(id: $0).map(CityEntity.init) }
    }
    func entities(matching string: String) async throws -> [CityEntity] {
        GeoStore.shared.search(string, limit: 40).map(CityEntity.init)
    }
    func suggestedEntities() async throws -> [CityEntity] {
        GeoStore.shared.popular.map(CityEntity.init)
    }
}

struct SelectCityIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Моє місто"
    static var description = IntentDescription("Місто, для якого віджет показує статус тривоги.")

    @Parameter(title: "Місто")
    var city: CityEntity?

    @Parameter(title: "Повітряні цілі", default: true)
    var showTargets: Bool
}

// MARK: - Timeline

struct AlertEntry: TimelineEntry {
    let date: Date
    let model: WidgetModel
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AlertEntry {
        AlertEntry(date: Date(), model: WidgetModel(snapshot: .placeholder, city: GeoStore.shared.defaultCity))
    }

    func snapshot(for configuration: SelectCityIntent, in context: Context) async -> AlertEntry {
        if context.isPreview { return placeholder(in: context) }
        return await load(configuration)
    }

    func timeline(for configuration: SelectCityIntent, in context: Context) async -> Timeline<AlertEntry> {
        let e = await load(configuration)
        // macOS decides the real refresh rate; ask for every 5 minutes.
        return Timeline(entries: [e], policy: .after(Date().addingTimeInterval(300)))
    }

    private func load(_ c: SelectCityIntent) async -> AlertEntry {
        let snap = await Aggregator().fetch()
        let city = c.city.flatMap { GeoStore.shared.hromada(id: $0.id) } ?? GeoStore.shared.defaultCity
        return AlertEntry(date: Date(), model: WidgetModel(snapshot: snap, city: city, showTargets: c.showTargets))
    }
}

// MARK: - Widget

struct UAAlertWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: AlertEntry

    var size: WidgetSize {
        switch family {
        case .systemSmall: return .small
        case .systemMedium: return .medium
        default: return .large
        }
    }

    var body: some View {
        AlertWidgetView(model: entry.model, size: size, more: AnyView(Link(destination: URL(string: "uaalert://settings")!) { MoreDots() }))
            .containerBackground(for: .widget) { AlertWidgetBackground(alarm: entry.model.isAlarm && size != .large) }
            .widgetURL(URL(string: "uaalert://open"))
    }
}

struct UAAlertWidget: Widget {
    let kind = "UAAlertWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectCityIntent.self, provider: Provider()) { entry in
            UAAlertWidgetView(entry: entry)
        }
        .configurationDisplayName("Тривоги України")
        .description("Карта тривог по районах, повітряні цілі та статус вашого міста.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct UAAlertWidgetBundle: WidgetBundle {
    var body: some Widget { UAAlertWidget() }
}
