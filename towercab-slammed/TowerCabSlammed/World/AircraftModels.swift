import Foundation
import SceneKit
import UIKit

// =============================================================================
// Procedural airframes — lark72 (C172 analog), vela22 (SR22 analog),
// comet60 (Challenger-class bizjet). Stylized realism from lathes + extruded
// planforms; every material physically based; liveries baked into a shared
// fuselage wrap texture (see AircraftLiveries.swift).
//
// Model space: node origin = ground contact (bottom of tires), nose = -Z.
// The integrator owns the root transform; all animation happens on children.
// =============================================================================

// MARK: - Shared helpers (also used by CabInterior.swift)

func pbrMaterial(_ color: UIColor, roughness: CGFloat = 0.5, metalness: CGFloat = 0.0) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .physicallyBased
    m.diffuse.contents = color
    m.roughness.contents = roughness
    m.metalness.contents = metalness
    return m
}

/// Near-black blue-green glass, low roughness so the golden-hour sun glints.
func canopyGlassMaterial() -> SCNMaterial {
    let m = pbrMaterial(UIColor(red: 0.02, green: 0.055, blue: 0.06, alpha: 1),
                        roughness: 0.08, metalness: 0.1)
    return m
}

/// Surface of revolution around +Z (nose at min z). u wraps the circumference
/// with u = 0 at the belly; v runs nose→tail — matches ArtTextures.fuselage.
func latheGeometry(_ profile: [(z: Float, r: Float)], segments: Int = 28,
                   material: SCNMaterial) -> SCNGeometry {
    let rings = profile.count
    var positions: [SCNVector3] = []
    var normals: [SCNVector3] = []
    var uvs: [CGPoint] = []
    let zMin = profile.map { $0.z }.min() ?? 0
    let zMax = profile.map { $0.z }.max() ?? 1
    let zSpan = max(0.001, zMax - zMin)
    for i in 0..<rings {
        let p = profile[i]
        let prev = profile[max(0, i - 1)]
        let next = profile[min(rings - 1, i + 1)]
        let dz = next.z - prev.z
        let slope: Float = abs(dz) < 0.0001 ? 0 : (next.r - prev.r) / dz
        let k = 1 / sqrt(1 + slope * slope)
        for j in 0...segments {
            let u = Float(j) / Float(segments)
            let theta = -Float.pi / 2 + u * 2 * .pi
            let c = cos(theta), s = sin(theta)
            positions.append(SCNVector3(p.r * c, p.r * s, p.z))
            normals.append(SCNVector3(c * k, s * k, -slope * k))
            uvs.append(CGPoint(x: CGFloat(u), y: CGFloat((p.z - zMin) / zSpan)))
        }
    }
    var indices: [UInt32] = []
    let stride = UInt32(segments + 1)
    for i in 0..<UInt32(rings - 1) {
        for j in 0..<UInt32(segments) {
            let a = i * stride + j
            let b = a + 1
            let c = a + stride
            let d = c + 1
            indices.append(contentsOf: [a, d, c, a, b, d])
        }
    }
    let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: positions),
                                    SCNGeometrySource(normals: normals),
                                    SCNGeometrySource(textureCoordinates: uvs)],
                          elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    geo.materials = [material]
    return geo
}

func latheNode(_ profile: [(z: Float, r: Float)], segments: Int = 28,
               material: SCNMaterial) -> SCNNode {
    SCNNode(geometry: latheGeometry(profile, segments: segments, material: material))
}

/// Symmetric tapered wing/stab planform. Root trailing edge sits at the node's
/// z position; leading edge points toward -Z. `sweep` = tip LE setback.
private func wingNode(span: CGFloat, rootChord: CGFloat, tipChord: CGFloat, sweep: CGFloat,
                      thickness: CGFloat, material: SCNMaterial) -> SCNNode {
    let hs = span / 2
    let p = UIBezierPath()
    p.move(to: CGPoint(x: 0, y: 0))
    p.addLine(to: CGPoint(x: -hs, y: rootChord - sweep - tipChord))
    p.addLine(to: CGPoint(x: -hs, y: rootChord - sweep))
    p.addLine(to: CGPoint(x: 0, y: rootChord))
    p.addLine(to: CGPoint(x: hs, y: rootChord - sweep))
    p.addLine(to: CGPoint(x: hs, y: rootChord - sweep - tipChord))
    p.close()
    let shape = SCNShape(path: p, extrusionDepth: thickness)
    shape.chamferRadius = min(0.03, thickness * 0.3)
    shape.materials = [material]
    let n = SCNNode(geometry: shape)
    n.eulerAngles.x = -.pi / 2
    return n
}

