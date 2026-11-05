import AppKit

/// A flake still in the air. Coordinates are global CG points (y down).
struct Flake {
    var x: CGFloat = 0, y: CGFloat = 0
    var vy: CGFloat = 0
    var phase: CGFloat = 0, freq: CGFloat = 1, size: CGFloat = 1
    var far = false
    var screen: CGRect = .zero
}

/// A clump of settled snow that slid or was shaken off a ledge; falls with gravity.
struct Chunk {
    var x: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat, volume: CGFloat
    var source: String?
    var age: CGFloat = 0
    var radius: CGFloat { min(6, max(1.5, sqrt(volume / (.pi * 0.5)))) }
}

/// The top edge of a window or the Dock, carrying a heightmap of snow.
/// The heightmap is stored relative to the ledge, so the snow rides along when the window moves.
final class Surface {
    static let colW: CGFloat = 2
    var frame: CGRect
    let inset: CGFloat
    /// radius of the window's rounded top corners
    let corner: CGFloat
    var cols: [CGFloat]
    var occluded: [Bool]
    /// how far the ledge drops below its top line at each column (follows the rounded corners)
    var drop: [CGFloat] = []
    var visible = true
    var spillL: CGFloat = 0, spillR: CGFloat = 0
    /// spill collected at run ends that border a hidden stretch, per column
    var spillAt: [CGFloat] = []
    /// smoothed motion of the window (pt/s, pt/s²), y down
    var vx: CGFloat = 0, vy: CGFloat = 0, ax: CGFloat = 0, ay: CGFloat = 0
    func resetMotion() { vx = 0; vy = 0; ax = 0; ay = 0 }

    init(frame: CGRect, inset: CGFloat, corner: CGFloat) {
        self.frame = frame
        self.inset = inset
        self.corner = corner
        let n = Surface.columns(for: frame.width, inset: inset)
        cols = Array(repeating: 0, count: n)
        occluded = Array(repeating: false, count: n)
        computeDrop()
    }

    private func computeDrop() {
        let n = cols.count, w = CGFloat(n) * Surface.colW
        drop = (0..<n).map { c in
            let x = (CGFloat(c) + 0.5) * Surface.colW
            let d = min(x, w - x)
            guard d < corner else { return 0 }
            let t = corner - d
            return corner - sqrt(max(0, corner * corner - t * t))
        }
    }

    static func columns(for width: CGFloat, inset: CGFloat) -> Int { max(1, Int((width - inset * 2) / colW)) }
    var ledgeX: CGFloat { frame.minX + inset }
    var ledgeY: CGFloat { frame.minY }
    var ledgeWidth: CGFloat { CGFloat(cols.count) * Surface.colW }
    var hasSnow: Bool { cols.contains { $0 > 0.05 } }

    /// Keep snow anchored to the left edge; whatever no longer fits spills off the right.
    func resize(to width: CGFloat) {
        let n = Surface.columns(for: width, inset: inset)
        if n < cols.count {
            spillR += cols[n...].reduce(0, +) * Surface.colW
            cols.removeLast(cols.count - n)
            occluded.removeLast(occluded.count - n)
        } else if n > cols.count {
            cols += Array(repeating: 0, count: n - cols.count)
            occluded += Array(repeating: false, count: n - occluded.count)
        }
        computeDrop()
    }
}

final class SnowEngine {
    static let shared = SnowEngine()
    private let settings = Settings.shared

    private(set) var flakes: [Flake] = []
    private(set) var chunks: [Chunk] = []
    private(set) var surfaces: [String: Surface] = [:]
    /// visible surfaces, front to back (Dock first)
    private(set) var order: [String] = []
    private var screens: [CGRect] = []
    private var time: CGFloat = 0
    private var pollAcc: CGFloat = 1, dockAcc: CGFloat = 1, missingAcc: CGFloat = 0
    private var dockRect: CGRect?

    private let maxPile: CGFloat = 60
    /// The HTML demo's units: one grid cell ≈ 3.6pt, one sim step = 1/60s.
    private let cell: CGFloat = 3.6
    private var perStep: CGFloat { cell * 60 }
    /// The demo canvas area the "amount" slider was tuned on.
    private let demoArea: CGFloat = 1080 * 648
    private let chunkVolume: CGFloat = 10

    func setScreens(_ s: [CGRect]) {
        screens = s
        flakes.removeAll()
        fillFlakes(anywhere: true)
    }

    func clear() {
        for s in surfaces.values { for i in s.cols.indices { s.cols[i] = 0 }; s.spillL = 0; s.spillR = 0 }
        chunks.removeAll()
    }

