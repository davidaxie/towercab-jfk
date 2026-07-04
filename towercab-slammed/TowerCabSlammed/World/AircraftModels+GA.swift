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
/// gear with fairings, a beefier/deeper cowl, longer nose, and a 3-blade
/// constant-speed prop with a big spinner. span 11.0 m, len 8.84 m, height 2.84.
/// SAME high-wing planform + area as the 172 (16.2 m²), just heftier + taller on
/// its gear. Mirrors buildLark; every live part wired the same.
func buildC182(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 1.26  // fuselage centerline height — sits taller than the 172

    let airframe = AirframeCache.airframe(kind: .c182, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
        let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
        let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)

        // Fuselage: 8.84 m nose-to-tail (nose −4.34, tail +4.50). Slab-sided
        // rounded-rectangle family look, but LONGER-nosed and beefier than the
        // 172: the forward section stays fat well ahead of the wing to carry the
        // deeper 230 hp cowl, then tapers to the cut-down aft deck + tailcone.
        let fus = latheNode([(-4.34, 0.14), (-4.22, 0.54), (-3.60, 0.70), (-2.80, 0.79),
                             (-1.90, 0.82), (-0.90, 0.80), (0.15, 0.62), (1.40, 0.40),
                             (2.80, 0.22), (4.10, 0.11), (4.50, 0.02)],
                            material: fuselageMaterial(kind: .c182, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Deep, hefty, bulged cowl — the Skylane's meatier nose. A short forward
        // lathe collar that stays fat right to the prop plane (flat-topped, low
        // cheek intakes read as the bulk), distinctly NOT a round radial cowl.
        let cowl = latheNode([(-4.40, 0.12), (-4.34, 0.50), (-4.10, 0.66), (-3.72, 0.74),
                              (-3.30, 0.76)],
                             segments: 24, material: bodyMat)
        cowl.position.y = cy
        root.addChildNode(cowl)

        // Squared-ish glasshouse cabin, forward under the high wing.
        let cabin = SCNNode(geometry: SCNBox(width: 1.14, height: 0.54, length: 1.9, chamferRadius: 0.15))
        cabin.geometry?.materials = [canopyGlassMaterial()]
        cabin.position = SCNVector3(0, 1.84, -1.45)
        root.addChildNode(cabin)
        // Cut-down aft deck carrying the wraparound Omni-Vision rear window.
        let rearWindow = SCNNode(geometry: SCNBox(width: 1.04, height: 0.28, length: 0.5, chamferRadius: 0.1))
        rearWindow.geometry?.materials = [canopyGlassMaterial()]
        rearWindow.position = SCNVector3(0, 1.82, -0.42)
        root.addChildNode(rearWindow)

        // High wing — span 11.0, near-rectangular inboard with a mild straight
        // taper outboard (same planform/area as the 172). Root TE at z −0.35.
        let wing = wingNode(span: 11.0, rootChord: 1.6, tipChord: 1.1, sweep: 0,
                            thickness: 0.14, material: bodyMat)
        wing.position = SCNVector3(0, 2.14, -0.35)
        root.addChildNode(wing)
        // Squared, slightly-upturned tips (read the ~1.5° dihedral via raised caps).
        if let tip = pal.wingtip {
            let tm = pbrMaterial(tip, roughness: pal.roughness)
            for x in [Float(-5.42), Float(5.42)] {
                let cap = SCNNode(geometry: SCNBox(width: 0.23, height: 0.155, length: 1.12, chamferRadius: 0.04))
                cap.geometry?.materials = [tm]
                cap.position = SCNVector3(x, 2.22, -1.30)
                root.addChildNode(cap)
            }
        }
        for s in [Float(-1), Float(1)] {
            // Single straight lift strut per side to ~40% semi-span — the defining
            // Cessna high-wing feature.
            root.addChildNode(strutNode(from: SCNVector3(0.70 * s, 1.44, -1.05),
                                        to: SCNVector3(2.25 * s, 2.10, -1.15),
                                        radius: 0.034, material: bodyMat))
        }

        // Swept vertical fin with a dorsal fin fillet, taller than the 172.
        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0.05, y: 0))
        finPath.addLine(to: CGPoint(x: 0.14, y: 1.56))
        finPath.addQuadCurve(to: CGPoint(x: 0.66, y: 1.66), controlPoint: CGPoint(x: 0.32, y: 1.70))
        finPath.addQuadCurve(to: CGPoint(x: 1.06, y: 0.66), controlPoint: CGPoint(x: 0.98, y: 1.20))
        finPath.addQuadCurve(to: CGPoint(x: 3.05, y: 0.0), controlPoint: CGPoint(x: 1.65, y: 0.05))
        finPath.close()
        let fin = finNode(path: finPath, thickness: 0.13, material: tailMat)
        fin.position = SCNVector3(0, 1.36, 4.44)
        root.addChildNode(fin)

        // Low-set near-rectangular stabilizer (not a T-tail), span ~3.5 m.
        let stab = wingNode(span: 3.5, rootChord: 1.0, tipChord: 0.62, sweep: 0.16,
                            thickness: 0.085, material: bodyMat)
        stab.position = SCNVector3(0, 1.38, 4.42)
        root.addChildNode(stab)

        // Fixed tricycle gear with teardrop wheel fairings, beefier than the 172.
        // Main STRUTS + fairings stay static in the cache; main WHEELS are live.
        let fairing: [(z: Float, r: Float)] = [(-0.38, 0.03), (-0.17, 0.18), (0.06, 0.21),
                                               (0.32, 0.13), (0.53, 0.02)]
        for s in [Float(-1), Float(1)] {
            root.addChildNode(strutNode(from: SCNVector3(0.38 * s, 1.02, -0.30),
                                        to: SCNVector3(1.22 * s, 0.38, -0.35),
                                        radius: 0.045, material: bodyMat))
            let f = latheNode(fairing, segments: 16, material: bodyMat)
            f.position = SCNVector3(1.25 * s, 0.36, -0.35)
            root.addChildNode(f)
        }
        root.addChildNode(strutNode(from: SCNVector3(0, 0.92, -3.30),
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
    // 3-blade constant-speed metal prop, Ø ~2.03 m, big pointed spinner, on the
    // deep cowl nose.
    let prop = makePropGroup(at: SCNVector3(0, cy, -4.46), bladeCount: 3, bladeLength: 0.92,
                             spinnerScale: 1.15, discDiameter: 2.03)
    body.addChildNode(prop.group)

    // Live surfaces + main wheels (high wing: TE at wing.z + rootChord).
    let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
    let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
    let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
    let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)
    let strutMat = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.5)
    let live = buildPropLive(spec: PropLiveSpec(
        wingY: 2.14, wingTE_Z: -0.35, wingHalfSpan: 5.5,
        ailChord: 0.36, ailSpan: 1.95, ailInboard: 3.1,
        flapChord: 0.36, flapSpan: 2.3, flapInboard: 0.78,
        surfThickness: 0.085,
        stabY: 1.38, stabTE_Z: 4.42, stabHalfSpan: 1.75, elevChord: 0.34,
        finBaseY: 1.36, finTE_Z: 4.40, rudderHeight: 1.48, rudderChord: 0.36,
        mainX: 1.25, mainZ: -0.35, mainTopY: 0.52,
        mainRadius: 0.25, mainWidth: 0.17, mainStrutR: 0.0),
        bodyMat: bodyMat, tailMat: tailMat, tire: tire, hub: hub, strutMat: strutMat)
    live.install(on: body)

    let shadow = makeContactShadow(span: 11.0, length: 8.84)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-5.5, 2.18, -1.30),
        navRight: SCNVector3(5.5, 2.18, -1.30),
        tail: SCNVector3(0, 1.54, 4.50),
        beacon: SCNVector3(0, 2.98, 4.05),
        landing: SCNVector3(0, 1.00, -4.44)))
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

