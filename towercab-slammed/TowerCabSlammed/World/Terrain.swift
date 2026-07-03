import Foundation
import SceneKit
import UIKit
import simd

// =============================================================================
// Terrain — the Pacific (living water, D3), the mesa with its 488 m cliffs and
// fBm rim (A11/D4), foam rings at the cliff base, Catalina's painterly
// interior ridges rising ESE/SE (A11/D11), a barely-there mainland band on the
// NE horizon (D14), and the marine-layer bank offshore WNW (real geography).
// Distant landforms are faceted low-poly meshes that hold color, not detail;
// aerial haze (scene fog) does the rest.
// =============================================================================

enum WorldTerrainBuilder {

    static func build(into root: SCNNode, airport: AirportLayout) {
        root.addChildNode(oceanNode(airport: airport))
        root.addChildNode(foamNode(airport: airport))
        root.addChildNode(mesaTopNode(airport: airport))
        root.addChildNode(cliffNode(airport: airport))
        root.addChildNode(ridgesNode(airport: airport))
        root.addChildNode(mainlandNode())
        root.addChildNode(marineLayerNode())
    }

    // MARK: - Ocean (D3 — de-periodized swell, depth gradient, sparkle lane)

    private static func oceanNode(airport: AirportLayout) -> SCNNode {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = worldColor(0.085, 0.24, 0.30)
        material.roughness.contents = 0.12
        material.metalness.contents = 0.0
        material.setValue(NSNumber(value: 0.30), forKey: "rippleGain")
        material.shaderModifiers = [.surface: """
            #pragma arguments
            float rippleGain;
            #pragma body
            float3 wpos = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
            float t = scn_frame.time;
            float2 p = wpos.xz;
            // Octave 1 — long swell.
            float a1 = sin(p.x * 0.019 + t * 0.55 + sin(p.y * 0.011 + t * 0.30) * 1.7);
            float a2 = sin(p.y * 0.023 - t * 0.45 + sin(p.x * 0.013 - t * 0.26) * 1.5);
            // Octave 2 — chop, rotated ~23° so the sets never align (D3).
            float2 q = float2(p.x * 0.9205 - p.y * 0.3907, p.x * 0.3907 + p.y * 0.9205);
            float b1 = sin(q.x * 0.11 + q.y * 0.07 + t * 1.35);
            float b2 = sin(q.x * 0.09 - q.y * 0.13 + t * 1.05);
            // Octave 3 — mid-scale confusion.
            float c1 = sin(p.x * 0.052 - p.y * 0.041 + t * 0.85);
            float c2 = sin(p.y * 0.047 + p.x * 0.036 - t * 0.72);
            float dist = length(_surface.position.xyz);
            float g = rippleGain / (1.0 + dist * 0.00030);
            float3 wn = normalize(float3((a1 * 0.50 + b1 * 0.30 + c1 * 0.20) * g, 1.0,
                                         (a2 * 0.50 + b2 * 0.30 + c2 * 0.20) * g));
            _surface.normal = normalize((scn_frame.viewTransform * float4(wn, 0.0)).xyz);
            // Distance color gradient: coastal teal into deep channel blue.
            float dm = clamp(dist / 9000.0, 0.0, 1.0);
            _surface.diffuse.rgb = mix(float3(0.085, 0.24, 0.30), float3(0.045, 0.13, 0.22), dm);
            // Animated sparkle lane toward the low WSW sun, gated by hash noise.
            float3 cam = scn_frame.inverseViewTransform[3].xyz;
            float2 vd = p - cam.xz;
            float vl = max(length(vd), 1.0);
            float lane = pow(max(dot(vd / vl, float2(-0.921, 0.391)), 0.0), 30.0);
            float2 cell = floor(p * 0.35 + float2(t * 0.9, -t * 0.7));
            float hash = fract(sin(dot(cell, float2(127.1, 311.7))) * 43758.5453);
            float sparkle = step(0.93, hash) * lane;
            _surface.emission.rgb += float3(1.0, 0.78, 0.48) * sparkle * 0.8;
            """]

        let plane = SCNPlane(width: 62_000, height: 62_000)
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.name = "ocean"
        node.eulerAngles.x = -.pi / 2
        node.position = SCNVector3(0, Float(-airport.mesaDropMeters), 0)
        node.castsShadow = false
        return node
    }

    // MARK: - Foam rings at the cliff base (D3)