/// Vertical surface from a profile drawn with +x = forward, +y = up.
/// The node's z position maps to path x = 0; extrusion is sideways thickness.
private func finNode(path: UIBezierPath, thickness: CGFloat, material: SCNMaterial) -> SCNNode {
    let shape = SCNShape(path: path, extrusionDepth: thickness)
    shape.chamferRadius = min(0.03, thickness * 0.3)
    shape.materials = [material]
    let n = SCNNode(geometry: shape)
    n.eulerAngles.y = .pi / 2
    return n
}

private func strutNode(from a: SCNVector3, to b: SCNVector3, radius: CGFloat,
                       material: SCNMaterial) -> SCNNode {
    let d = simd_float3(b.x - a.x, b.y - a.y, b.z - a.z)
    let len = simd_length(d)
    let cyl = SCNCylinder(radius: radius, height: CGFloat(len))
    cyl.radialSegmentCount = 10
    cyl.materials = [material]
    let n = SCNNode(geometry: cyl)
    n.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
    let dir = d / max(len, 0.0001)
    let up = simd_float3(0, 1, 0)
    if simd_dot(dir, up) < -0.9999 {
        n.simdOrientation = simd_quatf(angle: .pi, axis: simd_float3(1, 0, 0))
    } else {
        n.simdOrientation = simd_quatf(from: up, to: dir)
    }
    return n
}

private func wheelNode(radius: CGFloat, width: CGFloat,
                       tire: SCNMaterial, hub: SCNMaterial) -> SCNNode {
    let group = SCNNode()
    let t = SCNCylinder(radius: radius, height: width)
    t.radialSegmentCount = 16
    t.materials = [tire]
    let tn = SCNNode(geometry: t)
    tn.eulerAngles.z = .pi / 2
    group.addChildNode(tn)
    let h = SCNCylinder(radius: radius * 0.42, height: width + 0.015)
    h.radialSegmentCount = 12
    h.materials = [hub]
    let hn = SCNNode(geometry: h)
    hn.eulerAngles.z = .pi / 2
    group.addChildNode(hn)
    return group
}

private func haloNode(colorKey: String, color: UIColor, size: CGFloat) -> SCNNode {
    let plane = SCNPlane(width: size, height: size)
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = ArtTextures.halo(key: colorKey, color: color)
    m.blendMode = .add
    m.writesToDepthBuffer = false
    plane.materials = [m]
    let n = SCNNode(geometry: plane)
    n.constraints = [SCNBillboardConstraint()]
    n.castsShadow = false
    n.renderingOrder = 20
    return n
}

/// Emissive nav bulb + additive halo billboard. No SCNLight.
private func navLightNode(colorKey: String, color: UIColor, haloSize: CGFloat) -> SCNNode {
    let bulb = SCNSphere(radius: 0.04)
    bulb.segmentCount = 8
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = color
    bulb.materials = [m]
    let n = SCNNode(geometry: bulb)
    n.castsShadow = false
    n.addChildNode(haloNode(colorKey: colorKey, color: color, size: haloSize))
    return n
}

// MARK: - Assembled parts

private struct CraftParts {
    let body: SCNNode
    let propGroup: SCNNode?
    let blades: SCNNode?
    let blurDisc: SCNNode?
    let beaconNodes: [SCNNode]
    let strobeNodes: [SCNNode]
    let landingLight: SCNLight
    let landingGlow: [SCNNode]
    /// (pivot node, euler angles when fully retracted)
    let gear: [(node: SCNNode, foldedEuler: SCNVector3)]
    let smokeOffset: SCNVector3
}

/// Flattened static airframes cached per (kind, livery); instances get clones
/// that share geometry and materials.
private enum AirframeCache {
    private static var flats: [String: SCNNode] = [:]
    static func airframe(kind: AircraftKind, livery: Livery, build: () -> SCNNode) -> SCNNode {
        let key = kind.rawValue + "|" + livery.rawValue
        if let n = flats[key] { return n.clone() }
        let flat = build().flattenedClone()
        flat.name = "airframe"
        flats[key] = flat
        return flat.clone()
    }
}

private func fuselageMaterial(kind: AircraftKind, livery: Livery) -> SCNMaterial {
    let pal = livery.palette
    let m = SCNMaterial()
    m.lightingModel = .physicallyBased
    m.diffuse.contents = ArtTextures.fuselage(kind: kind, livery: livery)
    m.roughness.contents = pal.roughness
    m.metalness.contents = pal.metalness
    return m
}

// MARK: - Common sub-assemblies

