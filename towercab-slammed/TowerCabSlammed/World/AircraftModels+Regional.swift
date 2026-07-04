import Foundation
import SceneKit
import UIKit

// =============================================================================
// Regional airframes — four fully-rigged builds graduating off placeholders:
//
//   buildATR72     → atr72   (ATR 72-600): HIGH-wing TWIN TURBOPROP, CONVENTIONAL
//     dorsal-filleted fin (NOT a T-tail), near-1:1 STUBBY fuselage, big low-slung
//     belly with side gear sponsons, 6-blade props nearly brushing the cabin.
//     span 27.05 m, length 27.17 m.
//   buildDash8Q400 → dash8   (Bombardier Dash 8 Q400): HIGH-wing TWIN TURBOPROP,
//     T-TAIL, LONG stretched fuselage with a POINTED nose, tall main gear that
//     retracts REARWARD into unusually LONG engine nacelles, 6-blade props.
//     span 28.4 m, length 32.83 m.
//   buildE190      → e190    (Embraer E190): regional JET, LOW swept wing, two
//     UNDER-WING turbofans on pylons, CONVENTIONAL low tail (fin + low stab),
//     double-bubble fuselage, canted blade WINGLETS, big cabin windows.
//     span 28.72 m, length 36.24 m.
//   buildCRJ900    → crj900  (Bombardier CRJ900): regional JET, LOW swept wing,
//     two REAR-FUSELAGE turbofans, T-TAIL, the longest/thinnest silhouette of the
//     set (36.2 m long on a 24.85 m span), clean wingtips, low-riding stance.
//
// Turboprops (ATR/Dash8) use twinPropLive (spinning 6-blade prop discs, from
// AircraftModels+Turboprop.swift) — NOT fanGroups. The jets (E190/CRJ900) use
// makeFanGroup + makeHeatWash per nacelle exactly like buildComet / buildE175.
//
// All four carry retractable gear via the Comet-style `gear` fold list
// (liveGearLeg-style pivots + live wheels + real oleos), mirroring buildKingAir350
// (turboprops) and buildComet / buildE175 (jets).
//
// Model space matches the rest of the fleet: node origin = ground contact (bottom
// of tires), nose = −Z, tail = +Z. Static shell → AirframeCache; live parts
// (props / fans / heat-wash / surfaces / wheels / oleos / lights) stay OUT of the
// cache and are added onto `body`.
// =============================================================================

// MARK: - Twin-prop live rig (self-contained, cross-file-safe)

/// A twin turboprop's two spinning prop discs. `twinPropLive` in
/// AircraftModels+Turboprop.swift is file-private, so this file rebuilds the
/// twin rig from the PUBLIC makePropGroup, exactly like buildBaron58's twin in
/// AircraftModels+GA.swift: two makePropGroup discs, each spinning IN PLACE about
/// its own nacelle hub, with engine 2 MIRRORED to engine 1 via a per-frame
/// SCNTransformConstraint. The rig only ever drives engine 1 (`propGroup` spin +
/// `blades`/`blurDisc` opacity); the constraint copies engine 1's spin + blur
/// opacity onto engine 2, so both read identically without orbiting across the
/// nose. Returns the CraftParts prop fields ready to hand straight through.
private func regionalTwinProp(body: SCNNode, hubLeft: SCNVector3, hubRight: SCNVector3,
                              bladeCount: Int, bladeLength: CGFloat,
                              spinnerScale: Float, discDiameter: CGFloat)
    -> (propGroup: SCNNode, blades: SCNNode, blurDisc: SCNNode) {
    let p1 = makePropGroup(at: hubLeft, bladeCount: bladeCount, bladeLength: bladeLength,
                           spinnerScale: spinnerScale, discDiameter: discDiameter)
    let p2 = makePropGroup(at: hubRight, bladeCount: bladeCount, bladeLength: bladeLength,
                           spinnerScale: spinnerScale, discDiameter: discDiameter)
    body.addChildNode(p1.group)
    body.addChildNode(p2.group)

    // Engine-2 mirror: a per-frame constraint copies engine 1's local spin angle
    // and live blur-node opacities onto engine 2, rebuilding engine 2's transform
    // as its fixed translation ∘ engine-1 rotation. Weak captures avoid a cycle.
    let mirror = SCNTransformConstraint(inWorldSpace: false) {
        [weak g1 = p1.group, weak b1 = p1.blades, weak d1 = p1.disc,
         weak b2 = p2.blades, weak d2 = p2.disc] _, transform in
        var t = transform
        let z = g1?.eulerAngles.z ?? 0
        let rot = SCNMatrix4MakeRotation(z, 0, 0, 1)
        var placed = SCNMatrix4Identity
        placed = SCNMatrix4Translate(placed, hubRight.x, hubRight.y, hubRight.z)
        t = SCNMatrix4Mult(rot, placed)
        b2?.opacity = b1?.opacity ?? 1
        d2?.opacity = d1?.opacity ?? 0
        return t
    }
    p2.group.constraints = [mirror]

    // The rig spins engine 1 (`propGroup`) and fades engine 1's blades/disc; the
    // constraint mirrors both onto engine 2.
    return (p1.group, p1.blades, p1.disc)
}

// MARK: - ATR 72-600 (HIGH-wing twin turboprop, conventional tail)

