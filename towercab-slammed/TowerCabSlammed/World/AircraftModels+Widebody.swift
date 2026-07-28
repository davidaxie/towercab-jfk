import Foundation
import SceneKit
import UIKit

// =============================================================================
// Widebody airframes — the fleet's biggest spectacle heavies. Six fully-rigged,
// to-scale procedural builds, all mirroring buildComet / buildAirliner (jet
// CraftParts): a long lathe-turned tube fuselage carrying a texture-baked
// cabin-window row, a LOW swept wing, turbofan nacelles via makeFanGroup,
// a conventional swept tail (swept fin + horizontal stab with hinged rudder /
// elevator), retractable multi-wheel-bogie gear from live wheels + real oleos,
// a makeLightKit and a makeContactShadow.
//
// Every build is grounded in the researched reference blueprint (span/length/
// height + the distinctiveFeatures list); the silhouettes are tuned so the six
// read UNMISTAKABLY apart:
//
//   buildB767  → b767  (767-300ER: 47.57 m span, len 54.94 m — long, PENCIL-THIN
//                semi-widebody twin; span shorter than length; forward-leaning
//                4-wheel main bogies; tall blended winglets; 2 under-wing engines)
//   buildB787  → b787  (787-9: 60.12 m span, len 62.81 m — glassy composite twin,
//                smooth blended nose with a 4-window flight deck, RAKED scimitar
//                wingtips, chevron engine cowls; near-square planform)
//   buildA330  → a330  (A330-300: 60.3 m span, len 63.69 m — Airbus widebody twin,
//                rounded droop-snoot nose, short CANTED wingtip FENCES; 2 engines)
//   buildA350  → a350  (A350-900: 64.75 m span, len 66.8 m — smooth composite twin
//                with the black "flying goggles" cockpit MASK, curved SABRE
//                wingtips, 2 big Trent XWB engines)
//   buildB747  → b747  (747-400: 64.4 m span, len 70.6 m — the Queen: forward
//                upper-deck HUMP, FOUR under-wing engines, ~1.8 m canted winglets)
//   buildDC10  → dc10  (DC-10-30: 50.39 m span, len 55.35 m — widebody TRIJET:
//                2 under-wing + one HIGH in the tail through the fin base in a
//                banjo fairing; extra centreline main gear)
//
// Model space matches the other builds: node origin = ground contact (bottom of
// tires), nose = −Z, tail = +Z. Static shell goes through AirframeCache; live
// parts (fans / heat-wash / surfaces / wheels / oleos / lights) stay OUT of the
// cache and are added onto `body`, exactly as buildComet / buildAirliner do.
// =============================================================================

// MARK: - Widebody spec

/// Every dimension needed to stamp a to-scale widebody. All lengths in metres,
/// in model space (nose −Z, tail +Z, y = height above the tire contact patch).
/// Distinct from the Airliner file's private AirlinerSpec so this file is
/// self-contained; the widebody extras (raked tips, fences, cockpit mask, the
/// 747 hump and the DC-10 tail engine) are layered on top.
private struct WidebodySpec {
    let kind: AircraftKind

    // Fuselage: a nose→tail lathe profile [(z, radius)]. `cy` lifts the tube so
    // the belly clears the gear; `segments` picks circumferential resolution.
    let fuselage: [(z: Float, r: Float)]
    let cy: Float
    let fuseSegments: Int
    /// Optional upper-deck bulge (747 hump) — a second, higher lathe tube.
    var upperDeck: [(z: Float, r: Float)]? = nil
    var upperDeckCY: Float = 0

    // Flight-deck windscreen cap (dark glass ellipsoid over the nose).
    let screenScale: SCNVector3
    let screenPos: SCNVector3
    /// A350 signature: a glossy-black "flying goggles" mask wrapping the nose,
    /// drawn as a slightly larger flattened dark ellipsoid behind the screen.
    var cockpitMask: Bool = false

    // Low main wing (wingNode: origin = root TE, extends forward −Z).
    let wingSpan: CGFloat
    let wingRootChord: CGFloat
    let wingTipChord: CGFloat
    let wingSweep: CGFloat        // tip LE setback
    let wingThickness: CGFloat
    let wingY: Float             // low-wing centreline height
    let wingTE_Z: Float          // root trailing-edge z (== wingNode.position.z)

    // Wingtip device (winglet / raked tip / sabre / fence). `cant` = z-roll
    // radians (≈0 ⇒ raked-flat tip; larger ⇒ upright winglet). `height` metres.
    let wingHalfSpan: Float      // tip station |x|
    let tipHeight: CGFloat
    let tipChordFwd: CGFloat     // tip device root chord (fore-aft)
    let tipCant: Float
    /// nil ⇒ no lower fin; set ⇒ an A380-style fence dropping below the tip
    /// (unused by these six but kept for parity with the shared builder shape).
    let lowerFenceHeight: CGFloat?

