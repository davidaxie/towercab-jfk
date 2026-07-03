import Foundation
import SceneKit
import UIKit
import simd

// =============================================================================
// Airfield details — MIRL edge lights (the dusk switch-on beat), REIL strobes
// at the 22 threshold, the PVASI left of the runway 4 approach (A6), windsock
// with segmented circle (D23), runway-remaining + hold signs (A10), the one
// hangar + Spanish Colonial terminal (A9), the fictional tower shaft, scrub
// clusters (D15), boulders, and the two Catalina bison (A12). Emissive
// materials register with AirfieldLightBank; the sky director drives their
// dusk ramp from sim time.
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

    /// `onHour < 0` means always on at `dayIntensity` (PVASI), still brightening at dusk.
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
        root.addChildNode(pvasiNode(airport: airport, frame: frame, bank: bank))
        root.addChildNode(reilNode(airport: airport, frame: frame, bank: bank))
        for group in edgeLightNodes(airport: airport, frame: frame, bank: bank) {
            root.addChildNode(group)
        }
        root.addChildNode(signsNode(airport: airport, frame: frame))
        root.addChildNode(windsockNode(airport: airport, bank: bank))
        root.addChildNode(buildingsNode(airport: airport, frame: frame, bank: bank))
        root.addChildNode(groundClutterNode(airport: airport, frame: frame))
        root.addChildNode(towerNode(airport: airport, bank: bank))
        root.addChildNode(apronFloodNode(airport: airport, frame: frame, bank: bank))
        root.addChildNode(bisonNode(airport: airport, frame: frame))
        root.addChildNode(scrubNode(airport: airport, frame: frame))
    }

    // MARK: - Shared lamp bits

    /// Crossed additive glow quads — invisible while emission is 0 (additive
    /// black), they carry the oversized-at-dusk read (D21).
    private static func haloCross(size: CGFloat, material: SCNMaterial) -> SCNNode {
        let node = SCNNode()
        for yaw in [Float(0), .pi / 2] {
            let plane = SCNPlane(width: size, height: size)
            plane.materials = [material]
            let q = SCNNode(geometry: plane)
            q.eulerAngles.y = yaw
            node.addChildNode(q)
        }
        return node
    }

    private static func haloMaterial(color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.black
        m.emission.contents = color
        m.emission.intensity = 0
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        return m
    }

    // MARK: - PVASI (A6 — single pulsating unit LEFT of the runway 4 approach,
    // i.e. the NW side near the SW end; replaces the fictional 22-side PAPI)

    private static func pvasiNode(airport: AirportLayout, frame: FieldFrame,
                                  bank: AirfieldLightBank) -> SCNNode {
        let container = SCNNode()
        container.name = "pvasi"
        let st = frame.point(s: 790, p: -(airport.runway.width / 2 + 15))
        let y = airport.groundHeight(at: st)
        let housing = WorldMat.pbr(worldColor(0.16, 0.18, 0.16), roughness: 0.6, metalness: 0.3)

        let box = SCNNode(geometry: SCNBox(width: 1.1, height: 0.7, length: 0.6, chamferRadius: 0.05))
        box.geometry?.materials = [housing]
        box.position = worldV3(st, y + 0.65)
        box.eulerAngles.y = worldYawFacing(frame.dir)     // faces the 4 approach (SW)
        container.addChildNode(box)
        let leg = SCNNode(geometry: SCNCylinder(radius: 0.06, height: 0.4))
        leg.geometry?.materials = [housing]
        leg.position = worldV3(st, y + 0.2)
        container.addChildNode(leg)

        // On-glide white, always lit, boosted at dusk; the 2 s pulse rides on
        // node opacity so the bank keeps owning emission intensity.
        let lens = SCNMaterial()
        lens.lightingModel = .constant
        lens.diffuse.contents = UIColor.black
        bank.register(material: lens, color: worldColor(1.0, 0.97, 0.90), onHour: -1, day: 2.6, night: 5.5)
        let lensNode = SCNNode(geometry: SCNPlane(width: 0.7, height: 0.32))
        lensNode.geometry?.materials = [lens]
        lensNode.position = SCNVector3(0, 0.06, 0.31)
        box.addChildNode(lensNode)

        let halo = haloMaterial(color: worldColor(1.0, 0.95, 0.85))
        bank.register(material: halo, color: worldColor(1.0, 0.95, 0.85), onHour: -1, day: 0.8, night: 3.0)
        let glow = haloCross(size: 2.2, material: halo)
        glow.position = worldV3(st, y + 0.7)
        container.addChildNode(glow)

        let pulse = SCNAction.repeatForever(.sequence([
            .fadeOpacity(to: 0.35, duration: 1.0),
            .fadeOpacity(to: 1.0, duration: 1.0),
        ]))
        pulse.timingMode = .easeInEaseOut
        glow.runAction(pulse)
        lensNode.runAction(pulse.copy() as! SCNAction)
        return container
    }

    // MARK: - REIL (A6 — synchronized white strobes flanking the 22 threshold)

    private static func reilNode(airport: AirportLayout, frame: FieldFrame,
                                 bank: AirfieldLightBank) -> SCNNode {
        let container = SCNNode()
        container.name = "reil"
        let housing = WorldMat.pbr(worldColor(0.18, 0.19, 0.18), roughness: 0.55, metalness: 0.3)
        // 2 s cycle, double flash, both units on the same clock (synchronized).
        let flash = SCNAction.repeatForever(.sequence([
            .fadeOpacity(to: 1.0, duration: 0.04),
            .fadeOpacity(to: 0.0, duration: 0.10),
            .wait(duration: 0.10),
            .fadeOpacity(to: 1.0, duration: 0.04),
            .fadeOpacity(to: 0.0, duration: 0.10),
            .wait(duration: 1.62),
        ]))
        for side in [-1.0, 1.0] {
            let st = frame.point(s: 2, p: side * (airport.runway.width / 2 + 12))
            let y = airport.groundHeight(at: st)
            let box = SCNNode(geometry: SCNBox(width: 0.4, height: 0.35, length: 0.3, chamferRadius: 0.04))
            box.geometry?.materials = [housing]
            box.position = worldV3(st, y + 0.45)
            box.eulerAngles.y = worldYawFacing(-frame.dir)   // faces the 22 approach (NE)
            container.addChildNode(box)
            let post = SCNNode(geometry: SCNCylinder(radius: 0.05, height: 0.35))
            post.geometry?.materials = [housing]
            post.position = worldV3(st, y + 0.17)
            container.addChildNode(post)

            let strobe = SCNMaterial()
            strobe.lightingModel = .constant
            strobe.diffuse.contents = UIColor.black
            strobe.emission.contents = worldColor(1.0, 1.0, 0.98)
            strobe.emission.intensity = 6.0
            strobe.blendMode = .add
            strobe.writesToDepthBuffer = false
            strobe.isDoubleSided = true
            let glow = haloCross(size: 2.6, material: strobe)
            glow.position = worldV3(st, y + 0.55)
            glow.opacity = 0
            glow.runAction(flash.copy() as! SCNAction)
            container.addChildNode(glow)
        }
        return container
    }

    // MARK: - MIRL edge + threshold lights (staggered dusk switch-on)

    private static func edgeLightNodes(airport: AirportLayout, frame: FieldFrame,
                                       bank: AirfieldLightBank) -> [SCNNode] {
        let groupCount = 6
        var groups: [SCNNode] = []
        let stakeMat = WorldMat.pbr(worldColor(0.5, 0.48, 0.44), roughness: 0.7, metalness: 0.3)
        let length = airport.runway.length
        let lateral = airport.runway.width / 2 + 2.5

        func lamp(at st: V2, lens: SCNMaterial, halo: SCNMaterial, parent: SCNNode) {
            let world = frame.point(s: st.x, p: st.y)
            let y = airport.groundHeight(at: world)
            let post = SCNNode(geometry: SCNCylinder(radius: 0.05, height: 0.30))
            post.geometry?.materials = [stakeMat]
            post.position = worldV3(world, y + 0.15)
            parent.addChildNode(post)
            // D21: true-scale warm-glass lens by day; the additive halo cross
            // carries the oversized read once the bank ramps it at dusk.
            let head = SCNNode(geometry: SCNSphere(radius: 0.22))
            head.geometry?.materials = [lens]
            head.position = worldV3(world, y + 0.42)
            parent.addChildNode(head)
            let glow = haloCross(size: 1.7, material: halo)
            glow.position = worldV3(world, y + 0.45)
            parent.addChildNode(glow)
        }

        // Edge lights: warm white, in 6 groups marching from the 22 end.
        for g in 0..<groupCount {
            let container = SCNNode()
            let onHour = edgeLightsOnHour + Double(g) * edgeLightGroupStagger
            let lens = WorldMat.pbr(worldColor(0.55, 0.50, 0.42), roughness: 0.3)
            bank.register(material: lens, color: worldColor(1.0, 0.85, 0.58), onHour: onHour, night: 7.0)
            let halo = haloMaterial(color: worldColor(1.0, 0.85, 0.58))
            bank.register(material: halo, color: worldColor(1.0, 0.85, 0.58), onHour: onHour, night: 3.4)
            let s0 = length * Double(g) / Double(groupCount)
            let s1 = length * Double(g + 1) / Double(groupCount)
            var s = s0 + 14
            while s < s1 {
                lamp(at: V2(s, lateral), lens: lens, halo: halo, parent: container)
                lamp(at: V2(s, -lateral), lens: lens, halo: halo, parent: container)
                s += 55
            }
            let flat = container.flattenedClone()
            flat.name = "edgeLights\(g)"
            groups.append(flat)
        }
        // Threshold bar at the 22 end: green, switches with group 0.
        let thresholdContainer = SCNNode()
        let greenLens = WorldMat.pbr(worldColor(0.30, 0.42, 0.32), roughness: 0.3)
        bank.register(material: greenLens, color: worldColor(0.15, 1.0, 0.35),
                      onHour: edgeLightsOnHour, night: 4.5)
        let greenHalo = haloMaterial(color: worldColor(0.2, 1.0, 0.4))
        bank.register(material: greenHalo, color: worldColor(0.2, 1.0, 0.4),
                      onHour: edgeLightsOnHour, night: 2.4)
        for k in 0..<6 {
            let p = -lateral + Double(k) / 5.0 * lateral * 2
            lamp(at: V2(-4, p), lens: greenLens, halo: greenHalo, parent: thresholdContainer)
        }
        let flat = thresholdContainer.flattenedClone()
        flat.name = "thresholdLights"
        groups.append(flat)
        return groups
    }

    // MARK: - Signs (A10 — runway-remaining boards NW side; D-F21 hold sign)

    private static func signsNode(airport: AirportLayout, frame: FieldFrame) -> SCNNode {
        let container = SCNNode()
        container.name = "signs"
        let postMat = WorldMat.pbr(worldColor(0.45, 0.44, 0.42), roughness: 0.6, metalness: 0.4)

        func board(texture: UIImage, w: CGFloat, h: CGFloat, at st: V2,
                   topY: Double, facing: V2) {
            let world = frame.point(s: st.x, p: st.y)
            let ground = airport.groundHeight(at: world)
            let post = SCNNode(geometry: SCNCylinder(radius: 0.05, height: CGFloat(topY)))
            post.geometry?.materials = [postMat]
            post.position = worldV3(world, ground + topY / 2)
            container.addChildNode(post)
            let mat = WorldMat.pbr(texture, roughness: 0.5)
            mat.emission.contents = texture         // legible against dusk sky
            mat.emission.intensity = 0.25
            let plane = SCNPlane(width: w, height: h)
            plane.materials = [mat]
            let sign = SCNNode(geometry: plane)
            sign.position = worldV3(world, ground + topY - Double(h) / 2)
            sign.eulerAngles.y = worldYawFacing(facing)
            container.addChildNode(sign)
        }

        // Distance remaining for landing 22 (rolls B → A): "2" at 2,000 ft
        // remaining, "1" at 1,000 ft — both on the NW side.
        let sideP = -(airport.runway.width / 2 + 11)
        board(texture: WorldTex.remainingSign("2"), w: 1.3, h: 1.3,
              at: V2(airport.runway.length - 609.6, sideP), topY: 2.2, facing: -frame.dir)
        board(texture: WorldTex.remainingSign("1"), w: 1.3, h: 1.3,
              at: V2(airport.runway.length - 304.8, sideP), topY: 2.2, facing: -frame.dir)
        // Red/white runway hold sign beside the hold-short bar.
        let holdSt = frame.station(airport.holdShortPoint)
        board(texture: WorldTex.holdSign(), w: 1.3, h: 0.5,
              at: V2(holdSt.x + 7, holdSt.y + 1.5), topY: 1.3, facing: frame.perp)

        let flat = container.flattenedClone()
        flat.name = "signs"
        return flat
    }

    // MARK: - Windsock (D23 — SE by the ramp, segmented circle, plump & lit)

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

        // Segmented circle — white marker boards ringing the sock (D23).
        let segMat = WorldMat.pbr(worldColor(0.92, 0.91, 0.87), roughness: 0.6)
        for i in 0..<10 {
            let a = Double(i) / 10 * 2 * .pi
            let seg = SCNNode(geometry: SCNBox(width: 2.6, height: 0.16, length: 0.7, chamferRadius: 0.03))
            seg.geometry?.materials = [segMat]
            seg.position = SCNVector3(Float(cos(a) * 9.0), 0.1, Float(sin(a) * 9.0))
            seg.eulerAngles.y = Float(-a + .pi / 2)
            base.addChildNode(seg)
        }

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
        sockMat.emission.contents = UIColor(red: 0.55, green: 0.22, blue: 0.05, alpha: 1)
        let cone = SCNCone(topRadius: 0.16, bottomRadius: 0.50, height: 3.0)   // D23 plump
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

    // MARK: - Buildings (A9 — ONE hangar + two-story Spanish Colonial terminal)

    private static func buildingsNode(airport: AirportLayout, frame: FieldFrame,
                                      bank: AirfieldLightBank) -> SCNNode {
        let container = SCNNode()

        // Shared warm window glow (dusk).
        let windowMat = SCNMaterial()
        windowMat.lightingModel = .constant
        windowMat.diffuse.contents = worldColor(0.12, 0.09, 0.06)
        bank.register(material: windowMat, color: worldColor(1.0, 0.72, 0.38),
                      onHour: windowsOnHour, ramp: 0.006, night: 3.2)

        // D22/F28: the dirt pad rotates with the building and wraps its
        // footprint + 4 m; buildings sink slightly into it.
        func place(_ node: SCNNode, s: Double, p: Double, facing: V2,
                   padW: CGFloat, padD: CGFloat, sink: Double = 0.22) {
            let world = frame.point(s: s, p: p)
            let y = airport.groundHeight(at: world)
            let wrapper = SCNNode()
            wrapper.position = worldV3(world, y)
            wrapper.eulerAngles.y = worldYawFacing(facing)
            node.position.y -= Float(sink)
            wrapper.addChildNode(node)
            let pad = SCNNode(geometry: SCNPlane(width: padW + 4, height: padD + 4))
            pad.geometry?.materials = [WorldMat.dirtPad]
            pad.eulerAngles.x = -.pi / 2
            pad.position = SCNVector3(0, 0.04, 0)
            wrapper.addChildNode(pad)
            container.addChildNode(wrapper)
        }

        // --- The hangar (relocated-Hamilton-Cove style): gable, cream
        // corrugated, big open door facing the ramp; NE of the terminal along
        // the ramp's back edge, ≥12 m clear of every taxi route (A9).
        let hangar = gabledHangar(width: 20, depth: 14, wallH: 5.0, ridgeH: 7.6,
                                  wall: WorldMat.corrugatedCream, roof: WorldMat.corrugatedSage,
                                  front: WorldMat.pbr(WorldTex.hangarFront(baseR: 0.83, baseG: 0.77, baseB: 0.66,
                                                                           openDoor: true, seed: 0x91),
                                                      roughness: 0.55, metalness: 0.2))
        place(hangar, s: 470, p: 170, facing: -frame.perp, padW: 20, padD: 14)

        // --- Terminal: two-story Spanish Colonial (A9) — whitewashed stucco
        // masses, red clay tile, arcade facing the ramp, squat tower one floor
        // higher with a pyramidal cap, blue-and-gold tile accents.
        let terminal = SCNNode()
        let bodyW: CGFloat = 18, bodyD: CGFloat = 10, bodyH: CGFloat = 7.2
        let body = SCNNode(geometry: SCNBox(width: bodyW, height: bodyH, length: bodyD, chamferRadius: 0))
        let frontMat = WorldMat.pbr(WorldTex.terminalFront(), roughness: 0.9)
        // SCNBox materials: +Z, +X, -Z, -X, +Y, -Y. Front (+Z) faces the ramp.
        body.geometry?.materials = [frontMat, WorldMat.stucco, WorldMat.stucco,
                                    WorldMat.stucco, WorldMat.stucco, WorldMat.stucco]
        body.position = SCNVector3(0, Float(bodyH / 2), 0)
        terminal.addChildNode(body)
        // Hip roof over the main block.
        let roof = SCNNode(geometry: SCNPyramid(width: bodyW + 2.0, height: 2.4, length: bodyD + 2.0))
        roof.geometry?.materials = [WorldMat.roofTile]
        roof.position = SCNVector3(0, Float(bodyH), 0)
        terminal.addChildNode(roof)
        // Arcade colonnade along the ramp face: tile pent roof on 5 piers.
        let porch = SCNNode(geometry: SCNBox(width: bodyW - 2, height: 0.28, length: 3.2, chamferRadius: 0))
        porch.geometry?.materials = [WorldMat.roofTile]
        porch.position = SCNVector3(0, 3.6, Float(bodyD / 2) + 1.7)
        terminal.addChildNode(porch)
        for i in 0..<5 {
            let pier = SCNNode(geometry: SCNBox(width: 0.42, height: 3.6, length: 0.42, chamferRadius: 0.03))
            pier.geometry?.materials = [WorldMat.stucco]
            let x = Float(-(bodyW - 3.4) / 2) + Float(i) * Float((bodyW - 3.4) / 4)
            pier.position = SCNVector3(x, 1.8, Float(bodyD / 2) + 3.0)
            terminal.addChildNode(pier)
        }
        // Squat tower — one floor higher, pyramidal red-tile cap.
        let towerW: CGFloat = 5.2, towerH: CGFloat = 10.2
        let squat = SCNNode(geometry: SCNBox(width: towerW, height: towerH, length: towerW, chamferRadius: 0))
        squat.geometry?.materials = [WorldMat.stucco]
        squat.position = SCNVector3(Float(bodyW / 2 - towerW / 2 + 0.6), Float(towerH / 2), 0)
        terminal.addChildNode(squat)
        let cap = SCNNode(geometry: SCNPyramid(width: towerW + 1.2, height: 2.6, length: towerW + 1.2))
        cap.geometry?.materials = [WorldMat.roofTile]
        cap.position = SCNVector3(Float(bodyW / 2 - towerW / 2 + 0.6), Float(towerH), 0)
        terminal.addChildNode(cap)
        // Blue-and-gold tile band around the squat tower (A9 accents).
        let bandMat = WorldMat.pbr(WorldTex.tileBand(), roughness: 0.6, wrap: true)
        let band = SCNNode(geometry: SCNBox(width: towerW + 0.12, height: 0.5, length: towerW + 0.12,
                                            chamferRadius: 0))
        band.geometry?.materials = [bandMat]
        band.position = SCNVector3(Float(bodyW / 2 - towerW / 2 + 0.6), Float(towerH) - 1.5, 0)
        terminal.addChildNode(band)
        // Warm windows: upper floor over the arcade + one lit tower window.
        for dx in [-6.3, -3.6, -0.9, 1.8] {
            let w = SCNNode(geometry: SCNPlane(width: 1.2, height: 1.9))
            w.geometry?.materials = [windowMat]
            w.position = SCNVector3(Float(dx), 5.3, Float(bodyD / 2) + 0.06)
            terminal.addChildNode(w)
        }
        let tw = SCNNode(geometry: SCNPlane(width: 1.0, height: 1.4))
        tw.geometry?.materials = [windowMat]
        tw.position = SCNVector3(Float(bodyW / 2 - towerW / 2 + 0.6), 7.6, Float(towerW / 2) + 0.06)
        terminal.addChildNode(tw)
        // Ground-floor arcade glow, seen through the arches at dusk.
        for dx in [-3.4, 0.0, 3.4] {
            let w = SCNNode(geometry: SCNPlane(width: 1.6, height: 1.7))
            w.geometry?.materials = [windowMat]
            w.position = SCNVector3(Float(dx), 1.3, Float(bodyD / 2) + 0.06)
            terminal.addChildNode(w)
        }
        place(terminal, s: 600, p: 163, facing: -frame.perp, padW: 26, padD: 18)

        // --- Support cluster (A9): a handful of secondary structures so the
        // ramp reads as a lived-in little airport village, not two boxes. All
        // kept at p >= 178 (well clear of the ramp/taxi routes) along the back
        // edge of the field on the tower/SE side.

        // Two small maintenance/utility sheds NE of the hangar (reuse the gable
        // builder at shed scale, alternating cream/sage skins).
        let shedA = gabledHangar(width: 7.5, depth: 6, wallH: 3.0, ridgeH: 4.4,
                                 wall: WorldMat.corrugatedSage, roof: WorldMat.corrugatedCream,
                                 front: WorldMat.pbr(WorldTex.hangarFront(baseR: 0.62, baseG: 0.63, baseB: 0.53,
                                                                          openDoor: false, seed: 0x51),
                                                     roughness: 0.58, metalness: 0.2))
        place(shedA, s: 432, p: 186, facing: -frame.perp, padW: 7.5, padD: 6)
        let shedB = gabledHangar(width: 9, depth: 6.5, wallH: 3.2, ridgeH: 4.8,
                                 wall: WorldMat.corrugatedCream, roof: WorldMat.corrugatedSage,
                                 front: WorldMat.pbr(WorldTex.hangarFront(baseR: 0.83, baseG: 0.77, baseB: 0.66,
                                                                          openDoor: true, seed: 0x52),
                                                     roughness: 0.55, metalness: 0.2))
        place(shedB, s: 505, p: 192, facing: -frame.perp, padW: 9, padD: 6.5)

        // A low whitewashed ops / pilot-lounge box beside the terminal, one
        // story with a shallow hip roof — matches the Spanish-Colonial palette.
        let ops = SCNNode()
        let opsW: CGFloat = 8, opsD: CGFloat = 6, opsH: CGFloat = 3.4
        let opsBody = SCNNode(geometry: SCNBox(width: opsW, height: opsH, length: opsD, chamferRadius: 0))
        opsBody.geometry?.materials = [WorldMat.stucco]
        opsBody.position = SCNVector3(0, Float(opsH / 2), 0)
        ops.addChildNode(opsBody)
        let opsRoof = SCNNode(geometry: SCNPyramid(width: opsW + 1.2, height: 1.4, length: opsD + 1.2))
        opsRoof.geometry?.materials = [WorldMat.roofTile]
        opsRoof.position = SCNVector3(0, Float(opsH), 0)
        ops.addChildNode(opsRoof)
        // A couple of warm dusk windows on the ramp face (+Z after facing).
        for dx in [-2.2, 0.6] {
            let w = SCNNode(geometry: SCNPlane(width: 1.1, height: 1.4))
            w.geometry?.materials = [windowMat]
            w.position = SCNVector3(Float(dx), 1.9, Float(opsD / 2) + 0.05)
            ops.addChildNode(w)
        }
        place(ops, s: 574, p: 186, facing: -frame.perp, padW: 8, padD: 6)

        // Fuel farm: two light-tan tanks on a shared pad NE of the sheds.
        let tankMat = WorldMat.pbr(worldColor(0.80, 0.76, 0.66), roughness: 0.45, metalness: 0.55)
        let fuelFarm = SCNNode()
        for dx in [-2.0, 2.0] {
            let tank = SCNNode(geometry: SCNCylinder(radius: 1.6, height: 3.2))
            tank.geometry?.materials = [tankMat]
            tank.position = SCNVector3(Float(dx), 1.6, 0)
            fuelFarm.addChildNode(tank)
            // Domed cap.
            let cap = SCNNode(geometry: SCNSphere(radius: 1.6))
            cap.geometry?.materials = [tankMat]
            cap.scale = SCNVector3(1, 0.35, 1)
            cap.position = SCNVector3(Float(dx), 3.2, 0)
            fuelFarm.addChildNode(cap)
        }
        place(fuelFarm, s: 470, p: 198, facing: -frame.perp, padW: 9, padD: 5)

        // A small covered picnic ramada near the terminal front (4 posts + a
        // flat tile roof) — the kind of shaded overlook Catalina's café has.
        let ramada = SCNNode()
        let ramW: CGFloat = 4.2, ramD: CGFloat = 3.2, postH: Float = 2.5
        let ramPostMat = WorldMat.pbr(worldColor(0.42, 0.32, 0.22), roughness: 0.9)
        for (sx, sz) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
            let post = SCNNode(geometry: SCNCylinder(radius: 0.09, height: CGFloat(postH)))
            post.geometry?.materials = [ramPostMat]
            post.position = SCNVector3(Float(Double(ramW / 2) * sx), postH / 2, Float(Double(ramD / 2) * sz))
            ramada.addChildNode(post)
        }
        let ramRoof = SCNNode(geometry: SCNBox(width: ramW + 0.6, height: 0.22, length: ramD + 0.6, chamferRadius: 0.05))
        ramRoof.geometry?.materials = [WorldMat.roofTile]
        ramRoof.position = SCNVector3(0, postH + 0.11, 0)
        ramada.addChildNode(ramRoof)
        place(ramada, s: 616, p: 180, facing: -frame.perp, padW: 5, padD: 4, sink: 0.05)

        let flat = container.flattenedClone()
        flat.name = "buildings"
        return flat
    }

    private static func gabledHangar(width: CGFloat, depth: CGFloat, wallH: CGFloat, ridgeH: CGFloat,
                                     wall: SCNMaterial, roof: SCNMaterial, front: SCNMaterial) -> SCNNode {
        let node = SCNNode()
        let w = Float(width), d = Float(depth), h = Float(wallH), r = Float(ridgeH)

        var walls = WorldMesh()
        // Side walls (±X), back wall (-Z rear; +Z front carries the doorway).
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
        // Back gable (-Z): wall + triangle to ridge.
        wallQuad(SIMD3(w/2, 0, -d/2), SIMD3(-w/2, 0, -d/2), SIMD3(-w/2, h, -d/2), SIMD3(w/2, h, -d/2),
                 normal: SIMD3(0, 0, -1), uScale: uBack)
        let bg0 = walls.add(SIMD3(-w/2, h, -d/2), SIMD3(0, 0, -1), SIMD2(0, 0))
        let bg1 = walls.add(SIMD3(w/2, h, -d/2), SIMD3(0, 0, -1), SIMD2(uBack, 0))
        let bg2 = walls.add(SIMD3(0, r, -d/2), SIMD3(0, 0, -1), SIMD2(uBack / 2, -0.6))
        let bp0 = walls.positions[Int(bg0)], bp1 = walls.positions[Int(bg1)], bp2 = walls.positions[Int(bg2)]
        if simd_dot(simd_cross(bp1 - bp0, bp2 - bp0), SIMD3(0, 0, -1)) >= 0 {
            walls.triangle(bg0, bg1, bg2)
        } else {
            walls.triangle(bg0, bg2, bg1)
        }
        let wallNode = SCNNode(geometry: walls.build(material: wall))
        node.addChildNode(wallNode)

        // Front gable (+Z): flat facade with the doorway texture, facing the ramp.
        var frontMesh = WorldMesh()
        let fn = SIMD3<Float>(0, 0, 1)
        let f0 = frontMesh.add(SIMD3(-w/2, 0, d/2), fn, SIMD2(0, 1))
        let f1 = frontMesh.add(SIMD3(w/2, 0, d/2), fn, SIMD2(1, 1))
        let f2 = frontMesh.add(SIMD3(w/2, h, d/2), fn, SIMD2(1, 0.25))
        let f3 = frontMesh.add(SIMD3(-w/2, h, d/2), fn, SIMD2(0, 0.25))
        let f4 = frontMesh.add(SIMD3(0, r, d/2), fn, SIMD2(0.5, 0))
        frontMesh.quad(f0, f1, f2, f3, desiredNormal: fn)
        let fp3 = frontMesh.positions[Int(f3)], fp2 = frontMesh.positions[Int(f2)], fp4 = frontMesh.positions[Int(f4)]
        if simd_dot(simd_cross(fp2 - fp3, fp4 - fp3), fn) >= 0 {
            frontMesh.triangle(f3, f2, f4)
        } else {
            frontMesh.triangle(f3, f4, f2)
        }
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

    // MARK: - Ground clutter (a small visitor parking lot with a few cars +
    // worn dirt footpaths threading the buildings and out to the rim overlooks
    // — implies a world beyond the mesa without touching AirportGeometry).

    private static func groundClutterNode(airport: AirportLayout, frame: FieldFrame) -> SCNNode {
        let container = SCNNode()
        container.name = "groundClutter"

        // Gravel parking pad beside the terminal (SE of it, p ~186), riding the
        // terrain like the building dirt pads.
        let lotS0 = 588.0, lotSLen = 15.0, lotP0 = 178.0, lotPLen = 11.0
        var padMesh = WorldMesh()
        let up = SIMD3<Float>(0, 1, 0)
        var grid: [[Int32]] = []
        let cols = 4, rows = 3
        for r in 0...rows {
            var rowIdx: [Int32] = []
            let p = lotP0 + lotPLen * Double(r) / Double(rows)
            for c in 0...cols {
                let s = lotS0 + lotSLen * Double(c) / Double(cols)
                let world = frame.point(s: s, p: p)
                let y = airport.groundHeight(at: world) + 0.05
                rowIdx.append(padMesh.add(worldF3(world, y), up,
                                          SIMD2(Float(Double(c) / Double(cols) * 3),
                                                Float(Double(r) / Double(rows) * 2))))
            }
            grid.append(rowIdx)
        }
        for r in 0..<rows {
            for c in 0..<cols {
                padMesh.quad(grid[r][c], grid[r][c + 1], grid[r + 1][c + 1], grid[r + 1][c], desiredNormal: up)
            }
        }
        let padMat = WorldMat.pbr(WorldTex.dirtPad(), roughness: 0.97, wrap: true)
        container.addChildNode(SCNNode(geometry: padMesh.build(material: padMat)))

        // A few parked cars — muted body colors, simple two-box silhouette.
        let carPaints: [SCNMaterial] = [
            WorldMat.pbr(worldColor(0.62, 0.20, 0.16), roughness: 0.4, metalness: 0.3),   // faded red
            WorldMat.pbr(worldColor(0.20, 0.30, 0.42), roughness: 0.4, metalness: 0.3),   // dusty blue
            WorldMat.pbr(worldColor(0.78, 0.76, 0.70), roughness: 0.45, metalness: 0.25), // cream white
            WorldMat.pbr(worldColor(0.28, 0.30, 0.28), roughness: 0.45, metalness: 0.3),  // dark grey
        ]
        let glassMat = WorldMat.pbr(worldColor(0.10, 0.13, 0.16), roughness: 0.2, metalness: 0.5)
        let tireMat = WorldMat.pbr(worldColor(0.08, 0.08, 0.09), roughness: 0.9)
        var crng = WorldRand(seed: 0xCA75)
        func car(s: Double, p: Double, yaw: Double, paint: SCNMaterial) {
            let world = frame.point(s: s, p: p)
            let y = airport.groundHeight(at: world)
            let c = SCNNode()
            c.position = worldV3(world, y)
            c.eulerAngles.y = Float(yaw)
            let bodyL = 4.2, bodyW = 1.75
            let lower = SCNNode(geometry: SCNBox(width: CGFloat(bodyW), height: 0.75, length: CGFloat(bodyL), chamferRadius: 0.28))
            lower.geometry?.materials = [paint]
            lower.position = SCNVector3(0, 0.72, 0)
            c.addChildNode(lower)
            let cabin = SCNNode(geometry: SCNBox(width: CGFloat(bodyW * 0.92), height: 0.62, length: CGFloat(bodyL * 0.5), chamferRadius: 0.22))
            cabin.geometry?.materials = [glassMat]
            cabin.position = SCNVector3(0, 1.28, Float(bodyL * -0.03))
            c.addChildNode(cabin)
            for (dx, dz) in [(-1.0, 1.0), (1.0, 1.0), (-1.0, -1.0), (1.0, -1.0)] {
                let wheel = SCNNode(geometry: SCNCylinder(radius: 0.32, height: 0.2))
                wheel.geometry?.materials = [tireMat]
                wheel.eulerAngles.z = .pi / 2
                wheel.position = SCNVector3(Float(dx * bodyW / 2), 0.32, Float(dz * bodyL * 0.34))
                c.addChildNode(wheel)
            }
            container.addChildNode(c)
        }
        // Three cars in the lot, slightly angled, one gap.
        let lotYaw = Double(worldYawFacing(frame.perp))
        car(s: 591, p: 182, yaw: lotYaw + crng.range(-0.1, 0.1), paint: carPaints[0])
        car(s: 595, p: 182, yaw: lotYaw + crng.range(-0.1, 0.1), paint: carPaints[2])
        car(s: 599, p: 182, yaw: lotYaw + crng.range(-0.1, 0.1), paint: carPaints[1])
        // A pickup parked by the hangar apron.
        car(s: 485, p: 182, yaw: lotYaw + 0.5, paint: carPaints[3])

        // Worn dirt footpaths (thin dirt ribbons riding the terrain). They fan
        // from the ramp/terminal toward the rim overlooks and link buildings.
        let paths: [[(Double, Double)]] = [
            [(600, 175), (615, 205), (632, 236), (648, 262)],   // terminal → SE overlook
            [(600, 175), (470, 178)],                            // terminal → hangar apron
            [(560, 175), (540, 210), (520, 250)],               // ramp → S rim
            [(470, 178), (432, 190)],                            // hangar → sheds
        ]
        for wp in paths {
            let pts = wp.map { frame.point(s: $0.0, p: $0.1) }
            let geo = worldRibbonGeometry(points: pts, width: 1.5, lift: 0.035,
                                          airport: airport, vPerMeter: 1.0 / 6.0,
                                          material: WorldMat.dirt, step: 10)
            container.addChildNode(SCNNode(geometry: geo))
        }

        let flat = container.flattenedClone()
        flat.name = "groundClutter"
        return flat
    }

    // MARK: - Tower (exterior shaft under the cab eye — derives from the layout)

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
        // the catwalk rails stay under the runway sightline.
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

        // Catwalk floor + low rails (kept below the runway sightline).
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

    // MARK: - Bison (A12 — the trademark pair, grazing NE of the ramp)

    private static func bisonNode(airport: AirportLayout, frame: FieldFrame) -> SCNNode {
        let container = SCNNode()
        container.name = "bison"
        let hide = WorldMat.pbr(worldColor(0.335, 0.245, 0.165), roughness: 0.95)
        let shag = WorldMat.pbr(worldColor(0.225, 0.160, 0.110), roughness: 1.0)

        func bison(at st: V2, yaw: Double) -> SCNNode {
            // Silhouette-read only: rounded masses, shaggy front, head low,
            // ~1.7 m at the hump.
            let b = SCNNode()
            let world = frame.point(s: st.x, p: st.y)
            b.position = worldV3(world, airport.groundHeight(at: world))
            b.eulerAngles.y = Float(yaw)

            let barrel = SCNNode(geometry: SCNBox(width: 1.0, height: 1.0, length: 1.9, chamferRadius: 0.42))
            barrel.geometry?.materials = [hide]
            barrel.position = SCNVector3(0, 0.95, -0.15)
            b.addChildNode(barrel)
            let hump = SCNNode(geometry: SCNSphere(radius: 0.62))
            hump.geometry?.materials = [shag]
            hump.position = SCNVector3(0, 1.12, 0.55)
            hump.scale = SCNVector3(0.95, 0.92, 1.0)
            b.addChildNode(hump)
            let chest = SCNNode(geometry: SCNSphere(radius: 0.52))
            chest.geometry?.materials = [shag]
            chest.position = SCNVector3(0, 0.72, 0.78)
            b.addChildNode(chest)
            let head = SCNNode(geometry: SCNBox(width: 0.42, height: 0.5, length: 0.62, chamferRadius: 0.16))
            head.geometry?.materials = [shag]
            head.position = SCNVector3(0, 0.52, 1.18)   // head low — grazing
            b.addChildNode(head)
            for (dx, dz) in [(-0.32, 0.55), (0.32, 0.55), (-0.32, -0.75), (0.32, -0.75)] {
                let leg = SCNNode(geometry: SCNCylinder(radius: 0.09, height: 0.62))
                leg.geometry?.materials = [hide]
                leg.position = SCNVector3(Float(dx), 0.31, Float(dz))
                b.addChildNode(leg)
            }
            return b
        }
        container.addChildNode(bison(at: V2(318, 132), yaw: 0.9))
        container.addChildNode(bison(at: V2(332, 147), yaw: 2.5))
        let flat = container.flattenedClone()
        flat.name = "bison"
        return flat
    }

    // MARK: - Scrub + boulders (D15 — archetypes, clusters, tints)

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
        // D19 road corridor (matches WorldAirportBuilder.serviceRoadNode).
        let roadPts: [(Double, Double)] = [(618, 128), (660, 168), (712, 224), (748, 268), (772, 296)]
        func nearRoad(_ st: V2) -> Bool {
            for i in 0..<(roadPts.count - 1) {
                let a = V2(roadPts[i].0, roadPts[i].1), b = V2(roadPts[i + 1].0, roadPts[i + 1].1)
                let ab = b - a
                let t = max(0, min(1, simd_dot(st - a, ab) / simd_dot(ab, ab)))
                if simd_length(st - (a + ab * t)) < 8 { return true }
            }
            return false
        }
        func isClear(_ st: V2) -> Bool {
            let s = st.x, p = st.y
            if s > -45 && s < airport.runway.length + 45 && abs(p) < 26 { return false }     // runway strip
            if s > -20 && s < airport.runway.length + 20 && p > 42 && p < 68 { return false } // Alpha
            for stub in [10.0, 550.0, 880.0] where s > stub - 14 && s < stub + 14 && p > -6 && p < 100 { return false }
            if s > 395 && s < 660 && p > 55 && p < 200 { return false }   // ramp + infield + buildings + cab
            if simd_length(st - V2(400, 84)) < 14 { return false }         // windsock + segmented circle
            if simd_length(st - V2(790, -26.5)) < 10 { return false }      // PVASI
            if abs(s - 2) < 8 && abs(p) > 15 && abs(p) < 32 { return false } // REIL pair
            if abs(s - airport.runway.length + 609.6) < 6 && abs(p + 22) < 6 { return false } // signs
            if abs(s - airport.runway.length + 304.8) < 6 && abs(p + 22) < 6 { return false }
            if s > 300 && s < 350 && p > 115 && p < 165 { return false }   // bison clearing
            if nearRoad(st) { return false }
            return true
        }

        let container = SCNNode()
        var rng = WorldRand(seed: 0x5C2B)
        let tints = WorldMat.scrubTints

        // Bounding box of the outline for rejection sampling.
        var minX = Double.greatestFiniteMagnitude, maxX = -Double.greatestFiniteMagnitude
        var minZ = Double.greatestFiniteMagnitude, maxZ = -Double.greatestFiniteMagnitude
        for p in outline {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minZ = min(minZ, p.y); maxZ = max(maxZ, p.y)
        }

        // D15 — three archetypes; every bush sinks 0.42·size into the ground.
        func addBush(at p: V2, size: Double) {
            let archetype = rng.int(3)
            let mat = tints[rng.int(tints.count)]
            let bush = SCNNode()
            switch archetype {
            case 0:      // low mounded lobe
                let sphere = SCNSphere(radius: 1)
                sphere.segmentCount = 7
                sphere.materials = [mat]
                let m = SCNNode(geometry: sphere)
                m.scale = SCNVector3(Float(size), Float(size * rng.range(0.42, 0.58)),
                                     Float(size * rng.range(0.8, 1.1)))
                bush.addChildNode(m)
            case 1:      // double lobe — big + small
                let s1 = SCNSphere(radius: 1); s1.segmentCount = 7; s1.materials = [mat]
                let m1 = SCNNode(geometry: s1)
                m1.scale = SCNVector3(Float(size * 0.9), Float(size * 0.5), Float(size * 0.85))
                bush.addChildNode(m1)
                let s2 = SCNSphere(radius: 1); s2.segmentCount = 6; s2.materials = [mat]
                let m2 = SCNNode(geometry: s2)
                m2.scale = SCNVector3(Float(size * 0.55), Float(size * 0.42), Float(size * 0.5))
                m2.position = SCNVector3(Float(size * 0.7), Float(size * 0.05), Float(size * 0.2))
                bush.addChildNode(m2)
            default:     // upright rounded cone (young toyon)
                let cone = SCNCone(topRadius: CGFloat(size * 0.18), bottomRadius: CGFloat(size * 0.62),
                                   height: CGFloat(size * 0.95))
                cone.radialSegmentCount = 7
                cone.materials = [mat]
                let m = SCNNode(geometry: cone)
                m.position.y = Float(size * 0.42)
                bush.addChildNode(m)
            }
            let y = airport.groundHeight(at: p)
            // Half-height ≈ 0.5·size; sinking 0.42·size roots every bush (D15).
            bush.position = worldV3(p, y + size * 0.08)
            bush.eulerAngles.y = Float(rng.range(0, .pi * 2))
            container.addChildNode(bush)
        }

        // Cluster sampling: 40 parents, 2–5 children within 8 m, cap ~220.
        var placed = 0
        var parents = 0
        var attempts = 0
        while parents < 40 && attempts < 6000 && placed < 220 {
            attempts += 1
            let p = V2(rng.range(minX, maxX), rng.range(minZ, maxZ))
            guard insidePolygon(p), isClear(frame.station(p)) else { continue }
            parents += 1
            addBush(at: p, size: rng.range(1.2, 2.6))
            placed += 1
            let children = 2 + rng.int(4)
            for _ in 0..<children where placed < 220 {
                let q = p + V2(rng.range(-8, 8), rng.range(-8, 8))
                guard insidePolygon(q), isClear(frame.station(q)) else { continue }
                addBush(at: q, size: rng.range(0.7, 1.7))
                placed += 1
            }
        }

        // --- Trees (the missing vertical vegetation): low-poly eucalyptus /
        // pine canopies whose long shadows rake the turf at golden hour. A
        // tapered trunk + 2-4 overlapping canopy lobes, warm-lit greens.
        let barkMat = WorldMat.pbr(worldColor(0.34, 0.27, 0.20), roughness: 0.95)
        // Tree-greens: slightly bluer/darker than the scrub so canopies read
        // as trees, plus a dusty eucalyptus sage.
        let treeTints: [SCNMaterial] = [
            WorldMat.pbr(worldColor(0.30, 0.36, 0.24), roughness: 0.95),   // deep olive
            WorldMat.pbr(worldColor(0.26, 0.33, 0.22), roughness: 0.95),   // pine green
            WorldMat.pbr(worldColor(0.40, 0.44, 0.34), roughness: 0.95),   // dusty eucalyptus
            WorldMat.pbr(worldColor(0.34, 0.40, 0.26), roughness: 0.95),   // mid sage-green
        ]
        func addTree(at p: V2, size: Double) {
            let tree = SCNNode()
            let trunkH = size
            let trunkR = size * 0.032 + 0.06
            let trunk = SCNNode(geometry: SCNCylinder(radius: CGFloat(trunkR), height: CGFloat(trunkH)))
            trunk.geometry?.materials = [barkMat]
            trunk.position = SCNVector3(0, Float(trunkH / 2), 0)
            tree.addChildNode(trunk)
            let canopyMat = treeTints[rng.int(treeTints.count)]
            let lobes = 2 + rng.int(3)
            let crownBase = trunkH * 0.62
            for _ in 0..<lobes {
                let lr = size * rng.range(0.28, 0.46)
                let sph = SCNSphere(radius: CGFloat(lr))
                sph.segmentCount = 6
                sph.materials = [canopyMat]
                let lobe = SCNNode(geometry: sph)
                lobe.position = SCNVector3(Float(size * rng.range(-0.22, 0.22)),
                                           Float(crownBase + size * rng.range(0.0, 0.5)),
                                           Float(size * rng.range(-0.22, 0.22)))
                lobe.scale = SCNVector3(1.0, Float(rng.range(0.85, 1.25)), 1.0)
                tree.addChildNode(lobe)
            }
            let y = airport.groundHeight(at: p)
            tree.position = worldV3(p, y - 0.15)     // roots just into the turf
            tree.eulerAngles.y = Float(rng.range(0, .pi * 2))
            container.addChildNode(tree)
        }

        // Scatter ~30 trees in 7 loose groves, biased toward the ESE half and
        // near the buildings/road; windrow a couple along the service road.
        var treesPlaced = 0
        var groves = 0
        var groveAttempts = 0
        while groves < 7 && groveAttempts < 3000 && treesPlaced < 34 {
            groveAttempts += 1
            // Bias grove centers toward the SE half (p > centroid-ish) & inland.
            let gp = V2(rng.range(minX, maxX), rng.range(minZ, maxZ))
            let gst = frame.station(gp)
            guard insidePolygon(gp), isClear(gst) else { continue }
            // Prefer the ESE/inland half — skip most grove seeds on the far NW
            // over-the-water side so trees frame the field, not the pattern.
            if gst.y < 40 && rng.unit() > 0.35 { continue }
            groves += 1
            addTree(at: gp, size: rng.range(4.5, 7.0)); treesPlaced += 1
            let kids = 2 + rng.int(4)
            for _ in 0..<kids where treesPlaced < 34 {
                let q = gp + V2(rng.range(-13, 13), rng.range(-13, 13))
                guard insidePolygon(q), isClear(frame.station(q)) else { continue }
                addTree(at: q, size: rng.range(3.5, 6.2)); treesPlaced += 1
            }
        }
        // Eucalyptus windrow lining the service road (D19 corridor waypoints).
        for i in 0..<(roadPts.count - 1) {
            let a = V2(roadPts[i].0, roadPts[i].1), b = V2(roadPts[i + 1].0, roadPts[i + 1].1)
            for t in stride(from: 0.0, to: 1.0, by: 0.5) {
                let st = a + (b - a) * t + V2(0, 9)      // 9 m off the road, SE side
                let w = frame.point(s: st.x, p: st.y)
                guard insidePolygon(w), isClear(st) else { continue }
                addTree(at: w, size: rng.range(4.0, 5.5)); treesPlaced += 1
            }
        }

        // --- Wildflower / iceplant accents: tiny flat color patches near the
        // rim overlooks, coastal magenta + gold, for painterly hue sparkle.
        let flowerMats: [SCNMaterial] = [
            { let m = WorldMat.pbr(worldColor(0.72, 0.28, 0.42), roughness: 0.9); m.emission.contents = worldColor(0.30, 0.06, 0.14); m.emission.intensity = 0.15; return m }(),
            { let m = WorldMat.pbr(worldColor(0.86, 0.66, 0.22), roughness: 0.9); m.emission.contents = worldColor(0.30, 0.20, 0.04); m.emission.intensity = 0.15; return m }(),
            WorldMat.pbr(worldColor(0.78, 0.42, 0.30), roughness: 0.9),
        ]
        var fAttempts = 0, fPlaced = 0
        while fPlaced < 70 && fAttempts < 4000 {
            fAttempts += 1
            // Bias toward the rim (0.80-0.95 of the outline radius).
            let idx = rng.int(outline.count)
            let f = rng.range(0.78, 0.95)
            let p = centroid + (outline[idx] - centroid) * f + V2(rng.range(-10, 10), rng.range(-10, 10))
            guard insidePolygon(p), isClear(frame.station(p)) else { continue }
            let patch = SCNNode()
            let clumpCount = 2 + rng.int(4)
            let mat = flowerMats[rng.int(flowerMats.count)]
            for _ in 0..<clumpCount {
                let s = rng.range(0.12, 0.28)
                let sph = SCNSphere(radius: CGFloat(s))
                sph.segmentCount = 4
                sph.materials = [mat]
                let dot = SCNNode(geometry: sph)
                dot.position = SCNVector3(Float(rng.range(-0.4, 0.4)), Float(s * 0.5), Float(rng.range(-0.4, 0.4)))
                patch.addChildNode(dot)
            }
            patch.position = worldV3(p, airport.groundHeight(at: p))
            container.addChildNode(patch)
            fPlaced += 1
        }

        // --- Rocks: faceted low-poly lumps (flat-shaded like the cliffs), with
        // a couple of outcrop clusters ON the mesa top for geologic interest —
        // not just dice on the rim.
        let rockMat = WorldMat.pbr(worldColor(0.560, 0.492, 0.410), roughness: 0.92)
        func addRock(at p: V2, size: Double, seed: UInt64) {
            var rrng = WorldRand(seed: seed)
            // Irregular lump: jitter a small ring of top/bottom vertices.
            var mesh = WorldMesh()
            let sides = 6
            let h = size * rrng.range(0.6, 1.0)
            var top: [SIMD3<Float>] = []
            var bot: [SIMD3<Float>] = []
            for k in 0..<sides {
                let a = Double(k) / Double(sides) * 2 * .pi
                let rTop = size * rrng.range(0.35, 0.6)
                let rBot = size * rrng.range(0.7, 1.05)
                top.append(SIMD3(Float(cos(a) * rTop), Float(h * rrng.range(0.75, 1.0)), Float(sin(a) * rTop)))
                bot.append(SIMD3(Float(cos(a) * rBot), Float(rrng.range(-0.05, 0.1) * size), Float(sin(a) * rBot)))
            }
            let apex = SIMD3<Float>(Float(rrng.range(-0.15, 0.15) * size), Float(h), Float(rrng.range(-0.15, 0.15) * size))
            let center = SIMD3<Float>(0, 0, 0)
            for k in 0..<sides {
                let j = (k + 1) % sides
                let up = SIMD3<Float>(0, 1, 0)
                mesh.facet(top[k], top[j], apex, hint: up, uv: .zero)               // crown
                mesh.facet(bot[k], top[j], top[k], hint: up, uv: .zero)             // side upper
                mesh.facet(bot[k], bot[j], top[j], hint: up, uv: .zero)             // side lower
                mesh.facet(bot[k], center, bot[j], hint: SIMD3(0, -1, 0), uv: .zero) // base
            }
            let rock = SCNNode(geometry: mesh.build(material: rockMat))
            rock.position = worldV3(p, airport.groundHeight(at: p) - size * 0.1)
            rock.eulerAngles.y = Float(rrng.range(0, 6.2))
            container.addChildNode(rock)
        }
        // Rim rocks.
        for i in 0..<14 {
            let idx = (i * 17 + 5) % outline.count
            let p = centroid + (outline[idx] - centroid) * rng.range(0.82, 0.90)
            guard isClear(frame.station(p)) else { continue }
            addRock(at: p, size: rng.range(0.9, 2.0), seed: 0x0C00 &+ UInt64(i))
        }
        // A couple of outcrop clusters on the mesa top (station coords s,p —
        // inland, off the pavement). Converted to world before placing.
        let outcropStations: [V2] = [V2(700, 130), V2(760, 90), V2(220, -90), V2(120, 120)]
        for (ci, st) in outcropStations.enumerated() {
            guard isClear(st) else { continue }
            let base = frame.point(s: st.x, p: st.y)      // world
            let clusterN = 3 + rng.int(3)
            for j in 0..<clusterN {
                let q = base + V2(rng.range(-6, 6), rng.range(-6, 6))
                guard insidePolygon(q), isClear(frame.station(q)) else { continue }
                addRock(at: q, size: rng.range(0.7, 1.6), seed: 0x0D00 &+ UInt64(ci * 10 + j))
            }
        }

        let flat = container.flattenedClone()
        flat.name = "scrub"
        return flat
    }
}
