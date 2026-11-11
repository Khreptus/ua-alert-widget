import SwiftUI

public enum WidgetSize: String, CaseIterable, Identifiable, Sendable {
    case small, medium, large
    public var id: String { rawValue }
    public var title: String { switch self { case .small: return "S"; case .medium: return "M"; case .large: return "L" } }
    public var size: CGSize {
        switch self {
        case .small: return CGSize(width: 170, height: 170)
        case .medium: return CGSize(width: 364, height: 170)
        case .large: return CGSize(width: 364, height: 382)
        }
    }
}

public struct WidgetModel {
    public var snapshot: Snapshot
    public var city: Hromada?
    public var showTargets: Bool
    public var showThreat: Bool
    public var mode: MapMode
    public var now: Date

    public init(snapshot: Snapshot, city: Hromada?, showTargets: Bool = true, showThreat: Bool = true, mode: MapMode = .raions, now: Date = Date()) {
        self.snapshot = snapshot; self.city = city; self.showTargets = showTargets; self.showThreat = showThreat; self.mode = mode; self.now = now
    }

    public var status: CityStatus? { city.map { snapshot.status(for: $0) } }
    public var isAlarm: Bool { status?.level == .alert }
    public var noData: Bool { snapshot.isEmpty || (!snapshot.sources.isEmpty && snapshot.sources.allSatisfy { !$0.ok }) }
}

// MARK: - Background

