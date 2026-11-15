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
    /// Map fills (user palette).
    public static let mapRed = Color(hex: 0xA53029)
    public static let mapAmber = Color(hex: 0xBC8734)
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
        case .alert: return mapRed
        case .threat: return showThreat ? mapAmber : idle
        case .recon: return showThreat ? mapAmber.opacity(0.3) : idle
        case .none: return idle
        }
    }
}

public extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// Global switches for map interaction. The widget extension leaves `enabled` off (WidgetKit is static).
public enum MapInteraction {
    public static var enabled = false
    /// True while the pointer pressed on a zoomed map: the desktop window must not move then.
    public static var blockWindowDrag = false
}

public struct UAMapView: View {
    let snapshot: Snapshot
    let city: Hromada?
    var showTargets: Bool
    var showThreat: Bool
    var mode: MapMode
    var pinColor: Color
    /// When set, a click on the map reports the point (lat, lon) instead of zooming.
    var onPick: ((Double, Double) -> Void)? = nil
    /// Initial view: centre (lat, lon) and zoom.
    var focus: (lat: Double, lon: Double, zoom: CGFloat)? = nil
    /// Square frame; the map fills it (cropped at the sides, pan to see them).
    var square: Bool = false

    @State private var selected: String? = nil
    @State private var didFocus = false
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize? = nil
    @Environment(\.colorScheme) private var scheme

    /// Up to street level (raster tile zoom ≈ 15).
    static let maxZoom: CGFloat = 900

    public init(snapshot: Snapshot, city: Hromada?, showTargets: Bool = true, showThreat: Bool = true, mode: MapMode = .raions, pinColor: Color = Theme.blue,
                onPick: ((Double, Double) -> Void)? = nil, focus: (lat: Double, lon: Double, zoom: CGFloat)? = nil, square: Bool = false) {
        self.square = square
        self.snapshot = snapshot; self.city = city; self.showTargets = showTargets; self.showThreat = showThreat; self.mode = mode; self.pinColor = pinColor
        self.onPick = onPick; self.focus = focus
    }

