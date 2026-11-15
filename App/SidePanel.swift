import AppKit
import SwiftUI

/// Full-height panel that slides in from the right edge of the screen.
@MainActor
final class SidePanelController: ObservableObject {
    static let shared = SidePanelController()

    @Published var pinned = false
    @Published private(set) var visible = false

    static let width: CGFloat = 400
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var edgeSince: Date?
    private var hideWork: DispatchWorkItem?

    func start() {
        let handler: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.mouseMoved() } }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { e in handler(e); return e }) { monitors.append(l) }
        if let k = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if e.keyCode == 53, MainActor.assumeIsolated({ self?.visible == true }) { MainActor.assumeIsolated { self?.hide() }; return nil }
            return e
        }) { monitors.append(k) }
    }

    private var screen: NSScreen? {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main
    }

    private func mouseMoved() {
        let m = NSEvent.mouseLocation
        guard let s = screen else { return }
        // Edge trigger: pointer pressed against the right edge (below the menu bar) for a moment.
        if Prefs.shared.sidePanelEdge, !visible, m.x >= s.frame.maxX - 2, m.y < s.visibleFrame.maxY - 4, m.y > s.frame.minY + 40 {
            if edgeSince == nil { edgeSince = Date() }
            if let t = edgeSince, Date().timeIntervalSince(t) > 0.25 { edgeSince = nil; show() }
        } else {
            edgeSince = nil
        }
        // Auto-hide when the pointer leaves (unless pinned).
        if visible, !pinned, let p = panel {
            if p.frame.insetBy(dx: -24, dy: -24).contains(m) { hideWork?.cancel(); hideWork = nil }
            else if hideWork == nil {
                let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hideWork = nil; self?.hide() } }
                hideWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
            }
        }
    }

    private func frames(_ s: NSScreen) -> (shown: NSRect, hidden: NSRect) {
        let v = s.visibleFrame
        let shown = NSRect(x: v.maxX - Self.width - 8, y: v.minY + 8, width: Self.width, height: v.height - 16)
        var hidden = shown; hidden.origin.x = s.frame.maxX + 20
        return (shown, hidden)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        let root = SidePanelView()
            .environmentObject(AppModel.shared).environmentObject(Prefs.shared)
            .environmentObject(AlertHistory.shared).environmentObject(self)
        p.contentView = NSHostingView(rootView: root)
        return p
    }

    func toggle() { visible ? hide() : show() }

    func show() {
        guard let s = screen else { return }
        if panel == nil { panel = makePanel() }
        guard let p = panel else { return }
        let f = frames(s)
        if !visible { p.setFrame(f.hidden, display: false) }
        p.orderFrontRegardless()
        visible = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            p.animator().setFrame(f.shown, display: true)
        }
    }

    func hide() {
        guard let p = panel, visible, let s = p.screen ?? screen else { return }
        visible = false
        hideWork?.cancel(); hideWork = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().setFrame(frames(s).hidden, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { if self?.visible == false { p.orderOut(nil) } }
        })
    }
}

// MARK: - Content

struct SidePanelView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var history: AlertHistory
    @EnvironmentObject var ctl: SidePanelController

    var body: some View {
        let st = model.status
        ZStack {
            VisualEffect().clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(hex: 0x1C1C1F).opacity(0.55))
            RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    StatusCard(st: st)
                    UAMapView(snapshot: model.snapshot, city: model.city, showTargets: prefs.showTargets, showThreat: prefs.showThreat, mode: prefs.mapMode,
                              pinColor: model.status?.level == .alert ? Theme.red : Theme.blue)
                        .background(Color(hex: 0x111113))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    ThreatsList()
                    CounterCard()
                    CountryStats()
                    footer
                }
                .padding(16)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 24, height: 24)
            Text("Тривога UA").font(.system(size: 15, weight: .semibold))
            Spacer()
            LivePill(time: model.snapshot.updated, noData: model.snapshot.isEmpty)
            Button { ctl.pinned.toggle() } label: {
                Image(systemName: ctl.pinned ? "pin.fill" : "pin").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ctl.pinned ? Theme.blue : .white.opacity(0.7))
                    .frame(width: 26, height: 22).background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
            }.buttonStyle(.plain).help(ctl.pinned ? "Відкріпити" : "Закріпити панель")
            Button { ctl.hide() } label: {
                Image(systemName: "chevron.right.2").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                    .frame(width: 26, height: 22).background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
            }.buttonStyle(.plain).help("Сховати (Esc)")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { AppDelegate.shared?.showSettings() } label: {
                Label("Налаштування", systemImage: "gearshape").font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
            }.buttonStyle(.plain)
            Link(destination: URL(string: "https://dimap.live/")!) {
                Text("Відкрити dimap.live ↗").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.blue))
            }
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

private struct StatusCard: View {
    @EnvironmentObject var model: AppModel
    let st: CityStatus?

