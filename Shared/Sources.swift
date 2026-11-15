import Foundation

// MARK: - Networking

enum NetError: Error { case status(Int), badJSON }

enum Net {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 12
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15",
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "uk-UA,uk;q=0.9,en;q=0.8",
        ]
        return URLSession(configuration: c)
    }()

    static func json(_ urlString: String, site: String) async throws -> Any {
        guard let url = URL(string: urlString), url.scheme == "https" else { throw NetError.badJSON }
        var r = URLRequest(url: url)
        r.setValue(site + "/", forHTTPHeaderField: "Referer")
        r.setValue(site, forHTTPHeaderField: "Origin")
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else { throw NetError.status(code) }
        guard data.count < 8_000_000 else { throw NetError.badJSON }   // refuse oversized responses
        return try JSONSerialization.jsonObject(with: data)
    }
}

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func str(_ keys: String...) -> String? {
        for k in keys { if let v = self[k] as? String, !v.isEmpty { return v } }
        return nil
    }
    func num(_ keys: String...) -> Double? {
        for k in keys {
            if let v = self[k] as? Double { return v }
            if let v = self[k] as? Int { return Double(v) }
            if let v = self[k] as? NSNumber { return v.doubleValue }
            if let v = self[k] as? String, let d = Double(v) { return d }
        }
        return nil
    }
    func date(_ keys: String...) -> Date? {
        for k in keys {
            if let s = self[k] as? String, let d = ISODate.parse(s) { return d }
            if let n = self[k] as? NSNumber {
                let v = n.doubleValue
                return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
            }
        }
        return nil
    }
}

enum ISODate {
    private static let f1: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static let f2: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    static func parse(_ s: String) -> Date? { f1.date(from: s) ?? f2.date(from: s) }
}

// MARK: - ukrainealarm (official map)

struct UkraineAlarmResult {
    var raions: [String: RegionAlert] = [:]
    var oblasts: [String: RegionAlert] = [:]
    var cities: [String: RegionAlert] = [:]
    var hromadas: [String: RegionAlert] = [:]
    var targets: [AirTarget] = []
}

enum UkraineAlarmClient {
    static let site = "https://map.ukrainealarm.com"

    static func fetch() async throws -> UkraineAlarmResult {
        guard let root = try await Net.json(site + "/api/v2/data/mapUpdate", site: site) as? JSON else { throw NetError.badJSON }
        var out = UkraineAlarmResult()
        for a in (root["alerts"] as? [JSON]) ?? [] {
            guard let name = a.str("regionName") else { continue }
            let active = (a["activeAlerts"] as? [JSON]) ?? []
            guard !active.isEmpty else { continue }
            let since = active.compactMap { $0.date("lastUpdate") }.min() ?? a.date("lastUpdate")
            // Each active alert carries levels: "red" = масштабна тривога, "yellow" = загроза дронів/ракет
            var level: AlertLevel = .none
            for al in active {
                let lv = (al["activeAlertLevels"] as? [JSON]) ?? []
                if lv.isEmpty { level = .alert }
                for l in lv {
                    switch (l.str("alertLevel") ?? "red").lowercased() {
                    case "yellow", "orange": level = max(level, .threat)
                    default: level = .alert
                    }
                }
            }
            guard level != .none else { continue }
            let st = RegionAlert(level: level, since: since)
            switch a.str("regionType") ?? "" {
            case "State":
                if name.hasPrefix("м.") { out.cities[name] = st.merged(with: out.cities[name]) }
                else { out.oblasts[name] = st.merged(with: out.oblasts[name]) }
            case "District":
                out.raions[name] = st.merged(with: out.raions[name])
            case "Community":
                let k = Hromada.normalise(name)
                out.hromadas[k] = st.merged(with: out.hromadas[k])
            default:
                break
            }
        }
        // Air targets (format not documented — parse defensively)
        if let loc = root["locations"] as? JSON {
            let lists = [(loc["targets"] as? [Any]) ?? [], (loc["targetsPoints"] as? [Any]) ?? []]
            var i = 0
            for list in lists {
                for item in list {
                    guard let t = item as? JSON else { continue }
                    let pt = (t["point"] as? JSON) ?? (t["location"] as? JSON) ?? t
                    guard let lat = pt.num("lat", "latitude"), let lon = pt.num("lng", "lon", "longitude") else { continue }
                    i += 1
                    out.targets.append(AirTarget(
                        id: "ua-" + (t.str("id", "targetId") ?? String(i)),
                        kind: TargetKind.from(t.str("type", "targetType", "kind")),
                        lat: lat, lon: lon,
                        bearing: t.num("direction", "course", "bearing", "azimuth", "heading"),
                        speed: t.num("speed", "speedKmh"),
                        lastSeen: t.date("lastUpdate", "updatedAt", "time", "timestamp") ?? Date(),
                        sources: ["ukrainealarm"]))
                }
            }
        }
        return out
    }
}

