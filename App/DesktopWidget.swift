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
    @Published var expanded = false
    @Published var pinned = false
    @Published var settingsOpen = false { didSet { if !settingsOpen { scheduleCollapse() } } }
    private var hovering = false
    private var collapseWork: DispatchWorkItem?

    func hover(_ inside: Bool) {
        hovering = inside
        if inside {
            collapseWork?.cancel()
            if !expanded { expanded = true }
        } else {
            scheduleCollapse()
        }
    }

    func togglePin() {
        pinned.toggle()
        if pinned { expanded = true } else { scheduleCollapse(delay: 0.1) }
    }

    private func scheduleCollapse(delay: Double = 0.45) {
        collapseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.hovering && !self.pinned && !self.settingsOpen { self.expanded = false }
        }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    static func contentSize(compact: Bool, expanded: Bool, size: WidgetSize) -> CGSize {
        guard compact else { return size.size }
        let strip = StripView.size
        guard expanded else { return strip }
        return CGSize(width: max(strip.width, size.size.width), height: strip.height + 8 + size.size.height)
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
        let cs = DesktopUIState.contentSize(compact: prefs.compactMode, expanded: ui.expanded, size: prefs.widgetSize)
        let target = NSSize(width: cs.width * prefs.widgetScale, height: cs.height * prefs.widgetScale)
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
        let p = DesktopPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 36),
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
            p.setFrameTopLeftPoint(NSPoint(x: v.maxX - 400, y: v.maxY - 16))
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
        let cs = DesktopUIState.contentSize(compact: prefs.compactMode, expanded: ui.expanded, size: size)
        Group {
            if prefs.compactMode {
                VStack(alignment: .leading, spacing: 8) {
                    StripView(model: model.widgetModel, more: moreButton, pinned: ui.pinned, sirenPlaying: model.sirenPlaying, onMute: { model.stopSiren() })
                        .onTapGesture { ui.togglePin() }
                        .help(ui.pinned ? "Клік — згорнути" : "Клік — закріпити відкритим")
                    if ui.expanded { card(size).transition(.opacity) }
                }
            } else {
                card(size)
            }
        }
        .frame(width: cs.width, height: cs.height, alignment: .topLeading)
        .scaleEffect(prefs.widgetScale, anchor: .topLeading)
        .frame(width: cs.width * prefs.widgetScale, height: cs.height * prefs.widgetScale, alignment: .topLeading)
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

    private func card(_ size: WidgetSize) -> some View {
        let wm = model.widgetModel
        let alarm = wm.isAlarm && size != .large
        return AlertWidgetView(model: wm, size: size, more: prefs.compactMode ? nil : moreButton,
                               sirenPlaying: model.sirenPlaying, onMute: { model.stopSiren() })
            .frame(width: size.size.width, height: size.size.height)
            .background(AlertWidgetBackground(alarm: alarm))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(alarm ? 0.18 : 0.08), lineWidth: 1))
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