private func makePropGroup(at position: SCNVector3, bladeCount: Int, bladeLength: CGFloat,
                           spinnerScale: Float, discDiameter: CGFloat) -> (group: SCNNode, blades: SCNNode, disc: SCNNode) {
    let group = SCNNode()
    group.position = position

    let solid = SCNNode()
    let spinnerMat = pbrMaterial(UIColor(white: 0.82, alpha: 1), roughness: 0.3, metalness: 0.7)
    let spinner = latheNode([(-0.40, 0.02), (-0.30, 0.085), (-0.14, 0.135), (0.0, 0.16)],
                            segments: 16, material: spinnerMat)
    spinner.scale = SCNVector3(spinnerScale, spinnerScale, spinnerScale)
    solid.addChildNode(spinner)
    let bladeMat = pbrMaterial(UIColor(white: 0.10, alpha: 1), roughness: 0.55)
    for i in 0..<bladeCount {
        let blade = SCNNode(geometry: SCNBox(width: 0.085, height: bladeLength,
                                             length: 0.045, chamferRadius: 0.02))
        blade.geometry?.materials = [bladeMat]
        blade.position = SCNVector3(0, 0, -0.06)
        blade.pivot = SCNMatrix4MakeTranslation(0, -Float(bladeLength) / 2 - 0.08, 0)
        blade.eulerAngles.z = Float(i) * 2 * .pi / Float(bladeCount)
        solid.addChildNode(blade)
    }
    let blades = solid.flattenedClone()
    group.addChildNode(blades)

    let plane = SCNPlane(width: discDiameter, height: discDiameter)
    let dm = SCNMaterial()
    dm.lightingModel = .constant
    dm.diffuse.contents = ArtTextures.propBlur()
    dm.isDoubleSided = true
    dm.writesToDepthBuffer = false
    plane.materials = [dm]
    let disc = SCNNode(geometry: plane)
    disc.position = SCNVector3(0, 0, -0.12)
    disc.opacity = 0
    disc.castsShadow = false
    disc.renderingOrder = 15
    group.addChildNode(disc)

    return (group, blades, disc)
}

private struct LightSpec {
    var navLeft: SCNVector3
    var navRight: SCNVector3
    var tail: SCNVector3
    var beacon: SCNVector3
    var landing: SCNVector3
}

private func makeLightKit(on body: SCNNode, spec: LightSpec)
    -> (beacons: [SCNNode], strobes: [SCNNode], light: SCNLight, glow: [SCNNode]) {
    let red = UIColor(red: 1.0, green: 0.15, blue: 0.1, alpha: 1)
    let green = UIColor(red: 0.15, green: 1.0, blue: 0.35, alpha: 1)
    let white = UIColor(white: 1, alpha: 1)

    let navL = navLightNode(colorKey: "red", color: red, haloSize: 0.7)
    navL.position = spec.navLeft
    let navR = navLightNode(colorKey: "green", color: green, haloSize: 0.7)
    navR.position = spec.navRight
    let tail = navLightNode(colorKey: "white", color: white, haloSize: 0.6)
    tail.position = spec.tail
    body.addChildNode(navL)
    body.addChildNode(navR)
    body.addChildNode(tail)

    let beacon = navLightNode(colorKey: "red", color: red, haloSize: 0.9)
    beacon.position = spec.beacon
    body.addChildNode(beacon)

    var strobes: [SCNNode] = []
    for x in [spec.navLeft.x - 0.12, spec.navRight.x + 0.12] {
        let s = haloNode(colorKey: "white", color: white, size: 1.15)
        s.position = SCNVector3(x, spec.navLeft.y, spec.navLeft.z)
        s.opacity = 0
        body.addChildNode(s)
        strobes.append(s)
    }

    // Landing light: warm emissive lens + halo + the single SCNLight spot.
    let warm = UIColor(red: 1.0, green: 0.9, blue: 0.72, alpha: 1)
    let lens = SCNSphere(radius: 0.06)
    lens.segmentCount = 8
    let lm = SCNMaterial()
    lm.lightingModel = .constant
    lm.diffuse.contents = warm
    lens.materials = [lm]
    let lensNode = SCNNode(geometry: lens)
    lensNode.position = spec.landing
    lensNode.castsShadow = false
    let spot = SCNLight()
    spot.type = .spot
    spot.color = warm
    spot.intensity = 0
    spot.spotInnerAngle = 8
    spot.spotOuterAngle = 26
    spot.attenuationStartDistance = 2
    spot.attenuationEndDistance = 130
    spot.castsShadow = false
    lensNode.light = spot
    lensNode.eulerAngles.x = -0.12   // angled slightly down the nose
    let halo = haloNode(colorKey: "landing", color: warm, size: 1.7)
    halo.position = SCNVector3(0, 0, -0.15)
    lensNode.addChildNode(halo)
    lensNode.opacity = 0
    body.addChildNode(lensNode)

    return ([beacon], strobes, spot, [lensNode])
}

// MARK: - The three airframes