    private static func foamNode(airport: AirportLayout) -> SCNNode {
        let outline = airport.mesaOutline
        var centroid = V2(0, 0)
        for p in outline { centroid += p }
        centroid /= Double(outline.count)
        let container = SCNNode()
        container.name = "foam"

        func ring(offset: Double, width: Double, opacity: CGFloat, scroll: Double) -> SCNNode {
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = WorldTex.foamBand()
            material.diffuse.wrapS = .repeat
            material.diffuse.wrapT = .repeat
            material.blendMode = .alpha
            material.writesToDepthBuffer = false
            material.isDoubleSided = true
            material.setValue(NSNumber(value: scroll), forKey: "scrollRate")
            material.shaderModifiers = [.geometry: """
                #pragma arguments
                float scrollRate;
                #pragma body
                _geometry.texcoords[0].y += scn_frame.time * scrollRate;
                """]
            var mesh = WorldMesh()
            let up = SIMD3<Float>(0, 1, 0)
            let y = -airport.mesaDropMeters + 0.7          // −487.6
            var prevIn: Int32 = -1, prevOut: Int32 = -1
            var perimeter = 0.0
            // Close the loop with duplicated first-point vertices whose v
            // CONTINUES past the last column (no texture smear at the seam).
            for i in 0...outline.count {
                let p = outline[i % outline.count]
                if i > 0 { perimeter += simd_length(p - outline[i - 1]) }
                let outward = simd_normalize(p - centroid)
                let inner = p + outward * offset
                let outer = p + outward * (offset + width)
                let v = Float(perimeter / 55.0)
                let ii = mesh.add(worldF3(inner, y), up, SIMD2(0, v))
                let oi = mesh.add(worldF3(outer, y), up, SIMD2(1, v))
                if prevIn >= 0 { mesh.quad(prevIn, prevOut, oi, ii, desiredNormal: up) }
                prevIn = ii; prevOut = oi
            }
            let node = SCNNode(geometry: mesh.build(material: material))
            node.opacity = opacity
            node.castsShadow = false
            return node
        }
        container.addChildNode(ring(offset: 18, width: 26, opacity: 0.35, scroll: 0.014))
        container.addChildNode(ring(offset: 73, width: 34, opacity: 0.15, scroll: -0.009))
        return container
    }

    // MARK: - Mesa top (A11 — samples groundHeight: hump profile + knolls)

    private static func mesaTopNode(airport: AirportLayout) -> SCNNode {
        let outline = airport.mesaOutline
        var centroid = V2(0, 0)
        for p in outline { centroid += p }
        centroid /= Double(outline.count)

        var mesh = WorldMesh()
        let rings = 9
        let n = outline.count
        let uvScale: Float = 1.0 / 42.0
        func vertex(_ p: V2) -> Int32 {
            let y = airport.groundHeight(at: p)
            // Numeric normal — the profile is piecewise and carries knolls.
            let d = 6.0
            let hx = (airport.groundHeight(at: p + V2(d, 0)) - airport.groundHeight(at: p - V2(d, 0))) / (2 * d)
            let hz = (airport.groundHeight(at: p + V2(0, d)) - airport.groundHeight(at: p - V2(0, d))) / (2 * d)
            let normal = simd_normalize(SIMD3<Float>(Float(-hx), 1, Float(-hz)))
            return mesh.add(worldF3(p, y), normal,
                            SIMD2(Float(p.x) * uvScale, Float(p.y) * uvScale))
        }
        // Ring 0 = centroid alone; rings 1...R interpolate out to the rim.
        let centerIdx = vertex(centroid)
        var ringIdx: [[Int32]] = []
        for r in 1...rings {
            let f = Double(r) / Double(rings)
            var ring: [Int32] = []
            for i in 0..<n {
                ring.append(vertex(centroid + (outline[i] - centroid) * f))
            }
            ringIdx.append(ring)
        }
        let up = SIMD3<Float>(0, 1, 0)
        for i in 0..<n {
            let j = (i + 1) % n
            let a = centerIdx, b = ringIdx[0][i], c = ringIdx[0][j]
            let pa = mesh.positions[Int(a)], pb = mesh.positions[Int(b)], pc = mesh.positions[Int(c)]
            if simd_dot(simd_cross(pb - pa, pc - pa), up) >= 0 {
                mesh.triangle(a, b, c)
            } else {
                mesh.triangle(a, c, b)
            }
        }
        for r in 0..<(rings - 1) {
            for i in 0..<n {
                let j = (i + 1) % n
                mesh.quad(ringIdx[r][i], ringIdx[r + 1][i], ringIdx[r + 1][j], ringIdx[r][j],
                          desiredNormal: up)
            }
        }
        let node = SCNNode(geometry: mesh.build(material: WorldMat.grass))
        node.name = "mesaTop"
        return node
    }

