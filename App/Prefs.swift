import Foundation
import SwiftUI

/// User settings for the app (desktop window + menu bar + siren).
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var cityID: String { didSet { d.set(cityID, forKey: "cityID") } }
    /// Exact point picked by the user (map / address / my location). nil → the hromada itself.
    @Published var customPoint: CustomPoint? { didSet { save(customPoint) } }

    struct CustomPoint: Codable, Equatable { var lat: Double; var lon: Double; var label: String }

    private func save(_ p: CustomPoint?) {
        if let p, let data = try? JSONEncoder().encode(p) { d.set(data, forKey: "customPoint") } else { d.removeObject(forKey: "customPoint") }
    }

    /// Picks a hromada from the list (drops any custom point).
    func pickHromada(_ id: String) { customPoint = nil; cityID = id }

    /// Sets an exact point; the hromada/raion are derived from it.
    @discardableResult
    func pickPoint(lat: Double, lon: Double, label: String) -> Bool {
        guard let h = GeoStore.shared.locate(lat: lat, lon: lon, label: label) else { return false }
        cityID = h.id
        customPoint = CustomPoint(lat: lat, lon: lon, label: label)
        return true
    }
    @Published var showTargets: Bool { didSet { d.set(showTargets, forKey: "showTargets") } }
    @Published var showThreat: Bool { didSet { d.set(showThreat, forKey: "showThreat") } }
    @Published var mapMode: MapMode { didSet { d.set(mapMode.rawValue, forKey: "mapMode") } }
    @Published var sirenOnAlert: Bool { didSet { d.set(sirenOnAlert, forKey: "sirenOnAlert") } }
    @Published var sirenOnHighThreat: Bool { didSet { d.set(sirenOnHighThreat, forKey: "sirenOnHighThreat") } }
    @Published var bannerOnThreat: Bool { didSet { d.set(bannerOnThreat, forKey: "bannerOnThreat") } }
    @Published var sirenOnThreat: Bool { didSet { d.set(sirenOnThreat, forKey: "sirenOnThreat") } }
    @Published var notifyRecon: Bool { didSet { d.set(notifyRecon, forKey: "notifyRecon") } }
    @Published var chimeOnClear: Bool { didSet { d.set(chimeOnClear, forKey: "chimeOnClear") } }
    @Published var volume: Double { didSet { d.set(volume, forKey: "volume") } }
    @Published var sirenSeconds: Double { didSet { d.set(sirenSeconds, forKey: "sirenSeconds") } }
    @Published var showDesktopWidget: Bool { didSet { d.set(showDesktopWidget, forKey: "showDesktopWidget") } }
    @Published var widgetSize: WidgetSize { didSet { d.set(widgetSize.rawValue, forKey: "widgetSize") } }
    @Published var widgetScale: Double { didSet { d.set(widgetScale, forKey: "widgetScale") } }
    @Published var widgetOnTop: Bool { didSet { d.set(widgetOnTop, forKey: "widgetOnTop") } }
    @Published var compactMode: Bool { didSet { d.set(compactMode, forKey: "compactMode") } }

    private init() {
        d.register(defaults: [
            "cityID": GeoStore.shared.defaultCity?.id ?? "",
            "showTargets": true, "showThreat": true, "mapMode": MapMode.raions.rawValue,
            "sirenOnAlert": true, "sirenOnHighThreat": true, "bannerOnThreat": true, "sirenOnThreat": false, "notifyRecon": true, "chimeOnClear": true,
            "volume": 0.8, "sirenSeconds": 30.0,
            "showDesktopWidget": true, "widgetSize": WidgetSize.large.rawValue, "widgetScale": 1.0, "widgetOnTop": false, "compactMode": true,
        ])
        cityID = d.string(forKey: "cityID") ?? ""
        customPoint = d.data(forKey: "customPoint").flatMap { try? JSONDecoder().decode(CustomPoint.self, from: $0) }
        showTargets = d.bool(forKey: "showTargets")
        showThreat = d.bool(forKey: "showThreat")
        mapMode = MapMode(rawValue: d.string(forKey: "mapMode") ?? "") ?? .raions
        sirenOnAlert = d.bool(forKey: "sirenOnAlert")
        sirenOnHighThreat = d.bool(forKey: "sirenOnHighThreat")
        bannerOnThreat = d.bool(forKey: "bannerOnThreat")
        sirenOnThreat = d.bool(forKey: "sirenOnThreat")
        notifyRecon = d.bool(forKey: "notifyRecon")
        chimeOnClear = d.bool(forKey: "chimeOnClear")
        volume = d.double(forKey: "volume")
        sirenSeconds = d.double(forKey: "sirenSeconds")
        showDesktopWidget = d.bool(forKey: "showDesktopWidget")
        widgetSize = WidgetSize(rawValue: d.string(forKey: "widgetSize") ?? "") ?? .large
        widgetScale = d.double(forKey: "widgetScale")
        widgetOnTop = d.bool(forKey: "widgetOnTop")
        compactMode = d.bool(forKey: "compactMode")
    }

    var city: Hromada? {
        if let p = customPoint, let h = GeoStore.shared.locate(lat: p.lat, lon: p.lon, label: p.label) { return h }
        return GeoStore.shared.hromada(id: cityID) ?? GeoStore.shared.defaultCity
    }
}
