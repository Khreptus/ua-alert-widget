import SwiftUI
import AppKit

public enum MapMode: String, CaseIterable, Identifiable, Sendable {
    case raions, oblasts
    public var id: String { rawValue }
    public var title: String { self == .raions ? "Райони" : "Області" }
}

public enum Theme {
    public static let red = Color(hex: 0xFF453A)
    public static let amber = Color(hex: 0xFF9F0A)
    public static let green = Color(hex: 0x30D158)
    public static let blue = Color(hex: 0x0A84FF)
    /// Colours below adapt to light / dark appearance (the desktop widget forces dark).
    public static let idle = dyn(0x2C2C2F, 0xD5D5DA)
    public static let raionBorder = dyn(0x141416, 0xF4F4F6)
    public static let oblastBorder = dyn(0x0B0B0D, 0xFFFFFF)
    public static let text = Color(nsColor: .labelColor)
    public static let secondary = Color(nsColor: .secondaryLabelColor)
    public static let tertiary = Color(nsColor: .tertiaryLabelColor)
    public static let bgTop = Color(hex: 0x222225)
    public static let bgBottom = Color(hex: 0x141416)
    public static let alarmTop = Color(hex: 0xD7261E)
    public static let alarmBottom = Color(hex: 0x8E1410)

    public static func dyn(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let h = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: 1)
        })
    }

    public static func color(_ l: AlertLevel, showThreat: Bool = true) -> Color {
        switch l {
        case .alert: return red
        case .threat: return showThreat ? amber : idle
        case .recon: return showThreat ? amber.opacity(0.3) : idle
        case .none: return idle
        }
    }
}

public extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

public struct UAMapView: View {
    let snapshot: Snapshot
    let city: Hromada?
    var showTargets: Bool
    var showThreat: Bool
    var mode: MapMode
    var pinColor: Color

    public init(snapshot: Snapshot, city: Hromada?, showTargets: Bool = true, showThreat: Bool = true, mode: MapMode = .raions, pinColor: Color = Theme.blue) {
        self.snapshot = snapshot; self.city = city; self.showTargets = showTargets; self.showThreat = showThreat; self.mode = mode; self.pinColor = pinColor
    }

    public var body: some View {
        let geo = GeoStore.shared
        Canvas { ctx, size in
            let s = size.width / geo.width
            let tf = CGAffineTransform(scaleX: s, y: s)

            // Oblast-level aggregate (for "Області" mode)
            var oblastLevel: [String: AlertLevel] = [:]
            if mode == .oblasts {
                for r in geo.raions {
                    let l = snapshot.raionState(r.name, oblast: r.oblast).level
                    if l > (oblastLevel[r.oblast] ?? .none) { oblastLevel[r.oblast] = l }
                }
            }
            for r in geo.raions {
                let level = mode == .raions ? snapshot.raionState(r.name, oblast: r.oblast).level : (oblastLevel[r.oblast] ?? .none)
                let p = r.path.applying(tf)
                ctx.fill(p, with: .color(Theme.color(level, showThreat: showThreat)))
                if level == .recon && showThreat { Stripes.draw(in: ctx, path: p, scale: s) }
                if mode == .raions { ctx.stroke(p, with: .color(Theme.raionBorder), lineWidth: max(0.35, 0.8 * s)) }
            }
            ctx.stroke(geo.oblastBorders.applying(tf), with: .color(Theme.oblastBorder), style: StrokeStyle(lineWidth: max(0.7, 1.6 * s), lineJoin: .round))

            // Kyiv city
            let kyiv = geo.project(lat: 50.45, lon: 30.52).applying(tf)
            let kyivLevel = snapshot.cities["м. Київ"]?.level ?? .none
            let kr = max(2.5, 5 * s)
            ctx.fill(Path(ellipseIn: CGRect(x: kyiv.x - kr, y: kyiv.y - kr, width: kr * 2, height: kr * 2)), with: .color(kyivLevel == .recon ? Theme.amber : Theme.color(kyivLevel, showThreat: showThreat)))
            ctx.stroke(Path(ellipseIn: CGRect(x: kyiv.x - kr, y: kyiv.y - kr, width: kr * 2, height: kr * 2)), with: .color(Theme.oblastBorder), lineWidth: 1)

            // Air targets
            if showTargets {
                let sz = max(5.5, min(9, 13 * s))
                for t in snapshot.targets {
                    let p = geo.project(lat: t.lat, lon: t.lon).applying(tf)
                    guard p.x > -10, p.y > -10, p.x < size.width + 10, p.y < size.height + 10 else { continue }
                    var c = ctx
                    c.translateBy(x: p.x, y: p.y)
                    c.rotate(by: .degrees(t.bearing ?? 0))
                    let shape = TargetGlyph.path(t.kind, size: sz)
                    c.fill(shape, with: .color(TargetGlyph.color(t.kind)))
                    c.stroke(shape, with: .color(.black.opacity(0.85)), lineWidth: 0.8)
                }
            }

            // City pin
            if let city {
                let p = geo.project(lat: city.lat, lon: city.lon).applying(tf)
                let halo = max(7, 12 * s)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - halo, y: p.y - halo, width: halo * 2, height: halo * 2)), with: .color(pinColor.opacity(0.28)))
                let core = max(3, 4.5 * s)
                let rect = CGRect(x: p.x - core, y: p.y - core, width: core * 2, height: core * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(.white))
                ctx.stroke(Path(ellipseIn: rect), with: .color(pinColor), lineWidth: max(1.5, 2.5 * s))
            }
        }
        .aspectRatio(geo.width / geo.height, contentMode: .fit)
        .accessibilityLabel("Карта тривог України")
    }
}