    func step(_ dt: CGFloat) {
        time += dt
        dockAcc += dt
        pollAcc += dt
        if dockAcc > 0.1 {
            dockAcc = 0
            // with auto-hide the Dock slides below the screen edge; only count it while its top edge is on screen.
            // Its snow stays stored while hidden and shows again when it slides back up.
            let d = WindowTracker.dockFrame()
            dockRect = d.flatMap { d in screens.contains { $0.contains(CGPoint(x: d.midX, y: d.minY + 2)) } ? d : nil }
        }
        refreshSurfaces(interval: pollAcc)
        pollAcc = 0
        fillFlakes(anywhere: false)
        moveFlakes(dt)
        moveChunks(dt)
        settle(dt)
    }

    // MARK: flakes in the air

    private func windAt(_ y: CGFloat) -> CGFloat {
        let yc = y / cell
        return (CGFloat(settings.wind) * 0.08 + 0.12 * sin(time * 0.37 + yc * 0.021)
                + 0.07 * sin(time * 1.3 + yc * 0.07)) * perStep
    }

    private func pickScreen() -> CGRect {
        let total = screens.reduce(0) { $0 + $1.width * $1.height }
        var r = CGFloat.random(in: 0...max(total, 1))
        for sc in screens { r -= sc.width * sc.height; if r <= 0 { return sc } }
        return screens.last ?? .zero
    }

    private func makeFlake(far: Bool, anywhere: Bool) -> Flake {
        let sc = pickScreen()
        var f = Flake()
        f.screen = sc
        f.far = far
        f.size = far ? 1 : .random(in: 0.7...1.3)
        f.vy = (far ? .random(in: 0.08...0.15) : .random(in: 0.16...0.32)) * perStep
        f.phase = .random(in: 0...(2 * .pi))
        f.freq = far ? 1.1 : .random(in: 0.7...1.8)
        f.x = .random(in: sc.minX...max(sc.minX + 1, sc.maxX))
        f.y = anywhere ? .random(in: sc.minY...max(sc.minY + 1, sc.maxY)) : sc.minY - .random(in: 0...40)
        return f
    }

    /// Same density as the demo: `amount` near flakes per demo-canvas area, plus half as many far ones.
    private func fillFlakes(anywhere: Bool) {
        let area = screens.reduce(0) { $0 + $1.width * $1.height }
        let near = Int((settings.amount * Double(area / demoArea)).rounded())
        let far = near / 2
        var nNear = 0, nFar = 0
        flakes.removeAll { f in
            if f.far { nFar += 1; return nFar > far } else { nNear += 1; return nNear > near }
        }
        while nNear < near { flakes.append(makeFlake(far: false, anywhere: anywhere)); nNear += 1 }
        while nFar < far { flakes.append(makeFlake(far: true, anywhere: anywhere)); nFar += 1 }
    }

    /// Sprite diameter, as drawn in the demo.
    func flakeDiameter(_ f: Flake) -> CGFloat {
        let sz = CGFloat(settings.size)
        return f.far ? cell * 1.1 * sqrt(sz) : f.size * cell * 2.2 * sz
    }
    /// Radius of the snow a flake carries (its visible core).
    func flakeRadius(_ f: Flake) -> CGFloat { flakeDiameter(f) * 0.3 }

    private func moveFlakes(_ dt: CGFloat) {
        let speed = CGFloat(settings.speed), sq = sqrt(speed)
        for i in flakes.indices {
            var f = flakes[i]
            let ph = time * f.freq + f.phase
            let y0 = f.y
            // flutter: swing side to side, slow down at the ends of each swing, plus a slow drift
            f.y += f.vy * speed * (0.7 + 0.45 * abs(cos(ph))) * dt
            if f.far {
                f.x += (windAt(f.y) * 0.45 + sin(ph) * 0.1 * sq * perStep) * dt
            } else {
                f.x += (windAt(f.y) * (0.6 + f.size * 0.4)
                        + sin(ph) * 0.22 * (0.5 + f.size * 0.5) * sq * perStep
                        + sin(ph * 0.31 + f.phase * 2) * 0.06 * perStep) * dt
            }
            if f.x < f.screen.minX { f.x += f.screen.width } else if f.x >= f.screen.maxX { f.x -= f.screen.width }
            if f.y > f.screen.maxY + 10 { flakes[i] = makeFlake(far: f.far, anywhere: false); continue }
            if !f.far, let s = landing(x: f.x, y0: y0, y1: f.y, ignore: nil) {
                let r = flakeRadius(f)
                deposit(on: s, x: f.x, volume: .pi * r * r * 0.5, radius: r * 2.5)
                flakes[i] = makeFlake(far: false, anywhere: false)
                continue
            }
            flakes[i] = f
        }
    }

