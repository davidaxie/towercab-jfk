import Foundation
import SceneKit
import UIKit
import simd

// =============================================================================
// Airfield details — PAPI, runway edge lights (the dusk switch-on beat),
// windsock, hangars, the Spanish-style terminal, the fictional tower shaft,
// scrub, and boulders. Emissive materials register with AirfieldLightBank;
// the sky director drives their dusk ramp from sim time.
// =============================================================================

/// Emissive materials / lights that switch on around dusk. Sky calls
/// `update(hour:)` every frame; per-entry work is just a CGFloat store.
final class AirfieldLightBank {
    private struct MaterialEntry {
        let material: SCNMaterial
        let onHour: Double
        let rampHours: Double
        let dayIntensity: CGFloat
        let nightIntensity: CGFloat
    }
    private struct LightEntry {
        let light: SCNLight
        let onHour: Double
        let rampHours: Double
        let nightIntensity: CGFloat
    }
    private var materials: [MaterialEntry] = []
    private var lights: [LightEntry] = []

    /// `onHour < 0` means always on at `dayIntensity` (PAPI), still brightening at dusk.
    func register(material: SCNMaterial, color: UIColor, onHour: Double,
                  ramp: Double = 0.0015, day: CGFloat = 0, night: CGFloat) {
        material.emission.contents = color
        material.emission.intensity = day
        materials.append(MaterialEntry(material: material, onHour: onHour, rampHours: ramp,
                                       dayIntensity: day, nightIntensity: night))
    }

    func register(light: SCNLight, onHour: Double, ramp: Double = 0.004, night: CGFloat) {
        light.intensity = 0
        lights.append(LightEntry(light: light, onHour: onHour, rampHours: ramp, nightIntensity: night))
    }

    func update(hour: Double) {
        for e in materials {
            let a: Double
            if e.onHour < 0 {
                a = worldSmoothstep(18.05, 18.05 + 0.02, hour)   // always-on: dusk boost only
            } else {
                a = worldSmoothstep(e.onHour, e.onHour + e.rampHours, hour)
            }
            e.material.emission.intensity = e.dayIntensity + CGFloat(a) * (e.nightIntensity - e.dayIntensity)
        }
        for e in lights {
            let a = worldSmoothstep(e.onHour, e.onHour + e.rampHours, hour)
            e.light.intensity = CGFloat(a) * e.nightIntensity
        }
    }
}

enum WorldDetailsBuilder {

    /// Dusk choreography (sim hours). Edge lights walk down the runway
    /// over ~2 real seconds starting 18:06.
    static let windowsOnHour = 18.03
    static let apronFloodOnHour = 18.05
    static let edgeLightsOnHour = 18.10
    static let edgeLightGroupStagger = 0.0013

    static func build(into root: SCNNode, airport: AirportLayout, bank: AirfieldLightBank) {
        let frame = FieldFrame(airport)
        root.addChildNode(papiNode(airport: airport, frame: frame, bank: bank))
        for group in edgeLightNodes(airport: airport, frame: frame, bank: bank) {
            root.addChildNode(group)
        }
        root.addChildNode(windsockNode(airport: airport, bank: bank))
        root.addChildNode(buildingsNode(airport: airport, frame: frame, bank: bank))
        root.addChildNode(towerNode(airport: airport, bank: bank))
        root.addChildNode(apronFloodNode(airport: airport, frame: frame, bank: bank))
        root.addChildNode(scrubNode(airport: airport, frame: frame))
    }

    // MARK: - PAPI (left of the 22 threshold, on-glide two-white-two-red)