// MARK: - dimap.live

struct DimapAlerts {
    var raions: [String: RegionAlert] = [:]
    var cities: [String: RegionAlert] = [:]
}

enum DimapClient {
    static let site = "https://dimap.live"
    static let api = "https://api.dimap.live/api"

    static func alerts() async throws -> DimapAlerts {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        guard let list = try await Net.json(api + "/alerts?_refresh=\(ts)", site: site) as? [JSON] else { throw NetError.badJSON }
        var out = DimapAlerts()
        for a in list {
            guard let region = a.str("region") else { continue }
            let level: AlertLevel
            switch (a.str("color") ?? "").lowercased() {
            case "red": level = .alert
            case "yellow", "orange": level = .threat
            default: level = .none
            }
            guard level != .none else { continue }
            let st = RegionAlert(level: level, since: a.date("startedAt"))
            if region.hasPrefix("м.") { out.cities[region] = st.merged(with: out.cities[region]) }
            else { out.raions[region] = st.merged(with: out.raions[region]) }
        }
        return out
    }

    /// Places with "дорозвідка" mentioned in the dimap news feed during the last 30 minutes.
    static func recon() async throws -> ReconPlaces {
        guard let list = try await Net.json(api + "/news", site: site) as? [JSON] else { throw NetError.badJSON }
        var out = ReconPlaces()
        let now = Date()
        let items = list.compactMap { n -> (Date, JSON)? in n.date("date").map { ($0, n) } }.sorted { $0.0 < $1.0 }
        for (date, n) in items where now.timeIntervalSince(date) < 30 * 60 {
            let text = (n.str("textPlain", "text") ?? "").lowercased()
            let isRecon = text.contains("дорозвід") || text.contains("доразвід") || text.contains("доразвед") || text.contains("дорозвiд")
            let isEnd = text.contains("заверш") || text.contains("закінч") || text.contains("відбій дорозвід")
            guard isRecon else { continue }
            let places = ((n["classification"] as? JSON)?["places"] as? JSON) ?? [:]
            func names(_ k: String) -> [String] { ((places[k] as? [JSON]) ?? []).compactMap { $0.str("name") } }
            var obl = names("oblasts"), dist = names("districts"), cities = names("cities")
            if obl.isEmpty && dist.isEmpty && cities.isEmpty { obl = (n["regions"] as? [String]) ?? [] }
            if text.contains("київ") && !text.contains("київщин") && !text.contains("київськ") { cities.append("м. Київ") }
            for o in obl { if isEnd { out.oblasts.remove(o) } else { out.oblasts.insert(o) } }
            for d in dist { let k = d.hasSuffix("район") ? d : d + " район"; if isEnd { out.raions.remove(k) } else { out.raions.insert(k) } }
            for c in cities { let k = c.hasPrefix("м. ") ? c : "м. " + c; if isEnd { out.cities.remove(k) } else { out.cities.insert(k) } }
        }
        return out
    }

