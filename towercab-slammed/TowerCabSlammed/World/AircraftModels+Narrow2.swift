import Foundation
import SceneKit
import UIKit

// =============================================================================
// Second narrowbody wave — four more fully-rigged, to-scale airliner builds that
// graduate off the buildComet placeholder. Three are UNDER-WING twins with a
// CONVENTIONAL swept tail (built through a self-contained AirlinerSpec2 / build-
// Airliner2 pair that mirrors AircraftModels+Airliner.swift's private builder,
// since that one is file-private); the fourth is a REAR-FUSELAGE-engined T-tail
// jet (built the buildComet / buildPhenom300 way).
//
//   buildA319 → a319  (Airbus A319: span 35.8 m > length 33.84 m — the stubby
//     short-A320 whose WING is wider than the body is long; OVERSIZED-looking
//     tall fin; blade SHARKLETS; two under-wing CFM/V2500 nacelles; conventional
//     low tail; twin-wheel mains sitting fairly low.)
//   buildA321 → a321  (Airbus A321: the STRETCHED A320 — length 44.51 m ≫ span
//     35.8 m, a long slender pencil where the SAME family wing + fin now look
//     PROPORTIONALLY SMALL; sharklets; two under-wing nacelles; conventional low
//     tail; beefier twin-wheel mains.)
//   buildB757 → b757  (Boeing 757-200: long slender 47.32 m body with a pointed,
//     DROOPED nose and a long upswept tailcone; TALL stalky main gear on FOUR-
//     wheel bogies — its signature ramp stance; two BIG under-wing turbofans;
//     tall conventional tail; big blended winglets.)
//   buildMD80 → md80  (McDonnell Douglas MD-80: the definitive long-thin tube —
//     45.06 m on a 32.87 m span; TWO engines on the REAR fuselage, clean wing;
//     T-TAIL atop a tall fin; flat "beaver" chisel tailcone; twin-wheel mains;
//     low, close-to-the-tarmac stance; NO winglets.)
//
// Model space matches the rest of the fleet: node origin = ground contact
// (bottom of tires), nose = −Z, tail = +Z. Static shell → AirframeCache; live
// parts (fans / heat-wash / surfaces / wheels / oleos / lights) stay OUT of the
// cache and are added onto `body`, exactly as buildComet does.
// =============================================================================

// MARK: - Under-wing airliner spec (self-contained twin of the private one)

/// Every dimension needed to stamp a to-scale UNDER-WING airliner with a
/// CONVENTIONAL swept tail. All lengths in metres, model space (nose −Z, tail
/// +Z, y = height above the tire contact patch). This mirrors the file-private
/// `AirlinerSpec` in AircraftModels+Airliner.swift so the A319/A321/B757 share
/// one builder here.
private struct AirlinerSpec2 {
    let kind: AircraftKind

    // Fuselage lathe profile [(z, radius)]; `cy` lifts the tube to clear gear.
    let fuselage: [(z: Float, r: Float)]
    let cy: Float
    let fuseSegments: Int

    // Flight-deck windscreen cap (dark glass ellipsoid over the nose).
    let screenScale: SCNVector3
    let screenPos: SCNVector3

    // Low main wing (wingNode: origin = root TE, extends forward −Z).
    let wingSpan: CGFloat
    let wingRootChord: CGFloat
    let wingTipChord: CGFloat
    let wingSweep: CGFloat
    let wingThickness: CGFloat
    let wingY: Float
    let wingTE_Z: Float

    // Wingtip device (sharklet / blended winglet). `cant` = z-roll radians,
    // `height` in metres, `chordFwd` = device root chord.
    let wingHalfSpan: Float
    let tipHeight: CGFloat
    let tipChordFwd: CGFloat
    let tipCant: Float

    // Under-wing engines: |x| stations for ONE side (mirrored via ±).
    let engineXs: [Float]
    let fanRadius: CGFloat
    let nacelleZ: Float
    let nacelleY: Float
    let nacelleLen: Float
    let intakeZ: Float
    let exhaustZ: Float

    // Swept vertical fin (finNode: +x path = forward −Z; TE near node.z).
    let finBaseZ: Float
    let finBaseY: Float
    let finHeight: CGFloat
    let finRootChord: CGFloat
    let finMidChord: CGFloat
    let finThickness: CGFloat

    // Rudder (hingedRudderNode).
    let rudderHeight: CGFloat
    let rudderChord: CGFloat

    // Horizontal stab (wingNode) + elevator (hingedSurfaceNode at stab TE).
    let stabSpan: CGFloat
    let stabRootChord: CGFloat
    let stabTipChord: CGFloat
    let stabSweep: CGFloat
    let stabThickness: CGFloat
    let stabY: Float
    let stabTE_Z: Float

    // Ailerons (outboard) + flaps (inboard), hinged on the near-straight wing TE.
    let ailCenterX: Float, ailSpan: CGFloat, ailChord: CGFloat
    let flapCenterX: Float, flapSpan: CGFloat, flapChord: CGFloat
    let surfThickness: CGFloat

    // Retractable gear. Nose leg + two main legs; big jets carry multi-row bogies.
    let noseZ: Float, nosePivotY: Float, noseStrutLen: Float
    let noseWheelR: CGFloat, noseWheelW: CGFloat
    let mainX: Float, mainZ: Float, mainPivotY: Float, mainStrutLen: Float
    let mainWheelR: CGFloat, mainWheelW: CGFloat
    let mainBogieRows: Int       // wheel pairs fore↔aft per main leg (1 or 2)

    // Light kit anchor points + contact-shadow footprint.
    let light: LightSpec
    let shadowSpan: CGFloat, shadowLen: CGFloat
    let smokeOffset: SCNVector3
}

