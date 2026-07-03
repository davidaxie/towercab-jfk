import Foundation
import SceneKit
import UIKit

// =============================================================================
// AircraftModels+GA — three more fully-rigged GA airframes, built to real scale
// and wired exactly like the three template builds in AircraftModels.swift:
//
//   buildC182     → c182  (Cessna 182 Skylane: high-wing single, fixed gear,
//                          3-blade prop) — mirrors buildLark, scaled up + a
//                          beefier cowl.
//   buildPA28     → pa28  (Piper PA-28 Archer: low-wing single, fixed gear,
//                          squared Hershey-bar wing + squared stabilator) —
//                          mirrors buildVela + buildPropLive, FIXED gear.
//   buildBaron58  → baron58 (Beechcraft Baron 58: low-wing piston TWIN,
//                          retractable gear, 2 wing nacelles each with a prop) —
//                          mirrors buildVela + buildPropLive + 2 nacelles/props
//                          (both discs under one propGroup) + retractable
//                          liveGearLeg mains.
//
// Same conventions as the templates: node origin = ground contact, nose = −Z;
// static shell geometry goes through AirframeCache, live parts (props/surfaces/
// wheels/lights/shadow) stay OUT of the cache.
// =============================================================================

// MARK: - Cessna 182 Skylane (high-wing single, fixed gear)

