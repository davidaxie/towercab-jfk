import Foundation
import SceneKit
import UIKit

// =============================================================================
// Procedural airframes — three fully-rigged builds back the whole fleet:
//   buildLark  → c172 (Cessna 172, high-wing single)
//   buildVela  → sr22 (Cirrus SR22, low-wing single)
//   buildComet → challenger350 (Challenger 350, twin-nacelle bizjet)
// The other 13 real types are PLACEHOLDERs (pending real models): each maps to
// its nearest rigged build and is uniformly scaled by wingspan so size/rarity
// still reads. Stylized realism from lathes + extruded planforms; every
// material physically based; liveries baked into a shared fuselage wrap texture
// (see AircraftLiveries.swift).
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
func wingNode(span: CGFloat, rootChord: CGFloat, tipChord: CGFloat, sweep: CGFloat,
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
func finNode(path: UIBezierPath, thickness: CGFloat, material: SCNMaterial) -> SCNNode {
    let shape = SCNShape(path: path, extrusionDepth: thickness)
    shape.chamferRadius = min(0.03, thickness * 0.3)
    shape.materials = [material]
    let n = SCNNode(geometry: shape)
    n.eulerAngles.y = .pi / 2
    return n
}

func strutNode(from a: SCNVector3, to b: SCNVector3, radius: CGFloat,
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

func wheelNode(radius: CGFloat, width: CGFloat,
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

func haloNode(colorKey: String, color: UIColor, size: CGFloat) -> SCNNode {
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
/// Returns the halo separately so it can distance-scale (D25).
func navLightNode(colorKey: String, color: UIColor, haloSize: CGFloat)
    -> (node: SCNNode, halo: SCNNode) {
    let bulb = SCNSphere(radius: 0.04)
    bulb.segmentCount = 8
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = color
    bulb.materials = [m]
    let n = SCNNode(geometry: bulb)
    n.castsShadow = false
    let halo = haloNode(colorKey: colorKey, color: color, size: haloSize)
    n.addChildNode(halo)
    return (n, halo)
}

/// D24: radial-gradient contact shadow planted at ground contact. Fades with
/// phase in CraftEntity.update; fully visible by default for parked statics.
func makeContactShadow(span: CGFloat, length: CGFloat) -> SCNNode {
    let plane = SCNPlane(width: span * 0.55, height: length * 0.8)
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = ArtTextures.contactShadow()
    m.blendMode = .alpha
    m.writesToDepthBuffer = false
    plane.materials = [m]
    let n = SCNNode(geometry: plane)
    n.eulerAngles.x = -.pi / 2
    n.position.y = 0.02
    n.opacity = 0.42
    n.castsShadow = false
    n.renderingOrder = 5
    return n
}

// MARK: - Assembled parts

/// One live turbofan: a spun fan hub with blades + an additive blur disc at the
/// intake. Kept LIVE (never flattened) so the hub spins.
struct FanGroup {
    let spinner: SCNNode   // the fan hub + blades (rotates about local Z)
    let disc: SCNNode      // additive blur billboard, opacity driven by throttle
}

/// A hinged control surface: a live sub-node that pivots at its hinge line.
/// `sign` lets a pair (e.g. ailerons) deflect in opposition from one input.
struct Surface {
    let node: SCNNode
    let sign: Float
}

struct CraftParts {
    let body: SCNNode
    let propGroup: SCNNode?
    let blades: SCNNode?
    let blurDisc: SCNNode?
    /// challenger350 turbofans (empty for prop types).
    let fanGroups: [FanGroup]
    /// Warm heat-wash nodes behind the nacelles, gated on throttle (jets only).
    let heatWash: [SCNNode]
    let beaconNodes: [SCNNode]
    let strobeNodes: [SCNNode]
    /// Steady nav/tail bulbs — off at build (parked statics), lit in update().
    let navNodes: [SCNNode]
    /// Nav/beacon/strobe halo billboards that distance-scale (D25).
    let scalingHalos: [SCNNode]
    let contactShadow: SCNNode
    let landingLight: SCNLight
    let landingGlow: [SCNNode]
    /// (pivot node, euler angles when fully retracted)
    let gear: [(node: SCNNode, foldedEuler: SCNVector3)]
    let smokeOffset: SCNVector3
    /// Live main-gear contact points for the touchdown puff (world offsets in
    /// body space, at the tire contact patch).
    let gearContacts: [SCNVector3]
    /// Live wheel groups (spin about local X when rolling).
    let wheels: [(node: SCNNode, radius: Float)]
    /// Live oleo nodes that compress on the ground / squash on touchdown.
    /// `restY` is the un-compressed local Y; the node is pushed down from there.
    let oleos: [(node: SCNNode, restY: Float, travel: Float)]
    // Control surfaces.
    let ailerons: [Surface]
    let elevator: [Surface]
    let rudder: [Surface]
    let flaps: [Surface]
}

/// Flattened static airframes cached per (kind, livery); instances get clones
/// that share geometry and materials.
enum AirframeCache {
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

func fuselageMaterial(kind: AircraftKind, livery: Livery) -> SCNMaterial {
    let pal = livery.palette
    let m = SCNMaterial()
    m.lightingModel = .physicallyBased
    m.diffuse.contents = ArtTextures.fuselage(kind: kind, livery: livery)
    m.roughness.contents = pal.roughness
    m.metalness.contents = pal.metalness
    return m
}

// MARK: - Common sub-assemblies

func makePropGroup(at position: SCNVector3, bladeCount: Int, bladeLength: CGFloat,
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

// MARK: - Live control surfaces

/// A trailing-edge control surface: a thin slab whose LEADING edge is the hinge.
/// The returned node's pivot sits on the hinge line so `eulerAngles.x` swings the
/// slab trailing-edge-up (+) / down (−). Positive `chord` extends aft (+Z).
/// Kept LIVE — never flattened into the airframe cache.
func hingedSurfaceNode(span: CGFloat, chord: CGFloat, thickness: CGFloat,
                               material: SCNMaterial) -> SCNNode {
    let box = SCNBox(width: span, height: thickness, length: chord,
                     chamferRadius: min(0.02, thickness * 0.4))
    box.materials = [material]
    let n = SCNNode(geometry: box)
    // Geometry centered on the box; shift so the hinge (leading edge, −Z end)
    // is at the node origin and the slab extends aft.
    n.position = SCNVector3(0, 0, Float(chord) / 2)
    let pivot = SCNNode()
    pivot.addChildNode(n)
    return pivot
}

/// A rudder hinged about its LEADING (forward) edge, swinging left/right
/// (`eulerAngles.y`). Vertical slab: `height` up, `chord` aft.
func hingedRudderNode(height: CGFloat, chord: CGFloat, thickness: CGFloat,
                              material: SCNMaterial) -> SCNNode {
    let box = SCNBox(width: thickness, height: height, length: chord,
                     chamferRadius: min(0.02, thickness * 0.4))
    box.materials = [material]
    let n = SCNNode(geometry: box)
    n.position = SCNVector3(0, Float(height) / 2, Float(chord) / 2)
    let pivot = SCNNode()
    pivot.addChildNode(n)
    return pivot
}

// MARK: - Live wheel + oleo assembly

/// A live main-gear leg: an oleo strut node (compresses vertically) carrying a
/// live wheel that spins about local X. Returns the handles the entity animates.
/// `topY` = strut top attach height; wheel contact sits at y ≈ 0.
func liveGearLeg(topY: Float, wheelRadius: CGFloat, wheelWidth: CGFloat,
                         strutRadius: CGFloat, travel: Float,
                         tire: SCNMaterial, hub: SCNMaterial, strut: SCNMaterial)
    -> (leg: SCNNode, oleo: SCNNode, wheel: SCNNode) {
    let leg = SCNNode()
    // Oleo node holds the sliding portion; compressing it drops the wheel a
    // touch and shortens the visible strut.
    let oleo = SCNNode()
    oleo.position.y = topY
    let strutLen = topY - Float(wheelRadius)
    // strutRadius == 0 ⇒ the static shell already carries the visible strut
    // (fixed-gear pants); we only add a live wheel here.
    if strutRadius > 0 {
        oleo.addChildNode(strutNode(from: SCNVector3(0, 0, 0),
                                    to: SCNVector3(0, -strutLen, 0),
                                    radius: strutRadius, material: strut))
    }
    let wheel = wheelNode(radius: wheelRadius, width: wheelWidth, tire: tire, hub: hub)
    wheel.position = SCNVector3(0, -strutLen, 0)
    oleo.addChildNode(wheel)
    leg.addChildNode(oleo)
    _ = travel
    return (leg, oleo, wheel)
}

// MARK: - Turbofan (challenger350)

/// One live turbofan: a dark fan hub with a few blades that spins, plus a
/// cool-tinted additive blur disc parked at the intake face. The static nacelle
/// shell is built into the airframe cache; only this spinning core stays live.
func makeFanGroup(at position: SCNVector3, radius: CGFloat) -> (group: SCNNode, fan: FanGroup) {
    let group = SCNNode()
    group.position = position

    // Spun hub + blades — kept live (NOT flattened) so it can rotate.
    let spinner = SCNNode()
    let hubMat = pbrMaterial(UIColor(white: 0.06, alpha: 1), roughness: 0.5, metalness: 0.4)
    let cone = SCNCone(topRadius: 0, bottomRadius: radius * 0.24, height: radius * 0.5)
    cone.radialSegmentCount = 12
    cone.materials = [hubMat]
    let hub = SCNNode(geometry: cone)
    hub.eulerAngles.x = -.pi / 2   // nose cone points forward (−Z)
    hub.position.z = -Float(radius) * 0.18
    spinner.addChildNode(hub)

    let bladeMat = pbrMaterial(UIColor(white: 0.14, alpha: 1), roughness: 0.4, metalness: 0.5)
    let bladeCount = 10
    for i in 0..<bladeCount {
        let blade = SCNNode(geometry: SCNBox(width: 0.04, height: radius * 0.82,
                                             length: 0.02, chamferRadius: 0.008))
        blade.geometry?.materials = [bladeMat]
        blade.pivot = SCNMatrix4MakeTranslation(0, -Float(radius) * 0.41, 0)
        blade.eulerAngles.z = Float(i) * 2 * .pi / Float(bladeCount)
        spinner.addChildNode(blade)
    }
    group.addChildNode(spinner)

    // Cool blur disc at the intake face — jets always read blurred. Sits just
    // forward of the fan and double-sided so it reads from any cab angle.
    let plane = SCNPlane(width: radius * 2, height: radius * 2)
    let dm = SCNMaterial()
    dm.lightingModel = .constant
    dm.diffuse.contents = ArtTextures.fanBlur()
    dm.blendMode = .add
    dm.isDoubleSided = true
    dm.writesToDepthBuffer = false
    plane.materials = [dm]
    let disc = SCNNode(geometry: plane)
    disc.position = SCNVector3(0, 0, -Float(radius) * 0.35)
    disc.opacity = 0
    disc.castsShadow = false
    disc.renderingOrder = 15
    group.addChildNode(disc)

    return (group, FanGroup(spinner: spinner, disc: disc))
}

/// Warm additive heat-wash billboard placed behind a nacelle exhaust. Faces the
/// camera; opacity is throttle-gated in update(). No harsh gray smoke.
func makeHeatWash(at position: SCNVector3, size: CGFloat) -> SCNNode {
    let plane = SCNPlane(width: size, height: size)
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = ArtTextures.heatWash()
    m.blendMode = .add
    m.writesToDepthBuffer = false
    plane.materials = [m]
    let n = SCNNode(geometry: plane)
    n.constraints = [SCNBillboardConstraint()]
    n.position = position
    n.opacity = 0
    n.castsShadow = false
    n.renderingOrder = 14
    return n
}

struct LightSpec {
    var navLeft: SCNVector3
    var navRight: SCNVector3
    var tail: SCNVector3
    var beacon: SCNVector3
    var landing: SCNVector3
}

func makeLightKit(on body: SCNNode, spec: LightSpec)
    -> (beacons: [SCNNode], strobes: [SCNNode], navs: [SCNNode], halos: [SCNNode],
        light: SCNLight, glow: [SCNNode]) {
    let red = UIColor(red: 1.0, green: 0.15, blue: 0.1, alpha: 1)
    let green = UIColor(red: 0.15, green: 1.0, blue: 0.35, alpha: 1)
    let white = UIColor(white: 1, alpha: 1)

    let navL = navLightNode(colorKey: "red", color: red, haloSize: 0.7)
    navL.node.position = spec.navLeft
    let navR = navLightNode(colorKey: "green", color: green, haloSize: 0.7)
    navR.node.position = spec.navRight
    let tail = navLightNode(colorKey: "white", color: white, haloSize: 0.6)
    tail.node.position = spec.tail
    let navs = [navL.node, navR.node, tail.node]
    for n in navs {
        n.opacity = 0   // all lights off until update() runs (parked statics)
        body.addChildNode(n)
    }

    let beacon = navLightNode(colorKey: "red", color: red, haloSize: 0.9)
    beacon.node.position = spec.beacon
    beacon.node.opacity = 0
    body.addChildNode(beacon.node)

    var strobes: [SCNNode] = []
    for x in [spec.navLeft.x - 0.12, spec.navRight.x + 0.12] {
        let s = haloNode(colorKey: "white", color: white, size: 1.15)
        s.position = SCNVector3(x, spec.navLeft.y, spec.navLeft.z)
        s.opacity = 0
        body.addChildNode(s)
        strobes.append(s)
    }
    let halos = [navL.halo, navR.halo, tail.halo, beacon.halo] + strobes

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

    return ([beacon.node], strobes, navs, halos, spot, [lensNode])
}

// MARK: - The three airframes

/// Live surfaces + wheels shared by the two fixed-gear prop types. Built once
/// per instance (NOT cached/flattened) and added onto `body`.
struct PropLive {
    var ailerons: [Surface] = []
    var elevator: [Surface] = []
    var rudder: [Surface] = []
    var flaps: [Surface] = []
    var wheels: [(node: SCNNode, radius: Float)] = []
    var oleos: [(node: SCNNode, restY: Float, travel: Float)] = []
    var gearContacts: [SCNVector3] = []
    /// Live gear-leg root nodes the caller adds onto `body`.
    var legRoots: [SCNNode] = []

    /// Add every live node onto `body` and collect the surfaces for update().
    func install(on body: SCNNode) {
        for s in ailerons + elevator + rudder + flaps { body.addChildNode(s.node) }
        for leg in legRoots { body.addChildNode(leg) }
    }
}

/// Geometry knobs for a prop type's live surfaces + main wheels.
struct PropLiveSpec {
    // Wing (for ailerons + flaps): y height, trailing-edge z, half-span,
    // surface chord + thickness.
    let wingY: Float, wingTE_Z: Float, wingHalfSpan: Float
    let ailChord: CGFloat, ailSpan: CGFloat, ailInboard: Float
    let flapChord: CGFloat, flapSpan: CGFloat, flapInboard: Float
    let surfThickness: CGFloat
    // Stab (elevator): y, trailing-edge z, half-span, chord.
    let stabY: Float, stabTE_Z: Float, stabHalfSpan: Float, elevChord: CGFloat
    // Fin (rudder): base y, trailing-edge z, height, chord, thickness.
    let finBaseY: Float, finTE_Z: Float, rudderHeight: CGFloat, rudderChord: CGFloat
    // Main wheels: x offset, contact z, top attach y, wheel radius/width.
    let mainX: Float, mainZ: Float, mainTopY: Float
    let mainRadius: CGFloat, mainWidth: CGFloat, mainStrutR: CGFloat
}

func buildPropLive(spec: PropLiveSpec, bodyMat: SCNMaterial, tailMat: SCNMaterial,
                           tire: SCNMaterial, hub: SCNMaterial, strutMat: SCNMaterial) -> PropLive {
    var live = PropLive()

    // Ailerons — outboard trailing edge, one per side, deflect in opposition.
    for s in [Float(-1), Float(1)] {
        let a = hingedSurfaceNode(span: spec.ailSpan, chord: spec.ailChord,
                                  thickness: spec.surfThickness, material: bodyMat)
        let cx = s * (spec.ailInboard + Float(spec.ailSpan) / 2)
        a.position = SCNVector3(cx, spec.wingY, spec.wingTE_Z)
        live.ailerons.append(Surface(node: a, sign: s))   // right (+) goes opposite left
    }
    // Flaps — inboard trailing edge, both deflect the same way (positive = down).
    for s in [Float(-1), Float(1)] {
        let fl = hingedSurfaceNode(span: spec.flapSpan, chord: spec.flapChord,
                                   thickness: spec.surfThickness, material: bodyMat)
        let cx = s * (spec.flapInboard + Float(spec.flapSpan) / 2)
        fl.position = SCNVector3(cx, spec.wingY, spec.wingTE_Z)
        live.flaps.append(Surface(node: fl, sign: 1))
    }
    // Elevator — one slab spanning the stab trailing edge.
    let elev = hingedSurfaceNode(span: CGFloat(spec.stabHalfSpan * 2), chord: spec.elevChord,
                                 thickness: spec.surfThickness, material: bodyMat)
    elev.position = SCNVector3(0, spec.stabY, spec.stabTE_Z)
    live.elevator.append(Surface(node: elev, sign: 1))
    // Rudder — hinged at the fin trailing edge.
    let rud = hingedRudderNode(height: spec.rudderHeight, chord: spec.rudderChord,
                               thickness: spec.surfThickness, material: tailMat)
    rud.position = SCNVector3(0, spec.finBaseY, spec.finTE_Z)
    live.rudder.append(Surface(node: rud, sign: 1))

    // Live main wheels + a short oleo (fixed gear: tiny travel, but touchdown
    // squash still reads). Nose wheel stays in the static fairing.
    for s in [Float(-1), Float(1)] {
        let leg = liveGearLeg(topY: spec.mainTopY, wheelRadius: spec.mainRadius,
                              wheelWidth: spec.mainWidth, strutRadius: spec.mainStrutR,
                              travel: 0.06, tire: tire, hub: hub, strut: strutMat)
        leg.leg.position = SCNVector3(spec.mainX * s, 0, spec.mainZ)
        live.wheels.append((leg.wheel, Float(spec.mainRadius)))
        live.oleos.append((leg.oleo, spec.mainTopY, 0.06))
        live.gearContacts.append(SCNVector3(spec.mainX * s, 0, spec.mainZ))
        // Caller adds leg.leg to body.
        live.legRoots.append(leg.leg)
    }
    return live
}

/// c172 — high strut-braced wing, fixed gear with fairings, single prop.
func buildLark(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 1.18  // fuselage centerline height

    let airframe = AirframeCache.airframe(kind: .c172, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
        let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
        let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)

        let fus = latheNode([(-3.95, 0.10), (-3.88, 0.42), (-3.35, 0.58), (-2.65, 0.68),
                             (-1.85, 0.72), (-0.90, 0.70), (0.10, 0.55), (1.30, 0.36),
                             (2.60, 0.20), (3.70, 0.10), (3.95, 0.02)],
                            material: fuselageMaterial(kind: .c172, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Squared-ish glasshouse cabin.
        let cabin = SCNNode(geometry: SCNBox(width: 1.06, height: 0.5, length: 1.7, chamferRadius: 0.14))
        cabin.geometry?.materials = [canopyGlassMaterial()]
        cabin.position = SCNVector3(0, 1.72, -1.35)
        root.addChildNode(cabin)
        // A14: wraparound rear-window hint — dark glass band aft of the cabin.
        let rearWindow = SCNNode(geometry: SCNBox(width: 0.98, height: 0.26, length: 0.46, chamferRadius: 0.1))
        rearWindow.geometry?.materials = [canopyGlassMaterial()]
        rearWindow.position = SCNVector3(0, 1.70, -0.38)
        root.addChildNode(rearWindow)

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
            // A14: strut meets the wing at ~40% semi-span (x 2.2 of 5.5).
            root.addChildNode(strutNode(from: SCNVector3(0.66 * s, 1.35, -1.05),
                                        to: SCNVector3(2.2 * s, 1.96, -1.15),
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

        // Fixed tricycle gear with wheel fairings. Main STRUTS + fairings stay
        // static in the cache; the main WHEELS are live (spun in update()).
        let fairing: [(z: Float, r: Float)] = [(-0.36, 0.03), (-0.16, 0.17), (0.05, 0.20),
                                               (0.30, 0.12), (0.50, 0.02)]
        for s in [Float(-1), Float(1)] {
            root.addChildNode(strutNode(from: SCNVector3(0.35 * s, 0.95, -0.30),
                                        to: SCNVector3(1.15 * s, 0.36, -0.35),
                                        radius: 0.04, material: bodyMat))
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
    // A14: 2-blade McCauley-style prop, Ø 1.91 m.
    let prop = makePropGroup(at: SCNVector3(0, cy, -3.94), bladeCount: 2, bladeLength: 0.875,
                             spinnerScale: 1.0, discDiameter: 1.91)
    body.addChildNode(prop.group)

    // Live surfaces + main wheels (high wing: TE at wing.z + rootChord).
    let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
    let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
    let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
    let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)
    let strutMat = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.5)
    let live = buildPropLive(spec: PropLiveSpec(
        wingY: 2.0, wingTE_Z: -0.35, wingHalfSpan: 5.5,
        ailChord: 0.34, ailSpan: 1.9, ailInboard: 3.1,
        flapChord: 0.34, flapSpan: 2.2, flapInboard: 0.75,
        surfThickness: 0.08,
        stabY: 1.32, stabTE_Z: 3.9, stabHalfSpan: 1.7, elevChord: 0.32,
        finBaseY: 1.30, finTE_Z: 3.85, rudderHeight: 1.35, rudderChord: 0.34,
        mainX: 1.18, mainZ: -0.35, mainTopY: 0.5,
        mainRadius: 0.24, mainWidth: 0.16, mainStrutR: 0.0),
        bodyMat: bodyMat, tailMat: tailMat, tire: tire, hub: hub, strutMat: strutMat)
    live.install(on: body)

    let shadow = makeContactShadow(span: 11.0, length: 8.0)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-5.5, 2.0, -1.35),
        navRight: SCNVector3(5.5, 2.0, -1.35),
        tail: SCNVector3(0, 1.42, 3.97),
        beacon: SCNVector3(0, 2.80, 3.55),
        landing: SCNVector3(0, 0.93, -3.92)))
    return CraftParts(body: body, propGroup: prop.group, blades: prop.blades,
                      blurDisc: prop.disc, fanGroups: [], heatWash: [],
                      beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      navNodes: kit.navs, scalingHalos: kit.halos, contactShadow: shadow,
                      landingLight: kit.light, landingGlow: kit.glow, gear: [],
                      smokeOffset: SCNVector3(0, 0.26, -0.35),
                      gearContacts: live.gearContacts, wheels: live.wheels, oleos: live.oleos,
                      ailerons: live.ailerons, elevator: live.elevator,
                      rudder: live.rudder, flaps: live.flaps)
}

/// sr22 — sleek low wing, composite-smooth fuselage, raked canopy, fixed gear.
func buildVela(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 1.02

    let airframe = AirframeCache.airframe(kind: .sr22, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
        let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
        let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)

        let fus = latheNode([(-3.95, 0.10), (-3.78, 0.35), (-3.05, 0.55), (-2.10, 0.66),
                             (-1.00, 0.68), (0.20, 0.60), (1.40, 0.40), (2.70, 0.22),
                             (3.80, 0.08)],
                            material: fuselageMaterial(kind: .sr22, livery: livery))
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

        // Fixed gear in sleek pants. Struts + pants static; main wheels live.
        let pants: [(z: Float, r: Float)] = [(-0.42, 0.02), (-0.20, 0.15), (0.05, 0.18),
                                             (0.35, 0.10), (0.55, 0.02)]
        for s in [Float(-1), Float(1)] {
            root.addChildNode(strutNode(from: SCNVector3(0.5 * s, 0.75, -0.45),
                                        to: SCNVector3(1.37 * s, 0.36, -0.5),
                                        radius: 0.035, material: bodyMat))
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

    // Live surfaces + main wheels (low wing: TE at wing.z + rootChord = 1.30).
    let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
    let tailMat = pbrMaterial(pal.tail, roughness: pal.roughness, metalness: pal.metalness)
    let tire = pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.9)
    let hub = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.6)
    let strutMat = pbrMaterial(UIColor(white: 0.7, alpha: 1), roughness: 0.4, metalness: 0.5)
    let live = buildPropLive(spec: PropLiveSpec(
        wingY: 0.72, wingTE_Z: -0.15, wingHalfSpan: 5.85,
        ailChord: 0.30, ailSpan: 1.9, ailInboard: 3.3,
        flapChord: 0.30, flapSpan: 2.1, flapInboard: 0.8,
        surfThickness: 0.08,
        stabY: 1.12, stabTE_Z: 3.82, stabHalfSpan: 1.65, elevChord: 0.28,
        finBaseY: 1.12, finTE_Z: 3.75, rudderHeight: 1.15, rudderChord: 0.30,
        mainX: 1.4, mainZ: -0.5, mainTopY: 0.5,
        mainRadius: 0.25, mainWidth: 0.14, mainStrutR: 0.0),
        bodyMat: bodyMat, tailMat: tailMat, tire: tire, hub: hub, strutMat: strutMat)
    live.install(on: body)

    let shadow = makeContactShadow(span: 11.7, length: 7.9)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-5.8, 0.8, -0.93),
        navRight: SCNVector3(5.8, 0.8, -0.93),
        tail: SCNVector3(0, 1.12, 3.86),
        beacon: SCNVector3(0, 2.36, 3.55),
        landing: SCNVector3(0, 0.72, -3.9)))
    return CraftParts(body: body, propGroup: prop.group, blades: prop.blades,
                      blurDisc: prop.disc, fanGroups: [], heatWash: [],
                      beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      navNodes: kit.navs, scalingHalos: kit.halos, contactShadow: shadow,
                      landingLight: kit.light, landingGlow: kit.glow, gear: [],
                      smokeOffset: SCNVector3(0, 0.28, -0.5),
                      gearContacts: live.gearContacts, wheels: live.wheels, oleos: live.oleos,
                      ailerons: live.ailerons, elevator: live.elevator,
                      rudder: live.rudder, flaps: live.flaps)
}

/// challenger350 — low swept wing, aft twin nacelles, T-tail, retractable gear.
func buildComet(livery: Livery) -> CraftParts {
    let pal = livery.palette
    let cy: Float = 1.95

    let airframe = AirframeCache.airframe(kind: .challenger350, livery: livery) {
        let root = SCNNode()
        let bodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
        let accentMat = pbrMaterial(pal.accent, roughness: 0.25, metalness: 0.7)

        // A16: Challenger 350 proportions — 20.9 m nose-to-tail.
        let fus = latheNode([(-10.40, 0.10), (-10.15, 0.50), (-9.25, 0.85), (-7.70, 1.05),
                             (-5.10, 1.15), (2.20, 1.15), (5.40, 1.02), (7.70, 0.78),
                             (9.50, 0.45), (10.50, 0.12)],
                            segments: 32,
                            material: fuselageMaterial(kind: .challenger350, livery: livery))
        fus.position.y = cy
        root.addChildNode(fus)

        // Raked windscreen cap.
        let screen = SCNNode(geometry: SCNSphere(radius: 0.68))
        (screen.geometry as? SCNSphere)?.segmentCount = 24
        screen.geometry?.materials = [canopyGlassMaterial()]
        screen.scale = SCNVector3(0.78, 0.5, 1.15)
        screen.position = SCNVector3(0, 2.62, -8.05)
        root.addChildNode(screen)

        // D26: 19.9 m planform + 0.55 m canted-winglet reach per side = 21.0 m.
        let wing = wingNode(span: 19.9, rootChord: 3.4, tipChord: 1.0, sweep: 2.6,
                            thickness: 0.24, material: bodyMat)
        wing.position = SCNVector3(0, 1.0, 2.2)
        root.addChildNode(wing)

        // Canted winglets — 1.1 m tall, ~30° outboard cant.
        for s in [Float(-1), Float(1)] {
            let wp = UIBezierPath()
            wp.move(to: CGPoint(x: 0, y: 0))
            wp.addLine(to: CGPoint(x: 0.22, y: 1.02))
            wp.addQuadCurve(to: CGPoint(x: 0.55, y: 1.10), controlPoint: CGPoint(x: 0.34, y: 1.14))
            wp.addQuadCurve(to: CGPoint(x: 1.05, y: 0.0), controlPoint: CGPoint(x: 0.9, y: 0.3))
            wp.close()
            let wl = finNode(path: wp, thickness: 0.05, material: bodyMat)
            let cant = SCNNode()
            cant.position = SCNVector3(9.95 * s, 1.10, 1.75)
            cant.eulerAngles.z = -0.52 * s
            cant.addChildNode(wl)
            root.addChildNode(cant)
        }

        // Aft fuselage-mounted nacelles + pylons.
        let nacMat = pbrMaterial(pal.body, roughness: max(0.12, pal.roughness - 0.06),
                                 metalness: min(1, pal.metalness + 0.15))
        let intakeMat = pbrMaterial(UIColor(white: 0.05, alpha: 1), roughness: 0.4)
        for s in [Float(-1), Float(1)] {
            let nac = latheNode([(-1.75, 0.16), (-1.62, 0.44), (-1.15, 0.56), (-0.20, 0.58),
                                 (0.90, 0.52), (1.60, 0.30), (1.85, 0.12)],
                                segments: 20, material: nacMat)
            nac.position = SCNVector3(1.72 * s, 2.62, 5.9)
            root.addChildNode(nac)
            let intake = SCNNode(geometry: SCNCylinder(radius: 0.42, height: 0.04))
            intake.geometry?.materials = [intakeMat]
            intake.eulerAngles.x = .pi / 2
            intake.position = SCNVector3(1.72 * s, 2.62, 4.18)
            root.addChildNode(intake)
            // D26: near-flat stub pylon rooted at the fuselage shoulder —
            // kills the splayed-fin silhouette.
            let pylon = SCNNode(geometry: SCNBox(width: 0.14, height: 0.55, length: 1.7, chamferRadius: 0.05))
            pylon.geometry?.materials = [bodyMat]
            pylon.eulerAngles.z = 0.25 * s
            pylon.position = SCNVector3(1.35 * s, 2.45, 5.85)
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
        fin.position = SCNVector3(0, 2.45, 9.9)
        root.addChildNode(fin)
        let stab = wingNode(span: 6.4, rootChord: 1.5, tipChord: 0.8, sweep: 0.8,
                            thickness: 0.14, material: bodyMat)
        stab.position = SCNVector3(0, 5.85, 9.55)
        root.addChildNode(stab)
        if livery == .meridianVIP {
            let crest = SCNNode(geometry: SCNBox(width: 0.26, height: 0.62, length: 0.44, chamferRadius: 0.08))
            crest.geometry?.materials = [accentMat]
            crest.position = SCNVector3(0, 4.85, 8.85)
            root.addChildNode(crest)
        }
        return root
    }

    let body = SCNNode()
    body.addChildNode(airframe)

    // Live turbofans + a warm heat-wash behind each nacelle. The nacelle SHELL
    // is baked in the cache; only the spinning fan + blur disc are live here.
    // Nacelle intake face sits near z 4.18, centerline x ±1.72, y 2.62.
    var fanGroups: [FanGroup] = []
    var heatWashes: [SCNNode] = []
    for s in [Float(-1), Float(1)] {
        let fan = makeFanGroup(at: SCNVector3(1.72 * s, 2.62, 4.16), radius: 0.40)
        body.addChildNode(fan.group)
        fanGroups.append(fan.fan)
        // Warm wash just aft of the exhaust (nacelle tail ~ z 7.75).
        let wash = makeHeatWash(at: SCNVector3(1.72 * s, 2.62, 8.1), size: 1.7)
        body.addChildNode(wash)
        heatWashes.append(wash)
    }

    // Live control surfaces (jet).
    let surfBodyMat = pbrMaterial(pal.body, roughness: pal.roughness, metalness: pal.metalness)
    var ailerons: [Surface] = []
    var flaps: [Surface] = []
    // wingNode origin = ROOT TRAILING EDGE (z 2.2); the TE is nearly straight,
    // TE_z(x) ≈ 2.2 + 0.2·|x|/9.95. Hinge each surface ON that trailing edge.
    for s in [Float(-1), Float(1)] {
        // Aileron centered at |x| 6.7 → TE_z ≈ 2.34.
        let a = hingedSurfaceNode(span: 2.6, chord: 0.6, thickness: 0.12, material: surfBodyMat)
        a.position = SCNVector3(s * 6.7, 1.0, 2.34)
        ailerons.append(Surface(node: a, sign: s))
        body.addChildNode(a)
        // Flap centered at |x| 2.6 → TE_z ≈ 2.25.
        let fl = hingedSurfaceNode(span: 3.0, chord: 0.7, thickness: 0.12, material: surfBodyMat)
        fl.position = SCNVector3(s * 2.6, 1.0, 2.25)
        flaps.append(Surface(node: fl, sign: 1))
        body.addChildNode(fl)
    }
    // T-tail elevator: stab (wingNode) root TE is at z 9.55, y 5.85 — hinge the
    // elevator ON that trailing edge so it reads as the stab's moving portion.
    var elevator: [Surface] = []
    let elev = hingedSurfaceNode(span: 5.6, chord: 0.55, thickness: 0.10, material: surfBodyMat)
    elev.position = SCNVector3(0, 5.85, 9.55)
    elevator.append(Surface(node: elev, sign: 1))
    body.addChildNode(elev)
    // finNode extends FORWARD (+x = −Z), so the comet fin's trailing edge sits
    // near z 9.7 — hinge the rudder there, not aft of the whole fin.
    var rudder: [Surface] = []
    let rud = hingedRudderNode(height: 2.9, chord: 0.7, thickness: 0.16, material: surfBodyMat)
    rud.position = SCNVector3(0, 2.55, 9.7)
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
        // Static strut baked in.
        let strut = strutNode(from: SCNVector3(0, 0, 0), to: SCNVector3(0, -strutLen, 0),
                              radius: 0.055, material: strutMat)
        oleo.addChildNode(strut.flattenedClone())
        var ws: [SCNNode] = []
        let xs: [Float] = twin ? [-0.13, 0.13] : [0]
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

    let nose = gearLeg(pivotAt: SCNVector3(0, 1.16, -7.4), strutLen: 0.86,
                       wheelRadius: 0.30, wheelWidth: 0.11, twin: true, oleoTravel: 0.05)
    body.addChildNode(nose.pivot)
    for w in nose.wheels { wheels.append((w, 0.30)) }

    var gear: [(node: SCNNode, foldedEuler: SCNVector3)] =
        [(nose.pivot, SCNVector3(1.7, 0, 0))]  // folds forward into the nose
    var gearContacts: [SCNVector3] = []
    for s in [Float(-1), Float(1)] {
        let main = gearLeg(pivotAt: SCNVector3(1.9 * s, 0.95, 1.4), strutLen: 0.53,
                           wheelRadius: 0.42, wheelWidth: 0.3, twin: false, oleoTravel: 0.10)
        body.addChildNode(main.pivot)
        gear.append((main.pivot, SCNVector3(0, 0, 1.85 * -s)))  // mains fold inboard
        for w in main.wheels { wheels.append((w, 0.42)) }
        oleos.append((main.oleo, 0, 0.10))
        // Contact patch at ground level (pivot y 0.95 − strut 0.53 − radius 0.42 ≈ 0).
        gearContacts.append(SCNVector3(1.9 * s, 0, 1.4))
    }

    let shadow = makeContactShadow(span: 21.0, length: 20.9)
    body.addChildNode(shadow)
    let kit = makeLightKit(on: body, spec: LightSpec(
        navLeft: SCNVector3(-9.9, 1.12, 1.8),
        navRight: SCNVector3(9.9, 1.12, 1.8),
        tail: SCNVector3(0, 2.30, 10.55),
        beacon: SCNVector3(0, 3.14, -1.0),
        landing: SCNVector3(0, 1.42, -10.2)))
    return CraftParts(body: body, propGroup: nil, blades: nil, blurDisc: nil,
                      fanGroups: fanGroups, heatWash: heatWashes,
                      beaconNodes: kit.beacons, strobeNodes: kit.strobes,
                      navNodes: kit.navs, scalingHalos: kit.halos, contactShadow: shadow,
                      landingLight: kit.light, landingGlow: kit.glow, gear: gear,
                      smokeOffset: SCNVector3(0, 0.5, 1.4),
                      gearContacts: gearContacts, wheels: wheels, oleos: oleos,
                      ailerons: ailerons, elevator: elevator, rudder: rudder, flaps: flaps)
}

// MARK: - Live entity

final class CraftEntity: AircraftEntity {
    let node = SCNNode()
    private let parts: CraftParts
    private var time: Double
    private var propRate: Double = 0
    private var fanRate: Double = 0
    private var gearFold: Double = 0
    private var lastPhase: FlightPhase?
    private let bobPhase: Double

    // Light critically-damped attitude followers (radians). They snap on the
    // first update and then ease toward the sim target with a fast time constant
    // — just enough to absorb residual 10 Hz step-pops without visible lag.
    private var visPitch: Float = 0
    private var visBank: Float = 0
    private var visHeading: Float = 0
    private var attitudeInit = false

    // Ground yaw-rate tracker (for the rudder kick) — smoothed heading delta.
    private var lastHeading: Float = 0
    private var yawRate: Float = 0

    // Eased control-surface + oleo state.
    private var flapPos: Float = 0        // 0 cruise → ~0.5 rad extended
    private var oleoComp: Float = 0       // 0 extended → 1 fully compressed
    private var touchdownSquash: Float = 0 // brief impulse, relaxes over ~0.4 s

    private static var instanceCounter = 0

    /// PLACEHOLDER scale: uniformly resize a rigged build so a stand-in reads at
    /// the real type's size. `ref` is the donor build's real wingspan (m); the
    /// factor is target wingspan / ref. Applied to the body root, so the whole
    /// rig (prop/gear/surfaces/lights/shadow) scales coherently.
    private static func scale(_ body: SCNNode, _ kind: AircraftKind, ref: Double) {
        let f = Float(kind.spec.wingspanM / ref)
        body.scale = SCNVector3(f, f, f)
    }

    init(kind: AircraftKind, livery: Livery) {
        // Three rigged builds back the whole fleet. Reference wingspans for the
        // placeholder scale: Lark=c172 11.0 m, Vela=sr22 11.7 m, Comet=cl35 21.0 m.
        switch kind {
        // --- REAL (dedicated rigged build) ---
        case .c172:          parts = buildLark(livery: livery)
        case .sr22:          parts = buildVela(livery: livery)
        case .challenger350: parts = buildComet(livery: livery)

        // --- PLACEHOLDER — real model pending ---
        // High-wing singles / utility → Lark (scaled by wingspan / 11.0).
        case .c182:      parts = buildLark(livery: livery); Self.scale(parts.body, kind, ref: 11.0)  // PLACEHOLDER — real model pending
        case .caravan:   parts = buildLark(livery: livery); Self.scale(parts.body, kind, ref: 11.0)  // PLACEHOLDER — real model pending
        case .twinotter: parts = buildLark(livery: livery); Self.scale(parts.body, kind, ref: 11.0)  // PLACEHOLDER — real model pending
        // Low-wing / twins / tailwheel → Vela (scaled by wingspan / 11.7).
        case .pa28:       parts = buildVela(livery: livery); Self.scale(parts.body, kind, ref: 11.7)  // PLACEHOLDER — real model pending
        case .baron58:    parts = buildVela(livery: livery); Self.scale(parts.body, kind, ref: 11.7)  // PLACEHOLDER — real model pending
        case .kingair350: parts = buildVela(livery: livery); Self.scale(parts.body, kind, ref: 11.7)  // PLACEHOLDER — real model pending
        case .dc3:        parts = buildVela(livery: livery); Self.scale(parts.body, kind, ref: 11.7)  // PLACEHOLDER — real model pending
        // All jets → Comet (scaled by wingspan / 21.0).
        case .phenom300:  parts = buildComet(livery: livery); Self.scale(parts.body, kind, ref: 21.0) // PLACEHOLDER — real model pending
        case .e175:       parts = buildComet(livery: livery); Self.scale(parts.body, kind, ref: 21.0) // PLACEHOLDER — real model pending
        case .boeing737:  parts = buildComet(livery: livery); Self.scale(parts.body, kind, ref: 21.0) // PLACEHOLDER — real model pending
        case .airbus320:  parts = buildComet(livery: livery); Self.scale(parts.body, kind, ref: 21.0) // PLACEHOLDER — real model pending
        case .boeing777:  parts = buildComet(livery: livery); Self.scale(parts.body, kind, ref: 21.0) // PLACEHOLDER — real model pending
        case .airbus380:  parts = buildComet(livery: livery); Self.scale(parts.body, kind, ref: 21.0) // PLACEHOLDER — real model pending
        }
        node.addChildNode(parts.body)
        CraftEntity.instanceCounter += 1
        let seed = Double(CraftEntity.instanceCounter)
        bobPhase = seed * 2.399   // golden-angle spread so formations don't sync
        time = seed * 1.37
    }

    func update(_ state: AircraftRenderState, dt: TimeInterval) {
        time += dt
        let phase = state.phase
        let dtf = Float(dt)

        // --- P1: crab yaw + light attitude follower ------------------------
        // The fuselage points into wind (heading + crab) while the deterministic
        // ground track stays on `heading`. A fast critically-damped follower on
        // pitch/bank/heading absorbs residual 10 Hz step-pops with no visible
        // steady-state lag.
        let tgtPitch = Float(state.pitch)
        let tgtBank = Float(state.bank)
        let tgtHeading = Float(state.heading)
        let crab = Float(state.crab)
        if !attitudeInit {
            visPitch = tgtPitch; visBank = tgtBank; visHeading = tgtHeading
            lastHeading = tgtHeading
            attitudeInit = true
        } else {
            let k = min(1, dtf * 10)   // fast: only smooths the step edges
            visPitch += (tgtPitch - visPitch) * k
            visBank += (tgtBank - visBank) * k
            // Shortest-arc ease for heading so wrap-around never spins.
            visHeading += Float(angleDelta(from: Double(visHeading), to: Double(tgtHeading))) * k
        }

        // Root transform: the integrator owns position; we own attitude. Add the
        // airborne bob as a WORLD-UP offset on the root so it stays vertical even
        // in a hard bank (P6) — never on body-local Y, which tilts with roll.
        var bob: Float = 0
        if phase.isAirborne {
            let amp = 0.045 * min(1.0, Float(state.speed) / 45.0)
            bob = amp * Float(sin(time * 5.3 + bobPhase))
        }
        node.position = SCNVector3(Float(state.position.x),
                                   Float(state.position.y) + bob,
                                   Float(state.position.z))
        // eulerAngles Y is negated (heading is clockwise-positive); the fuselage
        // yaws to visHeading + crab so the nose leads the ground track in wind.
        node.eulerAngles = SCNVector3(visPitch, -(visHeading + crab), -visBank)
        parts.body.position.y = 0   // body stays put; bob lives on the root

        // Ground yaw-rate (smoothed) for the rudder kick.
        let rawYaw = Float(angleDelta(from: Double(lastHeading), to: Double(tgtHeading))) / max(dtf, 0.0001)
        lastHeading = tgtHeading
        yawRate += (rawYaw - yawRate) * min(1, dtf * 6)

        // Throttle drives blur intensity; fall back to speed if the sim never
        // set throttle (throttle == 0) so props still blur on a fast rollout.
        let throttle = state.throttle > 0
            ? Float(state.throttle)
            : min(1, Float(state.speed) / 60)

        // --- P2/P7: propeller ---------------------------------------------
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
            // Prefer throttle for the blur read; keep the rate floor so an idling
            // prop still shows a faint disc.
            let byThrottle = 0.55 * Double(throttle)
            let byRate = 0.55 * max(0, min(1, (propRate - 22) / 28))
            parts.blurDisc?.opacity = CGFloat(max(byThrottle, byRate))
        }

        // --- P2/P7: turbofans (comet) — always read blurred ----------------
        if !parts.fanGroups.isEmpty {
            let alive = !(phase == .parkedArrival || phase == .removed)
            // Fans idle-spin whenever alive, spool hard with throttle.
            let target: Double = alive ? Double(160 + 700 * throttle) : 0
            fanRate += (target - fanRate) * min(1, dt * 1.2)
            for fan in parts.fanGroups {
                fan.spinner.eulerAngles.z -= Float(fanRate * dt)
                // Blur disc: faint at idle, denser under power. Jets never show a
                // crisp fan, so keep a floor while alive.
                let discOpacity = alive ? CGFloat(0.35 + 0.45 * Double(throttle)) : 0
                fan.disc.opacity += (discOpacity - fan.disc.opacity) * CGFloat(min(1, dt * 6))
            }
            // Warm heat-wash: gated on throttle, strongest on takeoff/climb.
            let hot = (phase == .takeoffRoll || phase == .climbingOut || phase == .goingAround)
            let washPeak: CGFloat = hot ? 0.7 : 0.35
            let washTarget = CGFloat(max(0, Double(throttle) - 0.35) / 0.65) * washPeak
            for w in parts.heatWash {
                w.opacity += (washTarget - w.opacity) * CGFloat(min(1, dt * 4))
            }
        }

        // Nav lights + beacon — on whenever the aircraft is alive; parked
        // statics never reach update() and stay dark.
        let shutDown = phase == .parkedArrival || phase == .removed
        for n in parts.navNodes { n.opacity = shutDown ? 0 : 1 }

        // Beacon — soft red pulse, ~1.2 s cycle.
        let pulse = pow(max(0, sin(fmod(time, 1.2) / 1.2 * .pi)), 3.0)
        for n in parts.beaconNodes { n.opacity = shutDown ? 0 : CGFloat(0.15 + 0.85 * pulse) }

        // Strobes — brief white double-flash, ~1.8 s cycle, off when parked.
        let parked = shutDown || phase == .startingUp
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

        // D25: nav/beacon/strobe halos get the same distance treatment so
        // traffic still sparkles at pattern range.
        let navHaloScale = max(1, min(8, dist / 250))
        for h in parts.scalingHalos {
            h.scale = SCNVector3(navHaloScale, navHaloScale, navHaloScale)
        }

        // D24: contact shadow — planted on the ground, gone a couple of
        // seconds after liftoff, back through the flare.
        let grounded = !phase.isAirborne || phase == .flare
        let shadowTarget: CGFloat = grounded ? 0.42 : 0
        if lastPhase == nil {
            parts.contactShadow.opacity = shadowTarget  // snap on spawn
        } else {
            let shadowStep = CGFloat(dt / 2.0) * 0.42
            let currentShadow = parts.contactShadow.opacity
            parts.contactShadow.opacity = currentShadow
                + max(-shadowStep, min(shadowStep, shadowTarget - currentShadow))
        }

        // --- P3: control surfaces -----------------------------------------
        // All eased with min(1, dt*6); subtle deflections that read at pattern
        // range without ever looking cartoonish.
        let surfEase = min(1, dtf * 6)
        // Ailerons: roll into the bank — deflect opposite ±bank * k.
        let ailTarget = visBank * 0.5
        for a in parts.ailerons {
            let want = a.sign * ailTarget
            a.node.eulerAngles.x += (want - a.node.eulerAngles.x) * surfEase
        }
        // Elevator: trailing-edge UP in the flare / with nose-up pitch. On this
        // hinge, +rotation.x pushes the TE down, so nose-up ⇒ NEGATIVE.
        let elevTarget: Float = -((phase == .flare ? 0.28 : 0) + max(0, visPitch) * 0.6)
        for e in parts.elevator {
            e.node.eulerAngles.x += (elevTarget - e.node.eulerAngles.x) * surfEase
        }
        // Rudder: a small kick opposing the ground yaw-rate (only on the ground,
        // where the tiller/rudder actually swings the nose).
        let onGround = !phase.isAirborne || phase == .flare
        let rudTarget: Float = onGround ? max(-0.35, min(0.35, -yawRate * 0.5)) : 0
        for r in parts.rudder {
            r.node.eulerAngles.y += (rudTarget - r.node.eulerAngles.y) * surfEase
        }
        // Flaps: ease to a phase target. 0 cruise → ~0.5 rad on short final/flare;
        // retracted on climb-out.
        let flapWant: Float
        switch phase {
        case .shortFinal, .flare: flapWant = 0.5
        case .base, .finalApproach: flapWant = 0.28
        default: flapWant = 0   // cruise / climb-out / ground: eased back to clean
        }
        flapPos += (flapWant - flapPos) * surfEase
        for f in parts.flaps {
            // Flaps hinge trailing-edge DOWN → +rotation.x on this hinge.
            f.node.eulerAngles.x = flapPos
        }

        // --- P4: live wheels + oleo ---------------------------------------
        // Spin each wheel about its own axle from ground speed / its radius (so
        // small nose wheels spin faster than big mains); compress the oleo when
        // grounded; add a brief touchdown squash impulse that relaxes.
        let rolling = onGround && state.speed > 0.2 &&
            phase != .parkedArrival && phase != .removed
        if rolling {
            for w in parts.wheels {
                let r = max(0.05, w.radius)
                var a = w.node.eulerAngles.x - Float(state.speed) / r * dtf
                a = a.truncatingRemainder(dividingBy: Float.pi * 2)
                w.node.eulerAngles.x = a
            }
        }

        // Oleo static compression: settled when grounded, extended in the air.
        let compTarget: Float = onGround ? 1 : 0
        oleoComp += (compTarget - oleoComp) * min(1, dtf * 4)
        // Touchdown squash impulse relaxes over ~0.4 s.
        if touchdownSquash > 0 {
            touchdownSquash = max(0, touchdownSquash - dtf / 0.4)
        }
        for o in parts.oleos {
            // Compressing the oleo telescopes the wheel UP toward the airframe
            // (the airframe can't drop — the sim owns the root Y). Static settle
            // + a brief touchdown squash on top.
            let comp = (o.travel * 0.5 * oleoComp) + (o.travel * touchdownSquash)
            o.node.position.y = o.restY + comp
        }

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

        // --- P5: robust touchdown puff -------------------------------------
        // Fire on ANY airborne→rollout transition (not just flare→rollout) at a
        // real speed, guarding the first-frame spawn (lastPhase == nil).
        if let lp = lastPhase, lp.isAirborne, phase == .rollout, state.speed > 10 {
            touchdownSquash = 1
            for contact in parts.gearContacts { emitTireSmoke(at: contact) }
        }
        lastPhase = phase
    }

    /// A single warm, low-alpha soft-puff burst at a true main-gear contact.
    func emitTireSmoke(at contact: SCNVector3) {
        let ps = SCNParticleSystem()
        ps.loops = false
        ps.emissionDuration = 0.22
        ps.birthRate = 220
        ps.particleLifeSpan = 0.8
        ps.particleLifeSpanVariation = 0.25
        ps.particleVelocity = 2.4
        ps.particleVelocityVariation = 1.6
        ps.emittingDirection = SCNVector3(0, 1, 0.6)
        ps.spreadingAngle = 55
        ps.particleSize = 0.5
        ps.particleSizeVariation = 0.3
        ps.particleImage = ArtTextures.softPuff()
        // Warm golden-hour dust rather than cold gray smoke.
        ps.particleColor = UIColor(red: 0.86, green: 0.78, blue: 0.66, alpha: 0.38)
        ps.blendMode = .alpha
        let fade = CAKeyframeAnimation()
        fade.values = [0.5, 0.32, 0.0]
        fade.keyTimes = [0, 0.4, 1]
        fade.duration = 1
        ps.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
        let grow = CAKeyframeAnimation()
        grow.values = [0.35, 1.1]
        grow.keyTimes = [0, 1]
        grow.duration = 1
        ps.propertyControllers?[.size] = SCNParticlePropertyController(animation: grow)

        let n = SCNNode()
        // Contact is a body-space offset at the tire patch; lift a touch so the
        // puff blooms from just above the ground.
        n.position = SCNVector3(contact.x, contact.y + 0.15, contact.z)
        n.addParticleSystem(ps)
        parts.body.addChildNode(n)
        n.runAction(.sequence([.wait(duration: 1.8), .removeFromParentNode()]))
    }
}