// MARK: - Shared under-wing airliner builder

/// Assemble a fully-rigged under-wing airliner CraftParts from an AirlinerSpec2,
/// mirroring buildComet's jet wiring: static shell → AirframeCache; live fans /
/// heat-wash / surfaces / gear / lights added onto `body`.
private func buildAirliner2(_ spec: AirlinerSpec2, livery: Livery) -> CraftParts {
    let pal = livery.palette

    let airframe = AirframeCache.airframe(kind: spec.kind, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let nacMat = pbrMaterial(pal.body, roughness: max(0.12, pal.roughness - 0.06),
                                 metalness: min(1, pal.metalness + 0.15))
        let intakeMat = pbrMaterial(UIColor(white: 0.05, alpha: 1), roughness: 0.4)

        // --- Fuselage tube (cabin windows baked into the texture) -------------
        let fus = latheNode(spec.fuselage, segments: spec.fuseSegments,
                            material: fuselageMaterial(kind: spec.kind, livery: livery))
        fus.position.y = spec.cy
        root.addChildNode(fus)

        // Flight-deck windscreen cap.
        let screen = SCNNode(geometry: SCNSphere(radius: 0.9))
        (screen.geometry as? SCNSphere)?.segmentCount = 24
        screen.geometry?.materials = [canopyGlassMaterial()]
        screen.scale = spec.screenScale
        screen.position = spec.screenPos
        root.addChildNode(screen)

        // --- Low swept wing ---------------------------------------------------
        let wing = wingNode(span: spec.wingSpan, rootChord: spec.wingRootChord,
                            tipChord: spec.wingTipChord, sweep: spec.wingSweep,
                            thickness: spec.wingThickness, material: bodyMat)
        wing.position = SCNVector3(0, spec.wingY, spec.wingTE_Z)
        root.addChildNode(wing)

        // Wingtip devices — a swept-back tapering fin canted up off each tip.
        let wingTipLE_Z = spec.wingTE_Z - Float(spec.wingRootChord - spec.wingSweep)
        for s in [Float(-1), Float(1)] {
            let c = Float(spec.tipChordFwd)
            let h = Float(spec.tipHeight)
            let wp = UIBezierPath()
            wp.move(to: CGPoint(x: 0, y: 0))
            wp.addLine(to: CGPoint(x: CGFloat(c * 0.18), y: CGFloat(h)))
            wp.addQuadCurve(to: CGPoint(x: CGFloat(c * 0.55), y: CGFloat(h)),
                            controlPoint: CGPoint(x: CGFloat(c * 0.30), y: CGFloat(h * 1.05)))
            wp.addQuadCurve(to: CGPoint(x: CGFloat(c), y: 0),
                            controlPoint: CGPoint(x: CGFloat(c * 0.9), y: CGFloat(h * 0.3)))
            wp.close()
            let upTip = finNode(path: wp, thickness: spec.wingThickness * 0.42, material: bodyMat)
            let cant = SCNNode()
            cant.position = SCNVector3(spec.wingHalfSpan * s, spec.wingY + 0.02,
                                       wingTipLE_Z + Float(spec.tipChordFwd) * 0.55)
            cant.eulerAngles.z = -spec.tipCant * s
            cant.addChildNode(upTip)
            root.addChildNode(cant)
        }

        // --- Under-wing engines: nacelle shell + pylon (fan stays live) -------
        for s in [Float(-1), Float(1)] {
            for xz in spec.engineXs {
                let x = xz * s
                let half = spec.nacelleLen / 2
                let nac = latheNode([(-half, Float(spec.fanRadius) * 0.42),
                                     (-half * 0.78, Float(spec.fanRadius) * 1.02),
                                     (-half * 0.3, Float(spec.fanRadius) * 1.06),
                                     (half * 0.35, Float(spec.fanRadius) * 0.98),
                                     (half * 0.8, Float(spec.fanRadius) * 0.66),
                                     (half, Float(spec.fanRadius) * 0.34)],
                                    segments: 22, material: nacMat)
                nac.position = SCNVector3(x, spec.nacelleY, spec.nacelleZ)
                root.addChildNode(nac)
                // Dark intake ring at the fan face.
                let intake = SCNNode(geometry: SCNTorus(ringRadius: Double(spec.fanRadius) * 0.92,
                                                        pipeRadius: Double(spec.fanRadius) * 0.10))
                intake.geometry?.materials = [intakeMat]
                intake.eulerAngles.x = .pi / 2
                intake.position = SCNVector3(x, spec.nacelleY, spec.intakeZ)
                root.addChildNode(intake)
                // Pylon linking the nacelle up to the wing underside.
                let pylonLen = spec.wingY - spec.nacelleY + 0.2
                let pylon = SCNNode(geometry: SCNBox(width: 0.16,
                                                     height: CGFloat(max(0.2, pylonLen)),
                                                     length: CGFloat(spec.fanRadius) * 1.6,
                                                     chamferRadius: 0.05))
                pylon.geometry?.materials = [bodyMat]
                pylon.position = SCNVector3(x, spec.nacelleY + pylonLen / 2 - 0.05,
                                            spec.nacelleZ - 0.1)
                root.addChildNode(pylon)
            }
        }

        // --- Conventional swept tail: swept fin + horizontal stab -------------
        let finPath = UIBezierPath()
        let fh = Float(spec.finHeight)
        let frc = Float(spec.finRootChord)
        let fmc = Float(spec.finMidChord)
        finPath.move(to: CGPoint(x: 0.12, y: 0))
        finPath.addLine(to: CGPoint(x: CGFloat(frc * 0.42), y: CGFloat(fh)))
        finPath.addQuadCurve(to: CGPoint(x: CGFloat(fmc * 0.7 + frc * 0.30), y: CGFloat(fh)),
                             controlPoint: CGPoint(x: CGFloat(frc * 0.55), y: CGFloat(fh * 1.03)))
        finPath.addQuadCurve(to: CGPoint(x: CGFloat(frc), y: CGFloat(fh * 0.08)),
                             controlPoint: CGPoint(x: CGFloat(frc * 0.9), y: CGFloat(fh * 0.5)))
        finPath.addLine(to: CGPoint(x: CGFloat(frc), y: 0))
        finPath.close()
        let fin = finNode(path: finPath, thickness: spec.finThickness, material: bodyMat)
        fin.position = SCNVector3(0, spec.finBaseY, spec.finBaseZ)
        root.addChildNode(fin)

        let stab = wingNode(span: spec.stabSpan, rootChord: spec.stabRootChord,
                            tipChord: spec.stabTipChord, sweep: spec.stabSweep,
                            thickness: spec.stabThickness, material: bodyMat)
        stab.position = SCNVector3(0, spec.stabY, spec.stabTE_Z)
        root.addChildNode(stab)

        return root
    }

    let body = SCNNode()
    body.addChildNode(airframe)

    // --- Live turbofans + heat-wash (one FanGroup per engine) ----------------
    var fanGroups: [FanGroup] = []
    var heatWashes: [SCNNode] = []
    for s in [Float(-1), Float(1)] {
        for xz in spec.engineXs {
            let x = xz * s
            let fan = makeFanGroup(at: SCNVector3(x, spec.nacelleY, spec.intakeZ),
                                   radius: spec.fanRadius)
            body.addChildNode(fan.group)
            fanGroups.append(fan.fan)
            let wash = makeHeatWash(at: SCNVector3(x, spec.nacelleY, spec.exhaustZ),
                                    size: spec.fanRadius * 4.2)
            body.addChildNode(wash)
            heatWashes.append(wash)
        }
    }

    // --- Live control surfaces -----------------------------------------------
    let surfMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
    var ailerons: [Surface] = []
    var flaps: [Surface] = []
    // TE_z(x) ≈ wingTE_Z + wingSweep·|x|/wingHalfSpan (near-straight TE).
    let teSlope = Float(spec.wingSweep) / max(0.001, spec.wingHalfSpan)
    for s in [Float(-1), Float(1)] {
        let a = hingedSurfaceNode(span: spec.ailSpan, chord: spec.ailChord,
                                  thickness: spec.surfThickness, material: surfMat)
        a.position = SCNVector3(s * spec.ailCenterX, spec.wingY,
                                spec.wingTE_Z + teSlope * spec.ailCenterX)
        ailerons.append(Surface(node: a, sign: s))
        body.addChildNode(a)
        let fl = hingedSurfaceNode(span: spec.flapSpan, chord: spec.flapChord,
                                   thickness: spec.surfThickness, material: surfMat)
        fl.position = SCNVector3(s * spec.flapCenterX, spec.wingY,
                                 spec.wingTE_Z + teSlope * spec.flapCenterX)
        flaps.append(Surface(node: fl, sign: 1))
        body.addChildNode(fl)
    }
    // Elevator — one slab on the stab trailing edge.
    var elevator: [Surface] = []
    let elev = hingedSurfaceNode(span: spec.stabSpan * 0.92, chord: spec.stabTipChord * 0.7,
                                 thickness: spec.surfThickness, material: surfMat)
    elev.position = SCNVector3(0, spec.stabY, spec.stabTE_Z)
    elevator.append(Surface(node: elev, sign: 1))
    body.addChildNode(elev)
    // Rudder — hinged at the fin trailing edge (near finBaseZ).
    var rudder: [Surface] = []
    let rud = hingedRudderNode(height: spec.rudderHeight, chord: spec.rudderChord,
                               thickness: spec.finThickness, material: surfMat)
    rud.position = SCNVector3(0, spec.finBaseY, spec.finBaseZ)
    rudder.append(Surface(node: rud, sign: 1))
    body.addChildNode(rud)

    // --- Retractable gear: live wheels + real oleos --------------------------
    let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
    let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)
    let strutMat = pbrMaterial(UIColor(white: 0.75, alpha: 1), roughness: 0.35, metalness: 0.7)

    var wheels: [(node: SCNNode, radius: Float)] = []
    var oleos: [(node: SCNNode, restY: Float, travel: Float)] = []
    var gear: [(node: SCNNode, foldedEuler: SCNVector3)] = []
    var gearContacts: [SCNVector3] = []

    /// pivot → oleo → (static strut + live wheels). A bogie lays `rows` wheel
    /// pairs fore↔aft; a single-axle leg is rows == 1 with one pair.
    func gearLeg(pivotAt: SCNVector3, strutLen: Float, strutR: CGFloat,
                 wheelRadius: CGFloat, wheelWidth: CGFloat, rows: Int)
        -> (pivot: SCNNode, oleo: SCNNode, wheels: [SCNNode]) {
        let pivot = SCNNode()
        pivot.position = pivotAt
        let oleo = SCNNode()
        let strut = strutNode(from: SCNVector3(0, 0, 0), to: SCNVector3(0, -strutLen, 0),
                              radius: strutR, material: strutMat)
        oleo.addChildNode(strut.flattenedClone())
        var ws: [SCNNode] = []
        let rowGap = Float(wheelRadius) * 2.2
        let firstZ = -rowGap * Float(rows - 1) / 2
        for r in 0..<rows {
            let z = firstZ + rowGap * Float(r)
            for x in [-Float(wheelWidth) * 0.75, Float(wheelWidth) * 0.75] {
                let w = wheelNode(radius: wheelRadius, width: wheelWidth, tire: tire, hub: hub)
                w.position = SCNVector3(x, -strutLen, z)
                oleo.addChildNode(w)
                ws.append(w)
            }
        }
        pivot.addChildNode(oleo)
        return (pivot, oleo, ws)
    }

    // Nose leg — twin wheels, folds forward into the nose bay.
    let nose = gearLeg(pivotAt: SCNVector3(0, spec.nosePivotY, spec.noseZ),
                       strutLen: spec.noseStrutLen, strutR: 0.06,
                       wheelRadius: spec.noseWheelR, wheelWidth: spec.noseWheelW, rows: 1)
    body.addChildNode(nose.pivot)
    for w in nose.wheels { wheels.append((w, Float(spec.noseWheelR))) }
    gear.append((nose.pivot, SCNVector3(1.6, 0, 0)))

    // Main legs — one per side, each a 1- or 2-row bogie; fold inboard.
    for s in [Float(-1), Float(1)] {
        let x = spec.mainX * s
        let main = gearLeg(pivotAt: SCNVector3(x, spec.mainPivotY, spec.mainZ),
                           strutLen: spec.mainStrutLen, strutR: 0.075,
                           wheelRadius: spec.mainWheelR, wheelWidth: spec.mainWheelW,
                           rows: spec.mainBogieRows)
        body.addChildNode(main.pivot)
        gear.append((main.pivot, SCNVector3(0, 0, 1.7 * -s)))
        for w in main.wheels { wheels.append((w, Float(spec.mainWheelR))) }
        oleos.append((main.oleo, 0, 0.12))
        gearContacts.append(SCNVector3(x, 0, spec.mainZ))
    }

    // --- Shadow + light kit ---------------------------------------------------
    let shadow = makeContactShadow(span: spec.shadowSpan, length: spec.shadowLen)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: spec.light)

    return CraftParts(body: body, propGroup: nil, blades: nil, blurDisc: nil,
                      fanGroups: fanGroups, heatWash: heatWashes,
                      beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      navNodes: kit.navs, scalingHalos: kit.halos, contactShadow: shadow,
                      landingLight: kit.light, landingGlow: kit.glow, gear: gear,
                      smokeOffset: spec.smokeOffset,
                      gearContacts: gearContacts, wheels: wheels, oleos: oleos,
                      ailerons: ailerons, elevator: elevator, rudder: rudder, flaps: flaps)
}