/// pa28 — the Archer III: LOW cantilever wing (NO struts) with strong dihedral
/// and the semi-TAPERED planform (constant chord inboard, straight taper
/// outboard — the "tapered" Cherokee, not the old Hershey-bar), a low sleek
/// greenhouse cabin, a broad swept vertical fin with a LARGE dorsal fillet, and
/// a one-piece all-moving STABILATOR. FIXED tricycle gear on plain strut/pants,
/// low ground stance. span 10.7 m, len 7.32 m, height 2.21. Mirrors
/// buildVela + buildPropLive but with FIXED gear (mainStrutR: 0.0, no retract).
func buildPA28(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 0.96   // low-slung: the Archer sits close to the ground

    let airframe = AirframeCache.airframe(kind: .pa28, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
        let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
        let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)

        // Fuselage: 7.32 m (nose −3.55, tail +3.77). Slimmer, lower and more
        // streamlined than a Cessna — a smooth tapering cowl to a small spinner
        // up front, oval cabin section, then a slim tailcone with a gentle
        // upsweep to the conventional tail.
        let fus = latheNode([(-3.55, 0.10), (-3.40, 0.34), (-2.85, 0.52), (-1.95, 0.60),
                             (-0.95, 0.62), (0.15, 0.56), (1.35, 0.40), (2.55, 0.22),
                             (3.77, 0.07)],
                            material: fuselageMaterial(kind: .pa28, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Low sleek greenhouse cabin sitting ON TOP of the fuselage (the low wing
        // rides beneath it) — a flatter box canopy than the Cirrus bubble.
        let cabin = SCNNode(geometry: SCNBox(width: 1.0, height: 0.48, length: 1.5, chamferRadius: 0.13))
        cabin.geometry?.materials = [canopyGlassMaterial()]
        cabin.position = SCNVector3(0, 1.34, -0.9)
        root.addChildNode(cabin)

        // Semi-tapered wing: constant chord inboard then a straight taper out to
        // the tip (rootChord > tipChord, slight LE taper), low-mounted at the
        // belly with NO struts. Root TE at z −0.05.
        let wing = wingNode(span: 10.7, rootChord: 1.55, tipChord: 1.0, sweep: 0.18,
                            thickness: 0.13, material: bodyMat)
        wing.position = SCNVector3(0, 0.62, -0.05)
        root.addChildNode(wing)
        // Squared tips raised well up to read the pronounced ~7° dihedral — the
        // clear upward V that separates the Piper from the flat-winged Cessna.
        if let tip = pal.wingtip {
            let tm = pbrMaterial(tip, roughness: pal.roughness)
            for x in [Float(-5.28), Float(5.28)] {
                let cap = SCNNode(geometry: SCNBox(width: 0.2, height: 0.135, length: 1.0, chamferRadius: 0.04))
                cap.geometry?.materials = [tm]
                cap.position = SCNVector3(x, 0.88, -0.6)
                root.addChildNode(cap)
            }
        }

        // Broad swept vertical fin with a LARGE dorsal fillet sweeping up from the
        // spine — the Cherokee fin is a wide, filleted swept shape.
        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0.10, y: 0))
        finPath.addQuadCurve(to: CGPoint(x: 0.50, y: 1.10), controlPoint: CGPoint(x: 0.16, y: 0.72))
        finPath.addQuadCurve(to: CGPoint(x: 0.92, y: 1.18), controlPoint: CGPoint(x: 0.62, y: 1.22))
        finPath.addLine(to: CGPoint(x: 1.16, y: 1.00))
        finPath.addQuadCurve(to: CGPoint(x: 2.30, y: 0.0), controlPoint: CGPoint(x: 1.62, y: 0.22))
        finPath.close()
        let fin = finNode(path: finPath, thickness: 0.11, material: tailMat)
        fin.position = SCNVector3(0, 1.00, 3.62)
        root.addChildNode(fin)

        // Stabilator: one all-moving squared horizontal tail. The moving slab is
        // the LIVE elevator (below); this static slab is a thin forward root stub
        // (anti-servo hint) so the airframe still reads with a tailplane when
        // parked. Keep it thin/short-chord — the live elevator carries the area.
        let stab = wingNode(span: 3.4, rootChord: 0.42, tipChord: 0.40, sweep: 0.04,
                            thickness: 0.07, material: bodyMat)
        stab.position = SCNVector3(0, 0.90, 3.24)
        root.addChildNode(stab)

        // Fixed gear on short cantilever legs from the low wing/belly + standard
        // teardrop pants. Struts + pants static; main wheels live. Low stance.
        let pants: [(z: Float, r: Float)] = [(-0.34, 0.02), (-0.16, 0.13), (0.05, 0.16),
                                             (0.30, 0.09), (0.48, 0.02)]
        for s in [Float(-1), Float(1)] {
            root.addChildNode(strutNode(from: SCNVector3(0.48 * s, 0.58, -0.05),
                                        to: SCNVector3(1.28 * s, 0.32, -0.10),
                                        radius: 0.036, material: bodyMat))
            let p = latheNode(pants, segments: 16, material: bodyMat)
            p.position = SCNVector3(1.3 * s, 0.32, -0.10)
            root.addChildNode(p)
        }
        root.addChildNode(strutNode(from: SCNVector3(0, 0.60, -2.55),
                                    to: SCNVector3(0, 0.26, -2.62),
                                    radius: 0.032, material: bodyMat))
        let nw = wheelNode(radius: 0.20, width: 0.13, tire: tire, hub: hub)
        nw.position = SCNVector3(0, 0.20, -2.64)
        root.addChildNode(nw)
        let np = latheNode(pants, segments: 16, material: bodyMat)
        np.scale = SCNVector3(0.85, 0.85, 0.85)
        np.position = SCNVector3(0, 0.28, -2.64)
        root.addChildNode(np)
        return root
    }

    let body = SCNNode()
    body.addChildNode(airframe)
    // 2-blade fixed-pitch Sensenich prop, Ø ~1.88 m, small conical spinner.
    let prop = makePropGroup(at: SCNVector3(0, cy, -3.58), bladeCount: 2, bladeLength: 0.86,
                             spinnerScale: 0.95, discDiameter: 1.88)
    body.addChildNode(prop.group)

    // Live surfaces + main wheels (low wing: TE at wing.z + rootChord = 1.40).
    // The stabilator's LIVE elevator carries most of the tail's visible chord.
    let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
    let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
    let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
    let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)
    let strutMat = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.5)
    let live = buildPropLive(spec: PropLiveSpec(
        wingY: 0.62, wingTE_Z: -0.05, wingHalfSpan: 5.35,
        ailChord: 0.30, ailSpan: 1.8, ailInboard: 3.1,
        flapChord: 0.30, flapSpan: 1.9, flapInboard: 0.75,
        surfThickness: 0.08,
        // Stabilator: the moving slab hinges AT the static stub's trailing edge
        // (stub node z 3.24) and carries a long chord so it reads as one
        // all-moving surface — the stub is just a thin forward anti-servo root.
        stabY: 0.90, stabTE_Z: 3.24, stabHalfSpan: 1.7, elevChord: 0.5,
        finBaseY: 1.00, finTE_Z: 3.58, rudderHeight: 1.06, rudderChord: 0.32,
        mainX: 1.3, mainZ: -0.10, mainTopY: 0.48,
        mainRadius: 0.23, mainWidth: 0.14, mainStrutR: 0.0),
        bodyMat: bodyMat, tailMat: tailMat, tire: tire, hub: hub, strutMat: strutMat)
    live.install(on: body)

    let shadow = makeContactShadow(span: 10.7, length: 7.32)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-5.3, 0.86, -0.6),
        navRight: SCNVector3(5.3, 0.86, -0.6),
        tail: SCNVector3(0, 1.00, 3.70),
        beacon: SCNVector3(0, 2.18, 3.36),
        landing: SCNVector3(0, 0.62, -3.56)))
    return CraftParts(body: body, propGroup: prop.group, blades: prop.blades,
                      blurDisc: prop.disc, fanGroups: [], heatWash: [],
                      beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      navNodes: kit.navs, scalingHalos: kit.halos, contactShadow: shadow,
                      landingLight: kit.light, landingGlow: kit.glow, gear: [],
                      smokeOffset: SCNVector3(0, 0.24, -0.10),
                      gearContacts: live.gearContacts, wheels: live.wheels, oleos: live.oleos,
                      ailerons: live.ailerons, elevator: live.elevator,
                      rudder: live.rudder, flaps: live.flaps)
}

