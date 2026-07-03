import Foundation
import SceneKit
import UIKit

// =============================================================================
// Airliner airframes — the game's rare spectacle heavies. Four fully-rigged,
// to-scale procedural builds, all mirroring buildComet (jet CraftParts): a long
// lathe-turned tube fuselage carrying a texture-baked cabin-window row, a LOW
// swept wing, UNDER-WING turbofan nacelles via makeFanGroup, a conventional
// tail (swept fin + horizontal stab with a hinged rudder/elevator), retractable
// gear (multi-wheel bogies on the big ones) built from live wheels + real oleos,
// a makeLightKit and a makeContactShadow.
//
//   buildBoeing737 → boeing737  (737-800, narrowbody, 2 engines, blended winglets)
//   buildAirbus320 → airbus320  (A320,     narrowbody, 2 engines, sharklets)
//   buildBoeing777 → boeing777  (777-300ER, widebody TWIN, 2 big engines, raked tips)
//   buildAirbus380 → airbus380  (A380-800, DOUBLE-DECK, 4 engines, the whale)
//
// Model space matches the other builds: node origin = ground contact (bottom of
// tires), nose = −Z, tail = +Z. Static shell goes through AirframeCache; live
// parts (fans / heat-wash / surfaces / wheels / oleos / lights) stay OUT of the
// cache and are added onto `body`, exactly as buildComet does.
// =============================================================================

// MARK: - Airliner spec

/// Every dimension needed to stamp a to-scale airliner. All lengths in metres,
/// in model space (nose −Z, tail +Z, y = height above the tire contact patch).
private struct AirlinerSpec {
    let kind: AircraftKind

    // Fuselage: a nose→tail lathe profile [(z, radius)]. z runs −(nose) → +(tail);
    // `cy` lifts the whole tube so the belly clears the gear. `segments` picks the
    // circumferential resolution (heavies get more).
    let fuselage: [(z: Float, r: Float)]
    let cy: Float
    let fuseSegments: Int
    /// Optional upper-deck bulge for the A380 — a second, higher lathe tube.
    let upperDeck: [(z: Float, r: Float)]?
    let upperDeckCY: Float

    // Flight-deck windscreen cap (dark glass ellipsoid over the nose).
    let screenScale: SCNVector3
    let screenPos: SCNVector3

    // Low main wing (wingNode: origin = root TE, extends forward −Z).
    let wingSpan: CGFloat
    let wingRootChord: CGFloat
    let wingTipChord: CGFloat
    let wingSweep: CGFloat        // tip LE setback
    let wingThickness: CGFloat
    let wingY: Float             // low-wing centreline height
    let wingTE_Z: Float          // root trailing-edge z (== wingNode.position.z)

    // Wingtip device (winglet / sharklet / raked tip). `cant` = z-roll radians
    // (0 ⇒ raked-flat tip; larger ⇒ upright winglet). `height` in metres.
    let wingHalfSpan: Float      // tip station |x|
    let tipHeight: CGFloat
    let tipChordFwd: CGFloat     // tip device root chord (fore-aft)
    let tipCant: Float

    // Under-wing engines: one entry per engine → x station (mirrored via ±),
    // fan radius, and the fore/aft z of the nacelle centre + intake face.
    // xs are the |x| stations for ONE side; the builder mirrors them.
    let engineXs: [Float]
    let fanRadius: CGFloat
    let nacelleZ: Float          // nacelle centre z (hangs ahead of + below wing)
    let nacelleY: Float          // nacelle centreline height (below the wing)
    let nacelleLen: Float        // full cowl length
    let intakeZ: Float           // intake-face z (fan sits here)
    let exhaustZ: Float          // heat-wash z (aft of the cowl)

    // Swept vertical fin (finNode: +x path = forward −Z; TE near node.z).
    let finBaseZ: Float          // node z (≈ fin trailing edge)
    let finBaseY: Float
    let finHeight: CGFloat       // fin height above its base
    let finRootChord: CGFloat    // fore-aft reach at the base
    let finMidChord: CGFloat     // reach at the tip fillet
    let finThickness: CGFloat

    // Rudder (hingedRudderNode: extends aft +Z from position at the fin TE).
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

