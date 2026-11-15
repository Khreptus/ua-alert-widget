import Foundation
import AppKit
import SwiftUI

/// Raster basemap (OpenStreetMap standard tiles; darkened in code for dark mode) shown under the alert layer when the map is zoomed in.
/// Used only by the app: WidgetKit views are static and never ask for tiles.
public final class TileStore: ObservableObject, @unchecked Sendable {
    public static let shared = TileStore()

    public struct Key: Hashable, Sendable { public let z: Int, x: Int, y: Int; public let dark: Bool }

    @Published public private(set) var tick = 0

    private let lock = NSLock()
    private let cache = NSCache<NSString, NSImage>()
    private var pending = Set<Key>()
    private var queue: [Key] = []
    private var wanted = Set<Key>()
    private var inflight = 0
    private var tickScheduled = false
    private let maxInflight = 4
    private let session: URLSession

    private init() {
        cache.countLimit = 600
        let cfg = URLSessionConfiguration.default
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let old = caches?.appendingPathComponent("tiles") { try? FileManager.default.removeItem(at: old) }   // CARTO placeholders
        let dir = caches?.appendingPathComponent("osm-tiles")
        cfg.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 400 << 20, directory: dir)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
    }

    private func name(_ k: Key) -> NSString { "\(k.z)/\(k.x)/\(k.y)" as NSString }

    private func url(_ k: Key) -> URL {
        URL(string: "https://tile.openstreetmap.org/\(k.z)/\(k.x)/\(k.y).png")!
    }

    /// Cached image or nil (does not request).
    public func image(_ k: Key) -> NSImage? { cache.object(forKey: name(k)) }

    /// Start of a frame: the set of tiles the map currently needs (older queued requests are dropped).
    public func beginFrame() { lock.lock(); wanted.removeAll(keepingCapacity: true); lock.unlock() }

    /// Ask for a tile; returns it if already cached.
    public func request(_ k: Key) -> NSImage? {
        if let img = image(k) { return img }
        lock.lock()
        wanted.insert(k)
        if !pending.contains(k) { pending.insert(k); queue.append(k) }
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.pump() }
        return nil
    }

    private func pump() {
        lock.lock()
        while inflight < maxInflight, !queue.isEmpty {
            let k = queue.removeLast()   // newest first
            guard wanted.contains(k) else { pending.remove(k); continue }
            inflight += 1
            lock.unlock()
            fetch(k)
            lock.lock()
        }
        lock.unlock()
    }

    private func fetch(_ k: Key) {
        var req = URLRequest(url: url(k))
        req.setValue("TryvohaUA-macOS/1.0 (personal widget)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            if let data, (resp as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: data) {
                self.cache.setObject(img, forKey: self.name(k))
            }
            self.lock.lock()
            self.inflight -= 1
            self.pending.remove(k)
            let schedule = !self.tickScheduled
            self.tickScheduled = true
            self.lock.unlock()
            if schedule {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    self.lock.lock(); self.tickScheduled = false; self.lock.unlock()
                    self.tick &+= 1
                }
            }
            DispatchQueue.main.async { self.pump() }
        }.resume()
    }
}