    public var body: some View {
        let geo = GeoStore.shared
        GeometryReader { gp in
            let size = gp.size
            ZStack(alignment: .topTrailing) {
                if MapInteraction.enabled && zoom > 1.4 {
                    let detail = max(0, min(1, (Double(zoom) - 1.4) / 1.6))
                    BasemapView(view: basemapView(size: size), dark: scheme == .dark)
                        .opacity(detail)
                        .allowsHitTesting(false)
                }
                canvas(size: size)
                if let sel = selected, let t = snapshot.targets.first(where: { $0.id == sel }) {
                    let k = baseScale(size) * zoom
                    let p = GeoStore.shared.project(lat: t.lat, lon: t.lon)
                    let sp = CGPoint(x: p.x * k + offset.width, y: p.y * k + offset.height)
                    TargetInfoCard(t: t, city: city) { withAnimation(.snappy(duration: 0.2)) { selected = nil } }
                        .fixedSize()
                        .position(x: min(max(sp.x, 120), size.width - 120), y: sp.y > size.height / 2 ? sp.y - 90 : sp.y + 90)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
                if MapInteraction.enabled && zoom > 1.6 {
                    Text("© OpenFreeMap · © OpenMapTiles · © OpenStreetMap")
                        .font(.system(size: 7.5)).foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(Capsule().fill(.black.opacity(0.35)))
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .allowsHitTesting(false)
                }
                if MapInteraction.enabled {
                    MapEventCatcher(
                        onScroll: { e, loc in handleScroll(e, at: CGPoint(x: loc.x * size.width, y: loc.y * size.height), size: size) },
                        onMagnify: { m, loc in applyZoom(by: 1 + m, at: CGPoint(x: loc.x * size.width, y: loc.y * size.height), size: size) },
                        isZoomed: { zoom > 1.001 }
                    )
                    .allowsHitTesting(false)
                    if zoom > 1.01 {
                        Button { withAnimation(.snappy(duration: 0.3)) { zoom = 1; offset = home(size) } } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(.black.opacity(0.55)))
                                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .help("Скинути масштаб")
                        .padding(4)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(panGesture(size: size), including: MapInteraction.enabled && zoom > 1.001 ? .all : .subviews)
            .gesture(SpatialTapGesture(coordinateSpace: .local).onEnded { v in
                let loc = v.location
                guard let onPick else {
                    // Click on a target → info card; elsewhere → close it.
                    let k = baseScale(size) * zoom
                    let hit = snapshot.targets
                        .map { t -> (String, CGFloat) in
                            let p = GeoStore.shared.project(lat: t.lat, lon: t.lon)
                            return (t.id, hypot(p.x * k + offset.width - loc.x, p.y * k + offset.height - loc.y))
                        }
                        .filter { $0.1 < 16 }.min { $0.1 < $1.1 }
                    withAnimation(.snappy(duration: 0.2)) { selected = hit?.0 }
                    return
                }
                let s = baseScale(size)
                let m = CGPoint(x: (loc.x - offset.width) / (s * zoom), y: (loc.y - offset.height) / (s * zoom))
                let ll = GeoStore.shared.unproject(m)
                onPick(ll.lat, ll.lon)
            }, including: onPick != nil || (MapInteraction.enabled && showTargets) ? .all : .subviews)
            .onAppear {
                if square, focus == nil, !didFocus, size.width > 0 { didFocus = true; offset = home(size); return }
                guard let focus, !didFocus, size.width > 0 else { return }
                didFocus = true
                let s = baseScale(size)
                let p = GeoStore.shared.project(lat: focus.lat, lon: focus.lon)
                zoom = focus.zoom
                offset = clamp(CGSize(width: size.width / 2 - p.x * s * zoom, height: size.height / 2 - p.y * s * zoom), zoom: zoom, size: size)
            }
            .onTapGesture(count: 2) {
                guard MapInteraction.enabled, onPick == nil else { return }
                withAnimation(.snappy(duration: 0.3)) {
                    if zoom > 1.01 { zoom = 1; offset = home(size) } else { applyZoom(by: 2.5, at: CGPoint(x: size.width / 2, y: size.height / 2), size: size) }
                }
            }
        }
        .aspectRatio(square ? 1 : geo.width / geo.height, contentMode: .fit)
        .clipped()
        .accessibilityLabel("Карта тривог України")
    }

    // MARK: zoom / pan

    /// Map units → points at zoom 1 (fit by width, or cover the square).
    private func baseScale(_ size: CGSize) -> CGFloat {
        let g = GeoStore.shared
        return square ? max(size.width / g.width, size.height / g.height) : size.width / g.width
    }

    private func clamp(_ o: CGSize, zoom z: CGFloat, size: CGSize) -> CGSize {
        let g = GeoStore.shared, k = baseScale(size) * z
        let cw = g.width * k, ch = g.height * k
        func axis(_ v: CGFloat, _ view: CGFloat, _ content: CGFloat) -> CGFloat {
            content <= view ? (view - content) / 2 : min(0, max(view - content, v))
        }
        return CGSize(width: axis(o.width, size.width, cw), height: axis(o.height, size.height, ch))
    }

    private func home(_ size: CGSize) -> CGSize {
        let g = GeoStore.shared, k = baseScale(size)
        return clamp(CGSize(width: (size.width - g.width * k) / 2, height: (size.height - g.height * k) / 2), zoom: 1, size: size)
    }

    private func applyZoom(by factor: CGFloat, at p: CGPoint, size: CGSize) {
        let nz = min(Self.maxZoom, max(1, zoom * factor))
        guard nz != zoom else { return }
        let r = nz / zoom
        let o = CGSize(width: p.x - (p.x - offset.width) * r, height: p.y - (p.y - offset.height) * r)
        zoom = nz
        offset = clamp(o, zoom: nz, size: size)
    }

    private func handleScroll(_ e: NSEvent, at p: CGPoint, size: CGSize) {
        if e.hasPreciseScrollingDeltas && !e.modifierFlags.contains(.command) && !e.modifierFlags.contains(.option) {
            // Trackpad: two-finger scroll pans a zoomed map.
            offset = clamp(CGSize(width: offset.width + e.scrollingDeltaX, height: offset.height + e.scrollingDeltaY), zoom: zoom, size: size)
        } else {
            // Mouse wheel (or ⌘/⌥ + trackpad scroll): zoom around the pointer.
            let f: CGFloat = e.hasPreciseScrollingDeltas
                ? pow(1.015, max(-40, min(40, e.scrollingDeltaY)))
                : pow(1.4, max(-3, min(3, e.scrollingDeltaY)))
            applyZoom(by: f, at: p, size: size)
        }
    }

    private func panGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragStart == nil { dragStart = offset }
                let s = dragStart ?? offset
                offset = clamp(CGSize(width: s.width + v.translation.width, height: s.height + v.translation.height), zoom: zoom, size: size)
            }
            .onEnded { _ in dragStart = nil }
    }

    // MARK: drawing

    /// Centre and MapLibre zoom matching the current zoom/offset.
    private func basemapView(size: CGSize) -> (lat: Double, lon: Double, zoom: Double) {
        let geo = GeoStore.shared
        let k = baseScale(size) * zoom
        let c = CGPoint(x: (size.width / 2 - offset.width) / k, y: (size.height / 2 - offset.height) / k)
        let ll = geo.unproject(c)
        // MapLibre: 512 px world at zoom 0; ours: 256 px world → z = log2(points per 256-px world) − 1.
        let mz = log2(geo.unitsPerWorldPixel * Double(k)) - 1
        return (ll.lat, ll.lon, mz)
    }

    private func canvas(size _: CGSize) -> some View {
        let geo = GeoStore.shared
        let z = zoom, off = offset
        // Basemap fades in from ×1.4 to ×3.
        let detail: Double = MapInteraction.enabled ? max(0, min(1, (Double(z) - 1.4) / 1.6)) : 0
        let now = Date()
        return Canvas { ctx, size in
            let s = baseScale(size)
            let tf = CGAffineTransform(scaleX: s * z, y: s * z).concatenating(CGAffineTransform(translationX: off.width, y: off.height))
            let lw = s * min(2.2, pow(z, 0.25))      // line-width scale: grows gently with zoom
            func pt(_ lat: Double, _ lon: Double) -> CGPoint { geo.project(lat: lat, lon: lon).applying(tf) }
            let view = CGRect(origin: .zero, size: size).insetBy(dx: -30, dy: -30)


            var oblastLevel: [String: AlertLevel] = [:]
            if mode == .oblasts {
                for r in geo.raions {
                    let l = snapshot.raionState(r.name, oblast: r.oblast).level
                    if l > (oblastLevel[r.oblast] ?? .none) { oblastLevel[r.oblast] = l }
                }
            }
            let hi = z >= 2.2
            for r in geo.raions {
                let p = (hi ? r.pathHi : r.path).applying(tf)
                guard p.boundingRect.intersects(view) else { continue }
                let level = mode == .raions ? snapshot.raionState(r.name, oblast: r.oblast).level : (oblastLevel[r.oblast] ?? .none)
                let fillOpacity = level == .none || (!showThreat && level < .alert) ? 1 - detail : 1 - 0.58 * detail
                if fillOpacity > 0.01 { ctx.fill(p, with: .color(Theme.color(level, showThreat: showThreat).opacity(fillOpacity))) }
                if level == .recon && showThreat { var c = ctx; c.opacity = 1 - 0.5 * detail; Stripes.draw(in: c, path: p, scale: lw) }
                if mode == .raions { ctx.stroke(p, with: .color(Theme.raionBorder.opacity(1 - 0.6 * detail)), style: StrokeStyle(lineWidth: max(0.35, 0.7 * lw), lineCap: .round, lineJoin: .round)) }
            }
            // Cities with their own status (Kyiv, Sevastopol): filled outline.
            for c in geo.cities {
                let p = (hi ? c.pathHi : c.path).applying(tf)
                guard p.boundingRect.intersects(view) else { continue }
                let level = snapshot.cities[c.name]?.level ?? .none
                let col = level == .recon ? Theme.mapAmber : Theme.color(level, showThreat: showThreat)
                let op = level == .none ? 1 - detail : 1 - 0.58 * detail
                if op > 0.01 { ctx.fill(p, with: .color(col.opacity(op))) }
                ctx.stroke(p, with: .color(Theme.raionBorder.opacity(1 - 0.6 * detail)), lineWidth: max(0.35, 0.8 * lw))
            }
            ctx.stroke((hi ? geo.oblastBordersHi : geo.oblastBorders).applying(tf), with: .color(Theme.oblastBorder.opacity(1 - 0.35 * detail)), style: StrokeStyle(lineWidth: max(0.7, 1.4 * lw), lineCap: .round, lineJoin: .round))

            // Kyiv city dot (only while the city outline is too small to see)
            if z < 3 {
            let kyiv = pt(50.45, 30.52)
            let kyivLevel = snapshot.cities["м. Київ"]?.level ?? .none
            let kr = max(2.5, 5 * lw)
            let kRect = CGRect(x: kyiv.x - kr, y: kyiv.y - kr, width: kr * 2, height: kr * 2)
            ctx.fill(Path(ellipseIn: kRect), with: .color(kyivLevel == .recon ? Theme.mapAmber : Theme.color(kyivLevel, showThreat: showThreat)))
            ctx.stroke(Path(ellipseIn: kRect), with: .color(Theme.oblastBorder), lineWidth: 1)
            }

            // Air targets: flight cones first (under everything), then icons.
            if showTargets {
                // Positions exactly as reported by dimap (the site doesn't extrapolate either).
                let targets = snapshot.targets
                let lineScale = max(0.8, min(1.6, sqrt(z)))
                for t in targets {
                    guard t.bearing != nil else { continue }
                    let v = t.effectiveSpeed
                    // dimap: 10-minute look-ahead (ballistics kept to a readable length).
                    let minutes = v > 1500 ? min(10, 250 / v * 60) : 10
                    guard let cone = Projection.cone(t, minutes: minutes) else { continue }
                    let start = pt(t.lat, t.lon)
                    guard view.contains(start) || cone.center.contains(where: { view.contains(pt($0.lat, $0.lon)) }) else { continue }
                    let col = TargetGlyph.coneColor(speed: v)
                    let L = cone.left.map { pt($0.lat, $0.lon) }, R = cone.right.map { pt($0.lat, $0.lon) }, Cc = cone.center.map { pt($0.lat, $0.lon) }
                    guard let lEnd = L.last, let rEnd = R.last, let cEnd = Cc.last else { continue }
                    // Far edge: an arc through the tip of the course line.
                    let ctrl = CGPoint(x: 2 * cEnd.x - (lEnd.x + rEnd.x) / 2, y: 2 * cEnd.y - (lEnd.y + rEnd.y) / 2)
                    var poly = Path()
                    poly.move(to: start)
                    for q in L { poly.addLine(to: q) }
                    poly.addQuadCurve(to: rEnd, control: ctrl)
                    for q in R.reversed() { poly.addLine(to: q) }
                    poly.closeSubpath()
                    ctx.fill(poly, with: .linearGradient(Gradient(colors: [col.opacity(0.30), col.opacity(0.10)]), startPoint: start, endPoint: cEnd))
                    // Dashed sides and far arc.
                    var edges = Path()
                    edges.move(to: start); for q in L { edges.addLine(to: q) }
                    edges.addQuadCurve(to: rEnd, control: ctrl)
                    for q in R.reversed() { edges.addLine(to: q) }
                    edges.addLine(to: start)
                    ctx.stroke(edges, with: .color(col.opacity(0.8)), style: StrokeStyle(lineWidth: 0.9 * lineScale, lineCap: .round, lineJoin: .round, dash: [4, 3]))
                    // Solid, curved course line.
                    var line = Path()
                    line.move(to: start); for q in Cc { line.addLine(to: q) }
                    ctx.stroke(line, with: .color(col), style: StrokeStyle(lineWidth: 1.6 * lineScale, lineCap: .round, lineJoin: .round))

                    // Heading at the selected place: dashed line to it + "64,2 км · ≈9 хв (21:53)" at the cone tip.
                    if let city, let e = Projection.eta(t, toLat: city.lat, lon: city.lon), e > 0, e <= 60 {
                        let cp = pt(city.lat, city.lon)
                        var dl = Path(); dl.move(to: start); dl.addLine(to: cp)
                        ctx.stroke(dl, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        let km = Geo.distanceKm(lat1: t.lat, lon1: t.lon, lat2: city.lat, lon2: city.lon)
                        let kmS = String(format: "%.1f", km).replacingOccurrences(of: ".", with: ",")
                        let txt = "\(kmS) км · ≈\(Fmt.eta(e)) (\(Fmt.time(now.addingTimeInterval(e * 60))))"
                        let r = ctx.resolve(Text(txt).font(.system(size: 10, weight: .semibold)).foregroundColor(.white))
                        let ts = r.measure(in: CGSize(width: 260, height: 20))
                        let c = CGPoint(x: cEnd.x, y: cEnd.y + ts.height / 2 + 8)
                        let bg = CGRect(x: c.x - ts.width / 2 - 5, y: c.y - ts.height / 2 - 2, width: ts.width + 10, height: ts.height + 4)
                        ctx.fill(Path(roundedRect: bg, cornerRadius: 5), with: .color(.black.opacity(0.6)))
                        ctx.draw(r, at: c)
                    }
                }

                let base = max(9, min(13, 17 * s))
                let sz = base * min(1.9, 1 + 0.22 * (z - 1))
                let showLabels = z >= 2.4 || size.width >= 520
                for t in targets {
                    let p = pt(t.lat, t.lon)
                    guard view.contains(p) else { continue }
                    TargetGlyph.draw(in: ctx, kind: t.kind, at: p, bearing: t.bearing, size: sz)
                    if t.count > 1 {
                        let bp = CGPoint(x: p.x + sz * 0.62, y: p.y - sz * 0.55)
                        let br = max(5, sz * 0.36)
                        ctx.fill(Path(ellipseIn: CGRect(x: bp.x - br, y: bp.y - br, width: br * 2, height: br * 2)), with: .color(.black.opacity(0.85)))
                        ctx.draw(Text("\(t.count)").font(.system(size: br * 1.25, weight: .bold)).foregroundColor(.white), at: bp)
                    }
                    var lines: [String] = []
                    if showLabels { lines.append(t.model ?? t.kind.title) }
                    if !lines.isEmpty {
                        let txt = Text(lines.joined(separator: " · ")).font(.system(size: 9, weight: .semibold)).foregroundColor(.white)
                        let r = ctx.resolve(txt)
                        let ts = r.measure(in: CGSize(width: 200, height: 20))
                        let c = CGPoint(x: p.x, y: p.y + sz * 0.8 + ts.height / 2 + 2)
                        let bg = CGRect(x: c.x - ts.width / 2 - 4, y: c.y - ts.height / 2 - 1.5, width: ts.width + 8, height: ts.height + 3)
                        ctx.fill(Path(roundedRect: bg, cornerRadius: bg.height / 2), with: .color(.black.opacity(0.72)))
                        ctx.draw(r, at: c)
                    }
                }
            }

            // City pin
            if let city {
                let p = pt(city.lat, city.lon)
                let halo = max(7, 12 * lw)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - halo, y: p.y - halo, width: halo * 2, height: halo * 2)), with: .color(pinColor.opacity(0.28)))
                let core = max(3, 4.5 * lw)
                let rect = CGRect(x: p.x - core, y: p.y - core, width: core * 2, height: core * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(.white))
                ctx.stroke(Path(ellipseIn: rect), with: .color(pinColor), lineWidth: max(1.5, 2.5 * lw))
            }
            if let sel = selected, let t = snapshot.targets.first(where: { $0.id == sel }) {
                let p = pt(t.lat, t.lon)
                let r: CGFloat = 13
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(.white), lineWidth: 1.5)
            }
        }
    }
}