    // MARK: - Cliffs

    private static func cliffNode(airport: AirportLayout) -> SCNNode {
        let outline = airport.mesaOutline
        var centroid = V2(0, 0)
        for p in outline { centroid += p }
        centroid /= Double(outline.count)

        var rng = WorldRand(seed: 0xC1FF)
        var mesh = WorldMesh()
        let n = outline.count
        let drop = airport.mesaDropMeters
        // Depth fractions rim → waterline; each ring pulls inward and jitters,
        // giving banded, faceted rock that slopes gently in toward the base.
        let depths: [Double] = [0.0, 0.10, 0.30, 0.55, 0.82, 1.0]
        let insets: [Double] = [0.0, 6, 16, 28, 42, 52]

        // Precompute all ring points so quads share exact corners.
        var ringPts: [[SIMD3<Float>]] = []
        var ringUVu: [[Float]] = []
        for (ri, depth) in depths.enumerated() {
            var pts: [SIMD3<Float>] = []
            var us: [Float] = []
            var perimeter: Double = 0
            for i in 0..<n {
                let p = outline[i]
                if i > 0 { perimeter += simd_length(outline[i] - outline[i - 1]) }
                let inward = simd_normalize(centroid - p)
                var jitterAmp = 14.0 * depth * (1 - depth) * 4
                if ri == 0 || ri == depths.count - 1 { jitterAmp = 0 }
                let jitter = rng.range(-jitterAmp, jitterAmp)
                let q = p + inward * (insets[ri] + jitter)
                let yTop = airport.groundHeight(at: p)
                let y = yTop - (yTop + drop) * depth
                pts.append(worldF3(q, y))
                us.append(Float(perimeter / 55.0))
            }
            ringPts.append(pts)
            ringUVu.append(us)
        }
        for ri in 0..<(depths.count - 1) {
            let v0 = Float(depths[ri]), v1 = Float(depths[ri + 1])
            for i in 0..<n {
                let j = (i + 1) % n
                let a = ringPts[ri][i], b = ringPts[ri][j]
                let c = ringPts[ri + 1][j], d = ringPts[ri + 1][i]
                // Outward hint = away from centroid.
                let mid = (a + b + c + d) / 4
                let hint = simd_normalize(SIMD3<Float>(mid.x - Float(centroid.x), 0, mid.z - Float(centroid.y)))
                let uA = ringUVu[ri][i]
                var uB = ringUVu[ri][j]
                if j == 0 {   // wrap seam: continue u past the last column
                    uB = ringUVu[ri][i] + Float(simd_length(outline[0] - outline[n - 1]) / 55.0)
                }
                // Two flat-shaded triangles with matching UVs.
                addCliffTri(&mesh, a, b, c, SIMD2(uA, v0), SIMD2(uB, v0), SIMD2(uB, v1), hint)
                addCliffTri(&mesh, a, c, d, SIMD2(uA, v0), SIMD2(uB, v1), SIMD2(uA, v1), hint)
            }
        }
        let node = SCNNode(geometry: mesh.build(material: WorldMat.cliff))
        node.name = "cliffs"
        return node
    }

    private static func addCliffTri(_ mesh: inout WorldMesh,
                                    _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                                    _ uva: SIMD2<Float>, _ uvb: SIMD2<Float>, _ uvc: SIMD2<Float>,
                                    _ hint: SIMD3<Float>) {
        var nrm = simd_cross(b - a, c - a)
        let len = simd_length(nrm)
        nrm = len > 1e-6 ? nrm / len : hint
        if simd_dot(nrm, hint) < 0 { nrm = -nrm }
        let ia = mesh.add(a, nrm, uva)
        let ib = mesh.add(b, nrm, uvb)
        let ic = mesh.add(c, nrm, uvc)
        // Winding consistent with the (possibly flipped) normal.
        let geoN = simd_cross(b - a, c - a)
        if simd_dot(geoN, nrm) >= 0 { mesh.triangle(ia, ib, ic) } else { mesh.triangle(ia, ic, ib) }
    }

    // MARK: - Interior ridges (A11 — the island rises ESE/SE; D11 — facets
    // never band: 38 segments, shoulder pairs, per-facet albedo jitter via a
    // multiply noise texture)

    private struct RidgeSpec {
        let bearingDeg: Double               // compass bearing from the field
        let distance: Double
        let spineBearingDeg: Double          // direction the crest line runs
        let length: Double
        let halfWidth: Double
        let peak: Double                     // crest height above the field (y≈0)
        let color: UIColor
        let seed: UInt64
    }

