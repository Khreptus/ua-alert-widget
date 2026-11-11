import AppKit
import SwiftUI
import Combine

final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Borderless window on the desktop that hosts the live widget.
@MainActor
final class DesktopWidgetController {
    private var panel: DesktopPanel?
    private var bag = Set<AnyCancellable>()
    private let prefs = Prefs.shared

    func setup() {
        prefs.$showDesktopWidget.combineLatest(prefs.$widgetSize, prefs.$widgetScale, prefs.$widgetOnTop)
            .receive(on: RunLoop.main)
            .sink { [weak self] v in self?.apply(show: v.0, size: v.1, scale: v.2, onTop: v.3) }
            .store(in: &bag)
    }

    private func apply(show: Bool, size: WidgetSize, scale: Double, onTop: Bool) {
        guard show else { panel?.orderOut(nil); return }
        let p = panel ?? makePanel()
        let pt = size.size
        let frameSize = NSSize(width: pt.width * scale, height: pt.height * scale)
        var f = p.frame
        f.origin.y += f.size.height - frameSize.height  // keep top-left corner
        f.size = frameSize
        p.setFrame(f, display: true)
        p.level = onTop ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        p.collectionBehavior = onTop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.orderFrontRegardless()
    }

    private func makePanel() -> DesktopPanel {
        let p = DesktopPanel(contentRect: NSRect(x: 0, y: 0, width: 404, height: 422),
                             styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                             backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = DraggableHostingView(rootView: DesktopWidgetRoot().environmentObject(AppModel.shared).environmentObject(Prefs.shared))
        p.setFrameAutosaveName("UAAlertDesktopWidget")
        if !p.setFrameUsingName("UAAlertDesktopWidget"), let screen = NSScreen.main {
            let v = screen.visibleFrame
            p.setFrameTopLeftPoint(NSPoint(x: v.maxX - 430, y: v.maxY - 20))
        }
        panel = p
        return p
    }
}

struct DesktopWidgetRoot: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @State private var showSettings = false

    var body: some View {
        let size = prefs.widgetSize
        let wm = model.widgetModel
        let alarm = wm.isAlarm && size != .large
        AlertWidgetView(
            model: wm, size: size,
            more: AnyView(
                Button { showSettings.toggle() } label: { MoreDots() }
                    .buttonStyle(.plain)
                    .help("Налаштування віджета")
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                        WidgetSettingsPopover().environmentObject(model).environmentObject(prefs)
                    }
            ),
            sirenPlaying: model.sirenPlaying,
            onMute: { model.stopSiren() }
        )
        .frame(width: size.size.width, height: size.size.height)
        .background(AlertWidgetBackground(alarm: alarm))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(alarm ? 0.18 : 0.08), lineWidth: 1))
        .scaleEffect(prefs.widgetScale, anchor: .center)
        .frame(width: size.size.width * prefs.widgetScale, height: size.size.height * prefs.widgetScale)
        .gesture(WindowDragGesture.make())
        .contextMenu {
            Button("Налаштування…") { AppDelegate.shared?.showSettings() }
            Picker("Розмір", selection: $prefs.widgetSize) { ForEach(WidgetSize.allCases) { Text($0.title).tag($0) } }
            Toggle("Поверх вікон", isOn: $prefs.widgetOnTop)
            Divider()
            Button("Сховати віджет") { prefs.showDesktopWidget = false }
        }
    }
}


/// Hosting view that lets the borderless window be dragged by its background.
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Moves the window that contains the view while the user drags anywhere on the widget.
enum WindowDragGesture {
    private static var startMouse: NSPoint = .zero
    private static var startOrigin: NSPoint = .zero
    private static weak var window: NSWindow?

    static func make() -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
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
