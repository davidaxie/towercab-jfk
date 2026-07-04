import Foundation
import SceneKit
import UIKit
import simd

// =============================================================================
// Terrain — KJFK, the Bay Runway diorama. Everything procedural, no assets.
//
// JFK is FLAT, WIDE, WATERY, urban-adjacent. This file paints:
//   • a DEAD-FLAT pale expanse at the field datum (y=0) — grooved-concrete-adjacent
//     apron/infield land skirting the runway, sampling airport.groundHeight (flat=0);
//   • JAMAICA BAY — one big living water plane at y = -mesaDropMeters (≈ -4) with a
//     warm golden-hour sheen + a sun sparkle lane, wrapping the field to the
//     south / southwest / west, with a few low marsh-island hints riding it;
//   • a salt-marsh / land + haze band to the north & east (dry land side);
//   • a distant HAZY MANHATTAN SKYLINE — a cluster of procedural tower rectangles
//     of varied heights ~13 mi to the NW on the horizon, pre-warmed into the haze;
//   • salt/aerial haze so the far field dissolves into the sky (scene fog does
//     the rest; distant slabs are pre-lerped toward the horizon color).
//
// World convention (SimTypes): meters, Y up, North = -Z, East = +X. The active
// runway lands NW (301° true): `landDir` = headingDirection(301°). The terminal
// (NE) side is +perpSE; the bay (SW) side is -perpSE. Water fills the compass
// south / southwest / west sectors; Manhattan sits NW past the field.
//
// Keep the warm "Luminous Diorama" look: pale concrete-grey land, warm-teal bay
// water lit low from the WSW, amber haze, urban silhouette. Performant — big flat
// planes, faceted low-poly islands/towers that hold color not detail, aerial haze
// (scene fog) reading the far forms as simple shapes.
// =============================================================================

enum WorldTerrainBuilder {

    static func build(into root: SCNNode, airport: AirportLayout) {
        root.addChildNode(bayWaterNode(airport: airport))     // Jamaica Bay — living water plane
        root.addChildNode(fieldPlateNode(airport: airport))   // the flat pale field expanse
        root.addChildNode(shoreFoamNode(airport: airport))    // soft foam where land meets bay
        root.addChildNode(marshIslandsNode(airport: airport)) // low salt-marsh island hints on the bay
        root.addChildNode(landBandNode(airport: airport))     // dry land / haze band N & E
        root.addChildNode(manhattanNode(airport: airport))    // distant hazy skyline, NW horizon
        root.addChildNode(boatsNode(airport: airport))        // a few small craft + sunlit wakes
        root.addChildNode(saltHazeNode(airport: airport))     // low aerial-haze bands over the far bay
    }

    // MARK: - Geometry frame helpers (compass bearings → world XZ)

    /// Unit direction for a compass bearing in degrees (0 = N = -Z, 90 = E = +X).
    private static func bearing(_ deg: Double) -> V2 { headingDirection(degToRad(deg)) }

    // MARK: - Jamaica Bay (D3 lineage — de-periodized swell, warm sheen, sparkle
    // lane toward the low WSW sun). One large flat plane at the water datum. The
    // field plate above it hides the water under the airfield; the bay shows to
    // the south / southwest / west and out to the horizon.

