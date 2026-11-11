import Foundation
import SwiftUI
import UserNotifications
import WidgetKit

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var sirenPlaying = false
    @Published var now = Date()

    let prefs = Prefs.shared
    private let aggregator = Aggregator()
    private let siren = Siren()
    private var timer: Timer?
    private var clock: Timer?
    private var refreshing = false

    private var lastLevel: AlertLevel?
    private var lastHigh = false
    private var lastCityID = ""
    private var lastWidgetReload = Date.distantPast

    var city: Hromada? { prefs.city }
    var status: CityStatus? { city.map { snapshot.status(for: $0) } }

    var widgetModel: WidgetModel {
        WidgetModel(snapshot: snapshot, city: city, showTargets: prefs.showTargets, showThreat: prefs.showThreat, mode: prefs.mapMode, now: now)
    }

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        clock = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        var snap = await aggregator.fetch()
        applyTimedRecon(&snap)
        // keep previous data if every source failed
        if snap.sources.allSatisfy({ !$0.ok }), !snapshot.isEmpty {
            var s = snapshot; s.sources = snap.sources
            snapshot = s
        } else {
            snapshot = snap
        }
        now = Date()
        evaluate()
    }

    // MARK: Доразвідка by time: a raion stays "recon" for 15 min after its red alert ends
    private var prevRaionLevels: [String: AlertLevel] = [:]
    private var alertEnded: [String: Date] = [:]

    private func applyTimedRecon(_ s: inout Snapshot) {
        guard !s.sources.allSatisfy({ !$0.ok }) else { return }
        let now = Date()
        var cur: [String: AlertLevel] = [:]
        for r in GeoStore.shared.raions {
            let l = s.raionState(r.name, oblast: r.oblast).level
            cur[r.name] = l
            if prevRaionLevels[r.name] == .alert && l < .alert { alertEnded[r.name] = now }
            if l == .alert { alertEnded[r.name] = nil }
            if l == .none, let t = alertEnded[r.name], now.timeIntervalSince(t) < 15 * 60 {
                s.raions[r.name] = RegionAlert(level: .recon, since: t)
            }
        }
        alertEnded = alertEnded.filter { now.timeIntervalSince($0.value) < 15 * 60 }
        prevRaionLevels = cur
    }

    /// Compare city status with the previous one → siren / notifications.
    private func evaluate() {
        guard let city, let st = status else { return }
        if city.id != lastCityID {
            // City changed: just remember state, no siren.
            lastCityID = city.id; lastLevel = st.level; lastHigh = st.highThreat
            reloadWidgets(force: true)
            return
        }
        defer { lastLevel = st.level; lastHigh = st.highThreat }
        guard let prev = lastLevel else { return }

        if st.level == .alert && prev != .alert {
            notify(title: "🔴 Повітряна тривога — \(city.displayName)", body: "\(city.raion) · \(Fmt.time(Date())). Пройдіть в укриття.")
            if prefs.sirenOnAlert { playSiren() }
            reloadWidgets(force: true)
        } else if st.level == .threat && prev < .threat {
            if prefs.sirenOnThreat { playSiren() }
            if prefs.bannerOnThreat || prefs.sirenOnThreat {
                notify(title: "🟡 Загроза дронів / ракет — \(city.displayName)", body: city.raion, silent: !prefs.sirenOnThreat)
            }
            reloadWidgets(force: true)
        } else if st.level == .recon && prev > .recon {
            stopSiren()
            if prefs.notifyRecon { notify(title: "Доразвідка — \(city.displayName)", body: "Тривогу знято, триває доразвідка. Не поспішайте виходити з укриття.", silent: true) }
            reloadWidgets(force: true)
        } else if st.level == .none && prev != .none {
            stopSiren()
            if prev >= .threat || prev == .recon {
                notify(title: "Відбій — \(city.displayName)", body: city.raion, silent: true)
                if prefs.chimeOnClear { siren.play(.chime, seconds: 1, volume: prefs.volume * 0.7) }
            }
            reloadWidgets(force: true)
        } else if st.highThreat && !lastHigh {
            let dist = st.nearestKm.map { " · \(Int($0)) км" } ?? ""
            notify(title: "Висока загроза — \(city.displayName)", body: "\(st.nearestKind?.title ?? "Ціль") рухається в бік міста\(dist)")
            if prefs.sirenOnHighThreat && !sirenPlaying { playSiren() }
        }
        reloadWidgets(force: false)
    }

    private func reloadWidgets(force: Bool) {
        if force || Date().timeIntervalSince(lastWidgetReload) > 120 {
            lastWidgetReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func playSiren() {
        siren.play(.siren, seconds: prefs.sirenSeconds, volume: prefs.volume)
        sirenPlaying = true
        DispatchQueue.main.asyncAfter(deadline: .now() + prefs.sirenSeconds + 0.2) { [weak self] in
            guard let self else { return }
            if !self.siren.isPlaying { self.sirenPlaying = false }
        }
    }

    func stopSiren() {
        siren.stop()
        sirenPlaying = false
    }

    func testSiren() {
        if sirenPlaying { stopSiren(); return }
        siren.play(.siren, seconds: 4, volume: prefs.volume)
        sirenPlaying = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) { [weak self] in self?.sirenPlaying = false }
    }

    func cityChanged() {
        lastCityID = ""
        evaluate()
        objectWillChange.send()
    }

    private func notify(title: String, body: String, silent: Bool = false) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if !silent && !sirenPlaying { c.sound = .default }
        c.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
