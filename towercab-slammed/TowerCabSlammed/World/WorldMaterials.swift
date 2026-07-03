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
/// Yaw (radians about +Y) so a node's local +Z faces along 2D direction `d`.
@inline(__always) func worldYawFacing(_ d: V2) -> Float { Float(atan2(d.x, d.y)) }

/// Runway-relative coordinates: s = meters along the 22 roll from threshold B,
/// p = meters toward the tower/apron side — TRUE southeast (A7 flip).
struct FieldFrame {
    let origin: V2
    let dir: V2
    let perp: V2
    let length: Double
    init(_ airport: AirportLayout) {
        origin = airport.runway.thresholdB
        dir = airport.runway.dir22
        perp = V2(dir.y, -dir.x)          // matches KAVXAirport's perpSE exactly
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
    /// (flipped toward `hint` if provided). `uv` may spread a small patch so a
    /// multiply texture reads as per-facet albedo jitter (D11).
    mutating func facet(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                        hint: SIMD3<Float>? = nil, uv: SIMD2<Float> = .zero,
                        uvSpread: Float = 0) {
        var n = simd_cross(b - a, c - a)
        let len = simd_length(n)
        n = len > 1e-6 ? n / len : SIMD3(0, 1, 0)
        if let h = hint, simd_dot(n, h) < 0 { n = -n }
        let uvb = uv + SIMD2(uvSpread, 0)
        let uvc = uv + SIMD2(0, uvSpread)
        let ia = add(a, n, uv), ib = add(b, n, uvb), ic = add(c, n, uvc)
        let geoN = simd_cross(b - a, c - a)
        if simd_dot(geoN, n) >= 0 { triangle(ia, ib, ic) } else { triangle(ia, ic, ib) }
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
        // Standard (8-bit sRGB) range: on wide-gamut devices .automatic yields
        // an extended-range image whose Metal pixel format SceneKit rejects at
        // draw time (invalid-MTLPixelFormat abort). Force 8-bit here.
        fmt.preferredRange = .standard
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
    /// A3: 2019 re-poured CONCRETE — light-grey slabs with a visible joint
    /// grid (~6×6 m), crisp, minimal rubber. A5: BASIC visual markings only —
    /// numbers ("22"/"4") + centerline dashes, nothing else.
    static func runway(lengthMeters: Double, widthMeters: Double) -> UIImage {
        let W: CGFloat = 1024, H: CGFloat = 6144
        let ppmX = W / CGFloat(widthMeters)          // ≈ 44.7 px/m across
        let ppmY = H / CGFloat(lengthMeters)         // ≈ 6.7 px/m along
        func X(_ metersFromCenter: Double) -> CGFloat { W / 2 + CGFloat(metersFromCenter) * ppmX }
        func Y(_ stationFrom22: Double) -> CGFloat { CGFloat(stationFrom22) * ppmY }

        return image(CGSize(width: W, height: H)) { ctx, size in
            // Fresh light-grey concrete base.
            ctx.setFillColor(worldColor(0.615, 0.605, 0.585).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))

            // Per-slab tone variation (slabs ≈ 6 m along × 4 lanes across).
            var rng = WorldRand(seed: 0xA11C)
            let slabAlong = 6.0
            let lanes = 4
            var s = 0.0
            while s < lengthMeters {
                for lane in 0..<lanes {
                    let x0 = CGFloat(lane) / CGFloat(lanes) * W
                    let tone = rng.range(-0.045, 0.045)
                    let c = tone >= 0 ? worldColor(1, 1, 0.97, tone) : worldColor(0.1, 0.1, 0.12, -tone)
                    ctx.setFillColor(c.cgColor)
                    ctx.fill(CGRect(x: x0, y: Y(s), width: W / CGFloat(lanes),
                                    height: CGFloat(slabAlong) * ppmY + 1))
                }
                s += slabAlong
            }
            // Fine aggregate noise + faint sun-bleach patches.
            speckle(ctx, size: size, count: 5200, seed: 0xF00D,
                    radius: 0.6...2.4,
                    colors: [(worldColor(0.72, 0.71, 0.69), 0.09),
                             (worldColor(0.46, 0.45, 0.44), 0.08),
                             (worldColor(0.58, 0.55, 0.50), 0.05)])
            speckle(ctx, size: size, count: 90, seed: 0xF00E, radius: 40...160,
                    colors: [(worldColor(0.68, 0.67, 0.64), 0.06),
                             (worldColor(0.54, 0.53, 0.51), 0.05)])

            // Joint grid — crisp saw-cut lines.
            ctx.setStrokeColor(worldColor(0.40, 0.39, 0.38, 0.60).cgColor)
            ctx.setLineWidth(2.4)
            s = 0
            while s <= lengthMeters {
                ctx.move(to: CGPoint(x: 0, y: Y(s)))
                ctx.addLine(to: CGPoint(x: W, y: Y(s)))
                s += slabAlong
            }
            for lane in 0...lanes {
                let x = CGFloat(lane) / CGFloat(lanes) * W
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: H))
            }
            ctx.strokePath()
            // A few hairline cracks only — it's a 2019 pour.
            ctx.setLineWidth(1.0)
            for _ in 0..<14 {
                ctx.setStrokeColor(worldColor(0.38, 0.37, 0.36, rng.range(0.15, 0.28)).cgColor)
                var p = CGPoint(x: rng.cgRange(30, W - 30), y: rng.cgRange(0, H))
                ctx.move(to: p)
                for _ in 0..<rng.int(4) + 2 {
                    p.x += rng.cgRange(-20, 20); p.y += rng.cgRange(12, 70)
                    ctx.addLine(to: p)
                }
                ctx.strokePath()
            }
            // Minimal rubber: a light kiss in the 22 touchdown zone only.
            var r = WorldRand(seed: 0xB00B)
            for _ in 0..<70 {
                let st = r.range(140, 330)
                let off = r.range(-1, 1)
                let lateral = off * off * off * 4.8
                let cx = X(lateral + (r.unit() > 0.5 ? 2.6 : -2.6))
                let w = r.cgRange(8, 22), h = r.cgRange(30, 110)
                ctx.setFillColor(worldColor(0.22, 0.22, 0.23, 0.07 * r.range(0.4, 1)).cgColor)
                ctx.fillEllipse(in: CGRect(x: cx - w / 2, y: Y(st) - h / 2, width: w, height: h))
            }

            // ---- Paint (A5: numbers + centerline ONLY) ----
            let paint = worldColor(0.94, 0.93, 0.90, 0.93)
            ctx.setFillColor(paint.cgColor)

            // Centerline dashes (36.6 m dash / 24.4 m gap, 0.9 m wide).
            var cs = 66.0
            while cs + 36.6 < lengthMeters - 66 {
                ctx.fill(CGRect(x: X(-0.45), y: Y(cs), width: 0.9 * ppmX, height: 36.6 * ppmY))
                cs += 61.0
            }
            // Numerals as thick stroke glyphs, 18 m tall (A5/D17).
            // "22" reads to a pilot landing 22 (rotated); "4" upright (single
            // digit — not "04").
            strokeNumeral("22", ctx: ctx, center: CGPoint(x: W / 2, y: Y(45)),
                          ppmX: ppmX, ppmY: ppmY, rotated: true, color: paint)
            strokeNumeral("4", ctx: ctx, center: CGPoint(x: W / 2, y: Y(lengthMeters - 45)),
                          ppmX: ppmX, ppmY: ppmY, rotated: false, color: paint)

            // Subtle weathering over everything.
            speckle(ctx, size: size, count: 420, seed: 0xDEAD, radius: 2...8,
                    colors: [(worldColor(0.50, 0.49, 0.47), 0.08)])
        }
    }

    /// FAA-style stroke glyphs, drawn in meter space (18 m tall, ~1.5 m stroke).
    private static func strokeNumeral(_ text: String, ctx: CGContext, center: CGPoint,
                                      ppmX: CGFloat, ppmY: CGFloat, rotated: Bool, color: UIColor) {
        // Digit paths in a unit box (x 0…1 ≈ 6.2 m wide, y 0…1 = 18 m, y down).
        func strokes(for ch: Character) -> [[CGPoint]] {
            switch ch {
            case "2":
                return [[CGPoint(x: 0.06, y: 0.24), CGPoint(x: 0.16, y: 0.08),
                         CGPoint(x: 0.50, y: 0.03), CGPoint(x: 0.84, y: 0.08),
                         CGPoint(x: 0.94, y: 0.24), CGPoint(x: 0.88, y: 0.44),
                         CGPoint(x: 0.10, y: 0.88), CGPoint(x: 0.06, y: 0.97),
                         CGPoint(x: 0.94, y: 0.97)]]
            case "4":
                return [[CGPoint(x: 0.58, y: 0.03), CGPoint(x: 0.06, y: 0.60),
                         CGPoint(x: 0.06, y: 0.66), CGPoint(x: 0.94, y: 0.66)],
                        [CGPoint(x: 0.66, y: 0.34), CGPoint(x: 0.66, y: 0.97)]]
            default:
                return []
            }
        }
        let heightM = 18.0, widthM = 6.2, gapM = 2.6, strokeM = 1.5
        let digits = Array(text)
        let totalW = Double(digits.count) * widthM + Double(digits.count - 1) * gapM
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        if rotated { ctx.rotate(by: .pi) }
        ctx.scaleBy(x: ppmX, y: ppmY)          // now drawing in meters
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(CGFloat(strokeM))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for (i, ch) in digits.enumerated() {
            let x0 = -totalW / 2 + Double(i) * (widthM + gapM)
            for stroke in strokes(for: ch) {
                guard let first = stroke.first else { continue }
                ctx.move(to: CGPoint(x: CGFloat(x0) + first.x * CGFloat(widthM),
                                     y: (first.y - 0.5) * CGFloat(heightM)))
                for pt in stroke.dropFirst() {
                    ctx.addLine(to: CGPoint(x: CGFloat(x0) + pt.x * CGFloat(widthM),
                                            y: (pt.y - 0.5) * CGFloat(heightM)))
                }
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }

    /// Tileable taxiway/apron pavement — older grey-worn concrete/asphalt mix,
    /// subtly darker than the fresh runway (A3).
    static func taxiAsphalt() -> UIImage {
        image(CGSize(width: 512, height: 512)) { ctx, size in
            ctx.setFillColor(worldColor(0.455, 0.445, 0.425).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            speckle(ctx, size: size, count: 1500, seed: 0x7A21, radius: 0.7...3.0,
                    colors: [(worldColor(0.58, 0.57, 0.55), 0.11),
                             (worldColor(0.30, 0.30, 0.29), 0.11),
                             (worldColor(0.50, 0.45, 0.38), 0.06)], wrap: true)
            speckle(ctx, size: size, count: 26, seed: 0x7A22, radius: 20...60,
                    colors: [(worldColor(0.40, 0.39, 0.375), 0.10),
                             (worldColor(0.51, 0.50, 0.48), 0.08)], wrap: true)
            // Old patched joints wandering through.
            var rng = WorldRand(seed: 0x7A23)
            ctx.setLineWidth(2.5)
            for _ in 0..<5 {
                ctx.setStrokeColor(worldColor(0.33, 0.32, 0.31, rng.range(0.25, 0.45)).cgColor)
                let vertical = rng.unit() > 0.5
                var p = vertical ? CGPoint(x: rng.cgRange(0, size.width), y: 0)
                                 : CGPoint(x: 0, y: rng.cgRange(0, size.height))
                ctx.move(to: p)
                while (vertical ? p.y : p.x) < size.width {
                    if vertical { p.y += 60; p.x += rng.cgRange(-5, 5) }
                    else { p.x += 60; p.y += rng.cgRange(-5, 5) }
                    ctx.addLine(to: p)
                }
                ctx.strokePath()
            }
        }
    }

    /// Ramp concrete (D18): visible joints, three paved transient spots with
    /// double-size tiedown Ts (white outline), green edge marks (A8), oil
    /// clusters, plus a solid perimeter line (D16).
    /// Maps rect s∈[s0,s0+sLen], p∈[p0,p0+pLen] (runway-frame meters).
    static func apron(s0: Double, sLen: Double, p0: Double, pLen: Double,
                      spots: [(s: Double, p: Double)]) -> UIImage {
        let W: CGFloat = 2048, H: CGFloat = 560
        let sx = W / CGFloat(sLen), sy = H / CGFloat(pLen)
        func P(_ s: Double, _ p: Double) -> CGPoint {
            CGPoint(x: CGFloat(s - s0) * sx, y: CGFloat(p - p0) * sy)
        }
        return image(CGSize(width: W, height: H)) { ctx, size in
            // Old concrete, −8% from the previous base (D18).
            ctx.setFillColor(worldColor(0.400, 0.382, 0.354).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            speckle(ctx, size: size, count: 4200, seed: 0xC0C0, radius: 0.7...3.4,
                    colors: [(worldColor(0.51, 0.49, 0.46), 0.12),
                             (worldColor(0.28, 0.27, 0.25), 0.10),
                             (worldColor(0.43, 0.39, 0.32), 0.07)])
            speckle(ctx, size: size, count: 40, seed: 0xC0C1, radius: 40...150,
                    colors: [(worldColor(0.35, 0.335, 0.31), 0.10),
                             (worldColor(0.45, 0.43, 0.40), 0.08)])
            // Expansion joints every ~7.5 m — 4 px, strong enough to read
            // from the cab (D18).
            ctx.setStrokeColor(worldColor(0.22, 0.21, 0.195, 0.70).cgColor)
            ctx.setLineWidth(4)
            var s = s0 + 5.0
            while s < s0 + sLen { ctx.move(to: P(s, p0)); ctx.addLine(to: P(s, p0 + pLen)); s += 7.5 }
            var p = p0 + 5.0
            while p < p0 + pLen { ctx.move(to: P(s0, p)); ctx.addLine(to: P(s0 + sLen, p)); p += 7.5 }
            ctx.strokePath()

            var rng = WorldRand(seed: 0x011E)
            for spot in spots {
                let c = P(spot.s, spot.p)
                // Tiedown T at 2× with a white outline (D18).
                let armPx = CGFloat(6.0) * sx          // was ~3 m arms → 6 m
                let stemPx = CGFloat(4.5) * sy
                func tPath(_ width: CGFloat) {
                    ctx.setLineWidth(width)
                    ctx.setLineCap(.round)
                    ctx.move(to: CGPoint(x: c.x - armPx, y: c.y))
                    ctx.addLine(to: CGPoint(x: c.x + armPx, y: c.y))
                    ctx.move(to: CGPoint(x: c.x, y: c.y))
                    ctx.addLine(to: CGPoint(x: c.x, y: c.y + stemPx))
                    ctx.strokePath()
                }
                ctx.setStrokeColor(worldColor(0.93, 0.92, 0.88, 0.85).cgColor)
                tPath(0.44 * sx)
                ctx.setStrokeColor(worldColor(0.80, 0.63, 0.11, 0.95).cgColor)
                tPath(0.24 * sx)
                // Green-painted edge marks — corner brackets (A8, authentic
                // Catalina transient rows).
                ctx.setStrokeColor(worldColor(0.18, 0.44, 0.24, 0.9).cgColor)
                ctx.setLineWidth(0.20 * sx)
                let hw = CGFloat(7.5) * sx, hh = CGFloat(6.5) * sy
                for (dx, dy) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
                    let corner = CGPoint(x: c.x + CGFloat(dx) * hw, y: c.y + CGFloat(dy) * hh)
                    ctx.move(to: CGPoint(x: corner.x - CGFloat(dx) * 2.4 * sx, y: corner.y))
                    ctx.addLine(to: corner)
                    ctx.addLine(to: CGPoint(x: corner.x, y: corner.y - CGFloat(dy) * 2.0 * sy))
                }
                ctx.strokePath()
                // Oil stain clusters (D18).
                for _ in 0..<5 {
                    let q = CGPoint(x: c.x + rng.cgRange(-14, 14), y: c.y + rng.cgRange(-8, 16))
                    let r = rng.cgRange(3, 12)
                    ctx.setFillColor(worldColor(0.10, 0.095, 0.09, rng.range(0.12, 0.32)).cgColor)
                    ctx.fillEllipse(in: CGRect(x: q.x - r, y: q.y - r * 0.7, width: r * 2, height: r * 1.4))
                }
            }
            // Solid apron perimeter line (D16), inset 0.7 m.
            ctx.setStrokeColor(worldColor(0.80, 0.63, 0.11, 0.9).cgColor)
            ctx.setLineWidth(0.16 * sx)
            let inset = CGRect(x: 0.7 * sx, y: 0.7 * sy,
                               width: W - 1.4 * sx, height: H - 1.4 * sy)
            ctx.stroke(inset)
        }
    }

    /// A8 — dirt tiedown infield between the ramp and the taxiway: two cable
    /// rows drawn as thin dark streaks with small anchor dots, parked-wear
    /// ovals, dry grass creeping at the edges.
    static func dirtInfield(s0: Double, sLen: Double, p0: Double, pLen: Double,
                            rowPs: [Double], spots: [(s: Double, p: Double)]) -> UIImage {
        let W: CGFloat = 1536, H: CGFloat = 320
        let sx = W / CGFloat(sLen), sy = H / CGFloat(pLen)
        func P(_ s: Double, _ p: Double) -> CGPoint {
            CGPoint(x: CGFloat(s - s0) * sx, y: CGFloat(p - p0) * sy)
        }
        return image(CGSize(width: W, height: H)) { ctx, size in
            ctx.setFillColor(worldColor(0.472, 0.422, 0.330).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            speckle(ctx, size: size, count: 2600, seed: 0xD1F0, radius: 0.8...3.2,
                    colors: [(worldColor(0.56, 0.50, 0.39), 0.14),
                             (worldColor(0.36, 0.31, 0.24), 0.14)])
            speckle(ctx, size: size, count: 46, seed: 0xD1F1, radius: 20...80,
                    colors: [(worldColor(0.51, 0.46, 0.35), 0.10),
                             (worldColor(0.42, 0.37, 0.28), 0.09)])
            // Dry grass creeping in from the long edges.
            speckle(ctx, size: size, count: 260, seed: 0xD1F2, radius: 3...9,
                    colors: [(worldColor(0.47, 0.44, 0.26), 0.22)])
            var rng = WorldRand(seed: 0xD1F3)
            // Tiedown cables: thin dark streaks running the row length.
            for rowP in rowPs {
                let y = P(0, rowP).y
                ctx.setStrokeColor(worldColor(0.20, 0.18, 0.155, 0.7).cgColor)
                ctx.setLineWidth(2.2)
                ctx.move(to: CGPoint(x: 0.04 * W, y: y))
                ctx.addLine(to: CGPoint(x: 0.96 * W, y: y))
                ctx.strokePath()
                // faint parallel wear line where wheels sit
                ctx.setStrokeColor(worldColor(0.38, 0.33, 0.25, 0.5).cgColor)
                ctx.setLineWidth(5.0)
                ctx.move(to: CGPoint(x: 0.04 * W, y: y + 3.2 * sy))
                ctx.addLine(to: CGPoint(x: 0.96 * W, y: y + 3.2 * sy))
                ctx.strokePath()
            }
            for spot in spots {
                let c = P(spot.s, spot.p)
                // Anchor dots on the cable at each wing/tail point.
                ctx.setFillColor(worldColor(0.13, 0.12, 0.11, 0.9).cgColor)
                for dxM in [-4.6, 0.0, 4.6] {
                    let q = CGPoint(x: c.x + CGFloat(dxM) * sx, y: c.y)
                    ctx.fillEllipse(in: CGRect(x: q.x - 2.6, y: q.y - 2.6, width: 5.2, height: 5.2))
                }
                // Parked-aircraft wear oval.
                ctx.setFillColor(worldColor(0.42, 0.37, 0.285, rng.range(0.25, 0.4)).cgColor)
                ctx.fillEllipse(in: CGRect(x: c.x - 5.5 * sx, y: c.y - 3.0 * sy,
                                           width: 11 * sx, height: 7.5 * sy))
            }
        }
    }

    /// Tileable dry-summer grass (D12): warm golden sage base + burn patches.
    static func grass() -> UIImage {
        image(CGSize(width: 1024, height: 1024)) { ctx, size in
            ctx.setFillColor(worldColor(0.472, 0.438, 0.258).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            speckle(ctx, size: size, count: 70, seed: 0x6A55, radius: 60...220,
                    colors: [(worldColor(0.60, 0.53, 0.29), 0.26),     // dry gold (D12)
                             (worldColor(0.37, 0.39, 0.22), 0.18),     // deeper olive
                             (worldColor(0.53, 0.47, 0.31), 0.14)], wrap: true)
            speckle(ctx, size: size, count: 2600, seed: 0x6A56, radius: 1.5...6,
                    colors: [(worldColor(0.33, 0.35, 0.19), 0.20),
                             (worldColor(0.62, 0.55, 0.31), 0.16),
                             (worldColor(0.49, 0.49, 0.29), 0.14)], wrap: true)
            speckle(ctx, size: size, count: 500, seed: 0x6A57, radius: 0.8...2,
                    colors: [(worldColor(0.66, 0.60, 0.39), 0.28)], wrap: true)
        }
    }

    /// D12 — macro variation octave: large soft blotches, tiled ~400 m,
    /// multiplied over the grass so the mesa never reads as one flat tile.
    static func grassMacro() -> UIImage {
        image(CGSize(width: 256, height: 256)) { ctx, size in
            ctx.setFillColor(UIColor(white: 0.96, alpha: 1).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            speckle(ctx, size: size, count: 26, seed: 0x6A60, radius: 30...110,
                    colors: [(UIColor(white: 0.82, alpha: 1), 0.5),
                             (UIColor(white: 1.0, alpha: 1), 0.45)], wrap: true)
            speckle(ctx, size: size, count: 60, seed: 0x6A61, radius: 10...40,
                    colors: [(UIColor(white: 0.88, alpha: 1), 0.35),
                             (UIColor(white: 1.0, alpha: 1), 0.3)], wrap: true)
        }
    }

    /// D11 — neutral value noise multiplied over the interior ridges so the
    /// big facets never band. ~0.90…1.0 luminance.
    static func ridgeNoise() -> UIImage {
        image(CGSize(width: 256, height: 256)) { ctx, size in
            ctx.setFillColor(UIColor(white: 0.955, alpha: 1).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            speckle(ctx, size: size, count: 900, seed: 0x41D6, radius: 2...14,
                    colors: [(UIColor(white: 0.86, alpha: 1), 0.30),
                             (UIColor(white: 1.0, alpha: 1), 0.28)], wrap: true)
            speckle(ctx, size: size, count: 36, seed: 0x41D7, radius: 20...70,
                    colors: [(UIColor(white: 0.90, alpha: 1), 0.25),
                             (UIColor(white: 1.0, alpha: 1), 0.22)], wrap: true)
        }
    }

    /// D12 — small tiling normal-map speckle for grass micro detail.
    static func speckleNormal() -> UIImage? {
        let n = 128
        var height = [Double](repeating: 0, count: n * n)
        var rng = WorldRand(seed: 0x6A70)
        for i in 0..<(n * n) { height[i] = rng.unit() }
        // one smoothing pass (wrapping) so bumps are soft
        var smooth = height
        for y in 0..<n {
            for x in 0..<n {
                var acc = 0.0
                for dy in -1...1 {
                    for dx in -1...1 {
                        acc += height[((y + dy + n) % n) * n + ((x + dx + n) % n)]
                    }
                }
                smooth[y * n + x] = acc / 9.0
            }
        }
        var bytes = [UInt8](repeating: 255, count: n * n * 4)
        let amp = 2.2
        for y in 0..<n {
            for x in 0..<n {
                let hx = (smooth[y * n + (x + 1) % n] - smooth[y * n + (x + n - 1) % n]) * amp
                let hy = (smooth[((y + 1) % n) * n + x] - smooth[((y + n - 1) % n) * n + x]) * amp
                var v = SIMD3(-hx, -hy, 1)
                v = simd_normalize(v)
                let i = (y * n + x) * 4
                bytes[i] = UInt8((v.x * 0.5 + 0.5) * 255)
                bytes[i + 1] = UInt8((v.y * 0.5 + 0.5) * 255)
                bytes[i + 2] = UInt8((v.z * 0.5 + 0.5) * 255)
            }
        }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data),
              let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true,
                               intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Cliff strata: v=0 at the rim, v=1 at the waterline (talus band).
    /// D13: luminance range 0.42–0.72, visible erosion streaks, and 2–3 dark
    /// overhang shadow lines.
    static func cliff() -> UIImage {
        image(CGSize(width: 512, height: 1024)) { ctx, size in
            var rng = WorldRand(seed: 0xC11F)
            let bands: [UIColor] = [
                worldColor(0.720, 0.590, 0.445),
                worldColor(0.545, 0.435, 0.330),
                worldColor(0.660, 0.530, 0.395),
                worldColor(0.420, 0.335, 0.265),
                worldColor(0.610, 0.485, 0.360),
                worldColor(0.480, 0.385, 0.300),
            ]
            var y: CGFloat = 0
            var i = 0
            while y < size.height {
                let h = rng.cgRange(26, 70)
                ctx.setFillColor(bands[i % bands.count].cgColor)
                ctx.fill(CGRect(x: 0, y: y - 2, width: size.width, height: h + 4))
                y += h; i += 1
            }
            // Vertical erosion streaks (alpha 0.10–0.30).
            for _ in 0..<160 {
                let x = rng.cgRange(0, size.width)
                let w = rng.cgRange(2, 12)
                let dark = rng.unit() > 0.4
                let c = dark ? worldColor(0.28, 0.22, 0.17) : worldColor(0.76, 0.63, 0.48)
                ctx.setFillColor(c.withAlphaComponent(rng.cgRange(0.10, 0.30)).cgColor)
                ctx.fill(CGRect(x: x, y: rng.cgRange(-60, 200), width: w, height: rng.cgRange(300, 900)))
            }
            speckle(ctx, size: size, count: 1400, seed: 0xC120, radius: 1...5,
                    colors: [(worldColor(0.30, 0.24, 0.18), 0.16),
                             (worldColor(0.78, 0.65, 0.50), 0.13)])
            // Overhang shadow lines — hard top edge, soft falloff below (D13).
            for vf in [0.18, 0.42, 0.63] {
                let top = size.height * CGFloat(vf)
                for step in 0..<8 {
                    let a = 0.30 * (1 - CGFloat(step) / 8)
                    ctx.setFillColor(worldColor(0.16, 0.12, 0.09, Double(a)).cgColor)
                    ctx.fill(CGRect(x: 0, y: top + CGFloat(step) * 2.2, width: size.width, height: 2.2))
                }
            }
            // Talus fading up from the waterline.
            let talus = worldColor(0.545, 0.495, 0.435)
            for step in 0..<26 {
                let f = CGFloat(step) / 25
                ctx.setFillColor(talus.withAlphaComponent(0.05).cgColor)
                ctx.fill(CGRect(x: 0, y: size.height - 170 + f * 170, width: size.width, height: 170))
            }
        }
    }

    /// Tileable dirt for the service road (D19): warmer base, doubled rut
    /// contrast, feathered edges (u = across the road).
    static func dirt() -> UIImage {
        image(CGSize(width: 256, height: 256), opaque: false) { ctx, size in
            ctx.setFillColor(worldColor(0.455, 0.415, 0.335).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            speckle(ctx, size: size, count: 700, seed: 0xD127, radius: 0.8...3.5,
                    colors: [(worldColor(0.55, 0.49, 0.39), 0.16),
                             (worldColor(0.34, 0.30, 0.23), 0.16)], wrap: true)
            // Wheel ruts along v — contrast doubled (D19).
            ctx.setFillColor(worldColor(0.335, 0.290, 0.215, 0.95).cgColor)
            ctx.fill(CGRect(x: size.width * 0.24, y: 0, width: size.width * 0.10, height: size.height))
            ctx.fill(CGRect(x: size.width * 0.66, y: 0, width: size.width * 0.10, height: size.height))
            // pale crown between the ruts
            ctx.setFillColor(worldColor(0.52, 0.47, 0.38, 0.5).cgColor)
            ctx.fill(CGRect(x: size.width * 0.44, y: 0, width: size.width * 0.12, height: size.height))
            // Edge feather: alpha falls off over the outer 14% each side.
            let feather = size.width * 0.14
            for step in 0..<16 {
                let f = CGFloat(step) / 15
                ctx.setBlendMode(.destinationOut)
                ctx.setFillColor(UIColor(white: 0, alpha: (1 - f) * 0.35).cgColor)
                ctx.fill(CGRect(x: f * feather - 2, y: 0, width: feather / 15 + 3, height: size.height))
                ctx.fill(CGRect(x: size.width - f * feather - feather / 15 - 1, y: 0,
                                width: feather / 15 + 3, height: size.height))
                ctx.setBlendMode(.normal)
            }
        }
    }

    /// Bare-earth pad texture for under buildings (opaque, no ruts).
    static func dirtPad() -> UIImage {
        image(CGSize(width: 128, height: 128)) { ctx, size in
            ctx.setFillColor(worldColor(0.465, 0.42, 0.335).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            speckle(ctx, size: size, count: 260, seed: 0xD128, radius: 0.8...3.2,
                    colors: [(worldColor(0.55, 0.49, 0.39), 0.15),
                             (worldColor(0.36, 0.31, 0.24), 0.15)], wrap: true)
        }
    }

    /// D3 — broken foam band, alpha, scrolled slowly along the cliff base.
    /// u = across the ring width (feathered), v = along the perimeter.
    static func foamBand() -> UIImage {
        image(CGSize(width: 128, height: 512), opaque: false) { ctx, size in
            var rng = WorldRand(seed: 0xF0A3)
            for _ in 0..<70 {
                let y = rng.cgRange(0, size.height)
                let w = rng.cgRange(20, 70)
                let h = rng.cgRange(8, 30)
                let x = size.width * rng.cgRange(0.18, 0.82) - w / 2
                let a = rng.cgRange(0.35, 0.9)
                ctx.setFillColor(worldColor(0.96, 0.99, 1.0, Double(a)).cgColor)
                ctx.fillEllipse(in: CGRect(x: x, y: y - h / 2, width: w, height: h))
                if y < 40 {   // wrap seam
                    ctx.fillEllipse(in: CGRect(x: x, y: y + size.height - h / 2, width: w, height: h))
                }
            }
            // Feather across u so both edges dissolve.
            for step in 0..<20 {
                let f = CGFloat(step) / 19
                ctx.setBlendMode(.destinationOut)
                ctx.setFillColor(UIColor(white: 0, alpha: (1 - f) * 0.5).cgColor)
                let bandW = size.width * 0.30 / 20
                ctx.fill(CGRect(x: f * size.width * 0.30, y: 0, width: bandW + 2, height: size.height))
                ctx.fill(CGRect(x: size.width - f * size.width * 0.30 - bandW - 1, y: 0,
                                width: bandW + 2, height: size.height))
                ctx.setBlendMode(.normal)
            }
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

    /// Whitewashed stucco with gentle mottling (A9 — Spanish Colonial).
    static func stucco() -> UIImage {
        image(CGSize(width: 256, height: 256)) { ctx, size in
            ctx.setFillColor(worldColor(0.925, 0.895, 0.835).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            speckle(ctx, size: size, count: 600, seed: 0x57CC, radius: 1...6,
                    colors: [(worldColor(0.97, 0.95, 0.90), 0.12),
                             (worldColor(0.80, 0.75, 0.66), 0.10)], wrap: true)
        }
    }

    /// A9 — two-story Spanish Colonial terminal front: whitewashed stucco,
    /// five-arch arcade at grade, upper windows, a blue-and-gold tile band.
    /// Maps the 18 m × 7.2 m front face.
    static func terminalFront() -> UIImage {
        image(CGSize(width: 640, height: 256)) { ctx, size in
            ctx.setFillColor(worldColor(0.925, 0.895, 0.835).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            speckle(ctx, size: size, count: 500, seed: 0x7E12, radius: 1...5,
                    colors: [(worldColor(0.97, 0.95, 0.90), 0.12),
                             (worldColor(0.80, 0.75, 0.66), 0.10)])
            // Ground-floor arcade: five arches (openings into shaded patio).
            let archW: CGFloat = 74, springY = size.height * 0.62
            for i in 0..<5 {
                let cx = size.width * (0.5 + CGFloat(i - 2) * 0.185)
                let rect = CGRect(x: cx - archW / 2, y: springY, width: archW, height: size.height - springY)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: rect.minX, y: size.height))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + archW / 2))
                path.addArc(center: CGPoint(x: cx, y: rect.minY + archW / 2), radius: archW / 2,
                            startAngle: .pi, endAngle: 0, clockwise: false)
                path.addLine(to: CGPoint(x: rect.maxX, y: size.height))
                path.closeSubpath()
                ctx.addPath(path)
                ctx.setFillColor(worldColor(0.17, 0.13, 0.11).cgColor)
                ctx.fillPath()
                // warm patio bounce at the floor line
                ctx.setFillColor(worldColor(0.34, 0.22, 0.15, 0.8).cgColor)
                ctx.fill(CGRect(x: rect.minX + 3, y: size.height - 14, width: rect.width - 6, height: 14))
            }
            // Blue-and-gold Catalina tile band between the floors.
            let bandY = size.height * 0.46
            ctx.setFillColor(worldColor(0.15, 0.30, 0.52).cgColor)
            ctx.fill(CGRect(x: 0, y: bandY, width: size.width, height: 10))
            for x in stride(from: 4, to: Int(size.width), by: 14) {
                ctx.setFillColor(worldColor(0.85, 0.68, 0.20).cgColor)
                ctx.fill(CGRect(x: CGFloat(x), y: bandY + 2.5, width: 5, height: 5))
            }
            // Upper-floor windows (dark; warm glow planes overlay at dusk).
            for i in 0..<4 {
                let cx = size.width * (0.5 + CGFloat(i) * 0.148 - 0.222)
                let r = CGRect(x: cx - 17, y: size.height * 0.13, width: 34, height: 56)
                ctx.setFillColor(worldColor(0.16, 0.13, 0.11).cgColor)
                ctx.fill(r)
                ctx.setStrokeColor(worldColor(0.55, 0.36, 0.22, 0.9).cgColor)
                ctx.setLineWidth(3)
                ctx.stroke(r.insetBy(dx: -2, dy: -2))
            }
        }
    }

    /// Blue-and-gold Catalina tile accent band (thin decorative strip).
    static func tileBand() -> UIImage {
        image(CGSize(width: 256, height: 32)) { ctx, size in
            ctx.setFillColor(worldColor(0.15, 0.30, 0.52).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            for x in stride(from: 4, to: Int(size.width), by: 22) {
                ctx.setFillColor(worldColor(0.85, 0.68, 0.20).cgColor)
                ctx.fill(CGRect(x: CGFloat(x), y: 8, width: 14, height: 16))
                ctx.setFillColor(worldColor(0.10, 0.22, 0.42).cgColor)
                ctx.fill(CGRect(x: CGFloat(x) + 4, y: 12, width: 6, height: 8))
            }
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

    /// Windsock stripes: v runs base→tip (orange/white bands). D23 orange.
    static func windsock() -> UIImage {
        image(CGSize(width: 64, height: 256)) { ctx, size in
            let orange = worldColor(0.98, 0.44, 0.10)
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

    /// A10 — runway distance-remaining board: white numeral on black.
    static func remainingSign(_ text: String) -> UIImage {
        image(CGSize(width: 128, height: 128)) { ctx, size in
            ctx.setFillColor(worldColor(0.06, 0.06, 0.06).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setStrokeColor(worldColor(0.85, 0.85, 0.82).cgColor)
            ctx.setLineWidth(5)
            ctx.stroke(CGRect(x: 5, y: 5, width: size.width - 10, height: size.height - 10))
            let font = UIFont.systemFont(ofSize: 96, weight: .heavy)
            let str = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: worldColor(0.95, 0.95, 0.92)])
            let s = str.size()
            UIGraphicsPushContext(ctx)
            str.draw(at: CGPoint(x: (size.width - s.width) / 2, y: (size.height - s.height) / 2))
            UIGraphicsPopContext()
        }
    }

    /// D-F21 — red/white runway hold sign ("4-22").
    static func holdSign() -> UIImage {
        image(CGSize(width: 256, height: 96)) { ctx, size in
            ctx.setFillColor(worldColor(0.68, 0.08, 0.07).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setStrokeColor(worldColor(0.9, 0.88, 0.85).cgColor)
            ctx.setLineWidth(4)
            ctx.stroke(CGRect(x: 4, y: 4, width: size.width - 8, height: size.height - 8))
            let font = UIFont.systemFont(ofSize: 62, weight: .heavy)
            let str = NSAttributedString(string: "4-22", attributes: [
                .font: font, .foregroundColor: worldColor(0.97, 0.96, 0.93)])
            let s = str.size()
            UIGraphicsPushContext(ctx)
            str.draw(at: CGPoint(x: (size.width - s.width) / 2, y: (size.height - s.height) / 2))
            UIGraphicsPopContext()
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

    /// D12 — dry-summer grass with a ~400 m macro-variation multiply octave
    /// and a 4× detail speckle normal.
    static let grass: SCNMaterial = {
        let m = pbr(WorldTex.grass(), roughness: 0.95, wrap: true)
        m.multiply.contents = WorldTex.grassMacro()
        m.multiply.wrapS = .repeat
        m.multiply.wrapT = .repeat
        // Diffuse tiles at 42 m (mesa UV = meters/42); macro tiles at ~400 m.
        m.multiply.contentsTransform = SCNMatrix4MakeScale(42.0 / 400.0, 42.0 / 400.0, 1)
        if let nrm = WorldTex.speckleNormal() {
            m.normal.contents = nrm
            m.normal.wrapS = .repeat
            m.normal.wrapT = .repeat
            m.normal.contentsTransform = SCNMatrix4MakeScale(4, 4, 1)   // 4× detail
            m.normal.intensity = 0.55
        }
        return m
    }()

    static let cliff: SCNMaterial = {
        let m = pbr(WorldTex.cliff(), roughness: 0.92, doubleSided: true)
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .clamp
        return m
    }()
    static let taxiAsphalt: SCNMaterial = pbr(WorldTex.taxiAsphalt(), roughness: 0.88, wrap: true)
    /// Service-road dirt — feathered alpha edges (D19).
    static let dirt: SCNMaterial = {
        let m = pbr(WorldTex.dirt(), roughness: 0.97, wrap: true)
        m.transparencyMode = .aOne
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        return m
    }()
    static let dirtPad: SCNMaterial = pbr(WorldTex.dirtPad(), roughness: 0.97, wrap: true)
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
    /// D21 — daytime edge-light lens: warm glass, reads as a lamp not debris.
    static let lampGlassHousing: SCNMaterial = pbr(worldColor(0.55, 0.50, 0.42), roughness: 0.3)
    static let fuelPitSteel: SCNMaterial = pbr(worldColor(0.23, 0.23, 0.235), roughness: 0.45, metalness: 0.7)
    // D15 — six scrub tint variants.
    static let scrubTints: [SCNMaterial] = [
        pbr(worldColor(0.375, 0.415, 0.265), roughness: 0.95),
        pbr(worldColor(0.445, 0.445, 0.285), roughness: 0.95),
        pbr(worldColor(0.330, 0.360, 0.235), roughness: 0.95),
        pbr(worldColor(0.470, 0.430, 0.250), roughness: 0.95),
        pbr(worldColor(0.395, 0.380, 0.230), roughness: 0.95),
        pbr(worldColor(0.350, 0.400, 0.290), roughness: 0.95),
    ]
    static let boulder: SCNMaterial = pbr(worldColor(0.575, 0.500, 0.415), roughness: 0.9)
}
