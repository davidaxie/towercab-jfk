import Foundation
import SceneKit
import UIKit

// =============================================================================
// Turboprop + heritage airframes — four fully-rigged builds:
//   buildCaravan     → caravan     (Cessna 208, high-wing utility single TP)
//   buildKingAir350  → kingair350  (Beech King Air 350, low-wing cabin TWIN TP)
//   buildTwinOtter   → twinotter   (DHC-6, high-wing STOL TWIN TP)
//   buildDC3         → dc3         (Douglas DC-3, low-wing radial-piston TWIN,
//                                   taildragger, retractable mains + tailwheel)
//
// These mirror the three template builders in AircraftModels.swift:
//   buildLark   — high-wing fixed-gear GA (Caravan, Twin Otter follow this).
//   buildVela + buildPropLive — low-wing GA with full live surfaces (King Air,
//                 DC-3 follow this for wing/tail/gear surfaces).
//   buildComet  — retractable live gear via the `gear` fold list + liveGearLeg
//                 (King Air + DC-3 mains + DC-3 tailwheel borrow this pattern).
//
// Model space matches the templates: node origin = ground contact, nose = −Z,
// tail = +Z. Static shell geometry lives in AirframeCache; live parts (props,
// surfaces, wheels, lights, shadow) stay OUT of the cache.
//
// MULTI-ENGINE PROPS: a prop twin needs each wing disc to spin IN PLACE about
// its own hub. SceneKit rigid transforms mean a single spun parent orbits any
// x-offset child, so we cannot literally spin two wing discs from one rotating
// node. Instead we:
//   • give each nacelle spinner its own in-place SCNAction rotation (blades),
//   • keep `propGroup` as a lightweight spin node (harmless — no offset visual
//     children — but non-nil so CraftEntity.update still drives the opacity
//     fades below),
//   • route the blade-fade through `blades` (a parent of both nacelle spinners)
//     and the blur-disc fade through `blurDisc` (a parent of both discs; the
//     disc sprite is radially symmetric so it needs no spin).
// This keeps every CraftParts field the rig animates populated exactly as the
// single-prop templates expect, while the twins read correct at any angle.
// =============================================================================

// MARK: - Turboprop prop assemblies

/// One nacelle's spinning solid prop (spinner cone + blades), built about its
/// OWN local origin so it spins in place. Returned separately from the disc.
private func turbopropSpinner(bladeCount: Int, bladeLength: CGFloat,
                              spinnerScale: Float) -> SCNNode {
    let solid = SCNNode()
    let spinnerMat = pbrMaterial(UIColor(white: 0.16, alpha: 1), roughness: 0.35, metalness: 0.5)
    // Longer, pointier turboprop spinner than the GA piston cone.
    let spinner = latheNode([(-0.52, 0.02), (-0.40, 0.075), (-0.22, 0.13), (0.0, 0.17)],
                            segments: 16, material: spinnerMat)
    spinner.scale = SCNVector3(spinnerScale, spinnerScale, spinnerScale)
    solid.addChildNode(spinner)
    let bladeMat = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.5)
    for i in 0..<bladeCount {
        let blade = SCNNode(geometry: SCNBox(width: 0.10, height: bladeLength,
                                             length: 0.05, chamferRadius: 0.02))
        blade.geometry?.materials = [bladeMat]
        blade.position = SCNVector3(0, 0, -0.07)
        blade.pivot = SCNMatrix4MakeTranslation(0, -Float(bladeLength) / 2 - 0.10, 0)
        blade.eulerAngles.z = Float(i) * 2 * .pi / Float(bladeCount)
        solid.addChildNode(blade)
    }
    return solid
}

/// One nacelle's forward blur disc — a radially symmetric additive-free plane,
/// identical read to makePropGroup's disc. Needs no spin (symmetric).
private func propDiscNode(discDiameter: CGFloat) -> SCNNode {
    let plane = SCNPlane(width: discDiameter, height: discDiameter)
    let dm = SCNMaterial()
    dm.lightingModel = .constant
    dm.diffuse.contents = ArtTextures.propBlur()
    dm.isDoubleSided = true
    dm.writesToDepthBuffer = false
    plane.materials = [dm]
    let disc = SCNNode(geometry: plane)
    disc.opacity = 0
    disc.castsShadow = false
    disc.renderingOrder = 15
    return disc
}

/// Assemble a prop TWIN's live prop nodes. `hubs` are per-nacelle hub positions.
/// Returns:
///   • spinNode  — the lightweight node CraftEntity spins (kept non-nil so the
///                 update prop-branch runs; has no offset children so its own
///                 spin is a visual no-op).
///   • blades    — parent of both nacelle spinners; opacity fades the solids.
///   • blurDisc  — parent of both discs; opacity fades the blur discs in.
///   • installOn — adds the spinners + discs onto the body at their hubs and
///                 starts each spinner's in-place rotation.
private func twinPropLive(hubs: [SCNVector3], bladeCount: Int, bladeLength: CGFloat,
                          spinnerScale: Float, discDiameter: CGFloat)
    -> (spinNode: SCNNode, blades: SCNNode, blurDisc: SCNNode, install: (SCNNode) -> Void) {
    let spinNode = SCNNode()                 // harmless spin sink for update()
    let bladesContainer = SCNNode()          // opacity handle for all solids
    let discContainer = SCNNode()            // opacity handle for all discs
    var spinners: [SCNNode] = []
    var discs: [SCNNode] = []
    for hub in hubs {
        let sp = turbopropSpinner(bladeCount: bladeCount, bladeLength: bladeLength,
                                  spinnerScale: spinnerScale)
        sp.position = hub
        bladesContainer.addChildNode(sp)
        spinners.append(sp)

        let disc = propDiscNode(discDiameter: discDiameter)
        disc.position = SCNVector3(hub.x, hub.y, hub.z - 0.14)
        discContainer.addChildNode(disc)
        discs.append(disc)
    }
    let install: (SCNNode) -> Void = { body in
        body.addChildNode(spinNode)
        body.addChildNode(bladesContainer)
        body.addChildNode(discContainer)
        // Each spinner rotates in place about its own hub (own local Z).
        for sp in spinners {
            let spin = SCNAction.repeatForever(
                .rotateBy(x: 0, y: 0, z: -.pi * 2, duration: 0.09))
            sp.runAction(spin)
        }
    }
    return (spinNode, bladesContainer, discContainer, install)
}

// MARK: - caravan (Cessna 208 — high-wing utility single turboprop)

