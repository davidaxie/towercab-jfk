import Foundation
import SceneKit
import UIKit
import simd

// =============================================================================
// Terrain — the Pacific, the mesa with its 488 m cliffs, Catalina's painterly
// interior ridges, a barely-there mainland band on the NE horizon, and the
// marine-layer bank offshore. Distant landforms are faceted low-poly meshes
// that hold color, not detail; aerial haze (scene fog) does the rest.
// =============================================================================

enum WorldTerrainBuilder {

    static func build(into root: SCNNode, airport: AirportLayout) {
        let frame = FieldFrame(airport)
        root.addChildNode(oceanNode(airport: airport))
        root.addChildNode(mesaTopNode(airport: airport))
        root.addChildNode(cliffNode(airport: airport))
        root.addChildNode(ridgesNode(airport: airport, frame: frame))
        root.addChildNode(mainlandNode(frame: frame))
        root.addChildNode(marineLayerNode())
    }

    // MARK: - Ocean

    private static func oceanNode(airport: AirportLayout) -> SCNNode {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = worldColor(0.060, 0.205, 0.275)
        material.roughness.contents = 0.075
        material.metalness.contents = 0.0
        material.setValue(NSNumber(value: 0.16), forKey: "rippleGain")
        material.shaderModifiers = [.surface: """
            #pragma arguments
            float rippleGain;
            #pragma body
            float3 wpos = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
            float t = scn_frame.time;
            float2 p = wpos.xz;
            float a1 = sin(p.x * 0.019 + t * 0.55 + sin(p.y * 0.011 + t * 0.30) * 1.7);
            float a2 = sin(p.y * 0.023 - t * 0.45 + sin(p.x * 0.013 - t * 0.26) * 1.5);
            float b1 = sin(p.x * 0.11 + p.y * 0.07 + t * 1.35);
            float b2 = sin(p.x * 0.09 - p.y * 0.13 + t * 1.05);
            float dist = length(_surface.position.xyz);
            float g = rippleGain / (1.0 + dist * 0.00030);
            float3 wn = normalize(float3((a1 * 0.62 + b1 * 0.38) * g, 1.0, (a2 * 0.62 + b2 * 0.38) * g));
            _surface.normal = normalize((scn_frame.viewTransform * float4(wn, 0.0)).xyz);
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

    // MARK: - Mesa top

    private static func mesaTopNode(airport: AirportLayout) -> SCNNode {
        let outline = airport.mesaOutline
        var centroid = V2(0, 0)
        for p in outline { centroid += p }
        centroid /= Double(outline.count)

        var mesh = WorldMesh()
        let rings = 7
        let n = outline.count
        let uvScale: Float = 1.0 / 42.0
        func vertex(_ p: V2) -> Int32 {
            let y = airport.groundHeight(at: p)
            // Analytic hump normal (gradient along the runway axis only).
            let toB = p - airport.runway.thresholdB
            let s = simd_dot(toB, airport.runway.dir22)
            let t = max(0, min(1, s / airport.runway.length))
            let slope = airport.humpAmplitude * .pi / airport.runway.length * cos(.pi * t)
            let d = airport.runway.dir22
            let normal = simd_normalize(SIMD3<Float>(Float(-slope * d.x), 1, Float(-slope * d.y)))
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

    // MARK: - Interior ridges

    private struct RidgeSpec {
        let center: (s: Double, p: Double)   // runway-frame placement of spine midpoint
        let headingOffsetDeg: Double         // spine rotation relative to the runway axis
        let length: Double
        let halfWidth: Double
        let peak: Double                     // crest height above the field (y≈0)
        let color: UIColor
        let seed: UInt64
    }

    private static func ridgesNode(airport: AirportLayout, frame: FieldFrame) -> SCNNode {
        // Catalina's interior rises on the tower side of the field; the pattern
        // side and both runway ends stay open water. Farther ridges bake bluer.
        let specs: [RidgeSpec] = [
            .init(center: (s: 300, p: 1250), headingOffsetDeg: 0, length: 3600, halfWidth: 1050,
                  peak: 85, color: worldColor(0.430, 0.430, 0.285), seed: 11),      // low connecting saddle
            .init(center: (s: 900, p: 2550), headingOffsetDeg: 14, length: 4200, halfWidth: 950,
                  peak: 195, color: worldColor(0.435, 0.455, 0.330), seed: 23),
            .init(center: (s: -150, p: 4100), headingOffsetDeg: -10, length: 5200, halfWidth: 1150,
                  peak: 245, color: worldColor(0.435, 0.480, 0.420), seed: 37),
            .init(center: (s: 700, p: 5700), headingOffsetDeg: 8, length: 4600, halfWidth: 1000,
                  peak: 175, color: worldColor(0.430, 0.490, 0.500), seed: 51),
        ]
        let container = SCNNode()
        for spec in specs {
            container.addChildNode(ridgeNode(spec: spec, frame: frame,
                                             baseY: -airport.mesaDropMeters))
        }
        let flat = container.flattenedClone()
        flat.name = "ridges"
        return flat
    }

    private static func ridgeNode(spec: RidgeSpec, frame: FieldFrame, baseY: Double) -> SCNNode {
        var rng = WorldRand(seed: spec.seed)
        let mid = frame.point(s: spec.center.s, p: spec.center.p)
        let rot = degToRad(spec.headingOffsetDeg)
        let axis = simd_normalize(frame.dir * cos(rot) + frame.perp * sin(rot))
        let across = V2(-axis.y, axis.x)

        var mesh = WorldMesh()
        let segments = 14
        // Spine samples with jittered crest heights; ends taper to the water.
        var spine: [(pos: V2, h: Double, w: Double)] = []
        for k in 0...segments {
            let t = Double(k) / Double(segments)
            let along = (t - 0.5) * spec.length
            let envelope = sin(.pi * t)
            let bump = 1.0 + 0.55 * sin(t * 19.0 + rng.range(0, 6)) * rng.range(0.3, 1.0)
            let h = max(6, spec.peak * pow(envelope, 0.72) * (0.72 + 0.28 * bump))
            let lateral = rng.range(-0.16, 0.16) * spec.halfWidth
            spine.append((mid + axis * along + across * lateral,
                          h, spec.halfWidth * (0.35 + 0.65 * envelope)))
        }
        for k in 0..<segments {
            let (p0, h0, w0) = spine[k]
            let (p1, h1, w1) = spine[k + 1]
            let l0 = worldF3(p0 + across * w0, baseY), r0 = worldF3(p0 - across * w0, baseY)
            let l1 = worldF3(p1 + across * w1, baseY), r1 = worldF3(p1 - across * w1, baseY)
            // Shoulder points give the crest a faceted two-plane profile.
            let sh0 = worldF3(p0 + across * (w0 * 0.32), h0 * 0.62)
            let sh1 = worldF3(p1 + across * (w1 * 0.32), h1 * 0.62)
            let c0 = worldF3(p0 - across * (w0 * 0.10), h0)
            let c1 = worldF3(p1 - across * (w1 * 0.10), h1)
            let leftHint = worldF3(across, 0.4)
            let rightHint = worldF3(-across, 0.4)
            mesh.facet(l0, l1, sh1, hint: leftHint); mesh.facet(l0, sh1, sh0, hint: leftHint)
            mesh.facet(sh0, sh1, c1, hint: worldF3(across, 1.2)); mesh.facet(sh0, c1, c0, hint: worldF3(across, 1.2))
            mesh.facet(c0, c1, r1, hint: rightHint); mesh.facet(c0, r1, r0, hint: rightHint)
            // End caps.
            if k == 0 { mesh.facet(l0, sh0, c0, hint: worldF3(-axis, 0.3)); mesh.facet(l0, c0, r0, hint: worldF3(-axis, 0.3)) }
            if k == segments - 1 { mesh.facet(l1, c1, sh1, hint: worldF3(axis, 0.3)); mesh.facet(l1, r1, c1, hint: worldF3(axis, 0.3)) }
        }
        let material = WorldMat.pbr(spec.color, roughness: 0.95, doubleSided: true)
        return SCNNode(geometry: mesh.build(material: material))
    }

    // MARK: - Mainland silhouette (NE horizon)

    private static func mainlandNode(frame: FieldFrame) -> SCNNode {
        // Placed at ~19 km so ~95% of it dissolves into the haze — a
        // barely-there band standing for the coast 30 km out.
        var rng = WorldRand(seed: 0x33A1)
        let dirNE = headingDirection(degToRad(40))
        let center = dirNE * 19_000
        let axis = headingDirection(degToRad(130))   // band runs NW–SE across the view
        var mesh = WorldMesh()
        let segments = 16
        let length = 16_000.0
        let baseY = -488.0
        var prevTop: SIMD3<Float>?
        var prevBase: SIMD3<Float>?
        for k in 0...segments {
            let t = Double(k) / Double(segments)
            let along = (t - 0.5) * length
            let envelope = sin(.pi * t)
            // Thin band: ~30 km coast should subtend well under a degree.
            let h = (170 + 190 * rng.unit()) * pow(envelope, 0.6)
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
        let material = WorldMat.pbr(worldColor(0.36, 0.36, 0.46), roughness: 1.0, doubleSided: true)
        let node = SCNNode(geometry: mesh.build(material: material))
        node.name = "mainland"
        node.castsShadow = false
        return node
    }

    // MARK: - Marine layer (offshore WNW)

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
