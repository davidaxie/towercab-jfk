import Foundation
import SceneKit
import UIKit
import simd

// =============================================================================
// World shared infrastructure — deterministic RNG, mesh assembly, procedural
// textures, PBR material factory. All art is generated in code; nothing on
// disk. World convention: meters, Y up, north = -Z (see SimTypes.swift).
// =============================================================================

// MARK: - Deterministic RNG (world-local; the sim's SeededRNG stays sim-only)

struct WorldRand {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    mutating func cgRange(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat(range(Double(a), Double(b))) }
    mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
}

// MARK: - Small helpers

@inline(__always) func worldV3(_ p: V2, _ y: Double) -> SCNVector3 {
    SCNVector3(Float(p.x), Float(y), Float(p.y))
}
@inline(__always) func worldF3(_ p: V2, _ y: Double) -> SIMD3<Float> {
    SIMD3(Float(p.x), Float(y), Float(p.y))
}
@inline(__always) func worldSmoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)
}
@inline(__always) func worldColor(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> UIColor {
    UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
}

/// Runway-relative coordinates: s = meters along the 22 roll from threshold B,
/// p = meters toward the tower/apron side (the layout's `perpSE`).
struct FieldFrame {
    let origin: V2
    let dir: V2
    let perp: V2
    let length: Double
    init(_ airport: AirportLayout) {
        origin = airport.runway.thresholdB
        dir = airport.runway.dir22
        perp = V2(-dir.y, dir.x)          // matches KAVXAirport's perpSE exactly
        length = airport.runway.length
    }
    func point(s: Double, p: Double) -> V2 { origin + dir * s + perp * p }
    func station(_ q: V2) -> V2 {
        let d = q - origin
        return V2(simd_dot(d, dir), simd_dot(d, perp))
    }
}

// MARK: - Mesh assembly

struct WorldMesh {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var indices: [Int32] = []

    @discardableResult
    mutating func add(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ uv: SIMD2<Float>) -> Int32 {
        positions.append(p); normals.append(n); uvs.append(uv)
        return Int32(positions.count - 1)
    }

    mutating func triangle(_ a: Int32, _ b: Int32, _ c: Int32) {
        indices.append(a); indices.append(b); indices.append(c)
    }

    /// Quad a-b-c-d (loop order); winding auto-corrected toward `desiredNormal`.
    mutating func quad(_ a: Int32, _ b: Int32, _ c: Int32, _ d: Int32, desiredNormal: SIMD3<Float>) {
        let pa = positions[Int(a)], pb = positions[Int(b)], pc = positions[Int(c)]
        let n = simd_cross(pb - pa, pc - pa)
        if simd_dot(n, desiredNormal) >= 0 {
            triangle(a, b, c); triangle(a, c, d)
        } else {
            triangle(a, c, b); triangle(a, d, c)
        }
    }

    /// Flat-shaded triangle: duplicates vertices, uses the face normal
    /// (flipped toward `hint` if provided).
    mutating func facet(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                        hint: SIMD3<Float>? = nil, uv: SIMD2<Float> = .zero) {
        var n = simd_cross(b - a, c - a)
        let len = simd_length(n)
        n = len > 1e-6 ? n / len : SIMD3(0, 1, 0)
        if let h = hint, simd_dot(n, h) < 0 {
            n = -n
            let ia = add(a, n, uv), ib = add(c, n, uv), ic = add(b, n, uv)
            triangle(ia, ib, ic)
            return
        }
        let ia = add(a, n, uv), ib = add(b, n, uv), ic = add(c, n, uv)
        triangle(ia, ib, ic)
    }

    func build(material: SCNMaterial) -> SCNGeometry {
        let vData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let nData = normals.withUnsafeBufferPointer { Data(buffer: $0) }
        let tData = uvs.withUnsafeBufferPointer { Data(buffer: $0) }
        let vSrc = SCNGeometrySource(data: vData, semantic: .vertex,
                                     vectorCount: positions.count, usesFloatComponents: true,
                                     componentsPerVector: 3, bytesPerComponent: 4,
                                     dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let nSrc = SCNGeometrySource(data: nData, semantic: .normal,
                                     vectorCount: normals.count, usesFloatComponents: true,
                                     componentsPerVector: 3, bytesPerComponent: 4,
                                     dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let tSrc = SCNGeometrySource(data: tData, semantic: .texcoord,
                                     vectorCount: uvs.count, usesFloatComponents: true,
                                     componentsPerVector: 2, bytesPerComponent: 4,
                                     dataOffset: 0, dataStride: MemoryLayout<SIMD2<Float>>.stride)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let g = SCNGeometry(sources: [vSrc, nSrc, tSrc], elements: [element])
        g.materials = [material]
        return g
    }
}

/// Ground ribbon following a 2D polyline, sampling airport.groundHeight so
/// paved surfaces genuinely ride the midfield hump.
func worldRibbonGeometry(points: [V2], width: Double, lift: Double,
                         airport: AirportLayout, vPerMeter: Double?,
                         material: SCNMaterial, step: Double = 12) -> SCNGeometry {
    var mesh = WorldMesh()
    var rows: [(center: V2, normal: V2, v: Double)] = []
    var travelled = 0.0
    for seg in 0..<(points.count - 1) {
        let a = points[seg], b = points[seg + 1]
        let segLen = simd_length(b - a)
        guard segLen > 0.01 else { continue }
        let d = (b - a) / segLen
        let n = V2(-d.y, d.x)
        let count = max(1, Int(segLen / step))
        if seg == 0 { rows.append((a, n, 0)) }
        for k in 1...count {
            let t = Double(k) / Double(count)
            rows.append((a + d * (segLen * t), n, travelled + segLen * t))
        }
        travelled += segLen
    }
    let total = max(travelled, 0.001)
    // Average normals at shared row positions for simple mitering.
    for i in 1..<max(rows.count, 2) where i < rows.count {
        let blended = simd_normalize(rows[i - 1].normal + rows[i].normal)
        if blended.x.isFinite { rows[i].normal = blended }
    }
    var prevL: Int32 = -1, prevR: Int32 = -1
    let up = SIMD3<Float>(0, 1, 0)
    for row in rows {
        let v = Float(vPerMeter.map { row.v * $0 } ?? row.v / total)
        let lp = row.center + row.normal * (width / 2)
        let rp = row.center - row.normal * (width / 2)
        let ly = airport.groundHeight(at: lp) + lift
        let ry = airport.groundHeight(at: rp) + lift
        let li = mesh.add(worldF3(lp, ly), up, SIMD2(0, v))
        let ri = mesh.add(worldF3(rp, ry), up, SIMD2(1, v))
        if prevL >= 0 { mesh.quad(prevL, prevR, ri, li, desiredNormal: up) }
        prevL = li; prevR = ri
    }
    return mesh.build(material: material)
}

// MARK: - Procedural textures

enum WorldTex {

    static func image(_ size: CGSize, opaque: Bool = true,
                      _ draw: (CGContext, CGSize) -> Void) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            draw(ctx.cgContext, size)
        }
    }

    /// Scatter soft blobs; wraps across edges so tileable textures stay seamless.
    static func speckle(_ ctx: CGContext, size: CGSize, count: Int, seed: UInt64,
                        radius: ClosedRange<CGFloat>, colors: [(UIColor, CGFloat)],
                        wrap: Bool = false) {
        var rng = WorldRand(seed: seed)
        for _ in 0..<count {
            let r = rng.cgRange(radius.lowerBound, radius.upperBound)
            let x = rng.cgRange(0, size.width)
            let y = rng.cgRange(0, size.height)
            let (color, alpha) = colors[rng.int(colors.count)]
            ctx.setFillColor(color.withAlphaComponent(alpha * rng.cgRange(0.55, 1.0)).cgColor)
            var centers = [CGPoint(x: x, y: y)]
            if wrap {
                if x < r { centers.append(CGPoint(x: x + size.width, y: y)) }
                if x > size.width - r { centers.append(CGPoint(x: x - size.width, y: y)) }
                if y < r { centers.append(CGPoint(x: x, y: y + size.height)) }
                if y > size.height - r { centers.append(CGPoint(x: x, y: y - size.height)) }
            }
            for c in centers {
                ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r * 0.7, width: r * 2, height: r * 1.4))
            }
        }
    }

    // --- Airfield surfaces ---

    /// Full-length runway texture. v=0 = threshold B (RWY 22, NE end).
    /// u=0 = the pilot-right edge when landing 22 (+perp side).
    static func runway(lengthMeters: Double, widthMeters: Double) -> UIImage {
        let W: CGFloat = 768, H: CGFloat = 6144
        let ppmX = W / CGFloat(widthMeters)          // ≈ 42 px/m across
        let ppmY = H / CGFloat(lengthMeters)         // ≈ 6.2 px/m along
        func X(_ metersFromCenter: Double) -> CGFloat { W / 2 + CGFloat(metersFromCenter) * ppmX }
        func Y(_ stationFrom22: Double) -> CGFloat { CGFloat(stationFrom22) * ppmY }

        return image(CGSize(width: W, height: H)) { ctx, size in
            // Warm asphalt base.
            ctx.setFillColor(worldColor(0.170, 0.160, 0.152).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))

            // Large weathered patches (repaves, sun-bleach).
            var rng = WorldRand(seed: 0xA11C)
            for _ in 0..<230 {
                let w = rng.cgRange(40, 240), h = rng.cgRange(60, 420)
                let x = rng.cgRange(-w, W), y = rng.cgRange(-h, H)
                let lighter = rng.unit() > 0.45
                let tone = lighter ? worldColor(0.215, 0.205, 0.192) : worldColor(0.135, 0.128, 0.124)
                ctx.saveGState()
                ctx.translateBy(x: x + w / 2, y: y + h / 2)
                ctx.rotate(by: rng.cgRange(-0.12, 0.12))
                ctx.setFillColor(tone.withAlphaComponent(rng.cgRange(0.05, 0.14)).cgColor)
                ctx.fill(CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                ctx.restoreGState()
            }
            // Fine aggregate noise.
            speckle(ctx, size: size, count: 5200, seed: 0xF00D,
                    radius: 0.6...2.6,
                    colors: [(worldColor(0.30, 0.29, 0.27), 0.10),
                             (worldColor(0.09, 0.09, 0.09), 0.11),
                             (worldColor(0.24, 0.21, 0.18), 0.07)])
            // Crack lines.
            ctx.setLineWidth(1.2)
            for _ in 0..<64 {
                ctx.setStrokeColor(worldColor(0.07, 0.07, 0.07, rng.range(0.14, 0.30)).cgColor)
                var p = CGPoint(x: rng.cgRange(30, W - 30), y: rng.cgRange(0, H))
                ctx.move(to: p)
                for _ in 0..<rng.int(5) + 3 {
                    p.x += rng.cgRange(-26, 26); p.y += rng.cgRange(14, 90)
                    ctx.addLine(to: p)
                }
                ctx.strokePath()
            }
            // Rubber: heavy near the 22 touchdown zone (top), lighter near 04.
            func rubber(from s0: Double, to s1: Double, count: Int, seed: UInt64, alpha: CGFloat) {
                var r = WorldRand(seed: seed)
                for _ in 0..<count {
                    let s = r.range(s0, s1)
                    let off = r.range(-1, 1)
                    let lateral = off * off * off * 5.5   // clustered near the gear tracks
                    let cx = X(lateral + (r.unit() > 0.5 ? 1.9 : -1.9))
                    let cy = Y(s)
                    let w = r.cgRange(9, 30), h = r.cgRange(30, 130)
                    ctx.setFillColor(worldColor(0.05, 0.05, 0.055, Double(alpha) * r.range(0.4, 1)).cgColor)
                    ctx.fillEllipse(in: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
                }
            }
            rubber(from: 70, to: 380, count: 260, seed: 0xB00B, alpha: 0.16)
            rubber(from: lengthMeters - 330, to: lengthMeters - 80, count: 90, seed: 0xB00C, alpha: 0.10)

            // ---- Paint (aged white) ----
            let paint = worldColor(0.90, 0.885, 0.845, 0.90)
            ctx.setFillColor(paint.cgColor)

            // Edge stripes.
            let edgeX = widthMeters / 2 - 0.85
            for sideSign in [-1.0, 1.0] {
                let x = X(sideSign * edgeX)
                ctx.fill(CGRect(x: x - 0.23 * ppmX * 2, y: 0, width: 0.46 * ppmX, height: H))
            }
            // Piano keys at both ends: 6 stripes.
            let keyOffsets: [Double] = [-6.3, -3.9, -1.5, 1.5, 3.9, 6.3]
            for off in keyOffsets {
                ctx.fill(CGRect(x: X(off - 0.65), y: Y(7), width: 1.3 * ppmX, height: (24 - 7) * ppmY))
                ctx.fill(CGRect(x: X(off - 0.65), y: Y(lengthMeters - 24),
                                width: 1.3 * ppmX, height: (24 - 7) * ppmY))
            }
            // Threshold bar.
            ctx.fill(CGRect(x: X(-edgeX), y: Y(3.0), width: CGFloat(edgeX * 2) * ppmX, height: 1.6 * ppmY))
            ctx.fill(CGRect(x: X(-edgeX), y: Y(lengthMeters - 4.6),
                            width: CGFloat(edgeX * 2) * ppmX, height: 1.6 * ppmY))
            // Aiming-point bars.
            for sideSign in [-1.0, 1.0] {
                ctx.fill(CGRect(x: X(sideSign * 4.6 - 1.25), y: Y(252),
                                width: 2.5 * ppmX, height: 16 * ppmY))
                ctx.fill(CGRect(x: X(sideSign * 4.6 - 1.25), y: Y(lengthMeters - 268),
                                width: 2.5 * ppmX, height: 16 * ppmY))
            }
            // Centerline dashes (20 m dash / 15 m gap).
            var s = 70.0
            while s + 20 < lengthMeters - 70 {
                ctx.fill(CGRect(x: X(-0.23), y: Y(s), width: 0.46 * ppmX, height: 20 * ppmY))
                s += 35
            }
            // Numerals: "22" rotated 180° (reads to a pilot landing 22), "04" upright.
            drawNumeral("22", ctx: ctx, center: CGPoint(x: W / 2, y: Y(48)),
                        heightPx: 12 * ppmY, rotated: true, color: paint)
            drawNumeral("04", ctx: ctx, center: CGPoint(x: W / 2, y: Y(lengthMeters - 48)),
                        heightPx: 12 * ppmY, rotated: false, color: paint)

            // Wear over the paint near the touchdown zone.
            speckle(ctx, size: CGSize(width: W, height: H), count: 700, seed: 0xDEAD,
                    radius: 2...9,
                    colors: [(worldColor(0.14, 0.135, 0.13), 0.20)])
        }
    }

    private static func drawNumeral(_ text: String, ctx: CGContext, center: CGPoint,
                                    heightPx: CGFloat, rotated: Bool, color: UIColor) {
        let font = UIFont(name: "AvenirNextCondensed-Bold", size: heightPx * 0.82)
            ?? UIFont.systemFont(ofSize: heightPx * 0.82, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: heightPx * 0.16]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        if rotated { ctx.rotate(by: .pi) }
        // Stretch vertically toward real runway-numeral proportions.
        ctx.scaleBy(x: 1.0, y: 1.55)
        UIGraphicsPushContext(ctx)
        str.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
        UIGraphicsPopContext()
        ctx.restoreGState()
    }

    /// Tileable taxiway/apron-road asphalt, slightly lighter than the runway.
    static func taxiAsphalt() -> UIImage {
        image(CGSize(width: 512, height: 512)) { ctx, size in
            ctx.setFillColor(worldColor(0.205, 0.195, 0.185).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            speckle(ctx, size: size, count: 1500, seed: 0x7A21, radius: 0.7...3.0,
                    colors: [(worldColor(0.30, 0.29, 0.27), 0.12),
                             (worldColor(0.11, 0.11, 0.11), 0.12),
                             (worldColor(0.27, 0.23, 0.19), 0.06)], wrap: true)
            speckle(ctx, size: size, count: 26, seed: 0x7A22, radius: 20...60,
                    colors: [(worldColor(0.17, 0.165, 0.16), 0.10),
                             (worldColor(0.24, 0.23, 0.215), 0.08)], wrap: true)
        }
    }

    /// Apron concrete with tiedown rows, expansion joints and oil stains.
    /// Maps rect s∈[s0,s0+sLen], p∈[p0,p0+pLen] (runway-frame meters).
    static func apron(s0: Double, sLen: Double, p0: Double, pLen: Double,
                      spots: [(s: Double, p: Double)], vipSpot: (s: Double, p: Double)?) -> UIImage {
        let W: CGFloat = 2048, H: CGFloat = 1280
        let sx = W / CGFloat(sLen), sy = H / CGFloat(pLen)
        func P(_ s: Double, _ p: Double) -> CGPoint {
            CGPoint(x: CGFloat(s - s0) * sx, y: CGFloat(p - p0) * sy)
        }
        return image(CGSize(width: W, height: H)) { ctx, size in
            ctx.setFillColor(worldColor(0.435, 0.415, 0.385).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            speckle(ctx, size: size, count: 4200, seed: 0xC0C0, radius: 0.7...3.4,
                    colors: [(worldColor(0.55, 0.53, 0.50), 0.12),
                             (worldColor(0.30, 0.29, 0.27), 0.10),
                             (worldColor(0.47, 0.42, 0.35), 0.07)])
            speckle(ctx, size: size, count: 40, seed: 0xC0C1, radius: 40...150,
                    colors: [(worldColor(0.38, 0.365, 0.34), 0.10),
                             (worldColor(0.49, 0.47, 0.44), 0.08)])
            // Expansion joints every ~15 m.
            ctx.setStrokeColor(worldColor(0.24, 0.23, 0.215, 0.55).cgColor)
            ctx.setLineWidth(2.2)
            var s = s0 + 8.0
            while s < s0 + sLen { ctx.move(to: P(s, p0)); ctx.addLine(to: P(s, p0 + pLen)); s += 15 }
            var p = p0 + 8.0
            while p < p0 + pLen { ctx.move(to: P(s0, p)); ctx.addLine(to: P(s0 + sLen, p)); p += 15 }
            ctx.strokePath()
            var rng = WorldRand(seed: 0x011E)
            // Tiedowns + stains per spot.
            for spot in spots {
                let c = P(spot.s, spot.p)
                // taxi lead-in line
                ctx.setStrokeColor(worldColor(0.83, 0.66, 0.12, 0.85).cgColor)
                ctx.setLineWidth(0.18 * Double(sx))
                ctx.move(to: CGPoint(x: c.x, y: c.y - 11 * sy))
                ctx.addLine(to: c)
                ctx.strokePath()
                // tiedown anchors: three small circles in a T
                ctx.setFillColor(worldColor(0.83, 0.66, 0.12, 0.9).cgColor)
                for d in [(-4.6, 0.0), (4.6, 0.0), (0.0, 3.4)] {
                    let q = CGPoint(x: c.x + CGFloat(d.0) * sx, y: c.y + CGFloat(d.1) * sy)
                    ctx.fillEllipse(in: CGRect(x: q.x - 4, y: q.y - 4, width: 8, height: 8))
                }
                // oil stains
                for _ in 0..<3 {
                    let q = CGPoint(x: c.x + rng.cgRange(-30, 30), y: c.y + rng.cgRange(-16, 26))
                    let r = rng.cgRange(6, 26)
                    ctx.setFillColor(worldColor(0.10, 0.095, 0.09, rng.range(0.10, 0.30)).cgColor)
                    ctx.fillEllipse(in: CGRect(x: q.x - r, y: q.y - r * 0.7, width: r * 2, height: r * 1.4))
                }
            }
            if let vip = vipSpot {
                let c = P(vip.s, vip.p)
                ctx.setStrokeColor(worldColor(0.92, 0.90, 0.86, 0.9).cgColor)
                ctx.setLineWidth(3.5)
                let half: CGFloat = 12 * sx
                // corner brackets
                for (dx, dy) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
                    let corner = CGPoint(x: c.x + CGFloat(dx) * half, y: c.y + CGFloat(dy) * half * 0.62)
                    ctx.move(to: CGPoint(x: corner.x - CGFloat(dx) * 26, y: corner.y))
                    ctx.addLine(to: corner)
                    ctx.addLine(to: CGPoint(x: corner.x, y: corner.y - CGFloat(dy) * 26))
                }
                ctx.strokePath()
            }
        }
    }

    /// Tileable dry-scrub grass — warm sage-olive with golden burn patches.
    static func grass() -> UIImage {
        image(CGSize(width: 1024, height: 1024)) { ctx, size in
            ctx.setFillColor(worldColor(0.408, 0.408, 0.262).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            speckle(ctx, size: size, count: 70, seed: 0x6A55, radius: 60...220,
                    colors: [(worldColor(0.55, 0.50, 0.28), 0.16),     // dry gold
                             (worldColor(0.34, 0.37, 0.21), 0.18),     // deeper olive
                             (worldColor(0.50, 0.44, 0.30), 0.12)], wrap: true)
            speckle(ctx, size: size, count: 2600, seed: 0x6A56, radius: 1.5...6,
                    colors: [(worldColor(0.30, 0.32, 0.18), 0.20),
                             (worldColor(0.58, 0.52, 0.30), 0.16),
                             (worldColor(0.45, 0.46, 0.28), 0.14)], wrap: true)
            speckle(ctx, size: size, count: 500, seed: 0x6A57, radius: 0.8...2,
                    colors: [(worldColor(0.62, 0.57, 0.38), 0.28)], wrap: true)
        }
    }

    /// Cliff strata: v=0 at the rim, v=1 at the waterline (talus band).
    static func cliff() -> UIImage {
        image(CGSize(width: 512, height: 1024)) { ctx, size in
            var rng = WorldRand(seed: 0xC11F)
            let bands: [UIColor] = [
                worldColor(0.565, 0.435, 0.325),
                worldColor(0.645, 0.515, 0.385),
                worldColor(0.485, 0.375, 0.290),
                worldColor(0.610, 0.470, 0.340),
                worldColor(0.530, 0.415, 0.320),
            ]
            var y: CGFloat = 0
            var i = 0
            while y < size.height {
                let h = rng.cgRange(26, 70)
                ctx.setFillColor(bands[i % bands.count].cgColor)
                ctx.fill(CGRect(x: 0, y: y - 2, width: size.width, height: h + 4))
                y += h; i += 1
            }
            // Vertical erosion streaks.
            for _ in 0..<160 {
                let x = rng.cgRange(0, size.width)
                let w = rng.cgRange(2, 12)
                let dark = rng.unit() > 0.4
                let c = dark ? worldColor(0.30, 0.24, 0.19) : worldColor(0.70, 0.58, 0.45)
                ctx.setFillColor(c.withAlphaComponent(rng.cgRange(0.05, 0.16)).cgColor)
                ctx.fill(CGRect(x: x, y: rng.cgRange(-60, 200), width: w, height: rng.cgRange(300, 900)))
            }
            speckle(ctx, size: size, count: 1400, seed: 0xC120, radius: 1...5,
                    colors: [(worldColor(0.32, 0.26, 0.20), 0.16),
                             (worldColor(0.72, 0.60, 0.46), 0.13)])
            // Talus fading up from the waterline.
            let talus = worldColor(0.545, 0.495, 0.435)
            for step in 0..<26 {
                let f = CGFloat(step) / 25
                ctx.setFillColor(talus.withAlphaComponent(0.05).cgColor)
                ctx.fill(CGRect(x: 0, y: size.height - 170 + f * 170, width: size.width, height: 170))
            }
        }
    }

    /// Tileable dirt for the service road.
    static func dirt() -> UIImage {
        image(CGSize(width: 256, height: 256)) { ctx, size in
            ctx.setFillColor(worldColor(0.475, 0.405, 0.310).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            speckle(ctx, size: size, count: 700, seed: 0xD127, radius: 0.8...3.5,
                    colors: [(worldColor(0.56, 0.48, 0.37), 0.16),
                             (worldColor(0.35, 0.30, 0.23), 0.16)], wrap: true)
            // wheel ruts along v
            ctx.setFillColor(worldColor(0.395, 0.335, 0.255, 0.5).cgColor)
            ctx.fill(CGRect(x: size.width * 0.24, y: 0, width: size.width * 0.10, height: size.height))
            ctx.fill(CGRect(x: size.width * 0.66, y: 0, width: size.width * 0.10, height: size.height))
        }
    }

    /// Corrugated metal wall, parameterized base tone.
    static func corrugated(r: Double, g: Double, b: Double, rust: Double, seed: UInt64) -> UIImage {
        image(CGSize(width: 256, height: 256)) { ctx, size in
            ctx.setFillColor(worldColor(r, g, b).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            // Vertical ribs.
            for x in stride(from: 0, to: Int(size.width), by: 8) {
                ctx.setFillColor(worldColor(1, 1, 1, 0.10).cgColor)
                ctx.fill(CGRect(x: CGFloat(x), y: 0, width: 2.6, height: size.height))
                ctx.setFillColor(worldColor(0, 0, 0, 0.13).cgColor)
                ctx.fill(CGRect(x: CGFloat(x) + 4.6, y: 0, width: 2.6, height: size.height))
            }
            var rng = WorldRand(seed: seed)
            // Rust streaks bleeding down.
            for _ in 0..<Int(rust * 34) {
                let x = rng.cgRange(0, size.width)
                let top = rng.cgRange(0, size.height * 0.6)
                let h = rng.cgRange(24, 130)
                ctx.setFillColor(worldColor(0.48, 0.26, 0.13, rng.range(0.08, 0.26)).cgColor)
                ctx.fill(CGRect(x: x, y: top, width: rng.cgRange(2, 7), height: h))
            }
            speckle(ctx, size: size, count: 260, seed: seed &+ 1, radius: 0.8...3,
                    colors: [(worldColor(0, 0, 0), 0.10), (worldColor(1, 1, 1), 0.08)], wrap: true)
        }
    }

    /// Hangar gable front; optionally with a big open dark doorway.
    static func hangarFront(baseR: Double, baseG: Double, baseB: Double,
                            openDoor: Bool, seed: UInt64) -> UIImage {
        image(CGSize(width: 512, height: 384)) { ctx, size in
            // Corrugated backdrop.
            ctx.setFillColor(worldColor(baseR, baseG, baseB).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            for x in stride(from: 0, to: Int(size.width), by: 8) {
                ctx.setFillColor(worldColor(1, 1, 1, 0.09).cgColor)
                ctx.fill(CGRect(x: CGFloat(x), y: 0, width: 2.6, height: size.height))
                ctx.setFillColor(worldColor(0, 0, 0, 0.12).cgColor)
                ctx.fill(CGRect(x: CGFloat(x) + 4.6, y: 0, width: 2.6, height: size.height))
            }
            let doorRect = CGRect(x: size.width * 0.16, y: size.height * 0.30,
                                  width: size.width * 0.68, height: size.height * 0.70)
            if openDoor {
                // Deep warm-dark interior with a faint floor bounce.
                ctx.setFillColor(worldColor(0.055, 0.045, 0.045).cgColor)
                ctx.fill(doorRect)
                ctx.setFillColor(worldColor(0.16, 0.11, 0.08, 0.8).cgColor)
                ctx.fill(CGRect(x: doorRect.minX, y: doorRect.maxY - 26,
                                width: doorRect.width, height: 26))
                // header beam
                ctx.setFillColor(worldColor(baseR * 0.7, baseG * 0.7, baseB * 0.7).cgColor)
                ctx.fill(CGRect(x: doorRect.minX - 10, y: doorRect.minY - 16,
                                width: doorRect.width + 20, height: 16))
            } else {
                // Closed sliding door panels.
                ctx.setFillColor(worldColor(baseR * 0.86, baseG * 0.86, baseB * 0.84).cgColor)
                ctx.fill(doorRect)
                ctx.setStrokeColor(worldColor(0, 0, 0, 0.30).cgColor)
                ctx.setLineWidth(3)
                for i in 0...4 {
                    let x = doorRect.minX + doorRect.width * CGFloat(i) / 4
                    ctx.move(to: CGPoint(x: x, y: doorRect.minY))
                    ctx.addLine(to: CGPoint(x: x, y: doorRect.maxY))
                }
                ctx.strokePath()
            }
            var rng = WorldRand(seed: seed)
            for _ in 0..<20 {
                let x = rng.cgRange(0, size.width)
                ctx.setFillColor(worldColor(0.48, 0.26, 0.13, rng.range(0.06, 0.2)).cgColor)
                ctx.fill(CGRect(x: x, y: rng.cgRange(0, 80), width: rng.cgRange(2, 6), height: rng.cgRange(20, 90)))
            }
        }
    }

    /// White stucco with gentle mottling.
    static func stucco() -> UIImage {
        image(CGSize(width: 256, height: 256)) { ctx, size in
            ctx.setFillColor(worldColor(0.885, 0.845, 0.775).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            speckle(ctx, size: size, count: 600, seed: 0x57CC, radius: 1...6,
                    colors: [(worldColor(0.95, 0.92, 0.86), 0.12),
                             (worldColor(0.74, 0.69, 0.60), 0.10)], wrap: true)
        }
    }

    /// Terminal front: stucco + three arched openings + door.
    static func terminalFront() -> UIImage {
        image(CGSize(width: 512, height: 256)) { ctx, size in
            ctx.setFillColor(worldColor(0.885, 0.845, 0.775).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            speckle(ctx, size: size, count: 500, seed: 0x7E12, radius: 1...5,
                    colors: [(worldColor(0.95, 0.92, 0.86), 0.12),
                             (worldColor(0.74, 0.69, 0.60), 0.10)])
            // Arches.
            for i in 0..<3 {
                let cx = size.width * (0.25 + 0.25 * CGFloat(i))
                let w: CGFloat = 66, top: CGFloat = 92
                let rect = CGRect(x: cx - w / 2, y: top, width: w, height: size.height - top)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + w / 2))
                path.addArc(center: CGPoint(x: cx, y: rect.minY + w / 2), radius: w / 2,
                            startAngle: .pi, endAngle: 0, clockwise: false)
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.closeSubpath()
                ctx.addPath(path)
                ctx.setFillColor(worldColor(0.16, 0.12, 0.10).cgColor)
                ctx.fillPath()
            }
            // Sign band.
            ctx.setFillColor(worldColor(0.42, 0.24, 0.16, 0.9).cgColor)
            ctx.fill(CGRect(x: size.width * 0.30, y: 34, width: size.width * 0.40, height: 26))
        }
    }

    /// Terracotta barrel-tile roof, tileable.
    static func roofTile() -> UIImage {
        image(CGSize(width: 256, height: 256)) { ctx, size in
            ctx.setFillColor(worldColor(0.585, 0.290, 0.195).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            for y in stride(from: 0, to: Int(size.height), by: 22) {
                ctx.setFillColor(worldColor(0, 0, 0, 0.22).cgColor)
                ctx.fill(CGRect(x: 0, y: CGFloat(y) + 17, width: size.width, height: 5))
                ctx.setFillColor(worldColor(1, 0.75, 0.6, 0.14).cgColor)
                ctx.fill(CGRect(x: 0, y: CGFloat(y), width: size.width, height: 4))
                for x in stride(from: 0, to: Int(size.width), by: 16) {
                    ctx.setFillColor(worldColor(0, 0, 0, 0.10).cgColor)
                    ctx.fill(CGRect(x: CGFloat(x + (y / 22 % 2) * 8), y: CGFloat(y), width: 3, height: 20))
                }
            }
            speckle(ctx, size: size, count: 300, seed: 0x8007, radius: 1...4,
                    colors: [(worldColor(0.70, 0.42, 0.28), 0.14),
                             (worldColor(0.42, 0.20, 0.14), 0.14)], wrap: true)
        }
    }

    /// Tower cab glass band with mullions.
    static func towerGlass() -> UIImage {
        image(CGSize(width: 256, height: 128)) { ctx, size in
            ctx.setFillColor(worldColor(0.10, 0.15, 0.19).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            // sky reflection gradient
            let colors = [worldColor(0.55, 0.48, 0.42, 0.55).cgColor,
                          worldColor(0.12, 0.16, 0.22, 0.1).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            ctx.setFillColor(worldColor(0.88, 0.86, 0.82).cgColor)
            for x in stride(from: 0, to: Int(size.width), by: 42) {
                ctx.fill(CGRect(x: CGFloat(x), y: 0, width: 5, height: size.height))
            }
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 6))
            ctx.fill(CGRect(x: 0, y: size.height - 6, width: size.width, height: 6))
        }
    }

    /// Windsock stripes: v runs base→tip (orange/white bands).
    static func windsock() -> UIImage {
        image(CGSize(width: 64, height: 256)) { ctx, size in
            let orange = worldColor(0.94, 0.42, 0.10)
            let white = worldColor(0.93, 0.90, 0.86)
            for i in 0..<5 {
                ctx.setFillColor((i % 2 == 0 ? orange : white).cgColor)
                ctx.fill(CGRect(x: 0, y: CGFloat(i) * size.height / 5,
                                width: size.width, height: size.height / 5 + 1))
            }
        }
    }

    /// Hold-short bar: v=0 side dashed (runway side), v=1 side solid (holding side).
    static func holdShortBar() -> UIImage {
        image(CGSize(width: 512, height: 128), opaque: false) { ctx, size in
            let yellow = worldColor(0.83, 0.66, 0.12, 0.95)
            ctx.setFillColor(yellow.cgColor)
            // dashed pair (toward runway)
            for y in [CGFloat(10), CGFloat(38)] {
                var x: CGFloat = 0
                while x < size.width {
                    ctx.fill(CGRect(x: x, y: y, width: 26, height: 14))
                    x += 44
                }
            }
            // solid pair (holding side)
            ctx.fill(CGRect(x: 0, y: 70, width: size.width, height: 14))
            ctx.fill(CGRect(x: 0, y: 98, width: size.width, height: 14))
        }
    }

    /// Soft elongated white blob for the marine-layer bank.
    static func cloudBank() -> UIImage {
        image(CGSize(width: 512, height: 128), opaque: false) { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height * 0.62)
            let colors = [worldColor(1, 0.98, 0.95, 0.85).cgColor,
                          worldColor(1, 0.98, 0.95, 0.0).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors, locations: [0, 1]) {
                ctx.saveGState()
                ctx.translateBy(x: center.x, y: center.y)
                ctx.scaleBy(x: 1.0, y: 0.22)
                ctx.drawRadialGradient(grad, startCenter: .zero, startRadius: 0,
                                       endCenter: .zero, endRadius: size.width * 0.5, options: [])
                ctx.restoreGState()
            }
        }
    }
}

// MARK: - Materials

enum WorldMat {

    static func pbr(_ contents: Any, roughness: CGFloat, metalness: CGFloat = 0,
                    wrap: Bool = false, doubleSided: Bool = false) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = contents
        m.roughness.contents = roughness
        m.metalness.contents = metalness
        m.isDoubleSided = doubleSided
        if wrap {
            m.diffuse.wrapS = .repeat
            m.diffuse.wrapT = .repeat
        }
        m.diffuse.mipFilter = .linear
        return m
    }

    static let grass: SCNMaterial = pbr(WorldTex.grass(), roughness: 0.95, wrap: true)
    static let cliff: SCNMaterial = {
        let m = pbr(WorldTex.cliff(), roughness: 0.92, doubleSided: true)
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .clamp
        return m
    }()
    static let taxiAsphalt: SCNMaterial = pbr(WorldTex.taxiAsphalt(), roughness: 0.88, wrap: true)
    static let dirt: SCNMaterial = pbr(WorldTex.dirt(), roughness: 0.97, wrap: true)
    static let stripeYellow: SCNMaterial = pbr(worldColor(0.83, 0.66, 0.12), roughness: 0.7)
    static let corrugatedCream: SCNMaterial = pbr(
        WorldTex.corrugated(r: 0.83, g: 0.77, b: 0.66, rust: 1.0, seed: 0x41), roughness: 0.55,
        metalness: 0.25, wrap: true)
    static let corrugatedSage: SCNMaterial = pbr(
        WorldTex.corrugated(r: 0.62, g: 0.63, b: 0.53, rust: 0.6, seed: 0x42), roughness: 0.6,
        metalness: 0.2, wrap: true)
    static let stucco: SCNMaterial = pbr(WorldTex.stucco(), roughness: 0.9, wrap: true)
    static let roofTile: SCNMaterial = pbr(WorldTex.roofTile(), roughness: 0.85, wrap: true)
    static let towerGlass: SCNMaterial = pbr(WorldTex.towerGlass(), roughness: 0.25, metalness: 0.4)
    static let whitePaintMetal: SCNMaterial = pbr(worldColor(0.87, 0.85, 0.80), roughness: 0.5, metalness: 0.1)
    static let scrub1: SCNMaterial = pbr(worldColor(0.375, 0.415, 0.265), roughness: 0.95)
    static let scrub2: SCNMaterial = pbr(worldColor(0.445, 0.445, 0.285), roughness: 0.95)
    static let scrub3: SCNMaterial = pbr(worldColor(0.330, 0.360, 0.235), roughness: 0.95)
    static let boulder: SCNMaterial = pbr(worldColor(0.575, 0.500, 0.415), roughness: 0.9)
}
