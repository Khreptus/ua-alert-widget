import Foundation

public extension Geo {
    /// Signed shortest turn from a to b, −180…180 (positive = clockwise).
    static func signedAngle(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
}

public extension AirTarget {
    /// Real-time position `now`: keeps flying along the (turning) course since the fix was received,
    /// and eases out the jump between the old prediction and a new fix over ~1.5 s.
    func advanced(to now: Date, maxMinutes: Double = 2) -> AirTarget {
        guard bearing != nil else { return self }
        let base = fixAt ?? lastSeen
        let secs = max(0, now.timeIntervalSince(base))
        let m = min(maxMinutes, secs / 60)
        var t = self
        var p = Projection.LL(lat: lat, lon: lon)
        if m > 0.002 {
            let step = 0.1
            var done = 0.0
            while done < m {
                let dt = min(step, m - done)
                p = Geo.destination(p, km: effectiveSpeed * dt / 60, bearing: Projection.heading(self, at: done + dt / 2, horizon: 10))
                done += dt
            }
            t.bearing = Projection.heading(self, at: m, horizon: 10)
            // The turn already flown is used up: the cone keeps bending from the current heading.
            t.turn = turn * max(0, 1 - m / 10)
        }
        let k = max(0, 1 - secs / 1.5)
        t.lat = p.lat + corrLat * k
        t.lon = p.lon + corrLon * k
        return t
    }
}

/// Remembers recent fixes per target to derive course and turn rate when a source doesn't send them.
public final class TargetTracker: @unchecked Sendable {
    public static let shared = TargetTracker()
    private struct Fix {
        var lat: Double; var lon: Double; var bearing: Double?; var time: Date; var turn: Double
        /// Anchor for the actual course: last point ≥ 2 km back, and the course measured from it.
        var aLat: Double; var aLon: Double; var aTime: Date; var move: Double?
    }
    private var last: [String: Fix] = [:]
    /// Last target as delivered to the UI (with its fix time) — to keep motion continuous.
    private var shown: [String: AirTarget] = [:]
    private let lock = NSLock()

    public func update(_ targets: [AirTarget], now: Date = Date()) -> [AirTarget] {
        lock.lock(); defer { lock.unlock() }
        var out: [AirTarget] = []
        var next: [String: Fix] = [:]
        for var t in targets {
            if let f = last[t.id] {
                let dtMin = now.timeIntervalSince(f.time) / 60
                let moved = Geo.distanceKm(lat1: f.lat, lon1: f.lon, lat2: t.lat, lon2: t.lon)
                // Actual course = direction of real movement (source headings are often rounded to 5–45°).
                var aLat = f.aLat, aLon = f.aLon, aTime = f.aTime, move = f.move, turn = f.turn
                let fromAnchor = Geo.distanceKm(lat1: aLat, lon1: aLon, lat2: t.lat, lon2: t.lon)
                if fromAnchor >= 2 {
                    let b = Geo.bearing(lat1: aLat, lon1: aLon, lat2: t.lat, lon2: t.lon)
                    let mins = max(0.05, now.timeIntervalSince(aTime) / 60)
                    if let m0 = move {
                        // Observed turn rate, any size (a shahed can turn all the way round).
                        let rate = Geo.signedAngle(from: m0, to: b) / mins
                        turn = f.turn * 0.3 + rate * 0.7
                    }
                    move = b; aLat = t.lat; aLon = t.lon; aTime = now
                }
                if let m = move, now.timeIntervalSince(aTime) < 240 { t.bearing = m }
                if t.bearing == nil, moved > 1.5 { t.bearing = Geo.bearing(lat1: f.lat, lon1: f.lon, lat2: t.lat, lon2: t.lon) }
                // Turn: dimap's own value when it turns; otherwise what we actually observe.
                if !t.turnKnown || abs(t.turn) < 0.01 { t.turn = turn }
                let keepOld = moved < 0.15 && dtMin < 1
                next[t.id] = keepOld ? Fix(lat: f.lat, lon: f.lon, bearing: f.bearing, time: f.time, turn: turn, aLat: aLat, aLon: aLon, aTime: aTime, move: move)
                                     : Fix(lat: t.lat, lon: t.lon, bearing: t.bearing, time: now, turn: turn, aLat: aLat, aLon: aLon, aTime: aTime, move: move)
            } else {
                next[t.id] = Fix(lat: t.lat, lon: t.lon, bearing: t.bearing, time: now, turn: t.turn, aLat: t.lat, aLon: t.lon, aTime: now, move: nil)
            }
            // Same fix as before → keep its receive time; new fix → start from now, hiding the jump.
            if let prev = shown[t.id], abs(prev.lat - t.lat) < 1e-6, abs(prev.lon - t.lon) < 1e-6, prev.bearing == t.bearing {
                t.fixAt = prev.fixAt; t.corrLat = prev.corrLat; t.corrLon = prev.corrLon; t.turn = prev.turn
            } else {
                if let prev = shown[t.id] {
                    let was = prev.advanced(to: now)
                    let dLat = was.lat - t.lat, dLon = was.lon - t.lon
                    // Only smooth small jumps; a big correction is shown at once.
                    if Geo.distanceKm(lat1: was.lat, lon1: was.lon, lat2: t.lat, lon2: t.lon) < 15 { t.corrLat = dLat; t.corrLon = dLon }
                }
                t.fixAt = now
            }
            shown[t.id] = t
            out.append(t)
        }
        shown = shown.filter { k, _ in next[k] != nil }
        last = next
        return out
    }
}
