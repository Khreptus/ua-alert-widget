import Foundation
import CoreGraphics
import SwiftUI

public struct Hromada: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var raion: String
    public var oblast: String
    public var lat: Double
    public var lon: Double
    /// Custom place name for a user-picked point (street, village); nil for the hromada itself.
    public var label: String? = nil

    public var id: String { "\(name)|\(raion)" }

    /// "Ірпінська міська громада" → "Ірпінська громада"; "Київ" stays.
    public var displayName: String { label ?? baseName }

    /// "Ірпінська міська громада" → "Ірпінська громада".
    public var baseName: String {
        var n = name
        for s in [" міська територіальна громада", " селищна територіальна громада", " сільська територіальна громада", " міська громада", " селищна громада", " сільська громада", " територіальна громада"] {
            if n.hasSuffix(s) { n = String(n.dropLast(s.count)) + " громада"; break }
        }
        return n
    }

    /// Compact name for tight UI: "Хмельницька міська громада" → "Хмельницька гр."
    public var shortName: String {
        let d = displayName
        return d.hasSuffix(" громада") ? String(d.dropLast(" громада".count)) + " гр." : d
    }

    /// Normalised key used to match ukrainealarm community names.
    public var key: String { Hromada.normalise(name) }

    /// Key used for city-level entries in dimap/radarua ("м. Київ").
    public var cityKey: String {
        if raion == "Київ" || name == "Київ" { return "м. Київ" }
        return "м. " + baseName.replacingOccurrences(of: " громада", with: "")
    }

    public var isKyiv: Bool { raion == "Київ" || name == "Київ" }

    public static func normalise(_ s: String) -> String {
        let first = s.lowercased().replacingOccurrences(of: "’", with: "'").split(separator: " ").first.map(String.init) ?? s.lowercased()
        return first
    }
}

public struct RaionShape: Sendable {
    public let name: String
    public let oblast: String
    public let path: Path
    /// Full-detail outline for close zoom.
    public let pathHi: Path
}

public struct CityShape: Sendable {
    public let name: String
    public let path: Path
    public let pathHi: Path
}

private struct GeoFile: Decodable {
    struct Proj: Decodable { let g: Double; let ox: Double; let oy: Double }
    struct R: Decodable { let name: String; let oblast: String; let rings: [[Double]]; let hi: [[Double]]? }
    struct O: Decodable { let name: String; let rings: [[Double]]; let hi: [[Double]]? }
    let width: Double
    let height: Double
    let proj: Proj
    let raions: [R]
    let oblasts: [O]
    let cities: [O]?
}

/// Map geometry (projected to a 680-wide canvas) + list of hromadas.
public final class GeoStore: @unchecked Sendable {
    public static let shared = GeoStore()

    public let width: CGFloat
    public let height: CGFloat
    public let raions: [RaionShape]
    public let oblastBorders: Path
    public let oblastBordersHi: Path
    public let cities: [CityShape]
    public let oblastShapes: [String: Path]
    public let hromadas: [Hromada]
    /// Web-Mercator: map unit = world-pixel(zoom 0, 256 px) × g − offset.
    private let proj: (g: Double, ox: Double, oy: Double)
    /// Map units per zoom-0 world pixel (used to pick raster tile zoom).
    public var unitsPerWorldPixel: Double { proj.g }
    private let keyCounts: [String: Int]
    private let byID: [String: Hromada]