// MARK: - Airbus A319 (narrowbody, 2 engines, sharklets — the STUBBY one)

/// A319 — span 35.8 m, length 33.84 m, height 11.76 m. The short A320-family
/// member whose defining trait is that the WING IS WIDER THAN THE BODY IS LONG:
/// span 35.8 > length 33.84 gives a stubby, "chopped" silhouette. The vertical
/// fin (11.76 m height on a 33.84 m body) looks OVERSIZED. Same round Ø 3.95 m
/// tube (r 1.98) as the whole family, blade SHARKLETS pushing span to 35.8 m,
/// two under-wing nacelles, conventional low tail. Frames removed both fore and
/// aft of the wing ⇒ a nearly symmetric short tube about the wingbox.
func buildA319(livery: Livery) -> CraftParts {
    let cy: Float = 2.15   // A320-family stance (tall on its gear, clear belly gap)
    let r: Float = 1.98    // Ø 3.95 m cabin
    // Fuselage: −16.7 (rounded bulbous Airbus nose) → +17.14 (clean conical
    // tail). Length ≈ 33.84. Constant section is SHORT — the barrel is stubby.
    let fuselage: [(z: Float, r: Float)] = [
        (-16.7, 0.30), (-16.3, 0.82), (-15.4, 1.32), (-13.9, 1.72),
        (-11.9, r), (-3.0, r), (5.5, r), (10.0, r * 0.96),
        (13.7, r * 0.72), (15.9, r * 0.42), (17.14, 0.16)]
    let spec = AirlinerSpec2(
        kind: .a319,
        fuselage: fuselage, cy: cy, fuseSegments: 32,
        // Rounded Airbus windscreen cap high on the short nose.
        screenScale: SCNVector3(0.86, 0.68, 1.05),
        screenPos: SCNVector3(0, cy + 0.98, -14.0),
        // Standard A320-family wing — proportionally LARGE on this short body,
        // set slightly aft of mid-fuselage.
        wingSpan: 34.1, wingRootChord: 6.1, wingTipChord: 1.6, wingSweep: 6.0,
        wingThickness: 0.42, wingY: 1.5, wingTE_Z: 3.6,
        // Blade sharklets (~2.4 m) that carry span from 34.1 → 35.8 m.
        wingHalfSpan: 17.05, tipHeight: 2.4, tipChordFwd: 1.2, tipCant: 1.42,
        // Round inlets; CFM/V2500-class nacelles (smaller than the 757's).
        engineXs: [5.4], fanRadius: 1.0, nacelleZ: -1.8, nacelleY: 1.2,
        nacelleLen: 3.9, intakeZ: -3.4, exhaustZ: 0.9,
        // Oversized-looking TALL fin on the short body.
        finBaseZ: 15.7, finBaseY: cy + 1.4, finHeight: 6.5,
        finRootChord: 4.9, finMidChord: 3.0, finThickness: 0.32,
        rudderHeight: 5.5, rudderChord: 1.4,
        stabSpan: 12.45, stabRootChord: 3.2, stabTipChord: 1.1, stabSweep: 2.2,
        stabThickness: 0.22, stabY: cy + 0.5, stabTE_Z: 15.5,
        ailCenterX: 13.6, ailSpan: 2.8, ailChord: 0.9,
        flapCenterX: 6.4, flapSpan: 6.2, flapChord: 1.6,
        surfThickness: 0.16,
        noseZ: -12.0, nosePivotY: 1.94, noseStrutLen: 1.5,
        noseWheelR: 0.44, noseWheelW: 0.18,
        mainX: 2.6, mainZ: 5.4, mainPivotY: 2.0, mainStrutLen: 1.45,
        mainWheelR: 0.55, mainWheelW: 0.24, mainBogieRows: 1,
        light: LightSpec(
            navLeft: SCNVector3(-17.9, 1.5, 3.0),
            navRight: SCNVector3(17.9, 1.5, 3.0),
            tail: SCNVector3(0, cy + 1.3, 17.1),
            beacon: SCNVector3(0, cy + 1.9, 2.0),
            landing: SCNVector3(0, 1.0, 4.0)),
        shadowSpan: 35.8, shadowLen: 33.84,
        smokeOffset: SCNVector3(0, 0.5, 5.4))
    return buildAirliner2(spec, livery: livery)
}