/// Catches scroll-wheel and pinch events over the map (works in the non-activating desktop panel too).
struct MapEventCatcher: NSViewRepresentable {
    var onScroll: (NSEvent, CGPoint) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void
    var isZoomed: () -> Bool

    final class V: NSView {
        var monitor: Any?
        var parent: MapEventCatcher?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Pointer location normalised to 0…1 inside this view, or nil when outside.
        func norm(_ e: NSEvent) -> CGPoint? {
            guard let w = window, e.window === w, !isHiddenOrHasHiddenAncestor, bounds.width > 0, bounds.height > 0 else { return nil }
            let p = convert(e.locationInWindow, from: nil)
            guard bounds.contains(p) else { return nil }
            return CGPoint(x: p.x / bounds.width, y: p.y / bounds.height)
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .leftMouseDown, .leftMouseUp]) { [weak self] e in
                guard let self, let parent = self.parent else { return e }
                switch e.type {
                case .leftMouseUp:
                    MapInteraction.blockWindowDrag = false
                    return e
                case .leftMouseDown:
                    MapInteraction.blockWindowDrag = self.norm(e) != nil && parent.isZoomed()
                    return e
                case .scrollWheel:
                    guard let n = self.norm(e) else { return e }
                    if e.hasPreciseScrollingDeltas && !parent.isZoomed() && !e.modifierFlags.contains(.command) && !e.modifierFlags.contains(.option) { return e }
                    parent.onScroll(e, n)
                    return nil
                case .magnify:
                    guard let n = self.norm(e) else { return e }
                    parent.onMagnify(e.magnification, n)
                    return nil
                default:
                    return e
                }
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { uninstall() } else { install() }
        }
    }

    func makeNSView(context: Context) -> V {
        let v = V()
        v.parent = self
        return v
    }

    func updateNSView(_ v: V, context: Context) { v.parent = self }

    static func dismantleNSView(_ v: V, coordinator: ()) { v.uninstall() }
}

