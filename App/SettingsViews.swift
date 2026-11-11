import SwiftUI
import ServiceManagement

// MARK: - City picker

struct CityPicker: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    var onPick: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Місто або громада", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.blue.opacity(0.8), lineWidth: 1))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(GeoStore.shared.search(query, limit: 50)) { h in
                        let selected = h.id == prefs.cityID
                        Button {
                            prefs.cityID = h.id
                            model.cityChanged()
                            onPick?()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(h.displayName).font(.system(size: 13, weight: .medium))
                                    Text("\(h.raion) · \(h.oblast)").font(.system(size: 11)).opacity(0.7)
                                }
                                Spacer()
                                if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)) }
                            }
                            .foregroundStyle(selected ? .white : Theme.text)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.blue : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Popover (⋯)

struct WidgetSettingsPopover: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var model: AppModel
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if picking {
                HStack {
                    Button { picking = false } label: { Label("Назад", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(Theme.blue)
                    Spacer()
                    Text("Мій город").font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                CityPicker(onPick: { picking = false }).frame(height: 320)
            } else {
                Text("Налаштування віджета").font(.system(size: 13, weight: .semibold)).padding(.bottom, 4)
                Button { picking = true } label: {
                    row("Мій город") {
                        HStack(spacing: 4) {
                            Text(prefs.city?.displayName ?? "—").foregroundStyle(Theme.secondary).lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                        }
                    }
                }.buttonStyle(.plain)
                toggleRow("Повітряні цілі", "dimap.live + ukrainealarm", $prefs.showTargets)
                toggleRow("Сирена — тривога", "Масштабна (червона)", $prefs.sirenOnAlert)
                toggleRow("Сирена — загроза", "Дрони / ракети (жовта)", $prefs.sirenOnThreat)
                toggleRow("Загроза і дорозвідка", "Жовтим і смугами на карті", $prefs.showThreat)
                row("Карта") {
                    Picker("", selection: $prefs.mapMode) { ForEach(MapMode.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                }
                toggleRow("Компактний рядок", "Наведіть — розгорнеться, клік — закріпити", $prefs.compactMode)
                row("Розмір") {
                    Picker("", selection: $prefs.widgetSize) { ForEach(WidgetSize.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                }
                Divider().padding(.vertical, 4)
                Text("Джерела").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary).padding(.horizontal, 8)
                SourcesList()
                Divider().padding(.vertical, 4)
                Button { AppDelegate.shared?.showSettings() } label: {
                    Text("Усі налаштування…").foregroundStyle(Theme.blue).padding(.horizontal, 8).padding(.vertical, 4)
                }.buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 280)
        .environment(\.colorScheme, .dark)
    }

    func row<R: View>(_ title: String, @ViewBuilder right: () -> R) -> some View {
        HStack { Text(title).font(.system(size: 13, weight: .medium)); Spacer(); right() }
            .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
    }

    func toggleRow(_ title: String, _ sub: String, _ b: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(sub).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Toggle("", isOn: b).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }
}

struct SourcesList: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.snapshot.sources.isEmpty {
                Text("Завантаження…").font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(.horizontal, 8)
            }
            ForEach(model.snapshot.sources) { s in
                HStack(spacing: 8) {
                    Circle().fill(s.ok ? Theme.green : Theme.amber).frame(width: 7, height: 7)
                    Text(s.name).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(s.ok ? role(s.name) : s.detail).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, 8)
            }
        }
    }
    func role(_ n: String) -> String {
        switch n {
        case "ukrainealarm": return "тривоги · цілі"
        case "dimap.live": return "загрози · цілі"
        default: return "тривоги (резерв)"
        }
    }
}

// MARK: - Full settings window

struct SettingsView: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        TabView {
            CityPicker().padding(16)
                .tabItem { Label("Мій город", systemImage: "mappin.and.ellipse") }

            Form {
                Section("Сирена") {
                    Toggle("🔴 Сирена при масштабній тривозі", isOn: $prefs.sirenOnAlert)
                    Toggle("🟡 Сирена при загрозі дронів / ракет", isOn: $prefs.sirenOnThreat)
                    Toggle("🟡 Банер при загрозі (без звуку)", isOn: $prefs.bannerOnThreat)
                    Toggle("Банер про дорозвідку перед відбоєм", isOn: $prefs.notifyRecon)
                    Toggle("Тихий сигнал при відбої", isOn: $prefs.chimeOnClear)
                    Text("Сирена звучить лише коли ваш район зафарбовується на карті, і ніколи — коли Mac у режимі сну.").font(.caption).foregroundStyle(.secondary)
                    HStack { Text("Гучність"); Slider(value: $prefs.volume, in: 0...1) }
                    Picker("Тривалість сирени", selection: $prefs.sirenSeconds) {
                        Text("10 с").tag(10.0); Text("30 с").tag(30.0); Text("1 хв").tag(60.0); Text("2 хв").tag(120.0)
                    }
                    Button(model.sirenPlaying ? "Зупинити" : "Перевірити звук") { model.testSiren() }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Сирена", systemImage: "light.beacon.max") }

            Form {
                Section("Віджет на робочому столі") {
                    Toggle("Показувати віджет", isOn: $prefs.showDesktopWidget)
                    Toggle("Компактний рядок (розгортається при наведенні, клік — закріпити)", isOn: $prefs.compactMode)
                    Picker("Розмір", selection: $prefs.widgetSize) { Text("Малий").tag(WidgetSize.small); Text("Середній").tag(WidgetSize.medium); Text("Великий").tag(WidgetSize.large) }
                    Picker("Масштаб", selection: $prefs.widgetScale) { Text("100%").tag(1.0); Text("125%").tag(1.25); Text("150%").tag(1.5) }
                    Toggle("Поверх усіх вікон", isOn: $prefs.widgetOnTop)
                }
                Section("Карта") {
                    Picker("Деталізація", selection: $prefs.mapMode) { ForEach(MapMode.allCases) { Text($0.title).tag($0) } }
                    Toggle("Повітряні цілі (dimap.live + ukrainealarm)", isOn: $prefs.showTargets)
                    Toggle("Зони загрози (жовтим)", isOn: $prefs.showThreat)
                }
                Section("Система") {
                    Toggle("Запускати при вході в систему", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, on in
                            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                            catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                        }
                }
                Section("Джерела даних") { SourcesList() }
            }
            .formStyle(.grouped)
            .tabItem { Label("Віджет", systemImage: "rectangle.on.rectangle") }
        }
        .frame(width: 520, height: 520)
    }
}