// MARK: - Airbus A321 (narrowbody, 2 engines, sharklets — the STRETCHED one)

/// A321 — span 35.8 m, length 44.51 m, height 11.76 m. The STRETCHED A320: a
/// long slender pencil where length (44.51) far exceeds span (35.8) — the exact
/// opposite proportion to the A319. The SAME family wing + fin did not grow with
/// the stretch, so both look PROPORTIONALLY SMALL on the long body. Same Ø 3.95 m
/// tube (r 1.98), sharklets, two under-wing nacelles (modelled with the slightly
/// fatter neo-class cowl), conventional low tail, beefier twin-wheel mains.
func buildA321(livery: Livery) -> CraftParts {
    let cy: Float = 2.25   // rides tall on its gear
    let r: Float = 1.98    // Ø 3.95 m cabin (identical family cross-section)
    // Fuselage: −22.0 (same rounded Airbus nose) → +22.51 (clean conical tail).
    // Length ≈ 44.51 — a 4.27 m plug ahead of the wing, 2.67 m behind ⇒ the
    // constant barrel is LONG and uninterrupted.
    let fuselage: [(z: Float, r: Float)] = [
        (-22.0, 0.30), (-21.6, 0.82), (-20.7, 1.32), (-19.2, 1.72),
        (-17.0, r), (-4.0, r), (10.0, r), (15.0, r * 0.96),
        (19.0, r * 0.72), (21.3, r * 0.42), (22.51, 0.16)]
    let spec = AirlinerSpec2(
        kind: .a321,
        fuselage: fuselage, cy: cy, fuseSegments: 32,
        screenScale: SCNVector3(0.86, 0.68, 1.05),
        screenPos: SCNVector3(0, cy + 0.98, -19.3),
        // Same wing as the A319/A320 — now looks SMALL, set at mid-body.
        wingSpan: 34.1, wingRootChord: 6.1, wingTipChord: 1.6, wingSweep: 6.0,
        wingThickness: 0.42, wingY: 1.5, wingTE_Z: 3.0,
        wingHalfSpan: 17.05, tipHeight: 2.4, tipChordFwd: 1.2, tipCant: 1.42,
        // Fatter neo-class cowl (bigger fan) than the A319's.
        engineXs: [5.5], fanRadius: 1.08, nacelleZ: -2.2, nacelleY: 1.2,
        nacelleLen: 4.1, intakeZ: -3.9, exhaustZ: 0.7,
        // Same physical fin — now PROPORTIONALLY SMALL on the long body.
        finBaseZ: 20.8, finBaseY: cy + 1.4, finHeight: 6.3,
        finRootChord: 5.0, finMidChord: 3.0, finThickness: 0.32,
        rudderHeight: 5.4, rudderChord: 1.4,
        stabSpan: 12.45, stabRootChord: 3.2, stabTipChord: 1.1, stabSweep: 2.2,
        stabThickness: 0.22, stabY: cy + 0.5, stabTE_Z: 20.6,
        ailCenterX: 13.6, ailSpan: 2.8, ailChord: 0.9,
        flapCenterX: 6.4, flapSpan: 6.2, flapChord: 1.6,
        surfThickness: 0.16,
        noseZ: -17.4, nosePivotY: 1.94, noseStrutLen: 1.5,
        noseWheelR: 0.44, noseWheelW: 0.18,
        // Longer wheelbase; beefier main tyres than the A319.
        mainX: 2.7, mainZ: 5.9, mainPivotY: 2.10, mainStrutLen: 1.55,
        mainWheelR: 0.58, mainWheelW: 0.26, mainBogieRows: 1,
        light: LightSpec(
            navLeft: SCNVector3(-17.9, 1.5, 2.4),
            navRight: SCNVector3(17.9, 1.5, 2.4),
            tail: SCNVector3(0, cy + 1.3, 22.5),
            beacon: SCNVector3(0, cy + 1.9, 2.0),
            landing: SCNVector3(0, 1.0, 4.0)),
        shadowSpan: 35.8, shadowLen: 44.51,
        smokeOffset: SCNVector3(0, 0.5, 5.9))
    return buildAirliner2(spec, livery: livery)
}

