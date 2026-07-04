import Foundation
import SceneKit
import UIKit

// =============================================================================
// Airliner airframes — the game's rare spectacle heavies. Four fully-rigged,
// to-scale procedural builds, all mirroring buildComet (jet CraftParts): a long
// lathe-turned tube fuselage carrying a texture-baked cabin-window row, a LOW
// swept wing, UNDER-WING turbofan nacelles via makeFanGroup, a conventional
// swept tail (swept fin + horizontal stab with a hinged rudder/elevator),
// retractable gear (multi-wheel bogies on the big ones) built from live wheels +
// real oleos, a makeLightKit and a makeContactShadow.
//
// Every build is grounded in the researched reference blueprint (span/length/
// height + the distinctiveFeatures list), and the silhouettes are tuned so the
// four read UNMISTAKABLY apart:
//
//   buildBoeing737 → boeing737  (737-800: 35.79 m span, sits LOW to the tarmac,
//                    SHARP pointed nose, D-shaped flat-bottom CFM inlets, main
//                    wheels left exposed in the belly, ~2.4 m BLENDED winglets)
//   buildAirbus320 → airbus320  (A320: 35.8 m span, WIDER/rounder BULBOUS nose,
//                    sits TALL on long gear, perfectly ROUND inlets, blade
//                    SHARKLETS — the 737's opposite tells)
//   buildBoeing777 → boeing777  (777-300ER: 64.8 m span, long circular widebody
//                    twin, two ENORMOUS GE90 nacelles, curved RAKED wingtips,
//                    six-wheel main bogies, flat blade tailcone)
//   buildAirbus380 → airbus380  (A380-800: 79.75 m span, full-length DOUBLE-DECK
//                    ovoid, bulbous whale nose, FOUR engines two-per-wing,
//                    up-AND-down wingtip FENCES, wing + body main-gear bogies)
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
    /// Defaulted so single-deck airliners can omit them in the memberwise init.
    var upperDeck: [(z: Float, r: Float)]? = nil
    var upperDeckCY: Float = 0

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
    /// A380 wingtip fence: a short LOWER fin mirroring the upper one, so the tip
    /// device projects both up AND down (the A380 signature). nil ⇒ no lower fin.
    let lowerFenceHeight: CGFloat?

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
    /// 737 tell: squash the intake ring vertically so the inlet reads as a
    /// flat-bottomed "D" (extra ground clearance on the low-slung 737). 1 ⇒ round.
    let inletFlatten: Float

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
    /// 737 tell: leave the retracted main wheels visible in the belly (no gear
    /// doors) — a static half-wheel pair at the wheel well. nil ⇒ clean belly.
    let exposedMainWheelZ: Float?

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
        let tireMat = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
        let hubMat = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)

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
        // For the A380 an optional LOWER fence mirrors the upper one.
        let wingTipLE_Z = spec.wingTE_Z - Float(spec.wingRootChord - spec.wingSweep)
        for s in [Float(-1), Float(1)] {
            /// A swept-back tapering tip fin drawn +x = forward (−Z), +y = up,
            /// scaled to `h` metres tall.
            func tipFinPath(height h: Float, chord c: Float) -> UIBezierPath {
                let wp = UIBezierPath()
                wp.move(to: CGPoint(x: 0, y: 0))
                wp.addLine(to: CGPoint(x: CGFloat(c * 0.18), y: CGFloat(h)))
                wp.addQuadCurve(to: CGPoint(x: CGFloat(c * 0.55), y: CGFloat(h)),
                                controlPoint: CGPoint(x: CGFloat(c * 0.30), y: CGFloat(h * 1.05)))
                wp.addQuadCurve(to: CGPoint(x: CGFloat(c), y: 0),
                                controlPoint: CGPoint(x: CGFloat(c * 0.9), y: CGFloat(h * 0.3)))
                wp.close()
                return wp
            }
            let c = Float(spec.tipChordFwd)
            let upTip = finNode(path: tipFinPath(height: Float(spec.tipHeight), chord: c),
                                thickness: spec.wingThickness * 0.42, material: bodyMat)
            let cant = SCNNode()
            cant.position = SCNVector3(spec.wingHalfSpan * s, spec.wingY + 0.02,
                                       wingTipLE_Z + Float(spec.tipChordFwd) * 0.55)
            cant.eulerAngles.z = -spec.tipCant * s   // splay outboard
            cant.addChildNode(upTip)
            // A380 fence: a short lower fin dropping below the wingtip.
            if let lower = spec.lowerFenceHeight {
                let dnTip = finNode(path: tipFinPath(height: Float(lower), chord: c * 0.8),
                                    thickness: spec.wingThickness * 0.42, material: bodyMat)
                dnTip.scale = SCNVector3(1, -1, 1)   // flip so it grows downward
                cant.addChildNode(dnTip)
            }
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
                // 737 D-inlet: squash the cowl vertically so the bottom flattens.
                if spec.inletFlatten < 0.999 {
                    nac.scale = SCNVector3(1, spec.inletFlatten, 1)
                    nac.pivot = SCNMatrix4MakeTranslation(0, -Float(spec.fanRadius) * (1 - spec.inletFlatten) * 0.5, 0)
                }
                nac.position = SCNVector3(x, spec.nacelleY, spec.nacelleZ)
                root.addChildNode(nac)
                // Dark intake ring at the fan face (flattened to match a D-inlet).
                let intake = SCNNode(geometry: SCNTorus(ringRadius: Double(spec.fanRadius) * 0.92,
                                                        pipeRadius: Double(spec.fanRadius) * 0.10))
                intake.geometry?.materials = [intakeMat]
                intake.eulerAngles.x = .pi / 2
                intake.scale = SCNVector3(1, 1, spec.inletFlatten)  // torus lies in XZ ⇒ z is vertical
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

        // 737 tell: retracted main wheels left exposed in the belly (no doors).
        if let ez = spec.exposedMainWheelZ {
            for s in [Float(-1), Float(1)] {
                for dz in [Float(-1), Float(1)] {
                    let w = wheelNode(radius: spec.mainWheelR, width: spec.mainWheelW,
                                      tire: tireMat, hub: hubMat)
                    // Tuck them up flush against the belly centreline.
                    w.position = SCNVector3(0.55 * s, spec.cy - Float(spec.mainWheelR) * 0.7,
                                            ez + dz * Float(spec.mainWheelR) * 1.1)
                    root.addChildNode(w)
                }
            }
        }

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

/// 737-800 — span 35.79 m, len 39.47 m, height 12.55 m. A slim CIRCULAR tube
/// (Ø 3.76 m ⇒ r 1.88). The 737 hallmarks, all baked here: it sits LOW to the
/// tarmac on short gear (small belly-to-ground gap); a comparatively SHARP,
/// pointed nose; two CFM56 nacelles with the signature flat-bottomed "D" inlet
/// hung close to the ramp; ~2.4 m blended winglets; a short stubby tailcone with
/// a cylindrical APU "bullet"; and main-gear wheel faces left exposed in the
/// belly (no gear doors).
func buildBoeing737(livery: Livery) -> CraftParts {
    let cy: Float = 1.72   // LOW-slung 737: belly rides close to the ground
    let r: Float = 1.88    // cabin radius (Ø 3.76 m)
    // Fuselage: −19.6 (SHARP nose) → +19.87 (short stubby tail). Length ≈ 39.47.
    let fuselage: [(z: Float, r: Float)] = [
        (-19.6, 0.07), (-19.35, 0.42), (-18.7, 0.86), (-17.5, 1.36),
        (-15.3, 1.78), (-13.0, r), (-3.0, r), (7.0, r),
        (12.5, r * 0.95), (16.5, r * 0.68), (18.6, r * 0.40), (19.87, 0.15)]
    let spec = AirlinerSpec(
        kind: .boeing737,
        fuselage: fuselage, cy: cy, fuseSegments: 32,
        upperDeck: nil, upperDeckCY: 0,
        // Narrow, pointed windscreen cap set well forward on the sharp nose.
        screenScale: SCNVector3(0.74, 0.56, 1.35),
        screenPos: SCNVector3(0, cy + 0.92, -16.9),
        wingSpan: 35.79, wingRootChord: 6.2, wingTipChord: 1.55, wingSweep: 6.4,
        wingThickness: 0.42, wingY: 1.05, wingTE_Z: 3.6,
        // Blended winglets ~2.4 m: tall, smoothly curved, moderate cant.
        wingHalfSpan: 17.4, tipHeight: 2.4, tipChordFwd: 1.5, tipCant: 1.15,
        lowerFenceHeight: nil,
        // CFM56 hung LOW and close to the ramp; D-shaped inlet (flatten 0.82).
        // nacelleY keeps the flattened cowl bottom just above the tarmac.
        engineXs: [5.6], fanRadius: 1.05, nacelleZ: -2.4, nacelleY: 1.12,
        nacelleLen: 4.2, intakeZ: -4.2, exhaustZ: 0.5, inletFlatten: 0.82,
        finBaseZ: 18.4, finBaseY: cy + 1.4, finHeight: 6.7,
        finRootChord: 5.4, finMidChord: 2.6, finThickness: 0.34,
        rudderHeight: 5.7, rudderChord: 1.3,
        stabSpan: 13.4, stabRootChord: 3.4, stabTipChord: 1.2, stabSweep: 2.4,
        stabThickness: 0.24, stabY: cy + 0.55, stabTE_Z: 18.2,
        ailCenterX: 14.5, ailSpan: 3.2, ailChord: 0.9,
        flapCenterX: 6.5, flapSpan: 6.4, flapChord: 1.6,
        surfThickness: 0.16,
        // SHORT gear (737 sits low): pivotY = strut + wheelR so contact ≈ y 0.
        noseZ: -14.6, nosePivotY: 1.42, noseStrutLen: 0.98,
        noseWheelR: 0.44, noseWheelW: 0.18,
        mainX: 2.6, mainZ: 5.6, mainPivotY: 1.58, mainStrutLen: 1.02,
        mainWheelR: 0.56, mainWheelW: 0.24, mainBogieRows: 1, mainLegXs: [2.6],
        exposedMainWheelZ: 5.4,   // 737 tell: wheels visible in the belly
        light: LightSpec(
            navLeft: SCNVector3(-17.9, 1.05, 3.0),
            navRight: SCNVector3(17.9, 1.05, 3.0),
            tail: SCNVector3(0, cy + 1.3, 19.9),
            beacon: SCNVector3(0, cy + 1.9, 2.0),
            landing: SCNVector3(0, 0.6, 4.0)),
        shadowSpan: 35.79, shadowLen: 39.47,
        smokeOffset: SCNVector3(0, 0.4, 5.6))
    return buildAirliner(spec, livery: livery)
}

// MARK: - Airbus A320 (narrowbody, 2 engines, sharklets)

/// A320 — span 35.8 m, len 37.57 m, height 11.76 m. Same footprint class as the
/// 737 but tuned to the A320's *opposite* tells so the two never blur together:
/// a WIDER, stouter tube (Ø 3.95 m ⇒ r 1.98); a ROUNDED, slightly bulbous nose
/// (not the 737's sharp point); it sits noticeably TALL on longer gear (clear
/// belly-to-ground gap); perfectly ROUND engine inlets; and blade-like near-
/// vertical SHARKLETS (~2.5 m).
func buildAirbus320(livery: Livery) -> CraftParts {
    let cy: Float = 2.25   // A320 rides TALL on long gear (vs the low 737)
    let r: Float = 1.98    // WIDER than the 737 (Ø 3.95 m)
    // Fuselage: −18.6 (ROUNDED bulbous nose) → +18.97 (long clean conical tail).
    let fuselage: [(z: Float, r: Float)] = [
        (-18.6, 0.30), (-18.2, 0.82), (-17.3, 1.32), (-15.8, 1.72),
        (-13.6, r), (-3.5, r), (6.5, r), (11.5, r * 0.96),
        (15.4, r * 0.72), (17.7, r * 0.42), (18.97, 0.16)]
    let spec = AirlinerSpec(
        kind: .airbus320,
        fuselage: fuselage, cy: cy, fuseSegments: 32,
        upperDeck: nil, upperDeckCY: 0,
        // Rounder, blunter windscreen cap on the bulbous nose.
        screenScale: SCNVector3(0.86, 0.68, 1.05),
        screenPos: SCNVector3(0, cy + 0.98, -15.9),
        wingSpan: 35.8, wingRootChord: 6.1, wingTipChord: 1.6, wingSweep: 6.0,
        wingThickness: 0.42, wingY: 1.5, wingTE_Z: 4.2,
        // Sharklets: tall + near-vertical (bigger cant than the 737 winglet).
        wingHalfSpan: 17.35, tipHeight: 2.5, tipChordFwd: 1.2, tipCant: 1.42,
        lowerFenceHeight: nil,
        // Round inlets (flatten 1.0) sitting higher off the ground than the 737.
        engineXs: [5.5], fanRadius: 1.02, nacelleZ: -1.8, nacelleY: 1.2,
        nacelleLen: 4.0, intakeZ: -3.5, exhaustZ: 1.0, inletFlatten: 1.0,
        finBaseZ: 17.6, finBaseY: cy + 1.4, finHeight: 6.3,
        finRootChord: 5.0, finMidChord: 3.0, finThickness: 0.32,
        rudderHeight: 5.4, rudderChord: 1.4,
        stabSpan: 12.45, stabRootChord: 3.2, stabTipChord: 1.1, stabSweep: 2.2,
        stabThickness: 0.22, stabY: cy + 0.5, stabTE_Z: 17.4,
        ailCenterX: 14.2, ailSpan: 3.0, ailChord: 0.9,
        flapCenterX: 6.6, flapSpan: 6.6, flapChord: 1.6,
        surfThickness: 0.16,
        // TALLER gear than the 737 → the fuselage sits high with clear belly gap.
        noseZ: -13.7, nosePivotY: 1.94, noseStrutLen: 1.5,
        noseWheelR: 0.44, noseWheelW: 0.18,
        mainX: 2.6, mainZ: 6.2, mainPivotY: 2.10, mainStrutLen: 1.55,
        mainWheelR: 0.55, mainWheelW: 0.24, mainBogieRows: 1, mainLegXs: [2.6],
        exposedMainWheelZ: nil,   // A320 gear is fully doored (no visible wheels)
        light: LightSpec(
            navLeft: SCNVector3(-17.9, 1.5, 3.6),
            navRight: SCNVector3(17.9, 1.5, 3.6),
            tail: SCNVector3(0, cy + 1.3, 19.0),
            beacon: SCNVector3(0, cy + 1.9, 2.0),
            landing: SCNVector3(0, 1.0, 4.6)),
        shadowSpan: 35.8, shadowLen: 37.57,
        smokeOffset: SCNVector3(0, 0.5, 6.2))
    return buildAirliner(spec, livery: livery)
}

// MARK: - Boeing 777-300ER (widebody TWIN, 2 big engines, raked tips)

/// 777-300ER — span 64.8 m, len 73.9 m, height 18.5 m. A long, perfectly
/// CIRCULAR widebody tube (Ø 6.20 m ⇒ r 3.1) with the smoothly drooped Boeing
/// nose. Twin GE90 nacelles — the largest jet engines in service (fan Ø ~3.3 m ⇒
/// r 1.65), hung well ahead of and below the wing, disproportionately huge vs
/// the wing. Curved backward-RAKED wingtips (pointed rake, NOT vertical
/// winglets). SIX-wheel main bogies (three axles per side). Long tailcone ending
/// in the flat vertical BLADE tailcone. Tall main gear for GE90 clearance.
func buildBoeing777(livery: Livery) -> CraftParts {
    let cy: Float = 3.05
    let r: Float = 3.1     // widebody cabin radius (Ø 6.20 m)
    // Fuselage: −36.6 (drooped nose) → +37.3 (flat blade tailcone). Len ≈ 73.9.
    let fuselage: [(z: Float, r: Float)] = [
        (-36.6, 0.16), (-35.9, 1.05), (-34.3, 1.95), (-31.6, 2.72),
        (-27.0, r), (-8.0, r), (12.0, r), (22.0, r * 0.96),
        (30.0, r * 0.70), (34.8, r * 0.34), (37.3, 0.14)]
    let spec = AirlinerSpec(
        kind: .boeing777,
        fuselage: fuselage, cy: cy, fuseSegments: 40,
        screenScale: SCNVector3(0.88, 0.72, 1.7),
        screenPos: SCNVector3(0, cy + 1.55, -31.4),
        wingSpan: 64.8, wingRootChord: 13.5, wingTipChord: 2.2, wingSweep: 15.5,
        wingThickness: 0.8, wingY: 2.15, wingTE_Z: 6.5,
        // Raked tips: long, low, minimal cant (swept-back near-flat extension).
        wingHalfSpan: 31.6, tipHeight: 0.55, tipChordFwd: 3.4, tipCant: 0.16,
        lowerFenceHeight: nil,
        // GE90: enormous nacelles slung forward + low, well ahead of the wing.
        engineXs: [10.6], fanRadius: 1.65, nacelleZ: -4.2, nacelleY: 1.55,
        nacelleLen: 7.6, intakeZ: -7.6, exhaustZ: 1.2, inletFlatten: 1.0,
        finBaseZ: 33.6, finBaseY: cy + 2.3, finHeight: 9.6,
        finRootChord: 8.6, finMidChord: 4.2, finThickness: 0.52,
        rudderHeight: 8.4, rudderChord: 2.2,
        stabSpan: 21.5, stabRootChord: 5.6, stabTipChord: 1.8, stabSweep: 4.6,
        stabThickness: 0.38, stabY: cy + 0.9, stabTE_Z: 33.4,
        ailCenterX: 26.5, ailSpan: 5.2, ailChord: 1.4,
        flapCenterX: 12.5, flapSpan: 11.0, flapChord: 2.6,
        surfThickness: 0.24,
        // Tall gear so the GE90s clear the ramp. Six-wheel (3-row) main bogies.
        noseZ: -27.0, nosePivotY: 2.82, noseStrutLen: 2.2,
        noseWheelR: 0.62, noseWheelW: 0.24,
        mainX: 4.4, mainZ: 10.5, mainPivotY: 2.92, mainStrutLen: 2.2,
        mainWheelR: 0.72, mainWheelW: 0.30, mainBogieRows: 3, mainLegXs: [4.4],
        exposedMainWheelZ: nil,
        light: LightSpec(
            navLeft: SCNVector3(-32.4, 2.15, 5.5),
            navRight: SCNVector3(32.4, 2.15, 5.5),
            tail: SCNVector3(0, cy + 2.1, 37.4),
            beacon: SCNVector3(0, cy + 3.0, 2.0),
            landing: SCNVector3(0, 1.4, 7.5)),
        shadowSpan: 64.8, shadowLen: 73.9,
        smokeOffset: SCNVector3(0, 0.8, 10.5))
    return buildAirliner(spec, livery: livery)
}

// MARK: - Airbus A380-800 (DOUBLE-DECK, 4 engines, the whale)

/// A380-800 — span 79.75 m, len 72.7 m, height 24.1 m. The whale. A full-length
/// DOUBLE-DECK ovoid fuselage (two stacked tubes; taller than it is wide, widest
/// at the main-deck floor) with the bulbous whale nose and the flight deck set
/// LOW between the decks. FOUR under-wing turbofans (two per wing, inboard +
/// outboard). Up-AND-down wingtip FENCES (not tall winglets). A colossal broad,
/// low-aspect wing capped to the 80 m airport box, and a 24 m tail. Main gear =
/// two wing bogies + two body bogies per the reference (approximated as two 2-row
/// bogies per side at two stations).
func buildAirbus380(livery: Livery) -> CraftParts {
    let cy: Float = 3.7    // main-deck centreline
    let r: Float = 3.65    // main-deck radius (widest fuselage in service)
    // Main (lower) tube: −36.0 (whale nose) → +36.7 (upswept tail). Len ≈ 72.7.
    let fuselage: [(z: Float, r: Float)] = [
        (-36.0, 0.55), (-35.0, 1.6), (-33.2, 2.6), (-30.4, 3.25),
        (-25.5, r), (-6.0, r), (14.0, r), (23.0, r * 0.94),
        (30.0, r * 0.66), (34.0, r * 0.38), (36.7, 0.18)]
    // Upper deck: a full-length higher tube stacked on top, running nearly the
    // whole body so the double-deck bulge + twin window rows read from any angle.
    // It stops short of the far-forward nose (upper deck doesn't reach as far
    // forward as the lower) and tapers into the tail.
    let upper: [(z: Float, r: Float)] = [
        (-31.0, 0.3), (-29.5, 1.5), (-27.0, 2.35), (-23.0, 2.75),
        (-6.0, 2.85), (12.0, 2.85), (20.0, 2.5), (26.0, 1.7), (30.0, 0.6)]
    let spec = AirlinerSpec(
        kind: .airbus380,
        fuselage: fuselage, cy: cy, fuseSegments: 44,
        upperDeck: upper, upperDeckCY: cy + 3.0,
        // Cockpit set LOW and forward under the bulbous forehead (between decks).
        screenScale: SCNVector3(1.05, 0.7, 1.5),
        screenPos: SCNVector3(0, cy + 1.9, -29.5),
        wingSpan: 79.75, wingRootChord: 15.0, wingTipChord: 3.0, wingSweep: 17.0,
        wingThickness: 0.95, wingY: 3.3, wingTE_Z: 5.0,
        // Wingtip FENCES: a short upright fin PLUS a mirrored lower fin.
        wingHalfSpan: 38.9, tipHeight: 1.3, tipChordFwd: 2.6, tipCant: 0.35,
        lowerFenceHeight: 0.9,
        // FOUR engines: inboard (under the thick root) + outboard (toward tip).
        engineXs: [10.5, 20.5], fanRadius: 1.5, nacelleZ: -4.2, nacelleY: 2.05,
        nacelleLen: 6.8, intakeZ: -7.2, exhaustZ: 0.9, inletFlatten: 1.0,
        finBaseZ: 32.5, finBaseY: cy + 3.4, finHeight: 11.2,
        finRootChord: 9.4, finMidChord: 4.6, finThickness: 0.56,
        rudderHeight: 9.8, rudderChord: 2.4,
        stabSpan: 30.4, stabRootChord: 6.6, stabTipChord: 2.0, stabSweep: 5.4,
        stabThickness: 0.42, stabY: cy + 1.6, stabTE_Z: 32.0,
        ailCenterX: 32.0, ailSpan: 6.4, ailChord: 1.6,
        flapCenterX: 13.5, flapSpan: 13.0, flapChord: 3.0,
        surfThickness: 0.26,
        noseZ: -25.5, nosePivotY: 3.26, noseStrutLen: 2.6,
        noseWheelR: 0.66, noseWheelW: 0.26,
        // Two main legs per side: inner "body" bogie + outer "wing" bogie, both
        // approximated as 2-row bogies at two stations.
        mainX: 3.6, mainZ: 9.0, mainPivotY: 3.36, mainStrutLen: 2.68,
        mainWheelR: 0.68, mainWheelW: 0.28, mainBogieRows: 2, mainLegXs: [3.6, 6.2],
        exposedMainWheelZ: nil,
        light: LightSpec(
            navLeft: SCNVector3(-39.9, 3.3, 3.5),
            navRight: SCNVector3(39.9, 3.3, 3.5),
            tail: SCNVector3(0, cy + 2.6, 36.8),
            beacon: SCNVector3(0, cy + 6.4, 2.0),
            landing: SCNVector3(0, 1.8, 6.0)),
        shadowSpan: 79.75, shadowLen: 72.7,
        smokeOffset: SCNVector3(0, 1.0, 9.0))
    return buildAirliner(spec, livery: livery)
}