/// Vector glyphs for air targets, drawn "nose up" and rotated to the course.
public enum TargetGlyph {
    public static func coneColor(speed v: Double) -> Color {
        v < 250 ? Color(hex: 0xFFD60A) : (v < 600 ? Color(hex: 0xFF9F0A) : Color(hex: 0xFF453A))
    }

    public static func color(_ k: TargetKind) -> Color {
        switch k {
        case .shahed: return Color(hex: 0xF5F5F7)
        case .jetShahed: return Color(hex: 0xFF9F0A)
        case .geran5: return Color(hex: 0xFF6A3D)
        case .cruise: return Color(hex: 0xFFD60A)
        case .ballistic: return Color(hex: 0xFF453A)
        case .kab: return Color(hex: 0xBF5AF2)
        case .aircraft, .helicopter: return Color(hex: 0x64D2FF)
        case .recon: return Color(hex: 0xB4B4BC)
        case .fpv: return Color(hex: 0x30D158)
        case .unknown: return Color(hex: 0xE5E5EA)
        }
    }

    /// Mirror a right-half outline (x ≥ 0, from nose to tail) into a closed symmetric path, scaled by `h`.
    static func sym(_ pts: [(CGFloat, CGFloat)], _ h: CGFloat) -> Path {
        var p = Path()
        guard let f = pts.first else { return p }
        p.move(to: CGPoint(x: f.0 * h, y: f.1 * h))
        for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0 * h, y: q.1 * h)) }
        for q in pts.reversed() where q.0 != 0 { p.addLine(to: CGPoint(x: -q.0 * h, y: q.1 * h)) }
        p.closeSubpath()
        return p
    }

    /// Outline centred at 0,0, nose pointing up (−y), overall length ≈ `s`.
    public static func path(_ k: TargetKind, size s: CGFloat) -> Path {
        let h = s / 2
        switch k {
        case .shahed:
            // Geran-2 / Shahed-136: delta wing with wing-tip fins.
            return sym([(0, -1), (0.16, -0.62), (0.92, 0.48), (0.98, 0.86), (0.78, 0.74), (0.2, 0.62), (0.12, 0.8), (0, 0.8)], h)
        case .jetShahed:
            // Geran-3: slimmer delta with a jet engine nacelle sticking out of the tail.
            return sym([(0, -1), (0.13, -0.6), (0.78, 0.36), (0.8, 0.66), (0.24, 0.52), (0.2, 0.62), (0.2, 1.0), (0, 1.0)], h)
        case .geran5:
            // Geran-5: jet with swept wings mid-fuselage and a V-tail.
            return sym([(0, -1), (0.1, -0.78), (0.14, -0.4), (0.14, -0.2), (0.82, 0.34), (0.82, 0.46), (0.14, 0.24), (0.14, 0.66), (0.5, 0.98), (0.48, 1.04), (0.1, 0.9), (0, 0.9)], h)
        case .cruise:
            // Kalibr / Kh-101: long thin body, short straight wings, cruciform tail.
            return sym([(0, -1), (0.08, -0.86), (0.11, -0.62), (0.11, -0.06), (0.7, 0.08), (0.7, 0.2), (0.11, 0.14), (0.11, 0.72), (0.36, 0.98), (0.11, 0.94), (0.08, 1), (0, 1)], h)
        case .ballistic:
            // Iskander / KN-23: thick body, sharp nose, flared fins.
            return sym([(0, -1), (0.12, -0.72), (0.2, -0.36), (0.2, 0.56), (0.52, 0.98), (0.52, 1.04), (0.18, 0.96), (0, 0.96)], h)
        case .kab:
            // Guided glide bomb (UMPK): fat body with long straight wings and tail fins.
            return sym([(0, -0.92), (0.16, -0.82), (0.24, -0.56), (0.24, -0.12), (0.96, 0.02), (0.96, 0.14), (0.24, 0.12), (0.22, 0.62), (0.46, 0.96), (0.14, 0.86), (0, 0.86)], h)
        case .aircraft:
            return sym([(0, -1), (0.12, -0.7), (0.14, -0.24), (1, 0.18), (1, 0.36), (0.14, 0.24), (0.12, 0.66), (0.42, 0.92), (0.42, 1), (0.08, 0.94), (0, 0.94)], h)
        case .helicopter:
            var p = Path(ellipseIn: CGRect(x: -0.3 * h, y: -0.6 * h, width: 0.6 * h, height: 0.9 * h))
            p.addRect(CGRect(x: -0.07 * h, y: 0.2 * h, width: 0.14 * h, height: 0.75 * h))
            p.addRect(CGRect(x: -0.3 * h, y: 0.84 * h, width: 0.6 * h, height: 0.12 * h))
            for a in [CGFloat.pi / 4, -CGFloat.pi / 4] {
                let r = CGRect(x: -h, y: -0.06 * h, width: 2 * h, height: 0.12 * h)
                p.addPath(Path(roundedRect: r, cornerRadius: 0.06 * h).applying(CGAffineTransform(translationX: 0, y: 0.15 * h).rotated(by: a)))
            }
            return p
        case .recon:
            // Orlan-10 style: straight high-aspect wing, thin fuselage, small tailplane.
            var p = Path(roundedRect: CGRect(x: -0.1 * h, y: -0.82 * h, width: 0.2 * h, height: 1.62 * h), cornerRadius: 0.1 * h)
            p.addRoundedRect(in: CGRect(x: -1 * h, y: -0.34 * h, width: 2 * h, height: 0.22 * h), cornerSize: CGSize(width: 0.1 * h, height: 0.1 * h))
            p.addRoundedRect(in: CGRect(x: -0.42 * h, y: 0.62 * h, width: 0.84 * h, height: 0.16 * h), cornerSize: CGSize(width: 0.07 * h, height: 0.07 * h))
            return p
        case .fpv:
            var p = Path()
            for a in stride(from: CGFloat.pi / 4, to: 2 * .pi, by: .pi / 2) {
                let c = CGPoint(x: cos(a) * 0.62 * h, y: sin(a) * 0.62 * h)
                p.addEllipse(in: CGRect(x: c.x - 0.34 * h, y: c.y - 0.34 * h, width: 0.68 * h, height: 0.68 * h))
                p.addPath(Path(CGRect(x: 0, y: -0.08 * h, width: 0.62 * h, height: 0.16 * h)).applying(CGAffineTransform(rotationAngle: a)))
            }
            p.addRoundedRect(in: CGRect(x: -0.24 * h, y: -0.3 * h, width: 0.48 * h, height: 0.6 * h), cornerSize: CGSize(width: 0.1 * h, height: 0.1 * h))
            return p
        case .unknown:
            return Path(ellipseIn: CGRect(x: -0.55 * h, y: -0.55 * h, width: 1.1 * h, height: 1.1 * h))
        }
    }

    /// Draws a glyph with a soft glow and a dark outline so it reads on red, amber and grey fills.
    public static func draw(in ctx: GraphicsContext, kind k: TargetKind, at p: CGPoint, bearing: Double?, size s: CGFloat) {
        let col = color(k)
        let g = s * 0.78
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - g, y: p.y - g, width: g * 2, height: g * 2)),
                 with: .radialGradient(Gradient(colors: [col.opacity(0.45), col.opacity(0)]), center: p, startRadius: 0, endRadius: g))
        var c = ctx
        c.translateBy(x: p.x, y: p.y)
        if k != .fpv && k != .unknown { c.rotate(by: .degrees(bearing ?? 0)) }
        let shape = path(k, size: s)
        c.stroke(shape, with: .color(.black.opacity(0.9)), style: StrokeStyle(lineWidth: max(1.4, s * 0.14), lineJoin: .round))
        c.fill(shape, with: .color(col))
        if k == .unknown {
            c.draw(Text("?").font(.system(size: s * 0.6, weight: .heavy)).foregroundColor(.black), at: .zero)
        }
        if k == .jetShahed || k == .geran5 || k == .cruise || k == .ballistic {
            // Exhaust flame behind the tail.
            let fy = (k == .jetShahed ? 1.0 : (k == .geran5 ? 0.9 : (k == .ballistic ? 0.98 : 1.0))) * s / 2
            let fr = CGRect(x: -s * 0.07, y: fy, width: s * 0.14, height: s * 0.26)
            c.fill(Path(ellipseIn: fr), with: .linearGradient(Gradient(colors: [Color(hex: 0xFFE27A), Color(hex: 0xFF6A00).opacity(0)]), startPoint: CGPoint(x: 0, y: fr.minY), endPoint: CGPoint(x: 0, y: fr.maxY)))
        }
    }
}

