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

    // Pavement sits just proud of the terrain mesh to avoid z-fighting.
    static let pavementLift = 0.06
    static let stripeLift = 0.11
    static let decalLift = 0.14

    /// Ramp + infield rects in runway-frame coordinates (shared with
    /// GroundDetails so buildings hug their edges).
    static let apronS0 = 420.0, apronSLen = 200.0
    static let apronP0 = 96.0, apronPLen = 54.0
    static let infieldS0 = 430.0, infieldSLen = 180.0
    static let infieldP0 = 62.0, infieldPLen = 34.0
    /// Spots with p beyond this are on the paved ramp; the rest are dirt (A8).
    static let pavedSpotMinP = 95.0

    static func build(into root: SCNNode, airport: AirportLayout) {
        let frame = FieldFrame(airport)
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

        for tw in airport.taxiways {
            let ribbon = clippedToRunwayEdge(tw.points, frame: frame,
                                             halfWidth: runwayHalf, margin: 0.5)
            let asphalt = worldRibbonGeometry(points: ribbon, width: tw.width,
                                              lift: pavementLift, airport: airport,
                                              vPerMeter: 1.0 / 14.0,
                                              material: WorldMat.taxiAsphalt)
            container.addChildNode(SCNNode(geometry: asphalt))

            // Centerline — clipped at the hold-short bar on the departure stub
            // (D16: never paints across the runway numbers).
            var stripePts = ribbon
            if tw.id == "A1" {
                stripePts = tw.points.map { pt in
                    let st = frame.station(pt)
                    if abs(st.y) < holdBarP { return frame.point(s: st.x, p: holdBarP) }
                    return pt
                }
            }
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