/// atr72 — HIGH straight wing on top of a stubby ~1:1 fuselage, two PW127
/// turboprops with big 6-blade props on the wing leading edge (discs nearly
/// touching the cabin sides), a CONVENTIONAL tall swept fin with a pronounced
/// dorsal fillet (NOT a T-tail — the key ATR vs Dash 8 tell), low-slung belly
/// with fuselage-side main-gear sponsons, retractable tricycle gear.
/// span 27.05 m, length 27.17 m.
func buildATR72(livery: Livery) -> CraftParts {
    let pal = livery.palette
    // Low-slung belly: the high wing sits on top, so the fuselage centreline is
    // fairly low and the props hang big off the wing above it.
    let cy: Float = 1.98

    let wingY: Float = cy + 1.28   // HIGH wing sits on the cabin roof
    let nacX: Float = 2.35         // props nearly brush the cabin sides
    let nacY: Float = wingY - 0.10 // nacelles on/under the high wing LE
    let propZ: Float = -2.35       // prop plane well ahead of the wing LE

    let airframe = AirframeCache.airframe(kind: .atr72, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)

        // Stubby near-circular constant-section tube, 27.17 m nose-to-tail
        // (max radius ~1.38 ⇒ Ø 2.77 m). Rounded, fairly blunt slightly-drooped
        // radome up front; short conical tailcone sweeping up to the tall fin.
        let fus = latheNode([(-13.55, 0.14), (-13.25, 0.52), (-12.50, 0.90), (-11.35, 1.18),
                             (-9.80, 1.34), (-7.20, 1.38), (5.60, 1.38), (8.40, 1.28),
                             (10.90, 0.94), (12.70, 0.50), (13.60, 0.14)],
                            segments: 30,
                            material: fuselageMaterial(kind: .atr72, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Six-panel wraparound flight-deck glazing on the rounded, fairly high nose.
        let screen = SCNNode(geometry: SCNSphere(radius: 0.78))
        (screen.geometry as? SCNSphere)?.segmentCount = 24
        screen.geometry?.materials = [canopyGlassMaterial()]
        screen.scale = SCNVector3(0.82, 0.56, 1.05)
        screen.position = SCNVector3(0, cy + 0.72, -10.9)
        root.addChildNode(screen)

        // Raised wing box / fairing over the cabin roof (the ATR shoulder bulge).
        let box = SCNNode(geometry: SCNBox(width: 2.4, height: 0.44, length: 3.4, chamferRadius: 0.22))
        box.geometry?.materials = [bodyMat]
        box.position = SCNVector3(0, cy + 1.06, -0.5)
        root.addChildNode(box)

        // HIGH straight (unswept) constant-taper wing, 27.05 m span, high aspect
        // ratio. Root TE at z 0.4; NO winglets (clean squared tips).
        let wing = wingNode(span: 27.05, rootChord: 2.55, tipChord: 1.55, sweep: 0.15,
                            thickness: 0.26, material: bodyMat)
        wing.position = SCNVector3(0, wingY, 0.4)
        root.addChildNode(wing)
        if let tip = pal.wingtip {
            let tm = pbrMaterial(tip, roughness: pal.roughness)
            for x in [Float(-13.35), Float(13.35)] {
                let cap = SCNNode(geometry: SCNBox(width: 0.28, height: 0.24, length: 1.55, chamferRadius: 0.05))
                cap.geometry?.materials = [tm]
                cap.position = SCNVector3(x, wingY, -0.6)
                root.addChildNode(cap)
            }
        }

        // Two turboprop nacelles on the wing LE, projecting well forward with a
        // long slim spinner; each has a lower cooling intake near the spinner.
        let nacMat = pbrMaterial(pal.body, roughness: max(0.15, pal.roughness - 0.05),
                                 metalness: min(1, pal.metalness + 0.1))
        let intakeMat = pbrMaterial(UIColor(white: 0.05, alpha: 1), roughness: 0.4)
        for s in [Float(-1), Float(1)] {
            // Slim elongated nacelle projecting ahead of the LE, tapering aft over
            // the wing to house the main-gear... no: ATR mains go into the belly
            // sponson. Keep the nacelle a clean slim pod.
            let nac = latheNode([(-2.10, 0.16), (-1.90, 0.34), (-1.30, 0.44), (-0.20, 0.46),
                                 (1.10, 0.42), (2.30, 0.26), (3.05, 0.10)],
                                segments: 20, material: nacMat)
            nac.position = SCNVector3(nacX * s, nacY, -0.05)
            root.addChildNode(nac)
            // Lower cooling scoop just under the spinner.
            let scoop = SCNNode(geometry: SCNBox(width: 0.40, height: 0.18, length: 0.4, chamferRadius: 0.08))
            scoop.geometry?.materials = [intakeMat]
            scoop.position = SCNVector3(nacX * s, nacY - 0.34, -2.05)
            root.addChildNode(scoop)
        }

        // Fuselage-side main-gear SPONSONS at the belly (ATR mains retract into
        // these, not the wing) — a pair of streamlined side bulges low on the tube.
        for s in [Float(-1), Float(1)] {
            let spon = latheNode([(-1.6, 0.05), (-1.1, 0.30), (-0.2, 0.40), (0.8, 0.36), (1.7, 0.08)],
                                 segments: 16, material: bodyMat)
            spon.scale = SCNVector3(0.72, 0.62, 1.0)
            spon.position = SCNVector3(0.95 * s, cy - 0.92, -0.2)
            root.addChildNode(spon)
        }

        // CONVENTIONAL tall broad fin with a pronounced swept LE and a big forward
        // DORSAL FILLET blending into the fuselage spine (the ATR silhouette).
        // Horizontal stab is LOW on the fuselage/base of the fin (NOT a T-tail).
        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0.10, y: 0))
        finPath.addLine(to: CGPoint(x: 0.55, y: 4.30))
        finPath.addQuadCurve(to: CGPoint(x: 1.85, y: 4.42), controlPoint: CGPoint(x: 1.00, y: 4.55))
        finPath.addQuadCurve(to: CGPoint(x: 3.20, y: 0.90), controlPoint: CGPoint(x: 2.95, y: 2.1))
        // Long dorsal fillet raking forward down the spine.
        finPath.addLine(to: CGPoint(x: 4.35, y: 0.30))
        finPath.addQuadCurve(to: CGPoint(x: 5.30, y: 0.0), controlPoint: CGPoint(x: 4.90, y: 0.05))
        finPath.close()
        let fin = finNode(path: finPath, thickness: 0.24, material: tailMat)
        fin.position = SCNVector3(0, cy + 0.30, 12.6)
        root.addChildNode(fin)

        // LOW horizontal stab on the aft fuselage at the base of the fin.
        let stab = wingNode(span: 8.0, rootChord: 1.9, tipChord: 1.0, sweep: 0.4,
                            thickness: 0.16, material: bodyMat)
        stab.position = SCNVector3(0, cy + 0.44, 12.3)
        root.addChildNode(stab)
        if livery == .meridianVIP {
            let accentMat = pbrMaterial(pal.accent, roughness: 0.25, metalness: 0.7)
            let crest = SCNNode(geometry: SCNBox(width: 0.26, height: 0.62, length: 0.44, chamferRadius: 0.08))
            crest.geometry?.materials = [accentMat]
            crest.position = SCNVector3(0, cy + 3.2, 11.0)
            root.addChildNode(crest)
        }
        return root
    }

    let body = SCNNode()
    body.addChildNode(airframe)

    // Two 6-blade turboprops, Ø ~3.93 m (big Ratier-Figeac discs), one per
    // nacelle. Engine 1 spins in place; engine 2 mirrors it (propGroup non-nil so
    // the update fade-branch runs).
    let twin = regionalTwinProp(body: body,
                                hubLeft: SCNVector3(-nacX, nacY, propZ),
                                hubRight: SCNVector3(nacX, nacY, propZ),
                                bladeCount: 6, bladeLength: 1.75, spinnerScale: 1.2,
                                discDiameter: 3.93)

    // Live control surfaces. wingNode origin = ROOT TRAILING EDGE (z 0.4), so the
    // TE is AT wing.z; TE_z(x) = wing.z + |x|/halfSpan·(sweep + tipChord − rootChord)
    // = 0.4 + |x|/13.525·(0.15 + 1.55 − 2.55) = 0.4 − 0.0629·|x|. Nearly straight.
    let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
    let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
    let surfBodyMat = bodyMat
    let teSlope: Float = (0.15 + 1.55 - 2.55) / 13.525   // ≈ −0.0629
    let rootTE_Z: Float = 0.4                            // root trailing edge = wing.z

    var ailerons: [Surface] = []
    var flaps: [Surface] = []
    for s in [Float(-1), Float(1)] {
        // Aileron outboard, centered at |x| 10.0.
        let a = hingedSurfaceNode(span: 3.6, chord: 0.6, thickness: 0.14, material: surfBodyMat)
        a.position = SCNVector3(s * 10.0, wingY, rootTE_Z + teSlope * 10.0)
        ailerons.append(Surface(node: a, sign: s))
        body.addChildNode(a)
        // Flap inboard, between fuselage and nacelle + just outboard.
        let fl = hingedSurfaceNode(span: 4.4, chord: 0.7, thickness: 0.14, material: surfBodyMat)
        fl.position = SCNVector3(s * 4.4, wingY, rootTE_Z + teSlope * 4.4)
        flaps.append(Surface(node: fl, sign: 1))
        body.addChildNode(fl)
    }
    // Elevator on the LOW stab TE (stab node.z = 12.3 IS the trailing edge).
    var elevator: [Surface] = []
    let elev = hingedSurfaceNode(span: 7.6, chord: 0.65, thickness: 0.12, material: surfBodyMat)
    elev.position = SCNVector3(0, cy + 0.44, 12.3)
    elevator.append(Surface(node: elev, sign: 1))
    body.addChildNode(elev)
    // Rudder at the fin TE (finNode extends forward; TE near node.z 12.6).
    var rudder: [Surface] = []
    let rud = hingedRudderNode(height: 4.1, chord: 0.8, thickness: 0.22, material: tailMat)
    rud.position = SCNVector3(0, cy + 0.30, 12.6)
    rudder.append(Surface(node: rud, sign: 1))
    body.addChildNode(rud)

    // Retractable gear — live wheels + real oleos (Comet pattern). Nose folds
    // forward; mains fold inboard into the belly sponsons.
    let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
    let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)
    let strutMat = pbrMaterial(UIColor(white: 0.75, alpha: 1), roughness: 0.35, metalness: 0.7)

    var wheels: [(node: SCNNode, radius: Float)] = []
    var oleos: [(node: SCNNode, restY: Float, travel: Float)] = []
    var gear: [(node: SCNNode, foldedEuler: SCNVector3)] = []
    var gearContacts: [SCNVector3] = []

    func regGearLeg(pivotAt: SCNVector3, strutLen: Float, wheelRadius: CGFloat,
                    wheelWidth: CGFloat, twin: Bool) -> (pivot: SCNNode, oleo: SCNNode, wheels: [SCNNode]) {
        let pivot = SCNNode()
        pivot.position = pivotAt
        let oleo = SCNNode()
        let strut = strutNode(from: SCNVector3(0, 0, 0), to: SCNVector3(0, -strutLen, 0),
                              radius: 0.06, material: strutMat)
        oleo.addChildNode(strut.flattenedClone())
        var ws: [SCNNode] = []
        let xs: [Float] = twin ? [-0.15, 0.15] : [0]
        for x in xs {
            let w = wheelNode(radius: wheelRadius, width: wheelWidth, tire: tire, hub: hub)
            w.position = SCNVector3(x, -strutLen, 0)
            oleo.addChildNode(w)
            ws.append(w)
        }
        pivot.addChildNode(oleo)
        return (pivot, oleo, ws)
    }

    // Nose gear under the nose, folds forward. Short legs (low ground clearance).
    let nose = regGearLeg(pivotAt: SCNVector3(0, 1.02, -9.6), strutLen: 0.66,
                          wheelRadius: 0.34, wheelWidth: 0.13, twin: true)
    body.addChildNode(nose.pivot)
    for w in nose.wheels { wheels.append((w, 0.34)) }
    gear.append((nose.pivot, SCNVector3(1.7, 0, 0)))
    // Mains at the belly sponsons, fold inboard. Short legs (low-slung belly):
    // pivot y 0.94; strut 0.54 + radius 0.40 ⇒ contact at y ≈ 0.
    for s in [Float(-1), Float(1)] {
        let main = regGearLeg(pivotAt: SCNVector3(1.35 * s, 0.94, -0.2), strutLen: 0.54,
                              wheelRadius: 0.40, wheelWidth: 0.20, twin: true)
        body.addChildNode(main.pivot)
        gear.append((main.pivot, SCNVector3(0, 0, 1.8 * -s)))
        for w in main.wheels { wheels.append((w, 0.40)) }
        oleos.append((main.oleo, 0, 0.10))
        gearContacts.append(SCNVector3(1.35 * s, 0, -0.2))
    }

    let shadow = makeContactShadow(span: 27.05, length: 27.17)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-13.5, wingY, -0.6),
        navRight: SCNVector3(13.5, wingY, -0.6),
        tail: SCNVector3(0, cy + 0.30, 12.7),
        beacon: SCNVector3(0, cy + 4.6, 11.2),
        landing: SCNVector3(0, cy - 0.4, -1.0)))
    return CraftParts(body: body, propGroup: twin.propGroup, blades: twin.blades,
                      blurDisc: twin.blurDisc, fanGroups: [], heatWash: [],
                      beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      navNodes: kit.navs, scalingHalos: kit.halos, contactShadow: shadow,
                      landingLight: kit.light, landingGlow: kit.glow, gear: gear,
                      smokeOffset: SCNVector3(0, 0.35, -0.2),
                      gearContacts: gearContacts, wheels: wheels, oleos: oleos,
                      ailerons: ailerons, elevator: elevator, rudder: rudder, flaps: flaps)
}