/// c182 — a bigger-boned Skyhawk cousin: strut-braced high wing, fixed tricycle
/// gear with fairings, a beefier cowl, and a 3-blade constant-speed prop.
/// span 11.0 m, len 8.8 m. Mirrors buildLark; every live part wired the same.
func buildC182(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 1.24  // fuselage centerline height (a touch taller than the 172)

    let airframe = AirframeCache.airframe(kind: .c182, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
        let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
        let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)

        // Fuselage: 8.8 m nose-to-tail (nose −4.30, tail +4.50). Fatter forward
        // section carries the beefier cowl / bigger engine of the Skylane.
        let fus = latheNode([(-4.30, 0.12), (-4.20, 0.50), (-3.55, 0.66), (-2.75, 0.76),
                             (-1.90, 0.80), (-0.90, 0.78), (0.15, 0.60), (1.40, 0.40),
                             (2.80, 0.22), (4.10, 0.11), (4.50, 0.02)],
                            material: fuselageMaterial(kind: .c182, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Beefier cowl: a short forward lathe collar wrapping the nose ahead of
        // the windscreen — reads as the Skylane's deeper engine cowling.
        let cowl = latheNode([(-4.34, 0.10), (-4.28, 0.44), (-4.05, 0.60), (-3.70, 0.68),
                              (-3.35, 0.70)],
                             segments: 24, material: bodyMat)
        cowl.position.y = cy
        root.addChildNode(cowl)

        // Squared-ish glasshouse cabin.
        let cabin = SCNNode(geometry: SCNBox(width: 1.12, height: 0.54, length: 1.85, chamferRadius: 0.15))
        cabin.geometry?.materials = [canopyGlassMaterial()]
        cabin.position = SCNVector3(0, 1.82, -1.45)
        root.addChildNode(cabin)
        // Wraparound rear-window hint aft of the cabin.
        let rearWindow = SCNNode(geometry: SCNBox(width: 1.02, height: 0.28, length: 0.5, chamferRadius: 0.1))
        rearWindow.geometry?.materials = [canopyGlassMaterial()]
        rearWindow.position = SCNVector3(0, 1.80, -0.42)
        root.addChildNode(rearWindow)

        // High wing — span 11.0, mild taper. Root TE at z −0.35.
        let wing = wingNode(span: 11.0, rootChord: 1.6, tipChord: 1.1, sweep: 0,
                            thickness: 0.14, material: bodyMat)
        wing.position = SCNVector3(0, 2.12, -0.35)
        root.addChildNode(wing)
        if let tip = pal.wingtip {
            let tm = pbrMaterial(tip, roughness: pal.roughness)
            for x in [Float(-5.42), Float(5.42)] {
                let cap = SCNNode(geometry: SCNBox(width: 0.23, height: 0.155, length: 1.12, chamferRadius: 0.04))
                cap.geometry?.materials = [tm]
                cap.position = SCNVector3(x, 2.12, -1.30)
                root.addChildNode(cap)
            }
        }
        for s in [Float(-1), Float(1)] {
            // Strut meets the wing at ~40% semi-span.
            root.addChildNode(strutNode(from: SCNVector3(0.70 * s, 1.42, -1.05),
                                        to: SCNVector3(2.25 * s, 2.08, -1.15),
                                        radius: 0.034, material: bodyMat))
        }

        // Upright fin with dorsal fillet (a touch taller than the 172).
        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0.05, y: 0))
        finPath.addLine(to: CGPoint(x: 0.14, y: 1.52))
        finPath.addQuadCurve(to: CGPoint(x: 0.66, y: 1.62), controlPoint: CGPoint(x: 0.32, y: 1.66))
        finPath.addQuadCurve(to: CGPoint(x: 1.06, y: 0.66), controlPoint: CGPoint(x: 0.98, y: 1.18))
        finPath.addQuadCurve(to: CGPoint(x: 3.05, y: 0.0), controlPoint: CGPoint(x: 1.65, y: 0.05))
        finPath.close()
        let fin = finNode(path: finPath, thickness: 0.13, material: tailMat)
        fin.position = SCNVector3(0, 1.34, 4.44)
        root.addChildNode(fin)

        let stab = wingNode(span: 3.6, rootChord: 1.0, tipChord: 0.62, sweep: 0.16,
                            thickness: 0.085, material: bodyMat)
        stab.position = SCNVector3(0, 1.36, 4.42)
        root.addChildNode(stab)

        // Fixed tricycle gear with wheel fairings. Main STRUTS + fairings stay
        // static in the cache; the main WHEELS are live (spun in update()).
        let fairing: [(z: Float, r: Float)] = [(-0.38, 0.03), (-0.17, 0.18), (0.06, 0.21),
                                               (0.32, 0.13), (0.53, 0.02)]
        for s in [Float(-1), Float(1)] {
            root.addChildNode(strutNode(from: SCNVector3(0.38 * s, 1.00, -0.30),
                                        to: SCNVector3(1.22 * s, 0.38, -0.35),
                                        radius: 0.045, material: bodyMat))
            let f = latheNode(fairing, segments: 16, material: bodyMat)
            f.position = SCNVector3(1.25 * s, 0.36, -0.35)
            root.addChildNode(f)
        }
        root.addChildNode(strutNode(from: SCNVector3(0, 0.90, -3.30),
                                    to: SCNVector3(0, 0.32, -3.40),
                                    radius: 0.038, material: bodyMat))
        let nw = wheelNode(radius: 0.23, width: 0.15, tire: tire, hub: hub)
        nw.position = SCNVector3(0, 0.23, -3.42)
        root.addChildNode(nw)
        let nf = latheNode(fairing, segments: 16, material: bodyMat)
        nf.scale = SCNVector3(0.9, 0.9, 0.9)
        nf.position = SCNVector3(0, 0.32, -3.42)
        root.addChildNode(nf)
        return root
    }

    let body = SCNNode()
    body.addChildNode(airframe)
    // 3-blade constant-speed prop, Ø ~2.03 m, on the beefier cowl nose.
    let prop = makePropGroup(at: SCNVector3(0, cy, -4.40), bladeCount: 3, bladeLength: 0.92,
                             spinnerScale: 1.1, discDiameter: 2.03)
    body.addChildNode(prop.group)

    // Live surfaces + main wheels (high wing: TE at wing.z + rootChord).
    let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
    let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
    let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
    let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)
    let strutMat = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.5)
    let live = buildPropLive(spec: PropLiveSpec(
        wingY: 2.12, wingTE_Z: -0.35, wingHalfSpan: 5.5,
        ailChord: 0.36, ailSpan: 1.95, ailInboard: 3.1,
        flapChord: 0.36, flapSpan: 2.3, flapInboard: 0.78,
        surfThickness: 0.085,
        stabY: 1.36, stabTE_Z: 4.42, stabHalfSpan: 1.8, elevChord: 0.34,
        finBaseY: 1.34, finTE_Z: 4.38, rudderHeight: 1.45, rudderChord: 0.36,
        mainX: 1.25, mainZ: -0.35, mainTopY: 0.52,
        mainRadius: 0.25, mainWidth: 0.17, mainStrutR: 0.0),
        bodyMat: bodyMat, tailMat: tailMat, tire: tire, hub: hub, strutMat: strutMat)
    live.install(on: body)

    let shadow = makeContactShadow(span: 11.0, length: 8.8)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-5.5, 2.12, -1.35),
        navRight: SCNVector3(5.5, 2.12, -1.35),
        tail: SCNVector3(0, 1.52, 4.50),
        beacon: SCNVector3(0, 2.95, 4.05),
        landing: SCNVector3(0, 0.98, -4.38)))
    return CraftParts(body: body, propGroup: prop.group, blades: prop.blades,
                      blurDisc: prop.disc, fanGroups: [], heatWash: [],
                      beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      navNodes: kit.navs, scalingHalos: kit.halos, contactShadow: shadow,
                      landingLight: kit.light, landingGlow: kit.glow, gear: [],
                      smokeOffset: SCNVector3(0, 0.28, -0.35),
                      gearContacts: live.gearContacts, wheels: live.wheels, oleos: live.oleos,
                      ailerons: live.ailerons, elevator: live.elevator,
                      rudder: live.rudder, flaps: live.flaps)
}