/// caravan — long-nosed high-wing utility turboprop; fixed tricycle gear with
/// wheel fairings, single wing strut per side, big 3-blade prop, belly cargo
/// pod. Mirrors buildLark, scaled up (15.9 m span, 12.7 m length) with a long
/// turboprop nose.
func buildCaravan(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 1.55  // fuselage centerline height (tall utility stance)

    let airframe = AirframeCache.airframe(kind: .caravan, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
        let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
        let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)

        // Long turboprop nose (−6.35 m) + boxy, tall utility fuselage, tapering
        // to the tail at +6.35 m (12.7 m total).
        let fus = latheNode([(-6.35, 0.14), (-6.15, 0.44), (-5.35, 0.68), (-4.20, 0.86),
                             (-2.90, 0.96), (-1.30, 0.99), (0.60, 0.96), (2.40, 0.82),
                             (4.10, 0.56), (5.60, 0.28), (6.35, 0.05)],
                            segments: 30,
                            material: fuselageMaterial(kind: .caravan, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Asymmetric cowl detail: a LARGER intake scoop left of the spinner, a
        // SMALLER one on the right, plus a right-side exhaust stack — the
        // Caravan's signature unequal-intake nose. (blueprint distinctiveFeature)
        let intakeMat = pbrMaterial(UIColor(white: 0.05, alpha: 1), roughness: 0.4)
        let bigScoop = SCNNode(geometry: SCNBox(width: 0.26, height: 0.20, length: 0.5, chamferRadius: 0.06))
        bigScoop.geometry?.materials = [intakeMat]
        bigScoop.position = SCNVector3(-0.30, cy + 0.02, -6.05)   // left = larger
        root.addChildNode(bigScoop)
        let smallScoop = SCNNode(geometry: SCNBox(width: 0.18, height: 0.15, length: 0.42, chamferRadius: 0.05))
        smallScoop.geometry?.materials = [intakeMat]
        smallScoop.position = SCNVector3(0.28, cy + 0.02, -6.0)   // right = smaller
        root.addChildNode(smallScoop)
        let exhaust = SCNNode(geometry: SCNCylinder(radius: 0.07, height: 0.5))
        exhaust.geometry?.materials = [pbrMaterial(UIColor(white: 0.10, alpha: 1), roughness: 0.5, metalness: 0.6)]
        exhaust.eulerAngles.x = .pi / 2
        exhaust.position = SCNVector3(0.42, cy - 0.18, -5.5)   // right-side stack
        root.addChildNode(exhaust)

        // Belly cargo pod — the Caravan's signature underslung fairing, running
        // most of the fuselage length, streamlined and low-slung.
        let pod = latheNode([(-4.6, 0.04), (-4.2, 0.26), (-2.8, 0.40), (-1.0, 0.44),
                             (0.8, 0.44), (2.6, 0.36), (3.8, 0.20), (4.5, 0.06)],
                            segments: 18, material: bodyMat)
        pod.position = SCNVector3(0, 0.62, -0.9)
        pod.scale = SCNVector3(1.0, 0.55, 1.0)   // squashed vertically to hug belly
        root.addChildNode(pod)

        // Tall glasshouse cabin (utility greenhouse).
        let cabin = SCNNode(geometry: SCNBox(width: 1.32, height: 0.66, length: 2.5, chamferRadius: 0.16))
        cabin.geometry?.materials = [canopyGlassMaterial()]
        cabin.position = SCNVector3(0, cy + 0.74, -2.0)
        root.addChildNode(cabin)
        let rearWindow = SCNNode(geometry: SCNBox(width: 1.24, height: 0.34, length: 0.7, chamferRadius: 0.1))
        rearWindow.geometry?.materials = [canopyGlassMaterial()]
        rearWindow.position = SCNVector3(0, cy + 0.72, -0.5)
        root.addChildNode(rearWindow)

        // High wing (15.9 m span). TE sits at z −0.35; strut braced.
        let wing = wingNode(span: 15.9, rootChord: 1.75, tipChord: 1.2, sweep: 0,
                            thickness: 0.17, material: bodyMat)
        let wingY: Float = cy + 1.02
        wing.position = SCNVector3(0, wingY, -0.35)
        root.addChildNode(wing)
        if let tip = pal.wingtip {
            let tm = pbrMaterial(tip, roughness: pal.roughness)
            for x in [Float(-7.83), Float(7.83)] {
                let cap = SCNNode(geometry: SCNBox(width: 0.26, height: 0.185, length: 1.22, chamferRadius: 0.05))
                cap.geometry?.materials = [tm]
                cap.position = SCNVector3(x, wingY, -1.5)
                root.addChildNode(cap)
            }
        }
        // Single lift strut per side to ~40% semi-span.
        for s in [Float(-1), Float(1)] {
            root.addChildNode(strutNode(from: SCNVector3(0.78 * s, cy + 0.30, -1.05),
                                        to: SCNVector3(3.2 * s, wingY - 0.06, -1.15),
                                        radius: 0.045, material: bodyMat))
        }

        // Upright swept fin with dorsal fillet.
        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0.06, y: 0))
        finPath.addLine(to: CGPoint(x: 0.22, y: 1.92))
        finPath.addQuadCurve(to: CGPoint(x: 0.86, y: 2.04), controlPoint: CGPoint(x: 0.42, y: 2.10))
        finPath.addQuadCurve(to: CGPoint(x: 1.35, y: 0.80), controlPoint: CGPoint(x: 1.24, y: 1.5))
        finPath.addQuadCurve(to: CGPoint(x: 3.6, y: 0.0), controlPoint: CGPoint(x: 2.0, y: 0.06))
        finPath.close()
        let fin = finNode(path: finPath, thickness: 0.14, material: tailMat)
        fin.position = SCNVector3(0, cy + 0.02, 6.25)
        root.addChildNode(fin)

        let stab = wingNode(span: 4.6, rootChord: 1.2, tipChord: 0.75, sweep: 0.2,
                            thickness: 0.10, material: bodyMat)
        stab.position = SCNVector3(0, cy + 0.06, 6.2)
        root.addChildNode(stab)

        // Fixed tricycle gear with wheel fairings; struts + fairings static, main
        // WHEELS live. Tall stance (contact at y ≈ 0).
        let fairing: [(z: Float, r: Float)] = [(-0.42, 0.03), (-0.18, 0.20), (0.06, 0.24),
                                               (0.34, 0.14), (0.56, 0.02)]
        for s in [Float(-1), Float(1)] {
            root.addChildNode(strutNode(from: SCNVector3(0.42 * s, cy + 0.20, -0.30),
                                        to: SCNVector3(1.42 * s, 0.42, -0.35),
                                        radius: 0.05, material: bodyMat))
            let f = latheNode(fairing, segments: 16, material: bodyMat)
            f.position = SCNVector3(1.45 * s, 0.40, -0.35)
            root.addChildNode(f)
        }
        root.addChildNode(strutNode(from: SCNVector3(0, cy + 0.10, -4.7),
                                    to: SCNVector3(0, 0.36, -4.8),
                                    radius: 0.045, material: bodyMat))
        let nw = wheelNode(radius: 0.26, width: 0.16, tire: tire, hub: hub)
        nw.position = SCNVector3(0, 0.26, -4.82)
        root.addChildNode(nw)
        let nf = latheNode(fairing, segments: 16, material: bodyMat)
        nf.scale = SCNVector3(0.9, 0.9, 0.9)
        nf.position = SCNVector3(0, 0.37, -4.82)
        root.addChildNode(nf)
        return root
    }

    let body = SCNNode()
    body.addChildNode(airframe)

    // Big 3-blade turboprop, Ø ~2.69 m, on the long nose.
    let prop = makePropGroup(at: SCNVector3(0, cy, -6.4), bladeCount: 3, bladeLength: 1.20,
                             spinnerScale: 1.25, discDiameter: 2.69)
    body.addChildNode(prop.group)

    // Live surfaces + main wheels (high wing: TE at wing.z + rootChord).
    let wingY: Float = cy + 1.02
    let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
    let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
    let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
    let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)
    let strutMat = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.5)
    let live = buildPropLive(spec: PropLiveSpec(
        wingY: wingY, wingTE_Z: -0.35, wingHalfSpan: 7.95,
        ailChord: 0.42, ailSpan: 2.7, ailInboard: 4.6,
        flapChord: 0.42, flapSpan: 3.1, flapInboard: 0.9,
        surfThickness: 0.10,
        stabY: cy + 0.06, stabTE_Z: 6.2, stabHalfSpan: 2.3, elevChord: 0.42,
        finBaseY: cy + 0.02, finTE_Z: 6.15, rudderHeight: 1.85, rudderChord: 0.42,
        mainX: 1.45, mainZ: -0.35, mainTopY: 0.66,
        mainRadius: 0.30, mainWidth: 0.18, mainStrutR: 0.0),
        bodyMat: bodyMat, tailMat: tailMat, tire: tire, hub: hub, strutMat: strutMat)
    live.install(on: body)

    let shadow = makeContactShadow(span: 15.9, length: 12.7)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-7.95, wingY, -1.5),
        navRight: SCNVector3(7.95, wingY, -1.5),
        tail: SCNVector3(0, cy + 0.02, 6.35),
        beacon: SCNVector3(0, cy + 2.10, 5.9),
        landing: SCNVector3(0, wingY - 0.05, -1.9)))
    return CraftParts(body: body, propGroup: prop.group, blades: prop.blades,
                      blurDisc: prop.disc, fanGroups: [], heatWash: [],
                      beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      navNodes: kit.navs, scalingHalos: kit.halos, contactShadow: shadow,
                      landingLight: kit.light, landingGlow: kit.glow, gear: [],
                      smokeOffset: SCNVector3(0, 0.30, -0.35),
                      gearContacts: live.gearContacts, wheels: live.wheels, oleos: live.oleos,
                      ailerons: live.ailerons, elevator: live.elevator,
                      rudder: live.rudder, flaps: live.flaps)
}