    private func moveChunks(_ dt: CGFloat) {
        let bottom = screens.map(\.maxY).max() ?? 0
        var i = 0
        while i < chunks.count {
            var c = chunks[i]
            let y0 = c.y
            c.age += dt
            c.vy = min(c.vy + 700 * dt, 900)
            c.x += c.vx * dt
            c.y += c.vy * dt
            let ignore = c.age < 0.35 ? c.source : nil
            if let s = landing(x: c.x, y0: y0, y1: c.y, ignore: ignore) {
                deposit(on: s, x: c.x, volume: c.volume, radius: c.radius * 1.6)
                chunks.swapAt(i, chunks.count - 1); chunks.removeLast(); continue
            }
            if c.y > bottom + 20 { chunks.swapAt(i, chunks.count - 1); chunks.removeLast(); continue }
            chunks[i] = c
            i += 1
        }
    }

    /// The first snow surface crossed while moving from y0 to y1 at x.
    private func landing(x: CGFloat, y0: CGFloat, y1: CGFloat, ignore: String?) -> Surface? {
        var best: Surface?
        var bestTop = CGFloat.infinity
        for key in order where key != ignore {
            guard let s = surfaces[key], s.visible else { continue }
            let lx = x - s.ledgeX
            guard lx >= 0, lx < s.ledgeWidth else { continue }
            let c = Int(lx / Surface.colW)
            if s.occluded[c] { continue }
            let top = s.ledgeY + s.drop[c] - s.cols[c]
            if y0 <= top, y1 >= top, top < bestTop { best = s; bestTop = top }
        }
        return best
    }

    private func deposit(on s: Surface, x: CGFloat, volume: CGFloat, radius: CGFloat) {
        let n = s.cols.count
        let center = (x - s.ledgeX) / Surface.colW
        let rc = max(1, radius / Surface.colW)
        let c0 = max(0, Int(center - rc)), c1 = min(n - 1, Int(center + rc))
        guard c0 <= c1 else { return }
        var wsum: CGFloat = 0
        for c in c0...c1 { let d = (CGFloat(c) + 0.5 - center) / rc; wsum += max(0, 1 - d * d) }
        if wsum <= 0 { let c = min(n - 1, max(0, Int(center))); s.cols[c] += volume / Surface.colW; return }
        let k = volume / Surface.colW / wsum
        for c in c0...c1 {
            let d = (CGFloat(c) + 0.5 - center) / rc
            s.cols[c] = min(maxPile, s.cols[c] + k * max(0, 1 - d * d))
        }
    }

    // MARK: settled snow