// MARK: - Piper PA-28 Archer (low-wing single, fixed gear)

/// pa28 — the classic trainer/tourer: low semi-tapered "Hershey-bar" wing,
/// a low bubble/greenhouse cabin, squared vertical fin, and a one-piece
/// stabilator (all-moving horizontal tail). FIXED tricycle gear on plain
/// strut/pants. span 10.7 m, len 7.3 m. Mirrors buildVela + buildPropLive
/// but with FIXED gear (mainStrutR: 0.0, no retract).
func buildPA28(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 1.00

    let airframe = AirframeCache.airframe(kind: .pa28, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
        let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
        let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)

        // Fuselage: 7.3 m (nose −3.55, tail +3.75). Slab-sided Cherokee shape,
        // fairly constant depth through the cabin then a slim tail cone.
        let fus = latheNode([(-3.55, 0.11), (-3.42, 0.40), (-2.85, 0.56), (-1.95, 0.64),
                             (-0.95, 0.66), (0.15, 0.60), (1.35, 0.42), (2.55, 0.24),
                             (3.75, 0.08)],
                            material: fuselageMaterial(kind: .pa28, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Low greenhouse cabin — a flatter box canopy than the Cirrus bubble.
        let cabin = SCNNode(geometry: SCNBox(width: 1.02, height: 0.5, length: 1.55, chamferRadius: 0.13))
        cabin.geometry?.materials = [canopyGlassMaterial()]
        cabin.position = SCNVector3(0, 1.42, -0.95)
        root.addChildNode(cabin)

        // Hershey-bar wing: nearly rectangular planform (rootChord ≈ tipChord,
        // no sweep). Low-mounted. Root TE at z −0.10.
        let wing = wingNode(span: 10.7, rootChord: 1.5, tipChord: 1.3, sweep: 0,
                            thickness: 0.13, material: bodyMat)
        wing.position = SCNVector3(0, 0.70, -0.10)
        root.addChildNode(wing)
        if let tip = pal.wingtip {
            let tm = pbrMaterial(tip, roughness: pal.roughness)
            for x in [Float(-5.28), Float(5.28)] {
                let cap = SCNNode(geometry: SCNBox(width: 0.2, height: 0.145, length: 1.3, chamferRadius: 0.04))
                cap.geometry?.materials = [tm]
                cap.position = SCNVector3(x, 0.70, -0.75)
                root.addChildNode(cap)
            }
        }

        // Squared vertical fin (straight leading edge, blunt swept top) — the
        // Cherokee tail is boxy, not a graceful curve.
        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0.08, y: 0))
        finPath.addLine(to: CGPoint(x: 0.30, y: 1.16))
        finPath.addLine(to: CGPoint(x: 0.80, y: 1.22))
        finPath.addLine(to: CGPoint(x: 1.05, y: 1.02))
        finPath.addLine(to: CGPoint(x: 1.95, y: 0.0))
        finPath.close()
        let fin = finNode(path: finPath, thickness: 0.11, material: tailMat)
        fin.position = SCNVector3(0, 1.08, 3.66)
        root.addChildNode(fin)

        // Stabilator: one all-moving squared horizontal tail. The moving slab is
        // the LIVE elevator (below); this static slab is a thin anti-servo stub
        // so the airframe still reads with a tail plane when parked. Keep it thin
        // and short-chord — the live elevator carries the visible area.
        let stab = wingNode(span: 3.4, rootChord: 0.45, tipChord: 0.42, sweep: 0.05,
                            thickness: 0.07, material: bodyMat)
        stab.position = SCNVector3(0, 0.95, 3.30)
        root.addChildNode(stab)

        // Fixed gear on plain strut + small pants. Struts + pants static; main
        // wheels live.
        let pants: [(z: Float, r: Float)] = [(-0.34, 0.02), (-0.16, 0.13), (0.05, 0.16),
                                             (0.30, 0.09), (0.48, 0.02)]
        for s in [Float(-1), Float(1)] {
            root.addChildNode(strutNode(from: SCNVector3(0.48 * s, 0.66, -0.10),
                                        to: SCNVector3(1.28 * s, 0.34, -0.15),
                                        radius: 0.036, material: bodyMat))
            let p = latheNode(pants, segments: 16, material: bodyMat)
            p.position = SCNVector3(1.3 * s, 0.34, -0.15)
            root.addChildNode(p)
        }
        root.addChildNode(strutNode(from: SCNVector3(0, 0.66, -2.55),
                                    to: SCNVector3(0, 0.28, -2.62),
                                    radius: 0.032, material: bodyMat))
        let nw = wheelNode(radius: 0.21, width: 0.13, tire: tire, hub: hub)
        nw.position = SCNVector3(0, 0.21, -2.64)
        root.addChildNode(nw)
        let np = latheNode(pants, segments: 16, material: bodyMat)
        np.scale = SCNVector3(0.85, 0.85, 0.85)
        np.position = SCNVector3(0, 0.30, -2.64)
        root.addChildNode(np)
        return root
    }

    let body = SCNNode()
    body.addChildNode(airframe)
    // 2-blade fixed-pitch prop, Ø ~1.88 m.
    let prop = makePropGroup(at: SCNVector3(0, cy, -3.54), bladeCount: 2, bladeLength: 0.86,
                             spinnerScale: 1.0, discDiameter: 1.88)
    body.addChildNode(prop.group)

    // Live surfaces + main wheels (low wing: TE at wing.z + rootChord = 1.40).
    // The stabilator's LIVE elevator carries most of the tail's visible chord.
    let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
    let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
    let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
    let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)
    let strutMat = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.5)
    let live = buildPropLive(spec: PropLiveSpec(
        wingY: 0.70, wingTE_Z: -0.10, wingHalfSpan: 5.35,
        ailChord: 0.30, ailSpan: 1.8, ailInboard: 3.1,
        flapChord: 0.30, flapSpan: 1.9, flapInboard: 0.75,
        surfThickness: 0.08,
        // Stabilator: the moving slab hinges AT the static stub's trailing edge
        // (stub node z 3.30) and carries a long chord so it reads as one
        // all-moving surface — the stub is just a thin forward anti-servo root.
        stabY: 0.95, stabTE_Z: 3.30, stabHalfSpan: 1.7, elevChord: 0.5,
        finBaseY: 1.08, finTE_Z: 3.62, rudderHeight: 1.05, rudderChord: 0.32,
        mainX: 1.3, mainZ: -0.15, mainTopY: 0.5,
        mainRadius: 0.24, mainWidth: 0.14, mainStrutR: 0.0),
        bodyMat: bodyMat, tailMat: tailMat, tire: tire, hub: hub, strutMat: strutMat)
    live.install(on: body)

    let shadow = makeContactShadow(span: 10.7, length: 7.3)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-5.3, 0.78, -0.75),
        navRight: SCNVector3(5.3, 0.78, -0.75),
        tail: SCNVector3(0, 1.08, 3.72),
        beacon: SCNVector3(0, 2.28, 3.40),
        landing: SCNVector3(0, 0.70, -3.52)))
    return CraftParts(body: body, propGroup: prop.group, blades: prop.blades,
                      blurDisc: prop.disc, fanGroups: [], heatWash: [],
                      beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      navNodes: kit.navs, scalingHalos: kit.halos, contactShadow: shadow,
                      landingLight: kit.light, landingGlow: kit.glow, gear: [],
                      smokeOffset: SCNVector3(0, 0.26, -0.15),
                      gearContacts: live.gearContacts, wheels: live.wheels, oleos: live.oleos,
                      ailerons: live.ailerons, elevator: live.elevator,
                      rudder: live.rudder, flaps: live.flaps)
}