    // Under-wing engines: |x| stations for ONE side (mirrored via ±).
    let engineXs: [Float]
    let fanRadius: CGFloat
    let nacelleZ: Float          // nacelle centre z (hangs ahead of + below wing)
    let nacelleY: Float          // nacelle centreline height (below the wing)
    let nacelleLen: Float        // full cowl length
    let intakeZ: Float           // intake-face z (fan sits here)
    let exhaustZ: Float          // heat-wash z (aft of the cowl)
    /// 787 tell: serrated "chevron" cowl trailing edge. Drawn as a ring of small
    /// dark triangles at the nacelle tail. false ⇒ plain round cowl.
    var chevrons: Bool = false

    /// DC-10 tail engine: a third engine planted HIGH in the fin base with a
    /// straight-through banjo fairing. nil ⇒ twin. When set, the shared fin is
    /// raised to sit on top of the banjo and a live fan is added at `intakeZ`.
    var tailEngine: TailEngineSpec? = nil

    // Swept vertical fin (finNode: +x path = forward −Z; TE near node.z).
    let finBaseZ: Float
    let finBaseY: Float
    let finHeight: CGFloat
    let finRootChord: CGFloat
    let finMidChord: CGFloat
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

    // Ailerons (outboard) + flaps (inboard), hinged on the wing TE.
    let ailCenterX: Float, ailSpan: CGFloat, ailChord: CGFloat
    let flapCenterX: Float, flapSpan: CGFloat, flapChord: CGFloat
    let surfThickness: CGFloat

    // Retractable gear. Nose leg + main legs (multi-wheel bogies on the mains).
    let noseZ: Float, nosePivotY: Float, noseStrutLen: Float
    let noseWheelR: CGFloat, noseWheelW: CGFloat
    let mainZ: Float, mainPivotY: Float, mainStrutLen: Float
    let mainWheelR: CGFloat, mainWheelW: CGFloat
    let mainBogieRows: Int       // wheel pairs fore↔aft per main leg
    let mainLegXs: [Float]       // |x| stations for the main legs on ONE side
    /// DC-10-30 tell: an extra CENTERLINE main leg on the belly (two wheels).
    /// nil ⇒ none. When set, one live 1-row leg is added at x = 0.
    let centerlineMainZ: Float?

    // Light kit anchor points + contact-shadow footprint.
    let light: LightSpec
    let shadowSpan: CGFloat, shadowLen: CGFloat
    let smokeOffset: SCNVector3
}

/// DC-10 tail (banjo) engine geometry: a fat straight-through nacelle planted at
/// the base of the fin, above the aft fuselage roofline.
private struct TailEngineSpec {
    let z: Float                 // nacelle centre z
    let y: Float                 // nacelle centreline height (well above the roof)
    let fanRadius: CGFloat
    let nacelleLen: Float
    let intakeZ: Float           // straight-through intake face (fan sits here)
    let exhaustZ: Float          // heat-wash z (aft of the banjo)
}

// MARK: - Shared widebody builder

