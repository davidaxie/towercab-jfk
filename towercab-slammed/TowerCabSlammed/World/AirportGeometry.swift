import Foundation
import SceneKit
import UIKit
import simd

// =============================================================================
// Airport paved surfaces — the 2019 concrete runway riding the real asymmetric
// hump, taxiways with clipped centerlines + double edge lines (D2/D16), the SE
// midfield ramp, the dirt tiedown infield with its cable rows (A8), DC-3 fuel
// pit covers, the hold-short bar, and the dirt service road. Geometry follows
// AirportLayout.kavx verbatim.
// =============================================================================

enum WorldAirportBuilder {

    // =========================================================================
    // THE LIFT LADDER — one source of truth for every horizontal surface's
    // height above `airport.groundHeight`.
    //
    // Read this before adding a surface. On a FLAT field (KJFK sets
    // `flat = true`, so groundHeight ≡ 0) every one of these is coplanar apart
    // from its lift, so the ladder alone decides what the depth test draws.
    //
    // The KJFK audit (AUDIT-KJFK.md §A1) found the whole airport invisible
    // because the terrain's field plate was authored at 0.12 — ABOVE every
    // pavement lift below — and buried the runway, taxiways, apron, hold bars
    // and all three crossing runways. The plate is now the datum (0.0) and
    // everything paved stacks above it. `assertLiftLadder()` locks that in.
    // =========================================================================

    /// The ground the airfield sits on (`Terrain.fieldPlateNode`). THE DATUM —
    /// nothing paved may sit at or below this.
    static let fieldPlateLift = 0.0

    // Pavement sits just proud of the terrain mesh to avoid z-fighting.
    static let pavementLift = 0.06
    static let stripeLift = 0.11
    static let decalLift = 0.14

    // JFK box lifts: the inactive runways sit BELOW the active Bay Runway, and
    // the box connector taxiways below the inactive runways, so at every
    // crossing on the dead-flat field the higher surface's markings win the
    // depth test (no z-fighting on the coplanar field). The box runways carry
    // their markings baked into the texture (one ribbon each); the box taxiway
    // stripes ride just above their pavement but stay under the active runway.
    static let jfkBoxRunwayLift = 0.040
    static let jfkBoxTaxiLift = 0.020
    static let jfkBoxTaxiStripeLift = 0.030

    /// Every lift that must clear the field plate, lowest first. Kept next to
    /// the constants so a new surface is a one-line addition here too.
    static let pavedLifts: [(name: String, lift: Double)] = [
        ("jfkBoxTaxi", jfkBoxTaxiLift),
        ("jfkBoxTaxiStripe", jfkBoxTaxiStripeLift),
        ("jfkBoxRunway", jfkBoxRunwayLift),
        ("pavement", pavementLift),
        ("stripe", stripeLift),
        ("decal", decalLift),
    ]

    /// Debug-build guard: no paved surface may sink to or below the field
    /// plate. This is the assertion the A1 bug would have tripped on day one.
    static func assertLiftLadder() {
        for entry in pavedLifts {
            assert(entry.lift > fieldPlateLift,
                   "Lift ladder violated: \(entry.name) (\(entry.lift)) is not above "
                   + "fieldPlateLift (\(fieldPlateLift)) — on a flat field this surface "
                   + "is buried. See AUDIT-KJFK.md §A1.")
        }
    }

    /// Ramp + infield rects in runway-frame coordinates (shared with
    /// GroundDetails so buildings hug their edges).
    static let apronS0 = 420.0, apronSLen = 200.0
    static let apronP0 = 96.0, apronPLen = 54.0
    static let infieldS0 = 430.0, infieldSLen = 180.0
    static let infieldP0 = 62.0, infieldPLen = 34.0
    /// Spots with p beyond this are on the paved ramp; the rest are dirt (A8).
    static let pavedSpotMinP = 95.0

