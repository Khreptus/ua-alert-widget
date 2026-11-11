import Foundation

public enum AlertLevel: Int, Codable, Comparable, Sendable {
    /// none < recon (доразвідка) < threat (дрони/ракети, жовта) < alert (масштабна, червона)
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

public enum TargetKind: String, Codable, Sendable {
    case drone, missile, ballistic, aircraft, unknown

    public static func from(_ raw: String?) -> TargetKind {
        let s = (raw ?? "").lowercased()
        if s.contains("ballist") || s.contains("баліст") { return .ballistic }
        if s.contains("shahed") || s.contains("drone") || s.contains("uav") || s.contains("bpla") || s.contains("шахед") || s.contains("бпла") || s.contains("geran") { return .drone }
        if s.contains("missile") || s.contains("rocket") || s.contains("kr") || s.contains("ракет") || s.contains("kalibr") || s.contains("kh-") || s.contains("x-") { return .missile }
        if s.contains("avia") || s.contains("plane") || s.contains("aircraft") || s.contains("jet") || s.contains("авіа") || s.contains("mig") || s.contains("tu-") || s.contains("su-") { return .aircraft }
        return .unknown
    }

    public var title: String {
        switch self {
        case .drone: return "БпЛА"
        case .missile: return "Ракета"
        case .ballistic: return "Балістика"
        case .aircraft: return "Авіація"
        case .unknown: return "Ціль"
        }
    }
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
}

public extension Snapshot {
    func status(for city: Hromada, geo: GeoStore = .shared) -> CityStatus {
        var st = RegionAlert(level: .none)
        // The city's state = what is painted on the map: its raion (+ the city dot for Kyiv / regional centres).
        if let c = cities[city.cityKey] { st = st.merged(with: c) }
        st = st.merged(with: raionState(city.raion, oblast: city.oblast))

        var high = false
        var nearest: Double?
        var nearestKind: TargetKind?
        for t in targets {
            let d = Geo.distanceKm(lat1: t.lat, lon1: t.lon, lat2: city.lat, lon2: city.lon)
            if nearest == nil || d < nearest! { nearest = d; nearestKind = t.kind }
            if d < 25 { high = true; continue }
            if d < 120, let b = t.bearing {
                let toCity = Geo.bearing(lat1: t.lat, lon1: t.lon, lat2: city.lat, lon2: city.lon)
                if Geo.angleDiff(b, toCity) < 25 { high = true }
            }
            if t.kind == .ballistic && d < 400 { high = true }
        }
        return CityStatus(level: st.level, since: st.since, highThreat: high, nearestKm: nearest, nearestKind: nearestKind)
    }
}

// MARK: - Formatting

public enum Fmt {
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
