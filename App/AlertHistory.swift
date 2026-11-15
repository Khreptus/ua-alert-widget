import Foundation
import SwiftUI

/// Alert episodes for the user's place, recorded by the app itself (sources give no per-city history).
@MainActor
final class AlertHistory: ObservableObject {
    static let shared = AlertHistory()

    struct Episode: Codable, Equatable { var start: Date; var end: Date? }

    struct Stats {
        var dayCount = 0, monthCount = 0
        var dayTime: TimeInterval = 0, monthTime: TimeInterval = 0
        var average: TimeInterval { monthCount > 0 ? monthTime / Double(monthCount) : 0 }
        /// Alert count per day, oldest → today (30 values).
        var bars: [Int] = Array(repeating: 0, count: 30)
        var since: Date?
    }

    @Published private(set) var byCity: [String: [Episode]] = [:]
    private let key = "alertHistory.v1"
    private let started: Date

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: key), let v = try? JSONDecoder().decode([String: [Episode]].self, from: data) { byCity = v }
        if let s = d.object(forKey: "alertHistory.started") as? Date { started = s } else { started = Date(); d.set(started, forKey: "alertHistory.started") }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(byCity) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Called on every refresh with the current status of the place.
    func update(cityID: String, level: AlertLevel, since: Date?) {
        var list = byCity[cityID] ?? []
        let open = list.last.map { $0.end == nil } ?? false
        if level == .alert {
            guard !open else { return }
            let s = since ?? Date()
            // Same episode seen again after a restart: don't double count.
            if let last = list.last, let e = last.end, s <= e.addingTimeInterval(60) { list[list.count - 1].end = nil }
            else { list.append(Episode(start: s, end: nil)) }
        } else {
            guard open else { return }
            list[list.count - 1].end = Date()
        }
        let cutoff = Date().addingTimeInterval(-40 * 86400)
        list.removeAll { ($0.end ?? Date()) < cutoff }
        byCity[cityID] = list
        save()
    }

    func stats(cityID: String, now: Date = Date()) -> Stats {
        var st = Stats()
        st.since = started
        let list = byCity[cityID] ?? []
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let dayFrom = now.addingTimeInterval(-86400), monthFrom = now.addingTimeInterval(-30 * 86400)
        for e in list {
            let end = e.end ?? now
            func overlap(_ from: Date) -> TimeInterval { max(0, end.timeIntervalSince(max(e.start, from))) }
            if end > dayFrom { st.dayCount += 1; st.dayTime += overlap(dayFrom) }
            if end > monthFrom { st.monthCount += 1; st.monthTime += overlap(monthFrom) }
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: e.start), to: today).day ?? 99
            if days >= 0 && days < 30 { st.bars[29 - days] += 1 }
        }
        return st
    }

    static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m < 60 { return "\(m) хв" }
        return m % 60 == 0 ? "\(m / 60) год" : "\(m / 60) год \(m % 60) хв"
    }
}
