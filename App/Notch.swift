import AppKit
import SwiftUI

/// Dynamic-island style notifications that grow out of the MacBook notch (or the top centre on other screens).
@MainActor
final class NotchController: ObservableObject {
    static let shared = NotchController()

    enum Kind: Equatable { case alert, threat, recon, clear }

    struct Card: Equatable {
        var kind: Kind
        var title: String
        var subtitle: String
        var eta: String? = nil
        var target: TargetKind? = nil
    }

    @Published private(set) var card: Card?
    /// Start of the ongoing alert → compact island with a timer.
    @Published private(set) var ongoingSince: Date?
    @Published private(set) var expanded = false
    @Published private(set) var notchSize = CGSize(width: 190, height: 32)

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var hovering = false

    static let bigWidth: CGFloat = 460
    static let bigBody: CGFloat = 72
    static let compactWing: CGFloat = 92

    // MARK: API

    func show(_ c: Card, seconds: Double = 9) {
        guard Prefs.shared.notchNotifications else { return }
        card = c
        expanded = true
        layout(animated: true)
        scheduleCollapse(after: seconds)
    }

    private var rawOngoing: Date?

    func setOngoing(_ since: Date?) {
        rawOngoing = since
        refreshOngoing()
    }

    /// The persistent "Тривога · timer" strip is optional (off by default): only pop-up notifications otherwise.
    func refreshOngoing() {
        let v = Prefs.shared.notchNotifications && Prefs.shared.notchOngoing ? rawOngoing : nil
        guard ongoingSince != v else { return }
        ongoingSince = v
        if !expanded { layout(animated: true) }
    }

    func hover(_ on: Bool) {
        hovering = on
        if on, ongoingSince != nil, !expanded {
            if card == nil, let city = Prefs.shared.city {
                card = Card(kind: .alert, title: "Повітряна тривога", subtitle: city.displayName)
            }
            expanded = true
            layout(animated: true)
        } else if !on, expanded {
            scheduleCollapse(after: 1.2)
        }
    }

    func dismiss() {
        expanded = false
        card = nil
        layout(animated: true)
    }

    // MARK: Layout

    private func scheduleCollapse(after s: Double) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.hovering else { return }
                self.expanded = false
                self.layout(animated: true)
            }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func measureNotch(_ s: NSScreen) -> CGSize {
        let h = s.safeAreaInsets.top > 0 ? s.safeAreaInsets.top : NSStatusBar.system.thickness
        if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea, s.safeAreaInsets.top > 0 {
            return CGSize(width: s.frame.width - l.width - r.width, height: h)
        }
        return CGSize(width: 0, height: h)   // no notch: island appears below the menu bar centre
    }

    private func targetSize() -> CGSize? {
        if expanded, card != nil { return CGSize(width: Self.bigWidth, height: notchSize.height + Self.bigBody) }
        if ongoingSince != nil { return CGSize(width: max(notchSize.width, 160) + Self.compactWing * 2, height: notchSize.height) }
        return nil
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        let v = HoverHostingView(rootView: NotchIsland().environmentObject(self).environmentObject(AppModel.shared))
        v.onHover = { [weak self] on in self?.hover(on) }
        p.contentView = v
        return p
    }

    func layout(animated: Bool) {
        guard let s = screen else { return }
        notchSize = measureNotch(s)
        let base = CGSize(width: max(notchSize.width, 120), height: notchSize.height)
        let shadowPad: CGFloat = 24
        guard let size = targetSize() else {
            if let p = panel, p.isVisible {
                let r = rect(base, in: s, pad: shadowPad)
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = animated ? 0.28 : 0
                    p.animator().setFrame(r, display: true)
                    p.animator().alphaValue = 0
                }, completionHandler: { MainActor.assumeIsolated { p.orderOut(nil); p.alphaValue = 1 } })
            }
            return
        }
        if panel == nil { panel = makePanel() }
        guard let p = panel else { return }
        if !p.isVisible {
            p.setFrame(rect(base, in: s, pad: shadowPad), display: false)
            p.alphaValue = 1
            p.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.38 : 0
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.25, 0.35, 1)
            p.animator().setFrame(rect(size, in: s, pad: shadowPad), display: true)
        }
    }

    private func rect(_ size: CGSize, in s: NSScreen, pad: CGFloat) -> NSRect {
        let f = s.frame
        return NSRect(x: f.midX - size.width / 2 - pad, y: f.maxY - size.height - pad, width: size.width + pad * 2, height: size.height + pad)
    }
}

