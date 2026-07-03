import Foundation
import SceneKit
import UIKit

// =============================================================================
// Regional / light-jet airframes — two fully-rigged jet builds that graduate
// off the buildComet placeholder:
//   buildPhenom300 → phenom300 (Embraer Phenom 300): light jet, low wing, two
//     REAR-FUSELAGE turbofans, T-tail, retractable gear. A scaled-down Comet:
//     span 15.9 m, length 15.6 m (vs Comet 21.0 / 20.9).
//   buildE175 → e175 (Embraer E175): regional jet, low wing, two UNDER-WING
//     turbofans on pylons, CONVENTIONAL low tail (fin + low horizontal stab, NOT
//     a T-tail), retractable gear. span 26.0 m, length 31.7 m.
//
// Both mirror buildComet's rig EXACTLY (makeFanGroup per nacelle, makeHeatWash,
// hinged surfaces, live retractable gear, makeLightKit, makeContactShadow); the
// only differences are geometry placement — where the nacelles hang and where
// the horizontal stab lives. Static shell → AirframeCache; live parts stay out.
//
// Model space matches the rest of the fleet: node origin = ground contact
// (bottom of tires), nose = −Z, tail = +Z.
// =============================================================================

// MARK: - Phenom 300 (light jet, T-tail, aft-fuselage engines)