// MARK: - Bombardier Dash 8 Q400 (HIGH-wing twin turboprop, T-tail)

/// dash8 — HIGH straight wing on a LONG stretched tube with a sharply POINTED
/// nose; two PW150A turboprops with big 6-blade props on unusually LONG nacelles
/// that extend far aft of the wing (they house the REARWARD-retracting main
/// gear); a T-TAIL (stab at the top of a tall swept fin — the strongest Q400 vs
/// ATR tell). span 28.4 m, length 32.83 m.
func buildDash8Q400(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 2.05

    let wingY: Float = cy + 1.30   // HIGH wing on the cabin roof
    let nacX: Float = 2.55
    let nacY: Float = wingY - 0.14 // nacelles slung on the high wing
    let propZ: Float = -2.60       // props well ahead of the wing LE

    let airframe = AirframeCache.airframe(kind: .dash8, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)

        // LONG slender near-circular tube, 32.83 m nose-to-tail (max radius ~1.34
        // ⇒ Ø 2.69 m) — clearly stretched, length/span > 1.15. Sharply POINTED,
        // tapered nose (sleeker/faster than the ATR's blunt radome); long slim
        // tailcone sweeping up to the tall T-tail fin.
        let fus = latheNode([(-16.40, 0.05), (-16.10, 0.30), (-15.40, 0.68), (-14.30, 1.02),
                             (-12.70, 1.26), (-9.60, 1.34), (7.40, 1.34), (10.60, 1.20),
                             (13.20, 0.84), (15.20, 0.44), (16.40, 0.11)],
                            segments: 30,
                            material: fuselageMaterial(kind: .dash8, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Multi-panel wraparound flight-deck glazing set into the pointed nose.
        let screen = SCNNode(geometry: SCNSphere(radius: 0.74))
        (screen.geometry as? SCNSphere)?.segmentCount = 24
        screen.geometry?.materials = [canopyGlassMaterial()]
        screen.scale = SCNVector3(0.78, 0.52, 1.2)
        screen.position = SCNVector3(0, cy + 0.70, -13.6)
        root.addChildNode(screen)

        // Raised wing box / fairing over the cabin roof.
        let box = SCNNode(geometry: SCNBox(width: 2.3, height: 0.42, length: 3.2, chamferRadius: 0.20))
        box.geometry?.materials = [bodyMat]
        box.position = SCNVector3(0, cy + 1.08, -1.6)
        root.addChildNode(box)

        // HIGH straight (unswept) wing, 28.4 m span, set noticeably forward of
        // mid-length. Root TE at z −0.6; NO winglets (clean squared tips).
        let wing = wingNode(span: 28.4, rootChord: 2.7, tipChord: 1.5, sweep: 0.15,
                            thickness: 0.26, material: bodyMat)
        wing.position = SCNVector3(0, wingY, -0.6)
        root.addChildNode(wing)
        if let tip = pal.wingtip {
            let tm = pbrMaterial(tip, roughness: pal.roughness)
            for x in [Float(-14.0), Float(14.0)] {
                let cap = SCNNode(geometry: SCNBox(width: 0.28, height: 0.24, length: 1.5, chamferRadius: 0.05))
                cap.geometry?.materials = [tm]
                cap.position = SCNVector3(x, wingY, -1.6)
                root.addChildNode(cap)
            }
        }

        // Two unusually LONG deep nacelles on the wing LE that extend far AFT of
        // the wing trailing edge (they swallow the rearward-folding main gear —
        // the Q400 signature). Slim spinner up front.
        let nacMat = pbrMaterial(pal.body, roughness: max(0.15, pal.roughness - 0.05),
                                 metalness: min(1, pal.metalness + 0.1))
        let intakeMat = pbrMaterial(UIColor(white: 0.05, alpha: 1), roughness: 0.4)
        for s in [Float(-1), Float(1)] {
            // Long deep pod: forward spinner cap → deep midbody → long tapered
            // tail well behind the wing TE.
            let nac = latheNode([(-2.30, 0.16), (-2.10, 0.36), (-1.40, 0.50), (-0.20, 0.54),
                                 (1.40, 0.52), (2.90, 0.44), (4.20, 0.30), (5.05, 0.12)],
                                segments: 22, material: nacMat)
            nac.position = SCNVector3(nacX * s, nacY, -0.05)
            root.addChildNode(nac)
            // Lower cooling scoop near the spinner.
            let scoop = SCNNode(geometry: SCNBox(width: 0.40, height: 0.18, length: 0.42, chamferRadius: 0.08))
            scoop.geometry?.materials = [intakeMat]
            scoop.position = SCNVector3(nacX * s, nacY - 0.40, -2.25)
            root.addChildNode(scoop)
        }

        // T-TAIL — horizontal stab at the TOP of a tall swept fin (out of the
        // prop wash). Broad fin with a swept LE and a dorsal fillet. This is the
        // single strongest Q400 vs ATR identifier.
        let finTop: Float = 4.55
        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0.10, y: 0))
        finPath.addLine(to: CGPoint(x: 1.85, y: CGFloat(finTop)))
        finPath.addQuadCurve(to: CGPoint(x: 3.15, y: CGFloat(finTop) - 0.05),
                             controlPoint: CGPoint(x: 2.45, y: CGFloat(finTop) + 0.12))
        finPath.addQuadCurve(to: CGPoint(x: 4.05, y: 1.2), controlPoint: CGPoint(x: 3.95, y: 2.6))
        // Dorsal fillet raking forward at the base.
        finPath.addLine(to: CGPoint(x: 5.05, y: 0.28))
        finPath.addQuadCurve(to: CGPoint(x: 5.90, y: 0.0), controlPoint: CGPoint(x: 5.50, y: 0.05))
        finPath.close()
        let fin = finNode(path: finPath, thickness: 0.24, material: tailMat)
        fin.position = SCNVector3(0, cy + 0.30, 15.3)
        root.addChildNode(fin)

        // Horizontal stab ATOP the fin (T-tail), swept, spanning the fin top.
        let stab = wingNode(span: 8.6, rootChord: 2.0, tipChord: 1.0, sweep: 0.6,
                            thickness: 0.16, material: bodyMat)
        stab.position = SCNVector3(0, cy + 0.30 + finTop, 14.7)
        root.addChildNode(stab)
        if livery == .meridianVIP {
            let accentMat = pbrMaterial(pal.accent, roughness: 0.25, metalness: 0.7)
            let crest = SCNNode(geometry: SCNBox(width: 0.26, height: 0.60, length: 0.44, chamferRadius: 0.08))
            crest.geometry?.materials = [accentMat]
            crest.position = SCNVector3(0, cy + 3.4, 13.6)
            root.addChildNode(crest)
        }
        return root
    }

    let body = SCNNode()
    body.addChildNode(airframe)

    // Two 6-blade turboprops, Ø ~4.11 m (big Dowty discs), one per nacelle.
    let twin = regionalTwinProp(body: body,
                                hubLeft: SCNVector3(-nacX, nacY, propZ),
                                hubRight: SCNVector3(nacX, nacY, propZ),
                                bladeCount: 6, bladeLength: 1.85, spinnerScale: 1.2,
                                discDiameter: 4.11)

    // Live control surfaces. wingNode origin = ROOT TRAILING EDGE (z −0.6), so the
    // TE is AT wing.z; TE_z(x) = wing.z + |x|/halfSpan·(sweep + tipChord − rootChord)
    // = −0.6 + |x|/14.2·(0.15 + 1.5 − 2.7) = −0.6 − 0.0739·|x|. Nearly straight.
    let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
    let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
    let surfBodyMat = bodyMat
    let teSlope: Float = (0.15 + 1.5 - 2.7) / 14.2       // ≈ −0.0739
    let rootTE_Z: Float = -0.6                           // root trailing edge = wing.z

    var ailerons: [Surface] = []
    var flaps: [Surface] = []
    for s in [Float(-1), Float(1)] {
        let a = hingedSurfaceNode(span: 3.8, chord: 0.62, thickness: 0.14, material: surfBodyMat)
        a.position = SCNVector3(s * 10.4, wingY, rootTE_Z + teSlope * 10.4)
        ailerons.append(Surface(node: a, sign: s))
        body.addChildNode(a)
        let fl = hingedSurfaceNode(span: 4.6, chord: 0.72, thickness: 0.14, material: surfBodyMat)
        fl.position = SCNVector3(s * 4.6, wingY, rootTE_Z + teSlope * 4.6)
        flaps.append(Surface(node: fl, sign: 1))
        body.addChildNode(fl)
    }
    // T-tail elevator on the stab TE atop the fin (stab.y = cy+0.30+finTop;
    // stab node.z = 14.7 IS the trailing edge).
    var elevator: [Surface] = []
    let elev = hingedSurfaceNode(span: 8.2, chord: 0.7, thickness: 0.12, material: surfBodyMat)
    elev.position = SCNVector3(0, cy + 0.30 + 4.55, 14.7)
    elevator.append(Surface(node: elev, sign: 1))
    body.addChildNode(elev)
    // Rudder at the fin TE (finNode extends forward; TE near node.z 15.3).
    var rudder: [Surface] = []
    let rud = hingedRudderNode(height: 4.35, chord: 0.85, thickness: 0.22, material: tailMat)
    rud.position = SCNVector3(0, cy + 0.30, 15.3)
    rudder.append(Surface(node: rud, sign: 1))
    body.addChildNode(rud)

    // Retractable gear — live wheels + real oleos. Nose folds forward; mains
    // retract REARWARD into the long nacelles (the Q400 signature) — tall main
    // legs from the nacelles.
    let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
    let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)
    let strutMat = pbrMaterial(UIColor(white: 0.75, alpha: 1), roughness: 0.35, metalness: 0.7)

    var wheels: [(node: SCNNode, radius: Float)] = []
    var oleos: [(node: SCNNode, restY: Float, travel: Float)] = []
    var gear: [(node: SCNNode, foldedEuler: SCNVector3)] = []
    var gearContacts: [SCNVector3] = []

    func regGearLeg(pivotAt: SCNVector3, strutLen: Float, wheelRadius: CGFloat,
                    wheelWidth: CGFloat, twin: Bool) -> (pivot: SCNNode, oleo: SCNNode, wheels: [SCNNode]) {
        let pivot = SCNNode()
        pivot.position = pivotAt
        let oleo = SCNNode()
        let strut = strutNode(from: SCNVector3(0, 0, 0), to: SCNVector3(0, -strutLen, 0),
                              radius: 0.06, material: strutMat)
        oleo.addChildNode(strut.flattenedClone())
        var ws: [SCNNode] = []
        let xs: [Float] = twin ? [-0.15, 0.15] : [0]
        for x in xs {
            let w = wheelNode(radius: wheelRadius, width: wheelWidth, tire: tire, hub: hub)
            w.position = SCNVector3(x, -strutLen, 0)
            oleo.addChildNode(w)
            ws.append(w)
        }
        pivot.addChildNode(oleo)
        return (pivot, oleo, ws)
    }

    // Nose gear under the pointed nose, folds forward.
    let nose = regGearLeg(pivotAt: SCNVector3(0, 1.06, -12.1), strutLen: 0.70,
                          wheelRadius: 0.34, wheelWidth: 0.13, twin: true)
    body.addChildNode(nose.pivot)
    for w in nose.wheels { wheels.append((w, 0.34)) }
    gear.append((nose.pivot, SCNVector3(1.7, 0, 0)))
    // Mains under the nacelles, TALL legs, fold rearward-up. Pivot y = nacY−0.30;
    // strut sized so contact (pivot − strut − radius) lands at y ≈ 0.
    let mainPivotY: Float = nacY - 0.30
    let mainStrutLen: Float = mainPivotY - 0.44   // wheel radius ⇒ contact ≈ 0
    for s in [Float(-1), Float(1)] {
        let main = regGearLeg(pivotAt: SCNVector3(nacX * s, mainPivotY, 0.2), strutLen: mainStrutLen,
                              wheelRadius: 0.44, wheelWidth: 0.22, twin: true)
        body.addChildNode(main.pivot)
        // Mains rotate up-and-AFT into the back of the nacelle (Q400 signature).
        gear.append((main.pivot, SCNVector3(1.6, 0, 0)))
        for w in main.wheels { wheels.append((w, 0.44)) }
        oleos.append((main.oleo, 0, 0.11))
        gearContacts.append(SCNVector3(nacX * s, 0, 0.2))
    }

    let shadow = makeContactShadow(span: 28.4, length: 32.83)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-14.2, wingY, -1.6),
        navRight: SCNVector3(14.2, wingY, -1.6),
        tail: SCNVector3(0, cy + 0.30 + 4.55, 16.6),   // atop the T-tail
        beacon: SCNVector3(0, cy + 4.9, 13.8),
        landing: SCNVector3(0, nacY - 0.3, -1.2)))
    return CraftParts(body: body, propGroup: twin.propGroup, blades: twin.blades,
                      blurDisc: twin.blurDisc, fanGroups: [], heatWash: [],
                      beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      navNodes: kit.navs, scalingHalos: kit.halos, contactShadow: shadow,
                      landingLight: kit.light, landingGlow: kit.glow, gear: gear,
                      smokeOffset: SCNVector3(0, 0.35, 0.2),
                      gearContacts: gearContacts, wheels: wheels, oleos: oleos,
                      ailerons: ailerons, elevator: elevator, rudder: rudder, flaps: flaps)
}