    private static func papiNode(airport: AirportLayout, frame: FieldFrame, bank: AirfieldLightBank) -> SCNNode {
        let container = SCNNode()
        // Pilot's left when landing 22 = -perp side.
        let housing = WorldMat.pbr(worldColor(0.16, 0.18, 0.16), roughness: 0.6, metalness: 0.3)
        let white = SCNMaterial()
        white.lightingModel = .constant
        white.diffuse.contents = UIColor.black
        bank.register(material: white, color: worldColor(1.0, 0.98, 0.92), onHour: -1, day: 2.4, night: 5.0)
        let red = SCNMaterial()
        red.lightingModel = .constant
        red.diffuse.contents = UIColor.black
        bank.register(material: red, color: worldColor(1.0, 0.16, 0.10), onHour: -1, day: 2.4, night: 5.0)

        // Faces the 22 approach (looking back up the glideslope, toward -dir).
        let facingYaw = Float(-airport.runway.heading04)
        for i in 0..<4 {
            let st = frame.point(s: 150, p: -(airport.runway.width / 2 + 14 + Double(i) * 3.2))
            let y = airport.groundHeight(at: st)
            let box = SCNNode(geometry: SCNBox(width: 0.85, height: 0.5, length: 0.55, chamferRadius: 0.05))
            box.geometry?.materials = [housing]
            box.position = worldV3(st, y + 0.55)
            box.eulerAngles.y = facingYaw
            container.addChildNode(box)
            let lens = SCNNode(geometry: SCNPlane(width: 0.55, height: 0.26))
            lens.geometry?.materials = [i < 2 ? white : red]   // outer pair white, inner red
            lens.position = SCNVector3(0, 0.04, 0.29)
            box.addChildNode(lens)
            let leg = SCNNode(geometry: SCNCylinder(radius: 0.05, height: 0.35))
            leg.geometry?.materials = [housing]
            leg.position = worldV3(st, y + 0.17)
            container.addChildNode(leg)
        }
        let flat = container.flattenedClone()
        flat.name = "papi"
        return flat
    }

    // MARK: - Runway edge + threshold lights (staggered dusk switch-on)

    private static func edgeLightNodes(airport: AirportLayout, frame: FieldFrame,
                                       bank: AirfieldLightBank) -> [SCNNode] {
        let groupCount = 6
        var groups: [SCNNode] = []
        let stakeMat = WorldMat.pbr(worldColor(0.5, 0.48, 0.44), roughness: 0.7, metalness: 0.3)
        let length = airport.runway.length
        let lateral = airport.runway.width / 2 + 2.5

        func lamp(at st: V2, material: SCNMaterial, parent: SCNNode) {
            let world = frame.point(s: st.x, p: st.y)
            let y = airport.groundHeight(at: world)
            let post = SCNNode(geometry: SCNCylinder(radius: 0.05, height: 0.30))
            post.geometry?.materials = [stakeMat]
            post.position = worldV3(world, y + 0.15)
            parent.addChildNode(post)
            // Oversized on purpose: a 15 cm lamp is sub-pixel from the cab.
            // Diorama law — the light must READ at 500 m, not measure true.
            let head = SCNNode(geometry: SCNSphere(radius: 0.42))
            head.geometry?.materials = [material]
            head.position = worldV3(world, y + 0.5)
            parent.addChildNode(head)
        }

        // Edge lights: warm white, in 6 groups marching from the 22 end.
        for g in 0..<groupCount {
            let container = SCNNode()
            let mat = SCNMaterial()
            mat.lightingModel = .constant
            mat.diffuse.contents = worldColor(0.14, 0.12, 0.09)
            bank.register(material: mat, color: worldColor(1.0, 0.85, 0.58),
                          onHour: edgeLightsOnHour + Double(g) * edgeLightGroupStagger,
                          night: 7.0)
            let s0 = length * Double(g) / Double(groupCount)
            let s1 = length * Double(g + 1) / Double(groupCount)
            var s = s0 + 14
            while s < s1 {
                lamp(at: V2(s, lateral), material: mat, parent: container)
                lamp(at: V2(s, -lateral), material: mat, parent: container)
                s += 55
            }
            let flat = container.flattenedClone()
            flat.name = "edgeLights\(g)"
            groups.append(flat)
        }
        // Threshold bar at the 22 end: green, switches with group 0.
        let thresholdContainer = SCNNode()
        let green = SCNMaterial()
        green.lightingModel = .constant
        green.diffuse.contents = worldColor(0.06, 0.10, 0.07)
        bank.register(material: green, color: worldColor(0.15, 1.0, 0.35),
                      onHour: edgeLightsOnHour, night: 4.5)
        for k in 0..<6 {
            let p = -lateral + Double(k) / 5.0 * lateral * 2
            lamp(at: V2(-4, p), material: green, parent: thresholdContainer)
        }
        let flat = thresholdContainer.flattenedClone()
        flat.name = "thresholdLights"
        groups.append(flat)
        return groups
    }

    // MARK: - Windsock (wind 240/8 — points toward heading 060, gently working)