/// lark72 — high strut-braced wing, fixed gear with fairings, single prop.
private func buildLark(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 1.18  // fuselage centerline height

    let airframe = AirframeCache.airframe(kind: .lark72, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
        let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
        let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)

        let fus = latheNode([(-3.95, 0.10), (-3.88, 0.42), (-3.35, 0.58), (-2.65, 0.68),
                             (-1.85, 0.72), (-0.90, 0.70), (0.10, 0.55), (1.30, 0.36),
                             (2.60, 0.20), (3.70, 0.10), (3.95, 0.02)],
                            material: fuselageMaterial(kind: .lark72, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Squared-ish glasshouse cabin.
        let cabin = SCNNode(geometry: SCNBox(width: 1.06, height: 0.5, length: 1.7, chamferRadius: 0.14))
        cabin.geometry?.materials = [canopyGlassMaterial()]
        cabin.position = SCNVector3(0, 1.72, -1.35)
        root.addChildNode(cabin)

        let wing = wingNode(span: 11.0, rootChord: 1.5, tipChord: 1.05, sweep: 0,
                            thickness: 0.13, material: bodyMat)
        wing.position = SCNVector3(0, 2.0, -0.35)
        root.addChildNode(wing)
        if let tip = pal.wingtip {
            let tm = pbrMaterial(tip, roughness: pal.roughness)
            for x in [Float(-5.42), Float(5.42)] {
                let cap = SCNNode(geometry: SCNBox(width: 0.22, height: 0.145, length: 1.07, chamferRadius: 0.04))
                cap.geometry?.materials = [tm]
                cap.position = SCNVector3(x, 2.0, -1.33)
                root.addChildNode(cap)
            }
        }
        for s in [Float(-1), Float(1)] {
            root.addChildNode(strutNode(from: SCNVector3(0.66 * s, 1.35, -1.05),
                                        to: SCNVector3(1.95 * s, 1.95, -1.15),
                                        radius: 0.032, material: bodyMat))
        }

        // Upright fin with dorsal fillet.
        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0.05, y: 0))
        finPath.addLine(to: CGPoint(x: 0.14, y: 1.42))
        finPath.addQuadCurve(to: CGPoint(x: 0.62, y: 1.52), controlPoint: CGPoint(x: 0.3, y: 1.55))
        finPath.addQuadCurve(to: CGPoint(x: 1.0, y: 0.62), controlPoint: CGPoint(x: 0.92, y: 1.1))
        finPath.addQuadCurve(to: CGPoint(x: 2.85, y: 0.0), controlPoint: CGPoint(x: 1.55, y: 0.05))
        finPath.close()
        let fin = finNode(path: finPath, thickness: 0.12, material: tailMat)
        fin.position = SCNVector3(0, 1.30, 3.92)
        root.addChildNode(fin)

        let stab = wingNode(span: 3.4, rootChord: 0.95, tipChord: 0.6, sweep: 0.15,
                            thickness: 0.08, material: bodyMat)
        stab.position = SCNVector3(0, 1.32, 3.9)
        root.addChildNode(stab)

        // Fixed tricycle gear with wheel fairings.
        let fairing: [(z: Float, r: Float)] = [(-0.36, 0.03), (-0.16, 0.17), (0.05, 0.20),
                                               (0.30, 0.12), (0.50, 0.02)]
        for s in [Float(-1), Float(1)] {
            root.addChildNode(strutNode(from: SCNVector3(0.35 * s, 0.95, -0.30),
                                        to: SCNVector3(1.15 * s, 0.36, -0.35),
                                        radius: 0.04, material: bodyMat))
            let w = wheelNode(radius: 0.24, width: 0.16, tire: tire, hub: hub)
            w.position = SCNVector3(1.18 * s, 0.24, -0.35)
            root.addChildNode(w)
            let f = latheNode(fairing, segments: 16, material: bodyMat)
            f.position = SCNVector3(1.18 * s, 0.34, -0.35)
            root.addChildNode(f)
        }
        root.addChildNode(strutNode(from: SCNVector3(0, 0.85, -3.0),
                                    to: SCNVector3(0, 0.30, -3.08),
                                    radius: 0.035, material: bodyMat))
        let nw = wheelNode(radius: 0.22, width: 0.14, tire: tire, hub: hub)
        nw.position = SCNVector3(0, 0.22, -3.1)
        root.addChildNode(nw)
        let nf = latheNode(fairing, segments: 16, material: bodyMat)
        nf.scale = SCNVector3(0.9, 0.9, 0.9)
        nf.position = SCNVector3(0, 0.31, -3.1)
        root.addChildNode(nf)
        return root
    }

    let body = SCNNode()
    body.addChildNode(airframe)
    let prop = makePropGroup(at: SCNVector3(0, cy, -3.94), bladeCount: 2, bladeLength: 0.82,
                             spinnerScale: 1.0, discDiameter: 1.95)
    body.addChildNode(prop.group)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-5.5, 2.0, -1.35),
        navRight: SCNVector3(5.5, 2.0, -1.35),
        tail: SCNVector3(0, 1.42, 3.97),
        beacon: SCNVector3(0, 2.80, 3.55),
        landing: SCNVector3(0, 0.93, -3.92)))
    return CraftParts(body: body, propGroup: prop.group, blades: prop.blades,
                      blurDisc: prop.disc, beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      landingLight: kit.light, landingGlow: kit.glow, gear: [],
                      smokeOffset: SCNVector3(0, 0.26, -0.35))
}

