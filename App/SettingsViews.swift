import SwiftUI
import ServiceManagement

// MARK: - City picker

struct CityPicker: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var places: [PlaceHit] = []
    @State private var locating = false
    @State private var locError: String?
    var onPick: (() -> Void)? = nil

    private func usePoint(_ lat: Double, _ lon: Double, _ label: String) {
        if prefs.pickPoint(lat: lat, lon: lon, label: label) { model.cityChanged(); onPick?() }
        else { locError = "Ця точка поза межами України." }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Місто, громада або адреса", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.blue.opacity(0.8), lineWidth: 1))

            HStack(spacing: 6) {
                Button { PointPickerWindow.show() } label: {
                    Label("Точка на карті", systemImage: "mappin.and.ellipse").frame(maxWidth: .infinity)
                }
                Button {
                    locating = true; locError = nil
                    MyLocation.shared.request { loc, err in
                        guard let loc else { locating = false; locError = err; return }
                        Task {
                            let n = await Places.name(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
                            locating = false
                            usePoint(loc.coordinate.latitude, loc.coordinate.longitude, n ?? "Моє місце")
                        }
                    }
                } label: {
                    Label(locating ? "Визначаю…" : "Моє місце", systemImage: "location.fill").frame(maxWidth: .infinity)
                }
                .disabled(locating)
            }
            .controlSize(.regular)
            if let locError { Text(locError).font(.system(size: 11)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true) }
            if let p = prefs.customPoint {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(Theme.blue)
                    Text(p.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text("точна точка").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.blue.opacity(0.15)))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !places.isEmpty {
                        Text("Адреси").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 2)
                        ForEach(places) { pl in
                            Button { usePoint(pl.lat, pl.lon, pl.title) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "mappin").foregroundStyle(Theme.blue)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(pl.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        if !pl.subtitle.isEmpty { Text(pl.subtitle).font(.system(size: 11)).opacity(0.7).lineLimit(1) }
                                    }
                                    Spacer()
                                }
                                .foregroundStyle(Theme.text)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        Text("Громади").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 4)
                    }
                    ForEach(GeoStore.shared.search(query, limit: 50)) { h in
                        let selected = h.id == prefs.cityID && prefs.customPoint == nil
                        Button {
                            prefs.pickHromada(h.id)
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
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 3 else { places = []; return }
            try? await Task.sleep(nanoseconds: 450_000_000)
            if Task.isCancelled { return }
            let r = await Places.search(q)
            if !Task.isCancelled { places = Array(r.prefix(5)) }
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
                toggleRow("Повітряні цілі", "dimap · neptun · ukrainealarm", $prefs.showTargets)
                toggleRow("Сирена — тривога", "Коли ваш район зафарбований", $prefs.sirenOnAlert)
                toggleRow("Жовта тривога і дорозвідка", "Жовтим і смугами на карті", $prefs.showThreat)
                row("Карта") {
                    Picker("", selection: $prefs.mapMode) { ForEach(MapMode.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                }
                toggleRow("Компактний рядок", "Наведіть — розгорнеться, клік — закріпити", $prefs.compactMode)
                toggleRow("Сповіщення біля нотча", "Тривога, загроза, відбій — у стилі Dynamic Island", $prefs.notchNotifications)
                toggleRow("Рядок тривоги в нотчі", "Постійно: «Тривога» і таймер, поки триває", $prefs.notchOngoing)
                toggleRow("Бічна панель від краю", "Доведіть курсор до правого краю екрана", $prefs.sidePanelEdge)
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
        case "neptun.in.ua": return "цілі (додатково)"
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
                    Toggle("Повітряні цілі (dimap, neptun, ukrainealarm)", isOn: $prefs.showTargets)
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