    private static func bayWaterNode(airport: AirportLayout) -> SCNNode {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        // Warm coastal bay teal (a touch greener/siltier than open Pacific).
        material.diffuse.contents = worldColor(0.075, 0.205, 0.235)
        material.roughness.contents = 0.14
        material.metalness.contents = 0.0
        material.setValue(NSNumber(value: 0.26), forKey: "rippleGain")
        material.shaderModifiers = [.surface: """
            #pragma arguments
            float rippleGain;
            #pragma body
            float3 wpos = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
            float t = scn_frame.time;
            float2 p = wpos.xz;
            // Octave 1 — long, gentle bay swell (shorter fetch than open ocean).
            float a1 = sin(p.x * 0.021 + t * 0.50 + sin(p.y * 0.013 + t * 0.28) * 1.6);
            float a2 = sin(p.y * 0.025 - t * 0.42 + sin(p.x * 0.015 - t * 0.24) * 1.4);
            // Octave 2 — wind chop, rotated ~23° so sets never align.
            float2 q = float2(p.x * 0.9205 - p.y * 0.3907, p.x * 0.3907 + p.y * 0.9205);
            float b1 = sin(q.x * 0.12 + q.y * 0.08 + t * 1.30);
            float b2 = sin(q.x * 0.10 - q.y * 0.14 + t * 1.00);
            // Octave 3 — mid-scale confusion.
            float c1 = sin(p.x * 0.055 - p.y * 0.043 + t * 0.82);
            float c2 = sin(p.y * 0.049 + p.x * 0.038 - t * 0.70);
            float dist = length(_surface.position.xyz);
            float g = rippleGain / (1.0 + dist * 0.00034);
            float3 wn = normalize(float3((a1 * 0.50 + b1 * 0.30 + c1 * 0.20) * g, 1.0,
                                         (a2 * 0.50 + b2 * 0.30 + c2 * 0.20) * g));
            _surface.normal = normalize((scn_frame.viewTransform * float4(wn, 0.0)).xyz);
            // Depth gradient: siltier warm-teal shallows near the field into a
            // cooler channel blue farther out toward the Rockaways/Atlantic.
            float dm = clamp(dist / 11000.0, 0.0, 1.0);
            _surface.diffuse.rgb = mix(float3(0.090, 0.215, 0.235),
                                       float3(0.050, 0.135, 0.205), dm);
            // Warm sunset sheen: a broad low-frequency amber wash rising toward
            // the WSW sun so the whole sheet catches golden-hour light, not just
            // the sparkle lane.
            float3 cam = scn_frame.inverseViewTransform[3].xyz;
            float2 vd = p - cam.xz;
            float vl = max(length(vd), 1.0);
            float2 sunDir = float2(-0.940, -0.342);        // ~WSW (247° compass)
            float toward = max(dot(vd / vl, sunDir), 0.0);
            _surface.diffuse.rgb += float3(0.16, 0.10, 0.045) * pow(toward, 2.2);
            // Animated sparkle lane toward the low WSW sun, gated by hash noise.
            float lane = pow(toward, 28.0);
            float2 cell = floor(p * 0.32 + float2(t * 0.85, -t * 0.65));
            float hash = fract(sin(dot(cell, float2(127.1, 311.7))) * 43758.5453);
            float sparkle = step(0.93, hash) * lane;
            _surface.emission.rgb += float3(1.0, 0.80, 0.50) * sparkle * 0.85;
            """]

        // A huge plane so the bay reaches the fog horizon in every direction; the
        // field plate above masks the middle where the airfield sits.
        let plane = SCNPlane(width: 64_000, height: 64_000)
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.name = "bayWater"
        node.eulerAngles.x = -.pi / 2
        node.position = SCNVector3(0, Float(-airport.mesaDropMeters), 0)
        node.castsShadow = false
        node.renderingOrder = -50           // draw before the field plate & foam
        return node
    }

    // MARK: - The flat field plate (the dead-flat pale expanse the airfield sits
    // on). Samples groundHeight (flat → 0) so it agrees with the sim datum. A
    // broad tessellated disc lifted a hair above the water so it never z-fights
    // the bay; its rim drops as a thin bevel to the waterline so the field reads
    // as fortified fill projecting into the bay (the real Bay-Runway character).