    /// Angle-of-repose relaxation on every heightmap; overflow at the ends spills off as chunks.
    private func settle(_ dt: CGFloat) {
        let angle = (25 + CGFloat(settings.stick) * 50) * .pi / 180
        let maxD = Surface.colW * tan(angle)
        let melt = CGFloat(settings.melt) * 0.5 * dt
        for (key, s) in surfaces where s.visible {
            var h = s.cols
            let g = s.drop
            let n = h.count
            guard n > 0 else { continue }
            let occ = s.occluded
            if s.spillAt.count != n { s.spillAt = Array(repeating: 0, count: n) }
            // distance (in columns) to the nearest end of the visible run each column belongs to
            var dist = Array(repeating: 0, count: n)
            var run = 0
            for c in 0..<n { if occ[c] { run = 0 } else { dist[c] = run; run += 1 } }
            run = 0
            for c in stride(from: n - 1, through: 0, by: -1) { if occ[c] { run = 0 } else { dist[c] = min(dist[c], run); run += 1 } }
            // Near run ends the allowed slope eases from gentle to full over `edgeCols`, so a pile ends in a
            // rounded taper instead of a straight ramp that looks cut off.
            let edgeCols = 14
            func limit(_ distFromEdge: Int) -> CGFloat {
                maxD * min(1, max(0.12, CGFloat(distFromEdge + 1) / CGFloat(edgeCols)))
            }
            // hidden columns are frozen: their snow is kept but neither moves nor receives any
            for pass in 0..<2 {
                let forward = (pass + Int(time * 60)) % 2 == 0
                for j in 0..<(n - 1) {
                    let a = forward ? j : n - 2 - j, b = a + 1
                    if occ[a] || occ[b] { continue }
                    let lim = limit(min(dist[a], dist[b]))
                    let diff = (h[a] - g[a]) - (h[b] - g[b])
                    if diff > lim { let m = min(h[a], (diff - lim) * 0.5); h[a] -= m; h[b] += m }
                    else if -diff > lim { let m = min(h[b], (-diff - lim) * 0.5); h[b] -= m; h[a] += m }
                }
            }
            let edgeLim = limit(0)
            for c in 0..<n where !occ[c] && dist[c] == 0 && h[c] > edgeLim {
                let m = (h[c] - edgeLim) * 0.5
                h[c] -= m
                if c == 0 { s.spillL += m * Surface.colW }
                else if c == n - 1 { s.spillR += m * Surface.colW }
                else { s.spillAt[c] += m * Surface.colW }
            }
            for c in 0..<n where s.spillAt[c] >= chunkVolume {
                s.spillAt[c] -= chunkVolume
                let leftSide = c > 0 && occ[c - 1]
                chunks.append(Chunk(x: s.ledgeX + (CGFloat(c) + (leftSide ? 0 : 1)) * Surface.colW,
                                    y: s.ledgeY + g[c] - max(1, h[c]),
                                    vx: (leftSide ? -1 : 1) * .random(in: 10...35), vy: 0,
                                    volume: chunkVolume, source: key))
            }
            if melt > 0 { for c in 0..<n where h[c] > 0 && !occ[c] { h[c] = max(0, h[c] - melt) } }
            s.cols = h
            while s.spillL >= chunkVolume {
                s.spillL -= chunkVolume
                chunks.append(Chunk(x: s.ledgeX - 1, y: s.ledgeY + g[0] - max(1, h[0]), vx: -.random(in: 10...35),
                                    vy: 0, volume: chunkVolume, source: key))
            }
            while s.spillR >= chunkVolume {
                s.spillR -= chunkVolume
                chunks.append(Chunk(x: s.ledgeX + s.ledgeWidth + 1, y: s.ledgeY + g[n - 1] - max(1, h[n - 1]),
                                    vx: .random(in: 10...35), vy: 0, volume: chunkVolume, source: key))
            }
        }
    }

    /// Snow holds on while the window's acceleration stays within what friction (sideways) and gravity
    /// (downward) can hold. Past that, the excess knocks snow loose; it keeps the window's earlier velocity
    /// and scatters.
    private func shakeOff(_ s: Surface, key: String, dt: CGFloat) {
        let stick = CGFloat(settings.stick)
        let holdX = 2500 + stick * 10000      // pt/s²
        let holdDown = 2000 + stick * 8000
        let ex = max(0, abs(s.ax) - holdX) / holdX
        let ey = max(0, s.ay - holdDown) / holdDown
        let excess = ex + ey
        guard excess > 0, s.hasSnow, chunks.count < 2500 else { return }
        let fraction = min(0.9, excess * 6 * dt)
        let spread = 60 + 140 * min(excess, 3)
        // snow keeps moving the way the window was going before this jolt
        let baseVx = s.vx - s.ax * 0.025, baseVy = s.vy - s.ay * 0.025
        let n = s.cols.count, group = 3
        var c = 0
        while c < n {
            let e = min(n, c + group)
            let f = min(1, fraction * .random(in: 0.4...1.6))
            var vol: CGFloat = 0
            var top: CGFloat = 0
            for k in c..<e { let take = s.cols[k] * f; s.cols[k] -= take; vol += take * Surface.colW; top = max(top, s.cols[k] + take) }
            let x = s.ledgeX + (CGFloat(c) + CGFloat(e - c) / 2) * Surface.colW
            while vol > 0.3 {
                let v = min(vol, 8)
                vol -= v
                chunks.append(Chunk(x: x + .random(in: -3...3), y: s.ledgeY - .random(in: 0...max(1, top)),
                                    vx: baseVx + .random(in: -1...1) * spread,
                                    vy: baseVy + .random(in: -1...0.3) * spread,
                                    volume: v, source: key))
            }
            c = e
        }
    }