    var body: some View {
        let level = st?.level ?? .none
        let alarm = level == .alert
        let (title, color) = StateText.title(st)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if alarm { SirenIcon(size: 13).foregroundStyle(.white) } else { Circle().fill(color).frame(width: 7, height: 7) }
                Text(placeLine).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            }
            Text(alarm ? "ТРИВОГА" : title).font(.system(size: alarm ? 30 : 26, weight: .bold)).foregroundStyle(alarm ? .white : color)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(alarm ? 0.75 : 0.6)).lineLimit(1)
            if alarm && model.sirenPlaying {
                Button { model.stopSiren() } label: {
                    Label("Вимкнути звук", systemImage: "speaker.slash.fill").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xB3140F)).padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(.white))
                }.buttonStyle(.plain).padding(.top, 6)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(alarm
                ? AnyShapeStyle(LinearGradient(colors: [Theme.alarmTop, Theme.alarmBottom], startPoint: .top, endPoint: .bottom))
                : AnyShapeStyle(Color.white.opacity(0.06)))
        )
    }

    private var placeLine: String {
        guard let c = model.city else { return "Оберіть місто" }
        return c.label != nil ? c.displayName : "\(c.displayName) · \(c.raion)"
    }

    private var subtitle: String {
        guard let st else { return "" }
        let base = StateText.subtitle(st, now: model.now)
        return st.level == .alert ? "\(base) · \(model.city?.raion ?? "")" : base
    }
}

private struct ThreatsList: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs

    struct Row: Identifiable { let id: String; let t: AirTarget; let km: Double; let eta: Double? }

    var rows: [Row] {
        guard let c = model.city, prefs.showTargets else { return [] }
        return model.snapshot.targets.map { t in
            Row(id: t.id, t: t, km: Geo.distanceKm(lat1: c.lat, lon1: c.lon, lat2: t.lat, lon2: t.lon), eta: Projection.eta(t, toLat: c.lat, lon: c.lon))
        }
        .filter { $0.km < 150 || ($0.eta ?? 999) <= 30 }
        .sorted { ($0.eta ?? 1000 + $0.km) < ($1.eta ?? 1000 + $1.km) }
        .prefix(4).map { $0 }
    }

    var body: some View {
        let list = rows
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Загрози для вас").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(list.isEmpty ? "немає цілей поблизу" : "\(list.count) \(Fmt.plural(list.count, "ціль", "цілі", "цілей")) до 150 км")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            }
            if !list.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, r in
                        let col = r.eta.map { $0 <= 15 ? Color(hex: 0xFF453A) : Color(hex: 0xFF9F0A) } ?? Color(hex: 0xFFD60A)
                        if i > 0 { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
                        HStack(spacing: 10) {
                            TargetIcon(kind: r.t.kind, size: 14, bearing: r.t.bearing ?? 0)
                                .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 9).fill(col.opacity(0.16)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.t.model.map { "\(r.t.kind.title) · \($0)" } ?? r.t.kind.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(detail(r)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(r.eta.map { "~" + Fmt.eta($0) } ?? "—").font(.system(size: 15, weight: .semibold)).foregroundStyle(col)
                                Text(r.eta == nil ? "повз" : "підліт").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
            }
        }
    }

    private func detail(_ r: Row) -> String {
        guard let c = model.city else { return "" }
        let b = Geo.bearing(lat1: c.lat, lon1: c.lon, lat2: r.t.lat, lon2: r.t.lon)
        let dirs = ["на півночі", "на північному сході", "на сході", "на південному сході", "на півдні", "на південному заході", "на заході", "на північному заході"]
        let d = dirs[Int(((b + 22.5).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 45) % 8]
        let count = r.t.count > 1 ? " · ×\(r.t.count)" : ""
        return r.eta != nil ? "\(Int(r.km)) км · курс на вас\(count)" : "\(Int(r.km)) км \(d)\(count)"
    }
}

private struct CounterCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var history: AlertHistory

    var body: some View {
        let s = model.city.map { history.stats(cityID: $0.id, now: model.now) } ?? AlertHistory.Stats()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Тривоги · \(model.city?.displayName ?? "")").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text("30 днів").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
            HStack(alignment: .top, spacing: 16) {
                kpi("\(s.dayCount)", "за добу", s.dayCount > 0 ? "\(AlertHistory.duration(s.dayTime)) у тривозі" : "без тривог")
                kpi("\(s.monthCount)", "за місяць", s.monthCount > 0 ? "\(AlertHistory.duration(s.monthTime)) · у сер. \(AlertHistory.duration(s.average))" : "—")
            }
            let maxV = max(1, s.bars.max() ?? 1)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<30, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i == 29 ? Color(hex: 0xFF453A) : Theme.mapRed.opacity(s.bars[i] == 0 ? 0.25 : 0.85))
                        .frame(height: max(3, CGFloat(s.bars[i]) / CGFloat(maxV) * 32))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 34, alignment: .bottom)
            HStack {
                Text(Self.day.string(from: Date().addingTimeInterval(-29 * 86400))).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                Spacer()
                if let since = s.since, Date().timeIntervalSince(since) < 30 * 86400 {
                    Text("рахую з \(Self.day.string(from: since))").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                    Spacer()
                }
                Text("сьогодні").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.05)))
    }

    static let day: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "uk_UA"); f.dateFormat = "d MMM"; return f }()

    private func kpi(_ n: String, _ l: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(n).font(.system(size: 22, weight: .bold))
                Text(l).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
            Text(sub).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CountryStats: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let s = model.snapshot.summary()
        HStack(spacing: 8) {
            tile("\(s.alertRaions)", Fmt.plural(s.alertRaions, "район у тривозі", "райони в тривозі", "районів у тривозі"), Color(hex: 0xFF6B5E))
            tile("\(s.threatRaions)", "загроза", Color(hex: 0xE0A84E))
            tile("\(s.targets)", "цілей у повітрі", .white)
        }
    }
    private func tile(_ n: String, _ l: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(n).font(.system(size: 22, weight: .bold)).foregroundStyle(c)
            Text(l).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
    }
}