    static func build(into root: SCNNode, airport: AirportLayout) {
        assertLiftLadder()
        let frame = FieldFrame(airport)
        // JFK box: render the OTHER THREE runways + their connecting taxiways
        // BEFORE the active runway so the active Bay Runway's crisp markings win
        // any z-tie at the crossings, and before the apron/infield.
        if airport.icao == "KJFK" {
            root.addChildNode(jfkBoxRunwayNodes(airport: airport, frame: frame))
            root.addChildNode(jfkBoxTaxiwayNodes(airport: airport, frame: frame))
        }
        root.addChildNode(runwayNode(airport: airport))
        root.addChildNode(taxiwayNodes(airport: airport, frame: frame))
        root.addChildNode(apronNode(airport: airport, frame: frame))
        root.addChildNode(infieldNode(airport: airport, frame: frame))
        root.addChildNode(fuelPitNode(airport: airport, frame: frame))
        root.addChildNode(holdShortNode(airport: airport, frame: frame))
        root.addChildNode(serviceRoadNode(airport: airport, frame: frame))
    }

    // MARK: - Runway (A2/A3 — 914.4 × 22.9 m fresh concrete)

    private static func runwayNode(airport: AirportLayout) -> SCNNode {
        let rw = airport.runway
        let material = WorldMat.pbr(
            WorldTex.runway(lengthMeters: rw.length, widthMeters: rw.width),
            roughness: 0.62)
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        // Anisotropic filtering: the near runway fills the frame at a grazing
        // angle from the cab, so joints/dashes smear without it.
        material.diffuse.maxAnisotropy = 16
        // Micro concrete detail: a tiling normal + roughness map so saw-cut
        // joints and aggregate catch a faint highlight/micro-shadow at golden
        // hour. UV runs u=0…1 across width, v=0…1 along length; tile at ~2 m so
        // the maps read as ~11 tiles across × many along (kept square).
        let acrossTiles = Float(rw.width / 2.0)
        let alongTiles = Float(rw.length / 2.0)
        if let nrm = WorldTex.concreteNormal() {
            material.normal.contents = nrm
            material.normal.wrapS = .repeat
            material.normal.wrapT = .repeat
            material.normal.contentsTransform = SCNMatrix4MakeScale(acrossTiles, alongTiles, 1)
            material.normal.mipFilter = .linear
            material.normal.maxAnisotropy = 16
            material.normal.intensity = 0.35
        }
        material.roughness.contents = WorldTex.concreteRoughness()
        material.roughness.wrapS = .repeat
        material.roughness.wrapT = .repeat
        material.roughness.contentsTransform = SCNMatrix4MakeScale(acrossTiles, alongTiles, 1)
        material.roughness.mipFilter = .linear
        material.roughness.maxAnisotropy = 16
        // Ribbon from threshold B (v=0) to A (v=1); u=0 on the +perp side,
        // matching the texture's numeral orientation.
        let geometry = worldRibbonGeometry(points: [rw.thresholdB, rw.thresholdA],
                                           width: rw.width, lift: pavementLift,
                                           airport: airport, vPerMeter: nil,
                                           material: material, step: 8)
        let node = SCNNode(geometry: geometry)
        node.name = "runway"
        return node
    }

    // MARK: - KJFK box: the other three runways + connectors

    /// One JFK box runway, expressed in the active Bay Runway's runway-frame
    /// (s = along the Bay Runway from thr B / 31L; p = toward the terminal/NE).
    /// - The parallel 13L/31R is a line of constant `p`, spanning a range of `s`.
    /// - The two crossing 04/22 runways are lines of constant `s`, spanning a
    ///   range of `p` (perpendicular to the Bay Runway in-frame — the 031/211
    ///   axis resolves to pure ±p).
    /// `endB`/`endA` are the runway-frame endpoints (nameB→nameA); the texture's
    /// v=0 sits at `endB`.
    private struct JFKRunwaySpec {
        let nameB: String, nameA: String
        let endB: (s: Double, p: Double)   // texture v=0 threshold
        let endA: (s: Double, p: Double)   // texture v=1 threshold
        let width: Double
        let seed: UInt64
    }

