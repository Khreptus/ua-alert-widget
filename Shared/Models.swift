import Foundation

public enum AlertLevel: Int, Codable, Comparable, Sendable {
    /// none < recon (дорозвідка) < threat (дрони/ракети, жовта) < alert (масштабна, червона)
    case none = 0, recon = 1, threat = 2, alert = 3
    public static func < (a: AlertLevel, b: AlertLevel) -> Bool { a.rawValue < b.rawValue }
}

public struct RegionAlert: Codable, Hashable, Sendable {
    public var level: AlertLevel
    public var since: Date?
    public init(level: AlertLevel, since: Date? = nil) { self.level = level; self.since = since }

    /// Keeps the stronger level; for equal levels keeps the earliest start time.
    public func merged(with o: RegionAlert?) -> RegionAlert {
        guard let o else { return self }
        if o.level > level { return o }
        if o.level < level { return self }
        let s: Date? = [since, o.since].compactMap { $0 }.min()
        return RegionAlert(level: level, since: s)
    }
}

public enum TargetKind: String, Codable, Sendable, CaseIterable {
    case shahed, jetShahed, geran5, cruise, ballistic, kab, aircraft, helicopter, recon, fpv, unknown

    /// Maps dimap / neptun / ukrainealarm type ids and titles to a class.
    public static func from(_ raw: String?) -> TargetKind {
        let s = (raw ?? "").lowercased()
        func has(_ a: String...) -> Bool { a.contains { s.contains($0) } }
        if has("geran5", "geran-5", "geran_5", "герань-5", "герань 5") { return .geran5 }
        if has("reactive", "jet", "реактив", "geran3", "geran4", "geran-3", "geran-4", "герань-3", "герань-4", "shahed238", "shahed-238") { return .jetShahed }
        if has("fpv") { return .fpv }
        if has("ballist", "баліст", "iskanderm", "iskander-m", "іскандер-м", "kn23", "kn-23", "kingal", "kinzhal", "кинджал", "s300", "с-300", "oreshnik", "орешнік", "curkon", "zircon", "циркон") { return .ballistic }
        if has("kab", "каб", "ympk", "умпк", "ympd", "умпб", "bomb", "бомб") { return .kab }
        if has("kalibr", "калібр", "x101", "х-101", "x555", "х-555", "x55", "х-55", "x59", "х-59", "x69", "х-69", "x22", "х-22", "x31", "х-31", "oniks", "онікс", "p800", "iskanderk", "іскандер-к", "rocket", "missile", "cruise", "ракет", "крилат") { return .cruise }
        if has("vertolit", "heli", "гелікоптер", "вертол", "rotor") { return .helicopter }
        if has("orlan", "орлан", "zala", "supercam", "scout", "розвід", "molnia", "молнія", "lancet", "ланцет", "recon") { return .recon }
        if has("su34", "su35", "su-", "су-", "avia", "авіа", "plane", "aircraft", "mig", "міг", "tu-", "ту-") { return .aircraft }
        if has("shahed", "shakhed", "шахед", "geran", "герань", "dron", "drone", "uav", "бпла", "bpla") { return .shahed }
        return .unknown
    }

    public var title: String {
        switch self {
        case .shahed: return "Шахед"
        case .jetShahed: return "Реактивний шахед"
        case .geran5: return "Герань-5"
        case .cruise: return "Крилата ракета"
        case .ballistic: return "Балістика"
        case .kab: return "КАБ"
        case .aircraft: return "Авіація"
        case .helicopter: return "Гелікоптер"
        case .recon: return "Розвідувальний БпЛА"
        case .fpv: return "FPV"
        case .unknown: return "Ціль"
        }
    }

    /// Used when a source gives no speed (km/h).
    public var defaultSpeed: Double {
        switch self {
        case .shahed, .unknown: return 185
        case .jetShahed: return 550
        case .geran5: return 600
        case .cruise: return 800
        case .ballistic: return 3000
        case .kab: return 400
        case .aircraft: return 800
        case .helicopter: return 220
        case .recon: return 120
        case .fpv: return 90
        }
    }
}

/// Human names for specific dimap model ids.
public enum TargetModel {
    static let names: [String: String] = [
        "geran1_shahed131": "«Герань-1»", "geran2_shahed136": "«Герань-2»", "geran3": "«Герань-3»", "geran4": "«Герань-4»", "geran5": "«Герань-5»",
        "kalibr": "«Калібр»", "x101": "Х-101", "x555": "Х-555", "x55": "Х-55", "x59": "Х-59", "x69": "Х-69", "x22": "Х-22", "x31": "Х-31",
        "p800_oniks": "«Онікс»", "curkon": "«Циркон»", "iskanderm": "«Іскандер-М»", "iskanderk": "«Іскандер-К»", "kn23": "KN-23",
        "kingal": "«Кинджал»", "s300": "С-300", "oreshnik": "«Орешнік»", "kab_ympk": "КАБ з УМПК", "ympd_d30cn": "УМПБ Д-30СН",
        "su34": "Су-34", "su35": "Су-35", "orlan10": "«Орлан-10»", "orlan30": "«Орлан-30»", "zala": "ZALA", "supercam": "Supercam",
        "lancet1": "«Ланцет-1»", "lancet3": "«Ланцет-3»", "molnia1": "«Молнія-1»", "molnia2": "«Молнія-2»", "bm35_italmas": "БМ-35",
    ]
    public static func name(_ id: String?) -> String? { id.flatMap { names[$0.lowercased()] } }
}