public struct AlertWidgetBackground: View {
    let alarm: Bool
    public init(alarm: Bool) { self.alarm = alarm }
    public var body: some View {
        LinearGradient(colors: alarm ? [Theme.alarmTop, Theme.alarmBottom] : [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Root

public struct AlertWidgetView: View {
    let model: WidgetModel
    let size: WidgetSize
    let more: AnyView?
    let onMute: (() -> Void)?
    let sirenPlaying: Bool

    public init(model: WidgetModel, size: WidgetSize, more: AnyView? = nil, sirenPlaying: Bool = false, onMute: (() -> Void)? = nil) {
        self.model = model; self.size = size; self.more = more; self.sirenPlaying = sirenPlaying; self.onMute = onMute
    }

    public var body: some View {
        Group {
            switch size {
            case .small: SmallView(m: model, more: more)
            case .medium: MediumView(m: model, more: more, sirenPlaying: sirenPlaying, onMute: onMute)
            case .large: LargeView(m: model, more: more)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Pieces

struct StateText {
    static func title(_ s: CityStatus?) -> (String, Color) {
        guard let s else { return ("Оберіть місто", Theme.secondary) }
        switch s.level {
        case .alert: return ("Тривога", Theme.red)
        case .threat: return ("Загроза", Theme.amber)
        case .recon: return ("Дорозвідка", Theme.amber)
        case .none: return s.highThreat ? ("Висока загроза", Theme.amber) : ("Спокійно", Theme.green)
        }
    }

    static func subtitle(_ s: CityStatus?, now: Date) -> String {
        guard let s else { return "" }
        if s.level == .alert, let d = Fmt.duration(since: s.since, now: now), let since = s.since { return "з \(Fmt.time(since)) · \(d)" }
        if let km = s.nearestKm, km < 150, s.highThreat { return "\(s.nearestKind?.title ?? "Ціль") за \(Int(km)) км" }
        switch s.level {
        case .threat: return "Дрони / ракети"
        case .recon: return "Перед відбоєм"
        default: return "Тривоги немає"
        }
    }
}

struct LivePill: View {
    let time: Date
    let noData: Bool
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(noData ? Theme.secondary : Theme.red).frame(width: 6, height: 6)
            Text(noData ? "немає даних" : Fmt.time(time)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(noData ? Theme.secondary : Theme.red)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill((noData ? Theme.secondary : Theme.red).opacity(0.14)))
    }
}

struct LegendView: View {
    let showTargets: Bool
    var body: some View {
        HStack(spacing: 10) {
            item(Theme.red, "Тривога")
            item(Theme.amber, "Загроза")
            HStack(spacing: 4) { StripedSwatch(); Text("Дорозвідка").font(.system(size: 11)).foregroundStyle(Theme.secondary) }
            if showTargets {
                HStack(spacing: 4) {
                    TargetGlyph.path(.drone, size: 8).offsetBy(dx: 4, dy: 4).fill(Theme.text).frame(width: 8, height: 8)
                    Text("Ціль").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
        }
    }
    func item(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 7, height: 7); Text(t).font(.system(size: 11)).foregroundStyle(Theme.secondary) }
    }
}

struct CityRow: View {
    let m: WidgetModel
    var body: some View {
        let st = m.status
        HStack(spacing: 8) {
            Circle().fill(color(st)).frame(width: 7, height: 7)
            Text(m.city?.shortName ?? "Оберіть місто").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                .layoutPriority(2)
            ViewThatFits(in: .horizontal) {
                Text(m.city?.raion.replacingOccurrences(of: " район", with: " р-н") ?? "").font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(1)
                Color.clear.frame(width: 0, height: 0)
            }
            .layoutPriority(0)
            Spacer(minLength: 4)
            Text(rightText(st)).font(.system(size: 13, weight: .semibold)).foregroundStyle(color(st)).monospacedDigit().lineLimit(1)
                .fixedSize()
        }
    }
    func color(_ s: CityStatus?) -> Color {
        guard let s else { return Theme.secondary }
        switch s.level { case .alert: return Theme.red; case .threat, .recon: return Theme.amber; case .none: return s.highThreat ? Theme.amber : Theme.green }
    }
    func rightText(_ s: CityStatus?) -> String {
        guard let s else { return "" }
        switch s.level {
        case .alert: return "Тривога" + (Fmt.duration(since: s.since, now: m.now).map { " · \($0)" } ?? "")
        case .threat: return "Загроза · дрони/ракети"
        case .recon: return "Дорозвідка"
        case .none: return s.highThreat ? "Висока загроза" : "Тривоги немає"
        }
    }
}

struct SirenIcon: View {
    var size: CGFloat = 16
    var body: some View {
        Image(systemName: "light.beacon.max.fill").font(.system(size: size * 0.9, weight: .semibold))
    }
}

// MARK: - Small

struct SmallView: View {
    let m: WidgetModel
    let more: AnyView?
    var body: some View {
        let st = m.status
        let (title, color) = StateText.title(st)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                if m.isAlarm {
                    SirenIcon(size: 18).foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(Circle().fill(.white.opacity(0.18)))
                } else {
                    HStack(spacing: 5) {
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text(m.city?.shortName ?? "—").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 2)
                if let more { more }
            }
            if m.isAlarm {
                Spacer(minLength: 0)
                Text("ТРИВОГА").font(.system(size: 24, weight: .heavy)).kerning(1).foregroundStyle(.white)
                Text(m.city?.displayName ?? "").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                Text(StateText.subtitle(st, now: m.now)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            } else {
                Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(color).padding(.top, 2).lineLimit(1).minimumScaleFactor(0.7)
                Text(StateText.subtitle(st, now: m.now)).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer(minLength: 4)
                UAMapView(snapshot: m.snapshot, city: m.city, showTargets: m.showTargets, showThreat: m.showThreat, mode: m.mode)
            }
        }
        .padding(16)
    }
}

// MARK: - Medium

struct MediumView: View {
    let m: WidgetModel
    let more: AnyView?
    let sirenPlaying: Bool
    let onMute: (() -> Void)?
    var body: some View {
        let st = m.status
        let (title, color) = StateText.title(st)
        let sum = m.snapshot.summary()
        HStack(spacing: 12) {
            UAMapView(snapshot: m.snapshot, city: m.city, showTargets: m.showTargets, showThreat: m.showThreat, mode: m.mode, pinColor: m.isAlarm ? .white : Theme.blue)
                .frame(width: 190)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    if m.isAlarm { SirenIcon(size: 15).foregroundStyle(.white) } else { Circle().fill(color).frame(width: 7, height: 7) }
                    Text(m.isAlarm ? "Сирена" : (m.city?.shortName ?? "Тривоги")).font(.system(size: 13, weight: .semibold)).foregroundStyle(m.isAlarm ? .white : Theme.text).lineLimit(1)
                    Spacer(minLength: 2)
                    if let more { more }
                }
                Spacer(minLength: 4)
                Text(title).font(.system(size: m.isAlarm ? 28 : 24, weight: m.isAlarm ? .heavy : .bold)).foregroundStyle(m.isAlarm ? .white : color).lineLimit(1).minimumScaleFactor(0.6)
                Text(m.isAlarm ? "\(m.city?.displayName ?? "") · \(StateText.subtitle(st, now: m.now))" : StateText.subtitle(st, now: m.now))
                    .font(.system(size: 12, weight: m.isAlarm ? .medium : .regular)).foregroundStyle(m.isAlarm ? .white.opacity(0.85) : Theme.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if m.isAlarm, sirenPlaying, let onMute {
                    Button(action: onMute) {
                        HStack(spacing: 6) {
                            Image(systemName: "speaker.slash.fill").font(.system(size: 11, weight: .semibold))
                            Text("Вимкнути звук").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Color(hex: 0xB3140F))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(.white))
                    }.buttonStyle(.plain)
                } else {
                    Text("По країні: \(sum.alertRaions) \(Fmt.plural(sum.alertRaions, "район", "райони", "районів"))\(m.showTargets && sum.targets > 0 ? " · \(sum.targets) цілей" : "")")
                        .font(.system(size: 11)).foregroundStyle(m.isAlarm ? .white.opacity(0.7) : Theme.tertiary).lineLimit(1)
                }
            }
        }
        .padding(.leading, 12).padding([.trailing, .vertical], 16)
    }
}

// MARK: - Large

struct LargeView: View {
    let m: WidgetModel
    let more: AnyView?
    var body: some View {
        let sum = m.snapshot.summary()
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Повітряні тривоги").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(summaryLine(sum)).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 6)
                HStack(spacing: 8) {
                    LivePill(time: m.snapshot.updated, noData: m.noData)
                    if let more { more }
                }
            }
            UAMapView(snapshot: m.snapshot, city: m.city, showTargets: m.showTargets, showThreat: m.showThreat, mode: m.mode, pinColor: m.isAlarm ? Theme.red : Theme.blue)
                .frame(maxWidth: .infinity)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            CityRow(m: m)
            HStack { Spacer(); LegendView(showTargets: m.showTargets) }
        }
        .padding(16)
    }

    func summaryLine(_ s: Snapshot.Summary) -> String {
        var parts = ["\(s.alertRaions) \(Fmt.plural(s.alertRaions, "район", "райони", "районів"))"]
        if m.showThreat { parts.append("\(s.threatRaions) загроза") }
        if m.showTargets { parts.append("\(s.targets) \(Fmt.plural(s.targets, "ціль", "цілі", "цілей"))") }
        return parts.joined(separator: " · ")
    }
}

/// "⋯" button look (shared between app and widget).
public struct MoreDots: View {
    public init() {}
    public var body: some View {
        Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.85))
            .frame(width: 24, height: 24).background(Circle().fill(.white.opacity(0.10)))
            .contentShape(Circle())
    }
}

// MARK: - Compact strip (content only — the container draws the background)

public struct StripContent: View {
    let m: WidgetModel
    let width: CGFloat
    let sirenPlaying: Bool
    let onMute: (() -> Void)?

