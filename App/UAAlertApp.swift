import AppKit
import CoreServices
import SwiftUI
import WidgetKit

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
        // Make sure LaunchServices knows this bundle (and its widget extension) so the widget shows up in the gallery.
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        WidgetCenter.shared.reloadAllTimelines()
        AppModel.shared.start()
        desktop.setup()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Only opens settings. Never let an external link silence the siren or change settings.
        if urls.contains(where: { $0.scheme == "uaalert" }) { showSettings() }
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

/// Menu-bar window styled like Apple's own menu extras (Bluetooth, Wi-Fi): system material, no inner card.
struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @Environment(\.openURL) private var openURL

    var body: some View {
        let wm = model.widgetModel
        let sum = wm.snapshot.summary()
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Повітряні тривоги").font(.system(size: 13, weight: .bold))
                Spacer()
                LivePill(time: wm.snapshot.updated, noData: wm.noData)
            }
            .padding(.horizontal, 14).padding(.top, 8)
            Text(summary(sum, wm)).font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 1)

            UAMapView(snapshot: wm.snapshot, city: wm.city, showTargets: wm.showTargets, showThreat: wm.showThreat, mode: wm.mode,
                      pinColor: wm.isAlarm ? Theme.red : Theme.blue)
                .padding(.horizontal, 12).padding(.vertical, 8)

            CityRow(m: wm).padding(.horizontal, 14)
            HStack { Spacer(); LegendView(showTargets: wm.showTargets) }.padding(.horizontal, 14).padding(.top, 6)

            MenuSeparator()
            if model.sirenPlaying {
                MenuRow(title: "Вимкнути сирену", systemImage: "speaker.slash.fill", tint: Theme.red) { model.stopSiren() }
            }
            MenuToggleRow(title: "Віджет на робочому столі", isOn: $prefs.showDesktopWidget)
            MenuRow(title: "Офіційний сайт", trailing: "arrow.up.right") { openURL(URL(string: "https://map.ukrainealarm.com/")!) }
            MenuSeparator()
            MenuRow(title: "Налаштування…") { AppDelegate.shared?.showSettings() }
            MenuRow(title: "Вийти з UA Alert") { NSApp.terminate(nil) }
        }
        .padding(.vertical, 6)
        .frame(width: 340)
    }

    private func summary(_ s: Snapshot.Summary, _ m: WidgetModel) -> String {
        var parts = ["\(s.alertRaions) \(Fmt.plural(s.alertRaions, "район", "райони", "районів"))"]
        if m.showThreat { parts.append("\(s.threatRaions) загроза") }
        if m.showTargets { parts.append("\(s.targets) \(Fmt.plural(s.targets, "ціль", "цілі", "цілей"))") }
        return parts.joined(separator: " · ")
    }
}

struct MenuSeparator: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1).padding(.horizontal, 14).padding(.vertical, 5)
    }
}

/// A row that highlights on hover like a native menu item.
struct MenuRow: View {
    let title: String
    var systemImage: String? = nil
    var trailing: String? = nil
    var tint: Color? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).frame(width: 16) }
                Text(title).font(.system(size: 13))
                Spacer()
                if let trailing { Image(systemName: trailing).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
            }
            .foregroundStyle(tint ?? .primary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hover ? Color.primary.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.horizontal, 6)
    }
}

struct MenuToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 3)
    }
}