// MARK: - Boeing 757-200 (narrowbody, 2 BIG engines, tall stalky gear)

/// 757-200 — span 38.05 m, length 47.32 m, height 13.56 m. A long, slender tube
/// (Ø ~3.76 m ⇒ r 1.88) with the signature pointed, DROOPED nose (upper nose
/// slopes down) and a long upswept tailcone. Its most iconic ramp feature is the
/// TALL, stalky main gear standing the aircraft high off the ground, on FOUR-
/// WHEEL bogies (8 main wheels). Two BIG under-wing turbofans (over-powered for
/// its size). Tallest tail of the narrowbody set; big blended winglets; high-
/// dihedral wing.
func buildB757(livery: Livery) -> CraftParts {
    let cy: Float = 2.75   // TALL stalky stance — belly rides high off the ramp
    let r: Float = 1.88    // Ø ~3.76 m six-abreast tube
    // Fuselage: −23.4 (pointed DROOPED nose — the front rings pull DOWN off the
    // centreline via a small nose-tip droop) → +23.9 (long upswept tailcone).
    // Length ≈ 47.3.
    let fuselage: [(z: Float, r: Float)] = [
        (-23.4, 0.06), (-23.1, 0.40), (-22.4, 0.82), (-21.1, 1.28),
        (-18.9, 1.70), (-16.4, r), (-3.0, r), (10.0, r),
        (16.0, r * 0.94), (20.5, r * 0.62), (23.0, r * 0.30), (23.9, 0.12)]
    let spec = AirlinerSpec2(
        kind: .b757,
        fuselage: fuselage, cy: cy, fuseSegments: 32,
        // Narrow, forward-leaning windscreen cap on the pointed drooped nose.
        screenScale: SCNVector3(0.76, 0.58, 1.5),
        screenPos: SCNVector3(0, cy + 0.78, -20.2),
        // Big efficient high-dihedral wing.
        wingSpan: 38.05, wingRootChord: 7.4, wingTipChord: 1.7, wingSweep: 7.6,
        wingThickness: 0.5, wingY: 1.7, wingTE_Z: 4.0,
        // Large blended winglets (~2.4 m) retrofitted on many 757s.
        wingHalfSpan: 18.5, tipHeight: 2.4, tipChordFwd: 1.6, tipCant: 1.2,
        // BIG turbofans (RB211 / PW2000-class) — clearly larger than any A320's.
        engineXs: [5.9], fanRadius: 1.22, nacelleZ: -2.6, nacelleY: 1.32,
        nacelleLen: 5.0, intakeZ: -4.8, exhaustZ: 0.9,
        // TALLEST narrowbody tail (13.56 m aircraft height).
        finBaseZ: 21.4, finBaseY: cy + 1.5, finHeight: 7.8,
        finRootChord: 6.2, finMidChord: 3.2, finThickness: 0.38,
        rudderHeight: 6.7, rudderChord: 1.6,
        stabSpan: 15.2, stabRootChord: 4.0, stabTipChord: 1.3, stabSweep: 2.8,
        stabThickness: 0.26, stabY: cy + 0.6, stabTE_Z: 21.2,
        ailCenterX: 15.0, ailSpan: 3.4, ailChord: 1.0,
        flapCenterX: 7.0, flapSpan: 6.8, flapChord: 1.8,
        surfThickness: 0.18,
        // TALL stalky gear: long struts + high pivots ⇒ belly sits high. FOUR-
        // wheel main bogies (2 rows) — the 757's unusual narrowbody signature.
        noseZ: -17.8, nosePivotY: 2.44, noseStrutLen: 2.0,
        noseWheelR: 0.46, noseWheelW: 0.19,
        mainX: 2.9, mainZ: 6.6, mainPivotY: 2.60, mainStrutLen: 2.04,
        mainWheelR: 0.56, mainWheelW: 0.25, mainBogieRows: 2,
        light: LightSpec(
            navLeft: SCNVector3(-19.0, 1.7, 3.4),
            navRight: SCNVector3(19.0, 1.7, 3.4),
            tail: SCNVector3(0, cy + 1.4, 23.9),
            beacon: SCNVector3(0, cy + 2.2, 2.0),
            landing: SCNVector3(0, 1.3, 4.4)),
        shadowSpan: 38.05, shadowLen: 47.32,
        smokeOffset: SCNVector3(0, 0.6, 6.6))
    return buildAirliner2(spec, livery: livery)
}