/// phenom300 — low swept wing, aft twin fuselage nacelles, T-tail, retractable
/// gear. Structurally a scaled-down Challenger 350 (buildComet); every landmark
/// scaled to the Phenom's 15.6 m length / 15.9 m span from Comet's 20.9 / 21.0.
func buildPhenom300(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 1.55  // fuselage centerline height (smaller than Comet's 1.95)

    let airframe = AirframeCache.airframe(kind: .phenom300, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let accentMat = pbrMaterial(pal.accent, roughness: 0.25, metalness: 0.7)

        // Phenom 300 proportions — 15.6 m nose-to-tail (Comet lathe × ~0.746).
        let fus = latheNode([(-7.75, 0.08), (-7.55, 0.38), (-6.85, 0.64), (-5.70, 0.80),
                             (-3.80, 0.86), (1.65, 0.86), (4.00, 0.76), (5.75, 0.58),
                             (7.05, 0.34), (7.85, 0.09)],
                            segments: 32,
                            material: fuselageMaterial(kind: .phenom300, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Raked windscreen cap.
        let screen = SCNNode(geometry: SCNSphere(radius: 0.5))
        (screen.geometry as? SCNSphere)?.segmentCount = 24
        screen.geometry?.materials = [canopyGlassMaterial()]
        screen.scale = SCNVector3(0.78, 0.5, 1.15)
        screen.position = SCNVector3(0, 2.02, -6.0)
        root.addChildNode(screen)

        // Low swept wing — 15.9 m span incl. winglets. Planform 14.9 m + 0.5 m
        // canted winglet reach per side.
        let wing = wingNode(span: 14.9, rootChord: 2.6, tipChord: 0.8, sweep: 2.0,
                            thickness: 0.20, material: bodyMat)
        wing.position = SCNVector3(0, 0.85, 1.7)
        root.addChildNode(wing)

        // Canted winglets — ~0.85 m tall, outboard cant (Phenom's signature).
        for s in [Float(-1), Float(1)] {
            let wp = UIBezierPath()
            wp.move(to: CGPoint(x: 0, y: 0))
            wp.addLine(to: CGPoint(x: 0.18, y: 0.80))
            wp.addQuadCurve(to: CGPoint(x: 0.44, y: 0.86), controlPoint: CGPoint(x: 0.28, y: 0.90))
            wp.addQuadCurve(to: CGPoint(x: 0.82, y: 0.0), controlPoint: CGPoint(x: 0.70, y: 0.24))
            wp.close()
            let wl = finNode(path: wp, thickness: 0.045, material: bodyMat)
            let cant = SCNNode()
            cant.position = SCNVector3(7.45 * s, 0.95, 1.35)
            cant.eulerAngles.z = -0.52 * s
            cant.addChildNode(wl)
            root.addChildNode(cant)
        }

        // Aft fuselage-mounted nacelles + pylons.
        let nacMat = pbrMaterial(pal.body, roughness: max(0.12, pal.roughness - 0.06),
                                 metalness: min(1, pal.metalness + 0.15))
        let intakeMat = pbrMaterial(UIColor(white: 0.05, alpha: 1), roughness: 0.4)
        for s in [Float(-1), Float(1)] {
            let nac = latheNode([(-1.30, 0.12), (-1.20, 0.33), (-0.85, 0.42), (-0.15, 0.44),
                                 (0.67, 0.39), (1.18, 0.22), (1.38, 0.09)],
                                segments: 20, material: nacMat)
            nac.position = SCNVector3(1.28 * s, 2.02, 4.35)
            root.addChildNode(nac)
            let intake = SCNNode(geometry: SCNCylinder(radius: 0.31, height: 0.04))
            intake.geometry?.materials = [intakeMat]
            intake.eulerAngles.x = .pi / 2
            intake.position = SCNVector3(1.28 * s, 2.02, 3.08)
            root.addChildNode(intake)
            // Near-flat stub pylon rooted at the fuselage shoulder.
            let pylon = SCNNode(geometry: SCNBox(width: 0.11, height: 0.42, length: 1.3, chamferRadius: 0.04))
            pylon.geometry?.materials = [bodyMat]
            pylon.eulerAngles.z = 0.25 * s
            pylon.position = SCNVector3(1.0 * s, 1.86, 4.30)
            root.addChildNode(pylon)
        }

        // T-tail.
        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0.08, y: 0))
        finPath.addLine(to: CGPoint(x: 0.42, y: 2.48))
        finPath.addQuadCurve(to: CGPoint(x: 1.20, y: 2.58), controlPoint: CGPoint(x: 0.72, y: 2.64))
        finPath.addQuadCurve(to: CGPoint(x: 2.02, y: 0.22), controlPoint: CGPoint(x: 1.72, y: 1.12))
        finPath.addQuadCurve(to: CGPoint(x: 2.55, y: 0.0), controlPoint: CGPoint(x: 2.25, y: 0.05))
        finPath.close()
        let fin = finNode(path: finPath, thickness: 0.16, material: bodyMat)
        fin.position = SCNVector3(0, 1.95, 7.35)
        root.addChildNode(fin)
        let stab = wingNode(span: 4.8, rootChord: 1.15, tipChord: 0.6, sweep: 0.6,
                            thickness: 0.11, material: bodyMat)
        stab.position = SCNVector3(0, 4.55, 7.1)
        root.addChildNode(stab)
        if livery == .meridianVIP {
            let crest = SCNNode(geometry: SCNBox(width: 0.20, height: 0.48, length: 0.34, chamferRadius: 0.06))
            crest.geometry?.materials = [accentMat]
            crest.position = SCNVector3(0, 3.75, 6.55)
            root.addChildNode(crest)
        }
        return root
    }

    let body = SCNNode()
    body.addChildNode(airframe)

    // Live turbofans + a warm heat-wash behind each nacelle. The nacelle SHELL
    // is baked in the cache; only the spinning fan + blur disc are live here.
    // Nacelle intake face sits near z 3.08, centerline x ±1.28, y 2.02.
    var fanGroups: [FanGroup] = []
    var heatWashes: [SCNNode] = []
    for s in [Float(-1), Float(1)] {
        let fan = makeFanGroup(at: SCNVector3(1.28 * s, 2.02, 3.06), radius: 0.30)
        body.addChildNode(fan.group)
        fanGroups.append(fan.fan)
        // Warm wash just aft of the exhaust (nacelle tail ~ z 5.7).
        let wash = makeHeatWash(at: SCNVector3(1.28 * s, 2.02, 6.0), size: 1.3)
        body.addChildNode(wash)
        heatWashes.append(wash)
    }

    // Live control surfaces (jet). wingNode origin = ROOT TRAILING EDGE (z 1.7);
    // near-straight TE, TE_z(x) ≈ 1.7 + 2.0·|x|/7.45.
    let surfBodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
    var ailerons: [Surface] = []
    var flaps: [Surface] = []
    for s in [Float(-1), Float(1)] {
        // Aileron centered at |x| 5.0 → TE_z ≈ 1.7 + 2.0·5.0/7.45 ≈ 3.04.
        let a = hingedSurfaceNode(span: 2.0, chord: 0.5, thickness: 0.10, material: surfBodyMat)
        a.position = SCNVector3(s * 5.0, 0.85, 3.04)
        ailerons.append(Surface(node: a, sign: s))
        body.addChildNode(a)
        // Flap centered at |x| 2.0 → TE_z ≈ 1.7 + 2.0·2.0/7.45 ≈ 2.24.
        let fl = hingedSurfaceNode(span: 2.3, chord: 0.55, thickness: 0.10, material: surfBodyMat)
        fl.position = SCNVector3(s * 2.0, 0.85, 2.24)
        flaps.append(Surface(node: fl, sign: 1))
        body.addChildNode(fl)
    }
    // T-tail elevator: stab (wingNode) root TE is at z 7.1, y 4.55 — hinge the
    // elevator ON that trailing edge so it reads as the stab's moving portion.
    var elevator: [Surface] = []
    let elev = hingedSurfaceNode(span: 4.2, chord: 0.42, thickness: 0.09, material: surfBodyMat)
    elev.position = SCNVector3(0, 4.55, 7.1)
    elevator.append(Surface(node: elev, sign: 1))
    body.addChildNode(elev)
    // finNode extends FORWARD (+x = −Z), so the fin's trailing edge sits near
    // z 7.43 — hinge the rudder there, not aft of the whole fin.
    var rudder: [Surface] = []
    let rud = hingedRudderNode(height: 2.2, chord: 0.55, thickness: 0.14, material: surfBodyMat)
    rud.position = SCNVector3(0, 1.95, 7.43)
    rudder.append(Surface(node: rud, sign: 1))
    body.addChildNode(rud)

    // Retractable gear — live wheels + a real oleo on the mains.
    let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
    let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)
    let strutMat = pbrMaterial(UIColor(white: 0.75, alpha: 1), roughness: 0.35, metalness: 0.7)

    var wheels: [(node: SCNNode, radius: Float)] = []
    var oleos: [(node: SCNNode, restY: Float, travel: Float)] = []

    /// Build a pivot → oleo → (strut + live wheels). Static strut is flattened;
    /// wheels stay live under the oleo.
    func gearLeg(pivotAt: SCNVector3, strutLen: Float, wheelRadius: CGFloat,
                 wheelWidth: CGFloat, twin: Bool, oleoTravel: Float)
        -> (pivot: SCNNode, oleo: SCNNode, wheels: [SCNNode]) {
        let pivot = SCNNode()
        pivot.position = pivotAt
        let oleo = SCNNode()
        let strut = strutNode(from: SCNVector3(0, 0, 0), to: SCNVector3(0, -strutLen, 0),
                              radius: 0.045, material: strutMat)
        oleo.addChildNode(strut.flattenedClone())
        var ws: [SCNNode] = []
        let xs: [Float] = twin ? [-0.10, 0.10] : [0]
        for x in xs {
            let w = wheelNode(radius: wheelRadius, width: wheelWidth, tire: tire, hub: hub)
            w.position = SCNVector3(x, -strutLen, 0)
            oleo.addChildNode(w)
            ws.append(w)
        }
        pivot.addChildNode(oleo)
        _ = oleoTravel
        return (pivot, oleo, ws)
    }

    let nose = gearLeg(pivotAt: SCNVector3(0, 0.92, -5.5), strutLen: 0.66,
                       wheelRadius: 0.24, wheelWidth: 0.09, twin: true, oleoTravel: 0.05)
    body.addChildNode(nose.pivot)
    for w in nose.wheels { wheels.append((w, 0.24)) }

    var gear: [(node: SCNNode, foldedEuler: SCNVector3)] =
        [(nose.pivot, SCNVector3(1.7, 0, 0))]  // folds forward into the nose
    var gearContacts: [SCNVector3] = []
    for s in [Float(-1), Float(1)] {
        let main = gearLeg(pivotAt: SCNVector3(1.5 * s, 0.78, 1.15), strutLen: 0.44,
                           wheelRadius: 0.34, wheelWidth: 0.24, twin: false, oleoTravel: 0.09)
        body.addChildNode(main.pivot)
        gear.append((main.pivot, SCNVector3(0, 0, 1.85 * -s)))  // mains fold inboard
        for w in main.wheels { wheels.append((w, 0.34)) }
        oleos.append((main.oleo, 0, 0.09))
        // Contact patch at ground level (pivot y 0.78 − strut 0.44 − radius 0.34 ≈ 0).
        gearContacts.append(SCNVector3(1.5 * s, 0, 1.15))
    }

    let shadow = makeContactShadow(span: 15.9, length: 15.6)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-7.45, 0.95, 1.4),
        navRight: SCNVector3(7.45, 0.95, 1.4),
        tail: SCNVector3(0, 1.80, 7.9),
        beacon: SCNVector3(0, 2.55, -0.8),
        landing: SCNVector3(0, 1.10, -7.6)))
    return CraftParts(body: body, propGroup: nil, blades: nil, blurDisc: nil,
                      fanGroups: fanGroups, heatWash: heatWashes,
                      beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      navNodes: kit.navs, scalingHalos: kit.halos, contactShadow: shadow,
                      landingLight: kit.light, landingGlow: kit.glow, gear: gear,
                      smokeOffset: SCNVector3(0, 0.4, 1.15),
                      gearContacts: gearContacts, wheels: wheels, oleos: oleos,
                      ailerons: ailerons, elevator: elevator, rudder: rudder, flaps: flaps)
}