final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds.insetBy(dx: 24, dy: 0), options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(a); area = a
    }
    override func mouseEntered(with event: NSEvent) { MainActor.assumeIsolated { onHover?(true) } }
    override func mouseExited(with event: NSEvent) { MainActor.assumeIsolated { onHover?(false) } }
}

struct NotchIsland: View {
    @EnvironmentObject var n: NotchController
    @EnvironmentObject var model: AppModel

    private func color(_ k: NotchController.Kind) -> Color {
        switch k {
        case .alert: return Color(hex: 0xFF453A)
        case .threat: return Color(hex: 0xFF453A)
        case .recon: return Color(hex: 0xFF453A)
        case .clear: return Color(hex: 0x30D158)
        }
    }

    var body: some View {
        GeometryReader { g in
            let pad: CGFloat = 24
            let w = g.size.width - pad * 2
            let h = g.size.height - pad
            let big = n.expanded && n.card != nil
            ZStack(alignment: .top) {
                let shape = UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: big ? 30 : 14, bottomTrailing: big ? 30 : 14, topTrailing: 0), style: .continuous)
                shape.fill(.black)
                    .shadow(color: .black.opacity(big ? 0.5 : 0), radius: 18, y: 8)
                if big, let c = n.card {
                    // Thin accent outline (per Figma).
                    shape.strokeBorder(color(c.kind), lineWidth: 1.2)
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.62), .init(color: .white, location: 0.9)],
                                             startPoint: .top, endPoint: .bottom))
                }
                if big, let c = n.card { expandedBody(c) } else if n.ongoingSince != nil { compactBody }
            }
            .frame(width: w, height: h)
            .position(x: g.size.width / 2, y: h / 2)
            .contentShape(Rectangle())
            .onTapGesture { SidePanelController.shared.show(sticky: true); n.dismiss() }
        }
        .preferredColorScheme(.dark)
    }

    private var compactBody: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(color(.alert)).frame(width: 8, height: 8)
                Text("Тривога").font(.system(size: 12, weight: .semibold)).foregroundStyle(color(.alert))
            }
            .padding(.leading, 16)
            Spacer(minLength: 0)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(timer(ctx.date)).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.9))
            }
            .padding(.trailing, 16)
        }
        .frame(height: n.notchSize.height)
    }

    private func timer(_ now: Date) -> String {
        guard let s = n.ongoingSince else { return "" }
        let t = Int(max(0, now.timeIntervalSince(s)))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    private func expandedBody(_ c: NotchController.Card) -> some View {
        let col = color(c.kind)
        return VStack(spacing: 0) {
            Color.clear.frame(height: n.notchSize.height)
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(col.opacity(0.2))
                    switch c.kind {
                    case .alert: SirenIcon(size: 18).foregroundStyle(col)
                    case .clear: DoneRing(color: col).frame(width: 24, height: 24)
                    case .recon: Image(systemName: "binoculars.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(col)
                    case .threat: TargetIcon(kind: c.target ?? .shahed, size: 18)
                    }
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(c.subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 4)
                if c.kind == .alert, model.sirenPlaying {
                    Button { model.stopSiren() } label: {
                        Label("Тихо", systemImage: "speaker.slash.fill").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(col))
                    }.buttonStyle(.plain)
                } else if let eta = c.eta {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(eta).font(.system(size: 22, weight: .bold)).foregroundStyle(col)
                        Text("підліт").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
            Capsule().fill(col).frame(width: 60, height: 3).padding(.bottom, 6)
        }
    }
}

/// Duotone "done" ring from the Figma mockup.
struct DoneRing: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.125, dy: size.height * 0.125)
            ctx.fill(Path(ellipseIn: r), with: .color(Color(hex: 0x7E869E).opacity(0.25)))
            ctx.stroke(Path(ellipseIn: r), with: .color(color), lineWidth: 1.4)
            var p = Path()
            p.move(to: CGPoint(x: size.width * 0.34, y: size.height * 0.5))
            p.addLine(to: CGPoint(x: size.width * 0.45, y: size.height * 0.62))
            p.addLine(to: CGPoint(x: size.width * 0.68, y: size.height * 0.38))
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}
