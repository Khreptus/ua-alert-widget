import AppKit
import SwiftUI

@main
struct UAAlertApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    @StateObject private var prefs = Prefs.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent().environmentObject(model).environmentObject(prefs)
        } label: {
            MenuBarLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private let desktop = DesktopWidgetController()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)
        AppModel.shared.start()
        desktop.setup()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls where u.scheme == "uaalert" {
            if u.host == "mute" { AppModel.shared.stopSiren() } else { showSettings() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return true
    }

    func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Тривога UA — налаштування"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView().environmentObject(AppModel.shared).environmentObject(Prefs.shared))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let st = model.status
        let alarm = st?.level == .alert
        HStack(spacing: 3) {
            Image(systemName: alarm || st?.highThreat == true ? "light.beacon.max.fill" : "light.beacon.max")
            if alarm, let d = Fmt.duration(since: st?.since, now: model.now) { Text(d).monospacedDigit() }
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        let wm = model.widgetModel
        VStack(spacing: 10) {
            AlertWidgetView(model: wm, size: .large, more: nil, sirenPlaying: model.sirenPlaying, onMute: { model.stopSiren() })
                .frame(width: 364, height: 382)
                .background(AlertWidgetBackground(alarm: false))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if model.sirenPlaying {
                Button { model.stopSiren() } label: { Label("Вимкнути сирену", systemImage: "speaker.slash.fill").frame(maxWidth: .infinity) }
                    .controlSize(.large).buttonStyle(.borderedProminent).tint(Theme.red)
            }
            HStack {
                Toggle("Віджет на столі", isOn: $prefs.showDesktopWidget).toggleStyle(.switch).controlSize(.small)
                Spacer()
                Button("Налаштування…") { AppDelegate.shared?.showSettings() }
                Button("Вийти") { NSApp.terminate(nil) }
            }
            .font(.system(size: 12))
        }
        .padding(12)
        .environment(\.colorScheme, .dark)
    }
}