    public static let height: CGFloat = 36

    public init(model: WidgetModel, width: CGFloat, sirenPlaying: Bool = false, onMute: (() -> Void)? = nil) {
        self.m = model; self.width = width; self.sirenPlaying = sirenPlaying; self.onMute = onMute
    }

    public var body: some View {
        let st = m.status
        let alarm = m.isAlarm
        let (title, color) = StateText.title(st)
        let sum = m.snapshot.summary()
        let roomy = width >= 300
        HStack(spacing: 8) {
            if alarm || st?.highThreat == true {
                SirenIcon(size: 14).foregroundStyle(alarm ? .white : Theme.amber)
            } else if st?.level == .recon {
                StripedSwatch().scaleEffect(1.2)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            if roomy {
                Text(m.city?.shortName ?? "Оберіть місто")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(alarm ? .white : Theme.text).lineLimit(1)
            }
            Text(alarm ? (Fmt.duration(since: st?.since, now: m.now).map { "Тривога · \($0)" } ?? "Тривога") : title)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(alarm ? .white : color).lineLimit(1).monospacedDigit()
                .fixedSize()
            Spacer(minLength: 4)
            if alarm, sirenPlaying, let onMute {
                Button(action: onMute) { Image(systemName: "speaker.slash.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(hex: 0xB3140F)).frame(width: 24, height: 22).background(Capsule().fill(.white)) }
                    .buttonStyle(.plain).help("Вимкнути звук")
            } else if roomy {
                Text("\(sum.alertRaions) р-н\(m.showTargets ? " · \(sum.targets) ц." : "")")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(alarm ? .white.opacity(0.75) : Theme.tertiary).monospacedDigit().lineLimit(1)
            }
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(alarm ? .white.opacity(0.7) : Theme.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(width: width, height: StripContent.height)
        .environment(\.colorScheme, .dark)
    }
}
