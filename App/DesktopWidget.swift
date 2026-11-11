import AppKit
import SwiftUI
import Combine

final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hover / pin state of the compact strip.
@MainActor
final class DesktopUIState: ObservableObject {
    static let shared = DesktopUIState()
    /// Visual state (animated in SwiftUI).
    @Published var expanded = false
    /// Window size state: grows before the expand animation, shrinks after the collapse animation.
    @Published var panelExpanded = false
    @Published var pinned = false
    @Published var settingsOpen = false { didSet { if !settingsOpen { scheduleCollapse() } } }
    private var hovering = false
    private var collapseWork: DispatchWorkItem?
    static let animation = Animation.spring(response: 0.38, dampingFraction: 0.86)

    func hover(_ inside: Bool) {
        hovering = inside
        if inside { collapseWork?.cancel(); expand() } else { scheduleCollapse() }
    }

    func togglePin() {
        pinned.toggle()
        if pinned { expand() } else { scheduleCollapse(delay: 0.1) }
    }

    private func expand() {
        guard !expanded else { return }
        panelExpanded = true
        DispatchQueue.main.async { withAnimation(DesktopUIState.animation) { self.expanded = true } }
    }

    private func scheduleCollapse(delay: Double = 0.45) {
        collapseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering, !self.pinned, !self.settingsOpen, self.expanded else { return }
            withAnimation(DesktopUIState.animation) { self.expanded = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { if !self.expanded { self.panelExpanded = false } }
        }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Transparent margin around the widget so the shadow is never clipped.
    static let shadowPad: CGFloat = 26

    static func contentSize(compact: Bool, expanded: Bool, size: WidgetSize) -> CGSize {
        let full = size.size
        guard compact, !expanded else { return full }
        return CGSize(width: full.width, height: StripContent.height)
    }
}

/// Borderless window on the desktop that hosts the live widget.
@MainActor
final class DesktopWidgetController {
    private var panel: DesktopPanel?
    private var bag = Set<AnyCancellable>()
    private let prefs = Prefs.shared
    private let ui = DesktopUIState.shared

    func setup() {
        prefs.objectWillChange.merge(with: ui.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.apply() } }
            .store(in: &bag)
        apply()
    }

    private func apply() {
        guard prefs.showDesktopWidget else { panel?.orderOut(nil); return }
        let p = panel ?? makePanel()
        let cs = DesktopUIState.contentSize(compact: prefs.compactMode, expanded: ui.panelExpanded, size: prefs.widgetSize)
        let pad = DesktopUIState.shadowPad * 2
        let target = NSSize(width: cs.width * prefs.widgetScale + pad, height: cs.height * prefs.widgetScale + pad)
        if p.frame.size != target {
            var f = p.frame
            f.origin.y += f.size.height - target.height  // keep top-left corner in place
            f.size = target
            p.setFrame(f, display: true, animate: false)
        }
        let onTop = prefs.widgetOnTop
        p.level = onTop ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        p.collectionBehavior = onTop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if !p.isVisible { p.orderFrontRegardless() }
    }

    private func makePanel() -> DesktopPanel {
        let p = DesktopPanel(contentRect: NSRect(x: 0, y: 0, width: 416, height: 88),
                             styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                             backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = DraggableHostingView(rootView: DesktopWidgetRoot()
            .environmentObject(AppModel.shared).environmentObject(Prefs.shared).environmentObject(DesktopUIState.shared))
        if !p.setFrameUsingName("UAAlertDesktopWidget"), let screen = NSScreen.main {
            let v = screen.visibleFrame
            p.setFrameTopLeftPoint(NSPoint(x: v.maxX - 440, y: v.maxY - 8))
        }
        p.setFrameAutosaveName("UAAlertDesktopWidget")
        panel = p
        return p
    }
}

struct DesktopWidgetRoot: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var ui: DesktopUIState

