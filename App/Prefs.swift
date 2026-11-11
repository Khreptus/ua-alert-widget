import Foundation
import SwiftUI

/// User settings for the app (desktop window + menu bar + siren).
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var cityID: String { didSet { d.set(cityID, forKey: "cityID") } }
    @Published var showTargets: Bool { didSet { d.set(showTargets, forKey: "showTargets") } }
    @Published var showThreat: Bool { didSet { d.set(showThreat, forKey: "showThreat") } }
    @Published var mapMode: MapMode { didSet { d.set(mapMode.rawValue, forKey: "mapMode") } }
    @Published var sirenOnAlert: Bool { didSet { d.set(sirenOnAlert, forKey: "sirenOnAlert") } }
    @Published var sirenOnHighThreat: Bool { didSet { d.set(sirenOnHighThreat, forKey: "sirenOnHighThreat") } }
    @Published var bannerOnThreat: Bool { didSet { d.set(bannerOnThreat, forKey: "bannerOnThreat") } }
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
            "sirenOnAlert": true, "sirenOnHighThreat": true, "bannerOnThreat": false, "chimeOnClear": true,
            "volume": 0.8, "sirenSeconds": 30.0,
            "showDesktopWidget": true, "widgetSize": WidgetSize.large.rawValue, "widgetScale": 1.0, "widgetOnTop": false, "compactMode": true,
        ])
        cityID = d.string(forKey: "cityID") ?? ""
        showTargets = d.bool(forKey: "showTargets")
        showThreat = d.bool(forKey: "showThreat")
        mapMode = MapMode(rawValue: d.string(forKey: "mapMode") ?? "") ?? .raions
        sirenOnAlert = d.bool(forKey: "sirenOnAlert")
        sirenOnHighThreat = d.bool(forKey: "sirenOnHighThreat")
        bannerOnThreat = d.bool(forKey: "bannerOnThreat")
        chimeOnClear = d.bool(forKey: "chimeOnClear")
        volume = d.double(forKey: "volume")
        sirenSeconds = d.double(forKey: "sirenSeconds")
        showDesktopWidget = d.bool(forKey: "showDesktopWidget")
        widgetSize = WidgetSize(rawValue: d.string(forKey: "widgetSize") ?? "") ?? .large
        widgetScale = d.double(forKey: "widgetScale")
        widgetOnTop = d.bool(forKey: "widgetOnTop")
        compactMode = d.bool(forKey: "compactMode")
    }

    var city: Hromada? { GeoStore.shared.hromada(id: cityID) ?? GeoStore.shared.defaultCity }
}
