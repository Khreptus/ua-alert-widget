import SwiftUI
import AppKit
import CoreLocation

// MARK: - Geocoding (Apple, no key)

struct PlaceHit: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let subtitle: String
    let lat: Double
    let lon: Double
}

enum Places {
    static let uk = Locale(identifier: "uk_UA")

    /// Address / place search limited to Ukraine.
    static func search(_ q: String) async -> [PlaceHit] {
        let g = CLGeocoder()
        let marks = (try? await g.geocodeAddressString(q + ", Україна", in: nil, preferredLocale: uk)) ?? []
        return marks.compactMap { m in
            guard let c = m.location?.coordinate, m.isoCountryCode == nil || m.isoCountryCode == "UA" else { return nil }
            return PlaceHit(title: title(m), subtitle: [m.locality, m.administrativeArea].compactMap { $0 }.filter { $0 != title(m) }.joined(separator: " · "), lat: c.latitude, lon: c.longitude)
        }
    }

    /// Human name of a point (street + number, or village/city).
    static func name(lat: Double, lon: Double) async -> String? {
        let m = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon), preferredLocale: uk).first
        return m.map(title)
    }

    static func title(_ m: CLPlacemark) -> String {
        if let street = m.thoroughfare {
            let s = [street, m.subThoroughfare].compactMap { $0 }.joined(separator: ", ")
            return [m.locality, s].compactMap { $0 }.joined(separator: ", ")
        }
        return m.locality ?? m.name ?? "Обрана точка"
    }
}

// MARK: - My location

@MainActor
final class MyLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = MyLocation()
    private let mgr = CLLocationManager()
    private var done: ((CLLocation?, String?) -> Void)?

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func request(_ completion: @escaping (CLLocation?, String?) -> Void) {
        done = completion
        switch mgr.authorizationStatus {
        case .denied, .restricted:
            finish(nil, "Доступ до геолокації вимкнено: Системні параметри → Приватність і безпека → Служби геолокації → Тривога UA.")
        case .notDetermined:
            mgr.requestWhenInUseAuthorization()
            mgr.requestLocation()
        default:
            mgr.requestLocation()
        }
    }

    private func finish(_ l: CLLocation?, _ err: String?) {
        let d = done; done = nil
        d?(l, err)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let l = locations.last
        Task { @MainActor in self.finish(l, nil) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil, "Не вдалося визначити місце. Перевірте Wi‑Fi і дозвіл на геолокацію.") }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let st = manager.authorizationStatus
        Task { @MainActor in
            if st == .denied || st == .restricted, self.done != nil {
                self.finish(nil, "Доступ до геолокації вимкнено: Системні параметри → Приватність і безпека → Служби геолокації → Тривога UA.")
            }
        }
    }
}

// MARK: - Pick a point on the map

struct PointPickerView: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var model: AppModel
    var close: () -> Void

    @State private var point: (lat: Double, lon: Double)?
    @State private var name: String = ""
    @State private var outside = false

    var body: some View {
        let start = prefs.city
        let preview: Hromada? = point.flatMap { GeoStore.shared.locate(lat: $0.lat, lon: $0.lon, label: name) } ?? start
        VStack(spacing: 0) {
            UAMapView(snapshot: model.snapshot, city: preview, showTargets: false, showThreat: true, mode: .raions,
                      onPick: { lat, lon in pick(lat, lon) },
                      focus: start.map { ($0.lat, $0.lon, 60) })
                .background(Color(hex: 0x16171A))
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    if outside {
                        Text("Точка поза межами України").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.amber)
                    } else if let p = preview, point != nil {
                        Text(name.isEmpty ? "Визначаю адресу…" : name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text("\(p.raion) · \(p.oblast)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("Клікніть на карті, щоб поставити точку").font(.system(size: 13, weight: .semibold))
                        Text("Колесо миші — масштаб, перетягування — рух карти").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Скасувати", action: close).keyboardShortcut(.cancelAction)
                Button("Зберегти") {
                    if let p = point, prefs.pickPoint(lat: p.lat, lon: p.lon, label: name.isEmpty ? "Обрана точка" : name) {
                        model.cityChanged()
                        close()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(point == nil || outside)
            }
            .padding(12)
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private func pick(_ lat: Double, _ lon: Double) {
        outside = GeoStore.shared.raion(atLat: lat, lon: lon) == nil
        point = (lat, lon)
        name = ""
        Task {
            let n = await Places.name(lat: lat, lon: lon)
            if point?.lat == lat { name = n ?? "Обрана точка" }
        }
    }
}

@MainActor
enum PointPickerWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Моє місце на карті"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: PointPickerView(close: { window?.close() })
                .environmentObject(AppModel.shared).environmentObject(Prefs.shared))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