/// Assemble a fully-rigged widebody CraftParts from a WidebodySpec, mirroring
/// buildAirliner's jet wiring: static shell → AirframeCache; live fans /
/// heat-wash / surfaces / gear / lights added onto `body`.
private func buildWidebody(_ spec: WidebodySpec, livery: Livery) -> CraftParts {
    let pal = livery.palette

    let airframe = AirframeCache.airframe(kind: spec.kind, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        // Nacelle cowls read a touch glossier than the painted skin.
        let nacMat = pbrMaterial(pal.body, roughness: max(0.12, pal.roughness - 0.06),
                                 metalness: min(1, pal.metalness + 0.15))
        let intakeMat = pbrMaterial(UIColor(white: 0.05, alpha: 1), roughness: 0.4)
        // (wheel materials belong to the LIVE parts below, not the cached shell)

        // --- Fuselage tube (cabin windows are baked into the texture) ---------
        let fus = latheNode(spec.fuselage, segments: spec.fuseSegments,
                            material: fuselageMaterial(kind: spec.kind, livery: livery))
        fus.position.y = spec.cy
        root.addChildNode(fus)

        // Optional upper deck (747 hump) — a second stacked tube up front.
        if let upper = spec.upperDeck {
            let deck = latheNode(upper, segments: spec.fuseSegments,
                                 material: fuselageMaterial(kind: spec.kind, livery: livery))
            deck.position.y = spec.upperDeckCY
            root.addChildNode(deck)
        }

        // A350 black cockpit mask: a flattened glossy-black ellipsoid hugging the
        // nose, drawn just under the glass so the windscreen reads as a dark
        // wraparound visor even on a white airframe.
        if spec.cockpitMask {
            let maskMat = pbrMaterial(UIColor(red: 0.03, green: 0.035, blue: 0.045, alpha: 1),
                                      roughness: 0.22, metalness: 0.2)
            let mask = SCNNode(geometry: SCNSphere(radius: 0.9))
            (mask.geometry as? SCNSphere)?.segmentCount = 24
            mask.geometry?.materials = [maskMat]
            mask.scale = SCNVector3(spec.screenScale.x * 1.12,
                                    spec.screenScale.y * 1.16,
                                    spec.screenScale.z * 1.9)
            // Sweep the mask a touch aft + down so it "eye-liners" along the nose.
            mask.position = SCNVector3(spec.screenPos.x,
                                       spec.screenPos.y - 0.12,
                                       spec.screenPos.z + 1.1)
            root.addChildNode(mask)
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

        // Wingtip devices. cant≈0 ⇒ raked flat tip (787 / DC-10 plain); larger ⇒
        // upright winglet / canted fence (767 blended, A330 fence, 747 winglet,
        // A350 sabre). Rooted near the wing tip LE, extending up.
        let wingTipLE_Z = spec.wingTE_Z - Float(spec.wingRootChord - spec.wingSweep)
        if spec.tipHeight > 0.001 {
            for s in [Float(-1), Float(1)] {
                /// A swept-back tapering tip fin drawn +x = forward (−Z), +y = up.
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
                if let lower = spec.lowerFenceHeight {
                    let dnTip = finNode(path: tipFinPath(height: Float(lower), chord: c * 0.8),
                                        thickness: spec.wingThickness * 0.42, material: bodyMat)
                    dnTip.scale = SCNVector3(1, -1, 1)   // flip so it grows downward
                    cant.addChildNode(dnTip)
                }
                root.addChildNode(cant)
            }
        }

        // --- Under-wing engines: nacelle shell + pylon (fan stays live) -------
        func nacelleShell(at pos: SCNVector3, radius: CGFloat, len: Float,
                          chevrons: Bool) {
            let half = len / 2
            let nac = latheNode([(-half, Float(radius) * 0.42),
                                 (-half * 0.78, Float(radius) * 1.02),
                                 (-half * 0.3, Float(radius) * 1.06),
                                 (half * 0.35, Float(radius) * 0.98),
                                 (half * 0.8, Float(radius) * 0.66),
                                 (half, Float(radius) * 0.34)],
                                segments: 24, material: nacMat)
            nac.position = pos
            root.addChildNode(nac)
            // Dark intake ring at the fan face.
            let intake = SCNNode(geometry: SCNTorus(ringRadius: Double(radius) * 0.92,
                                                    pipeRadius: Double(radius) * 0.10))
            intake.geometry?.materials = [intakeMat]
            intake.eulerAngles.x = .pi / 2
            intake.position = SCNVector3(pos.x, pos.y, pos.z - half + 0.05)
            root.addChildNode(intake)
            // 787 chevrons: a ring of small dark sawtooth tabs at the cowl tail.
            if chevrons {
                let tailZ = pos.z + half
                let n = 14
                for i in 0..<n {
                    let ang = Float(i) / Float(n) * 2 * .pi
                    let tab = SCNNode(geometry: SCNPyramid(width: CGFloat(radius) * 0.20,
                                                           height: CGFloat(radius) * 0.30,
                                                           length: 0.04))
                    tab.geometry?.materials = [intakeMat]
                    // Point the pyramid apex aft, seated on the cowl-tail rim.
                    tab.eulerAngles = SCNVector3(-.pi / 2, 0, ang)
                    tab.position = SCNVector3(pos.x + sin(ang) * Float(radius) * 0.36,
                                              pos.y + cos(ang) * Float(radius) * 0.36,
                                              tailZ)
                    root.addChildNode(tab)
                }
            }
        }

        for s in [Float(-1), Float(1)] {
            for xz in spec.engineXs {
                let x = xz * s
                nacelleShell(at: SCNVector3(x, spec.nacelleY, spec.nacelleZ),
                             radius: spec.fanRadius, len: spec.nacelleLen,
                             chevrons: spec.chevrons)
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

        // --- DC-10 tail engine: banjo nacelle planted at the fin base ---------
        if let te = spec.tailEngine {
            // Fat straight-through cowl, longer + fatter than an under-wing pod,
            // sitting high above the aft roofline. The fin is planted on top.
            let half = te.nacelleLen / 2
            let banjo = latheNode([(-half, Float(te.fanRadius) * 0.48),
                                   (-half * 0.72, Float(te.fanRadius) * 1.04),
                                   (-half * 0.15, Float(te.fanRadius) * 1.10),
                                   (half * 0.45, Float(te.fanRadius) * 1.02),
                                   (half * 0.82, Float(te.fanRadius) * 0.70),
                                   (half, Float(te.fanRadius) * 0.40)],
                                  segments: 26, material: nacMat)
            banjo.position = SCNVector3(0, te.y, te.z)
            root.addChildNode(banjo)
            // Straight-through intake ring protruding at the front of the fin.
            let intake = SCNNode(geometry: SCNTorus(ringRadius: Double(te.fanRadius) * 0.92,
                                                    pipeRadius: Double(te.fanRadius) * 0.11))
            intake.geometry?.materials = [intakeMat]
            intake.eulerAngles.x = .pi / 2
            intake.position = SCNVector3(0, te.y, te.intakeZ)
            root.addChildNode(intake)
            // A fairing that blends the banjo down into the aft fuselage spine.
            let fillet = latheNode([(-half * 0.9, Float(te.fanRadius) * 0.30),
                                    (-half * 0.2, Float(te.fanRadius) * 0.62),
                                    (half * 0.5, Float(te.fanRadius) * 0.50),
                                    (half, Float(te.fanRadius) * 0.20)],
                                   segments: 20, material: bodyMat)
            fillet.position = SCNVector3(0, te.y - Float(te.fanRadius) * 0.85, te.z)
            root.addChildNode(fillet)
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
    // DC-10 third (tail) engine — a live fan + heat-wash on the banjo centreline.
    if let te = spec.tailEngine {
        let fan = makeFanGroup(at: SCNVector3(0, te.y, te.intakeZ), radius: te.fanRadius)
        body.addChildNode(fan.group)
        fanGroups.append(fan.fan)
        let wash = makeHeatWash(at: SCNVector3(0, te.y, te.exhaustZ), size: te.fanRadius * 4.0)
        body.addChildNode(wash)
        heatWashes.append(wash)
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

    // DC-10-30 centreline main leg — a single belly strut with a 2-wheel bogie,
    // folding forward. Sits between the two main bogies on the centreline.
    if let cz = spec.centerlineMainZ {
        let center = gearLeg(pivotAt: SCNVector3(0, spec.mainPivotY, cz),
                             strutLen: spec.mainStrutLen, strutR: 0.075,
                             wheelRadius: spec.mainWheelR, wheelWidth: spec.mainWheelW,
                             rows: 1)
        body.addChildNode(center.pivot)
        gear.append((center.pivot, SCNVector3(1.6, 0, 0)))
        for w in center.wheels { wheels.append((w, Float(spec.mainWheelR))) }
        oleos.append((center.oleo, 0, 0.12))
        gearContacts.append(SCNVector3(0, 0, cz))
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

// MARK: - Boeing 767-300ER (semi-widebody TWIN, 2 engines, blended winglets)

/// 767-300ER — span 47.57 m, len 54.94 m, height 15.85 m. The tell is a long,
/// PENCIL-THIN semi-widebody tube (Ø 5.03 m ⇒ r 2.52) whose span is NOTABLY
/// SHORTER than its length — the opposite of the near-square 787/A330. Two
/// under-wing high-bypass nacelles, tall ~3.35 m blended winglets raked sharply
/// up, a rounded stepped-brow Boeing nose, and forward-leaning 4-wheel main
/// bogies. Pacifica Air flagship.
func buildB767(livery: Livery) -> CraftParts {
    let cy: Float = 2.9
    let r: Float = 2.52    // semi-widebody cabin radius (Ø 5.03 m)
    // Fuselage: −27.3 (drooped ogive nose) → +27.6 (long clean taper). Len ≈ 54.9.
    let fuselage: [(z: Float, r: Float)] = [
        (-27.3, 0.14), (-26.7, 0.90), (-25.3, 1.66), (-23.0, 2.24),
        (-19.5, r), (-6.0, r), (9.0, r), (17.0, r * 0.96),
        (22.5, r * 0.70), (25.8, r * 0.34), (27.6, 0.13)]
    let spec = WidebodySpec(
        kind: .b767,
        fuselage: fuselage, cy: cy, fuseSegments: 36,
        screenScale: SCNVector3(0.82, 0.66, 1.55),
        screenPos: SCNVector3(0, cy + 1.35, -23.2),
        wingSpan: 47.57, wingRootChord: 10.0, wingTipChord: 1.9, wingSweep: 11.5,
        wingThickness: 0.66, wingY: 2.0, wingTE_Z: 5.5,
        // Tall blended winglets (~3.35 m): raked sharply up, moderate cant.
        wingHalfSpan: 23.1, tipHeight: 3.0, tipChordFwd: 2.0, tipCant: 1.05,
        lowerFenceHeight: nil,
        // Two under-wing high-bypass nacelles, moderate on the slim airframe.
        engineXs: [8.0], fanRadius: 1.35, nacelleZ: -3.2, nacelleY: 1.45,
        nacelleLen: 6.0, intakeZ: -6.0, exhaustZ: 1.0,
        finBaseZ: 24.6, finBaseY: cy + 1.9, finHeight: 8.2,
        finRootChord: 7.0, finMidChord: 3.4, finThickness: 0.46,
        rudderHeight: 7.2, rudderChord: 1.8,
        stabSpan: 18.6, stabRootChord: 4.6, stabTipChord: 1.5, stabSweep: 3.8,
        stabThickness: 0.32, stabY: cy + 0.7, stabTE_Z: 24.4,
        ailCenterX: 19.5, ailSpan: 4.2, ailChord: 1.2,
        flapCenterX: 9.0, flapSpan: 8.6, flapChord: 2.2,
        surfThickness: 0.2,
        noseZ: -19.6, nosePivotY: 2.66, noseStrutLen: 2.0,
        noseWheelR: 0.56, noseWheelW: 0.22,
        mainZ: 8.4, mainPivotY: 2.74, mainStrutLen: 2.0,
        mainWheelR: 0.66, mainWheelW: 0.28, mainBogieRows: 2, mainLegXs: [3.6],
        centerlineMainZ: nil,
        light: LightSpec(
            navLeft: SCNVector3(-23.8, 2.0, 4.6),
            navRight: SCNVector3(23.8, 2.0, 4.6),
            tail: SCNVector3(0, cy + 1.7, 27.6),
            beacon: SCNVector3(0, cy + 2.7, 2.0),
            landing: SCNVector3(0, 1.3, 6.0)),
        shadowSpan: 47.57, shadowLen: 54.94,
        smokeOffset: SCNVector3(0, 0.7, 8.4))
    return buildWidebody(spec, livery: livery)
}

// MARK: - Boeing 787-9 Dreamliner (widebody TWIN, raked tips, chevrons)

/// 787-9 — span 60.12 m, len 62.81 m, height 17.02 m. A glassy composite twin
/// with a near-square planform (span ≈ length). Signatures baked here: a smooth
/// blended nose with the flight-deck glass sinking INTO the contour (no stepped
/// brow); big GEnx/Trent nacelles with serrated CHEVRON cowl trailing edges;
/// long backward-RAKED scimitar wingtips (low, minimal cant, NOT vertical
/// winglets); a subtly raked fin. Meridian Air flagship.
func buildB787(livery: Livery) -> CraftParts {
    let cy: Float = 2.95
    let r: Float = 2.88    // widebody composite barrel (Ø 5.77 m)
    // Fuselage: −31.4 (smooth blended nose) → +31.4 (pointed tailcone). Len ≈ 62.8.
    // A gentler, longer nose blend (no sharp brow) than the 767.
    let fuselage: [(z: Float, r: Float)] = [
        (-31.4, 0.18), (-30.6, 1.02), (-28.8, 1.95), (-26.0, 2.62),
        (-21.5, r), (-6.0, r), (12.0, r), (20.0, r * 0.95),
        (26.5, r * 0.66), (30.0, r * 0.30), (31.4, 0.12)]
    let spec = WidebodySpec(
        kind: .b787,
        fuselage: fuselage, cy: cy, fuseSegments: 40,
        // Long low windscreen blended smoothly into the composite nose.
        screenScale: SCNVector3(0.9, 0.6, 1.95),
        screenPos: SCNVector3(0, cy + 1.35, -26.7),
        wingSpan: 60.12, wingRootChord: 12.5, wingTipChord: 1.6, wingSweep: 14.5,
        wingThickness: 0.74, wingY: 2.05, wingTE_Z: 6.0,
        // Raked scimitar tips: long, low, minimal cant (swept-back extension).
        wingHalfSpan: 29.2, tipHeight: 0.5, tipChordFwd: 3.2, tipCant: 0.14,
        lowerFenceHeight: nil,
        // Big GEnx/Trent nacelles with chevron cowl tails.
        engineXs: [9.8], fanRadius: 1.5, nacelleZ: -3.8, nacelleY: 1.5,
        nacelleLen: 6.8, intakeZ: -6.8, exhaustZ: 1.0,
        chevrons: true,
        finBaseZ: 28.0, finBaseY: cy + 2.1, finHeight: 8.8,
        finRootChord: 7.4, finMidChord: 3.4, finThickness: 0.48,
        rudderHeight: 7.6, rudderChord: 1.9,
        stabSpan: 19.6, stabRootChord: 4.8, stabTipChord: 1.5, stabSweep: 4.0,
        stabThickness: 0.34, stabY: cy + 0.8, stabTE_Z: 27.8,
        ailCenterX: 24.5, ailSpan: 4.6, ailChord: 1.3,
        flapCenterX: 11.0, flapSpan: 10.0, flapChord: 2.4,
        surfThickness: 0.22,
        noseZ: -22.0, nosePivotY: 2.72, noseStrutLen: 2.1,
        noseWheelR: 0.58, noseWheelW: 0.22,
        mainZ: 9.4, mainPivotY: 2.80, mainStrutLen: 2.1,
        mainWheelR: 0.68, mainWheelW: 0.28, mainBogieRows: 2, mainLegXs: [4.0],
        centerlineMainZ: nil,
        light: LightSpec(
            navLeft: SCNVector3(-30.1, 2.05, 5.0),
            navRight: SCNVector3(30.1, 2.05, 5.0),
            tail: SCNVector3(0, cy + 1.9, 31.4),
            beacon: SCNVector3(0, cy + 2.9, 2.0),
            landing: SCNVector3(0, 1.4, 6.6)),
        shadowSpan: 60.12, shadowLen: 62.81,
        smokeOffset: SCNVector3(0, 0.7, 9.4))
    return buildWidebody(spec, livery: livery)
}

// MARK: - Airbus A330-300 (widebody TWIN, canted wingtip fences)

/// A330-300 — span 60.3 m, len 63.69 m, height 16.83 m. Airbus widebody twin with
/// a near-square planform. Signatures: a rounded, slightly bulbous "droop-snoot"
/// Airbus nose (blunter than Boeing); short, wide, sharply CANTED wingtip FENCES
/// (~2.74 m, ~45°) — stubbier than 767 blended winglets or 787 raked tips; two
/// under-wing engines; clean rounded fin. Altair Express widebody.
func buildA330(livery: Livery) -> CraftParts {
    let cy: Float = 2.95
    let r: Float = 2.82    // Airbus widebody cabin radius (Ø 5.64 m)
    // Fuselage: −31.8 (rounded droop-snoot nose) → +31.9 (clean upswept taper).
    let fuselage: [(z: Float, r: Float)] = [
        (-31.8, 0.34), (-31.0, 1.15), (-29.4, 2.02), (-26.6, 2.58),
        (-22.0, r), (-6.0, r), (12.0, r), (20.0, r * 0.95),
        (26.5, r * 0.68), (30.2, r * 0.32), (31.9, 0.14)]
    let spec = WidebodySpec(
        kind: .a330,
        fuselage: fuselage, cy: cy, fuseSegments: 40,
        // Rounder, blunter Airbus windscreen cap on the droop-snoot nose.
        screenScale: SCNVector3(0.94, 0.72, 1.35),
        screenPos: SCNVector3(0, cy + 1.5, -27.0),
        wingSpan: 60.3, wingRootChord: 12.6, wingTipChord: 1.9, wingSweep: 13.5,
        wingThickness: 0.74, wingY: 2.05, wingTE_Z: 6.0,
        // Canted wingtip FENCES: short, wide, sharply canted (~45°) — stubby.
        wingHalfSpan: 29.4, tipHeight: 2.4, tipChordFwd: 2.4, tipCant: 0.78,
        lowerFenceHeight: nil,
        engineXs: [9.9], fanRadius: 1.45, nacelleZ: -3.8, nacelleY: 1.5,
        nacelleLen: 6.6, intakeZ: -6.6, exhaustZ: 1.0,
        finBaseZ: 28.2, finBaseY: cy + 2.1, finHeight: 8.6,
        finRootChord: 7.4, finMidChord: 3.6, finThickness: 0.48,
        rudderHeight: 7.4, rudderChord: 2.0,
        stabSpan: 19.4, stabRootChord: 4.8, stabTipChord: 1.5, stabSweep: 4.0,
        stabThickness: 0.34, stabY: cy + 0.8, stabTE_Z: 28.0,
        ailCenterX: 24.7, ailSpan: 4.6, ailChord: 1.3,
        flapCenterX: 11.0, flapSpan: 10.2, flapChord: 2.4,
        surfThickness: 0.22,
        noseZ: -22.2, nosePivotY: 2.72, noseStrutLen: 2.1,
        noseWheelR: 0.58, noseWheelW: 0.22,
        mainZ: 9.4, mainPivotY: 2.80, mainStrutLen: 2.1,
        mainWheelR: 0.68, mainWheelW: 0.28, mainBogieRows: 2, mainLegXs: [4.0],
        centerlineMainZ: nil,
        light: LightSpec(
            navLeft: SCNVector3(-30.2, 2.05, 5.0),
            navRight: SCNVector3(30.2, 2.05, 5.0),
            tail: SCNVector3(0, cy + 1.9, 31.9),
            beacon: SCNVector3(0, cy + 2.9, 2.0),
            landing: SCNVector3(0, 1.4, 6.6)),
        shadowSpan: 60.3, shadowLen: 63.69,
        smokeOffset: SCNVector3(0, 0.7, 9.4))
    return buildWidebody(spec, livery: livery)
}

// MARK: - Airbus A350-900 (widebody TWIN, black cockpit mask, sabre tips)

/// A350-900 — span 64.75 m, len 66.8 m, height 17.05 m. A smooth composite twin.
/// THE recognition cue is the glossy-BLACK "flying goggles" cockpit MASK wrapping
/// the six-panel windscreen; plus curved upswept "sabre" blended wingtips that
/// flow OUT of the wing (not a squared raked tip); two very large Trent XWB
/// engines on a clean airframe; a long slender pointed nose. Pacifica Air
/// flagship.
func buildA350(livery: Livery) -> CraftParts {
    let cy: Float = 2.98
    let r: Float = 2.98    // composite ovoid barrel (Ø 5.96 m)
    // Fuselage: −33.4 (slender pointed A380-derived nose) → +33.4 (downswept
    // tapered tailcone). Len ≈ 66.8.
    let fuselage: [(z: Float, r: Float)] = [
        (-33.4, 0.16), (-32.6, 1.0), (-30.8, 1.98), (-28.0, 2.68),
        (-23.0, r), (-6.0, r), (13.0, r), (21.0, r * 0.95),
        (28.0, r * 0.64), (31.6, 0.28), (33.4, 0.12)]
    let spec = WidebodySpec(
        kind: .a350,
        fuselage: fuselage, cy: cy, fuseSegments: 40,
        // Slender windscreen wrapped by the black mask (cockpitMask draws behind).
        screenScale: SCNVector3(0.86, 0.6, 1.7),
        screenPos: SCNVector3(0, cy + 1.35, -28.4),
        cockpitMask: true,
        wingSpan: 64.75, wingRootChord: 13.0, wingTipChord: 1.6, wingSweep: 15.0,
        wingThickness: 0.78, wingY: 2.1, wingTE_Z: 6.2,
        // Curved sabre tips: tall-ish, curved, blending out of the wing — a
        // taller/steeper cant than the 787's flat raked tip.
        wingHalfSpan: 31.4, tipHeight: 1.9, tipChordFwd: 2.8, tipCant: 0.62,
        lowerFenceHeight: nil,
        // Two very large Trent XWB nacelles.
        engineXs: [10.2], fanRadius: 1.55, nacelleZ: -3.9, nacelleY: 1.5,
        nacelleLen: 6.9, intakeZ: -7.0, exhaustZ: 1.0,
        finBaseZ: 29.6, finBaseY: cy + 2.1, finHeight: 9.0,
        finRootChord: 7.8, finMidChord: 3.6, finThickness: 0.5,
        rudderHeight: 7.8, rudderChord: 2.0,
        stabSpan: 20.4, stabRootChord: 5.0, stabTipChord: 1.6, stabSweep: 4.2,
        stabThickness: 0.36, stabY: cy + 0.8, stabTE_Z: 29.4,
        ailCenterX: 26.0, ailSpan: 4.8, ailChord: 1.35,
        flapCenterX: 11.5, flapSpan: 10.6, flapChord: 2.5,
        surfThickness: 0.22,
        noseZ: -23.4, nosePivotY: 2.74, noseStrutLen: 2.15,
        noseWheelR: 0.6, noseWheelW: 0.24,
        mainZ: 10.0, mainPivotY: 2.82, mainStrutLen: 2.15,
        mainWheelR: 0.7, mainWheelW: 0.30, mainBogieRows: 2, mainLegXs: [4.1],
        centerlineMainZ: nil,
        light: LightSpec(
            navLeft: SCNVector3(-32.4, 2.1, 5.2),
            navRight: SCNVector3(32.4, 2.1, 5.2),
            tail: SCNVector3(0, cy + 1.9, 33.4),
            beacon: SCNVector3(0, cy + 2.9, 2.0),
            landing: SCNVector3(0, 1.4, 6.8)),
        shadowSpan: 64.75, shadowLen: 66.8,
        smokeOffset: SCNVector3(0, 0.7, 10.0))
    return buildWidebody(spec, livery: livery)
}

// MARK: - Boeing 747-400 (widebody, FOUR engines, upper-deck hump)

/// 747-400 — span 64.4 m, len 70.6 m, height 19.4 m. The Queen of the Skies. The
/// defining cue is the forward upper-deck HUMP (a partial second deck faired into
/// the top-forward fuselage). FOUR under-wing high-bypass turbofans (two per
/// wing, inboard + outboard). ~1.8 m canted angular WINGLETS at the tips. A very
/// large tail and a blunt rounded nose. Meridian Air flagship heavy.
func buildB747(livery: Livery) -> CraftParts {
    let cy: Float = 3.35
    let r: Float = 3.25    // main-deck cabin radius (Ø 6.5 m)
    // Main tube: −35.3 (blunt rounded nose) → +35.3 (upswept clean tail). Len ≈70.6.
    let fuselage: [(z: Float, r: Float)] = [
        (-35.3, 0.5), (-34.4, 1.5), (-32.6, 2.5), (-29.8, 3.1),
        (-25.0, r), (-6.0, r), (13.0, r), (22.0, r * 0.95),
        (29.0, r * 0.68), (33.0, r * 0.34), (35.3, 0.16)]
    // Upper-deck hump: a shorter, higher tube faired onto the top-FORWARD crown,
    // running from just aft of the nose back about a third of the body, then
    // blending down into the main spine.
    let upper: [(z: Float, r: Float)] = [
        (-30.0, 0.4), (-28.5, 1.35), (-26.5, 2.0), (-23.0, 2.25),
        (-16.0, 2.25), (-9.0, 2.05), (-3.0, 1.4), (1.5, 0.55)]
    let spec = WidebodySpec(
        kind: .b747,
        fuselage: fuselage, cy: cy, fuseSegments: 44,
        upperDeck: upper, upperDeckCY: cy + 2.55,
        // Cockpit glass set high at the FRONT of the hump.
        screenScale: SCNVector3(0.95, 0.66, 1.35),
        screenPos: SCNVector3(0, cy + 3.0, -28.5),
        wingSpan: 64.4, wingRootChord: 14.5, wingTipChord: 2.0, wingSweep: 18.5,
        wingThickness: 0.85, wingY: 2.35, wingTE_Z: 6.5,
        // ~1.8 m canted angular winglets (distinct bolted-on blades).
        wingHalfSpan: 31.2, tipHeight: 1.8, tipChordFwd: 2.4, tipCant: 0.95,
        lowerFenceHeight: nil,
        // FOUR engines: inboard (under the thick root) + outboard (toward tip).
        engineXs: [8.4, 15.6], fanRadius: 1.45, nacelleZ: -4.0, nacelleY: 1.7,
        nacelleLen: 6.6, intakeZ: -6.8, exhaustZ: 0.8,
        finBaseZ: 31.0, finBaseY: cy + 2.4, finHeight: 10.6,
        finRootChord: 9.0, finMidChord: 4.4, finThickness: 0.56,
        rudderHeight: 9.2, rudderChord: 2.3,
        stabSpan: 22.2, stabRootChord: 5.8, stabTipChord: 1.9, stabSweep: 4.8,
        stabThickness: 0.4, stabY: cy + 1.0, stabTE_Z: 30.8,
        ailCenterX: 26.0, ailSpan: 5.2, ailChord: 1.5,
        flapCenterX: 11.5, flapSpan: 11.0, flapChord: 2.8,
        surfThickness: 0.24,
        noseZ: -25.0, nosePivotY: 3.10, noseStrutLen: 2.5,
        noseWheelR: 0.62, noseWheelW: 0.24,
        // Two wing bogies + two body bogies: approximated as two 2-row bogies per
        // side at an inner (body) and outer (wing) station.
        mainZ: 9.5, mainPivotY: 3.18, mainStrutLen: 2.5,
        mainWheelR: 0.68, mainWheelW: 0.28, mainBogieRows: 2, mainLegXs: [3.2, 5.6],
        centerlineMainZ: nil,
        light: LightSpec(
            navLeft: SCNVector3(-32.2, 2.35, 5.5),
            navRight: SCNVector3(32.2, 2.35, 5.5),
            tail: SCNVector3(0, cy + 2.2, 35.3),
            beacon: SCNVector3(0, cy + 5.6, 2.0),
            landing: SCNVector3(0, 1.6, 6.8)),
        shadowSpan: 64.4, shadowLen: 70.6,
        smokeOffset: SCNVector3(0, 0.9, 9.5))
    return buildWidebody(spec, livery: livery)
}

// MARK: - McDonnell Douglas DC-10-30 (widebody TRIJET, tail engine)

/// DC-10-30 — span 50.39 m, len 55.35 m, height 17.55 m. A widebody TRIJET: two
/// under-wing high-bypass nacelles PLUS a third engine mounted HIGH through the
/// base of the fin in a straight-through "banjo" fairing — the round intake
/// protrudes at the front of the fin and the fin is planted on top of it (THE
/// DC-10 tell). A stout ~6 m circular tube, 35° swept low wing with plain tips
/// (no winglets), and a DC-10-30 centreline extra main gear (2+4+4+2 wheels).
/// Altair Express classic widebody.
func buildDC10(livery: Livery) -> CraftParts {
    let cy: Float = 3.0
    let r: Float = 3.01    // widebody cabin radius (Ø 6.02 m)
    // Fuselage: −27.5 (rounded drooped radome) → +27.85 (clean upswept tail).
    let fuselage: [(z: Float, r: Float)] = [
        (-27.5, 0.16), (-26.8, 1.05), (-25.2, 2.0), (-22.6, 2.66),
        (-18.5, r), (-6.0, r), (10.0, r), (18.0, r * 0.95),
        (23.0, r * 0.70), (26.2, r * 0.34), (27.85, 0.14)]
    let spec = WidebodySpec(
        kind: .dc10,
        fuselage: fuselage, cy: cy, fuseSegments: 40,
        // Fairly blunt rounded Douglas flight-deck cap.
        screenScale: SCNVector3(0.9, 0.7, 1.3),
        screenPos: SCNVector3(0, cy + 1.55, -23.0),
        wingSpan: 50.39, wingRootChord: 11.5, wingTipChord: 1.9, wingSweep: 12.5,
        wingThickness: 0.72, wingY: 2.05, wingTE_Z: 5.8,
        // Plain wingtips — NO winglets on production DC-10s.
        wingHalfSpan: 24.5, tipHeight: 0, tipChordFwd: 0, tipCant: 0,
        lowerFenceHeight: nil,
        // Two big fat under-wing high-bypass CF6 nacelles.
        engineXs: [8.6], fanRadius: 1.45, nacelleZ: -3.6, nacelleY: 1.5,
        nacelleLen: 6.4, intakeZ: -6.5, exhaustZ: 1.0,
        // Third engine HIGH in the fin base (banjo, straight-through).
        tailEngine: TailEngineSpec(z: 26.8, y: cy + 3.6, fanRadius: 1.35,
                                   nacelleLen: 7.2, intakeZ: 23.4, exhaustZ: 30.8),
        // Fin planted ON TOP of the banjo → raised base (finBaseY above the roof).
        finBaseZ: 27.4, finBaseY: cy + 3.5, finHeight: 8.2,
        finRootChord: 7.2, finMidChord: 3.4, finThickness: 0.5,
        rudderHeight: 7.2, rudderChord: 1.9,
        // Low conventional horizontal stab on the aft-fuselage sides.
        stabSpan: 18.4, stabRootChord: 4.6, stabTipChord: 1.5, stabSweep: 3.8,
        stabThickness: 0.34, stabY: cy + 0.8, stabTE_Z: 24.6,
        ailCenterX: 20.5, ailSpan: 4.4, ailChord: 1.3,
        flapCenterX: 9.5, flapSpan: 9.0, flapChord: 2.3,
        surfThickness: 0.22,
        noseZ: -18.8, nosePivotY: 2.76, noseStrutLen: 2.15,
        noseWheelR: 0.58, noseWheelW: 0.22,
        mainZ: 9.0, mainPivotY: 2.84, mainStrutLen: 2.15,
        mainWheelR: 0.68, mainWheelW: 0.28, mainBogieRows: 2, mainLegXs: [3.6],
        // DC-10-30 centreline extra main gear (2 wheels) between the two mains.
        centerlineMainZ: 6.6,
        light: LightSpec(
            navLeft: SCNVector3(-25.2, 2.05, 5.0),
            navRight: SCNVector3(25.2, 2.05, 5.0),
            tail: SCNVector3(0, cy + 11.2, 27.4),
            beacon: SCNVector3(0, cy + 2.9, 2.0),
            landing: SCNVector3(0, 1.4, 6.5)),
        shadowSpan: 50.39, shadowLen: 55.35,
        smokeOffset: SCNVector3(0, 0.7, 9.0))
    return buildWidebody(spec, livery: livery)
}