// MARK: - E175 (regional jet, under-wing engines, conventional low tail)

/// e175 — low swept wing with UNDER-WING turbofans on pylons, a CONVENTIONAL low
/// tail (fin + low horizontal stab, NOT a T-tail), retractable gear. Mirrors
/// buildComet's rig but relocates the nacelles below the wing and puts the stab
/// low on the aft fuselage. span 26.0 m, length 31.7 m — Altair Express regional.
func buildE175(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 2.15  // fuselage centerline height

    let airframe = AirframeCache.airframe(kind: .e175, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let accentMat = pbrMaterial(pal.accent, roughness: 0.25, metalness: 0.7)

        // E175 proportions — 31.7 m nose-to-tail, wider tube than the bizjets.
        let fus = latheNode([(-15.85, 0.10), (-15.55, 0.55), (-14.40, 0.98), (-12.30, 1.28),
                             (-8.30, 1.42), (6.20, 1.42), (9.60, 1.30), (12.40, 1.02),
                             (14.60, 0.58), (15.85, 0.14)],
                            segments: 32,
                            material: fuselageMaterial(kind: .e175, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Raked windscreen cap.
        let screen = SCNNode(geometry: SCNSphere(radius: 0.82))
        (screen.geometry as? SCNSphere)?.segmentCount = 24
        screen.geometry?.materials = [canopyGlassMaterial()]
        screen.scale = SCNVector3(0.80, 0.5, 1.2)
        screen.position = SCNVector3(0, 2.95, -12.5)
        root.addChildNode(screen)

        // Low swept wing — 26.0 m span incl. winglets. Planform 24.7 m + 0.65 m
        // canted winglet reach per side.
        let wing = wingNode(span: 24.7, rootChord: 4.3, tipChord: 1.2, sweep: 3.4,
                            thickness: 0.30, material: bodyMat)
        wing.position = SCNVector3(0, 1.35, 3.0)
        root.addChildNode(wing)

        // Canted winglets — 1.3 m tall, outboard cant (E175 raked wingtip fence).
        for s in [Float(-1), Float(1)] {
            let wp = UIBezierPath()
            wp.move(to: CGPoint(x: 0, y: 0))
            wp.addLine(to: CGPoint(x: 0.26, y: 1.20))
            wp.addQuadCurve(to: CGPoint(x: 0.62, y: 1.30), controlPoint: CGPoint(x: 0.40, y: 1.34))
            wp.addQuadCurve(to: CGPoint(x: 1.20, y: 0.0), controlPoint: CGPoint(x: 1.02, y: 0.34))
            wp.close()
            let wl = finNode(path: wp, thickness: 0.055, material: bodyMat)
            let cant = SCNNode()
            cant.position = SCNVector3(12.35 * s, 1.45, 2.35)
            cant.eulerAngles.z = -0.50 * s
            cant.addChildNode(wl)
            root.addChildNode(cant)
        }

        // UNDER-WING nacelles on pylons hung BELOW the wing. Wing at y 1.35;
        // nacelles centered at y 0.55 (slung under), forward of the wing LE so
        // the intake pokes ahead of the leading edge.
        let nacMat = pbrMaterial(pal.body, roughness: max(0.12, pal.roughness - 0.06),
                                 metalness: min(1, pal.metalness + 0.15))
        let intakeMat = pbrMaterial(UIColor(white: 0.05, alpha: 1), roughness: 0.4)
        // Wing LE at the nacelle station (|x| 4.6): TE at wing.z + tip sweep is
        // aft; LE_z(x) ≈ wing.z − rootChord + sweep·|x|/12.35.
        for s in [Float(-1), Float(1)] {
            let nac = latheNode([(-2.05, 0.20), (-1.90, 0.52), (-1.35, 0.66), (-0.25, 0.68),
                                 (1.05, 0.60), (1.85, 0.34), (2.10, 0.14)],
                                segments: 22, material: nacMat)
            nac.position = SCNVector3(4.6 * s, 0.55, -0.30)
            root.addChildNode(nac)
            let intake = SCNNode(geometry: SCNCylinder(radius: 0.50, height: 0.04))
            intake.geometry?.materials = [intakeMat]
            intake.eulerAngles.x = .pi / 2
            intake.position = SCNVector3(4.6 * s, 0.55, -2.30)
            root.addChildNode(intake)
            // Pylon: vertical strut linking the nacelle up to the wing underside.
            let pylon = SCNNode(geometry: SCNBox(width: 0.20, height: 0.85, length: 1.5, chamferRadius: 0.05))
            pylon.geometry?.materials = [bodyMat]
            pylon.position = SCNVector3(4.6 * s, 1.05, -0.55)
            root.addChildNode(pylon)
        }

        // CONVENTIONAL low tail: swept fin + a LOW horizontal stab mounted on the
        // aft fuselage (NOT a T-tail).
        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0.12, y: 0))
        finPath.addLine(to: CGPoint(x: 0.70, y: 4.20))
        finPath.addQuadCurve(to: CGPoint(x: 2.05, y: 4.35), controlPoint: CGPoint(x: 1.20, y: 4.45))
        finPath.addQuadCurve(to: CGPoint(x: 3.45, y: 0.35), controlPoint: CGPoint(x: 2.95, y: 1.9))
        finPath.addQuadCurve(to: CGPoint(x: 4.30, y: 0.0), controlPoint: CGPoint(x: 3.85, y: 0.06))
        finPath.close()
        let fin = finNode(path: finPath, thickness: 0.24, material: bodyMat)
        fin.position = SCNVector3(0, 3.05, 14.7)
        root.addChildNode(fin)
        // LOW horizontal stab on the aft fuselage — sits at fuselage-top height,
        // well below the fin tip (conventional tail).
        let stab = wingNode(span: 9.6, rootChord: 2.3, tipChord: 1.0, sweep: 1.3,
                            thickness: 0.20, material: bodyMat)
        stab.position = SCNVector3(0, 3.30, 14.4)
        root.addChildNode(stab)
        if livery == .meridianVIP {
            let crest = SCNNode(geometry: SCNBox(width: 0.34, height: 0.80, length: 0.58, chamferRadius: 0.10))
            crest.geometry?.materials = [accentMat]
            crest.position = SCNVector3(0, 5.6, 13.0)
            root.addChildNode(crest)
        }
        return root
    }

    let body = SCNNode()
    body.addChildNode(airframe)

    // Live turbofans + a warm heat-wash behind each UNDER-WING nacelle. The
    // nacelle SHELL is baked in the cache; only the spinning fan + blur disc are
    // live here. Intake face sits near z −2.30, centerline x ±4.6, y 0.55.
    var fanGroups: [FanGroup] = []
    var heatWashes: [SCNNode] = []
    for s in [Float(-1), Float(1)] {
        let fan = makeFanGroup(at: SCNVector3(4.6 * s, 0.55, -2.32), radius: 0.48)
        body.addChildNode(fan.group)
        fanGroups.append(fan.fan)
        // Warm wash just aft of the exhaust (nacelle tail ~ z 1.65).
        let wash = makeHeatWash(at: SCNVector3(4.6 * s, 0.55, 2.0), size: 2.0)
        body.addChildNode(wash)
        heatWashes.append(wash)
    }

    // Live control surfaces (jet). wingNode origin = ROOT TRAILING EDGE (z 3.0);
    // near-straight TE, TE_z(x) ≈ 3.0 + 3.4·|x|/12.35.
    let surfBodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
    var ailerons: [Surface] = []
    var flaps: [Surface] = []
    for s in [Float(-1), Float(1)] {
        // Aileron centered at |x| 8.4 → TE_z ≈ 3.0 + 3.4·8.4/12.35 ≈ 5.31.
        let a = hingedSurfaceNode(span: 3.2, chord: 0.75, thickness: 0.14, material: surfBodyMat)
        a.position = SCNVector3(s * 8.4, 1.35, 5.31)
        ailerons.append(Surface(node: a, sign: s))
        body.addChildNode(a)
        // Flap centered at |x| 3.6 → TE_z ≈ 3.0 + 3.4·3.6/12.35 ≈ 3.99.
        let fl = hingedSurfaceNode(span: 3.8, chord: 0.9, thickness: 0.14, material: surfBodyMat)
        fl.position = SCNVector3(s * 3.6, 1.35, 3.99)
        flaps.append(Surface(node: fl, sign: 1))
        body.addChildNode(fl)
    }
    // Conventional-tail elevator: stab (wingNode) root TE is at z 14.4, y 3.30 —
    // hinge the elevator ON that trailing edge (low, not on the fin top).
    var elevator: [Surface] = []
    let elev = hingedSurfaceNode(span: 9.0, chord: 0.85, thickness: 0.14, material: surfBodyMat)
    elev.position = SCNVector3(0, 3.30, 14.4)
    elevator.append(Surface(node: elev, sign: 1))
    body.addChildNode(elev)
    // finNode extends FORWARD (+x = −Z), so the fin's trailing edge sits near
    // z 14.82 — hinge the rudder there, not aft of the whole fin.
    var rudder: [Surface] = []
    let rud = hingedRudderNode(height: 3.7, chord: 0.9, thickness: 0.20, material: surfBodyMat)
    rud.position = SCNVector3(0, 3.05, 14.82)
    rudder.append(Surface(node: rud, sign: 1))
    body.addChildNode(rud)

    // Retractable gear — live wheels + a real oleo on the mains.
    let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
    let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)
    let strutMat = pbrMaterial(UIColor(white: 0.75, alpha: 1), roughness: 0.35, metalness: 0.7)

    var wheels: [(node: SCNNode, radius: Float)] = []
    var oleos: [(node: SCNNode, restY: Float, travel: Float)] = []

    /// Build a pivot → oleo → (strut + live wheels). Static strut is flattened;
    /// wheels stay live under the oleo.
    func gearLeg(pivotAt: SCNVector3, strutLen: Float, wheelRadius: CGFloat,
                 wheelWidth: CGFloat, twin: Bool, oleoTravel: Float)
        -> (pivot: SCNNode, oleo: SCNNode, wheels: [SCNNode]) {
        let pivot = SCNNode()
        pivot.position = pivotAt
        let oleo = SCNNode()
        let strut = strutNode(from: SCNVector3(0, 0, 0), to: SCNVector3(0, -strutLen, 0),
                              radius: 0.075, material: strutMat)
        oleo.addChildNode(strut.flattenedClone())
        var ws: [SCNNode] = []
        let xs: [Float] = twin ? [-0.16, 0.16] : [-0.16, 0.16]
        for x in xs {
            let w = wheelNode(radius: wheelRadius, width: wheelWidth, tire: tire, hub: hub)
            w.position = SCNVector3(x, -strutLen, 0)
            oleo.addChildNode(w)
            ws.append(w)
        }
        pivot.addChildNode(oleo)
        _ = oleoTravel
        return (pivot, oleo, ws)
    }

    let nose = gearLeg(pivotAt: SCNVector3(0, 1.30, -11.6), strutLen: 0.98,
                       wheelRadius: 0.36, wheelWidth: 0.13, twin: true, oleoTravel: 0.06)
    body.addChildNode(nose.pivot)
    for w in nose.wheels { wheels.append((w, 0.36)) }

    var gear: [(node: SCNNode, foldedEuler: SCNVector3)] =
        [(nose.pivot, SCNVector3(1.7, 0, 0))]  // folds forward into the nose
    var gearContacts: [SCNVector3] = []
    for s in [Float(-1), Float(1)] {
        // Mains carry a twin bogie (two wheels per leg) on the wing box.
        let main = gearLeg(pivotAt: SCNVector3(2.7 * s, 1.10, 3.4), strutLen: 0.58,
                           wheelRadius: 0.52, wheelWidth: 0.26, twin: true, oleoTravel: 0.12)
        body.addChildNode(main.pivot)
        gear.append((main.pivot, SCNVector3(0, 0, 1.85 * -s)))  // mains fold inboard
        for w in main.wheels { wheels.append((w, 0.52)) }
        oleos.append((main.oleo, 0, 0.12))
        // Contact patch at ground level (pivot y 1.10 − strut 0.58 − radius 0.52 ≈ 0).
        gearContacts.append(SCNVector3(2.7 * s, 0, 3.4))
    }

    let shadow = makeContactShadow(span: 26.0, length: 31.7)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-12.35, 1.45, 2.4),
        navRight: SCNVector3(12.35, 1.45, 2.4),
        tail: SCNVector3(0, 2.90, 15.7),
        beacon: SCNVector3(0, 3.55, -1.4),
        landing: SCNVector3(0, 1.55, -15.4)))
    return CraftParts(body: body, propGroup: nil, blades: nil, blurDisc: nil,
                      fanGroups: fanGroups, heatWash: heatWashes,
                      beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      navNodes: kit.navs, scalingHalos: kit.halos, contactShadow: shadow,
                      landingLight: kit.light, landingGlow: kit.glow, gear: gear,
                      smokeOffset: SCNVector3(0, 0.6, 3.4),
                      gearContacts: gearContacts, wheels: wheels, oleos: oleos,
                      ailerons: ailerons, elevator: elevator, rudder: rudder, flaps: flaps)
}