// MARK: - kingair350 (Beech King Air 350 — low-wing cabin TWIN turboprop)

/// kingair350 — low-wing cabin-class turboprop twin; retractable tricycle gear,
/// two wing nacelles with 4-blade props, winglets. Mirrors buildVela +
/// buildPropLive for the surfaces, adds two turboprop nacelles + a Comet-style
/// retractable `gear` list. 17.7 m span, 14.2 m length.
func buildKingAir350(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 1.55

    // Nacelle centreline: on the wing, ±2.85 m out, at wing height, ahead of LE.
    let wingY: Float = 0.98
    let nacX: Float = 2.85
    let nacY: Float = wingY + 0.10
    let propZ: Float = -2.55   // prop plane well ahead of the wing LE

    let airframe = AirframeCache.airframe(kind: .kingair350, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)

        // Sleek pressurized fuselage, 14.2 m nose-to-tail.
        let fus = latheNode([(-7.10, 0.12), (-6.85, 0.44), (-6.00, 0.66), (-4.70, 0.80),
                             (-3.00, 0.86), (-0.80, 0.86), (1.60, 0.80), (3.80, 0.62),
                             (5.70, 0.34), (7.10, 0.06)],
                            segments: 30,
                            material: fuselageMaterial(kind: .kingair350, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Raked windscreen cap.
        let screen = SCNNode(geometry: SCNSphere(radius: 0.62))
        (screen.geometry as? SCNSphere)?.segmentCount = 24
        screen.geometry?.materials = [canopyGlassMaterial()]
        screen.scale = SCNVector3(0.74, 0.5, 1.2)
        screen.position = SCNVector3(0, cy + 0.66, -5.35)
        root.addChildNode(screen)

        // Low wing (17.7 m span). Root TE at z 0.3; slight sweep.
        let wing = wingNode(span: 17.7, rootChord: 2.2, tipChord: 1.05, sweep: 0.55,
                            thickness: 0.20, material: bodyMat)
        wing.position = SCNVector3(0, wingY, 0.30)
        root.addChildNode(wing)

        // Nacelle shells (static) + intakes + exhaust stubs, one per side. The
        // spinning prop core stays LIVE and is added outside the cache.
        let nacMat = pbrMaterial(pal.body, roughness: max(0.15, pal.roughness - 0.05),
                                 metalness: min(1, pal.metalness + 0.1))
        let intakeMat = pbrMaterial(UIColor(white: 0.05, alpha: 1), roughness: 0.4)
        for s in [Float(-1), Float(1)] {
            let nac = latheNode([(-2.55, 0.16), (-2.35, 0.34), (-1.70, 0.44), (-0.40, 0.46),
                                 (0.90, 0.42), (2.10, 0.26), (2.90, 0.10)],
                                segments: 20, material: nacMat)
            nac.position = SCNVector3(nacX * s, nacY, -0.55)
            root.addChildNode(nac)
            // Racetrack "pitot-type" intake — wider than tall, low near the
            // spinner (the modern 350 cowl intake). (blueprint distinctiveFeature)
            let scoop = SCNNode(geometry: SCNBox(width: 0.42, height: 0.16, length: 0.34, chamferRadius: 0.08))
            scoop.geometry?.materials = [intakeMat]
            scoop.position = SCNVector3(nacX * s, nacY - 0.30, -2.28)
            root.addChildNode(scoop)
        }

        // Winglets — canted up at the tips.
        for s in [Float(-1), Float(1)] {
            let wp = UIBezierPath()
            wp.move(to: CGPoint(x: 0, y: 0))
            wp.addLine(to: CGPoint(x: 0.18, y: 0.82))
            wp.addQuadCurve(to: CGPoint(x: 0.46, y: 0.90), controlPoint: CGPoint(x: 0.28, y: 0.94))
            wp.addQuadCurve(to: CGPoint(x: 0.95, y: 0.0), controlPoint: CGPoint(x: 0.82, y: 0.28))
            wp.close()
            let wl = finNode(path: wp, thickness: 0.05, material: tailMat)
            let cant = SCNNode()
            cant.position = SCNVector3(8.85 * s, wingY, -0.8)
            cant.eulerAngles.z = -0.42 * s
            cant.addChildNode(wl)
            root.addChildNode(cant)
        }

        // T-TAIL — the King Air 350 signature. A tall swept vertical fin carries
        // the horizontal stabilizer at its TOP (~2.3 m up), with a small aft
        // VENTRAL FIN under the tailcone. (blueprint: T-tail + ventral fin.)
        let finTop: Float = 2.35
        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0.08, y: 0))
        finPath.addLine(to: CGPoint(x: 1.05, y: CGFloat(finTop)))
        finPath.addQuadCurve(to: CGPoint(x: 1.95, y: CGFloat(finTop) - 0.06),
                             controlPoint: CGPoint(x: 1.55, y: CGFloat(finTop) + 0.10))
        finPath.addQuadCurve(to: CGPoint(x: 2.85, y: 0.0), controlPoint: CGPoint(x: 2.2, y: 0.5))
        finPath.close()
        let fin = finNode(path: finPath, thickness: 0.16, material: tailMat)
        fin.position = SCNVector3(0, cy + 0.10, 6.75)
        root.addChildNode(fin)

        // Horizontal stab ATOP the fin (T-tail), swept, spanning the fin top.
        let stab = wingNode(span: 5.6, rootChord: 1.3, tipChord: 0.72, sweep: 0.6,
                            thickness: 0.12, material: bodyMat)
        stab.position = SCNVector3(0, cy + 0.10 + finTop, 6.15)
        root.addChildNode(stab)

        // Small aft ventral fin under the tailcone (T-tail King Air trait).
        let ventPath = UIBezierPath()
        ventPath.move(to: CGPoint(x: 0.10, y: 0))
        ventPath.addLine(to: CGPoint(x: 0.30, y: -0.55))
        ventPath.addLine(to: CGPoint(x: 1.30, y: -0.62))
        ventPath.addLine(to: CGPoint(x: 1.60, y: 0.0))
        ventPath.close()
        let vent = finNode(path: ventPath, thickness: 0.12, material: tailMat)
        vent.position = SCNVector3(0, cy - 0.30, 6.65)
        root.addChildNode(vent)
        if livery == .meridianVIP {
            let accentMat = pbrMaterial(pal.accent, roughness: 0.25, metalness: 0.7)
            let crest = SCNNode(geometry: SCNBox(width: 0.22, height: 0.5, length: 0.36, chamferRadius: 0.06))
            crest.geometry?.materials = [accentMat]
            crest.position = SCNVector3(0, cy + 1.9, 6.05)
            root.addChildNode(crest)
        }
        return root
    }

    let body = SCNNode()
    body.addChildNode(airframe)

    // Two 4-blade turboprops, Ø ~2.79 m, one per nacelle. Spinners spin in place
    // via SCNAction; propGroup stays non-nil so the update fade-branch runs.
    let twin = twinPropLive(hubs: [SCNVector3(-nacX, nacY, propZ),
                                   SCNVector3( nacX, nacY, propZ)],
                            bladeCount: 4, bladeLength: 1.25, spinnerScale: 1.1,
                            discDiameter: 2.79)
    twin.install(body)

    // Live control surfaces + retractable mains.
    let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
    let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
    let surfBodyMat = bodyMat

    // Wing TE (low wing): wing.z + rootChord = 0.30 + 2.2 = 2.5.
    var ailerons: [Surface] = []
    var flaps: [Surface] = []
    for s in [Float(-1), Float(1)] {
        let a = hingedSurfaceNode(span: 2.6, chord: 0.5, thickness: 0.12, material: surfBodyMat)
        a.position = SCNVector3(s * 6.4, wingY, 2.5)
        ailerons.append(Surface(node: a, sign: s))
        body.addChildNode(a)
        // Inboard flap between fuselage and nacelle.
        let fl = hingedSurfaceNode(span: 2.2, chord: 0.55, thickness: 0.12, material: surfBodyMat)
        fl.position = SCNVector3(s * 1.9, wingY, 2.5)
        flaps.append(Surface(node: fl, sign: 1))
        body.addChildNode(fl)
    }
    // Elevator on the T-tail stab TE (atop the fin: stab.y = cy+0.10+2.35,
    // stab.z + rootChord = 6.15 + 1.3 = 7.45).
    var elevator: [Surface] = []
    let elev = hingedSurfaceNode(span: 5.4, chord: 0.5, thickness: 0.10, material: surfBodyMat)
    elev.position = SCNVector3(0, cy + 0.10 + 2.35, 7.45)
    elevator.append(Surface(node: elev, sign: 1))
    body.addChildNode(elev)
    // Rudder at the fin TE (finNode extends forward; TE near node.z 6.75).
    var rudder: [Surface] = []
    let rud = hingedRudderNode(height: 2.25, chord: 0.5, thickness: 0.14, material: tailMat)
    rud.position = SCNVector3(0, cy + 0.10, 6.75)
    rudder.append(Surface(node: rud, sign: 1))
    body.addChildNode(rud)

    // Retractable gear — live wheels + real oleo (Comet pattern). Nose folds
    // forward; mains fold inboard into the nacelles.
    let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
    let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)
    let strutMat = pbrMaterial(UIColor(white: 0.75, alpha: 1), roughness: 0.35, metalness: 0.7)

    var wheels: [(node: SCNNode, radius: Float)] = []
    var oleos: [(node: SCNNode, restY: Float, travel: Float)] = []
    var gear: [(node: SCNNode, foldedEuler: SCNVector3)] = []
    var gearContacts: [SCNVector3] = []

    func kingGearLeg(pivotAt: SCNVector3, strutLen: Float, wheelRadius: CGFloat,
                     wheelWidth: CGFloat, twin: Bool) -> (pivot: SCNNode, oleo: SCNNode, wheels: [SCNNode]) {
        let pivot = SCNNode()
        pivot.position = pivotAt
        let oleo = SCNNode()
        let strut = strutNode(from: SCNVector3(0, 0, 0), to: SCNVector3(0, -strutLen, 0),
                              radius: 0.045, material: strutMat)
        oleo.addChildNode(strut.flattenedClone())
        var ws: [SCNNode] = []
        let xs: [Float] = twin ? [-0.11, 0.11] : [0]
        for x in xs {
            let w = wheelNode(radius: wheelRadius, width: wheelWidth, tire: tire, hub: hub)
            w.position = SCNVector3(x, -strutLen, 0)
            oleo.addChildNode(w)
            ws.append(w)
        }
        pivot.addChildNode(oleo)
        return (pivot, oleo, ws)
    }

    // Nose gear under the nose, folds forward.
    let nose = kingGearLeg(pivotAt: SCNVector3(0, 1.02, -5.1), strutLen: 0.72,
                           wheelRadius: 0.26, wheelWidth: 0.10, twin: true)
    body.addChildNode(nose.pivot)
    for w in nose.wheels { wheels.append((w, 0.26)) }
    gear.append((nose.pivot, SCNVector3(1.7, 0, 0)))
    // Mains under the nacelles, fold inboard. Pivot y = nacY-0.30; strut sized
    // so contact (pivot - strut - radius) lands at y ≈ 0.
    let mainPivotY: Float = nacY - 0.30
    let mainStrutLen: Float = mainPivotY - 0.34   // wheel radius ⇒ contact ≈ 0
    for s in [Float(-1), Float(1)] {
        let main = kingGearLeg(pivotAt: SCNVector3(nacX * s, mainPivotY, -0.9), strutLen: mainStrutLen,
                               wheelRadius: 0.34, wheelWidth: 0.16, twin: false)
        body.addChildNode(main.pivot)
        gear.append((main.pivot, SCNVector3(0, 0, 1.75 * -s)))
        for w in main.wheels { wheels.append((w, 0.34)) }
        oleos.append((main.oleo, 0, 0.10))
        gearContacts.append(SCNVector3(nacX * s, 0, -0.9))
    }

    let shadow = makeContactShadow(span: 17.7, length: 14.2)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-8.85, wingY, -0.8),
        navRight: SCNVector3(8.85, wingY, -0.8),
        tail: SCNVector3(0, cy + 0.10 + 2.35, 7.35),   // atop the T-tail
        beacon: SCNVector3(0, cy + 2.55, 6.2),
        landing: SCNVector3(0, wingY - 0.1, -1.0)))
    return CraftParts(body: body, propGroup: twin.spinNode, blades: twin.blades,
                      blurDisc: twin.blurDisc, fanGroups: [], heatWash: [],
                      beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      navNodes: kit.navs, scalingHalos: kit.halos, contactShadow: shadow,
                      landingLight: kit.light, landingGlow: kit.glow, gear: gear,
                      smokeOffset: SCNVector3(0, 0.35, -0.9),
                      gearContacts: gearContacts, wheels: wheels, oleos: oleos,
                      ailerons: ailerons, elevator: elevator, rudder: rudder, flaps: flaps)
}