    /// The JFK hash, schematic-but-faithful (functional, not survey-accurate) in
    /// the Bay Runway's frame. Bay Runway is the active at s∈[0,len], p=0.
    ///   • 13L/31R — parallel, 10,000 ft, on the terminal (+p) side, staggered NW.
    ///   • 04L/22R — the longer crosser (inboard/west), s=1450.
    ///   • 04R/22L — the shorter crosser (near Terminal City), s=2350.
    /// Both crossers run along ±p (031/211 resolves to pure perpendicular here),
    /// crossing BOTH the Bay Runway (p=0) and the parallel (p=1350). 04 ends sit
    /// toward −p (SW/bay), 22 ends toward +p (NE). Their painted length is fitted
    /// to the flat field footprint (they'd otherwise overhang the terrain edge
    /// into Jamaica Bay), which reads honestly — JFK's 04/22 are bounded by the
    /// airport land too. The parallel keeps its full 10,000 ft.
    private static func jfkBoxSpecs() -> [JFKRunwaySpec] {
        let ft = 0.3048
        let parP = 1350.0                       // parallel offset onto the NE side
        let par13Len = 10000 * ft               // 3048 m (full length fits)
        let par13S0 = 900.0                      // NW-staggered start
        return [
            // Parallel 13L/31R: same B→A sense as the Bay Runway (31R↔13L).
            JFKRunwaySpec(nameB: "31R", nameA: "13L",
                          endB: (par13S0, parP), endA: (par13S0 + par13Len, parP),
                          width: 60, seed: 0x13F1),
            // Crossers: nameB = the 22 (NE, +p) end so numerals read landing 22
            // (rotated), nameA = the 04 (−p, SW) end upright. Longer one wider p-span.
            JFKRunwaySpec(nameB: "22R", nameA: "04L",
                          endB: (1450, 1650), endA: (1450, -900),
                          width: 60, seed: 0x04F1),
            JFKRunwaySpec(nameB: "22L", nameA: "04R",
                          endB: (2350, 1520), endA: (2350, -650),
                          width: 60, seed: 0x04F2),
        ]
    }

    private static func jfkBoxRunwayNodes(airport: AirportLayout, frame: FieldFrame) -> SCNNode {
        let container = SCNNode()
        for spec in jfkBoxSpecs() {
            let len = hypot(spec.endA.s - spec.endB.s, spec.endA.p - spec.endB.p)
            let img = WorldTex.jfkRunway(lengthMeters: len, widthMeters: spec.width,
                                         nameB: spec.nameB, nameA: spec.nameA, seed: spec.seed)
            let material = WorldMat.pbr(img, roughness: 0.6)
            material.diffuse.wrapS = .clamp
            material.diffuse.wrapT = .clamp
            material.diffuse.maxAnisotropy = 16
            let acrossTiles = Float(spec.width / 2.0)
            let alongTiles = Float(len / 2.0)
            if let nrm = WorldTex.concreteNormal() {
                material.normal.contents = nrm
                material.normal.wrapS = .repeat
                material.normal.wrapT = .repeat
                material.normal.contentsTransform = SCNMatrix4MakeScale(acrossTiles, alongTiles, 1)
                material.normal.mipFilter = .linear
                material.normal.maxAnisotropy = 16
                material.normal.intensity = 0.32
            }
            material.roughness.contents = WorldTex.concreteRoughness()
            material.roughness.wrapS = .repeat
            material.roughness.wrapT = .repeat
            material.roughness.contentsTransform = SCNMatrix4MakeScale(acrossTiles, alongTiles, 1)
            material.roughness.mipFilter = .linear
            material.roughness.maxAnisotropy = 16
            let a = frame.point(s: spec.endB.s, p: spec.endB.p)
            let b = frame.point(s: spec.endA.s, p: spec.endA.p)
            let geo = worldRibbonGeometry(points: [a, b], width: spec.width,
                                          lift: jfkBoxRunwayLift, airport: airport,
                                          vPerMeter: nil, material: material, step: 12)
            let node = SCNNode(geometry: geo)
            node.name = "runway-\(spec.nameB)-\(spec.nameA)"
            container.addChildNode(node)
        }
        container.name = "jfkBoxRunways"
        return container
    }

