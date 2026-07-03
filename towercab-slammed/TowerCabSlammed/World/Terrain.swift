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
        root.addChildNode(shallowsNode(airport: airport))     // turquoise cove band
        root.addChildNode(foamNode(airport: airport))
        root.addChildNode(mesaTopNode(airport: airport))
        root.addChildNode(grassWashNode(airport: airport))    // hue zones over the turf
        root.addChildNode(cliffNode(airport: airport))
        root.addChildNode(foothillsNode(airport: airport))    // rolling mid-distance ESE
        root.addChildNode(ridgesNode(airport: airport))
        root.addChildNode(boatsNode(airport: airport))        // vessels + sunlit wakes
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

    // MARK: - Shallow-water band (turquoise ring just outside the foam so the
    // cliff base reads as sunlit reef shallows dropping into channel blue, not a
    // hard foam/deep-water seam). Wider and brightest in the two coves.

    private static func shallowsNode(airport: AirportLayout) -> SCNNode {
        let outline = airport.mesaOutline
        var centroid = V2(0, 0)
        for p in outline { centroid += p }
        centroid /= Double(outline.count)

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.blendMode = .alpha
        material.writesToDepthBuffer = false
        material.isDoubleSided = true

        // Mean radius so we can detect coves as radial dips (the outline's two
        // coves pull inward; a notch = a wider, brighter shallow apron). This
        // is frame-agnostic, so it matches whatever coves the outline carries.
        var meanR = 0.0
        for p in outline { meanR += simd_length(p - centroid) }
        meanR /= Double(outline.count)

        var mesh = WorldMesh()
        let up = SIMD3<Float>(0, 1, 0)
        let y = -airport.mesaDropMeters + 0.4
        let n = outline.count
        var prevIn: Int32 = -1, prevOut: Int32 = -1
        for i in 0...n {
            let p = outline[i % n]
            let outward = simd_normalize(p - centroid)
            // Cove factor: how far this point is pulled inside the mean radius.
            let r = simd_length(p - centroid)
            let cove = max(0.0, min(1.0, (meanR - r) / (meanR * 0.14)))
            let inner = p + outward * 44.0
            let outer = p + outward * (60.0 + 130.0 * cove)
            let ii = mesh.add(worldF3(inner, y), up, SIMD2<Float>(0, 0))
            let oi = mesh.add(worldF3(outer, y), up, SIMD2<Float>(1, 0))
            if prevIn >= 0 { mesh.quad(prevIn, prevOut, oi, ii, desiredNormal: up) }
            prevIn = ii; prevOut = oi
        }
        // Ramp opacity across the band width via a 1-D gradient in the diffuse
        // alpha: bright turquoise at the cliff, dissolving to nothing outward.
        material.diffuse.contents = WorldTerrainBuilder.shallowGradient()
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        let node = SCNNode(geometry: mesh.build(material: material))
        node.name = "shallows"
        node.opacity = 0.5
        node.castsShadow = false
        return node
    }

    /// 1-D turquoise→clear gradient (u across the shallow band). Inline texture
    /// so we never touch WorldMaterials.swift.
    private static func shallowGradient() -> UIImage {
        WorldTex.image(CGSize(width: 64, height: 4), opaque: false) { ctx, size in
            let colors = [worldColor(0.30, 0.62, 0.60, 0.85).cgColor,
                          worldColor(0.24, 0.54, 0.55, 0.35).cgColor,
                          worldColor(0.10, 0.30, 0.38, 0.0).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors, locations: [0, 0.5, 1]) {
                ctx.drawLinearGradient(grad, start: .zero,
                                       end: CGPoint(x: size.width, y: 0), options: [])
            }
        }
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

    // MARK: - Grass hue wash (breaks the muddy uniform khaki: cool green in the
    // low swales, warm burnt-gold on the knoll crowns — soft, low-opacity color
    // decals draped over the turf at 100-400 m scale, painterly not noisy).
    // Additive/alpha color patches, sampling groundHeight so they hug the mesh.

    private static func grassWashNode(airport: AirportLayout) -> SCNNode {
        let outline = airport.mesaOutline
        var centroid = V2(0, 0)
        for p in outline { centroid += p }
        centroid /= Double(outline.count)
        var minX = Double.greatestFiniteMagnitude, maxX = -Double.greatestFiniteMagnitude
        var minZ = Double.greatestFiniteMagnitude, maxZ = -Double.greatestFiniteMagnitude
        for p in outline {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minZ = min(minZ, p.y); maxZ = max(maxZ, p.y)
        }
        func inside(_ p: V2) -> Bool {
            var hit = false; var j = outline.count - 1
            for i in 0..<outline.count {
                let a = outline[i], b = outline[j]
                if (a.y > p.y) != (b.y > p.y),
                   p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { hit.toggle() }
                j = i
            }
            return hit
        }
        let container = SCNNode()
        var rng = WorldRand(seed: 0x6A5F)
        // Radial-gradient discs so the washes feather to nothing at their edges.
        func washTex(_ color: UIColor) -> UIImage {
            WorldTex.image(CGSize(width: 64, height: 64), opaque: false) { ctx, size in
                let cg = color.cgColor
                let clear = color.withAlphaComponent(0).cgColor
                if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: [cg, clear] as CFArray, locations: [0, 1]) {
                    ctx.drawRadialGradient(grad,
                        startCenter: CGPoint(x: size.width / 2, y: size.height / 2), startRadius: 0,
                        endCenter: CGPoint(x: size.width / 2, y: size.height / 2),
                        endRadius: size.width / 2, options: [])
                }
            }
        }
        func washMat(_ color: UIColor) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = washTex(color)
            m.blendMode = .alpha
            m.writesToDepthBuffer = false
            m.isDoubleSided = true
            return m
        }
        // Elevation reference: the runway crest datum is y=0; knolls rise ~9-10 m.
        // Green washes favor lower ground; gold favors the crowns.
        let green = washMat(worldColor(0.30, 0.40, 0.20, 0.45))
        let gold  = washMat(worldColor(0.56, 0.44, 0.24, 0.40))
        let olive = washMat(worldColor(0.34, 0.38, 0.22, 0.42))

        func drape(_ center: V2, radius: Double, mat: SCNMaterial) {
            // Tessellated disc that samples groundHeight so it rides the hump.
            var mesh = WorldMesh()
            let up = SIMD3<Float>(0, 1, 0)
            let segs = 12
            let cy = airport.groundHeight(at: center) + 0.09
            let ci = mesh.add(worldF3(center, cy), up, SIMD2<Float>(0.5, 0.5))
            var ring: [Int32] = []
            for k in 0...segs {
                let a = Double(k) / Double(segs) * 2 * .pi
                let q = center + V2(cos(a), sin(a)) * radius
                let y = airport.groundHeight(at: q) + 0.09
                let uvx = Float(0.5 + 0.5 * cos(a)), uvy = Float(0.5 + 0.5 * sin(a))
                ring.append(mesh.add(worldF3(q, y), up, SIMD2<Float>(uvx, uvy)))
            }
            for k in 0..<segs {
                mesh.triangle(ci, ring[k], ring[k + 1])
            }
            container.addChildNode(SCNNode(geometry: mesh.build(material: mat)))
        }

        // Keep washes off the paved runway/ramp so no green tints the concrete.
        let frame = FieldFrame(airport)
        func onPavement(_ p: V2) -> Bool {
            let st = frame.station(p)
            if st.x > -20 && st.x < airport.runway.length + 20 && abs(st.y) < 18 { return true }
            if st.x > 400 && st.x < 640 && st.y > 55 && st.y < 155 { return true }   // ramp/infield
            return false
        }
        var placed = 0, attempts = 0
        while placed < 30 && attempts < 2000 {
            attempts += 1
            let p = V2(rng.range(minX, maxX), rng.range(minZ, maxZ))
            guard inside(centroid + (p - centroid) * 0.96), !onPavement(p) else { continue }
            let elev = airport.groundHeight(at: p)
            // Pick a wash by elevation: crowns (elev high, less negative) → gold;
            // swales (more negative) → green; middle → olive.
            let mat: SCNMaterial
            if elev > -3 { mat = rng.unit() > 0.4 ? gold : olive }
            else if elev < -9 { mat = rng.unit() > 0.4 ? green : olive }
            else { mat = rng.unit() > 0.5 ? olive : green }
            drape(p, radius: rng.range(55, 130), mat: mat)
            placed += 1
        }
        let flat = container.flattenedClone()
        flat.name = "grassWash"
        flat.castsShadow = false
        return flat
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
        // Nearer ridges get chaparral stipple (mottled sage/olive/tan); the
        // farther, bluer ridges keep the neutral value noise so haze reads them
        // as simple forms. `distance` from ridgeNode's spec picks which.
        material.multiply.contents = spec.distance < 4500
            ? WorldTerrainBuilder.chaparralTex() : WorldTex.ridgeNoise()
        material.multiply.wrapS = .repeat
        material.multiply.wrapT = .repeat
        let node = SCNNode(geometry: mesh.build(material: material))
        // Treed silhouette: scatter a few dark canopy blobs along the crest of
        // the two nearest chaparral ridges so the skyline isn't a bare arc.
        if spec.distance < 3200 {
            var trng = WorldRand(seed: spec.seed &+ 0x7EE)
            let treeMat = WorldMat.pbr(worldColor(0.26, 0.31, 0.22), roughness: 1.0, doubleSided: true)
            for k in stride(from: 3, to: segments - 3, by: 2) {
                guard trng.unit() > 0.45 else { continue }
                let (pc, hc, _) = spine[k]     // hc = absolute crest Y (above y=0 datum)
                let clump = SCNNode()
                let lobes = 2 + trng.int(2)
                for _ in 0..<lobes {
                    let rad = trng.range(6, 12)
                    let sph = SCNSphere(radius: CGFloat(rad))
                    sph.segmentCount = 5
                    sph.materials = [treeMat]
                    let lobe = SCNNode(geometry: sph)
                    lobe.position = SCNVector3(Float(trng.range(-8, 8)),
                                               Float(hc + rad * 0.4 + trng.range(0, 6)),
                                               Float(trng.range(-8, 8)))
                    lobe.scale = SCNVector3(1.0, Float(trng.range(0.9, 1.5)), 1.0)
                    clump.addChildNode(lobe)
                }
                clump.position = worldV3(pc, 0)
                node.addChildNode(clump)
            }
        }
        return node
    }

    // MARK: - Boats (the single strongest "real island" cue — a few small
    // vessels past the rim, moored in the SE cove and underway on the NW
    // over-the-water pattern side, each trailing a sunlit V-wake)

    private static func boatsNode(airport: AirportLayout) -> SCNNode {
        let container = SCNNode()
        container.name = "boats"
        let sea = -airport.mesaDropMeters
        var rng = WorldRand(seed: 0xB0A7)

        // Warm painted-hull materials (whites/creams catching the low sun).
        let hullWhite = WorldMat.pbr(worldColor(0.90, 0.88, 0.83), roughness: 0.4, metalness: 0.1)
        let hullDark = WorldMat.pbr(worldColor(0.16, 0.20, 0.26), roughness: 0.6)
        let cabinMat = WorldMat.pbr(worldColor(0.82, 0.79, 0.72), roughness: 0.5)

        // Wake material: reuse the foam band as a soft alpha ribbon.
        func wakeMaterial() -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = WorldTex.foamBand()
            m.diffuse.wrapS = .clamp
            m.diffuse.wrapT = .repeat
            m.blendMode = .alpha
            m.writesToDepthBuffer = false
            m.isDoubleSided = true
            // Warm the foam toward the sun so the wake reads as sunlit spray.
            m.emission.contents = worldColor(1.0, 0.86, 0.62)
            m.emission.intensity = 0.25
            return m
        }

        /// One boat: a chevron hull (2 triangles) + a low cabin box, optionally
        /// trailing a spreading V-wake. `headingDeg` = direction the bow points.
        func boat(pos: V2, headingDeg: Double, length: Double, moving: Bool) -> SCNNode {
            let b = SCNNode()
            b.position = worldV3(pos, sea + 0.15)
            b.eulerAngles.y = Float(-degToRad(headingDeg))     // local -Z = bow
            let hw = length * 0.28                               // half-beam
            let bow = length * 0.60
            let stern = length * 0.40

            // Hull: flat deck (chevron) sitting just above the water.
            var hull = WorldMesh()
            let up = SIMD3<Float>(0, 1, 0)
            let pBow = SIMD3<Float>(0, 0.12, Float(-bow))
            let pSL  = SIMD3<Float>(Float(-hw), 0.12, Float(stern))
            let pSR  = SIMD3<Float>(Float(hw), 0.12, Float(stern))
            let iBow = hull.add(pBow, up, SIMD2<Float>(0.5, 0))
            let iSL  = hull.add(pSL, up, SIMD2<Float>(0, 1))
            let iSR  = hull.add(pSR, up, SIMD2<Float>(1, 1))
            hull.triangle(iBow, iSL, iSR)
            let hullNode = SCNNode(geometry: hull.build(material: hullWhite))
            b.addChildNode(hullNode)

            // Dark waterline strip (a thin box hugging the deck edge).
            let waterline = SCNNode(geometry: SCNBox(width: CGFloat(hw * 2), height: 0.22,
                                                     length: CGFloat(bow + stern), chamferRadius: 0.08))
            waterline.geometry?.materials = [hullDark]
            waterline.position = SCNVector3(0, 0.0, Float((stern - bow) / 2))
            b.addChildNode(waterline)

            // Small cabin toward the stern.
            let cabin = SCNNode(geometry: SCNBox(width: CGFloat(hw * 1.1), height: CGFloat(length * 0.16),
                                                 length: CGFloat(length * 0.30), chamferRadius: 0.1))
            cabin.geometry?.materials = [cabinMat]
            cabin.position = SCNVector3(0, Float(length * 0.10), Float(stern * 0.35))
            b.addChildNode(cabin)

            if moving {
                // Spreading V-wake ribbon behind the stern.
                var wake = WorldMesh()
                let wUp = SIMD3<Float>(0, 1, 0)
                let wakeLen = length * 9.0
                let wakeSpread = length * 1.4
                let segs = 10
                var prevL: Int32 = -1, prevR: Int32 = -1
                for k in 0...segs {
                    let t = Double(k) / Double(segs)
                    let z = Float(stern + t * wakeLen)
                    let x = Float(t * wakeSpread)
                    let y: Float = 0.05
                    let li = wake.add(SIMD3(-x, y, z), wUp, SIMD2(0, Float(t * 6)))
                    let ri = wake.add(SIMD3(x, y, z), wUp, SIMD2(1, Float(t * 6)))
                    if prevL >= 0 { wake.quad(prevL, prevR, ri, li, desiredNormal: wUp) }
                    prevL = li; prevR = ri
                }
                let wakeNode = SCNNode(geometry: wake.build(material: wakeMaterial()))
                wakeNode.opacity = 0.55
                wakeNode.castsShadow = false
                b.addChildNode(wakeNode)

                // Slow forward creep so the sea has life (bow is -Z).
                let dist = rng.range(240, 420)
                let dur = rng.range(90, 150)
                let move = SCNAction.repeatForever(.sequence([
                    .moveBy(x: 0, y: 0, z: CGFloat(-dist), duration: dur),
                    .moveBy(x: 0, y: 0, z: CGFloat(dist), duration: dur),
                ]))
                b.runAction(move)
            }
            b.castsShadow = false
            return b
        }

        // Moored craft in the SE cove (mesa angle ~2.2). Bearing from the field
        // to that cove is ESE; anchor them ~700-900 m out, riding gently.
        let seCove = headingDirection(degToRad(118))
        for i in 0..<3 {
            let d = 720.0 + Double(i) * 55
            let jitter = V2(rng.range(-40, 40), rng.range(-40, 40))
            let pos = seCove * d + jitter
            let m = boat(pos: pos, headingDeg: rng.range(60, 300), length: rng.range(7, 10), moving: false)
            // A gentle moored bob.
            let bob = SCNAction.repeatForever(.sequence([
                .moveBy(x: 0, y: 0.18, z: 0, duration: 2.4),
                .moveBy(x: 0, y: -0.18, z: 0, duration: 2.7),
            ]))
            bob.timingMode = .easeInEaseOut
            m.runAction(bob)
            container.addChildNode(m)
        }

        // Underway boats on the NW pattern side (where the player looks on
        // approach) and one crossing the SW channel.
        let nwDir = headingDirection(degToRad(300))
        container.addChildNode(boat(pos: nwDir * 1500 + V2(120, -80), headingDeg: 205,
                                    length: rng.range(9, 12), moving: true))
        container.addChildNode(boat(pos: nwDir * 2400 + V2(-260, 140), headingDeg: 40,
                                    length: rng.range(8, 11), moving: true))
        let swDir = headingDirection(degToRad(235))
        container.addChildNode(boat(pos: swDir * 1900 + V2(80, 60), headingDeg: 120,
                                    length: rng.range(7, 10), moving: true))
        return container
    }

    // MARK: - Foothills (fills the empty ESE mid-distance between the mesa rim
    // ~500 m out and the first interior ridge at 1900 m, so the eye never jumps
    // from bare grass to a color-block hill — low rolling chaparral swells)

    private static func foothillsNode(airport: AirportLayout) -> SCNNode {
        let baseY = -airport.mesaDropMeters
        struct Swell { let bearing: Double; let dist: Double; let spineBearing: Double
                       let length: Double; let halfWidth: Double; let peak: Double; let seed: UInt64 }
        // A loose arc of gentle swells ringing the SE/ESE mid-distance, lower
        // and closer than ridgesNode's specs, colored like sunlit chaparral.
        let swells: [Swell] = [
            Swell(bearing: 128, dist: 1050, spineBearing: 108, length: 1500, halfWidth: 420, peak: 26, seed: 0x101),
            Swell(bearing: 150, dist: 1200, spineBearing: 96,  length: 1400, halfWidth: 380, peak: 22, seed: 0x102),
            Swell(bearing: 108, dist: 1150, spineBearing: 120, length: 1350, halfWidth: 360, peak: 24, seed: 0x103),
            Swell(bearing: 168, dist: 1300, spineBearing: 82,  length: 1250, halfWidth: 340, peak: 18, seed: 0x104),
        ]
        let container = SCNNode()
        for sw in swells {
            var rng = WorldRand(seed: sw.seed)
            let mid = headingDirection(degToRad(sw.bearing)) * sw.dist
            let axis = headingDirection(degToRad(sw.spineBearing))
            let across = V2(-axis.y, axis.x)
            var mesh = WorldMesh()
            let segments = 22
            var spine: [(pos: V2, h: Double, w: Double)] = []
            for k in 0...segments {
                let t = Double(k) / Double(segments)
                let along = (t - 0.5) * sw.length
                let envelope = sin(.pi * t)
                let bump = 0.75 + 0.25 * sin(t * 13 + rng.range(0, 5))
                // Absolute crest Y (peak above the y=0 field datum, matching the
                // ridge convention so the swell rises from the sea, not below it).
                let h = max(4, sw.peak * pow(envelope, 0.8) * bump)
                let lateral = rng.range(-0.12, 0.12) * sw.halfWidth
                spine.append((mid + axis * along + across * lateral,
                              h, sw.halfWidth * (0.4 + 0.6 * envelope)))
            }
            let profile: [(w: Double, h: Double)] = [
                (1.00, 0.0), (0.55, 0.42), (-0.02, 1.0), (-0.58, 0.40), (-1.00, 0.0),
            ]
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
                    let uv = SIMD2(Float(rng.range(0, 1)), Float(rng.range(0, 1)))
                    mesh.facet(a0, a1, b1, hint: hint, uv: uv, uvSpread: 0.03)
                    mesh.facet(a0, b1, b0, hint: hint, uv: uv + SIMD2(0.02, 0.02), uvSpread: 0.03)
                }
            }
            let material = WorldMat.pbr(worldColor(0.430, 0.452, 0.300), roughness: 0.96, doubleSided: true)
            material.multiply.contents = WorldTerrainBuilder.chaparralTex()
            material.multiply.wrapS = .repeat
            material.multiply.wrapT = .repeat
            container.addChildNode(SCNNode(geometry: mesh.build(material: material)))
        }
        let flat = container.flattenedClone()
        flat.name = "foothills"
        flat.castsShadow = false
        return flat
    }

    /// Mottled sage/olive/tan chaparral stipple (multiply over ridge/foothill
    /// facets so they read as vegetated Catalina hillside, not flat paper).
    /// Inline here so WorldMaterials.swift stays owned by the runway agent.
    private static func chaparralTex() -> UIImage {
        WorldTex.image(CGSize(width: 256, height: 256)) { ctx, size in
            ctx.setFillColor(UIColor(white: 0.96, alpha: 1).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            // Coloured stipple: darker sage clumps + warm tan gaps, so the
            // multiply shifts hue as well as value across the hillside.
            WorldTex.speckle(ctx, size: size, count: 520, seed: 0xC4A1,
                             radius: 3...16,
                             colors: [(worldColor(0.62, 0.70, 0.52), 0.30),   // sage highlight
                                      (worldColor(0.50, 0.52, 0.36), 0.30),   // olive
                                      (worldColor(0.70, 0.62, 0.44), 0.24),   // sun-tan gap
                                      (worldColor(0.40, 0.44, 0.32), 0.26)],  // shadow clump
                             wrap: true)
            WorldTex.speckle(ctx, size: size, count: 40, seed: 0xC4A2,
                             radius: 24...80,
                             colors: [(worldColor(0.66, 0.66, 0.50), 0.20),
                                      (worldColor(0.52, 0.54, 0.40), 0.20)], wrap: true)
        }
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
        let segments = 40                            // was 16 — carries headlands
        let length = 16_000.0
        let baseY = -488.3
        var prevTop: SIMD3<Float>?
        var prevBase: SIMD3<Float>?
        // Remember a few crest positions so faint town glows can sit in the
        // low saddles at dusk.
        var saddles: [(pos: V2, h: Double)] = []
        for k in 0...segments {
            let t = Double(k) / Double(segments)
            let along = (t - 0.5) * length
            let envelope = sin(.pi * t)
            // Coastal silhouette: a low-freq headland/notch ridgeline instead of
            // a smooth arch, so it reads as land, not a cutout.
            let ridge = 0.62 + 0.24 * sin(t * 7.0 + 0.6) + 0.14 * sin(t * 17.0 + 2.1)
            let h = (150 + 120 * ridge * rng.unit()) * pow(envelope, 0.55)
            let p = center + axis * along
            let top = worldF3(p, baseY + max(30, h))
            let base = worldF3(p, baseY)
            if let pt = prevTop, let pb = prevBase {
                let hint = worldF3(-dirNE, 0.15)
                mesh.facet(pb, base, top, hint: hint)
                mesh.facet(pb, top, pt, hint: hint)
            }
            prevTop = top; prevBase = base
            if ridge < 0.6 && envelope > 0.3 { saddles.append((p, baseY + max(30, h) * 0.4)) }
        }
        // Pre-warmed toward the dusk haze so it never reads as a khaki cutout.
        let material = WorldMat.pbr(worldColor(0.615, 0.535, 0.510), roughness: 1.0, doubleSided: true)
        let node = SCNNode(geometry: mesh.build(material: material))
        node.name = "mainland"
        node.castsShadow = false

        // A very faint scatter of warm town-glow points in the coastal saddles —
        // constant emissive, tiny and low-alpha, so the far shore feels
        // inhabited at dusk without ever competing with the airfield lights.
        let glowContainer = SCNNode()
        var grng = WorldRand(seed: 0x33B7)
        let glowMat = SCNMaterial()
        glowMat.lightingModel = .constant
        glowMat.diffuse.contents = UIColor.black
        glowMat.emission.contents = worldColor(1.0, 0.78, 0.50)
        glowMat.emission.intensity = 0.7
        glowMat.blendMode = .add
        glowMat.writesToDepthBuffer = false
        glowMat.isDoubleSided = true
        for s in saddles where grng.unit() > 0.4 {
            let count = 2 + grng.int(3)
            for _ in 0..<count {
                let dot = SCNNode(geometry: SCNPlane(width: 34, height: 34))
                dot.geometry?.materials = [glowMat]
                let off = axis * grng.range(-400, 400)
                dot.position = worldV3(s.pos + off, s.h + grng.range(-30, 40))
                dot.eulerAngles.y = Float(-degToRad(40) + .pi)
                glowContainer.addChildNode(dot)
            }
        }
        let flatGlow = glowContainer.flattenedClone()
        node.addChildNode(flatGlow)
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
            // Imperceptible drift — the bank breathes laterally over minutes so
            // the horizon is never quite static.
            let drift = Float(width) * 0.05
            let slow = SCNAction.repeatForever(.sequence([
                .moveBy(x: CGFloat(drift), y: 0, z: 0, duration: 140),
                .moveBy(x: CGFloat(-drift), y: 0, z: 0, duration: 140),
            ]))
            slow.timingMode = .easeInEaseOut
            node.runAction(slow)
            return node
        }
        container.addChildNode(slab(distance: 12_500, headingDeg: 287, width: 9000, height: 420,
                                    y: -310, alpha: 0.42))
        container.addChildNode(slab(distance: 14_200, headingDeg: 296, width: 11_000, height: 520,
                                    y: -280, alpha: 0.30))
        return container
    }
}