    private static func fieldPlateNode(airport: AirportLayout) -> SCNNode {
        let outline = airport.mesaOutline
        var centroid = V2(0, 0)
        for p in outline { centroid += p }
        centroid /= Double(outline.count)

        // Pale grooved-concrete land material — cool light grey with a warm cast,
        // a faint grid so it reads as ramp/apron concrete rather than blank paper.
        let material = WorldMat.pbr(fieldConcreteTex(), roughness: 0.94, wrap: true)
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(1.0 / 120.0, 1.0 / 120.0, 1)

        var mesh = WorldMesh()
        let up = SIMD3<Float>(0, 1, 0)
        let n = outline.count
        let rings = 6
        let lift = 0.12                                   // sit just above the bay
        // Center + concentric rings out to the outline, all flat at y = ground+lift.
        let centerIdx = mesh.add(worldF3(centroid, airport.groundHeight(at: centroid) + lift),
                                 up, SIMD2<Float>(Float(centroid.x), Float(centroid.y)))
        var ringIdx: [[Int32]] = []
        for r in 1...rings {
            let f = Double(r) / Double(rings)
            var ring: [Int32] = []
            for i in 0..<n {
                let q = centroid + (outline[i] - centroid) * f
                let y = airport.groundHeight(at: q) + lift
                ring.append(mesh.add(worldF3(q, y), up, SIMD2<Float>(Float(q.x), Float(q.y))))
            }
            ringIdx.append(ring)
        }
        for i in 0..<n {
            let j = (i + 1) % n
            mesh.triangle(centerIdx, ringIdx[0][i], ringIdx[0][j])
        }
        for r in 0..<(rings - 1) {
            for i in 0..<n {
                let j = (i + 1) % n
                mesh.quad(ringIdx[r][i], ringIdx[r + 1][i], ringIdx[r + 1][j], ringIdx[r][j],
                          desiredNormal: up)
            }
        }
        let node = SCNNode(geometry: mesh.build(material: material))
        node.name = "fieldPlate"
        node.renderingOrder = -20

        // Thin bevel skirt from the field rim down to the waterline — the fill
        // edge. A darker riprap tone so it reads as a built-up shore, not a cliff.
        var skirt = WorldMesh()
        let waterY = -airport.mesaDropMeters
        var prevTop: Int32 = -1, prevBot: Int32 = -1
        for i in 0...n {
            let p = outline[i % n]
            let outward = simd_normalize(p - centroid)
            let top = mesh_addSkirt(&skirt, worldF3(p, airport.groundHeight(at: p) + lift), outward)
            let botP = p + outward * 22.0                 // slope outward as it drops
            let bot = mesh_addSkirt(&skirt, worldF3(botP, waterY - 0.2), outward)
            if prevTop >= 0 {
                skirt.quad(prevTop, prevBot, bot, top,
                           desiredNormal: SIMD3(Float(outward.x), 0.35, Float(outward.y)))
            }
            prevTop = top; prevBot = bot
        }
        let skirtMat = WorldMat.pbr(worldColor(0.315, 0.300, 0.280), roughness: 0.98,
                                    doubleSided: true)
        let skirtNode = SCNNode(geometry: skirt.build(material: skirtMat))
        skirtNode.name = "fieldFill"
        skirtNode.castsShadow = false
        skirtNode.renderingOrder = -20
        node.addChildNode(skirtNode)
        return node
    }

    private static func mesh_addSkirt(_ mesh: inout WorldMesh, _ p: SIMD3<Float>,
                                      _ outward: V2) -> Int32 {
        mesh.add(p, SIMD3(Float(outward.x), 0.4, Float(outward.y)), SIMD2<Float>(0, 0))
    }