    /// Wide heavy-jet connectors tying the parallel taxiway to each crossing
    /// runway and stitching the box together, plus painted centerlines and edge
    /// lines. Kept clear of the active runway (the sim taxi routes are untouched).
    private static func jfkBoxTaxiwayNodes(airport: AirportLayout, frame: FieldFrame) -> SCNNode {
        let container = SCNNode()
        let parP = 1350.0
        let parOffset = 120.0            // matches KJFK's parallel "Papa" offset
        // Connector centerlines in (s,p). Wide (35 m) for A380/747 heavies.
        // A perimeter parallel on the far (NE) side of the box, running past the
        // 13L/31R threshold ends, plus stubs joining the two crossers and a link
        // from the terminal-side "Papa" parallel out to the box.
        // Outboard perimeter taxiway: beyond the crossers' +p (22) threshold ends
        // (1650 / 1520), still inside the flat field footprint (perp max ≈1870).
        let far = 1760.0
        let boxLinks: [[(s: Double, p: Double)]] = [
            // Outboard perimeter along the NE side (parallels 13L/31R).
            [(760, far), (4160, far)],
            // Two ends of the parallel 13L/31R tie into the perimeter.
            [(900, parP), (900, far)],
            [(3948, parP), (3948, far)],
            // Crossers: link each +p (22R/22L) threshold end up to the perimeter
            // (their p-spans are fitted in jfkBoxSpecs: 04L/22R ends at +1650,
            // 04R/22L at +1520).
            [(1450, 1650), (1450, far)],
            [(2350, 1520), (2350, far)],
            // Cross-feed between the two crossers along the terminal-side parallel.
            [(1450, parP), (2350, parP)],
            // Terminal "Papa" parallel out to the box parallel (heavy taxi lane).
            [(1500, parOffset), (1500, parP)],
            [(3100, parOffset), (3100, parP)],
        ]
        for link in boxLinks {
            let pts = link.map { frame.point(s: $0.s, p: $0.p) }
            let asphalt = worldRibbonGeometry(points: pts, width: 35, lift: jfkBoxTaxiLift,
                                              airport: airport, vPerMeter: 1.0 / 18.0,
                                              material: WorldMat.jfkTaxiConcrete, step: 16)
            container.addChildNode(SCNNode(geometry: asphalt))
            // Yellow centerline with a black gloss-guard band.
            let guardBand = worldRibbonGeometry(points: pts, width: 0.9,
                                                lift: jfkBoxTaxiStripeLift - 0.005,
                                                airport: airport, vPerMeter: 1.0,
                                                material: WorldMat.taxiGuardBlack)
            container.addChildNode(SCNNode(geometry: guardBand))
            let stripe = worldRibbonGeometry(points: pts, width: 0.35, lift: jfkBoxTaxiStripeLift,
                                             airport: airport, vPerMeter: 1.0,
                                             material: WorldMat.stripeYellow)
            container.addChildNode(SCNNode(geometry: stripe))
            // Double yellow edge lines.
            for side in [-1.0, 1.0] {
                for inset in [0.4, 0.85] {
                    let edgePts = offsetPolyline(pts, by: side * (35.0 / 2 - inset))
                    let line = worldRibbonGeometry(points: edgePts, width: 0.14,
                                                   lift: jfkBoxTaxiStripeLift,
                                                   airport: airport, vPerMeter: 1.0,
                                                   material: WorldMat.stripeYellow)
                    container.addChildNode(SCNNode(geometry: line))
                }
            }
        }
        let flat = container.flattenedClone()
        flat.name = "jfkBoxTaxiways"
        return flat
    }

    // MARK: - Taxiways

    /// D2 — clip any centerline endpoint that touches the runway so the stub
    /// ribbon starts at the runway edge + 0.5 m (sim routes untouched).
    private static func clippedToRunwayEdge(_ points: [V2], frame: FieldFrame,
                                            halfWidth: Double, margin: Double) -> [V2] {
        let clipP = halfWidth + margin
        return points.map { pt in
            let st = frame.station(pt)
            guard abs(st.y) < clipP, st.x > -30, st.x < frame.length + 30 else { return pt }
            return frame.point(s: st.x, p: st.y < 0 ? -clipP : clipP)
        }
    }