// MARK: - twinotter (DHC-6 — high-wing STOL TWIN turboprop)

/// twinotter — high-wing STOL turboprop twin; fixed tricycle gear, two wing
/// nacelles with 3-blade props, boxy fuselage, single fin, wing struts.
/// Mirrors buildLark scaled up + two nacelles. 19.8 m span, 15.8 m length.
func buildTwinOtter(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 1.62

    let wingY: Float = cy + 1.05
    let nacX: Float = 2.65
    let nacY: Float = wingY - 0.14   // nacelles slung just under the high wing
    let propZ: Float = -1.7

    let airframe = AirframeCache.airframe(kind: .twinotter, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
        let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
        let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)

        // Long boxy STOL fuselage, 15.8 m nose-to-tail.
        let fus = latheNode([(-7.90, 0.12), (-7.70, 0.42), (-7.00, 0.66), (-5.90, 0.84),
                             (-4.40, 0.94), (-2.40, 0.98), (0.40, 0.98), (2.80, 0.92),
                             (5.00, 0.66), (6.90, 0.34), (7.90, 0.07)],
                            segments: 28,
                            material: fuselageMaterial(kind: .twinotter, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Boxy flight-deck greenhouse.
        let cabin = SCNNode(geometry: SCNBox(width: 1.38, height: 0.6, length: 1.9, chamferRadius: 0.14))
        cabin.geometry?.materials = [canopyGlassMaterial()]
        cabin.position = SCNVector3(0, cy + 0.72, -6.0)
        root.addChildNode(cabin)
        // Passenger window band hint.
        let windowBand = SCNNode(geometry: SCNBox(width: 1.42, height: 0.3, length: 5.2, chamferRadius: 0.08))
        windowBand.geometry?.materials = [canopyGlassMaterial()]
        windowBand.position = SCNVector3(0, cy + 0.46, -2.2)
        root.addChildNode(windowBand)

        // High wing (19.8 m span). Root TE at z −0.2.
        let wing = wingNode(span: 19.8, rootChord: 1.98, tipChord: 1.75, sweep: 0,
                            thickness: 0.19, material: bodyMat)
        wing.position = SCNVector3(0, wingY, -0.2)
        root.addChildNode(wing)
        if let tip = pal.wingtip {
            let tm = pbrMaterial(tip, roughness: pal.roughness)
            for x in [Float(-9.75), Float(9.75)] {
                let cap = SCNNode(geometry: SCNBox(width: 0.28, height: 0.20, length: 1.78, chamferRadius: 0.05))
                cap.geometry?.materials = [tm]
                cap.position = SCNVector3(x, wingY, -1.1)
                root.addChildNode(cap)
            }
        }

        // Nacelle shells (static) integrated into the wing LEADING EDGE,
        // projecting forward, one per side — NOT slung under. Each has an
        // OVERSIZED lower air intake nearly as big as the spinner (the Twin
        // Otter's key recognition cue) and a single bracing strut behind it.
        let nacMat = pbrMaterial(pal.body, roughness: max(0.15, pal.roughness - 0.05),
                                 metalness: min(1, pal.metalness + 0.1))
        let intakeMat = pbrMaterial(UIColor(white: 0.05, alpha: 1), roughness: 0.4)
        for s in [Float(-1), Float(1)] {
            let nac = latheNode([(-1.70, 0.17), (-1.50, 0.32), (-0.90, 0.40), (0.20, 0.42),
                                 (1.30, 0.38), (2.40, 0.24), (3.10, 0.10)],
                                segments: 18, material: nacMat)
            nac.position = SCNVector3(nacX * s, nacY, 0.15)
            root.addChildNode(nac)
            // Oversized lower intake — a big rounded scoop under the spinner,
            // nearly the spinner's diameter (Twin Otter signature).
            let scoop = latheNode([(-0.55, 0.06), (-0.35, 0.28), (0.0, 0.34), (0.35, 0.30), (0.60, 0.10)],
                                  segments: 16, material: intakeMat)
            scoop.scale = SCNVector3(1.0, 0.85, 1.0)
            scoop.position = SCNVector3(nacX * s, nacY - 0.34, -1.55)
            root.addChildNode(scoop)
        }

        // Wing lift strut per side to ~40% semi-span, plus a single bracing
        // strut BEHIND each nacelle (Twin Otter distinctiveFeature).
        for s in [Float(-1), Float(1)] {
            root.addChildNode(strutNode(from: SCNVector3(0.82 * s, cy + 0.30, -0.55),
                                        to: SCNVector3(4.0 * s, wingY - 0.10, -0.6),
                                        radius: 0.05, material: bodyMat))
            // Bracing strut aft of each nacelle, fuselage-lower to wing.
            root.addChildNode(strutNode(from: SCNVector3(nacX * s, nacY - 0.30, 0.9),
                                        to: SCNVector3(nacX * s, wingY - 0.05, 0.6),
                                        radius: 0.035, material: bodyMat))
        }

        // CRUCIFORM tail (Twin Otter signature): a tall, square-TOPPED fin with
        // the horizontal stabilizer mounted PARTWAY UP the fin (not at the top,
        // not on the fuselage). Small dorsal fillet forward.
        let stabH: Float = 1.55   // stab attach height up the fin
        let finTop: Float = 2.55
        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0.06, y: 0))
        finPath.addLine(to: CGPoint(x: 0.30, y: CGFloat(finTop)))
        finPath.addLine(to: CGPoint(x: 1.15, y: CGFloat(finTop)))          // squared top
        finPath.addLine(to: CGPoint(x: 1.35, y: CGFloat(finTop) - 0.30))
        finPath.addQuadCurve(to: CGPoint(x: 1.95, y: 0.95), controlPoint: CGPoint(x: 1.80, y: 1.8))
        finPath.addQuadCurve(to: CGPoint(x: 3.5, y: 0.0), controlPoint: CGPoint(x: 2.3, y: 0.06))
        finPath.close()
        let fin = finNode(path: finPath, thickness: 0.15, material: tailMat)
        fin.position = SCNVector3(0, cy + 0.02, 7.35)
        root.addChildNode(fin)

        // Stab mounted partway up the fin (cruciform), braced by small struts.
        let stab = wingNode(span: 6.3, rootChord: 1.3, tipChord: 0.9, sweep: 0.1,
                            thickness: 0.11, material: bodyMat)
        stab.position = SCNVector3(0, cy + 0.02 + stabH, 7.05)
        root.addChildNode(stab)
        for s in [Float(-1), Float(1)] {
            root.addChildNode(strutNode(from: SCNVector3(1.4 * s, cy + 0.02 + stabH - 0.05, 6.6),
                                        to: SCNVector3(0.18 * s, cy + 0.02, 7.3),
                                        radius: 0.03, material: tailMat))
        }

        // Fixed tricycle gear (no fairings — bare STOL legs). Struts static,
        // main WHEELS live.
        for s in [Float(-1), Float(1)] {
            root.addChildNode(strutNode(from: SCNVector3(0.5 * s, cy - 0.05, -0.2),
                                        to: SCNVector3(1.55 * s, 0.42, -0.25),
                                        radius: 0.055, material: bodyMat))
        }
        root.addChildNode(strutNode(from: SCNVector3(0, cy - 0.1, -5.6),
                                    to: SCNVector3(0, 0.40, -5.7),
                                    radius: 0.05, material: bodyMat))
        let nw = wheelNode(radius: 0.30, width: 0.16, tire: tire, hub: hub)
        nw.position = SCNVector3(0, 0.30, -5.72)
        root.addChildNode(nw)
        return root
    }

    let body = SCNNode()
    body.addChildNode(airframe)

    // Two 3-blade turboprops, Ø ~2.59 m.
    let twin = twinPropLive(hubs: [SCNVector3(-nacX, nacY, propZ),
                                   SCNVector3( nacX, nacY, propZ)],
                            bladeCount: 3, bladeLength: 1.15, spinnerScale: 1.15,
                            discDiameter: 2.59)
    twin.install(body)

    // Live surfaces + main wheels (high wing: TE at wing.z + rootChord = 1.78).
    let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
    let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
    let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
    let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)
    let strutMat = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.5)
    let live = buildPropLive(spec: PropLiveSpec(
        wingY: wingY, wingTE_Z: -0.2, wingHalfSpan: 9.9,
        ailChord: 0.44, ailSpan: 3.0, ailInboard: 5.8,
        flapChord: 0.5, flapSpan: 4.4, flapInboard: 0.9,
        surfThickness: 0.11,
        stabY: cy + 0.02 + 1.55, stabTE_Z: 8.35, stabHalfSpan: 3.15, elevChord: 0.44,
        finBaseY: cy + 0.02, finTE_Z: 7.3, rudderHeight: 2.5, rudderChord: 0.5,
        mainX: 1.55, mainZ: -0.25, mainTopY: 0.72,
        mainRadius: 0.34, mainWidth: 0.18, mainStrutR: 0.0),
        bodyMat: bodyMat, tailMat: tailMat, tire: tire, hub: hub, strutMat: strutMat)
    live.install(on: body)

    let shadow = makeContactShadow(span: 19.8, length: 15.8)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-9.9, wingY, -1.1),
        navRight: SCNVector3(9.9, wingY, -1.1),
        tail: SCNVector3(0, cy + 0.02, 7.45),
        beacon: SCNVector3(0, cy + 2.55, 7.0),
        landing: SCNVector3(0, nacY - 0.2, -1.9)))
    return CraftParts(body: body, propGroup: twin.spinNode, blades: twin.blades,
                      blurDisc: twin.blurDisc, fanGroups: [], heatWash: [],
                      beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      navNodes: kit.navs, scalingHalos: kit.halos, contactShadow: shadow,
                      landingLight: kit.light, landingGlow: kit.glow, gear: [],
                      smokeOffset: SCNVector3(0, 0.32, -0.2),
                      gearContacts: live.gearContacts, wheels: live.wheels, oleos: live.oleos,
                      ailerons: live.ailerons, elevator: live.elevator,
                      rudder: live.rudder, flaps: live.flaps)
}