    private static func ridgesNode(airport: AirportLayout) -> SCNNode {
        // Mt Orizaba analog (639 m − 488 = 151 above field, ~3 km ESE),
        // Black Jack analog (~123 above field, SE), a near saddle, a far ESE
        // spine — and only low rolling forms NW toward the isthmus (A11).
        // Farther ridges bake bluer.
        let specs: [RidgeSpec] = [
            .init(bearingDeg: 120, distance: 1900, spineBearingDeg: 108, length: 2600,
                  halfWidth: 800, peak: 58, color: worldColor(0.438, 0.432, 0.286), seed: 11),
            .init(bearingDeg: 105, distance: 3000, spineBearingDeg: 116, length: 4200,
                  halfWidth: 1150, peak: 151, color: worldColor(0.442, 0.462, 0.338), seed: 23),
            .init(bearingDeg: 138, distance: 4200, spineBearingDeg: 98, length: 3600,
                  halfWidth: 950, peak: 123, color: worldColor(0.438, 0.474, 0.408), seed: 37),
            .init(bearingDeg: 92, distance: 5700, spineBearingDeg: 120, length: 4800,
                  halfWidth: 1100, peak: 132, color: worldColor(0.430, 0.488, 0.498), seed: 51),
            // NW: gentle isthmus swells only.
            .init(bearingDeg: 302, distance: 3900, spineBearingDeg: 310, length: 3000,
                  halfWidth: 900, peak: 34, color: worldColor(0.455, 0.468, 0.360), seed: 63),
            .init(bearingDeg: 322, distance: 5400, spineBearingDeg: 300, length: 3400,
                  halfWidth: 950, peak: 27, color: worldColor(0.445, 0.475, 0.430), seed: 71),
        ]
        let container = SCNNode()
        for spec in specs {
            container.addChildNode(ridgeNode(spec: spec, baseY: -airport.mesaDropMeters))
        }
        let flat = container.flattenedClone()
        flat.name = "ridges"
        return flat
    }

    private static func ridgeNode(spec: RidgeSpec, baseY: Double) -> SCNNode {
        var rng = WorldRand(seed: spec.seed)
        let mid = headingDirection(degToRad(spec.bearingDeg)) * spec.distance
        let axis = headingDirection(degToRad(spec.spineBearingDeg))
        let across = V2(-axis.y, axis.x)

        var mesh = WorldMesh()
        let segments = 38                                  // D11: was 14 — banding killer
        // Spine samples with jittered crest heights; ends taper to the water.
        var spine: [(pos: V2, h: Double, w: Double)] = []
        for k in 0...segments {
            let t = Double(k) / Double(segments)
            let along = (t - 0.5) * spec.length
            let envelope = sin(.pi * t)
            let bump = 1.0 + 0.55 * sin(t * 19.0 + rng.range(0, 6)) * rng.range(0.3, 1.0)
            let h = max(6, spec.peak * pow(envelope, 0.72) * (0.72 + 0.28 * bump))
            let lateral = rng.range(-0.14, 0.14) * spec.halfWidth
            spine.append((mid + axis * along + across * lateral,
                          h, spec.halfWidth * (0.35 + 0.65 * envelope)))
        }
        // Cross-section: base → shoulder → upper shoulder → crest, both sides
        // (lateral shoulder pairs, D11). Fractions of (halfWidth, height).
        let profile: [(w: Double, h: Double)] = [
            (1.00, 0.0), (0.62, 0.36), (0.28, 0.74), (-0.06, 1.0),
            (-0.34, 0.70), (-0.66, 0.32), (-1.00, 0.0),
        ]
        func uvPatch(_ r: inout WorldRand) -> SIMD2<Float> {
            SIMD2(Float(r.range(0, 1)), Float(r.range(0, 1)))
        }
        for k in 0..<segments {
            let (p0, h0, w0) = spine[k]
            let (p1, h1, w1) = spine[k + 1]
            for c in 0..<(profile.count - 1) {
                let fa = profile[c], fb = profile[c + 1]
                let a0 = worldF3(p0 + across * (w0 * fa.w), fa.h <= 0 ? baseY : baseY + (h0 - baseY) * fa.h)
                let b0 = worldF3(p0 + across * (w0 * fb.w), fb.h <= 0 ? baseY : baseY + (h0 - baseY) * fb.h)
                let a1 = worldF3(p1 + across * (w1 * fa.w), fa.h <= 0 ? baseY : baseY + (h1 - baseY) * fa.h)
                let b1 = worldF3(p1 + across * (w1 * fb.w), fb.h <= 0 ? baseY : baseY + (h1 - baseY) * fb.h)
                let hintSide = fa.w + fb.w >= 0 ? across : -across
                let hint = worldF3(hintSide, 0.85)
                let uv = uvPatch(&rng)
                mesh.facet(a0, a1, b1, hint: hint, uv: uv, uvSpread: 0.02)
                mesh.facet(a0, b1, b0, hint: hint, uv: uv + SIMD2(0.01, 0.01), uvSpread: 0.02)
            }
            // End caps.
            if k == 0 || k == segments - 1 {
                let (pc, hc, wc) = k == 0 ? spine[0] : spine[segments]
                let capHint = worldF3(k == 0 ? -axis : axis, 0.3)
                let crest = worldF3(pc + across * (wc * -0.06), baseY + (hc - baseY))
                let l = worldF3(pc + across * wc, baseY)
                let r = worldF3(pc - across * wc, baseY)
                mesh.facet(l, crest, r, hint: capHint, uv: uvPatch(&rng), uvSpread: 0.02)
            }
        }
        let material = WorldMat.pbr(spec.color, roughness: 0.95, doubleSided: true)
        material.multiply.contents = WorldTex.ridgeNoise()
        material.multiply.wrapS = .repeat
        material.multiply.wrapT = .repeat
        return SCNNode(geometry: mesh.build(material: material))
    }