    private static func taxiwayNodes(airport: AirportLayout, frame: FieldFrame) -> SCNNode {
        let container = SCNNode()
        let runwayHalf = airport.runway.width / 2
        let holdBarP = frame.station(airport.holdShortPoint).y
        // JFK is a big international field: pale grooved concrete taxiways (the
        // Catalina asphalt stays for KAVX). The line-up stub is C1 at KJFK.
        let isJFK = airport.icao == "KJFK"
        let taxiMaterial = isJFK ? WorldMat.jfkTaxiConcrete : WorldMat.taxiAsphalt
        // Longer UV period on the wide JFK concrete so grooves don't strobe.
        let taxiVPerM = isJFK ? 1.0 / 18.0 : 1.0 / 14.0
        let lineUpStub = isJFK ? "C1" : "A1"

        for tw in airport.taxiways {
            let ribbon = clippedToRunwayEdge(tw.points, frame: frame,
                                             halfWidth: runwayHalf, margin: 0.5)
            let asphalt = worldRibbonGeometry(points: ribbon, width: tw.width,
                                              lift: pavementLift, airport: airport,
                                              vPerMeter: taxiVPerM,
                                              material: taxiMaterial)
            container.addChildNode(SCNNode(geometry: asphalt))

            // Centerline — clipped at the hold-short bar on the departure stub
            // (D16: never paints across the runway numbers).
            var stripePts = ribbon
            if tw.id == lineUpStub {
                stripePts = tw.points.map { pt in
                    let st = frame.station(pt)
                    if abs(st.y) < holdBarP { return frame.point(s: st.x, p: holdBarP) }
                    return pt
                }
            }
            // Black gloss-guard band under the centerline (spec taxiway line =
            // 0.15 m yellow flanked by black; here a 0.75 m dark band reads as
            // the contrast border against the grey asphalt from the cab).
            let guardBand = worldRibbonGeometry(points: stripePts, width: 0.75,
                                                lift: stripeLift - 0.005, airport: airport,
                                                vPerMeter: 1.0, material: WorldMat.taxiGuardBlack)
            container.addChildNode(SCNNode(geometry: guardBand))
            let stripe = worldRibbonGeometry(points: stripePts, width: 0.35,
                                             lift: stripeLift, airport: airport,
                                             vPerMeter: 1.0, material: WorldMat.stripeYellow)
            container.addChildNode(SCNNode(geometry: stripe))

            // D16 — double yellow edge lines.
            for side in [-1.0, 1.0] {
                for inset in [0.35, 0.75] {
                    let offset = side * (tw.width / 2 - inset)
                    let edgePts = offsetPolyline(ribbon, by: offset)
                    let line = worldRibbonGeometry(points: edgePts, width: 0.14,
                                                   lift: stripeLift, airport: airport,
                                                   vPerMeter: 1.0, material: WorldMat.stripeYellow)
                    container.addChildNode(SCNNode(geometry: line))
                }
            }
        }
        let flat = container.flattenedClone()
        flat.name = "taxiways"
        return flat
    }

    private static func offsetPolyline(_ points: [V2], by offset: Double) -> [V2] {
        guard points.count >= 2 else { return points }
        var out: [V2] = []
        for (i, p) in points.enumerated() {
            let a = points[max(0, i - 1)], b = points[min(points.count - 1, i + 1)]
            let d = simd_normalize(b - a)
            out.append(p + V2(-d.y, d.x) * offset)
        }
        return out
    }

    // MARK: - Ramp (paved) + dirt tiedown infield (A8)

    private static func groundGrid(frame: FieldFrame, airport: AirportLayout,
                                   s0: Double, sLen: Double, p0: Double, pLen: Double,
                                   lift: Double, cols: Int, rows: Int,
                                   material: SCNMaterial) -> SCNGeometry {
        var mesh = WorldMesh()
        let up = SIMD3<Float>(0, 1, 0)
        var grid: [[Int32]] = []
        for r in 0...rows {
            var rowIdx: [Int32] = []
            let p = p0 + pLen * Double(r) / Double(rows)
            for c in 0...cols {
                let s = s0 + sLen * Double(c) / Double(cols)
                let world = frame.point(s: s, p: p)
                let y = airport.groundHeight(at: world) + lift
                rowIdx.append(mesh.add(worldF3(world, y), up,
                                       SIMD2(Float(Double(c) / Double(cols)),
                                             Float(Double(r) / Double(rows)))))
            }
            grid.append(rowIdx)
        }
        for r in 0..<rows {
            for c in 0..<cols {
                mesh.quad(grid[r][c], grid[r][c + 1], grid[r + 1][c + 1], grid[r + 1][c],
                          desiredNormal: up)
            }
        }
        return mesh.build(material: material)
    }

    private static func apronNode(airport: AirportLayout, frame: FieldFrame) -> SCNNode {
        // Paved transient spots only (dirt rows live on the infield).
        var paved: [(s: Double, p: Double)] = []
        for spot in airport.apronSpots {
            let st = frame.station(spot.position)
            if st.y >= pavedSpotMinP { paved.append((st.x, st.y)) }
        }
        let image = WorldTex.apron(s0: apronS0, sLen: apronSLen,
                                   p0: apronP0, pLen: apronPLen, spots: paved)
        let material = WorldMat.pbr(image, roughness: 0.82)
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        let node = SCNNode(geometry: groundGrid(frame: frame, airport: airport,
                                                s0: apronS0, sLen: apronSLen,
                                                p0: apronP0, pLen: apronPLen,
                                                lift: pavementLift, cols: 14, rows: 5,
                                                material: material))
        node.name = "apron"
        return node
    }