    private init() {
        let bundle = Bundle.main
        var w: CGFloat = 680, h: CGFloat = 453
        var rs: [RaionShape] = []
        var borders = Path(), bordersHi = Path()
        var cs: [CityShape] = []
        var obl: [String: Path] = [:]
        var p = (g: 52.86014132521543, ox: 7598.214709740463, oy: 4446.620731212759)
        if let url = bundle.url(forResource: "geo", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let g = try? JSONDecoder().decode(GeoFile.self, from: data) {
            w = g.width; h = g.height
            p = (g.proj.g, g.proj.ox, g.proj.oy)
            rs = g.raions.map { RaionShape(name: $0.name, oblast: $0.oblast, path: GeoStore.path($0.rings), pathHi: GeoStore.path($0.hi ?? $0.rings)) }
            for o in g.oblasts {
                let path = GeoStore.path(o.rings)
                borders.addPath(path)
                bordersHi.addPath(GeoStore.path(o.hi ?? o.rings))
                obl[o.name] = path
            }
            cs = (g.cities ?? []).map { CityShape(name: $0.name, path: GeoStore.path($0.rings), pathHi: GeoStore.path($0.hi ?? $0.rings)) }
        }
        width = w; height = h; raions = rs; oblastBorders = borders; oblastBordersHi = bordersHi; cities = cs; oblastShapes = obl; proj = p

        var hs: [Hromada] = []
        if let url = bundle.url(forResource: "hromady", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([Hromada].self, from: data) {
            hs = list
        }
        hromadas = hs.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        var kc: [String: Int] = [:]
        for x in hs { kc[x.key, default: 0] += 1 }
        keyCounts = kc
        byID = Dictionary(hs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private static func path(_ rings: [[Double]]) -> Path {
        var path = Path()
        for r in rings where r.count >= 6 {
            path.move(to: CGPoint(x: r[0], y: r[1]))
            var i = 2
            while i + 1 < r.count { path.addLine(to: CGPoint(x: r[i], y: r[i + 1])); i += 2 }
            path.closeSubpath()
        }
        return path
    }

    public func project(lat: Double, lon: Double) -> CGPoint {
        let x = (lon + 180) / 360 * 256
        let r = max(-85, min(85, lat)) * .pi / 180
        let y = (1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * 256
        return CGPoint(x: x * proj.g - proj.ox, y: y * proj.g - proj.oy)
    }

    /// Map-space rectangle of a slippy-map tile.
    public func tileRect(z: Int, x: Int, y: Int) -> CGRect {
        let w = 256 / pow(2, Double(z))
        return CGRect(x: Double(x) * w * proj.g - proj.ox, y: Double(y) * w * proj.g - proj.oy, width: w * proj.g, height: w * proj.g)
    }

    /// Map-space point → zoom-0 world pixel.
    public func world(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x + proj.ox) / proj.g, y: (p.y + proj.oy) / proj.g)
    }

    public func isUniqueHromadaKey(_ key: String) -> Bool { (keyCounts[key] ?? 0) == 1 }

    public func hromada(id: String) -> Hromada? { byID[id] }

    public var defaultCity: Hromada? { hromadas.first { $0.isKyiv } }

    public var popular: [Hromada] {
        let names = ["Київ", "Харківська міська громада", "Одеська міська громада", "Дніпровська міська громада", "Львівська міська громада", "Запорізька міська громада", "Ірпінська міська громада", "Бучанська міська громада", "Вінницька міська громада", "Полтавська міська громада", "Чернігівська міська громада", "Сумська міська громада", "Миколаївська міська громада", "Житомирська міська громада", "Черкаська міська громада", "Кропивницька міська громада", "Хмельницька міська громада", "Рівненська міська громада", "Луцька міська громада", "Тернопільська міська громада", "Івано-Франківська міська громада", "Ужгородська міська громада", "Чернівецька міська громада", "Херсонська міська громада"]
        return names.compactMap { n in hromadas.first { $0.name == n } }
    }

    /// Inverse of `project`: map point → lat/lon.
    public func unproject(_ p: CGPoint) -> (lat: Double, lon: Double) {
        let w = world(p)
        let lon = Double(w.x) / 256 * 360 - 180
        let lat = atan(sinh(.pi * (1 - 2 * Double(w.y) / 256))) * 180 / .pi
        return (lat, lon)
    }

    /// Raion (name, oblast) containing the point, nil outside Ukraine. Kyiv/Sevastopol return the city.
    public func raion(atLat lat: Double, lon: Double) -> (name: String, oblast: String)? {
        let p = project(lat: lat, lon: lon)
        if let c = cities.first(where: { $0.pathHi.contains(p) }) {
            return c.name == "м. Київ" ? ("Київ", "Київ") : ("Севастополь", "Севастополь")
        }
        if let r = raions.first(where: { $0.path.boundingRect.contains(p) && $0.pathHi.contains(p) }) { return (r.name, r.oblast) }
        return nil
    }

    /// A user-picked point: the hromada it belongs to (nearest hromada of the containing raion),
    /// moved to the exact point and labelled with the place name.
    public func locate(lat: Double, lon: Double, label: String?) -> Hromada? {
        let r = raion(atLat: lat, lon: lon)
        let pool = r.map { rr in hromadas.filter { $0.raion == rr.name || ($0.isKyiv && rr.name == "Київ") } } ?? []
        let cands = pool.isEmpty ? hromadas : pool
        guard var h = cands.min(by: { Geo.distanceKm(lat1: $0.lat, lon1: $0.lon, lat2: lat, lon2: lon) < Geo.distanceKm(lat1: $1.lat, lon1: $1.lon, lat2: lat, lon2: lon) }) else { return nil }
        h.lat = lat; h.lon = lon
        h.label = (label?.isEmpty == false) ? label : h.baseName
        return h
    }

    public func search(_ q: String, limit: Int = 40) -> [Hromada] {
        let s = q.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return popular }
        var starts: [Hromada] = [], contains: [Hromada] = []
        for h in hromadas {
            let n = h.name.lowercased()
            if n.hasPrefix(s) { starts.append(h) }
            else if n.contains(s) || h.raion.lowercased().contains(s) { contains.append(h) }
            if starts.count >= limit { break }
        }
        return Array((starts + contains).prefix(limit))
    }
}

public enum Geo {
    public static func distanceKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180, dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Initial bearing from point 1 to point 2, degrees clockwise from north.
    public static func bearing(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let φ1 = lat1 * .pi / 180, φ2 = lat2 * .pi / 180, Δλ = (lon2 - lon1) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        let b = atan2(y, x) * 180 / .pi
        return (b + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Point at `km` along `bearing` (degrees) from `p`.
    public static func destination(_ p: Projection.LL, km: Double, bearing: Double) -> Projection.LL {
        let r = 6371.0, δ = km / r, θ = bearing * .pi / 180
        let φ1 = p.lat * .pi / 180, λ1 = p.lon * .pi / 180
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return Projection.LL(lat: φ2 * 180 / .pi, lon: λ2 * 180 / .pi)
    }

    public static func angleDiff(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }
}
