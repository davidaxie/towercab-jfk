import Foundation
import SceneKit
import UIKit
import simd

// =============================================================================
// Airport paved surfaces — runway ribbon (rides the midfield hump), taxiways
// with yellow centerlines, hold-short bar, apron slab with tiedowns, and the
// dirt service road. Geometry follows AirportLayout.kavx verbatim.
// =============================================================================

enum WorldAirportBuilder {

    // Pavement sits just proud of the terrain mesh to avoid z-fighting.
    static let pavementLift = 0.06
    static let stripeLift = 0.11
    static let decalLift = 0.14

    static func build(into root: SCNNode, airport: AirportLayout) {
        let frame = FieldFrame(airport)
        root.addChildNode(runwayNode(airport: airport))
        root.addChildNode(taxiwayNodes(airport: airport))
        root.addChildNode(apronNode(airport: airport, frame: frame))
        root.addChildNode(holdShortNode(airport: airport, frame: frame))
        root.addChildNode(serviceRoadNode(airport: airport, frame: frame))
    }

    // MARK: - Runway

    private static func runwayNode(airport: AirportLayout) -> SCNNode {
        let rw = airport.runway
        let material = WorldMat.pbr(
            WorldTex.runway(lengthMeters: rw.length, widthMeters: rw.width),
            roughness: 0.87)
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        // Ribbon from threshold B (v=0) to A (v=1); u=0 on the +perp side,
        // matching the texture's numeral orientation.
        let geometry = worldRibbonGeometry(points: [rw.thresholdB, rw.thresholdA],
                                           width: rw.width, lift: pavementLift,
                                           airport: airport, vPerMeter: nil,
                                           material: material, step: 10)
        let node = SCNNode(geometry: geometry)
        node.name = "runway"
        return node
    }

    // MARK: - Taxiways

    private static func taxiwayNodes(airport: AirportLayout) -> SCNNode {
        let container = SCNNode()
        for tw in airport.taxiways {
            let asphalt = worldRibbonGeometry(points: tw.points, width: tw.width,
                                              lift: pavementLift, airport: airport,
                                              vPerMeter: 1.0 / 14.0,
                                              material: WorldMat.taxiAsphalt)
            container.addChildNode(SCNNode(geometry: asphalt))
            let stripe = worldRibbonGeometry(points: tw.points, width: 0.35,
                                             lift: stripeLift, airport: airport,
                                             vPerMeter: 1.0, material: WorldMat.stripeYellow)
            container.addChildNode(SCNNode(geometry: stripe))
        }
        // Apron ↔ Alpha connector (first leg of the layout's taxi-out route).
        let connector = Array(airport.routeTaxiOut.prefix(2))
        if connector.count == 2 {
            let asphalt = worldRibbonGeometry(points: connector, width: 12,
                                              lift: pavementLift, airport: airport,
                                              vPerMeter: 1.0 / 14.0,
                                              material: WorldMat.taxiAsphalt)
            container.addChildNode(SCNNode(geometry: asphalt))
            let stripe = worldRibbonGeometry(points: connector, width: 0.35,
                                             lift: stripeLift, airport: airport,
                                             vPerMeter: 1.0, material: WorldMat.stripeYellow)
            container.addChildNode(SCNNode(geometry: stripe))
        }
        let flat = container.flattenedClone()
        flat.name = "taxiways"
        return flat
    }

    // MARK: - Apron

    /// Apron rect in runway-frame coordinates (shared with GroundDetails so
    /// buildings hug its edges).
    static let apronS0 = 408.0, apronSLen = 174.0
    static let apronP0 = 72.0, apronPLen = 106.0

    private static func apronNode(airport: AirportLayout, frame: FieldFrame) -> SCNNode {
        var spots: [(s: Double, p: Double)] = []
        for spot in airport.apronSpots {
            let st = frame.station(spot.position)
            spots.append((st.x, st.y))
        }
        // The VIP pad = center spot of the deeper row (largest p).
        let vip = spots.max { a, b in
            (a.p, -abs(a.s - (apronS0 + apronSLen / 2))) < (b.p, -abs(b.s - (apronS0 + apronSLen / 2)))
        }
        let image = WorldTex.apron(s0: apronS0, sLen: apronSLen, p0: apronP0, pLen: apronPLen,
                                   spots: spots, vipSpot: vip)
        let material = WorldMat.pbr(image, roughness: 0.82)
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp

        var mesh = WorldMesh()
        let up = SIMD3<Float>(0, 1, 0)
        let cols = 12, rows = 8
        var grid: [[Int32]] = []
        for r in 0...rows {
            var rowIdx: [Int32] = []
            let p = apronP0 + apronPLen * Double(r) / Double(rows)
            for c in 0...cols {
                let s = apronS0 + apronSLen * Double(c) / Double(cols)
                let world = frame.point(s: s, p: p)
                let y = airport.groundHeight(at: world) + pavementLift
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
        let node = SCNNode(geometry: mesh.build(material: material))
        node.name = "apron"
        return node
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

    // MARK: - Dirt service road

    private static func serviceRoadNode(airport: AirportLayout, frame: FieldFrame) -> SCNNode {
        let waypoints: [(Double, Double)] = [
            (582, 108), (640, 132), (700, 158), (790, 186), (880, 202), (952, 208),
        ]
        let points = waypoints.map { frame.point(s: $0.0, p: $0.1) }
        let geometry = worldRibbonGeometry(points: points, width: 4.2, lift: 0.03,
                                           airport: airport, vPerMeter: 1.0 / 9.0,
                                           material: WorldMat.dirt, step: 18)
        let node = SCNNode(geometry: geometry)
        node.name = "serviceRoad"
        return node
    }
}