    private static func infieldNode(airport: AirportLayout, frame: FieldFrame) -> SCNNode {
        var dirtSpots: [(s: Double, p: Double)] = []
        var rowPs: Set<Int> = []
        for spot in airport.apronSpots {
            let st = frame.station(spot.position)
            if st.y < pavedSpotMinP {
                dirtSpots.append((st.x, st.y))
                rowPs.insert(Int(st.y.rounded()))
            }
        }
        let image = WorldTex.dirtInfield(s0: infieldS0, sLen: infieldSLen,
                                         p0: infieldP0, pLen: infieldPLen,
                                         rowPs: rowPs.sorted().map(Double.init),
                                         spots: dirtSpots)
        let material = WorldMat.pbr(image, roughness: 0.96)
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        let node = SCNNode(geometry: groundGrid(frame: frame, airport: airport,
                                                s0: infieldS0, sLen: infieldSLen,
                                                p0: infieldP0, pLen: infieldPLen,
                                                lift: 0.03, cols: 12, rows: 3,
                                                material: material))
        node.name = "dirtInfield"
        return node
    }

    // MARK: - DC-3 fuel pit covers (A8 — flush steel discs by the terminal)

    private static func fuelPitNode(airport: AirportLayout, frame: FieldFrame) -> SCNNode {
        let container = SCNNode()
        for s in [576.0, 590.0, 604.0] {
            let world = frame.point(s: s, p: 141)
            let y = airport.groundHeight(at: world)
            let disc = SCNNode(geometry: SCNCylinder(radius: 0.6, height: 0.05))
            disc.geometry?.materials = [WorldMat.fuelPitSteel]
            disc.position = worldV3(world, y + pavementLift + 0.035)
            container.addChildNode(disc)
        }
        let flat = container.flattenedClone()
        flat.name = "fuelPits"
        return flat
    }

    // MARK: - Hold-short bar (stub A1)

    private static func holdShortNode(airport: AirportLayout, frame: FieldFrame) -> SCNNode {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = WorldTex.holdShortBar()
        material.roughness.contents = 0.7
        material.isDoubleSided = false
        material.transparency = 1
        material.blendMode = .alpha
        material.writesToDepthBuffer = false

        // Bar spans the taxiway width; the solid pair faces the holding side
        // (away from the runway → larger p).
        let st = frame.station(airport.holdShortPoint)
        var mesh = WorldMesh()
        let up = SIMD3<Float>(0, 1, 0)
        let halfW = 5.0     // across the 10 m stub, along the runway axis
        let depth = 2.1
        var idx: [Int32] = []
        // v=0 edge toward the runway (smaller p) → dashed pair (texture top);
        // the solid pair faces the holding aircraft on the Alpha side.
        for (u, v) in [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)] {
            let s = st.x - halfW + u * halfW * 2
            let p = st.y - depth / 2 + v * depth
            let world = frame.point(s: s, p: p)
            let y = airport.groundHeight(at: world) + decalLift
            idx.append(mesh.add(worldF3(world, y), up, SIMD2(Float(u), Float(v))))
        }
        mesh.quad(idx[0], idx[1], idx[2], idx[3], desiredNormal: up)
        let node = SCNNode(geometry: mesh.build(material: material))
        node.name = "holdShortBar"
        return node
    }

    // MARK: - Dirt service road (D19 — winds SE from the ramp toward the rim)

    private static func serviceRoadNode(airport: AirportLayout, frame: FieldFrame) -> SCNNode {
        let waypoints: [(Double, Double)] = [
            (618, 128), (660, 168), (712, 224), (748, 268), (772, 296),
        ]
        let points = waypoints.map { frame.point(s: $0.0, p: $0.1) }
        let geometry = worldRibbonGeometry(points: points, width: 4.6, lift: 0.03,
                                           airport: airport, vPerMeter: 1.0 / 9.0,
                                           material: WorldMat.dirt, step: 14)
        let node = SCNNode(geometry: geometry)
        node.name = "serviceRoad"
        return node
    }
}