/// vela22 — sleek low wing, composite-smooth fuselage, raked canopy, fixed gear.
private func buildVela(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 1.02

    let airframe = AirframeCache.airframe(kind: .vela22, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
        let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
        let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)

        let fus = latheNode([(-3.95, 0.10), (-3.78, 0.35), (-3.05, 0.55), (-2.10, 0.66),
                             (-1.00, 0.68), (0.20, 0.60), (1.40, 0.40), (2.70, 0.22),
                             (3.80, 0.08)],
                            material: fuselageMaterial(kind: .vela22, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Raked bubble canopy.
        let canopy = SCNNode(geometry: SCNSphere(radius: 0.6))
        (canopy.geometry as? SCNSphere)?.segmentCount = 24
        canopy.geometry?.materials = [canopyGlassMaterial()]
        canopy.scale = SCNVector3(0.82, 0.6, 1.65)
        canopy.position = SCNVector3(0, 1.38, -1.1)
        root.addChildNode(canopy)

        let wing = wingNode(span: 11.7, rootChord: 1.45, tipChord: 0.85, sweep: 0.25,
                            thickness: 0.13, material: bodyMat)
        wing.position = SCNVector3(0, 0.72, -0.15)
        root.addChildNode(wing)
        if let tip = pal.wingtip {
            let tm = pbrMaterial(tip, roughness: pal.roughness)
            for x in [Float(-5.76), Float(5.76)] {
                let cap = SCNNode(geometry: SCNBox(width: 0.2, height: 0.145, length: 0.87, chamferRadius: 0.04))
                cap.geometry?.materials = [tm]
                cap.position = SCNVector3(x, 0.72, -0.93)
                root.addChildNode(cap)
            }
        }

        // Slightly swept fin.
        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0.05, y: 0))
        finPath.addLine(to: CGPoint(x: 0.30, y: 1.22))
        finPath.addQuadCurve(to: CGPoint(x: 0.72, y: 1.30), controlPoint: CGPoint(x: 0.45, y: 1.34))
        finPath.addQuadCurve(to: CGPoint(x: 2.15, y: 0.0), controlPoint: CGPoint(x: 1.35, y: 0.45))
        finPath.close()
        let fin = finNode(path: finPath, thickness: 0.11, material: tailMat)
        fin.position = SCNVector3(0, 1.12, 3.80)
        root.addChildNode(fin)

        let stab = wingNode(span: 3.3, rootChord: 0.8, tipChord: 0.5, sweep: 0.25,
                            thickness: 0.08, material: bodyMat)
        stab.position = SCNVector3(0, 1.12, 3.82)
        root.addChildNode(stab)

        // Fixed gear in sleek pants.
        let pants: [(z: Float, r: Float)] = [(-0.42, 0.02), (-0.20, 0.15), (0.05, 0.18),
                                             (0.35, 0.10), (0.55, 0.02)]
        for s in [Float(-1), Float(1)] {
            root.addChildNode(strutNode(from: SCNVector3(0.5 * s, 0.75, -0.45),
                                        to: SCNVector3(1.37 * s, 0.36, -0.5),
                                        radius: 0.035, material: bodyMat))
            let w = wheelNode(radius: 0.25, width: 0.14, tire: tire, hub: hub)
            w.position = SCNVector3(1.4 * s, 0.25, -0.5)
            root.addChildNode(w)
            let p = latheNode(pants, segments: 16, material: bodyMat)
            p.position = SCNVector3(1.4 * s, 0.36, -0.5)
            root.addChildNode(p)
        }
        root.addChildNode(strutNode(from: SCNVector3(0, 0.7, -2.88),
                                    to: SCNVector3(0, 0.28, -2.95),
                                    radius: 0.032, material: bodyMat))
        let nw = wheelNode(radius: 0.22, width: 0.13, tire: tire, hub: hub)
        nw.position = SCNVector3(0, 0.22, -2.97)
        root.addChildNode(nw)
        let np = latheNode(pants, segments: 16, material: bodyMat)
        np.scale = SCNVector3(0.85, 0.85, 0.85)
        np.position = SCNVector3(0, 0.31, -2.97)
        root.addChildNode(np)
        return root
    }

    let body = SCNNode()
    body.addChildNode(airframe)
    let prop = makePropGroup(at: SCNVector3(0, cy, -3.92), bladeCount: 3, bladeLength: 0.78,
                             spinnerScale: 1.05, discDiameter: 1.85)
    body.addChildNode(prop.group)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-5.8, 0.8, -0.93),
        navRight: SCNVector3(5.8, 0.8, -0.93),
        tail: SCNVector3(0, 1.12, 3.86),
        beacon: SCNVector3(0, 2.36, 3.55),
        landing: SCNVector3(0, 0.72, -3.9)))
    return CraftParts(body: body, propGroup: prop.group, blades: prop.blades,
                      blurDisc: prop.disc, beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      landingLight: kit.light, landingGlow: kit.glow, gear: [],
                      smokeOffset: SCNVector3(0, 0.28, -0.5))
}