    private static func windsockNode(airport: AirportLayout, bank: AirfieldLightBank) -> SCNNode {
        let base = SCNNode()
        base.name = "windsock"
        let groundY = airport.groundHeight(at: airport.windsockPosition)
        base.position = worldV3(airport.windsockPosition, groundY)

        let poleMat = WorldMat.whitePaintMetal
        let pole = SCNNode(geometry: SCNCylinder(radius: 0.07, height: 5.0))
        pole.geometry?.materials = [poleMat]
        pole.position = SCNVector3(0, 2.5, 0)
        base.addChildNode(pole)

        // Lit ring just under the sock — a dusk beacon for the sock itself.
        let ringMat = SCNMaterial()
        ringMat.lightingModel = .constant
        ringMat.diffuse.contents = worldColor(0.2, 0.16, 0.1)
        bank.register(material: ringMat, color: worldColor(1.0, 0.82, 0.5), onHour: 18.107, night: 3.5)
        let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.22, pipeRadius: 0.045))
        ring.geometry?.materials = [ringMat]
        ring.position = SCNVector3(0, 4.72, 0)
        base.addChildNode(ring)

        // Sock assembly: yaw to the wind, drooped for ~8 kts, wobbling gently.
        let yaw = SCNNode()
        yaw.position = SCNVector3(0, 4.95, 0)
        yaw.eulerAngles.y = Float(-degToRad(60))            // wind FROM 240 → sock points 060
        base.addChildNode(yaw)
        let droop = SCNNode()
        droop.eulerAngles.x = -0.42                          // ~24° below horizontal
        yaw.addChildNode(droop)

        let sockMat = SCNMaterial()
        sockMat.lightingModel = .physicallyBased
        sockMat.diffuse.contents = WorldTex.windsock()
        sockMat.roughness.contents = 0.9
        sockMat.isDoubleSided = true
        // Read against a backlit dusk sky — the sock is wind info, never dark.
        sockMat.emission.contents = UIColor(red: 0.42, green: 0.16, blue: 0.03, alpha: 1)
        let cone = SCNCone(topRadius: 0.14, bottomRadius: 0.40, height: 3.0)
        cone.materials = [sockMat]
        let sock = SCNNode(geometry: cone)
        sock.eulerAngles.x = -.pi / 2                        // cone +Y (tip) points along -Z
        sock.position = SCNVector3(0, 0, -1.5)
        droop.addChildNode(sock)

        // Gentle 8 kt breathing: droop and yaw wobble on offset periods.
        let droopWobble = SCNAction.repeatForever(.sequence([
            .rotateTo(x: -0.34, y: 0, z: 0, duration: 1.7, usesShortestUnitArc: true),
            .rotateTo(x: -0.50, y: 0, z: 0, duration: 2.3, usesShortestUnitArc: true),
            .rotateTo(x: -0.40, y: 0, z: 0, duration: 1.4, usesShortestUnitArc: true),
            .rotateTo(x: -0.47, y: 0, z: 0, duration: 2.0, usesShortestUnitArc: true),
        ]))
        droopWobble.timingMode = .easeInEaseOut
        droop.runAction(droopWobble)
        let yawBase = -degToRad(60)
        let yawWobble = SCNAction.repeatForever(.sequence([
            .rotateTo(x: 0, y: CGFloat(yawBase + 0.10), z: 0, duration: 2.6, usesShortestUnitArc: true),
            .rotateTo(x: 0, y: CGFloat(yawBase - 0.08), z: 0, duration: 3.1, usesShortestUnitArc: true),
            .rotateTo(x: 0, y: CGFloat(yawBase + 0.04), z: 0, duration: 2.2, usesShortestUnitArc: true),
        ]))
        yawWobble.timingMode = .easeInEaseOut
        yaw.runAction(yawWobble)
        return base
    }

    // MARK: - Buildings (hangars + Spanish terminal)

    private static func buildingsNode(airport: AirportLayout, frame: FieldFrame,
                                      bank: AirfieldLightBank) -> SCNNode {
        let container = SCNNode()
        let yawAlign = Float(-airport.runway.heading22)

        // Shared warm window glow (dusk).
        let windowMat = SCNMaterial()
        windowMat.lightingModel = .constant
        windowMat.diffuse.contents = worldColor(0.12, 0.09, 0.06)
        bank.register(material: windowMat, color: worldColor(1.0, 0.72, 0.38),
                      onHour: windowsOnHour, ramp: 0.006, night: 3.2)

        func place(_ node: SCNNode, s: Double, p: Double, extraYaw: Float = 0, sink: Double = 0.25) {
            let world = frame.point(s: s, p: p)
            let y = airport.groundHeight(at: world) - sink
            node.position = worldV3(world, y)
            node.eulerAngles.y = yawAlign + extraYaw
            container.addChildNode(node)
            // Dirt pad footprint so structures don't sit straight on grass.
            let pad = SCNNode(geometry: SCNPlane(width: 30, height: 26))
            pad.geometry?.materials = [WorldMat.dirt]
            pad.eulerAngles.x = -.pi / 2
            pad.position = worldV3(world, airport.groundHeight(at: world) + 0.04)
            container.addChildNode(pad)
        }

        // Hangar 1 — cream, big open dark doorway facing the apron (-p side).
        let h1 = gabledHangar(width: 24, depth: 16, wallH: 4.6, ridgeH: 7.0,
                              wall: WorldMat.corrugatedCream, roof: WorldMat.corrugatedSage,
                              front: WorldMat.pbr(WorldTex.hangarFront(baseR: 0.83, baseG: 0.77, baseB: 0.66,
                                                                       openDoor: true, seed: 0x91),
                                                  roughness: 0.55, metalness: 0.2))
        place(h1, s: 452, p: 188, extraYaw: .pi / 2)   // doorway faces the apron (-p)

        // Hangar 2 — sage, closed, slightly skewed.
        let h2 = gabledHangar(width: 19, depth: 13, wallH: 4.0, ridgeH: 6.0,
                              wall: WorldMat.corrugatedSage, roof: WorldMat.corrugatedCream,
                              front: WorldMat.pbr(WorldTex.hangarFront(baseR: 0.62, baseG: 0.63, baseB: 0.53,
                                                                       openDoor: false, seed: 0x92),
                                                  roughness: 0.6, metalness: 0.2))
        place(h2, s: 512, p: 191, extraYaw: .pi / 2 + 0.09)
        // Hangar 2 side windows (warm at dusk).
        for dx in [-4.0, 0.0, 4.0] {
            let w = SCNNode(geometry: SCNPlane(width: 1.4, height: 0.9))
            w.geometry?.materials = [windowMat]
            w.position = SCNVector3(Float(dx), 2.6, Float(-13.0 / 2) - 0.05)
            w.eulerAngles.y = .pi
            h2.addChildNode(w)
        }

        // Spanish-style terminal — white stucco, red tile hip roof, arcade.
        let terminal = SCNNode()
        let bodyW: CGFloat = 17, bodyD: CGFloat = 10, bodyH: CGFloat = 4.2
        let body = SCNNode(geometry: SCNBox(width: bodyW, height: bodyH, length: bodyD, chamferRadius: 0))
        let frontMat = WorldMat.pbr(WorldTex.terminalFront(), roughness: 0.9)
        // SCNBox materials: +Z, +X, -Z, -X, +Y, -Y. Front (+Z) faces the apron.
        body.geometry?.materials = [frontMat, WorldMat.stucco, WorldMat.stucco,
                                    WorldMat.stucco, WorldMat.stucco, WorldMat.stucco]
        body.position = SCNVector3(0, Float(bodyH / 2), 0)
        terminal.addChildNode(body)
        let roof = SCNNode(geometry: SCNPyramid(width: bodyW + 2.2, height: 2.6, length: bodyD + 2.2))
        roof.geometry?.materials = [WorldMat.roofTile]
        roof.position = SCNVector3(0, Float(bodyH), 0)
        terminal.addChildNode(roof)
        // Porch: tile slab on four posts along the front.
        let porch = SCNNode(geometry: SCNBox(width: bodyW - 3, height: 0.25, length: 2.6, chamferRadius: 0))
        porch.geometry?.materials = [WorldMat.roofTile]
        porch.position = SCNVector3(0, 3.0, Float(bodyD / 2) + 1.3)
        terminal.addChildNode(porch)
        for i in 0..<4 {
            let post = SCNNode(geometry: SCNBox(width: 0.28, height: 3.0, length: 0.28, chamferRadius: 0.02))
            post.geometry?.materials = [WorldMat.stucco]
            let x = Float(-(bodyW - 4) / 2) + Float(i) * Float((bodyW - 4) / 3)
            post.position = SCNVector3(x, 1.5, Float(bodyD / 2) + 2.2)
            terminal.addChildNode(post)
        }
        // Cupola.
        let cup = SCNNode(geometry: SCNBox(width: 1.6, height: 1.4, length: 1.6, chamferRadius: 0))
        cup.geometry?.materials = [WorldMat.stucco]
        cup.position = SCNVector3(0, Float(bodyH) + 2.6, 0)
        terminal.addChildNode(cup)
        let cupRoof = SCNNode(geometry: SCNPyramid(width: 2.0, height: 0.9, length: 2.0))
        cupRoof.geometry?.materials = [WorldMat.roofTile]
        cupRoof.position = SCNVector3(0, Float(bodyH) + 3.3, 0)
        terminal.addChildNode(cupRoof)
        // Terminal windows glow through the arches at dusk.
        for dx in [-4.2, 0.0, 4.2] {
            let w = SCNNode(geometry: SCNPlane(width: 1.5, height: 1.9))
            w.geometry?.materials = [windowMat]
            w.position = SCNVector3(Float(dx), 1.5, Float(bodyD / 2) + 0.06)
            terminal.addChildNode(w)
        }
        // Terminal front (+Z local) faces NE toward the apron with extraYaw 0.
        place(terminal, s: 604, p: 122, extraYaw: 0)

        let flat = container.flattenedClone()
        flat.name = "buildings"
        return flat
    }

    private static func gabledHangar(width: CGFloat, depth: CGFloat, wallH: CGFloat, ridgeH: CGFloat,
                                     wall: SCNMaterial, roof: SCNMaterial, front: SCNMaterial) -> SCNNode {
        let node = SCNNode()
        let w = Float(width), d = Float(depth), h = Float(wallH), r = Float(ridgeH)

        var walls = WorldMesh()
        // Side walls (±X), back wall (+Z rear).
        func wallQuad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ dd: SIMD3<Float>,
                      normal: SIMD3<Float>, uScale: Float) {
            let ia = walls.add(a, normal, SIMD2(0, 1))
            let ib = walls.add(b, normal, SIMD2(uScale, 1))
            let ic = walls.add(c, normal, SIMD2(uScale, 0))
            let id = walls.add(dd, normal, SIMD2(0, 0))
            walls.quad(ia, ib, ic, id, desiredNormal: normal)
        }
        let uSide = Float(depth / 3), uBack = Float(width / 3)
        wallQuad(SIMD3(-w/2, 0, -d/2), SIMD3(-w/2, 0, d/2), SIMD3(-w/2, h, d/2), SIMD3(-w/2, h, -d/2),
                 normal: SIMD3(-1, 0, 0), uScale: uSide)
        wallQuad(SIMD3(w/2, 0, d/2), SIMD3(w/2, 0, -d/2), SIMD3(w/2, h, -d/2), SIMD3(w/2, h, d/2),
                 normal: SIMD3(1, 0, 0), uScale: uSide)
        // Back gable (+Z): wall + triangle to ridge.
        wallQuad(SIMD3(w/2, 0, d/2), SIMD3(-w/2, 0, d/2), SIMD3(-w/2, h, d/2), SIMD3(w/2, h, d/2),
                 normal: SIMD3(0, 0, 1), uScale: uBack)
        let bg0 = walls.add(SIMD3(-w/2, h, d/2), SIMD3(0, 0, 1), SIMD2(0, 0))
        let bg1 = walls.add(SIMD3(w/2, h, d/2), SIMD3(0, 0, 1), SIMD2(uBack, 0))
        let bg2 = walls.add(SIMD3(0, r, d/2), SIMD3(0, 0, 1), SIMD2(uBack / 2, -0.6))
        let bp0 = walls.positions[Int(bg0)], bp1 = walls.positions[Int(bg1)], bp2 = walls.positions[Int(bg2)]
        if simd_dot(simd_cross(bp1 - bp0, bp2 - bp0), SIMD3(0, 0, 1)) >= 0 {
            walls.triangle(bg0, bg1, bg2)
        } else {
            walls.triangle(bg0, bg2, bg1)
        }
        let wallNode = SCNNode(geometry: walls.build(material: wall))
        node.addChildNode(wallNode)

        // Front gable (-Z): flat facade with the doorway texture.
        var frontMesh = WorldMesh()
        let fn = SIMD3<Float>(0, 0, -1)
        let f0 = frontMesh.add(SIMD3(-w/2, 0, -d/2), fn, SIMD2(0, 1))
        let f1 = frontMesh.add(SIMD3(w/2, 0, -d/2), fn, SIMD2(1, 1))
        let f2 = frontMesh.add(SIMD3(w/2, h, -d/2), fn, SIMD2(1, 0.25))
        let f3 = frontMesh.add(SIMD3(-w/2, h, -d/2), fn, SIMD2(0, 0.25))
        let f4 = frontMesh.add(SIMD3(0, r, -d/2), fn, SIMD2(0.5, 0))
        frontMesh.quad(f0, f1, f2, f3, desiredNormal: fn)
        frontMesh.triangle(f3, f2, f4)
        // ensure winding faces -Z
        let frontNode = SCNNode(geometry: frontMesh.build(material: front))
        node.addChildNode(frontNode)

        // Roof planes with a small eave overhang.
        var roofMesh = WorldMesh()
        let ov: Float = 0.7
        let roofU = Float(depth / 3), roofV = Float(width / 5)
        func roofPlane(_ eaveX: Float) {
            let nx: Float = eaveX < 0 ? -0.6 : 0.6
            let normal = simd_normalize(SIMD3<Float>(nx, 1, 0))
            let a = SIMD3<Float>(eaveX, h - 0.15, -d/2 - ov)
            let b = SIMD3<Float>(eaveX, h - 0.15, d/2 + ov)
            let c = SIMD3<Float>(0, r + 0.08, d/2 + ov)
            let dd = SIMD3<Float>(0, r + 0.08, -d/2 - ov)
            let ia = roofMesh.add(a, normal, SIMD2(0, 0))
            let ib = roofMesh.add(b, normal, SIMD2(roofU, 0))
            let ic = roofMesh.add(c, normal, SIMD2(roofU, roofV))
            let id = roofMesh.add(dd, normal, SIMD2(0, roofV))
            roofMesh.quad(ia, ib, ic, id, desiredNormal: normal)
        }
        roofPlane(-w/2 - ov)
        roofPlane(w/2 + ov)
        let roofMat = roof.copy() as! SCNMaterial
        roofMat.isDoubleSided = true
        let roofNode = SCNNode(geometry: roofMesh.build(material: roofMat))
        node.addChildNode(roofNode)
        return node
    }

    // MARK: - Tower (exterior shaft under the cab eye)

    private static func towerNode(airport: AirportLayout, bank: AirfieldLightBank) -> SCNNode {
        let container = SCNNode()
        container.name = "towerExterior"
        let eye = airport.towerCabEye
        let ground2D = V2(eye.x, eye.z)
        let groundY = airport.groundHeight(at: ground2D)
        // The exterior wraps the camera: the CabInterior (glass at r 2.5,
        // panes -0.72…+1.22, console -0.53, floor -1.65, ceiling +1.44 around
        // the eye) supplies everything the player sees at eye level. Exterior
        // pieces must stay OUT of the sightline band: sill fascia tops out
        // below the glass, roof fascia floats above the interior ceiling, and
        // the catwalk rails stay under the runway sightline (~12.7° down).
        let floorY = eye.y - 1.72              // cab floor / catwalk level
        let sillTopY = eye.y - 0.78            // fascia stops below the glass sill
        let roofY = eye.y + 1.55               // exterior roof fascia
        func at(_ y: Double) -> SCNVector3 { SCNVector3(Float(eye.x), Float(y), Float(eye.z)) }

        let shaftH = floorY - groundY + 0.4
        let shaft = SCNNode(geometry: SCNCylinder(radius: 1.9, height: CGFloat(shaftH)))
        shaft.geometry?.materials = [WorldMat.stucco]
        shaft.position = at(groundY + shaftH / 2 - 0.4)
        container.addChildNode(shaft)

        // Flared support under the catwalk.
        let flare = SCNNode(geometry: SCNCone(topRadius: 2.9, bottomRadius: 1.9, height: 1.6))
        flare.geometry?.materials = [WorldMat.stucco]
        flare.position = at(floorY - 0.9)
        container.addChildNode(flare)

        // Catwalk floor + low rails (kept below the 12.7° runway sightline).
        let walk = SCNNode(geometry: SCNTube(innerRadius: 2.5, outerRadius: 3.4, height: 0.1))
        walk.geometry?.materials = [WorldMat.whitePaintMetal]
        walk.position = at(floorY - 0.05)
        container.addChildNode(walk)
        for railY in [floorY + 0.35, floorY + 0.72] {
            let rail = SCNNode(geometry: SCNTorus(ringRadius: 3.35, pipeRadius: 0.03))
            rail.geometry?.materials = [WorldMat.whitePaintMetal]
            rail.position = at(railY)
            container.addChildNode(rail)
        }
        for i in 0..<10 {
            let a = Double(i) / 10 * 2 * .pi
            let post = SCNNode(geometry: SCNCylinder(radius: 0.028, height: 0.8))
            post.geometry?.materials = [WorldMat.whitePaintMetal]
            post.position = SCNVector3(Float(eye.x + cos(a) * 3.35),
                                       Float(floorY + 0.4),
                                       Float(eye.z + sin(a) * 3.35))
            container.addChildNode(post)
        }

        // Sill fascia ring just outside the interior glass — from inside it is
        // the panel under the windows; from outside, the cab's lower band.
        // Tube, not cylinder: nothing may fill the cab interior volume.
        let sill = SCNNode(geometry: SCNTube(innerRadius: 2.52, outerRadius: 2.62,
                                             height: CGFloat(sillTopY - floorY)))
        sill.geometry?.materials = [WorldMat.stucco]
        sill.position = at((sillTopY + floorY) / 2)
        container.addChildNode(sill)

        // Roof fascia above the interior ceiling (silhouette from outside).
        let roofFascia = SCNNode(geometry: SCNTube(innerRadius: 2.45, outerRadius: 3.0, height: 0.3))
        roofFascia.geometry?.materials = [WorldMat.whitePaintMetal]
        roofFascia.position = at(roofY)
        container.addChildNode(roofFascia)
        let roofCap = SCNNode(geometry: SCNCylinder(radius: 2.98, height: 0.08))
        roofCap.geometry?.materials = [WorldMat.whitePaintMetal]
        roofCap.position = at(roofY + 0.19)
        container.addChildNode(roofCap)

        // Amber obstruction beacon (dusk).
        let beaconMat = SCNMaterial()
        beaconMat.lightingModel = .constant
        beaconMat.diffuse.contents = worldColor(0.3, 0.1, 0.05)
        bank.register(material: beaconMat, color: worldColor(1.0, 0.35, 0.12), onHour: windowsOnHour, night: 4.0)
        let beacon = SCNNode(geometry: SCNSphere(radius: 0.14))
        beacon.geometry?.materials = [beaconMat]
        beacon.position = at(roofY + 0.37)
        container.addChildNode(beacon)

        let flat = container.flattenedClone()
        flat.name = "towerExterior"
        return flat
    }

    // MARK: - Apron flood (one real spot, on at dusk)

    private static func apronFloodNode(airport: AirportLayout, frame: FieldFrame,
                                       bank: AirfieldLightBank) -> SCNNode {
        let container = SCNNode()
        container.name = "apronFlood"
        let poleBase = frame.point(s: WorldAirportBuilder.apronS0 + 8,
                                   p: WorldAirportBuilder.apronP0 + WorldAirportBuilder.apronPLen - 6)
        let groundY = airport.groundHeight(at: poleBase)
        let pole = SCNNode(geometry: SCNCylinder(radius: 0.09, height: 9))
        pole.geometry?.materials = [WorldMat.whitePaintMetal]
        pole.position = worldV3(poleBase, groundY + 4.5)
        container.addChildNode(pole)
        let headMat = SCNMaterial()
        headMat.lightingModel = .constant
        headMat.diffuse.contents = worldColor(0.2, 0.18, 0.14)
        bank.register(material: headMat, color: worldColor(1.0, 0.83, 0.55),
                      onHour: apronFloodOnHour, ramp: 0.008, night: 4.0)
        let head = SCNNode(geometry: SCNBox(width: 0.9, height: 0.35, length: 0.5, chamferRadius: 0.06))
        head.geometry?.materials = [headMat]
        head.position = worldV3(poleBase, groundY + 8.9)
        container.addChildNode(head)

        let spot = SCNLight()
        spot.type = .spot
        spot.color = worldColor(1.0, 0.80, 0.52)
        spot.spotInnerAngle = 40
        spot.spotOuterAngle = 95
        spot.attenuationStartDistance = 10
        spot.attenuationEndDistance = 80
        spot.castsShadow = false
        bank.register(light: spot, onHour: apronFloodOnHour, ramp: 0.008, night: 900)
        let lightNode = SCNNode()
        lightNode.light = spot
        lightNode.position = worldV3(poleBase, groundY + 8.8)
        let apronCenter = frame.point(s: WorldAirportBuilder.apronS0 + WorldAirportBuilder.apronSLen / 2,
                                      p: WorldAirportBuilder.apronP0 + WorldAirportBuilder.apronPLen / 2)
        lightNode.look(at: worldV3(apronCenter, airport.groundHeight(at: apronCenter)))
        container.addChildNode(lightNode)
        return container
    }

    // MARK: - Scrub + boulders

    private static func scrubNode(airport: AirportLayout, frame: FieldFrame) -> SCNNode {
        let outline = airport.mesaOutline
        var centroid = V2(0, 0)
        for p in outline { centroid += p }
        centroid /= Double(outline.count)
        // Shrunken outline keeps bushes off the crumbling rim.
        let inner = outline.map { centroid + ($0 - centroid) * 0.93 }

        func insidePolygon(_ p: V2) -> Bool {
            var inside = false
            var j = inner.count - 1
            for i in 0..<inner.count {
                let a = inner[i], b = inner[j]
                if (a.y > p.y) != (b.y > p.y),
                   p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }
        func isClear(_ st: V2) -> Bool {
            let s = st.x, p = st.y
            if s > -45 && s < airport.runway.length + 45 && abs(p) < 24 { return false }   // runway strip
            if s > -30 && s < airport.runway.length + 20 && p > 38 && p < 72 { return false } // Alpha
            for stub in [10.0, 560.0, 940.0] where s > stub - 14 && s < stub + 14 && p > -6 && p < 72 { return false }
            if s > WorldAirportBuilder.apronS0 - 12 && s < WorldAirportBuilder.apronS0 + WorldAirportBuilder.apronSLen + 40
                && p > WorldAirportBuilder.apronP0 - 12 && p < 235 { return false }         // apron + buildings
            if abs(s - 315) < 9 && abs(p - 40) < 9 { return false }                          // windsock
            if s > 560 && s < 980 && p > 95 && p < 225 { return false }                      // road corridor
            if abs(s - 150) < 12 && p < -18 && p > -36 { return false }                      // PAPI
            return true
        }

        let container = SCNNode()
        var rng = WorldRand(seed: 0x5C2B)
        let mats = [WorldMat.scrub1, WorldMat.scrub2, WorldMat.scrub3]
        var placed = 0
        var attempts = 0
        // Bounding box of the outline for rejection sampling.
        var minX = Double.greatestFiniteMagnitude, maxX = -Double.greatestFiniteMagnitude
        var minZ = Double.greatestFiniteMagnitude, maxZ = -Double.greatestFiniteMagnitude
        for p in outline {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minZ = min(minZ, p.y); maxZ = max(maxZ, p.y)
        }
        while placed < 170 && attempts < 4000 {
            attempts += 1
            let p = V2(rng.range(minX, maxX), rng.range(minZ, maxZ))
            guard insidePolygon(p), isClear(frame.station(p)) else { continue }
            let size = rng.range(0.8, 2.4)
            let sphere = SCNSphere(radius: 1)
            sphere.segmentCount = 7
            sphere.materials = [mats[rng.int(mats.count)]]
            let bush = SCNNode(geometry: sphere)
            let y = airport.groundHeight(at: p)
            bush.position = worldV3(p, y + size * 0.32)
            bush.scale = SCNVector3(Float(size), Float(size * rng.range(0.42, 0.6)), Float(size * rng.range(0.8, 1.1)))
            bush.eulerAngles.y = Float(rng.range(0, .pi * 2))
            container.addChildNode(bush)
            placed += 1
        }
        // A few boulders near the rim.
        for i in 0..<12 {
            let idx = (i * 5 + 3) % outline.count
            let p = centroid + (outline[idx] - centroid) * rng.range(0.82, 0.90)
            guard isClear(frame.station(p)) else { continue }
            let size = rng.range(0.7, 1.8)
            let rock = SCNNode(geometry: SCNBox(width: CGFloat(size * 1.4), height: CGFloat(size),
                                                length: CGFloat(size * 1.1), chamferRadius: CGFloat(size * 0.3)))
            rock.geometry?.materials = [WorldMat.boulder]
            rock.position = worldV3(p, airport.groundHeight(at: p) + size * 0.28)
            rock.eulerAngles = SCNVector3(Float(rng.range(-0.3, 0.3)), Float(rng.range(0, 6.2)), Float(rng.range(-0.3, 0.3)))
            container.addChildNode(rock)
        }
        let flat = container.flattenedClone()
        flat.name = "scrub"
        return flat
    }
}