    // Ailerons (outboard) + flaps (inboard), hinged on the wing TE. TE is nearly
    // straight; TE_z(x) ≈ wingTE_Z + wingSweep·|x|/wingHalfSpan.
    let ailCenterX: Float, ailSpan: CGFloat, ailChord: CGFloat
    let flapCenterX: Float, flapSpan: CGFloat, flapChord: CGFloat
    let surfThickness: CGFloat

    // Retractable gear. Nose leg + two main legs. Big jets carry multi-wheel
    // bogies (wheelsPerBogieRow × 2 rows) on the mains.
    let noseZ: Float, nosePivotY: Float, noseStrutLen: Float
    let noseWheelR: CGFloat, noseWheelW: CGFloat
    let mainX: Float, mainZ: Float, mainPivotY: Float, mainStrutLen: Float
    let mainWheelR: CGFloat, mainWheelW: CGFloat
    let mainBogieRows: Int       // wheel pairs fore↔aft per main leg (1, 2 or 3)
    let mainLegXs: [Float]       // |x| stations for the main legs on ONE side

    // Light kit anchor points + contact-shadow footprint.
    let light: LightSpec
    let shadowSpan: CGFloat, shadowLen: CGFloat
    let smokeOffset: SCNVector3
}

// MARK: - Shared airliner builder