    // MARK: - Mainland silhouette (NE horizon)

    private static func mainlandNode() -> SCNNode {
        // Placed at ~19 km so ~95% of it dissolves into the haze — a
        // barely-there band standing for the coast 30 km out. D14: heights
        // held to 170–240 m and the color pre-lerped toward the haze so it
        // can never read as a floating khaki cutout.
        var rng = WorldRand(seed: 0x33A1)
        let dirNE = headingDirection(degToRad(40))
        let center = dirNE * 19_000
        let axis = headingDirection(degToRad(130))   // band runs NW–SE across the view
        var mesh = WorldMesh()
        let segments = 16
        let length = 16_000.0
        let baseY = -488.3
        var prevTop: SIMD3<Float>?
        var prevBase: SIMD3<Float>?
        for k in 0...segments {
            let t = Double(k) / Double(segments)
            let along = (t - 0.5) * length
            let envelope = sin(.pi * t)
            // Thin band: ~30 km coast should subtend well under a degree.
            let h = (170 + 70 * rng.unit()) * pow(envelope, 0.6)
            let p = center + axis * along
            let top = worldF3(p, baseY + max(30, h))
            let base = worldF3(p, baseY)
            if let pt = prevTop, let pb = prevBase {
                let hint = worldF3(-dirNE, 0.15)
                mesh.facet(pb, base, top, hint: hint)
                mesh.facet(pb, top, pt, hint: hint)
            }
            prevTop = top; prevBase = base
        }
        let material = WorldMat.pbr(worldColor(0.60, 0.53, 0.52), roughness: 1.0, doubleSided: true)
        let node = SCNNode(geometry: mesh.build(material: material))
        node.name = "mainland"
        node.castsShadow = false
        return node
    }

    // MARK: - Marine layer (offshore WNW — real geography, verified post-flip:
    // bearings 287/296 are compass-absolute, unaffected by the A7 mirror fix)

    private static func marineLayerNode() -> SCNNode {
        let container = SCNNode()
        container.name = "marineLayer"
        let image = WorldTex.cloudBank()
        func slab(distance: Double, headingDeg: Double, width: CGFloat, height: CGFloat,
                  y: Double, alpha: CGFloat) -> SCNNode {
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = image
            material.isDoubleSided = true
            material.transparency = alpha
            material.blendMode = .alpha
            material.writesToDepthBuffer = false
            let plane = SCNPlane(width: width, height: height)
            plane.materials = [material]
            let node = SCNNode(geometry: plane)
            let d = headingDirection(degToRad(headingDeg))
            node.position = worldV3(d * distance, y)
            // Face back toward the field (plane's +Z looks at the origin).
            node.eulerAngles.y = Float(-degToRad(headingDeg) + .pi)
            node.castsShadow = false
            return node
        }
        container.addChildNode(slab(distance: 12_500, headingDeg: 287, width: 9000, height: 420,
                                    y: -310, alpha: 0.42))
        container.addChildNode(slab(distance: 14_200, headingDeg: 296, width: 11_000, height: 520,
                                    y: -280, alpha: 0.30))
        return container
    }
}