public struct AirTarget: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var kind: TargetKind
    public var lat: Double
    public var lon: Double
    public var bearing: Double?
    public var speed: Double?
    public var lastSeen: Date
    public var sources: [String]
    /// Specific model ("Х-101"), if the source knows it.
    public var model: String? = nil
    /// Turn rate, degrees per minute (dimap `_turn`).
    public var turn: Double = 0
    /// Group size ("×3").
    public var count: Int = 1

    public var effectiveSpeed: Double { (speed ?? 0) > 0 ? speed! : kind.defaultSpeed }
    public var label: String { (model ?? kind.title) + (count > 1 ? " ×\(count)" : "") }
}

// MARK: - Projected path (same model as dimap: curved cone, 10 minutes ahead)

public struct Projection: Sendable {
    public struct LL: Sendable { public var lat: Double; public var lon: Double }
    public var left: [LL] = []
    public var right: [LL] = []
    public var center: [LL] = []

    /// Heading after `t` minutes: turn rate fades out over the horizon, clamped to ±60°.
    static func heading(_ t: AirTarget, at m: Double, horizon: Double) -> Double {
        let mm = min(m, horizon)
        return (t.bearing ?? 0) + max(-60, min(60, t.turn * mm * (1 - mm / (2 * horizon))))
    }

    public static func cone(_ t: AirTarget, minutes: Double = 10, width: Double = 16) -> Projection? {
        guard t.bearing != nil else { return nil }
        let n = 24
        let dt = minutes / Double(n)
        let v = t.effectiveSpeed
        var p = Projection()
        var l = LL(lat: t.lat, lon: t.lon), r = l, c = l
        for k in 1...n {
            let tt = (Double(k) - 0.5) * dt
            let h = heading(t, at: tt, horizon: minutes)
            let half = 6 + (width - 6) * min(1, tt / minutes)
            let step = v * dt / 60
            l = Geo.destination(l, km: step, bearing: h - half)
            r = Geo.destination(r, km: step, bearing: h + half)
            c = Geo.destination(c, km: step, bearing: h)
            p.left.append(l); p.right.append(r); p.center.append(c)
        }
        return p
    }

    /// Minutes until the target's projected path passes the point (≤ radius km), up to `maxMinutes`.
    public static func eta(_ t: AirTarget, toLat lat: Double, lon: Double, radiusKm: Double = 12, maxMinutes: Double = 90) -> Double? {
        let d0 = Geo.distanceKm(lat1: t.lat, lon1: t.lon, lat2: lat, lon2: lon)
        if d0 <= radiusKm { return 0 }
        guard t.bearing != nil else { return nil }
        let v = t.effectiveSpeed
        guard d0 / v * 60 <= maxMinutes else { return nil }
        let dt = 0.25
        var c = LL(lat: t.lat, lon: t.lon)
        var m = 0.0
        var best = d0
        while m < maxMinutes {
            m += dt
            c = Geo.destination(c, km: v * dt / 60, bearing: heading(t, at: m, horizon: 10))
            let d = Geo.distanceKm(lat1: c.lat, lon1: c.lon, lat2: lat, lon2: lon)
            if d <= radiusKm { return m }
            if d > best + 30 { return nil }   // moving away
            best = min(best, d)
        }
        return nil
    }
}

public struct SourceStatus: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var ok: Bool
    public var detail: String
}

public struct Snapshot: Codable, Sendable {
    /// Raion name ("Бучанський район") → state
    public var raions: [String: RegionAlert] = [:]
    /// City key ("м. Київ") → state
    public var cities: [String: RegionAlert] = [:]
    /// Oblast-wide alerts (official) ("Київська область") → state
    public var oblasts: [String: RegionAlert] = [:]
    /// Normalised hromada key ("ірпінська") → state (official, community level)
    public var hromadas: [String: RegionAlert] = [:]
    public var targets: [AirTarget] = []
    public var sources: [SourceStatus] = []
    public var updated: Date = .distantPast

    public init() {}

    public var isEmpty: Bool { updated == .distantPast }

    public func raionState(_ raion: String, oblast: String) -> RegionAlert {
        let r = raions[raion] ?? RegionAlert(level: .none)
        return r.merged(with: oblasts[oblast])
    }

    public struct Summary: Sendable {
        public var alertRaions = 0
        public var threatRaions = 0
        public var reconRaions = 0
        public var alertOblasts = 0
        public var targets = 0
        /// Red + yellow: both are air-raid alerts.
        public var totalAlert: Int { alertRaions + threatRaions }
    }