// MARK: - McDonnell Douglas MD-80 (rear-fuselage engines, T-tail)

/// md80 — span 32.87 m, length 45.06 m, height 9.05 m. The definitive long-thin
/// tube: a slender Ø 3.35 m (r 1.68) pencil stretched to 45 m (length-to-diameter
/// ~13:1). TWO low-bypass turbofans mounted on the REAR fuselage (one each side,
/// on short stub pylons, tucked below and ahead of the T-tail) — the wing is
/// completely CLEAN with NO winglets. A T-TAIL: the horizontal stab perches atop
/// a tall, fillet-based fin, clear of the engine efflux. A flat "beaver" chisel
/// tailcone. Twin-wheel mains, low close-to-the-tarmac stance. Structurally the
/// buildComet / buildPhenom300 rear-engine T-tail family, stretched to mainline
/// scale. Static shell → cache; live parts stay on `body`.
func buildMD80(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 1.85  // low, close-to-the-tarmac fuselage centreline

    let airframe = AirframeCache.airframe(kind: .md80, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)

        // Very long slender tube (r 1.68 over 45 m). Pointed, moderately drooped
        // DC-9/MD radome up front; constant section for most of the length; hard
        // taper at the aft end into the flat "beaver" chisel tailcone. The last
        // two rings pinch the radius down and the tail terminates in a small flat
        // wedge rather than a rounded point.
        let r: Float = 1.68
        let fus = latheNode([(-22.3, 0.05), (-22.0, 0.30), (-21.3, 0.66), (-20.2, 1.06),
                             (-18.6, 1.42), (-16.0, r), (10.0, r), (16.0, r * 0.98),
                             (19.5, r * 0.82), (21.4, r * 0.52), (22.3, r * 0.30),
                             (22.76, 0.16)],
                            segments: 30,
                            material: fuselageMaterial(kind: .md80, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Classic Douglas stepped, slightly pointed windscreen wrapping the nose.
        let screen = SCNNode(geometry: SCNSphere(radius: 0.72))
        (screen.geometry as? SCNSphere)?.segmentCount = 24
        screen.geometry?.materials = [canopyGlassMaterial()]
        screen.scale = SCNVector3(0.74, 0.56, 1.35)
        screen.position = SCNVector3(0, cy + 0.72, -19.1)
        root.addChildNode(screen)

        // Low CLEAN swept wing set well forward of the rear engines — NO winglets,
        // plain squared tips. ~24.5° sweep; span 32.87 m. Sits ahead of mid-body.
        let wing = wingNode(span: 32.87, rootChord: 6.0, tipChord: 1.5, sweep: 6.6,
                            thickness: 0.42, material: bodyMat)
        wing.position = SCNVector3(0, 1.28, 0.5)
        root.addChildNode(wing)

        // --- Rear-fuselage nacelles + short stub pylons -----------------------
        // Long slim low-bypass "cigar" cowls (NOT fat high-bypass fans), mounted
        // high on the aft fuselage sides, close to the tube, aft of the wing.
        let nacMat = pbrMaterial(pal.body, roughness: max(0.12, pal.roughness - 0.06),
                                 metalness: min(1, pal.metalness + 0.15))
        let intakeMat = pbrMaterial(UIColor(white: 0.05, alpha: 1), roughness: 0.4)
        for s in [Float(-1), Float(1)] {
            // Slim, long nacelle (r ~0.72, ~5.2 m long) — cigar-shaped.
            let nac = latheNode([(-2.60, 0.20), (-2.42, 0.58), (-1.80, 0.70), (-0.40, 0.72),
                                 (1.30, 0.66), (2.30, 0.42), (2.60, 0.20)],
                                segments: 22, material: nacMat)
            nac.position = SCNVector3(1.95 * s, cy + 0.55, 15.7)
            root.addChildNode(nac)
            let intake = SCNNode(geometry: SCNCylinder(radius: 0.62, height: 0.04))
            intake.geometry?.materials = [intakeMat]
            intake.eulerAngles.x = .pi / 2
            intake.position = SCNVector3(1.95 * s, cy + 0.55, 13.14)
            root.addChildNode(intake)
            // Short near-flat stub pylon rooted at the fuselage shoulder — keeps
            // the nacelle hugging the tube.
            let pylon = SCNNode(geometry: SCNBox(width: 0.60, height: 0.34, length: 2.6, chamferRadius: 0.06))
            pylon.geometry?.materials = [bodyMat]
            pylon.position = SCNVector3(1.35 * s, cy + 0.5, 15.4)
            root.addChildNode(pylon)
        }

        // --- T-tail: tall filleted fin carrying the stab at its very top -------
        let finPath = UIBezierPath()
        // +x = forward (−Z), +y = up. Tall fin (~6.0 m) with a base fillet.
        finPath.move(to: CGPoint(x: 0.12, y: 0))
        finPath.addLine(to: CGPoint(x: 1.05, y: 5.95))               // swept LE up to the tip
        finPath.addQuadCurve(to: CGPoint(x: 3.00, y: 6.10), controlPoint: CGPoint(x: 1.75, y: 6.28))
        finPath.addQuadCurve(to: CGPoint(x: 4.50, y: 0.55), controlPoint: CGPoint(x: 4.05, y: 2.2))
        // Base fillet raking forward down the spine.
        finPath.addLine(to: CGPoint(x: 5.40, y: 0.22))
        finPath.addQuadCurve(to: CGPoint(x: 6.10, y: 0.0), controlPoint: CGPoint(x: 5.80, y: 0.04))
        finPath.close()
        let fin = finNode(path: finPath, thickness: 0.36, material: bodyMat)
        fin.position = SCNVector3(0, cy + 1.35, 21.0)
        root.addChildNode(fin)
        // Horizontal stab perched at the FIN TIP (~y cy+1.35+6.0). Slight sweep.
        let stab = wingNode(span: 12.6, rootChord: 3.0, tipChord: 1.1, sweep: 2.4,
                            thickness: 0.24, material: bodyMat)
        stab.position = SCNVector3(0, cy + 7.25, 19.9)
        root.addChildNode(stab)

        return root
    }

    let body = SCNNode()
    body.addChildNode(airframe)

    // --- Live turbofans + heat-wash (rear-fuselage nacelles) -----------------
    // Intake face at z 13.14, centreline x ±1.95, y cy+0.55.
    var fanGroups: [FanGroup] = []
    var heatWashes: [SCNNode] = []
    for s in [Float(-1), Float(1)] {
        let fan = makeFanGroup(at: SCNVector3(1.95 * s, cy + 0.55, 13.12), radius: 0.56)
        body.addChildNode(fan.group)
        fanGroups.append(fan.fan)
        // Warm wash aft of the exhaust (nacelle tail ~ z 18.3).
        let wash = makeHeatWash(at: SCNVector3(1.95 * s, cy + 0.55, 18.6), size: 2.2)
        body.addChildNode(wash)
        heatWashes.append(wash)
    }

    // --- Live control surfaces -----------------------------------------------
    // wingNode origin = ROOT TRAILING EDGE (z 0.5); TE_z(x) = wing.z +
    // |x|/halfSpan · (sweep + tipChord − rootChord)
    //   = 0.5 + |x|/16.435 · (6.6 + 1.5 − 6.0) = 0.5 + 0.1278·|x|.
    let surfBodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
    var ailerons: [Surface] = []
    var flaps: [Surface] = []
    for s in [Float(-1), Float(1)] {
        // Aileron centred at |x| 13.0 → TE_z ≈ 0.5 + 0.1278·13.0 ≈ 2.16.
        let a = hingedSurfaceNode(span: 3.0, chord: 0.9, thickness: 0.16, material: surfBodyMat)
        a.position = SCNVector3(s * 13.0, 1.28, 2.16)
        ailerons.append(Surface(node: a, sign: s))
        body.addChildNode(a)
        // Flap centred at |x| 5.5 → TE_z ≈ 0.5 + 0.1278·5.5 ≈ 1.20.
        let fl = hingedSurfaceNode(span: 6.0, chord: 1.5, thickness: 0.16, material: surfBodyMat)
        fl.position = SCNVector3(s * 5.5, 1.28, 1.20)
        flaps.append(Surface(node: fl, sign: 1))
        body.addChildNode(fl)
    }
    // T-tail elevator hinged on the stab TE at the fin tip (z 19.9, y cy+7.25).
    var elevator: [Surface] = []
    let elev = hingedSurfaceNode(span: 11.6, chord: 0.85, thickness: 0.16, material: surfBodyMat)
    elev.position = SCNVector3(0, cy + 7.25, 19.9)
    elevator.append(Surface(node: elev, sign: 1))
    body.addChildNode(elev)
    // Rudder hinged at the fin trailing edge. finNode extends forward (+x = −Z);
    // the fin's aft base corner sits at fin.z − minPathX 0.12 ≈ z 20.88. Hinge
    // the rudder slab there so it tucks into the aft edge.
    var rudder: [Surface] = []
    let rud = hingedRudderNode(height: 5.8, chord: 1.4, thickness: 0.30, material: surfBodyMat)
    rud.position = SCNVector3(0, cy + 1.35, 20.88)
    rudder.append(Surface(node: rud, sign: 1))
    body.addChildNode(rud)

    // --- Retractable gear: live wheels + real oleos --------------------------
    let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
    let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)
    let strutMat = pbrMaterial(UIColor(white: 0.75, alpha: 1), roughness: 0.35, metalness: 0.7)

    var wheels: [(node: SCNNode, radius: Float)] = []
    var oleos: [(node: SCNNode, restY: Float, travel: Float)] = []

    /// pivot → oleo → (static strut + live wheels). `twin` lays two wheels on a
    /// single axle (MD-80 mains are twin-wheel, no bogie).
    func gearLeg(pivotAt: SCNVector3, strutLen: Float, wheelRadius: CGFloat,
                 wheelWidth: CGFloat, twin: Bool)
        -> (pivot: SCNNode, oleo: SCNNode, wheels: [SCNNode]) {
        let pivot = SCNNode()
        pivot.position = pivotAt
        let oleo = SCNNode()
        let strut = strutNode(from: SCNVector3(0, 0, 0), to: SCNVector3(0, -strutLen, 0),
                              radius: 0.07, material: strutMat)
        oleo.addChildNode(strut.flattenedClone())
        var ws: [SCNNode] = []
        let xs: [Float] = twin ? [-0.20, 0.20] : [0]
        for x in xs {
            let w = wheelNode(radius: wheelRadius, width: wheelWidth, tire: tire, hub: hub)
            w.position = SCNVector3(x, -strutLen, 0)
            oleo.addChildNode(w)
            ws.append(w)
        }
        pivot.addChildNode(oleo)
        return (pivot, oleo, ws)
    }

    // Nose leg — twin wheels, folds forward. Low stance ⇒ short struts.
    let nose = gearLeg(pivotAt: SCNVector3(0, 1.24, -17.4), strutLen: 0.92,
                       wheelRadius: 0.40, wheelWidth: 0.16, twin: true)
    body.addChildNode(nose.pivot)
    for w in nose.wheels { wheels.append((w, 0.40)) }

    var gear: [(node: SCNNode, foldedEuler: SCNVector3)] =
        [(nose.pivot, SCNVector3(1.6, 0, 0))]  // folds forward into the nose
    var gearContacts: [SCNVector3] = []
    for s in [Float(-1), Float(1)] {
        // Twin-wheel mains retracting inward into the belly; low stance.
        let main = gearLeg(pivotAt: SCNVector3(2.5 * s, 1.10, 2.6), strutLen: 0.96,
                           wheelRadius: 0.54, wheelWidth: 0.26, twin: true)
        body.addChildNode(main.pivot)
        gear.append((main.pivot, SCNVector3(0, 0, 1.7 * -s)))  // mains fold inboard
        for w in main.wheels { wheels.append((w, 0.54)) }
        oleos.append((main.oleo, 0, 0.12))
        // Contact patch at ground level (pivot y 1.10 − strut 0.96 − radius 0.54 ≈ 0).
        gearContacts.append(SCNVector3(2.5 * s, 0, 2.6))
    }

    let shadow = makeContactShadow(span: 32.87, length: 45.06)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-16.4, 1.28, 1.9),
        navRight: SCNVector3(16.4, 1.28, 1.9),
        tail: SCNVector3(0, cy + 1.3, 22.7),
        beacon: SCNVector3(0, cy + 1.8, -1.0),
        landing: SCNVector3(0, 1.15, 2.0)))
    return CraftParts(body: body, propGroup: nil, blades: nil, blurDisc: nil,
                      fanGroups: fanGroups, heatWash: heatWashes,
                      beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      navNodes: kit.navs, scalingHalos: kit.halos, contactShadow: shadow,
                      landingLight: kit.light, landingGlow: kit.glow, gear: gear,
                      smokeOffset: SCNVector3(0, 0.55, 15.7),
                      gearContacts: gearContacts, wheels: wheels, oleos: oleos,
                      ailerons: ailerons, elevator: elevator, rudder: rudder, flaps: flaps)
}