public enum TargetGlyph {
    /// Glyph pointing "up" (north), centred at 0,0.
    public static func path(_ k: TargetKind, size s: CGFloat) -> Path {
        var p = Path()
        let h = s / 2
        switch k {
        case .drone, .unknown:
            p.move(to: CGPoint(x: 0, y: -h)); p.addLine(to: CGPoint(x: h * 0.85, y: h * 0.8)); p.addLine(to: CGPoint(x: 0, y: h * 0.45)); p.addLine(to: CGPoint(x: -h * 0.85, y: h * 0.8)); p.closeSubpath()
        case .missile, .ballistic:
            p.move(to: CGPoint(x: 0, y: -h))
            p.addQuadCurve(to: CGPoint(x: h * 0.28, y: -h * 0.2), control: CGPoint(x: h * 0.28, y: -h * 0.75))
            p.addLine(to: CGPoint(x: h * 0.28, y: h * 0.4)); p.addLine(to: CGPoint(x: h * 0.55, y: h)); p.addLine(to: CGPoint(x: -h * 0.55, y: h)); p.addLine(to: CGPoint(x: -h * 0.28, y: h * 0.4)); p.addLine(to: CGPoint(x: -h * 0.28, y: -h * 0.2))
            p.addQuadCurve(to: CGPoint(x: 0, y: -h), control: CGPoint(x: -h * 0.28, y: -h * 0.75))
            p.closeSubpath()
        case .aircraft:
            p.move(to: CGPoint(x: 0, y: -h)); p.addLine(to: CGPoint(x: h * 0.15, y: -h * 0.2)); p.addLine(to: CGPoint(x: h, y: h * 0.15)); p.addLine(to: CGPoint(x: h, y: h * 0.35)); p.addLine(to: CGPoint(x: h * 0.15, y: h * 0.2)); p.addLine(to: CGPoint(x: h * 0.35, y: h)); p.addLine(to: CGPoint(x: -h * 0.35, y: h)); p.addLine(to: CGPoint(x: -h * 0.15, y: h * 0.2)); p.addLine(to: CGPoint(x: -h, y: h * 0.35)); p.addLine(to: CGPoint(x: -h, y: h * 0.15)); p.addLine(to: CGPoint(x: -h * 0.15, y: -h * 0.2)); p.closeSubpath()
        }
        return p
    }

    public static func color(_ k: TargetKind) -> Color {
        switch k {
        case .drone, .unknown: return .white
        case .missile: return Color(hex: 0xFFD60A)
        case .ballistic: return Color(hex: 0xFF6B6B)
        case .aircraft: return Color(hex: 0x64D2FF)
        }
    }
}


/// Diagonal amber stripes for "доразвідка".
public enum Stripes {
    public static func draw(in ctx: GraphicsContext, path p: Path, scale s: CGFloat) {
        var c = ctx
        c.clip(to: p)
        let b = p.boundingRect
        let step = max(3, 7 * s)
        var stripes = Path()
        var x = b.minX - b.height
        while x < b.maxX {
            stripes.move(to: CGPoint(x: x, y: b.maxY))
            stripes.addLine(to: CGPoint(x: x + b.height, y: b.minY))
            x += step
        }
        c.stroke(stripes, with: .color(Theme.amber), lineWidth: max(1, 2.4 * s))
    }
}

/// Small legend swatch with stripes.
public struct StripedSwatch: View {
    public init() {}
    public var body: some View {
        Canvas { ctx, size in
            let p = Path(ellipseIn: CGRect(origin: .zero, size: size))
            ctx.fill(p, with: .color(Theme.amber.opacity(0.3)))
            Stripes.draw(in: ctx, path: p, scale: 0.35)
        }
        .frame(width: 8, height: 8)
    }
}