// MARK: - dc3 (Douglas DC-3 — low-wing radial-piston TWIN, taildragger)

/// dc3 — low-wing taildragger twin with two big radial piston engines (round
/// cowls, 3-blade props); retractable mains + a fixed tailwheel (NOT a nose
/// gear); polished retro finish. Mirrors buildVela + buildPropLive for the
/// surfaces, adds two radial nacelles + a Comet-style retractable main-gear
/// fold. 29.0 m span, 19.7 m length.
func buildDC3(livery: Livery) -> CraftParts {
    let pal = livery.palette
    // Taildragger: nose sits HIGH, tail low. The fuselage centreline is pitched
    // up on the ground; we model a nose-high static stance by lifting the front.
    let cy: Float = 2.15

    let wingY: Float = 1.30
    let nacX: Float = 3.55
    let nacY: Float = wingY + 0.24   // radial cowls sit proud on the wing LE
    let propZ: Float = -3.15         // props well forward of the wing

    let airframe = AirframeCache.airframe(kind: .dc3, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
        let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
        let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)

        // Fat, near-circular retro fuselage — the DC-3 'dolphin' torpedo, 19.7 m
        // nose-to-tail. Deepest through the cockpit/forward cabin, tapering to a
        // slim UPSWEPT tailcone that carries the tailwheel. The shell stays LEVEL
        // in body space so live parts (props/gear/surfaces) never float — the
        // nose-high taildragger stance comes from tall forward mains + a short
        // aft tailwheel, not from rotating the shell.
        let fus = latheNode([(-9.85, 0.16), (-9.50, 0.58), (-8.40, 0.92), (-6.80, 1.16),
                             (-4.30, 1.24), (-0.80, 1.24), (2.80, 1.10), (5.70, 0.80),
                             (8.10, 0.44), (9.85, 0.12)],
                            segments: 34,
                            material: fuselageMaterial(kind: .dc3, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Cockpit windscreen band.
        let cabin = SCNNode(geometry: SCNBox(width: 1.5, height: 0.5, length: 1.7, chamferRadius: 0.16))
        cabin.geometry?.materials = [canopyGlassMaterial()]
        cabin.position = SCNVector3(0, cy + 0.86, -7.4)
        root.addChildNode(cabin)
        // Cabin window band.
        let windowBand = SCNNode(geometry: SCNBox(width: 1.6, height: 0.34, length: 7.0, chamferRadius: 0.1))
        windowBand.geometry?.materials = [canopyGlassMaterial()]
        windowBand.position = SCNVector3(0, cy + 0.5, -2.2)
        root.addChildNode(windowBand)

        // Low wing (29.0 m span): a broad tapered center panel. The classic
        // DC-3 gull look — near-flat center section, dihedralled outer panels —
        // is read via raised, outboard-canted tip caps below.
        let wing = wingNode(span: 29.0, rootChord: 3.6, tipChord: 1.4, sweep: 1.2,
                            thickness: 0.30, material: bodyMat)
        wing.position = SCNVector3(0, wingY, 1.0)
        root.addChildNode(wing)
        // Dihedralled outer-panel hint: raised, canted wingtip caps.
        for s in [Float(-1), Float(1)] {
            let cap = SCNNode(geometry: SCNBox(width: 3.0, height: 0.26, length: 1.5, chamferRadius: 0.2))
            cap.geometry?.materials = [bodyMat]
            cap.position = SCNVector3(13.0 * s, wingY + 0.55, -0.4)
            cap.eulerAngles.z = -0.16 * s   // upward outboard bend (gull)
            root.addChildNode(cap)
        }

        // Two big ROUND RADIAL cowls on the wing LE, one per side — short fat
        // blunt cylinders with a circular cooling-air front ring and a hub boss.
        let cowlMat = pbrMaterial(UIColor(white: 0.16, alpha: 1), roughness: 0.35, metalness: 0.55)
        let ringMat = pbrMaterial(UIColor(white: 0.28, alpha: 1), roughness: 0.4, metalness: 0.5)
        for s in [Float(-1), Float(1)] {
            // Blunt round cowl — short fat lathe, widest near the front face.
            let cowl = latheNode([(-2.55, 0.40), (-2.35, 0.70), (-1.95, 0.80), (-1.30, 0.82),
                                  (-0.60, 0.78), (0.20, 0.64), (1.00, 0.46), (1.60, 0.34)],
                                 segments: 26, material: cowlMat)
            cowl.position = SCNVector3(nacX * s, nacY, -0.55)
            root.addChildNode(cowl)
            // Circular cowl-front ring (the radial's cooling-inlet lip).
            let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.72, pipeRadius: 0.10))
            ring.geometry?.materials = [ringMat]
            ring.eulerAngles.x = .pi / 2
            ring.position = SCNVector3(nacX * s, nacY, -3.05)
            root.addChildNode(ring)
            // Small central hub boss behind the spinner.
            let boss = SCNNode(geometry: SCNSphere(radius: 0.24))
            (boss.geometry as? SCNSphere)?.segmentCount = 12
            boss.geometry?.materials = [cowlMat]
            boss.position = SCNVector3(nacX * s, nacY, -2.9)
            root.addChildNode(boss)
            // Nacelle fairing trailing back over the wing to the gear bay.
            let fairing = latheNode([(-0.2, 0.44), (1.2, 0.46), (2.8, 0.38), (4.2, 0.22), (5.2, 0.06)],
                                    segments: 18, material: bodyMat)
            fairing.position = SCNVector3(nacX * s, nacY - 0.05, -0.4)
            root.addChildNode(fairing)
        }

        // Tall rounded fin with big dorsal fillet (the DC-3 silhouette).
        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0.10, y: 0))
        finPath.addLine(to: CGPoint(x: 0.35, y: 2.70))
        finPath.addQuadCurve(to: CGPoint(x: 1.35, y: 2.85), controlPoint: CGPoint(x: 0.55, y: 2.95))
        finPath.addQuadCurve(to: CGPoint(x: 2.30, y: 1.0), controlPoint: CGPoint(x: 2.15, y: 2.0))
        finPath.addQuadCurve(to: CGPoint(x: 4.6, y: 0.0), controlPoint: CGPoint(x: 2.9, y: 0.06))
        finPath.close()
        let fin = finNode(path: finPath, thickness: 0.18, material: tailMat)
        fin.position = SCNVector3(0, cy + 0.10, 8.55)
        root.addChildNode(fin)

        let stab = wingNode(span: 8.0, rootChord: 1.9, tipChord: 1.0, sweep: 0.4,
                            thickness: 0.15, material: bodyMat)
        stab.position = SCNVector3(0, cy + 0.18, 8.3)
        root.addChildNode(stab)
        return root
    }

    let body = SCNNode()
    body.addChildNode(airframe)

    // Two 3-blade radial props, Ø ~3.5 m (big Hamilton Standard).
    let twin = twinPropLive(hubs: [SCNVector3(-nacX, nacY, propZ),
                                   SCNVector3( nacX, nacY, propZ)],
                            bladeCount: 3, bladeLength: 1.60, spinnerScale: 1.35,
                            discDiameter: 3.5)
    twin.install(body)

    // Live control surfaces (low wing: wing.z + rootChord = 1.0 + 3.6 = 4.6).
    let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
    let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
    let surfBodyMat = bodyMat

    var ailerons: [Surface] = []
    var flaps: [Surface] = []
    for s in [Float(-1), Float(1)] {
        let a = hingedSurfaceNode(span: 4.2, chord: 0.75, thickness: 0.14, material: surfBodyMat)
        a.position = SCNVector3(s * 10.4, wingY, 4.6)
        ailerons.append(Surface(node: a, sign: s))
        body.addChildNode(a)
        // Inboard flap between fuselage and nacelle.
        let fl = hingedSurfaceNode(span: 2.6, chord: 0.85, thickness: 0.14, material: surfBodyMat)
        fl.position = SCNVector3(s * 1.9, wingY, 4.6)
        flaps.append(Surface(node: fl, sign: 1))
        body.addChildNode(fl)
    }
    // Elevator on the stab TE (stab.z + rootChord = 8.3 + 1.9 = 10.2).
    var elevator: [Surface] = []
    let elev = hingedSurfaceNode(span: 7.8, chord: 0.75, thickness: 0.12, material: surfBodyMat)
    elev.position = SCNVector3(0, cy + 0.18, 10.2)
    elevator.append(Surface(node: elev, sign: 1))
    body.addChildNode(elev)
    // Rudder at the fin TE (near node.z 8.55).
    var rudder: [Surface] = []
    let rud = hingedRudderNode(height: 2.5, chord: 0.7, thickness: 0.16, material: tailMat)
    rud.position = SCNVector3(0, cy + 0.10, 8.55)
    rudder.append(Surface(node: rud, sign: 1))
    body.addChildNode(rud)

    // Retractable mains (fold aft/up into the nacelles) + a FIXED tailwheel.
    let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
    let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)
    let strutMat = pbrMaterial(UIColor(white: 0.72, alpha: 1), roughness: 0.35, metalness: 0.65)

    var wheels: [(node: SCNNode, radius: Float)] = []
    var oleos: [(node: SCNNode, restY: Float, travel: Float)] = []
    var gear: [(node: SCNNode, foldedEuler: SCNVector3)] = []
    var gearContacts: [SCNVector3] = []

    func dcGearLeg(pivotAt: SCNVector3, strutLen: Float, wheelRadius: CGFloat,
                   wheelWidth: CGFloat) -> (pivot: SCNNode, oleo: SCNNode, wheel: SCNNode) {
        let pivot = SCNNode()
        pivot.position = pivotAt
        let oleo = SCNNode()
        let strut = strutNode(from: SCNVector3(0, 0, 0), to: SCNVector3(0, -strutLen, 0),
                              radius: 0.07, material: strutMat)
        oleo.addChildNode(strut.flattenedClone())
        let w = wheelNode(radius: wheelRadius, width: wheelWidth, tire: tire, hub: hub)
        w.position = SCNVector3(0, -strutLen, 0)
        oleo.addChildNode(w)
        pivot.addChildNode(oleo)
        return (pivot, oleo, w)
    }

    // Big main wheels under the nacelles (the DC-3's forward-mounted mains),
    // on long legs — these carry the weight forward and hold the nose high.
    // Pivot y = nacY-0.30 = 1.24; strut 0.69 + radius 0.55 ⇒ contact at y ≈ 0.
    let mainPivotY: Float = nacY - 0.30
    let mainStrutLen: Float = mainPivotY - 0.55   // wheel radius, so contact ≈ 0
    for s in [Float(-1), Float(1)] {
        let main = dcGearLeg(pivotAt: SCNVector3(nacX * s, mainPivotY, -1.7), strutLen: mainStrutLen,
                             wheelRadius: 0.55, wheelWidth: 0.24)
        body.addChildNode(main.pivot)
        // Mains rotate up-and-aft into the back of the nacelle (staying partly
        // exposed, the DC-3 signature — the fold only tucks them ~part way).
        gear.append((main.pivot, SCNVector3(1.35, 0, 0)))
        wheels.append((main.wheel, 0.55))
        oleos.append((main.oleo, 0, 0.12))
        gearContacts.append(SCNVector3(nacX * s, 0, -1.7))
    }
    // FIXED tailwheel — small, aft, always down (NOT part of the retract fold).
    // A short leg on the low aft fuselage: pivot y = cy-1.15 = 1.00; strut 0.76
    // + radius 0.24 ⇒ contact at y ≈ 0, keeping the tail low (nose-high stance).
    let tailPivotY: Float = cy - 1.15
    let tail = dcGearLeg(pivotAt: SCNVector3(0, tailPivotY, 7.9), strutLen: tailPivotY - 0.24,
                         wheelRadius: 0.24, wheelWidth: 0.12)
    body.addChildNode(tail.pivot)
    wheels.append((tail.wheel, 0.24))
    oleos.append((tail.oleo, 0, 0.05))
    gearContacts.append(SCNVector3(0, 0, 7.9))

    let shadow = makeContactShadow(span: 29.0, length: 19.7)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-14.5, wingY, 0.2),
        navRight: SCNVector3(14.5, wingY, 0.2),
        tail: SCNVector3(0, cy + 0.10, 8.65),
        beacon: SCNVector3(0, cy + 2.9, 7.9),
        landing: SCNVector3(0, wingY - 0.05, -0.2)))
    return CraftParts(body: body, propGroup: twin.spinNode, blades: twin.blades,
                      blurDisc: twin.blurDisc, fanGroups: [], heatWash: [],
                      beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      navNodes: kit.navs, scalingHalos: kit.halos, contactShadow: shadow,
                      landingLight: kit.light, landingGlow: kit.glow, gear: gear,
                      smokeOffset: SCNVector3(0, 0.5, -1.7),
                      gearContacts: gearContacts, wheels: wheels, oleos: oleos,
                      ailerons: ailerons, elevator: elevator, rudder: rudder, flaps: flaps)
}