    public func summary(geo: GeoStore = .shared) -> Summary {
        var s = Summary()
        var obl = Set<String>()
        for r in geo.raions {
            let st = raionState(r.name, oblast: r.oblast)
            if st.level == .alert { s.alertRaions += 1; obl.insert(r.oblast) }
            else if st.level == .threat { s.threatRaions += 1 }
            else if st.level == .recon { s.reconRaions += 1 }
        }
        s.alertOblasts = obl.count
        s.targets = targets.count
        return s
    }

    public static var placeholder: Snapshot {
        var s = Snapshot()
        for n in ["Харківський район", "Ізюмський район", "Донецький район", "Покровський район", "Краматорський район"] { s.raions[n] = RegionAlert(level: .alert, since: Date().addingTimeInterval(-3600)) }
        for n in ["Чернігівський район", "Бучанський район", "Броварський район"] { s.raions[n] = RegionAlert(level: .threat) }
        s.updated = Date()
        return s
    }
}

// MARK: - City status

public struct CityStatus: Sendable {
    public var level: AlertLevel
    public var since: Date?
    public var highThreat: Bool
    public var nearestKm: Double?
    public var nearestKind: TargetKind?
    /// Minutes until the closest target heading at the city arrives.
    public var etaMinutes: Double? = nil
    public var etaKind: TargetKind? = nil
    /// What the attack looks like right now: "Балістика", "Масована атака · дрони + ракети", "Дрони" …
    public var attack: String? = nil
    /// Red and yellow are both air-raid alerts (yellow is shown as such only on the map).
    public var isAlarm: Bool { level >= .threat }
}

public extension Snapshot {
    /// Rough description of the current attack for the place: ballistic / massive / drones / missiles.
    func attackKind(lat: Double, lon: Double) -> String? {
        var near: [TargetKind: Int] = [:], all: [TargetKind: Int] = [:]
        for t in targets {
            all[t.kind, default: 0] += t.count
            if Geo.distanceKm(lat1: t.lat, lon1: t.lon, lat2: lat, lon2: lon) < 400 { near[t.kind, default: 0] += t.count }
        }
        let drones = (all[.shahed] ?? 0) + (all[.jetShahed] ?? 0) + (all[.geran5] ?? 0)
        let missiles = (all[.cruise] ?? 0) + (all[.ballistic] ?? 0)
        let massive = drones >= 25 || missiles >= 5
        if (near[.ballistic] ?? 0) > 0 { return massive ? "Балістика · масована атака" : "Балістика" }
        if massive {
            let parts = [drones > 0 ? "дрони" : nil, missiles > 0 ? "ракети" : nil].compactMap { $0 }
            return "Масована атака" + (parts.isEmpty ? "" : " · " + parts.joined(separator: " + "))
        }
        let nd = (near[.shahed] ?? 0) + (near[.jetShahed] ?? 0) + (near[.geran5] ?? 0)
        if (near[.cruise] ?? 0) > 0 { return nd > 0 ? "Ракети + дрони" : "Крилаті ракети" }
        if (near[.kab] ?? 0) > 0 { return "КАБи" }
        if nd > 0 { return nd == 1 ? "Дрон поруч" : "Дрони · \(nd)" }
        if (near[.aircraft] ?? 0) + (near[.helicopter] ?? 0) > 0 { return "Авіація" }
        return nil
    }

    func status(for city: Hromada, geo: GeoStore = .shared) -> CityStatus {
        var st = RegionAlert(level: .none)
        // The city's state = what is painted on the map: its raion (+ the city dot for Kyiv / regional centres).
        if let c = cities[city.cityKey] { st = st.merged(with: c) }
        st = st.merged(with: raionState(city.raion, oblast: city.oblast))

        var high = false
        var nearest: Double?
        var nearestKind: TargetKind?
        var eta: Double?
        var etaKind: TargetKind?
        for t in targets {
            let d = Geo.distanceKm(lat1: t.lat, lon1: t.lon, lat2: city.lat, lon2: city.lon)
            if nearest == nil || d < nearest! { nearest = d; nearestKind = t.kind }
            if d < 25 { high = true }
            if let e = Projection.eta(t, toLat: city.lat, lon: city.lon) {
                if eta == nil || e < eta! { eta = e; etaKind = t.kind }
                if e <= 30 { high = true }
            }
        }
        return CityStatus(level: st.level, since: st.since, highThreat: high, nearestKm: nearest, nearestKind: nearestKind, etaMinutes: eta, etaKind: etaKind,
                          attack: attackKind(lat: city.lat, lon: city.lon))
    }
}

// MARK: - Formatting

public enum Fmt {
    public static func eta(_ m: Double) -> String {
        if m < 1 { return "<1 хв" }
        let i = Int(m.rounded())
        return i < 60 ? "\(i) хв" : "\(i / 60) год \(i % 60) хв"
    }
    public static func duration(since: Date?, now: Date = Date()) -> String? {
        guard let since else { return nil }
        let m = max(0, Int(now.timeIntervalSince(since) / 60))
        if m < 60 { return "\(m) хв" }
        let h = m / 60, r = m % 60
        if h >= 24 { return "\(h / 24) д \(h % 24) год" }
        return r == 0 ? "\(h) год" : "\(h) год \(r) хв"
    }

    public static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "uk_UA")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    public static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return one }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
        return many
    }
}