/// comet60 — low swept wing, aft twin nacelles, T-tail, retractable gear.
private func buildComet(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 1.95

    let airframe = AirframeCache.airframe(kind: .comet60, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let accentMat = pbrMaterial(pal.accent, roughness: 0.25, metalness: 0.7)

        let fus = latheNode([(-9.20, 0.10), (-9.00, 0.50), (-8.20, 0.85), (-6.80, 1.05),
                             (-4.50, 1.15), (2.00, 1.15), (4.80, 1.02), (6.80, 0.78),
                             (8.40, 0.45), (9.25, 0.12)],
                            segments: 32,
                            material: fuselageMaterial(kind: .comet60, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Raked windscreen cap.
        let screen = SCNNode(geometry: SCNSphere(radius: 0.68))
        (screen.geometry as? SCNSphere)?.segmentCount = 24
        screen.geometry?.materials = [canopyGlassMaterial()]
        screen.scale = SCNVector3(0.78, 0.5, 1.15)
        screen.position = SCNVector3(0, 2.62, -7.15)
        root.addChildNode(screen)

        let wing = wingNode(span: 19.6, rootChord: 3.4, tipChord: 1.0, sweep: 2.6,
                            thickness: 0.24, material: bodyMat)
        wing.position = SCNVector3(0, 1.0, 2.2)
        root.addChildNode(wing)

        // Winglets.
        for s in [Float(-1), Float(1)] {
            let wp = UIBezierPath()
            wp.move(to: CGPoint(x: 0, y: 0))
            wp.addLine(to: CGPoint(x: 0.18, y: 0.78))
            wp.addQuadCurve(to: CGPoint(x: 0.5, y: 0.82), controlPoint: CGPoint(x: 0.3, y: 0.85))
            wp.addQuadCurve(to: CGPoint(x: 0.95, y: 0.0), controlPoint: CGPoint(x: 0.8, y: 0.25))
            wp.close()
            let wl = finNode(path: wp, thickness: 0.05, material: bodyMat)
            wl.position = SCNVector3(9.72 * s, 1.12, 1.75)
            root.addChildNode(wl)
        }

        // Aft fuselage-mounted nacelles + pylons.
        let nacMat = pbrMaterial(pal.body, roughness: max(0.12, pal.roughness - 0.06),
                                 metalness: min(1, pal.metalness + 0.15))
        let intakeMat = pbrMaterial(UIColor(white: 0.05, alpha: 1), roughness: 0.4)
        for s in [Float(-1), Float(1)] {
            let nac = latheNode([(-1.75, 0.16), (-1.62, 0.44), (-1.15, 0.56), (-0.20, 0.58),
                                 (0.90, 0.52), (1.60, 0.30), (1.85, 0.12)],
                                segments: 20, material: nacMat)
            nac.position = SCNVector3(1.72 * s, 2.62, 5.3)
            root.addChildNode(nac)
            let intake = SCNNode(geometry: SCNCylinder(radius: 0.42, height: 0.04))
            intake.geometry?.materials = [intakeMat]
            intake.eulerAngles.x = .pi / 2
            intake.position = SCNVector3(1.72 * s, 2.62, 3.58)
            root.addChildNode(intake)
            let pylon = SCNNode(geometry: SCNBox(width: 0.14, height: 0.55, length: 1.7, chamferRadius: 0.05))
            pylon.geometry?.materials = [bodyMat]
            pylon.eulerAngles.z = 0.5 * s
            pylon.position = SCNVector3(1.25 * s, 2.45, 5.25)
            root.addChildNode(pylon)
        }

        // T-tail.
        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0.10, y: 0))
        finPath.addLine(to: CGPoint(x: 0.55, y: 3.30))
        finPath.addQuadCurve(to: CGPoint(x: 1.60, y: 3.42), controlPoint: CGPoint(x: 0.95, y: 3.5))
        finPath.addQuadCurve(to: CGPoint(x: 2.70, y: 0.28), controlPoint: CGPoint(x: 2.3, y: 1.5))
        finPath.addQuadCurve(to: CGPoint(x: 3.40, y: 0.0), controlPoint: CGPoint(x: 3.0, y: 0.06))
        finPath.close()
        let fin = finNode(path: finPath, thickness: 0.2, material: bodyMat)
        fin.position = SCNVector3(0, 2.45, 8.9)
        root.addChildNode(fin)
        let stab = wingNode(span: 6.4, rootChord: 1.5, tipChord: 0.8, sweep: 0.8,
                            thickness: 0.14, material: bodyMat)
        stab.position = SCNVector3(0, 5.85, 8.55)
        root.addChildNode(stab)
        if livery == .meridianVIP {
            let crest = SCNNode(geometry: SCNBox(width: 0.26, height: 0.62, length: 0.44, chamferRadius: 0.08))
            crest.geometry?.materials = [accentMat]
            crest.position = SCNVector3(0, 4.85, 7.85)
            root.addChildNode(crest)
        }
        return root
    }

    let body = SCNNode()
    body.addChildNode(airframe)

    // Retractable gear — dynamic, one flattened leg under each pivot.
    let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
    let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)
    let strutMat = pbrMaterial(UIColor(white: 0.75, alpha: 1), roughness: 0.35, metalness: 0.7)

    func gearLeg(strutLen: Float, wheelRadius: CGFloat, wheelWidth: CGFloat, twin: Bool) -> SCNNode {
        let leg = SCNNode()
        leg.addChildNode(strutNode(from: SCNVector3(0, 0, 0),
                                   to: SCNVector3(0, -strutLen, 0),
                                   radius: 0.055, material: strutMat))
        let xs: [Float] = twin ? [-0.13, 0.13] : [0]
        for x in xs {
            let w = wheelNode(radius: wheelRadius, width: wheelWidth, tire: tire, hub: hub)
            w.position = SCNVector3(x, -strutLen, 0)
            leg.addChildNode(w)
        }
        return leg.flattenedClone()
    }

    let nosePivot = SCNNode()
    nosePivot.position = SCNVector3(0, 1.16, -6.6)
    nosePivot.addChildNode(gearLeg(strutLen: 0.86, wheelRadius: 0.30, wheelWidth: 0.11, twin: true))
    body.addChildNode(nosePivot)

    var gear: [(node: SCNNode, foldedEuler: SCNVector3)] =
        [(nosePivot, SCNVector3(1.7, 0, 0))]  // folds forward into the nose
    for s in [Float(-1), Float(1)] {
        let pivot = SCNNode()
        pivot.position = SCNVector3(1.9 * s, 0.95, 1.4)
        pivot.addChildNode(gearLeg(strutLen: 0.53, wheelRadius: 0.42, wheelWidth: 0.3, twin: false))
        body.addChildNode(pivot)
        gear.append((pivot, SCNVector3(0, 0, 1.85 * -s)))  // mains fold inboard
    }

    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-9.68, 1.15, 1.8),
        navRight: SCNVector3(9.68, 1.15, 1.8),
        tail: SCNVector3(0, 2.28, 9.3),
        beacon: SCNVector3(0, 3.14, -1.0),
        landing: SCNVector3(0, 1.42, -9.0)))
    return CraftParts(body: body, propGroup: nil, blades: nil, blurDisc: nil,
                      beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      landingLight: kit.light, landingGlow: kit.glow, gear: gear,
                      smokeOffset: SCNVector3(0, 0.5, 1.4))
}

