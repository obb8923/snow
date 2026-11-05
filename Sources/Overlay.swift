import AppKit

/// Converts a Cocoa screen frame (origin bottom-left) to global CG coordinates (origin top-left, y down).
func cgRect(fromCocoa f: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? f.height
    return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
}

/// Transparent, click-through window covering one screen, above the Dock.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: false)
        let view = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.cgFrame = cgRect(fromCocoa: screen.frame)
        contentView = view
    }
    var overlayView: OverlayView { contentView as! OverlayView }
}

final class OverlayView: NSView {
    var cgFrame: CGRect = .zero
    override var isFlipped: Bool { true }

    private static let sprite: CGImage = {
        // soft white dot: solid core, then a smoothstep falloff sampled at many stops,
        // so there is no kink in the curve that reads as a ring
        let px = 128, half = CGFloat(px) / 2
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let c = CGPoint(x: half, y: half)
        let steps = 32
        var colors: [CGColor] = [], locations: [CGFloat] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let u = min(max((t - 0.2) / 0.8, 0), 1)
            colors.append(CGColor(gray: 1, alpha: 1 - u * u * (3 - 2 * u)))
            locations.append(t)
        }
        let core = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: locations)!
        ctx.drawRadialGradient(core, startCenter: c, startRadius: 0, endCenter: c, endRadius: half, options: [])
        return ctx.makeImage()!
    }()

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        ctx.interpolationQuality = .high
        ctx.translateBy(x: -cgFrame.minX, y: -cgFrame.minY)
        let engine = SnowEngine.shared
        let view = cgFrame.insetBy(dx: -20, dy: -80)

        // far layer
        ctx.setAlpha(0.35)
        for f in engine.flakes where f.far && view.contains(CGPoint(x: f.x, y: f.y)) {
            let r = engine.flakeDiameter(f) / 2
            ctx.draw(Self.sprite, in: CGRect(x: f.x - r, y: f.y - r, width: r * 2, height: r * 2))
        }
        ctx.setAlpha(1)

        // settled snow, with a soft shadow so it stays visible on light windows
        ctx.saveGState()
        // Back to front, so a nearer window's snow covers a farther one's; and each pile is clipped to
        // the parts not hidden behind windows in front of it (rounded corners included).
        let order = engine.order
        for i in stride(from: order.count - 1, through: 0, by: -1) {
            guard let s = engine.surfaces[order[i]], s.visible,
                  view.intersects(CGRect(x: s.ledgeX, y: s.ledgeY - 70, width: s.ledgeWidth, height: 72)) else { continue }
            guard let (body, rim) = pilePaths(s) else { continue }
            let pileBox = body.boundingBox.insetBy(dx: -2, dy: -2)
            ctx.saveGState()
            // cut out each front window separately (one even-odd path would re-show where two of them overlap)
            for j in 0..<i {
                guard let f = engine.surfaces[order[j]]?.frame, f.intersects(pileBox) else { continue }
                let r: CGFloat = order[j] == "dock" ? 20 : 16
                let keep = CGMutablePath()
                keep.addRect(pileBox.union(f))
                keep.addRoundedRect(in: f, cornerWidth: r, cornerHeight: r)
                ctx.addPath(keep); ctx.clip(using: .evenOdd)
            }
            let top = s.ledgeY - (s.cols.max() ?? 0)
            ctx.saveGState()
            ctx.addPath(body); ctx.clip()
            ctx.drawLinearGradient(Self.pileGradient, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: s.ledgeY),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
            ctx.addPath(rim)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95)); ctx.setLineWidth(1.5); ctx.setLineCap(.round)
            ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.setFillColor(CGColor(red: 0.97, green: 0.98, blue: 1, alpha: 1))
        for c in engine.chunks where view.contains(CGPoint(x: c.x, y: c.y)) {
            let r = c.radius
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
        ctx.restoreGState()

        // near layer
        ctx.setAlpha(0.95)
        for f in engine.flakes where !f.far && view.contains(CGPoint(x: f.x, y: f.y)) {
            let r = engine.flakeDiameter(f) / 2
            ctx.draw(Self.sprite, in: CGRect(x: f.x - r, y: f.y - r, width: r * 2, height: r * 2))
        }
        ctx.setAlpha(1)
    }

    /// Display-only smoothing of a heightmap: three box-blur passes (≈ gaussian, ±10pt),
    /// which rounds peaks and pile ends the way the demo's blur + threshold does.
    static func smoothed(_ src: [CGFloat]) -> [CGFloat] {
        let n = src.count, r = 3
        guard n > 2 else { return src }
        var a = src, b = src
        for _ in 0..<3 {
            // zero beyond the ends, so pile ends taper down instead of standing up
            func at(_ i: Int) -> CGFloat { i < 0 || i >= n ? 0 : a[i] }
            var sum: CGFloat = 0
            for k in -r...r { sum += at(k) }
            for i in 0..<n {
                b[i] = sum / CGFloat(2 * r + 1)
                sum += at(i + r + 1) - at(i - r)
            }
            swap(&a, &b)
        }
        return a
    }

    private static let pileGradient = CGGradient(colorsSpace: nil, colors: [
        CGColor(red: 0.965, green: 0.976, blue: 1, alpha: 1),
        CGColor(red: 0.79, green: 0.84, blue: 0.94, alpha: 1)] as CFArray, locations: [0, 1])!

    /// One closed shape per run of visible snow (smooth top through column midpoints, flat bottom on the
    /// ledge), plus the top edge alone for the bright rim.
    private func pilePaths(_ s: Surface) -> (CGPath, CGPath)? {
        let w = Surface.colW, y0 = s.ledgeY, n = s.cols.count
        let path = CGMutablePath(), rim = CGMutablePath()
        let h = Self.smoothed(s.cols)
        var c = 0
        while c < n {
            if h[c] < 0.3 || s.occluded[c] { c += 1; continue }
            var e = c
            while e + 1 < n, h[e + 1] >= 0.3, !s.occluded[e + 1] { e += 1 }
            func px(_ k: Int) -> CGFloat { s.ledgeX + (CGFloat(k) + 0.5) * w }
            func gy(_ k: Int) -> CGFloat { y0 + s.drop[k] }
            func py(_ k: Int) -> CGFloat { gy(k) - h[k] }
            path.move(to: CGPoint(x: s.ledgeX + CGFloat(c) * w, y: gy(c)))
            path.addLine(to: CGPoint(x: px(c), y: py(c)))
            rim.move(to: CGPoint(x: px(c), y: py(c)))
            if e > c {
                for k in c..<e {
                    let mid = CGPoint(x: (px(k) + px(k + 1)) / 2, y: (py(k) + py(k + 1)) / 2)
                    path.addQuadCurve(to: mid, control: CGPoint(x: px(k), y: py(k)))
                    rim.addQuadCurve(to: mid, control: CGPoint(x: px(k), y: py(k)))
                }
            }
            path.addLine(to: CGPoint(x: px(e), y: py(e)))
            rim.addLine(to: CGPoint(x: px(e), y: py(e)))
            // bottom follows the ledge, including the rounded corners
            path.addLine(to: CGPoint(x: s.ledgeX + CGFloat(e + 1) * w, y: gy(e)))
            for k in stride(from: e, through: c, by: -1) { path.addLine(to: CGPoint(x: px(k), y: gy(k))) }
            path.closeSubpath()
            c = e + 1
        }
        return path.isEmpty ? nil : (path, rim)
    }
}