// MARK: - Embraer E190 (regional jet, under-wing engines, conventional low tail)

/// e190 — LOW swept wing with two UNDER-WING CF34-10E turbofans on pylons, a
/// CONVENTIONAL low tail (fin + low horizontal stab, NOT a T-tail — the E190 vs
/// CRJ tell), a double-bubble fuselage with unusually LARGE cabin windows, and
/// canted blade WINGLETS. A scaled-up sibling of buildE175: span 28.72 m,
/// length 36.24 m — sits tall on its gear (height 10.57 m).
func buildE190(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 2.35  // sits tall on its gear (taller stance than CRJ)

    let airframe = AirframeCache.airframe(kind: .e190, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let accentMat = pbrMaterial(pal.accent, roughness: 0.25, metalness: 0.7)

        // E190 proportions — 36.24 m nose-to-tail, double-bubble tube (max radius
        // ~1.55, wider at shoulder than floor). Smoothly pointed jet radome
        // sweeping up into the 4-pane windscreen; clean pointed upswept tailcone
        // with an APU exhaust at the very tip.
        let fus = latheNode([(-18.10, 0.06), (-17.80, 0.34), (-17.10, 0.72), (-16.05, 1.12),
                             (-14.50, 1.42), (-11.30, 1.55), (7.20, 1.55), (10.90, 1.40),
                             (14.00, 1.06), (16.60, 0.56), (18.10, 0.12)],
                            segments: 34,
                            material: fuselageMaterial(kind: .e190, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Protruding APU exhaust cone at the pointed tailcone tip (E-Jet cue).
        let apuMat = pbrMaterial(UIColor(white: 0.18, alpha: 1), roughness: 0.6, metalness: 0.4)
        let apu = SCNCone(topRadius: 0.06, bottomRadius: 0.17, height: 0.6)
        apu.radialSegmentCount = 16
        apu.materials = [apuMat]
        let apuNode = SCNNode(geometry: apu)
        apuNode.eulerAngles.x = .pi / 2   // taper points aft
        apuNode.position = SCNVector3(0, cy + 0.05, 18.45)
        root.addChildNode(apuNode)

        // Four-pane raked windscreen wrapping the pointed nose.
        let screen = SCNNode(geometry: SCNSphere(radius: 0.86))
        (screen.geometry as? SCNSphere)?.segmentCount = 24
        screen.geometry?.materials = [canopyGlassMaterial()]
        screen.scale = SCNVector3(0.82, 0.52, 1.3)
        screen.position = SCNVector3(0, cy + 0.98, -14.5)
        root.addChildNode(screen)

        // Low swept wing — 28.72 m span incl. winglets. Planform 27.2 m + 0.76 m
        // canted winglet reach per side. sweep 4.6 over 13.6 m half-span.
        let wing = wingNode(span: 27.2, rootChord: 4.7, tipChord: 1.3, sweep: 4.6,
                            thickness: 0.32, material: bodyMat)
        wing.position = SCNVector3(0, 1.45, 3.4)
        root.addChildNode(wing)

        // Canted blade WINGLETS — 1.45 m tall, upward blade (E190 identifier).
        for s in [Float(-1), Float(1)] {
            let wp = UIBezierPath()
            wp.move(to: CGPoint(x: 0, y: 0))
            wp.addLine(to: CGPoint(x: 0.28, y: 1.34))
            wp.addQuadCurve(to: CGPoint(x: 0.66, y: 1.45), controlPoint: CGPoint(x: 0.42, y: 1.50))
            wp.addQuadCurve(to: CGPoint(x: 1.28, y: 0.0), controlPoint: CGPoint(x: 1.10, y: 0.36))
            wp.close()
            let wl = finNode(path: wp, thickness: 0.06, material: bodyMat)
            let cant = SCNNode()
            // Tip chord (sweep 4.6) runs z≈3.0 (LE) → 4.3 (TE); winglet foot near
            // the tip LE, canted more upright than a raked tip.
            cant.position = SCNVector3(13.6 * s, 1.55, 3.2)
            cant.eulerAngles.z = -0.62 * s
            cant.addChildNode(wl)
            root.addChildNode(cant)
        }

        // UNDER-WING nacelles on pylons hung BELOW the wing. Wing at y 1.45;
        // nacelles centered at y 0.60 (slung under), intake ahead of the wing LE.
        // Bigger, fatter nacelles than the CRJ's rear engines.
        let nacMat = pbrMaterial(pal.body, roughness: max(0.12, pal.roughness - 0.06),
                                 metalness: min(1, pal.metalness + 0.15))
        let intakeMat = pbrMaterial(UIColor(white: 0.05, alpha: 1), roughness: 0.4)
        for s in [Float(-1), Float(1)] {
            let nac = latheNode([(-2.25, 0.22), (-2.05, 0.58), (-1.45, 0.74), (-0.25, 0.76),
                                 (1.15, 0.68), (2.05, 0.38), (2.35, 0.16)],
                                segments: 22, material: nacMat)
            nac.position = SCNVector3(5.1 * s, 0.60, -0.35)
            root.addChildNode(nac)
            let intake = SCNNode(geometry: SCNCylinder(radius: 0.56, height: 0.04))
            intake.geometry?.materials = [intakeMat]
            intake.eulerAngles.x = .pi / 2
            intake.position = SCNVector3(5.1 * s, 0.60, -2.55)
            root.addChildNode(intake)
            // Core exhaust plug poking aft of the nacelle tail.
            let plug = SCNCone(topRadius: 0.06, bottomRadius: 0.17, height: 0.46)
            plug.radialSegmentCount = 16
            plug.materials = [intakeMat]
            let plugNode = SCNNode(geometry: plug)
            plugNode.eulerAngles.x = .pi / 2   // taper points aft
            plugNode.position = SCNVector3(5.1 * s, 0.60, 2.20)
            root.addChildNode(plugNode)
            // Pylon: vertical strut linking the nacelle up to the wing underside.
            let pylon = SCNNode(geometry: SCNBox(width: 0.22, height: 0.95, length: 1.7, chamferRadius: 0.05))
            pylon.geometry?.materials = [bodyMat]
            pylon.position = SCNVector3(5.1 * s, 1.10, -0.65)
            root.addChildNode(pylon)
        }

        // CONVENTIONAL low tail: swept fin with a short triangular DORSAL FILLET,
        // and a LOW horizontal stab on the aft fuselage (NOT a T-tail).
        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0.14, y: 0))                      // aft base corner
        finPath.addLine(to: CGPoint(x: 0.90, y: 4.75))               // swept LE up to...
        finPath.addQuadCurve(to: CGPoint(x: 2.40, y: 4.90), controlPoint: CGPoint(x: 1.45, y: 5.00))
        finPath.addQuadCurve(to: CGPoint(x: 3.95, y: 0.60), controlPoint: CGPoint(x: 3.40, y: 2.2))
        // Short dorsal fillet raking forward down the spine.
        finPath.addLine(to: CGPoint(x: 5.05, y: 0.24))
        finPath.addQuadCurve(to: CGPoint(x: 5.95, y: 0.0), controlPoint: CGPoint(x: 5.55, y: 0.04))
        finPath.close()
        let fin = finNode(path: finPath, thickness: 0.26, material: bodyMat)
        fin.position = SCNVector3(0, cy + 1.05, 16.9)
        root.addChildNode(fin)
        // LOW horizontal stab on the aft fuselage — well below the fin tip.
        let stab = wingNode(span: 10.6, rootChord: 2.5, tipChord: 1.1, sweep: 1.4,
                            thickness: 0.22, material: bodyMat)
        stab.position = SCNVector3(0, cy + 1.30, 16.6)
        root.addChildNode(stab)
        if livery == .meridianVIP {
            let crest = SCNNode(geometry: SCNBox(width: 0.34, height: 0.82, length: 0.58, chamferRadius: 0.10))
            crest.geometry?.materials = [accentMat]
            crest.position = SCNVector3(0, cy + 3.8, 15.0)
            root.addChildNode(crest)
        }
        return root
    }

    let body = SCNNode()
    body.addChildNode(airframe)

    // Live turbofans + a warm heat-wash behind each UNDER-WING nacelle. Intake
    // face sits near z −2.55, centerline x ±5.1, y 0.60.
    var fanGroups: [FanGroup] = []
    var heatWashes: [SCNNode] = []
    for s in [Float(-1), Float(1)] {
        let fan = makeFanGroup(at: SCNVector3(5.1 * s, 0.60, -2.57), radius: 0.54)
        body.addChildNode(fan.group)
        fanGroups.append(fan.fan)
        // Warm wash just aft of the exhaust (nacelle tail ~ z 2.0).
        let wash = makeHeatWash(at: SCNVector3(5.1 * s, 0.60, 2.35), size: 2.2)
        body.addChildNode(wash)
        heatWashes.append(wash)
    }

    // Live control surfaces (jet). wingNode origin = ROOT TRAILING EDGE (z 3.4);
    // TE_z(x) = wing.z + |x|/halfSpan·(sweep + tipChord − rootChord)
    //         = 3.4 + |x|/13.6·(4.6 + 1.3 − 4.7) = 3.4 + 0.0882·|x|.
    let surfBodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
    var ailerons: [Surface] = []
    var flaps: [Surface] = []
    for s in [Float(-1), Float(1)] {
        // Aileron centered at |x| 9.5 → TE_z ≈ 3.4 + 0.0882·9.5 ≈ 4.24.
        let a = hingedSurfaceNode(span: 3.6, chord: 0.8, thickness: 0.14, material: surfBodyMat)
        a.position = SCNVector3(s * 9.5, 1.45, 3.4 + 0.0882 * 9.5)
        ailerons.append(Surface(node: a, sign: s))
        body.addChildNode(a)
        // Flap centered at |x| 3.8 → TE_z ≈ 3.4 + 0.0882·3.8 ≈ 3.74.
        let fl = hingedSurfaceNode(span: 4.2, chord: 0.95, thickness: 0.14, material: surfBodyMat)
        fl.position = SCNVector3(s * 3.8, 1.45, 3.4 + 0.0882 * 3.8)
        flaps.append(Surface(node: fl, sign: 1))
        body.addChildNode(fl)
    }
    // Conventional-tail elevator on the LOW stab TE (stab node.z = 16.6 IS the
    // trailing edge, y = cy+1.30).
    var elevator: [Surface] = []
    let elev = hingedSurfaceNode(span: 10.0, chord: 0.9, thickness: 0.14, material: surfBodyMat)
    elev.position = SCNVector3(0, cy + 1.30, 16.6)
    elevator.append(Surface(node: elev, sign: 1))
    body.addChildNode(elev)
    // Rudder at the fin TE (finNode extends forward; TE near node.z 16.9 − 0.14).
    var rudder: [Surface] = []
    let rud = hingedRudderNode(height: 4.2, chord: 0.95, thickness: 0.22, material: surfBodyMat)
    rud.position = SCNVector3(0, cy + 1.05, 16.75)
    rudder.append(Surface(node: rud, sign: 1))
    body.addChildNode(rud)

    // Retractable gear — live wheels + a real oleo on the mains. Tall legs give
    // ground clearance for the under-wing engines (E190 stands high).
    let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
    let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)
    let strutMat = pbrMaterial(UIColor(white: 0.75, alpha: 1), roughness: 0.35, metalness: 0.7)

    var wheels: [(node: SCNNode, radius: Float)] = []
    var oleos: [(node: SCNNode, restY: Float, travel: Float)] = []

    func gearLeg(pivotAt: SCNVector3, strutLen: Float, wheelRadius: CGFloat,
                 wheelWidth: CGFloat, twin: Bool)
        -> (pivot: SCNNode, oleo: SCNNode, wheels: [SCNNode]) {
        let pivot = SCNNode()
        pivot.position = pivotAt
        let oleo = SCNNode()
        let strut = strutNode(from: SCNVector3(0, 0, 0), to: SCNVector3(0, -strutLen, 0),
                              radius: 0.075, material: strutMat)
        oleo.addChildNode(strut.flattenedClone())
        var ws: [SCNNode] = []
        let xs: [Float] = twin ? [-0.17, 0.17] : [0]
        for x in xs {
            let w = wheelNode(radius: wheelRadius, width: wheelWidth, tire: tire, hub: hub)
            w.position = SCNVector3(x, -strutLen, 0)
            oleo.addChildNode(w)
            ws.append(w)
        }
        pivot.addChildNode(oleo)
        return (pivot, oleo, ws)
    }

    // Nose gear folds forward. Taller legs than the CRJ (E190 rides high).
    let nose = gearLeg(pivotAt: SCNVector3(0, 1.52, -13.4), strutLen: 1.14,
                       wheelRadius: 0.38, wheelWidth: 0.14, twin: true)
    body.addChildNode(nose.pivot)
    for w in nose.wheels { wheels.append((w, 0.38)) }

    var gear: [(node: SCNNode, foldedEuler: SCNVector3)] =
        [(nose.pivot, SCNVector3(1.7, 0, 0))]  // folds forward into the nose
    var gearContacts: [SCNVector3] = []
    for s in [Float(-1), Float(1)] {
        // Mains carry a twin bogie on the wing box. Tall legs (pivot y 1.30).
        let main = gearLeg(pivotAt: SCNVector3(2.9 * s, 1.30, 3.8), strutLen: 0.75,
                           wheelRadius: 0.55, wheelWidth: 0.28, twin: true)
        body.addChildNode(main.pivot)
        gear.append((main.pivot, SCNVector3(0, 0, 1.85 * -s)))  // mains fold inboard
        for w in main.wheels { wheels.append((w, 0.55)) }
        oleos.append((main.oleo, 0, 0.12))
        // Contact at ground level (pivot y 1.30 − strut 0.75 − radius 0.55 ≈ 0).
        gearContacts.append(SCNVector3(2.9 * s, 0, 3.8))
    }

    let shadow = makeContactShadow(span: 28.72, length: 36.24)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-13.6, 1.55, 2.8),
        navRight: SCNVector3(13.6, 1.55, 2.8),
        tail: SCNVector3(0, cy + 1.05, 17.9),
        beacon: SCNVector3(0, cy + 1.9, -1.6),
        landing: SCNVector3(0, 1.7, -17.5)))
    return CraftParts(body: body, propGroup: nil, blades: nil, blurDisc: nil,
                      fanGroups: fanGroups, heatWash: heatWashes,
                      beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      navNodes: kit.navs, scalingHalos: kit.halos, contactShadow: shadow,
                      landingLight: kit.light, landingGlow: kit.glow, gear: gear,
                      smokeOffset: SCNVector3(0, 0.6, 3.8),
                      gearContacts: gearContacts, wheels: wheels, oleos: oleos,
                      ailerons: ailerons, elevator: elevator, rudder: rudder, flaps: flaps)
}