/// Assemble a fully-rigged airliner CraftParts from an AirlinerSpec, mirroring
/// buildComet's jet wiring: static shell → AirframeCache; live fans / heat-wash /
/// surfaces / gear / lights added onto `body`.
private func buildAirliner(_ spec: AirlinerSpec, livery: Livery) -> CraftParts {
    let pal = livery.palette

    let airframe = AirframeCache.airframe(kind: spec.kind, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        // Nacelle cowls read a touch glossier than the painted skin.
        let nacMat = pbrMaterial(pal.body, roughness: max(0.12, pal.roughness - 0.06),
                                 metalness: min(1, pal.metalness + 0.15))
        let intakeMat = pbrMaterial(UIColor(white: 0.05, alpha: 1), roughness: 0.4)

        // --- Fuselage tube (cabin windows are baked into the texture) ---------
        let fus = latheNode(spec.fuselage, segments: spec.fuseSegments,
                            material: fuselageMaterial(kind: spec.kind, livery: livery))
        fus.position.y = spec.cy
        root.addChildNode(fus)

        // Optional upper deck (A380) — a second stacked tube above the main one.
        if let upper = spec.upperDeck {
            let deck = latheNode(upper, segments: spec.fuseSegments,
                                 material: fuselageMaterial(kind: spec.kind, livery: livery))
            deck.position.y = spec.upperDeckCY
            root.addChildNode(deck)
        }

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

        // Wingtip devices. cant≈0 ⇒ raked flat tip (777); larger ⇒ upright
        // winglet/sharklet (737/A320). Rooted at the wing tip LE-ish, extends up.
        let wingTipLE_Z = spec.wingTE_Z - Float(spec.wingRootChord - spec.wingSweep)
        for s in [Float(-1), Float(1)] {
            let wp = UIBezierPath()
            let c = Float(spec.tipChordFwd)
            let h = Float(spec.tipHeight)
            // Path: +x = forward (−Z), +y = up. A swept-back tapering tip fin.
            wp.move(to: CGPoint(x: 0, y: 0))
            wp.addLine(to: CGPoint(x: CGFloat(c * 0.18), y: CGFloat(h)))
            wp.addQuadCurve(to: CGPoint(x: CGFloat(c * 0.55), y: CGFloat(h)),
                            controlPoint: CGPoint(x: CGFloat(c * 0.30), y: CGFloat(h * 1.05)))
            wp.addQuadCurve(to: CGPoint(x: CGFloat(c), y: 0),
                            controlPoint: CGPoint(x: CGFloat(c * 0.9), y: CGFloat(h * 0.3)))
            wp.close()
            let tip = finNode(path: wp, thickness: spec.wingThickness * 0.42, material: bodyMat)
            let cant = SCNNode()
            cant.position = SCNVector3(spec.wingHalfSpan * s, spec.wingY + 0.02,
                                       wingTipLE_Z + Float(spec.tipChordFwd) * 0.55)
            cant.eulerAngles.z = -spec.tipCant * s   // splay outboard
            cant.addChildNode(tip)
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

        // --- Conventional tail: swept fin + horizontal stab -------------------
        let finPath = UIBezierPath()
        let fh = Float(spec.finHeight)
        let frc = Float(spec.finRootChord)
        let fmc = Float(spec.finMidChord)
        // +x = forward (−Z), +y = up. Root reaches `frc` forward; the tip fillet
        // pulls back to `fmc`, so the fin trailing edge sits near path x = 0.
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
    /// pairs fore↔aft; a single-wheel leg is rows == 1 with one pair.
    func gearLeg(pivotAt: SCNVector3, strutLen: Float, strutR: CGFloat,
                 wheelRadius: CGFloat, wheelWidth: CGFloat, rows: Int)
        -> (pivot: SCNNode, oleo: SCNNode, wheels: [SCNNode]) {
        let pivot = SCNNode()
        pivot.position = pivotAt
        let oleo = SCNNode()
        let strut = strutNode(from: SCNVector3(0, 0, 0), to: SCNVector3(0, -strutLen, 0),
                              radius: strutR, material: strutMat)
        oleo.addChildNode(strut.flattenedClone())
        // Bogie beam for multi-row bogies.
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

    // Main legs — one or more per side, each a multi-row bogie; fold inboard.
    for s in [Float(-1), Float(1)] {
        for lx in spec.mainLegXs {
            let x = lx * s
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

// MARK: - Boeing 737-800 (narrowbody, 2 engines, blended winglets)

/// 737-800 — span 35.8 m, len 39.5 m. Slim narrowbody tube, low wing, two
/// under-wing CFM-style nacelles, tall blended winglets, swept fin.
func buildBoeing737(livery: Livery) -> CraftParts {
    let cy: Float = 2.05
    let r: Float = 1.88   // cabin radius
    // Fuselage: −19.6 (nose) → +19.9 (tail cone). Length ≈ 39.5 m.
    let fuselage: [(z: Float, r: Float)] = [
        (-19.6, 0.10), (-19.2, 0.60), (-18.3, 1.05), (-16.8, 1.55),
        (-14.5, r), (-4.0, r), (6.0, r), (11.0, r * 0.94),
        (15.5, r * 0.72), (18.4, r * 0.42), (19.9, 0.16)]
    let spec = AirlinerSpec(
        kind: .boeing737,
        fuselage: fuselage, cy: cy, fuseSegments: 32,
        upperDeck: nil, upperDeckCY: 0,
        screenScale: SCNVector3(0.80, 0.62, 1.25),
        screenPos: SCNVector3(0, cy + 0.95, -16.7),
        wingSpan: 35.8, wingRootChord: 6.2, wingTipChord: 1.6, wingSweep: 6.4,
        wingThickness: 0.42, wingY: 1.35, wingTE_Z: 3.6,
        wingHalfSpan: 17.4, tipHeight: 2.4, tipChordFwd: 1.5, tipCant: 1.15,
        engineXs: [5.6], fanRadius: 1.05, nacelleZ: -2.4, nacelleY: 0.95,
        nacelleLen: 4.2, intakeZ: -4.2, exhaustZ: 0.5,
        finBaseZ: 18.4, finBaseY: cy + 1.4, finHeight: 6.6,
        finRootChord: 5.4, finMidChord: 2.6, finThickness: 0.34,
        rudderHeight: 5.6, rudderChord: 1.3,
        stabSpan: 13.4, stabRootChord: 3.4, stabTipChord: 1.2, stabSweep: 2.4,
        stabThickness: 0.24, stabY: cy + 0.55, stabTE_Z: 18.2,
        ailCenterX: 14.5, ailSpan: 3.2, ailChord: 0.9,
        flapCenterX: 6.5, flapSpan: 6.4, flapChord: 1.6,
        surfThickness: 0.16,
        // Gear pivots sit so tire contact lands at y ≈ 0 (pivotY = strut + wheelR).
        noseZ: -14.6, nosePivotY: 1.74, noseStrutLen: 1.3,
        noseWheelR: 0.44, noseWheelW: 0.18,
        mainX: 2.6, mainZ: 5.6, mainPivotY: 1.91, mainStrutLen: 1.35,
        mainWheelR: 0.56, mainWheelW: 0.24, mainBogieRows: 1, mainLegXs: [2.6],
        light: LightSpec(
            navLeft: SCNVector3(-17.9, 1.35, 3.0),
            navRight: SCNVector3(17.9, 1.35, 3.0),
            tail: SCNVector3(0, cy + 1.3, 20.0),
            beacon: SCNVector3(0, cy + 1.9, 2.0),
            landing: SCNVector3(0, 0.9, 4.0)),
        shadowSpan: 35.8, shadowLen: 39.5,
        smokeOffset: SCNVector3(0, 0.5, 5.6))
    return buildAirliner(spec, livery: livery)
}

// MARK: - Airbus A320 (narrowbody, 2 engines, sharklets)

/// A320 — span 35.8 m, len 37.6 m. Same footprint as the 737 but a shorter,
/// slightly fatter tube, a more upright fin, and blade-like SHARKLETS (near-
/// vertical, shorter than the 737's blended winglet) so the two read distinct.
func buildAirbus320(livery: Livery) -> CraftParts {
    let cy: Float = 2.05
    let r: Float = 1.95   // A320 fuselage is a touch wider than the 737
    // Fuselage: −18.7 (nose) → +18.9 (tail). Length ≈ 37.6 m.
    let fuselage: [(z: Float, r: Float)] = [
        (-18.7, 0.10), (-18.3, 0.62), (-17.4, 1.10), (-15.9, 1.60),
        (-13.6, r), (-3.5, r), (6.5, r), (11.5, r * 0.95),
        (15.2, r * 0.72), (17.6, r * 0.42), (18.9, 0.16)]
    let spec = AirlinerSpec(
        kind: .airbus320,
        fuselage: fuselage, cy: cy, fuseSegments: 32,
        upperDeck: nil, upperDeckCY: 0,
        screenScale: SCNVector3(0.82, 0.64, 1.15),
        screenPos: SCNVector3(0, cy + 0.98, -15.8),
        wingSpan: 35.8, wingRootChord: 6.1, wingTipChord: 1.6, wingSweep: 6.0,
        wingThickness: 0.42, wingY: 1.35, wingTE_Z: 4.2,
        // Sharklets: tall + near-vertical (bigger cant than the 737 winglet).
        wingHalfSpan: 17.35, tipHeight: 2.3, tipChordFwd: 1.2, tipCant: 1.4,
        engineXs: [5.5], fanRadius: 1.02, nacelleZ: -1.8, nacelleY: 0.95,
        nacelleLen: 4.0, intakeZ: -3.5, exhaustZ: 1.0,
        finBaseZ: 17.6, finBaseY: cy + 1.4, finHeight: 6.3,
        finRootChord: 5.0, finMidChord: 3.0, finThickness: 0.32,
        rudderHeight: 5.4, rudderChord: 1.4,
        stabSpan: 12.4, stabRootChord: 3.2, stabTipChord: 1.1, stabSweep: 2.2,
        stabThickness: 0.22, stabY: cy + 0.5, stabTE_Z: 17.4,
        ailCenterX: 14.2, ailSpan: 3.0, ailChord: 0.9,
        flapCenterX: 6.6, flapSpan: 6.6, flapChord: 1.6,
        surfThickness: 0.16,
        // Gear pivots sit so tire contact lands at y ≈ 0 (pivotY = strut + wheelR).
        noseZ: -13.7, nosePivotY: 1.74, noseStrutLen: 1.3,
        noseWheelR: 0.44, noseWheelW: 0.18,
        mainX: 2.6, mainZ: 6.2, mainPivotY: 1.90, mainStrutLen: 1.35,
        mainWheelR: 0.55, mainWheelW: 0.24, mainBogieRows: 1, mainLegXs: [2.6],
        light: LightSpec(
            navLeft: SCNVector3(-17.9, 1.35, 3.6),
            navRight: SCNVector3(17.9, 1.35, 3.6),
            tail: SCNVector3(0, cy + 1.3, 19.0),
            beacon: SCNVector3(0, cy + 1.9, 2.0),
            landing: SCNVector3(0, 0.9, 4.6)),
        shadowSpan: 35.8, shadowLen: 37.6,
        smokeOffset: SCNVector3(0, 0.5, 6.2))
    return buildAirliner(spec, livery: livery)
}

// MARK: - Boeing 777-300ER (widebody TWIN, 2 big engines, raked tips)

/// 777-300ER — span 64.8 m, len 73.9 m. Long widebody twin; two of the largest
/// turbofans in service; RAKED (swept, near-flat) wingtips; six-wheel main
/// bogies. The silhouette reads as a very long tube with just two huge engines.
func buildBoeing777(livery: Livery) -> CraftParts {
    let cy: Float = 2.9
    let r: Float = 3.1    // widebody cabin radius
    // Fuselage: −36.6 (nose) → +37.3 (tail). Length ≈ 73.9 m.
    let fuselage: [(z: Float, r: Float)] = [
        (-36.6, 0.14), (-36.0, 0.9), (-34.6, 1.7), (-32.0, 2.5),
        (-27.5, r), (-8.0, r), (12.0, r), (22.0, r * 0.95),
        (30.0, r * 0.70), (34.5, r * 0.40), (37.3, 0.18)]
    let spec = AirlinerSpec(
        kind: .boeing777,
        fuselage: fuselage, cy: cy, fuseSegments: 40,
        upperDeck: nil, upperDeckCY: 0,
        screenScale: SCNVector3(0.86, 0.70, 1.6),
        screenPos: SCNVector3(0, cy + 1.55, -31.6),
        wingSpan: 64.8, wingRootChord: 11.5, wingTipChord: 2.4, wingSweep: 13.0,
        wingThickness: 0.75, wingY: 1.9, wingTE_Z: 6.5,
        // Raked tips: long, low, minimal cant (swept-back flat extension).
        wingHalfSpan: 31.6, tipHeight: 0.55, tipChordFwd: 3.2, tipCant: 0.18,
        engineXs: [10.6], fanRadius: 1.72, nacelleZ: -3.6, nacelleY: 1.85,
        nacelleLen: 7.4, intakeZ: -6.8, exhaustZ: 1.4,
        finBaseZ: 33.6, finBaseY: cy + 2.3, finHeight: 9.4,
        finRootChord: 8.6, finMidChord: 4.2, finThickness: 0.52,
        rudderHeight: 8.2, rudderChord: 2.2,
        stabSpan: 21.5, stabRootChord: 5.6, stabTipChord: 1.8, stabSweep: 4.6,
        stabThickness: 0.38, stabY: cy + 0.9, stabTE_Z: 33.4,
        ailCenterX: 26.5, ailSpan: 5.2, ailChord: 1.4,
        flapCenterX: 12.5, flapSpan: 11.0, flapChord: 2.6,
        surfThickness: 0.24,
        // Gear pivots sit so tire contact lands at y ≈ 0 (pivotY = strut + wheelR).
        noseZ: -27.5, nosePivotY: 2.67, noseStrutLen: 2.05,
        noseWheelR: 0.62, noseWheelW: 0.24,
        mainX: 4.4, mainZ: 10.5, mainPivotY: 2.77, mainStrutLen: 2.05,
        mainWheelR: 0.72, mainWheelW: 0.30, mainBogieRows: 3, mainLegXs: [4.4],
        light: LightSpec(
            navLeft: SCNVector3(-32.4, 1.9, 5.5),
            navRight: SCNVector3(32.4, 1.9, 5.5),
            tail: SCNVector3(0, cy + 2.1, 37.4),
            beacon: SCNVector3(0, cy + 3.0, 2.0),
            landing: SCNVector3(0, 1.4, 7.5)),
        shadowSpan: 64.8, shadowLen: 73.9,
        smokeOffset: SCNVector3(0, 0.8, 10.5))
    return buildAirliner(spec, livery: livery)
}

// MARK: - Airbus A380-800 (DOUBLE-DECK, 4 engines, the whale)

/// A380-800 — span 79.8 m, len 72.7 m. Full double-deck fuselage, four huge
/// under-wing turbofans, four-wheel + six-wheel main bogies. The double-deck
/// tube + FOUR engines make the silhouette unmistakable.
func buildAirbus380(livery: Livery) -> CraftParts {
    let cy: Float = 3.4
    let r: Float = 3.6    // main-deck radius (widest fuselage in service)
    // Main tube: −36.0 (nose) → +36.7 (tail). Length ≈ 72.7 m.
    let fuselage: [(z: Float, r: Float)] = [
        (-36.0, 0.16), (-35.3, 1.0), (-33.6, 2.0), (-30.6, 2.9),
        (-25.5, r), (-6.0, r), (14.0, r), (23.0, r * 0.94),
        (30.0, r * 0.68), (34.0, r * 0.40), (36.7, 0.18)]
    // Upper deck: a shorter, higher, slightly narrower tube stacked on top so the
    // classic full-length double-deck bulge reads from any cab angle.
    let upper: [(z: Float, r: Float)] = [
        (-30.0, 0.2), (-28.5, 1.3), (-26.0, 2.0), (-22.0, 2.35),
        (-6.0, 2.45), (12.0, 2.45), (20.0, 2.1), (25.0, 1.4), (28.5, 0.5)]
    let spec = AirlinerSpec(
        kind: .airbus380,
        fuselage: fuselage, cy: cy, fuseSegments: 44,
        upperDeck: upper, upperDeckCY: cy + 2.65,
        screenScale: SCNVector3(1.0, 0.85, 1.7),
        screenPos: SCNVector3(0, cy + 3.4, -28.5),
        wingSpan: 79.8, wingRootChord: 13.5, wingTipChord: 2.8, wingSweep: 15.0,
        wingThickness: 0.9, wingY: 2.5, wingTE_Z: 5.0,
        wingHalfSpan: 38.9, tipHeight: 1.6, tipChordFwd: 2.6, tipCant: 0.9,
        // FOUR engines: inboard + outboard on each side.
        engineXs: [10.5, 20.5], fanRadius: 1.55, nacelleZ: -4.0, nacelleY: 1.65,
        nacelleLen: 6.8, intakeZ: -7.0, exhaustZ: 0.9,
        finBaseZ: 32.5, finBaseY: cy + 3.2, finHeight: 11.0,
        finRootChord: 9.4, finMidChord: 4.6, finThickness: 0.56,
        rudderHeight: 9.6, rudderChord: 2.4,
        stabSpan: 30.4, stabRootChord: 6.6, stabTipChord: 2.0, stabSweep: 5.4,
        stabThickness: 0.42, stabY: cy + 1.5, stabTE_Z: 32.0,
        ailCenterX: 32.0, ailSpan: 6.4, ailChord: 1.6,
        flapCenterX: 13.5, flapSpan: 13.0, flapChord: 3.0,
        surfThickness: 0.26,
        // Gear pivots sit so tire contact lands at y ≈ 0 (pivotY = strut + wheelR).
        noseZ: -25.5, nosePivotY: 3.11, noseStrutLen: 2.45,
        noseWheelR: 0.66, noseWheelW: 0.26,
        // Two main legs per side: inner "body" bogie (6-wheel) + outer "wing"
        // bogie (4-wheel). We approximate both as 2-row bogies at two stations.
        mainX: 3.6, mainZ: 9.0, mainPivotY: 3.18, mainStrutLen: 2.5,
        mainWheelR: 0.68, mainWheelW: 0.28, mainBogieRows: 2, mainLegXs: [3.6, 6.2],
        light: LightSpec(
            navLeft: SCNVector3(-39.9, 2.5, 3.5),
            navRight: SCNVector3(39.9, 2.5, 3.5),
            tail: SCNVector3(0, cy + 2.6, 36.8),
            beacon: SCNVector3(0, cy + 6.0, 2.0),
            landing: SCNVector3(0, 1.6, 6.0)),
        shadowSpan: 79.8, shadowLen: 72.7,
        smokeOffset: SCNVector3(0, 1.0, 9.0))
    return buildAirliner(spec, livery: livery)
}
