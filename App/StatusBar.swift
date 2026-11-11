import AppKit
import Combine
import SwiftUI

/// Own menu-bar item + drop-down panel (instead of MenuBarExtra) so the glass and corner radius are fully ours.
@MainActor
final class StatusBarController {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var bag = Set<AnyCancellable>()
    private let model = AppModel.shared

    static let radius: CGFloat = 26

    func setup() {
        if let b = item.button {
            b.target = self
            b.action = #selector(toggle)
            b.imagePosition = .imageLeading
        }
        updateButton()
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateButton() } }
            .store(in: &bag)
    }

    private func updateButton() {
        guard let b = item.button else { return }
        let st = model.status
        let filled = st?.level == .alert || st?.highThreat == true
        let img = NSImage(systemSymbolName: filled ? "light.beacon.max.fill" : "light.beacon.max", accessibilityDescription: "Тривога UA")
        img?.isTemplate = true
        b.image = img
        if st?.level == .alert, let d = Fmt.duration(since: st?.since, now: model.now) {
            b.title = " " + d
        } else {
            b.title = ""
        }
    }

    @objc private func toggle() {
        if let p = panel, p.isVisible { close() } else { open() }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false

        let glass = NSVisualEffectView()
        glass.material = .menu
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.maskImage = StatusBarController.mask(StatusBarController.radius)
        glass.wantsLayer = true

        let host = NSHostingView(rootView: MenuBarContent().environmentObject(AppModel.shared).environmentObject(Prefs.shared))
        host.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            host.topAnchor.constraint(equalTo: glass.topAnchor),
            host.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        // thin rim like Apple's menus
        let rim = RimView(radius: StatusBarController.radius)
        rim.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(rim)
        NSLayoutConstraint.activate([
            rim.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            rim.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            rim.topAnchor.constraint(equalTo: glass.topAnchor),
            rim.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        p.contentView = glass
        return p
    }

    func open() {
        let p = panel ?? makePanel()
        panel = p
        guard let button = item.button, let bw = button.window else { return }
        let size = p.contentView?.fittingSize ?? NSSize(width: 384, height: 480)
        let br = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = bw.screen ?? NSScreen.main
        var x = br.midX - size.width / 2
        if let vf = screen?.visibleFrame { x = min(max(x, vf.minX + 6), vf.maxX - size.width - 6) }
        let y = br.minY - size.height - 6
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.invalidateShadow()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        item.button?.highlight(true)

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.close() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if e.keyCode == 53 { Task { @MainActor in self?.close() }; return nil }
            return e
        }) { monitors.append(l) }
    }

    func close() {
        guard let p = panel, p.isVisible else { return }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        item.button?.highlight(false)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }

    static func mask(_ r: CGFloat) -> NSImage {
        let side = r * 2 + 1
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

private final class RimView: NSView {
    let radius: CGFloat
    init(radius: CGFloat) { self.radius = radius; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        NSColor.white.withAlphaComponent(0.16).setStroke()
        p.lineWidth = 0.5
        p.stroke()
    }
}