// MARK: - Bombardier CRJ900 (regional jet, rear-fuselage engines, T-tail)

/// crj900 — LOW swept wing (clean tips, NO large winglets), two CF34-8C5
/// turbofans on the REAR FUSELAGE sides, a T-TAIL kept clear of the exhaust —
/// the direct visual OPPOSITE of the E190 (engines on the tail, not the wing).
/// The longest/thinnest silhouette of the set: 36.2 m long on a 24.85 m span,
/// low-riding stance (short gear, height only 7.51 m). Structurally a scaled-up
/// Challenger 350 (buildComet) / Phenom 300 pattern.
func buildCRJ900(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 1.72  // low cabin floor / short gear — sits close to the tarmac

    let airframe = AirframeCache.airframe(kind: .crj900, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let accentMat = pbrMaterial(pal.accent, roughness: 0.25, metalness: 0.7)

        // Very long, SLENDER tube (Challenger-derived), 36.2 m nose-to-tail on a
        // thin section (max radius ~1.35 ⇒ pencil-like length/span ~1.46). Pointed
        // business-jet nose; upswept tapered tailcone leading to the rear engines
        // and T-tail.
        let fus = latheNode([(-18.10, 0.05), (-17.80, 0.30), (-17.10, 0.66), (-16.10, 1.00),
                             (-14.60, 1.26), (-11.40, 1.35), (7.60, 1.35), (11.00, 1.22),
                             (14.10, 0.90), (16.60, 0.50), (18.10, 0.13)],
                            segments: 32,
                            material: fuselageMaterial(kind: .crj900, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Pointed business-jet windscreen wrapping the nose (low + forward).
        let screen = SCNNode(geometry: SCNSphere(radius: 0.80))
        (screen.geometry as? SCNSphere)?.segmentCount = 24
        screen.geometry?.materials = [canopyGlassMaterial()]
        screen.scale = SCNVector3(0.78, 0.5, 1.25)
        screen.position = SCNVector3(0, cy + 0.90, -14.6)
        root.addChildNode(screen)

        // Low swept wing — 24.85 m span, mildly swept, short-span (contributing to
        // the pencil silhouette). Root TE at z 2.6. Clean tips: small tip fairing
        // caps, NO large blended winglets (the CRJ vs E190 tell).
        let wing = wingNode(span: 24.85, rootChord: 4.1, tipChord: 1.2, sweep: 3.6,
                            thickness: 0.30, material: bodyMat)
        wing.position = SCNVector3(0, 1.25, 2.6)
        root.addChildNode(wing)
        // Small clean tip fairings (NOT winglets).
        for s in [Float(-1), Float(1)] {
            let cap = SCNNode(geometry: SCNBox(width: 0.5, height: 0.22, length: 1.2, chamferRadius: 0.08))
            cap.geometry?.materials = [bodyMat]
            cap.position = SCNVector3(12.42 * s, 1.30, 1.9)
            root.addChildNode(cap)
        }

        // REAR-FUSELAGE nacelles on short stub pylons (NOT under the wing). Slim
        // nacelles hugging the aft fuselage sides just below + ahead of the T-tail.
        let nacMat = pbrMaterial(pal.body, roughness: max(0.12, pal.roughness - 0.06),
                                 metalness: min(1, pal.metalness + 0.15))
        let intakeMat = pbrMaterial(UIColor(white: 0.05, alpha: 1), roughness: 0.4)
        let nacY: Float = cy + 0.30
        for s in [Float(-1), Float(1)] {
            let nac = latheNode([(-1.85, 0.14), (-1.70, 0.44), (-1.20, 0.56), (-0.20, 0.58),
                                 (0.95, 0.52), (1.70, 0.30), (1.95, 0.12)],
                                segments: 20, material: nacMat)
            nac.position = SCNVector3(1.75 * s, nacY, 9.0)
            root.addChildNode(nac)
            let intake = SCNNode(geometry: SCNCylinder(radius: 0.44, height: 0.04))
            intake.geometry?.materials = [intakeMat]
            intake.eulerAngles.x = .pi / 2
            intake.position = SCNVector3(1.75 * s, nacY, 7.20)
            root.addChildNode(intake)
            // Near-flat stub pylon rooted at the aft-fuselage shoulder.
            let pylon = SCNNode(geometry: SCNBox(width: 0.14, height: 0.55, length: 1.7, chamferRadius: 0.05))
            pylon.geometry?.materials = [bodyMat]
            pylon.eulerAngles.z = 0.24 * s
            pylon.position = SCNVector3(1.35 * s, nacY - 0.14, 8.95)
            root.addChildNode(pylon)
        }

        // T-TAIL — horizontal stab at the top of a tall swept fin, kept clear of
        // the rear-engine exhaust. The T-tail-plus-rear-engines combo is the CRJ
        // signature (vs the E190's under-wing engines + low tail).
        let finTop: Float = 4.90
        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0.10, y: 0))
        finPath.addLine(to: CGPoint(x: 1.90, y: CGFloat(finTop)))
        finPath.addQuadCurve(to: CGPoint(x: 3.20, y: CGFloat(finTop) - 0.05),
                             controlPoint: CGPoint(x: 2.50, y: CGFloat(finTop) + 0.12))
        finPath.addQuadCurve(to: CGPoint(x: 4.15, y: 1.0), controlPoint: CGPoint(x: 4.05, y: 2.5))
        // Dorsal fillet raking forward at the base.
        finPath.addLine(to: CGPoint(x: 5.15, y: 0.28))
        finPath.addQuadCurve(to: CGPoint(x: 6.05, y: 0.0), controlPoint: CGPoint(x: 5.60, y: 0.05))
        finPath.close()
        let fin = finNode(path: finPath, thickness: 0.26, material: bodyMat)
        fin.position = SCNVector3(0, cy + 1.05, 15.4)
        root.addChildNode(fin)

        // Horizontal stab ATOP the fin (T-tail), swept, spanning the fin top.
        // Slight anhedral on the -900 → model flat/level.
        let stab = wingNode(span: 8.4, rootChord: 2.0, tipChord: 1.0, sweep: 0.7,
                            thickness: 0.18, material: bodyMat)
        stab.position = SCNVector3(0, cy + 1.05 + finTop, 14.8)
        root.addChildNode(stab)
        if livery == .meridianVIP {
            let crest = SCNNode(geometry: SCNBox(width: 0.30, height: 0.72, length: 0.50, chamferRadius: 0.10))
            crest.geometry?.materials = [accentMat]
            crest.position = SCNVector3(0, cy + 3.6, 13.6)
            root.addChildNode(crest)
        }
        return root
    }

    let body = SCNNode()
    body.addChildNode(airframe)

    // Live turbofans + a warm heat-wash behind each REAR-FUSELAGE nacelle. Intake
    // face sits near z 7.20, centerline x ±1.75, y cy+0.30.
    let nacY: Float = cy + 0.30
    var fanGroups: [FanGroup] = []
    var heatWashes: [SCNNode] = []
    for s in [Float(-1), Float(1)] {
        let fan = makeFanGroup(at: SCNVector3(1.75 * s, nacY, 7.18), radius: 0.42)
        body.addChildNode(fan.group)
        fanGroups.append(fan.fan)
        // Warm wash just aft of the exhaust (nacelle tail ~ z 10.95).
        let wash = makeHeatWash(at: SCNVector3(1.75 * s, nacY, 11.3), size: 1.8)
        body.addChildNode(wash)
        heatWashes.append(wash)
    }

    // Live control surfaces (jet). wingNode origin = ROOT TRAILING EDGE (z 2.6);
    // TE_z(x) = wing.z + |x|/halfSpan·(sweep + tipChord − rootChord)
    //         = 2.6 + |x|/12.425·(3.6 + 1.2 − 4.1) = 2.6 + 0.0563·|x|.
    let surfBodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
    var ailerons: [Surface] = []
    var flaps: [Surface] = []
    for s in [Float(-1), Float(1)] {
        // Aileron centered at |x| 8.6 → TE_z ≈ 2.6 + 0.0563·8.6 ≈ 3.08.
        let a = hingedSurfaceNode(span: 3.2, chord: 0.72, thickness: 0.14, material: surfBodyMat)
        a.position = SCNVector3(s * 8.6, 1.25, 2.6 + 0.0563 * 8.6)
        ailerons.append(Surface(node: a, sign: s))
        body.addChildNode(a)
        // Flap centered at |x| 3.4 → TE_z ≈ 2.6 + 0.0563·3.4 ≈ 2.79.
        let fl = hingedSurfaceNode(span: 3.8, chord: 0.85, thickness: 0.14, material: surfBodyMat)
        fl.position = SCNVector3(s * 3.4, 1.25, 2.6 + 0.0563 * 3.4)
        flaps.append(Surface(node: fl, sign: 1))
        body.addChildNode(fl)
    }
    // T-tail elevator on the stab TE atop the fin (stab.y = cy+1.05+finTop;
    // stab node.z = 14.8 IS the trailing edge).
    var elevator: [Surface] = []
    let elev = hingedSurfaceNode(span: 8.0, chord: 0.7, thickness: 0.12, material: surfBodyMat)
    elev.position = SCNVector3(0, cy + 1.05 + 4.90, 14.8)
    elevator.append(Surface(node: elev, sign: 1))
    body.addChildNode(elev)
    // Rudder at the fin TE (finNode extends forward; TE near node.z 15.4 − 0.10).
    var rudder: [Surface] = []
    let rud = hingedRudderNode(height: 4.3, chord: 0.9, thickness: 0.22, material: surfBodyMat)
    rud.position = SCNVector3(0, cy + 1.05, 15.3)
    rudder.append(Surface(node: rud, sign: 1))
    body.addChildNode(rud)

    // Retractable gear — live wheels + a real oleo on the mains. SHORT legs (the
    // CRJ sits notably LOW).
    let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
    let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)
    let strutMat = pbrMaterial(UIColor(white: 0.75, alpha: 1), roughness: 0.35, metalness: 0.7)

    var wheels: [(node: SCNNode, radius: Float)] = []
    var oleos: [(node: SCNNode, restY: Float, travel: Float)] = []

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
        let xs: [Float] = twin ? [-0.16, 0.16] : [0]
        for x in xs {
            let w = wheelNode(radius: wheelRadius, width: wheelWidth, tire: tire, hub: hub)
            w.position = SCNVector3(x, -strutLen, 0)
            oleo.addChildNode(w)
            ws.append(w)
        }
        pivot.addChildNode(oleo)
        return (pivot, oleo, ws)
    }

    // Nose gear folds forward. SHORT legs (low-riding stance).
    let nose = gearLeg(pivotAt: SCNVector3(0, 0.98, -13.5), strutLen: 0.62,
                       wheelRadius: 0.34, wheelWidth: 0.13, twin: true)
    body.addChildNode(nose.pivot)
    for w in nose.wheels { wheels.append((w, 0.34)) }

    var gear: [(node: SCNNode, foldedEuler: SCNVector3)] =
        [(nose.pivot, SCNVector3(1.7, 0, 0))]  // folds forward into the nose
    var gearContacts: [SCNVector3] = []
    for s in [Float(-1), Float(1)] {
        // Mains twin bogie on the wing box, SHORT legs (pivot y 0.86).
        let main = gearLeg(pivotAt: SCNVector3(2.5 * s, 0.86, 3.0), strutLen: 0.36,
                           wheelRadius: 0.48, wheelWidth: 0.26, twin: true)
        body.addChildNode(main.pivot)
        gear.append((main.pivot, SCNVector3(0, 0, 1.85 * -s)))  // mains fold inboard
        for w in main.wheels { wheels.append((w, 0.48)) }
        oleos.append((main.oleo, 0, 0.10))
        // Contact at ground level (pivot y 0.86 − strut 0.36 − radius 0.48 ≈ 0).
        gearContacts.append(SCNVector3(2.5 * s, 0, 3.0))
    }

    let shadow = makeContactShadow(span: 24.85, length: 36.2)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-12.42, 1.30, 2.0),
        navRight: SCNVector3(12.42, 1.30, 2.0),
        tail: SCNVector3(0, cy + 1.05 + 4.90, 16.6),   // atop the T-tail
        beacon: SCNVector3(0, cy + 1.9, -1.4),
        landing: SCNVector3(0, 1.4, -17.4)))
    return CraftParts(body: body, propGroup: nil, blades: nil, blurDisc: nil,
                      fanGroups: fanGroups, heatWash: heatWashes,
                      beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      navNodes: kit.navs, scalingHalos: kit.halos, contactShadow: shadow,
                      landingLight: kit.light, landingGlow: kit.glow, gear: gear,
                      smokeOffset: SCNVector3(0, 0.5, 9.0),
                      gearContacts: gearContacts, wheels: wheels, oleos: oleos,
                      ailerons: ailerons, elevator: elevator, rudder: rudder, flaps: flaps)
}