// MARK: - Live entity

final class CraftEntity: AircraftEntity {
    let node = SCNNode()
    private let parts: CraftParts
    private var time: Double
    private var propRate: Double = 0
    private var gearFold: Double = 0
    private var lastPhase: FlightPhase?
    private let bobPhase: Double

    private static var instanceCounter = 0

    init(kind: AircraftKind, livery: Livery) {
        switch kind {
        case .lark72: parts = buildLark(livery: livery)
        case .vela22: parts = buildVela(livery: livery)
        case .comet60: parts = buildComet(livery: livery)
        }
        node.addChildNode(parts.body)
        CraftEntity.instanceCounter += 1
        let seed = Double(CraftEntity.instanceCounter)
        bobPhase = seed * 2.399   // golden-angle spread so formations don't sync
        time = seed * 1.37
    }

    func update(_ state: AircraftRenderState, dt: TimeInterval) {
        // Root transform is owned by the integrator — set exactly as the stub did.
        node.position = SCNVector3(state.position.x, state.position.y, state.position.z)
        node.eulerAngles = SCNVector3(Float(state.pitch), -Float(state.heading), -Float(state.bank))

        time += dt
        let phase = state.phase

        // Subtle life: tiny speed-scaled bob only when airborne.
        if phase.isAirborne {
            let amp = 0.045 * min(1.0, state.speed / 45.0)
            parts.body.position.y = Float(amp * sin(time * 5.3 + bobPhase))
        } else {
            parts.body.position.y = 0
        }

        // Propeller.
        if let prop = parts.propGroup {
            let target: Double
            if phase == .parkedArrival || phase == .removed {
                target = 0
            } else if phase.isAirborne || phase == .takeoffRoll {
                target = 82
            } else {
                target = max(11, state.speed * 3.0)
            }
            propRate += (target - propRate) * min(1, dt * 1.6)
            prop.eulerAngles.z -= Float(propRate * dt)
            parts.blades?.opacity = CGFloat(max(0, min(1, 1 - (propRate - 14) / 16)))
            parts.blurDisc?.opacity = CGFloat(0.55 * max(0, min(1, (propRate - 22) / 28)))
        }

        // Beacon — soft red pulse, ~1.2 s cycle.
        let pulse = pow(max(0, sin(fmod(time, 1.2) / 1.2 * .pi)), 3.0)
        for n in parts.beaconNodes { n.opacity = CGFloat(0.15 + 0.85 * pulse) }

        // Strobes — brief white double-flash, ~1.8 s cycle, off when parked.
        let parked = phase == .parkedArrival || phase == .startingUp || phase == .removed
        let sp = fmod(time, 1.8)
        let flash = !parked && (sp < 0.05 || (sp > 0.14 && sp < 0.19))
        for n in parts.strobeNodes { n.opacity = flash ? 1 : 0 }

        // Landing light — lens/halo fade + the one spot. The halo scales with
        // distance from the cab so a light on 3-mile final still reads as the
        // golden-hour "pearl" (PRD: lights must sparkle on final).
        let want: CGFloat = state.landingLightsOn ? 1 : 0
        let toEye = SIMD3<Float>(Float(state.position.x), Float(state.position.y),
                                 Float(state.position.z)) - aircraftObserverEye
        let dist = simd_length(toEye)
        let haloScale = max(1, min(16, dist / 180))
        for n in parts.landingGlow {
            n.opacity += (want - n.opacity) * CGFloat(min(1, dt * 8))
            n.scale = SCNVector3(haloScale, haloScale, haloScale)
        }
        parts.landingLight.intensity = 2600 * (parts.landingGlow.first?.opacity ?? 0)

        // Retractable gear — smooth ~1.5 s swing.
        if !parts.gear.isEmpty {
            let target: Double = state.gearDown ? 0 : 1
            if lastPhase == nil {
                gearFold = target  // snap on spawn, animate afterwards
            } else {
                let step = dt / 1.5
                gearFold += max(-step, min(step, target - gearFold))
            }
            let f = Float(gearFold)
            for g in parts.gear {
                g.node.eulerAngles = SCNVector3(g.foldedEuler.x * f,
                                                g.foldedEuler.y * f,
                                                g.foldedEuler.z * f)
                g.node.isHidden = gearFold > 0.995
            }
        }

        // Touchdown puff on the flare → rollout transition.
        if lastPhase == .flare && phase == .rollout && state.speed > 10 {
            emitTireSmoke()
        }
        lastPhase = phase
    }