// MARK: - Beechcraft Baron 58 (low-wing piston TWIN, retractable gear)

/// baron58 — cabin-class piston twin: LOW cantilever wing (no struts) carrying
/// two engine nacelles that project AHEAD of the leading edge, each with its own
/// 3-blade prop + pointed spinner; a long nose (nose baggage) and a stretched
/// 6-seat cabin showing FOUR side windows per side; a tall, boldly aft-SWEPT
/// vertical fin (Debonair-derived — the family signature); RETRACTABLE tricycle
/// gear (mains fold aft/inboard into the nacelles, nose folds forward). span
/// 11.53 m, len 9.09 m, height 2.79. Mirrors buildVela + buildPropLive for the
/// low-wing rig, adds two wing nacelles/props (each prop spins in place — see the
/// engine-2 mirror constraint below), and retractable liveGearLeg mains.
func buildBaron58(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 1.06
    // Wing geometry knobs reused by the airframe shell AND the live parts.
    let wingY: Float = 0.74
    let wingTE_Z: Float = 0.15
    let nacX: Float = 1.80            // nacelle centerline |x| (~0.31 span)
    let nacFront: Float = -2.95       // prop plane z (nacelle nose, well ahead of LE)
    let mainZ: Float = 0.55           // main-gear contact z (folds into nacelle)

    let airframe = AirframeCache.airframe(kind: .baron58, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
        let nacMat = pbrMaterial(pal.body, roughness: max(0.12, pal.roughness - 0.04),
                                 metalness: min(1, pal.metalness + 0.1))

        // Fuselage: 9.09 m (nose −4.30, tail +4.79). LONG, low, sleek cabin-class
        // tube — a lengthened forward fuselage (nose baggage) gives the long-nosed
        // look, then a stretched cabin and a smoothly tapering upswept tailcone.
        let fus = latheNode([(-4.30, 0.11), (-4.12, 0.40), (-3.35, 0.60), (-2.20, 0.73),
                             (-0.95, 0.78), (0.30, 0.75), (1.60, 0.58), (2.95, 0.36),
                             (4.10, 0.15), (4.79, 0.04)],
                            material: fuselageMaterial(kind: .baron58, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Cabin greenhouse — a long row hinting at the stretched 58's FOUR side
        // windows per side (vs three on the 55).
        let cabin = SCNNode(geometry: SCNBox(width: 1.1, height: 0.5, length: 1.7, chamferRadius: 0.14))
        cabin.geometry?.materials = [canopyGlassMaterial()]
        cabin.position = SCNVector3(0, 1.50, -1.15)
        root.addChildNode(cabin)
        // Aft club-cabin window band (the rear pair of the four windows, over the
        // reversible club seating / double rear doors).
        let rearWindow = SCNNode(geometry: SCNBox(width: 1.02, height: 0.30, length: 1.05, chamferRadius: 0.1))
        rearWindow.geometry?.materials = [canopyGlassMaterial()]
        rearWindow.position = SCNVector3(0, 1.46, 0.45)
        root.addChildNode(rearWindow)

        // Low cantilever wing — span 11.53, straight-tapered (more taper outer),
        // slight LE sweep. NO struts. Root TE at z 0.15.
        let wing = wingNode(span: 11.53, rootChord: 1.65, tipChord: 0.95, sweep: 0.2,
                            thickness: 0.15, material: bodyMat)
        wing.position = SCNVector3(0, wingY, wingTE_Z)
        root.addChildNode(wing)
        // Squared tips raised to read the ~6° dihedral of the clean Beech wing.
        if let tip = pal.wingtip {
            let tm = pbrMaterial(tip, roughness: pal.roughness)
            for x in [Float(-5.67), Float(5.67)] {
                let cap = SCNNode(geometry: SCNBox(width: 0.22, height: 0.15, length: 0.97, chamferRadius: 0.04))
                cap.geometry?.materials = [tm]
                cap.position = SCNVector3(x, wingY + 0.18, -0.35)
                root.addChildNode(cap)
            }
        }

        // Two engine nacelles faired into the wing LE, projecting WELL FORWARD of
        // it to a spinner. The static SHELL (cowl + aft fairing the mains retract
        // into) lives here; the spinning prop is live (below). Nacelle spans z
        // −2.95 (cowl nose, ahead of the LE at ~−1.5) → +1.15 (tail fairing over
        // the wheel well).
        for s in [Float(-1), Float(1)] {
            let nac = latheNode([(-2.95, 0.13), (-2.80, 0.32), (-2.30, 0.42), (-1.35, 0.45),
                                 (-0.10, 0.44), (0.60, 0.36), (1.15, 0.16)],
                                segments: 20, material: nacMat)
            nac.position = SCNVector3(nacX * s, wingY - 0.04, 0)
            root.addChildNode(nac)
            // Polished spinner backplate collar at the prop plane.
            let collar = latheNode([(-2.98, 0.05), (-2.92, 0.16), (-2.84, 0.22)],
                                   segments: 16, material: nacMat)
            collar.position = SCNVector3(nacX * s, wingY - 0.04, 0)
            root.addChildNode(collar)
        }

        // Tall, boldly aft-SWEPT vertical fin — the Debonair/Bonanza-derived tail
        // (LE swept ~40°+): a high, strongly raked fin, the standout silhouette.
        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0.06, y: 0))
        finPath.addLine(to: CGPoint(x: 0.95, y: 1.48))
        finPath.addQuadCurve(to: CGPoint(x: 1.40, y: 1.56), controlPoint: CGPoint(x: 1.08, y: 1.60))
        finPath.addQuadCurve(to: CGPoint(x: 2.55, y: 0.0), controlPoint: CGPoint(x: 2.05, y: 0.55))
        finPath.close()
        let fin = finNode(path: finPath, thickness: 0.12, material: tailMat)
        fin.position = SCNVector3(0, 1.18, 4.28)
        root.addChildNode(fin)

        // Low straight tailplane with slight taper (conventional — NOT V-tail).
        let stab = wingNode(span: 4.2, rootChord: 1.05, tipChord: 0.6, sweep: 0.24,
                            thickness: 0.09, material: bodyMat)
        stab.position = SCNVector3(0, 1.20, 4.30)
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
    // Elevator — one slab spanning the stab trailing edge. Stab node is at z 4.30
    // (its TE), so the elevator hinges there.
    var elevator: [Surface] = []
    let elev = hingedSurfaceNode(span: 4.2, chord: 0.34, thickness: 0.08, material: surfBodyMat)
    elev.position = SCNVector3(0, 1.20, 4.30)
    elevator.append(Surface(node: elev, sign: 1))
    body.addChildNode(elev)
    // Rudder — hinged at the swept fin's trailing edge (finNode TE near node.z 4.28).
    var rudder: [Surface] = []
    let rud = hingedRudderNode(height: 1.42, chord: 0.32, thickness: 0.11, material: tailMat)
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

    // Nose gear: pivot → live wheel on a live oleo strut, folds forward into the
    // belly under the cockpit (well aft of the long nose baggage bay).
    let noseLeg = liveGearLeg(topY: 0.72, wheelRadius: 0.20, wheelWidth: 0.12,
                              strutRadius: 0.035, travel: 0.08,
                              tire: tire, hub: hub, strut: strutMat)
    let nosePivot = SCNNode()
    nosePivot.position = SCNVector3(0, 0, -2.55)
    nosePivot.addChildNode(noseLeg.leg)
    body.addChildNode(nosePivot)
    wheels.append((noseLeg.wheel, 0.20))
    gear.append((nosePivot, SCNVector3(1.7, 0, 0)))   // folds forward into the belly

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

    let shadow = makeContactShadow(span: 11.53, length: 9.09)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-5.72, 0.98, -0.35),
        navRight: SCNVector3(5.72, 0.98, -0.35),
        tail: SCNVector3(0, 1.18, 4.74),
        beacon: SCNVector3(0, 2.60, 3.95),
        landing: SCNVector3(0, 0.74, -4.20)))
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