    static func targets() async throws -> [AirTarget] {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let root = try await Net.json(api + "/targets?_refresh=\(ts)", site: site)
        let list: [JSON] = ((root as? JSON)?["targets"] as? [JSON]) ?? (root as? [JSON]) ?? []
        return list.compactMap { t in
            guard let lat = t.num("lat", "latitude"), let lon = t.num("lng", "lon", "longitude") else { return nil }
            let type = t.str("type", "kind")
            var a = AirTarget(
                id: "dm-" + (t.str("id") ?? "\(lat),\(lon)"),
                kind: TargetKind.from(type),
                lat: lat, lon: lon,
                bearing: t.num("bearing", "course", "direction"),
                speed: t.num("speed"),
                lastSeen: t.date("lastSeen", "updatedAt") ?? Date(),
                sources: ["dimap"])
            a.model = TargetModel.name(type)
            if let tr = t.num("_turn", "turn") { a.turn = tr; a.turnKnown = true }
            a.altitude = t.num("altitude")
            a.count = Int(t.num("count") ?? 1)
            return a
        }
    }
}

// MARK: - neptun.in.ua (extra target source; dimap has priority)

enum NeptunClient {
    static let site = "https://neptun.in.ua"

    static func threats() async throws -> [AirTarget] {
        guard let root = try await Net.json(site + "/api/v1/threats", site: site) as? JSON else { throw NetError.badJSON }
        return ((root["threats"] as? [JSON]) ?? []).compactMap { t in
            guard (t.str("status") ?? "active") == "active",
                  let lat = t.num("lat", "latitude"), let lon = t.num("lon", "lng", "longitude") else { return nil }
            let type = t.str("type") ?? ""
            let title = t.str("title")
            var kind = TargetKind.from(type)
            if kind == .unknown { kind = TargetKind.from(title) }
            var a = AirTarget(
                id: "np-" + (t.str("id") ?? "\(lat),\(lon)"),
                kind: kind, lat: lat, lon: lon,
                bearing: t.num("heading", "course", "bearing"),
                speed: t.num("speed", "speedKmh"),
                lastSeen: t.date("updatedAt", "lastSeenAt") ?? Date(),
                sources: ["neptun"])
            if let title, TargetKind.from(title) != .unknown, title.count > 4, title != "БпЛА" { a.model = title }
            a.count = max(1, Int(t.num("count") ?? 1))
            return a
        }
    }
}

public struct ReconPlaces: Sendable {
    public var raions = Set<String>()
    public var cities = Set<String>()
    public var oblasts = Set<String>()
}

// MARK: - radarua.com (alerts only — used as a fallback)

struct RadarAlerts {
    var raions: [String: RegionAlert] = [:]
    var cities: [String: RegionAlert] = [:]
}

enum RadarUAClient {
    static let site = "https://radarua.com"

    static func alerts() async throws -> RadarAlerts {
        guard let root = try await Net.json(site + "/api/alerts", site: site) as? JSON else { throw NetError.badJSON }
        var out = RadarAlerts()
        for (key, value) in (root["mapZoneStates"] as? JSON) ?? [:] {
            guard let v = value as? JSON else { continue }
            let alerted = (v["alerted"] as? Bool) ?? false
            let lvl = (v["level"] as? String ?? "").lowercased()
            let level: AlertLevel = (alerted && lvl != "yellow") || lvl == "red" ? .alert : (lvl == "yellow" ? .threat : .none)
            guard level != .none else { continue }
            let name = String(key.split(separator: "|").first ?? Substring(key))
            let st = RegionAlert(level: level)
            if name.hasPrefix("м.") { out.cities[name] = st.merged(with: out.cities[name]) }
            else { out.raions[name] = st.merged(with: out.raions[name]) }
        }
        return out
    }
}

// MARK: - Aggregator

public final class Aggregator: @unchecked Sendable {
    /// Targets from the secondary services from the last full fetch (used to enrich fast dimap updates).
    private var lastUA: [AirTarget] = []
    private var lastNP: [AirTarget] = []

    /// Fast path: only dimap targets (every ~2 s), enriched with the last known details from other services.
    public func fetchTargets() async -> [AirTarget]? {
        guard let dm = try? await DimapClient.targets() else { return nil }
        var t = Aggregator.mergeTargets(Aggregator.mergeTargets(dm, lastUA, addUnmatched: false), lastNP, radiusKm: 15, addUnmatched: false)
        t.removeAll { x in x.kind == .fpv || ["Ланцет", "Молнія"].contains { (x.model ?? "").contains($0) } }
        return t
    }
    public init() {}