    /// Pale grooved-concrete field texture: cool light grey with a warm cast and
    /// a faint slab/groove grid (tiles at 120 m). Salt-bleached, not pristine —
    /// this is the flat land around the runway, not the runway itself.
    private static func fieldConcreteTex() -> UIImage {
        WorldTex.image(CGSize(width: 512, height: 512)) { ctx, size in
            ctx.setFillColor(worldColor(0.585, 0.585, 0.575).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            // Broad tonal blotches so the huge plate never reads as one flat tile.
            WorldTex.speckle(ctx, size: size, count: 42, seed: 0x1A5E, radius: 40...160,
                             colors: [(worldColor(0.63, 0.62, 0.60), 0.16),
                                      (worldColor(0.52, 0.52, 0.52), 0.14),
                                      (worldColor(0.60, 0.57, 0.50), 0.09)], wrap: true)
            // Fine aggregate grain.
            WorldTex.speckle(ctx, size: size, count: 2200, seed: 0x1A5F, radius: 0.7...3.0,
                             colors: [(worldColor(0.70, 0.69, 0.67), 0.08),
                                      (worldColor(0.44, 0.44, 0.44), 0.08)], wrap: true)
            // Faint slab-joint grid (~24 m cells at 120 m tile → 5 cells).
            ctx.setStrokeColor(worldColor(0.40, 0.40, 0.39, 0.35).cgColor)
            ctx.setLineWidth(1.6)
            let cells = 5
            for k in 0...cells {
                let f = CGFloat(k) / CGFloat(cells)
                ctx.move(to: CGPoint(x: f * size.width, y: 0))
                ctx.addLine(to: CGPoint(x: f * size.width, y: size.height))
                ctx.move(to: CGPoint(x: 0, y: f * size.height))
                ctx.addLine(to: CGPoint(x: size.width, y: f * size.height))
            }
            ctx.strokePath()
            // A hint of salt-marsh green creeping at random edges (the field is
            // ringed by wet grass on its dry sides).
            WorldTex.speckle(ctx, size: size, count: 120, seed: 0x1A60, radius: 6...26,
                             colors: [(worldColor(0.40, 0.44, 0.30), 0.10),
                                      (worldColor(0.46, 0.47, 0.34), 0.09)], wrap: true)
        }
    }

    // MARK: - Shore foam (soft broken foam where the fill edge meets the bay —
    // the D3 foam band reused as a thin alpha ribbon just outside the field rim,
    // scrolling slowly so the waterline is alive).

    private static func shoreFoamNode(airport: AirportLayout) -> SCNNode {
        let outline = airport.mesaOutline
        var centroid = V2(0, 0)
        for p in outline { centroid += p }
        centroid /= Double(outline.count)

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = WorldTex.foamBand()
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        material.blendMode = .alpha
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        material.setValue(NSNumber(value: 0.010), forKey: "scrollRate")
        material.shaderModifiers = [.geometry: """
            #pragma arguments
            float scrollRate;
            #pragma body
            _geometry.texcoords[0].y += scn_frame.time * scrollRate;
            """]

        var mesh = WorldMesh()
        let up = SIMD3<Float>(0, 1, 0)
        let y = -airport.mesaDropMeters + 0.25
        let n = outline.count
        var prevIn: Int32 = -1, prevOut: Int32 = -1
        var perimeter = 0.0
        for i in 0...n {
            let p = outline[i % n]
            if i > 0 { perimeter += simd_length(p - outline[(i - 1) % n]) }
            let outward = simd_normalize(p - centroid)
            // Sit the foam just past the fill toe (skirt reaches ~22 m out).
            let inner = p + outward * 20.0
            let outer = p + outward * 46.0
            let v = Float(perimeter / 55.0)
            let ii = mesh.add(worldF3(inner, y), up, SIMD2<Float>(0, v))
            let oi = mesh.add(worldF3(outer, y), up, SIMD2<Float>(1, v))
            if prevIn >= 0 { mesh.quad(prevIn, prevOut, oi, ii, desiredNormal: up) }
            prevIn = ii; prevOut = oi
        }
        let node = SCNNode(geometry: mesh.build(material: material))
        node.name = "shoreFoam"
        node.opacity = 0.28
        node.castsShadow = false
        node.renderingOrder = -10
        return node
    }

    // MARK: - Marsh islands (low salt-marsh island hints riding the bay to the
    // SW / S / W — the Jamaica Bay Wildlife Refuge look: flat, barely-raised
    // grassy shoals, a few hundred meters out, dissolving into haze). Faceted
    // flat discs a hair above the water, warm marsh-green pre-lerped toward haze.

    private static func marshIslandsNode(airport: AirportLayout) -> SCNNode {
        let container = SCNNode()
        let waterY = -airport.mesaDropMeters
        // Bearings into the water sectors: SW, SSW, S, WSW, W.
        struct Isle { let bearing: Double; let dist: Double; let rx: Double; let rz: Double
                      let rot: Double; let seed: UInt64; let color: UIColor }
        let isles: [Isle] = [
            Isle(bearing: 218, dist: 2600, rx: 520, rz: 300, rot: 30,  seed: 0x51A1,
                 color: worldColor(0.360, 0.400, 0.300)),
            Isle(bearing: 200, dist: 3400, rx: 700, rz: 360, rot: -18, seed: 0x51A2,
                 color: worldColor(0.345, 0.385, 0.295)),
            Isle(bearing: 236, dist: 3000, rx: 460, rz: 260, rot: 52,  seed: 0x51A3,
                 color: worldColor(0.370, 0.405, 0.305)),
            Isle(bearing: 250, dist: 4200, rx: 820, rz: 380, rot: 8,   seed: 0x51A4,
                 color: worldColor(0.400, 0.420, 0.330)),   // farther → hazier/tanner
            Isle(bearing: 182, dist: 4600, rx: 640, rz: 300, rot: -40, seed: 0x51A5,
                 color: worldColor(0.410, 0.425, 0.340)),
            Isle(bearing: 268, dist: 5200, rx: 900, rz: 420, rot: 20,  seed: 0x51A6,
                 color: worldColor(0.430, 0.435, 0.360)),
        ]
        for isle in isles {
            var rng = WorldRand(seed: isle.seed)
            let center = bearing(isle.bearing) * isle.dist
            let axis = bearing(isle.rot)                  // long-axis direction
            let across = V2(-axis.y, axis.x)
            var mesh = WorldMesh()
            let up = SIMD3<Float>(0, 1, 0)
            let segs = 20
            let y = waterY + 1.2                          // barely-raised shoal
            let ci = mesh.add(worldF3(center, y), up, SIMD2<Float>(0.5, 0.5))
            var ring: [Int32] = []
            for k in 0...segs {
                let a = Double(k) / Double(segs) * 2 * .pi
                // Jittered radius so the marsh reads as an irregular natural shoal.
                let jit = 1.0 + rng.range(-0.22, 0.16)
                let off = axis * (cos(a) * isle.rx * jit) + across * (sin(a) * isle.rz * jit)
                let uvx = Float(0.5 + 0.5 * cos(a)), uvy = Float(0.5 + 0.5 * sin(a))
                ring.append(mesh.add(worldF3(center + off, y), up, SIMD2<Float>(uvx, uvy)))
            }
            for k in 0..<segs { mesh.triangle(ci, ring[k], ring[k + 1]) }
            let mat = WorldMat.pbr(isle.color, roughness: 1.0, doubleSided: true)
            let node = SCNNode(geometry: mesh.build(material: mat))
            node.castsShadow = false
            container.addChildNode(node)
        }
        let flat = container.flattenedClone()
        flat.name = "marshIslands"
        flat.castsShadow = false
        flat.renderingOrder = -15
        return flat
    }

    // MARK: - Dry land band (the N & E sides — Queens/Long Island: a low, flat,
    // hazy land mass wrapping the compass N through E, standing for the built-up
    // shore feeding the field. Not water. A shallow ring segment of faceted land
    // pre-lerped toward the dusk haze so it reads as a soft horizon, not a wall).

    private static func landBandNode(airport: AirportLayout) -> SCNNode {
        var rng = WorldRand(seed: 0x1A4D)
        var mesh = WorldMesh()
        let waterY = -airport.mesaDropMeters
        // Sweep the land arc from NW (330°) through N and E to SE (150°) — i.e.
        // everything that ISN'T the bay (which owns S/SW/W). Two concentric
        // radii so the land has a little depth and a low ragged crest.
        let a0 = 330.0, a1 = 510.0                        // 330° → 150° (wrapping through 360)
        let inner = 6500.0, outer = 12_000.0
        let steps = 60
        let crestBase = waterY + 6.0
        var prevInner: SIMD3<Float>?
        var prevMidTop: SIMD3<Float>?
        for k in 0...steps {
            let t = Double(k) / Double(steps)
            let deg = a0 + (a1 - a0) * t
            let dir = bearing(deg)
            // Low ragged crest: a few octaves of gentle relief (30–90 m), never
            // a hard wall — Queens is flat. Height rises a touch toward the NE.
            let ridge = 0.5 + 0.28 * sin(deg * 0.09 + 0.7) + 0.14 * sin(deg * 0.031 + 2.0)
            let h = crestBase + (30.0 + 70.0 * max(0.0, ridge)) * rng.range(0.7, 1.0)
            let ip = dir * inner
            let op = dir * outer
            let innerV = worldF3(ip, waterY + 2.0)
            let midTopV = worldF3((ip + op) * 0.5, h)
            if let pi = prevInner, let pmt = prevMidTop {
                let hint = worldF3(dir, 0.25)
                // near flat apron (inner) up to the low crest (mid)
                mesh.facet(pi, innerV, midTopV, hint: hint)
                mesh.facet(pi, midTopV, pmt, hint: hint)
            }
            prevInner = innerV; prevMidTop = midTopV
        }
        // Pre-warmed toward the dusk haze so it never reads as a floating cutout.
        let material = WorldMat.pbr(worldColor(0.560, 0.505, 0.480), roughness: 1.0,
                                    doubleSided: true)
        let node = SCNNode(geometry: mesh.build(material: material))
        node.name = "landBand"
        node.castsShadow = false
        node.renderingOrder = -30

        // A faint scatter of warm town-glow points along the low crest so the
        // built-up shore feels inhabited at golden hour without competing with
        // the airfield lights (constant emissive, tiny, low alpha).
        let glowContainer = SCNNode()
        var grng = WorldRand(seed: 0x1A4E)
        let glowMat = SCNMaterial()
        glowMat.lightingModel = .constant
        glowMat.diffuse.contents = UIColor.black
        glowMat.emission.contents = worldColor(1.0, 0.80, 0.52)
        glowMat.emission.intensity = 0.6
        glowMat.blendMode = .add
        glowMat.writesToDepthBuffer = false
        glowMat.isDoubleSided = true
        for k in stride(from: 2, to: steps - 2, by: 2) where grng.unit() > 0.55 {
            let t = Double(k) / Double(steps)
            let deg = a0 + (a1 - a0) * t
            let dir = bearing(deg)
            let count = 2 + grng.int(3)
            for _ in 0..<count {
                let d = grng.range(inner + 200, (inner + outer) * 0.5)
                let dot = SCNNode(geometry: SCNPlane(width: 40, height: 40))
                dot.geometry?.materials = [glowMat]
                dot.position = worldV3(dir * d, waterY + grng.range(4, 40))
                dot.eulerAngles.y = worldYawFacing(-dir)      // face the field
                glowContainer.addChildNode(dot)
            }
        }
        let flatGlow = glowContainer.flattenedClone()
        flatGlow.castsShadow = false
        node.addChildNode(flatGlow)
        return node
    }

    // MARK: - Manhattan skyline (the distant hazy cluster of towers ~13 mi to the
    // NW on the horizon). A silhouette of procedural tower rectangles of varied
    // heights, tightly clustered, pre-lerped toward the dusk haze so it reads as
    // a faint city on the horizon — the urban-adjacent JFK signature. Faceted
    // extruded boxes hold color, not detail; scene fog + haze do the rest.

    private static func manhattanNode(airport: AirportLayout) -> SCNNode {
        // NW of the field, ~13 mi ≈ 21 km out (research: 12–16 mi). Placed just
        // inside the day fogEnd (18 km) so it's a faint band, not a hard model —
        // actually push to 15.5 km so it survives the dusk fog (14 km) as a ghost.
        let cityBearing = 315.0                            // NW
        let cityDist = 15_500.0
        let waterY = -airport.mesaDropMeters
        let center = bearing(cityBearing) * cityDist
        // The skyline runs roughly perpendicular to the view axis (a band across
        // the NW horizon). Cluster width ~5.5 km so it reads as Midtown+Downtown.
        let bandAxis = bearing(cityBearing + 90)           // sweep the cluster left↔right
        let container = SCNNode()

        var rng = WorldRand(seed: 0x3A17)
        // Two soft humps (Midtown + Lower Manhattan) so the cluster has the
        // real twin-massing rather than a uniform comb.
        let bandHalf = 2800.0
        // Pre-warmed silhouette colors: nearer/taller towers a hair darker, the
        // farthest bleached almost fully into the haze.
        func towerColor(_ far: Double) -> UIColor {
            // far: 0 (front, more saturated) → 1 (back, nearly haze).
            let hazeR = 0.70, hazeG = 0.60, hazeB = 0.585
            let bodyR = 0.475, bodyG = 0.445, bodyB = 0.480
            let f = min(1.0, max(0.0, far))
            return worldColor(bodyR + (hazeR - bodyR) * f,
                              bodyG + (hazeG - bodyG) * f,
                              bodyB + (hazeB - bodyB) * f)
        }

        // Build a batch of extruded rectangular towers. Each is a simple faceted
        // box; we flatten the whole cluster into one node for performance.
        let count = 90
        for i in 0..<count {
            let u = Double(i) / Double(count - 1)          // 0…1 across the band
            // Twin-hump density: more towers (and taller) at u≈0.32 (Midtown) and
            // u≈0.72 (Downtown), sparser between.
            let midtown = exp(-pow((u - 0.32) / 0.16, 2))
            let downtown = exp(-pow((u - 0.72) / 0.12, 2))
            let mass = max(midtown, downtown * 0.92)
            // Skip some slots in the gap so the two clusters read distinctly.
            if mass < 0.14 && rng.unit() > 0.35 { continue }
            let along = (u - 0.5) * 2 * bandHalf + rng.range(-90, 90)
            // Depth jitter so the cluster has front/back rows (parallax + haze).
            let depth = rng.range(-1400, 1400)
            let pos = center + bandAxis * along + bearing(cityBearing) * depth
            // Tower footprint + height. Iconic supertalls punch up at the hump
            // peaks; the mass falls off to low blocky mid-rises at the edges.
            let base = 30.0 + 140.0 * mass
            let spike = rng.unit() > (1.0 - 0.10 - 0.22 * mass) ? rng.range(140, 320) : 0
            let h = (base + spike) * rng.range(0.7, 1.15)
            let w = rng.range(60, 150)
            let d = rng.range(60, 150)
            // Farther-back (more +depth toward the city, or edge towers) → hazier.
            let far = min(1.0, 0.35 + 0.45 * (depth / 1400.0 + 1.0) * 0.5 + 0.25 * (1.0 - mass))
            let mat = WorldMat.pbr(towerColor(far), roughness: 1.0, doubleSided: true)
            let box = SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(d),
                             chamferRadius: 0)
            box.materials = [mat]
            let node = SCNNode(geometry: box)
            node.position = worldV3(pos, waterY + h / 2)
            node.eulerAngles.y = Float(rng.range(-0.25, 0.25))
            node.castsShadow = false
            container.addChildNode(node)
        }

        let flat = container.flattenedClone()
        flat.name = "manhattan"
        flat.castsShadow = false
        flat.renderingOrder = -35

        // A faint warm window-glow wash on the sunlit (SW-facing) sides so the
        // city catches the low sun — a single low-alpha additive plane draped in
        // front of the cluster, tinted amber, so the silhouette glows without
        // per-window cost.
        let glowMat = SCNMaterial()
        glowMat.lightingModel = .constant
        glowMat.diffuse.contents = UIColor.black
        glowMat.emission.contents = manhattanGlowTex()
        glowMat.emission.intensity = 0.5
        glowMat.blendMode = .add
        glowMat.writesToDepthBuffer = false
        glowMat.isDoubleSided = true
        let glowPlane = SCNPlane(width: CGFloat(bandHalf * 2.2), height: 380)
        glowPlane.materials = [glowMat]
        let glow = SCNNode(geometry: glowPlane)
        glow.position = worldV3(center - bearing(cityBearing) * 400, waterY + 150)
        glow.eulerAngles.y = worldYawFacing(-bearing(cityBearing))
        glow.castsShadow = false
        glow.renderingOrder = -34
        flat.addChildNode(glow)
        return flat
    }