// MARK: - Beechcraft Baron 58 (low-wing piston TWIN, retractable gear)

/// baron58 — cabin-class piston twin: low wing carrying two engine nacelles,
/// each with its own prop; 6-seat cabin with the extra pair of side windows;
/// swept vertical fin; RETRACTABLE tricycle gear (mains fold inboard into the
/// nacelles, nose folds forward). span 11.5 m, len 8.5 m. Mirrors buildVela +
/// buildPropLive for the low-wing rig, adds two wing nacelles/props (both prop
/// discs parented under ONE propGroup so the single spin animates both), and
/// retractable liveGearLeg mains with real oleo struts.
func buildBaron58(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 1.06
    // Wing geometry knobs reused by the airframe shell AND the live parts.
    let wingY: Float = 0.74
    let wingTE_Z: Float = -0.05
    let nacX: Float = 1.85            // nacelle centerline |x|
    let nacFront: Float = -2.65       // prop plane z (nacelle nose)
    let mainZ: Float = 0.55           // main-gear contact z (folds into nacelle)

    let airframe = AirframeCache.airframe(kind: .baron58, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
        let nacMat = pbrMaterial(pal.body, roughness: max(0.12, pal.roughness - 0.04),
                                 metalness: min(1, pal.metalness + 0.1))

        // Fuselage: 8.5 m (nose −3.90, tail +4.60). Deeper cabin-class section
        // than the singles — carries a 6-seat club cabin.
        let fus = latheNode([(-3.90, 0.11), (-3.75, 0.42), (-3.05, 0.62), (-2.05, 0.74),
                             (-0.90, 0.78), (0.30, 0.74), (1.55, 0.56), (2.85, 0.34),
                             (3.95, 0.14), (4.60, 0.04)],
                            material: fuselageMaterial(kind: .baron58, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Cabin greenhouse — longer than a single, hinting at the 6-seat club
        // cabin's two window rows.
        let cabin = SCNNode(geometry: SCNBox(width: 1.12, height: 0.52, length: 2.05, chamferRadius: 0.14))
        cabin.geometry?.materials = [canopyGlassMaterial()]
        cabin.position = SCNVector3(0, 1.50, -0.85)
        root.addChildNode(cabin)
        // Aft club-cabin window band (the extra rear pair of windows).
        let rearWindow = SCNNode(geometry: SCNBox(width: 1.04, height: 0.30, length: 0.7, chamferRadius: 0.1))
        rearWindow.geometry?.materials = [canopyGlassMaterial()]
        rearWindow.position = SCNVector3(0, 1.46, 0.55)
        root.addChildNode(rearWindow)

        // Low wing — span 11.5, mild taper. Root TE at z −0.05.
        let wing = wingNode(span: 11.5, rootChord: 1.6, tipChord: 0.95, sweep: 0.2,
                            thickness: 0.15, material: bodyMat)
        wing.position = SCNVector3(0, wingY, wingTE_Z)
        root.addChildNode(wing)
        if let tip = pal.wingtip {
            let tm = pbrMaterial(tip, roughness: pal.roughness)
            for x in [Float(-5.66), Float(5.66)] {
                let cap = SCNNode(geometry: SCNBox(width: 0.22, height: 0.16, length: 0.97, chamferRadius: 0.04))
                cap.geometry?.materials = [tm]
                cap.position = SCNVector3(x, wingY, -0.55)
                root.addChildNode(cap)
            }
        }

        // Two engine nacelles slung under the wing. The static SHELL (cowl +
        // aft fairing that the mains retract into) lives here; the spinning prop
        // is live (below). Nacelle spans z −2.75 (cowl nose) → +1.15 (tail
        // fairing over the wheel well).
        for s in [Float(-1), Float(1)] {
            let nac = latheNode([(-2.75, 0.14), (-2.60, 0.34), (-2.10, 0.44), (-1.20, 0.46),
                                 (-0.10, 0.44), (0.60, 0.36), (1.15, 0.16)],
                                segments: 20, material: nacMat)
            nac.position = SCNVector3(nacX * s, wingY - 0.04, 0)
            root.addChildNode(nac)
            // Polished spinner backplate collar at the prop plane.
            let collar = latheNode([(-2.78, 0.05), (-2.72, 0.16), (-2.64, 0.22)],
                                   segments: 16, material: nacMat)
            collar.position = SCNVector3(nacX * s, wingY - 0.04, 0)
            root.addChildNode(collar)
        }

        // Swept vertical fin (Baron's tall, slightly swept tail).
        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0.06, y: 0))
        finPath.addLine(to: CGPoint(x: 0.34, y: 1.34))
        finPath.addQuadCurve(to: CGPoint(x: 0.82, y: 1.44), controlPoint: CGPoint(x: 0.48, y: 1.48))
        finPath.addQuadCurve(to: CGPoint(x: 2.35, y: 0.0), controlPoint: CGPoint(x: 1.55, y: 0.5))
        finPath.close()
        let fin = finNode(path: finPath, thickness: 0.12, material: tailMat)
        fin.position = SCNVector3(0, 1.18, 4.30)
        root.addChildNode(fin)

        let stab = wingNode(span: 4.0, rootChord: 1.05, tipChord: 0.6, sweep: 0.28,
                            thickness: 0.09, material: bodyMat)
        stab.position = SCNVector3(0, 1.20, 4.34)
        root.addChildNode(stab)
        return root
    }

    let body = SCNNode()
    body.addChildNode(airframe)

    // TWIN props. Each engine needs to spin about ITS OWN axis at the nacelle —
    // a shared parent rotating about the fuselage centerline would ORBIT the
    // offset props across the nose, so the naive "both under one spun parent"
    // is wrong. Instead we hand the rig ONE real spinning prop (engine 1, the
    // left nacelle, which spins in place about its own local Z), and MIRROR
    // engine 2 to it every frame with a constraint. The rig only ever mutates
    // `parts.propGroup.eulerAngles.z` and `parts.blades/.blurDisc` opacity on
    // engine 1; the constraint copies engine 1's local spin + blur opacity onto
    // engine 2 after the rig runs, so both read identically without orbiting.
    let p1 = makePropGroup(at: SCNVector3(nacX * -1, wingY - 0.04, nacFront),
                           bladeCount: 3, bladeLength: 0.82,
                           spinnerScale: 1.0, discDiameter: 1.88)
    let p2 = makePropGroup(at: SCNVector3(nacX * 1, wingY - 0.04, nacFront),
                           bladeCount: 3, bladeLength: 0.82,
                           spinnerScale: 1.0, discDiameter: 1.88)
    body.addChildNode(p1.group)
    body.addChildNode(p2.group)
    let propGroup = p1.group   // the ONE node the rig spins (in place at its nacelle)

    // Engine-2 mirror: a per-frame constraint copies engine 1's spin angle and
    // its live blur-node opacities onto engine 2. The closure returns engine 2's
    // transform unchanged except for the local Z rotation; the opacity copies are
    // side effects (constraints run every frame during scene evaluation, after
    // update()). Weak-ref capture avoids a retain cycle through the node graph.
    let mirror = SCNTransformConstraint(inWorldSpace: false) {
        [weak g1 = p1.group, weak b1 = p1.blades, weak d1 = p1.disc,
         weak b2 = p2.blades, weak d2 = p2.disc] node, transform in
        var t = transform
        // Copy engine 1's accumulated spin (local eulerAngles.z) into engine 2.
        let z = g1?.eulerAngles.z ?? node.eulerAngles.z
        let rot = SCNMatrix4MakeRotation(z, 0, 0, 1)
        // Rebuild engine-2 transform = its fixed translation ∘ engine-1 rotation.
        var placed = SCNMatrix4Identity
        placed = SCNMatrix4Translate(placed, nacX * 1, wingY - 0.04, nacFront)
        t = SCNMatrix4Mult(rot, placed)
        // Mirror blur opacities (cosmetic; driven on engine 1 by the rig).
        b2?.opacity = b1?.opacity ?? 1
        d2?.opacity = d1?.opacity ?? 0
        return t
    }
    p2.group.constraints = [mirror]

    // Live surfaces + retractable main gear.
    let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
    let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
    let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)
    let strutMat = pbrMaterial(UIColor(white: 0.75, alpha: 1), roughness: 0.35, metalness: 0.7)
    let surfBodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)

    // --- Control surfaces. wingNode origin = ROOT TRAILING EDGE, so the wing's
    // TE is AT its position.z (the shape extends FORWARD to −Z for the chord).
    // Wing sits at z wingTE_Z with a mild 0.2 m tip sweep; the TE is nearly
    // straight, so we hinge each surface just aft of wingTE_Z. ---
    var ailerons: [Surface] = []
    var flaps: [Surface] = []
    let wingTE: Float = wingTE_Z        // TE is at the wing node's z position
    for s in [Float(-1), Float(1)] {
        let a = hingedSurfaceNode(span: 1.9, chord: 0.30, thickness: 0.08, material: surfBodyMat)
        // Outboard of the nacelle: centered near |x| 4.4.
        a.position = SCNVector3(s * 4.4, wingY, wingTE)
        ailerons.append(Surface(node: a, sign: s))
        body.addChildNode(a)
        // Inboard flap between fuselage and nacelle: centered near |x| 1.0.
        let fl = hingedSurfaceNode(span: 1.4, chord: 0.30, thickness: 0.08, material: surfBodyMat)
        fl.position = SCNVector3(s * 1.0, wingY, wingTE)
        flaps.append(Surface(node: fl, sign: 1))
        body.addChildNode(fl)
    }
    // Elevator — one slab spanning the stab trailing edge. Stab node is at z 4.34
    // (its TE), so the elevator hinges there.
    var elevator: [Surface] = []
    let elev = hingedSurfaceNode(span: 4.0, chord: 0.34, thickness: 0.08, material: surfBodyMat)
    elev.position = SCNVector3(0, 1.20, 4.34)
    elevator.append(Surface(node: elev, sign: 1))
    body.addChildNode(elev)
    // Rudder — hinged at the fin trailing edge (finNode TE near node.z 4.30).
    var rudder: [Surface] = []
    let rud = hingedRudderNode(height: 1.28, chord: 0.32, thickness: 0.11, material: tailMat)
    rud.position = SCNVector3(0, 1.18, 4.28)
    rudder.append(Surface(node: rud, sign: 1))
    body.addChildNode(rud)

    // --- Retractable gear: live wheels + real oleo on the mains, folding via a
    // pivot node exactly like buildComet. Nose folds forward; mains fold inboard
    // into the nacelles. ---
    var wheels: [(node: SCNNode, radius: Float)] = []
    var oleos: [(node: SCNNode, restY: Float, travel: Float)] = []
    var gear: [(node: SCNNode, foldedEuler: SCNVector3)] = []
    var gearContacts: [SCNVector3] = []

    // Nose gear: pivot → live wheel on a live oleo strut, folds forward.
    let noseLeg = liveGearLeg(topY: 0.72, wheelRadius: 0.20, wheelWidth: 0.12,
                              strutRadius: 0.035, travel: 0.08,
                              tire: tire, hub: hub, strut: strutMat)
    let nosePivot = SCNNode()
    nosePivot.position = SCNVector3(0, 0, -2.70)
    nosePivot.addChildNode(noseLeg.leg)
    body.addChildNode(nosePivot)
    wheels.append((noseLeg.wheel, 0.20))
    gear.append((nosePivot, SCNVector3(1.7, 0, 0)))   // folds forward into the nose

    // Main gear under each nacelle: pivot → live wheel on a live oleo, folds
    // inboard into the nacelle wheel well.
    for s in [Float(-1), Float(1)] {
        let leg = liveGearLeg(topY: 0.74, wheelRadius: 0.28, wheelWidth: 0.16,
                              strutRadius: 0.045, travel: 0.10,
                              tire: tire, hub: hub, strut: strutMat)
        let pivot = SCNNode()
        pivot.position = SCNVector3(nacX * s, 0, mainZ)
        pivot.addChildNode(leg.leg)
        body.addChildNode(pivot)
        wheels.append((leg.wheel, 0.28))
        oleos.append((leg.oleo, 0.74, 0.10))
        gear.append((pivot, SCNVector3(0, 0, 1.6 * -s)))   // fold inboard
        gearContacts.append(SCNVector3(nacX * s, 0, mainZ))
    }

    let shadow = makeContactShadow(span: 11.5, length: 8.5)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-5.7, 0.82, -0.55),
        navRight: SCNVector3(5.7, 0.82, -0.55),
        tail: SCNVector3(0, 1.18, 4.55),
        beacon: SCNVector3(0, 2.50, 4.05),
        landing: SCNVector3(0, 0.74, -3.88)))
    return CraftParts(body: body, propGroup: propGroup, blades: p1.blades,
                      blurDisc: p1.disc, fanGroups: [], heatWash: [],
                      beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      navNodes: kit.navs, scalingHalos: kit.halos, contactShadow: shadow,
                      landingLight: kit.light, landingGlow: kit.glow, gear: gear,
                      smokeOffset: SCNVector3(0, 0.30, 0.55),
                      gearContacts: gearContacts, wheels: wheels, oleos: oleos,
                      ailerons: ailerons, elevator: elevator,
                      rudder: rudder, flaps: flaps)
}