/// A target glyph as a SwiftUI view (legend, lists).
public struct TargetIcon: View {
    let kind: TargetKind
    let size: CGFloat
    var bearing: Double
    public init(kind: TargetKind, size: CGFloat = 12, bearing: Double = 0) { self.kind = kind; self.size = size; self.bearing = bearing }
    public var body: some View {
        Canvas { ctx, sz in
            TargetGlyph.draw(in: ctx, kind: kind, at: CGPoint(x: sz.width / 2, y: sz.height / 2), bearing: bearing, size: size)
        }
        .frame(width: size * 1.5, height: size * 1.5)
    }
}


/// Diagonal amber stripes for "дорозвідка".
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
        c.stroke(stripes, with: .color(Theme.mapAmber), lineWidth: max(1, 2.4 * s))
    }
}

/// Small legend swatch with stripes.
public struct StripedSwatch: View {
    public init() {}
    public var body: some View {
        Canvas { ctx, size in
            let p = Path(ellipseIn: CGRect(origin: .zero, size: size))
            ctx.fill(p, with: .color(Theme.mapAmber.opacity(0.3)))
            Stripes.draw(in: ctx, path: p, scale: 0.35)
        }
        .frame(width: 8, height: 8)
    }
}

/// Details of a clicked air target.
struct TargetInfoCard: View {
    let t: AirTarget
    let city: Hromada?
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                TargetIcon(kind: t.kind, size: 16, bearing: t.bearing ?? 0)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(TargetGlyph.color(t.kind).opacity(0.16)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.model ?? t.kind.title).font(.system(size: 13, weight: .semibold))
                    if t.model != nil { Text(t.kind.title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)) }
                }
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                        .frame(width: 18, height: 18).background(Circle().fill(.white.opacity(0.1)))
                }.buttonStyle(.plain)
            }
            Divider().overlay(Color.white.opacity(0.1))
            ForEach(rows, id: \.0) { r in
                HStack {
                    Text(r.0).foregroundStyle(.white.opacity(0.55))
                    Spacer(minLength: 12)
                    Text(r.1).foregroundStyle(.white).multilineTextAlignment(.trailing)
                }
                .font(.system(size: 11.5))
            }
        }
        .padding(12)
        .frame(width: 236)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: 0x1C1C1F).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        .environment(\.colorScheme, .dark)
    }

    private var rows: [(String, String)] {
        var r: [(String, String)] = []
        if t.count > 1 { r.append(("Кількість", "\(t.count)")) }
        r.append(("Швидкість", (t.speed ?? 0) > 0 ? "\(Int(t.speed!)) км/год" : "~\(Int(t.kind.defaultSpeed)) км/год (типова)"))
        if let b = t.bearing { r.append(("Курс", "\(Int(b))° · \(Self.compass(b))")) }
        if t.bearing != nil, abs(t.turn) >= 0.5 {
            r.append(("Поворот", "\(t.turn > 0 ? "праворуч" : "ліворуч") \(String(format: "%.0f", abs(t.turn)))°/хв"))
        }
        if let a = t.altitude, a > 0 { r.append(("Висота", a >= 1000 ? String(format: "%.1f км", a / 1000) : "\(Int(a)) м")) }
        if let c = city {
            let km = Geo.distanceKm(lat1: t.lat, lon1: t.lon, lat2: c.lat, lon2: c.lon)
            r.append(("До вас", String(format: "%.1f км", km).replacingOccurrences(of: ".", with: ",")))
            if let e = Projection.eta(t, toLat: c.lat, lon: c.lon), e > 0 {
                r.append(("Підліт", "≈\(Fmt.eta(e)) (\(Fmt.time(Date().addingTimeInterval(e * 60))))"))
            } else {
                r.append(("Підліт", "не в бік вас"))
            }
        }
        let ago = max(0, Int(Date().timeIntervalSince(t.lastSeen)))
        r.append(("Оновлено", ago < 60 ? "щойно" : "\(ago / 60) хв тому"))
        r.append(("Джерела", t.sources.joined(separator: ", ")))
        return r
    }

    static func compass(_ b: Double) -> String {
        let d = ["Пн", "ПнСх", "Сх", "ПдСх", "Пд", "ПдЗх", "Зх", "ПнЗх"]
        return d[Int(((b + 22.5).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 45) % 8]
    }
}