    private func run<T>(_ name: String, _ op: @escaping () async throws -> T) async -> (T?, SourceStatus) {
        do {
            let v = try await op()
            return (v, SourceStatus(name: name, ok: true, detail: "OK"))
        } catch NetError.status(let c) {
            return (nil, SourceStatus(name: name, ok: false, detail: "HTTP \(c)"))
        } catch {
            return (nil, SourceStatus(name: name, ok: false, detail: "немає зв'язку"))
        }
    }

    public func fetch() async -> Snapshot {
        // Alerts come only from ukrainealarm (official). dimap / neptun are used for air targets only.
        async let ua = run("ukrainealarm") { try await UkraineAlarmClient.fetch() }
        async let dmT = run("dimap.live цілі") { try await DimapClient.targets() }
        async let np = run("neptun.in.ua") { try await NeptunClient.threats() }
        let (uaR, dmTR, npR) = await (ua, dmT, np)
        lastUA = uaR.0?.targets ?? lastUA
        lastNP = npR.0 ?? lastNP

        var s = Snapshot()
        if let u = uaR.0 {
            s.raions = u.raions; s.oblasts = u.oblasts; s.cities = u.cities; s.hromadas = u.hromadas
        }
        // Targets: dimap first, then ukrainealarm and neptun fill the gaps
        if dmTR.1.ok {
            // dimap is the reference: show only its targets; other services only add details (course, model).
            s.targets = Aggregator.mergeTargets(Aggregator.mergeTargets(dmTR.0 ?? [], uaR.0?.targets ?? [], addUnmatched: false), npR.0 ?? [], radiusKm: 15, addUnmatched: false)
        } else {
            // dimap is down: show only targets confirmed by both other services; doubtful ones are hidden.
            s.targets = Aggregator.mergeTargets(uaR.0?.targets ?? [], npR.0 ?? [], radiusKm: 15, addUnmatched: false).filter { $0.sources.count >= 2 }
        }
        // Tactical front-line drones (FPV, Lancet, Molnia) are noise for a city widget.
        s.targets.removeAll { t in
            t.kind == .fpv || ["Ланцет", "Молнія"].contains { (t.model ?? "").contains($0) }
        }

        s.sources = [uaR.1, SourceStatus(name: "dimap.live", ok: dmTR.1.ok, detail: dmTR.1.detail), SourceStatus(name: "neptun.in.ua", ok: npR.1.ok, detail: npR.1.detail)]
        s.updated = Date()
        return s
    }

    public static func applyRecon(_ rc: ReconPlaces, to s: inout Snapshot, geo: GeoStore = .shared) {
        let recon = RegionAlert(level: .recon, since: Date())
        var raions = rc.raions
        for r in geo.raions where rc.oblasts.contains(r.oblast) { raions.insert(r.name) }
        for name in raions {
            let oblast = geo.raions.first { $0.name == name }?.oblast ?? ""
            if s.raionState(name, oblast: oblast).level < .recon { s.raions[name] = recon }
        }
        for c in rc.cities where (s.cities[c]?.level ?? .none) < .recon { s.cities[c] = recon }
    }

    static func mergeTargets(_ a: [AirTarget], _ b: [AirTarget], radiusKm: Double = 10, addUnmatched: Bool = true) -> [AirTarget] {
        let now = Date()
        var out = a.filter { now.timeIntervalSince($0.lastSeen) < 300 }
        for t in b where now.timeIntervalSince(t.lastSeen) < 300 {
            if let i = out.firstIndex(where: { o in
                Geo.distanceKm(lat1: o.lat, lon1: o.lon, lat2: t.lat, lon2: t.lon) < radiusKm &&
                (o.bearing == nil || t.bearing == nil || Geo.angleDiff(o.bearing!, t.bearing!) < 30)
            }) {
                out[i].sources = Array(Set(out[i].sources + t.sources)).sorted()
                if out[i].bearing == nil { out[i].bearing = t.bearing }
                if out[i].model == nil { out[i].model = t.model }
                if out[i].kind == .unknown { out[i].kind = t.kind }
                if t.lastSeen > out[i].lastSeen { out[i].lastSeen = t.lastSeen }
            } else if addUnmatched {
                out.append(t)
            }
        }
        return out
    }
}