    /// Knock a fraction of the snow off a surface as falling chunks.
    private func shake(_ s: Surface, key: String, fraction: CGFloat, vx: CGFloat) {
        let n = s.cols.count, group = 5
        var c = 0
        while c < n {
            let e = min(n, c + group)
            var vol: CGFloat = 0
            for k in c..<e { let take = s.cols[k] * fraction; s.cols[k] -= take; vol += take * Surface.colW }
            let x = s.ledgeX + (CGFloat(c) + CGFloat(e - c) / 2) * Surface.colW
            while vol > 0.5 {
                let v = min(vol, 40)
                vol -= v
                chunks.append(Chunk(x: x + .random(in: -4...4), y: s.ledgeY - 2,
                                    vx: vx * 0.4 + .random(in: -25...25), vy: -.random(in: 0...140),
                                    volume: v, source: key))
            }
            c = e
        }
    }

    // MARK: window tracking

    private func refreshSurfaces(interval: CGFloat) {
        var newOrder: [String] = []
        var seen = Set<String>()
        if let d = dockRect {
            update("dock", frame: d, inset: 20, interval: interval)
            newOrder.append("dock"); seen.insert("dock")
        }
        for w in WindowTracker.onscreenWindows() {
            let key = "w\(w.id)"
            update(key, frame: w.frame, inset: 16, interval: interval)
            newOrder.append(key); seen.insert(key)
        }
        var missing: [String] = []
        for (key, s) in surfaces where !seen.contains(key) {
            s.visible = false
            if !s.hasSnow { surfaces[key] = nil } else if key != "dock" { missing.append(key) }
        }
        // a window that vanished for good drops its snow; minimized or other-Space windows keep theirs
        missingAcc += interval
        if !missing.isEmpty, missingAcc > 0.5 {
            missingAcc = 0
            let alive = WindowTracker.allWindowIDs()
            for key in missing {
                guard let id = CGWindowID(key.dropFirst()), !alive.contains(id), let s = surfaces[key] else { continue }
                s.visible = true
                shake(s, key: key, fraction: 1, vx: 0)
                surfaces[key] = nil
            }
        }
        order = newOrder
        computeOcclusion()
    }

    /// Snow only sits on the flat part of the top edge; the rounded corners (`inset` on each side) stay bare.
    private func update(_ key: String, frame: CGRect, inset: CGFloat, interval: CGFloat) {
        guard let s = surfaces[key] else { surfaces[key] = Surface(frame: frame, inset: inset, corner: 0); return }
        let dx = frame.minX - s.frame.minX, dy = frame.minY - s.frame.minY
        if !s.visible || interval <= 0 || hypot(dx, dy) > 600 {
            // reappeared or jumped (Space switch, display change): not a shake
            s.visible = true
            s.resetMotion()
        } else {
            // low-pass the velocity, then the acceleration, so 1pt position jitter doesn't read as a jolt
            let kv = 1 - exp(-interval / 0.035), ka = 1 - exp(-interval / 0.03)
            let nvx = s.vx + (dx / interval - s.vx) * kv
            let nvy = s.vy + (dy / interval - s.vy) * kv
            s.ax += ((nvx - s.vx) / interval - s.ax) * ka
            s.ay += ((nvy - s.vy) / interval - s.ay) * ka
            s.vx = nvx; s.vy = nvy
        }
        if abs(frame.width - s.frame.width) > 0.5 { s.resize(to: frame.width) }
        s.frame = frame
        shakeOff(s, key: key, dt: interval)
    }

    /// Columns of a ledge that sit under a window in front of it are hidden and take no snow.
    /// A column of a ledge is hidden when a window in front of it, or the snow piled on that window,
    /// reaches down past the ledge there. Hidden columns take no snow and aren't drawn.
    private func computeOcclusion() {
        var fronts: [Surface] = []
        for key in order {
            guard let s = surfaces[key] else { continue }
            let n = s.cols.count
            for c in 0..<n { s.occluded[c] = false }
            let y = s.ledgeY
            for f in fronts {
                let r = f.frame
                // only windows whose body covers the ledge line, or whose snow could rise above it
                guard r.maxY > y, r.minY - maxPile <= y + 1 else { continue }
                let c0 = max(0, Int((r.minX - s.ledgeX) / Surface.colW))
                let c1 = min(n, Int(ceil((r.maxX - s.ledgeX) / Surface.colW)))
                guard c0 < c1 else { continue }
                for c in c0..<c1 where !s.occluded[c] {
                    let x = s.ledgeX + (CGFloat(c) + 0.5) * Surface.colW
                    var frontTop = r.minY
                    let fc = Int((x - f.ledgeX) / Surface.colW)
                    if fc >= 0, fc < f.cols.count, !f.occluded[fc] { frontTop -= f.cols[fc] }
                    if y + 1 >= frontTop - 1 { s.occluded[c] = true }
                }
            }
            fronts.append(s)
        }
    }
}
