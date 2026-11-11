import Foundation
import CoreGraphics
import SwiftUI

public struct Hromada: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var raion: String
    public var oblast: String
    public var lat: Double
    public var lon: Double

    public var id: String { "\(name)|\(raion)" }

    /// "Ірпінська міська громада" → "Ірпінська громада"; "Київ" stays.
    public var displayName: String {
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
        return "м. " + displayName.replacingOccurrences(of: " громада", with: "")
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
}

private struct GeoFile: Decodable {
    struct Proj: Decodable { let k: Double; let minx: Double; let miny: Double; let scale: Double }
    struct R: Decodable { let name: String; let oblast: String; let rings: [[Double]] }
    struct O: Decodable { let name: String; let rings: [[Double]] }
    let width: Double
    let height: Double
    let proj: Proj
    let raions: [R]
    let oblasts: [O]
}

/// Map geometry (projected to a 680-wide canvas) + list of hromadas.
public final class GeoStore: @unchecked Sendable {
    public static let shared = GeoStore()

    public let width: CGFloat
    public let height: CGFloat
    public let raions: [RaionShape]
    public let oblastBorders: Path
    public let oblastShapes: [String: Path]
    public let hromadas: [Hromada]
    private let proj: (k: Double, minx: Double, miny: Double, s: Double)
    private let keyCounts: [String: Int]
    private let byID: [String: Hromada]

    private init() {
        let bundle = Bundle.main
        var w: CGFloat = 680, h: CGFloat = 453
        var rs: [RaionShape] = []
        var borders = Path()
        var obl: [String: Path] = [:]
        var p = (k: 0.66262, minx: 14.6684, miny: -52.3795, s: 56.7285)
        if let url = bundle.url(forResource: "geo", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let g = try? JSONDecoder().decode(GeoFile.self, from: data) {
            w = g.width; h = g.height
            p = (g.proj.k, g.proj.minx, g.proj.miny, g.proj.scale)
            rs = g.raions.map { RaionShape(name: $0.name, oblast: $0.oblast, path: GeoStore.path($0.rings)) }
            for o in g.oblasts {
                let path = GeoStore.path(o.rings)
                borders.addPath(path)
                obl[o.name] = path
            }
        }
        width = w; height = h; raions = rs; oblastBorders = borders; oblastShapes = obl; proj = p

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
        CGPoint(x: (lon * proj.k - proj.minx) * proj.s, y: (-lat - proj.miny) * proj.s)
    }

    public func isUniqueHromadaKey(_ key: String) -> Bool { (keyCounts[key] ?? 0) == 1 }

    public func hromada(id: String) -> Hromada? { byID[id] }

    public var defaultCity: Hromada? { hromadas.first { $0.isKyiv } }

    public var popular: [Hromada] {
        let names = ["Київ", "Харківська міська громада", "Одеська міська громада", "Дніпровська міська громада", "Львівська міська громада", "Запорізька міська громада", "Ірпінська міська громада", "Бучанська міська громада", "Вінницька міська громада", "Полтавська міська громада", "Чернігівська міська громада", "Сумська міська громада", "Миколаївська міська громада", "Житомирська міська громада", "Черкаська міська громада", "Кропивницька міська громада", "Хмельницька міська громада", "Рівненська міська громада", "Луцька міська громада", "Тернопільська міська громада", "Івано-Франківська міська громада", "Ужгородська міська громада", "Чернівецька міська громада", "Херсонська міська громада"]
        return names.compactMap { n in hromadas.first { $0.name == n } }
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

    public static func angleDiff(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }
}
