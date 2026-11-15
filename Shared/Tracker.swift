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
    /// Dead-reckoned position `now`: the target keeps flying along its (turning) course since the last fix.
    func advanced(to now: Date, maxMinutes: Double = 4) -> AirTarget {
        guard bearing != nil else { return self }
        let m = min(maxMinutes, max(0, now.timeIntervalSince(lastSeen) / 60))
        guard m > 0.05 else { return self }
        var t = self
        var p = Projection.LL(lat: lat, lon: lon)
        let step = 0.25
        var done = 0.0
        while done < m {
            let dt = min(step, m - done)
            p = Geo.destination(p, km: effectiveSpeed * dt / 60, bearing: Projection.heading(self, at: done + dt / 2, horizon: 10))
            done += dt
        }
        t.lat = p.lat; t.lon = p.lon
        t.bearing = Projection.heading(self, at: m, horizon: 10)
        return t
    }
}

/// Remembers recent fixes per target to derive course and turn rate when a source doesn't send them.
public final class TargetTracker: @unchecked Sendable {
    public static let shared = TargetTracker()
    private struct Fix { var lat: Double; var lon: Double; var bearing: Double?; var time: Date; var turn: Double }
    private var last: [String: Fix] = [:]
    private let lock = NSLock()

    public func update(_ targets: [AirTarget], now: Date = Date()) -> [AirTarget] {
        lock.lock(); defer { lock.unlock() }
        var out: [AirTarget] = []
        var next: [String: Fix] = [:]
        for var t in targets {
            if let f = last[t.id] {
                let dtMin = now.timeIntervalSince(f.time) / 60
                let moved = Geo.distanceKm(lat1: f.lat, lon1: f.lon, lat2: t.lat, lon2: t.lon)
                // Course from movement when the source has none.
                if t.bearing == nil, moved > 1.5 { t.bearing = Geo.bearing(lat1: f.lat, lon1: f.lon, lat2: t.lat, lon2: t.lon) }
                // Turn rate (°/min) from the change of course, smoothed.
                var turn = f.turn
                if let b0 = f.bearing, let b1 = t.bearing, dtMin > 0.05 {
                    let rate = max(-20, min(20, Geo.signedAngle(from: b0, to: b1) / dtMin))
                    turn = f.turn * 0.3 + rate * 0.7
                }
                if t.turn == 0 { t.turn = turn }
                // Keep the previous fix while the target hasn't moved (avoids zero-time deltas).
                let keepOld = moved < 0.15 && dtMin < 1
                next[t.id] = keepOld ? Fix(lat: f.lat, lon: f.lon, bearing: f.bearing, time: f.time, turn: turn)
                                     : Fix(lat: t.lat, lon: t.lon, bearing: t.bearing, time: now, turn: turn)
            } else {
                next[t.id] = Fix(lat: t.lat, lon: t.lon, bearing: t.bearing, time: now, turn: t.turn)
            }
            out.append(t)
        }
        last = next
        return out
    }
}