    private func emitTireSmoke() {
        let ps = SCNParticleSystem()
        ps.loops = false
        ps.emissionDuration = 0.25
        ps.birthRate = 300
        ps.particleLifeSpan = 0.8
        ps.particleLifeSpanVariation = 0.25
        ps.particleVelocity = 2.6
        ps.particleVelocityVariation = 1.6
        ps.emittingDirection = SCNVector3(0, 1, 0.6)
        ps.spreadingAngle = 55
        ps.particleSize = 0.55
        ps.particleSizeVariation = 0.3
        ps.particleImage = ArtTextures.softPuff()
        ps.particleColor = UIColor(white: 0.72, alpha: 0.4)
        ps.blendMode = .alpha
        let fade = CAKeyframeAnimation()
        fade.values = [0.55, 0.35, 0.0]
        fade.keyTimes = [0, 0.4, 1]
        fade.duration = 1
        ps.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
        let grow = CAKeyframeAnimation()
        grow.values = [0.35, 1.1]
        grow.keyTimes = [0, 1]
        grow.duration = 1
        ps.propertyControllers?[.size] = SCNParticlePropertyController(animation: grow)

        let n = SCNNode()
        n.position = parts.smokeOffset
        n.addParticleSystem(ps)
        parts.body.addChildNode(n)
        n.runAction(.sequence([.wait(duration: 1.8), .removeFromParentNode()]))
    }
}
