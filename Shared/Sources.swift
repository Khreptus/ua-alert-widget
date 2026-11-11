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
            let st = RegionAlert(level: .alert, since: since)
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

    static func targets() async throws -> [AirTarget] {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let root = try await Net.json(api + "/targets?_refresh=\(ts)", site: site)
        let list: [JSON] = ((root as? JSON)?["targets"] as? [JSON]) ?? (root as? [JSON]) ?? []
        return list.compactMap { t in
            guard let lat = t.num("lat", "latitude"), let lon = t.num("lng", "lon", "longitude") else { return nil }
            return AirTarget(
                id: "dm-" + (t.str("id") ?? "\(lat),\(lon)"),
                kind: TargetKind.from(t.str("type", "kind")),
                lat: lat, lon: lon,
                bearing: t.num("bearing", "course", "direction"),
                speed: t.num("speed"),
                lastSeen: t.date("lastSeen", "updatedAt") ?? Date(),
                sources: ["dimap"])
        }
    }
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
        async let ua = run("ukrainealarm") { try await UkraineAlarmClient.fetch() }
        async let dmA = run("dimap.live") { try await DimapClient.alerts() }
        async let dmT = run("dimap.live цілі") { try await DimapClient.targets() }
        async let rr = run("radarua.com") { try await RadarUAClient.alerts() }
        let (uaR, dmAR, dmTR, rrR) = await (ua, dmA, dmT, rr)

        var s = Snapshot()
        // Official first
        if let u = uaR.0 {
            s.raions = u.raions; s.oblasts = u.oblasts; s.cities = u.cities; s.hromadas = u.hromadas
        }
        // dimap: alerts + threat zones
        if let d = dmAR.0 {
            for (k, v) in d.raions { s.raions[k] = v.merged(with: s.raions[k]) }
            for (k, v) in d.cities { s.cities[k] = v.merged(with: s.cities[k]) }
        }
        // radarua: fallback / extra confirmation
        if let r = rrR.0 {
            let officialDown = uaR.0 == nil
            for (k, v) in r.raions where officialDown || v.level == .threat || s.raions[k] == nil { s.raions[k] = v.merged(with: s.raions[k]) }
            for (k, v) in r.cities where officialDown || s.cities[k] == nil { s.cities[k] = v.merged(with: s.cities[k]) }
        }
        // Targets: ONLY dimap + ukrainealarm
        s.targets = Aggregator.mergeTargets(dmTR.0 ?? [], uaR.0?.targets ?? [])

        s.sources = [uaR.1, SourceStatus(name: "dimap.live", ok: dmAR.1.ok || dmTR.1.ok, detail: dmAR.1.ok ? (dmTR.1.ok ? "OK" : "без цілей") : dmAR.1.detail), rrR.1]
        s.updated = Date()
        return s
    }

    static func mergeTargets(_ a: [AirTarget], _ b: [AirTarget]) -> [AirTarget] {
        let now = Date()
        var out = a.filter { now.timeIntervalSince($0.lastSeen) < 300 }
        for t in b where now.timeIntervalSince(t.lastSeen) < 300 {
            if let i = out.firstIndex(where: { o in
                Geo.distanceKm(lat1: o.lat, lon1: o.lon, lat2: t.lat, lon2: t.lon) < 10 &&
                (o.bearing == nil || t.bearing == nil || Geo.angleDiff(o.bearing!, t.bearing!) < 30)
            }) {
                out[i].sources = Array(Set(out[i].sources + t.sources)).sorted()
                if out[i].bearing == nil { out[i].bearing = t.bearing }
                if t.lastSeen > out[i].lastSeen { out[i].lastSeen = t.lastSeen }
            } else {
                out.append(t)
            }
        }
        return out
    }
}