    /// A soft horizontal amber band with sparse brighter speckles — draped over
    /// the Manhattan cluster it reads as a hazy warm city glow catching the low
    /// sun, without any per-window geometry.
    private static func manhattanGlowTex() -> UIImage {
        WorldTex.image(CGSize(width: 512, height: 128), opaque: false) { ctx, size in
            // Warm base wash concentrated toward the lower half (the built mass).
            let colors = [worldColor(1.0, 0.72, 0.42, 0.0).cgColor,
                          worldColor(1.0, 0.70, 0.40, 0.30).cgColor,
                          worldColor(1.0, 0.66, 0.38, 0.0).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors, locations: [0, 0.62, 1]) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0),
                                       end: CGPoint(x: 0, y: size.height), options: [])
            }
            // Sparse brighter glints (sun off glass / lit windows).
            WorldTex.speckle(ctx, size: size, count: 160, seed: 0x3A18, radius: 1...4,
                             colors: [(worldColor(1.0, 0.86, 0.60), 0.5),
                                      (worldColor(1.0, 0.78, 0.50), 0.4)])
        }
    }

    // MARK: - Boats (a few small craft on the bay — the "real waterway" cue.
    // Moored in the SW shallows and underway on the SE approach side, each
    // trailing a sunlit V-wake.)

    private static func boatsNode(airport: AirportLayout) -> SCNNode {
        let container = SCNNode()
        container.name = "boats"
        let sea = -airport.mesaDropMeters
        var rng = WorldRand(seed: 0xB0A7)

        let hullWhite = WorldMat.pbr(worldColor(0.90, 0.88, 0.83), roughness: 0.4, metalness: 0.1)
        let hullDark = WorldMat.pbr(worldColor(0.16, 0.20, 0.26), roughness: 0.6)
        let cabinMat = WorldMat.pbr(worldColor(0.82, 0.79, 0.72), roughness: 0.5)

        func wakeMaterial() -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = WorldTex.foamBand()
            m.diffuse.wrapS = .clamp
            m.diffuse.wrapT = .repeat
            m.blendMode = .alpha
            m.writesToDepthBuffer = false
            m.isDoubleSided = true
            m.emission.contents = worldColor(1.0, 0.86, 0.62)
            m.emission.intensity = 0.25
            return m
        }

        /// One boat: chevron hull + low cabin, optionally trailing a V-wake.
        func boat(pos: V2, headingDeg: Double, length: Double, moving: Bool) -> SCNNode {
            let b = SCNNode()
            b.position = worldV3(pos, sea + 0.15)
            b.eulerAngles.y = Float(-degToRad(headingDeg))     // local -Z = bow
            let hw = length * 0.28
            let bow = length * 0.60
            let stern = length * 0.40

            var hull = WorldMesh()
            let up = SIMD3<Float>(0, 1, 0)
            let pBow = SIMD3<Float>(0, 0.12, Float(-bow))
            let pSL  = SIMD3<Float>(Float(-hw), 0.12, Float(stern))
            let pSR  = SIMD3<Float>(Float(hw), 0.12, Float(stern))
            let iBow = hull.add(pBow, up, SIMD2<Float>(0.5, 0))
            let iSL  = hull.add(pSL, up, SIMD2<Float>(0, 1))
            let iSR  = hull.add(pSR, up, SIMD2<Float>(1, 1))
            hull.triangle(iBow, iSL, iSR)
            b.addChildNode(SCNNode(geometry: hull.build(material: hullWhite)))

            let waterline = SCNNode(geometry: SCNBox(width: CGFloat(hw * 2), height: 0.22,
                                                     length: CGFloat(bow + stern), chamferRadius: 0.08))
            waterline.geometry?.materials = [hullDark]
            waterline.position = SCNVector3(0, 0.0, Float((stern - bow) / 2))
            b.addChildNode(waterline)

            let cabin = SCNNode(geometry: SCNBox(width: CGFloat(hw * 1.1), height: CGFloat(length * 0.16),
                                                 length: CGFloat(length * 0.30), chamferRadius: 0.1))
            cabin.geometry?.materials = [cabinMat]
            cabin.position = SCNVector3(0, Float(length * 0.10), Float(stern * 0.35))
            b.addChildNode(cabin)

            if moving {
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

        // Moored craft in the SW shallows (the bay side, ~1.2–1.6 km out).
        let swDir = bearing(222)
        for i in 0..<3 {
            let d = 1250.0 + Double(i) * 120
            let jitter = V2(rng.range(-90, 90), rng.range(-90, 90))
            let m = boat(pos: swDir * d + jitter, headingDeg: rng.range(60, 300),
                         length: rng.range(8, 12), moving: false)
            let bob = SCNAction.repeatForever(.sequence([
                .moveBy(x: 0, y: 0.18, z: 0, duration: 2.4),
                .moveBy(x: 0, y: -0.18, z: 0, duration: 2.7),
            ]))
            bob.timingMode = .easeInEaseOut
            m.runAction(bob)
            container.addChildNode(m)
        }

        // Underway boats: one crossing the SE approach lane (where the player
        // watches arrivals sweep in over the bay), one on the S bay, one WSW.
        let seDir = bearing(140)
        container.addChildNode(boat(pos: seDir * 2600 + V2(180, -120), headingDeg: 250,
                                    length: rng.range(11, 15), moving: true))
        let sDir = bearing(190)
        container.addChildNode(boat(pos: sDir * 3200 + V2(-260, 140), headingDeg: 60,
                                    length: rng.range(9, 13), moving: true))
        let wswDir = bearing(255)
        container.addChildNode(boat(pos: wswDir * 2400 + V2(80, 60), headingDeg: 150,
                                    length: rng.range(9, 12), moving: true))
        return container
    }

    // MARK: - Salt haze (low aerial-haze bands hanging over the far bay so the
    // water dissolves into the sky at the horizon — the warm salt-haze the JFK
    // reference calls for. Reuses the marine-layer cloud slab as thin, warm,
    // low-lying bands out over the water sectors.)

    private static func saltHazeNode(airport: AirportLayout) -> SCNNode {
        let container = SCNNode()
        container.name = "saltHaze"
        let image = WorldTex.cloudBank()
        let waterY = -airport.mesaDropMeters

        func slab(distance: Double, bearingDeg: Double, width: CGFloat, height: CGFloat,
                  y: Double, alpha: CGFloat) -> SCNNode {
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = image
            material.isDoubleSided = true
            material.transparency = alpha
            material.blendMode = .alpha
            material.writesToDepthBuffer = false
            // Warm the haze toward golden hour so it reads as salt/aerial haze,
            // not a grey marine layer.
            material.multiply.contents = worldColor(1.0, 0.82, 0.62)
            let plane = SCNPlane(width: width, height: height)
            plane.materials = [material]
            let node = SCNNode(geometry: plane)
            let d = bearing(bearingDeg)
            node.position = worldV3(d * distance, y)
            node.eulerAngles.y = worldYawFacing(-d)        // face the field
            node.castsShadow = false
            node.renderingOrder = -32
            // Imperceptible lateral drift so the horizon is never quite static.
            let drift = Float(width) * 0.04
            let slow = SCNAction.repeatForever(.sequence([
                .moveBy(x: CGFloat(drift), y: 0, z: 0, duration: 150),
                .moveBy(x: CGFloat(-drift), y: 0, z: 0, duration: 150),
            ]))
            slow.timingMode = .easeInEaseOut
            node.runAction(slow)
            return node
        }

        // Warm low haze banks ringing the water sectors (SW → S → SE), sitting
        // just above the waterline so the far bay fades into the sky.
        container.addChildNode(slab(distance: 9500, bearingDeg: 205, width: 12_000, height: 340,
                                    y: waterY + 60, alpha: 0.34))
        container.addChildNode(slab(distance: 11_000, bearingDeg: 235, width: 13_000, height: 420,
                                    y: waterY + 90, alpha: 0.26))
        container.addChildNode(slab(distance: 10_200, bearingDeg: 165, width: 11_000, height: 360,
                                    y: waterY + 70, alpha: 0.28))
        return container
    }
}