    var body: some View {
        let size = prefs.widgetSize
        let full = size.size
        let compact = prefs.compactMode
        let expanded = !compact || ui.expanded
        let wm = model.widgetModel
        let alarm = wm.isAlarm && (size != .large || !expanded)
        let panel = DesktopUIState.contentSize(compact: compact, expanded: ui.panelExpanded, size: size)
        let radius: CGFloat = expanded ? 22 : StripContent.height / 2

        ZStack(alignment: .top) {
            AlertWidgetView(model: wm, size: size, more: expanded ? moreButton : nil,
                            sirenPlaying: model.sirenPlaying, onMute: { model.stopSiren() })
                .frame(width: full.width, height: full.height)
                .opacity(expanded ? 1 : 0)
                .allowsHitTesting(expanded)
            if compact {
                StripContent(model: wm, width: full.width, sirenPlaying: model.sirenPlaying, onMute: { model.stopSiren() })
                    .opacity(expanded ? 0 : 1)
                    .allowsHitTesting(!expanded)
            }
        }
        .frame(width: full.width, height: expanded ? full.height : StripContent.height, alignment: .top)
        .background(AlertWidgetBackground(alarm: alarm))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(alarm ? 0.18 : 0.08), lineWidth: 1))
        .overlay(alignment: .bottomLeading) {
            if compact && ui.pinned && expanded {
                Image(systemName: "pin.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tertiary)
                    .rotationEffect(.degrees(45)).padding(10).help("Закріплено — клік, щоб згорнути")
            }
        }
        .shadow(color: alarm ? Theme.red.opacity(0.4) : .black.opacity(0.35), radius: 14, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onTapGesture { if compact { ui.togglePin() } }
        .frame(width: panel.width, height: panel.height, alignment: .topLeading)
        .scaleEffect(prefs.widgetScale, anchor: .topLeading)
        .frame(width: panel.width * prefs.widgetScale, height: panel.height * prefs.widgetScale, alignment: .topLeading)
        .padding(DesktopUIState.shadowPad)
        .gesture(WindowDragGesture.make())
        .contextMenu {
            Button("Налаштування…") { AppDelegate.shared?.showSettings() }
            Toggle("Компактний рядок", isOn: $prefs.compactMode)
            Picker("Розмір", selection: $prefs.widgetSize) { ForEach(WidgetSize.allCases) { Text($0.title).tag($0) } }
            Toggle("Поверх вікон", isOn: $prefs.widgetOnTop)
            Divider()
            Button("Сховати віджет") { prefs.showDesktopWidget = false }
        }
    }

    private var moreButton: AnyView {
        AnyView(
            Button { ui.settingsOpen.toggle() } label: { MoreDots() }
                .buttonStyle(.plain)
                .help("Налаштування віджета")
                .popover(isPresented: $ui.settingsOpen, arrowEdge: .bottom) {
                    WidgetSettingsPopover().environmentObject(model).environmentObject(prefs)
                }
        )
    }
}

/// Hosting view: lets the borderless window be dragged and reports hover (works even when the app is inactive).
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    private var area: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        MainActor.assumeIsolated { DesktopUIState.shared.hover(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        MainActor.assumeIsolated { DesktopUIState.shared.hover(false) }
    }
}

/// Moves the desktop window while the user drags anywhere on the widget.
enum WindowDragGesture {
    private static var startMouse: NSPoint = .zero
    private static var startOrigin: NSPoint = .zero
    private static weak var window: NSWindow?

    static func make() -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { _ in
                let mouse = NSEvent.mouseLocation
                if window == nil {
                    window = NSApp.windows.first { $0 is DesktopPanel && $0.frame.contains(mouse) } ?? NSApp.windows.first { $0 is DesktopPanel }
                    startMouse = mouse
                    startOrigin = window?.frame.origin ?? .zero
                }
                guard let w = window else { return }
                w.setFrameOrigin(NSPoint(x: startOrigin.x + mouse.x - startMouse.x, y: startOrigin.y + mouse.y - startMouse.y))
            }
            .onEnded { _ in
                window?.saveFrame(usingName: "UAAlertDesktopWidget")
                window = nil
            }
    }
}
