import Foundation
import SceneKit
import UIKit

// =============================================================================
// The Catalina tower cab — static geometry surrounding the camera eye.
// Origin = the eye; panning the camera creates the parallax. Everything is
// categoryBitMask 2 so scene taps pass through to aircraft (category 1),
// and nothing in here casts shadows.
//
// Layout: radius ≈ 2.5 m, glass sloped outward 15°, 9 mullion bays, ceiling
// overhang above, wrap-around console below sightline (top ≥ 0.45 m under
// eye level), warm props: coffee mug (steam), headset, clipboard, CRT scope.
// =============================================================================

private let kBays = 9
private let kGlassRadius: Float = 2.5
private let kGlassTilt: Float = -0.262   // ~15°, top leans outward

/// D1: one lathed truncated-cone glass band (sill r 2.5 @ y −0.72 → head
/// r ~3.02 @ y +1.22, matching the 15° top-out rake). A single surface can't
/// double-blend at bay seams, which is what painted the two sky shafts.
private func glassBandNode(material: SCNMaterial) -> SCNNode {
    let segments = 36
    let yBot: Float = -0.72, yTop: Float = 1.22
    let rBot: Float = kGlassRadius
    let rTop: Float = rBot + (yTop - yBot) * tan(0.262)   // ≈ 3.02
    var positions: [SCNVector3] = []
    var normals: [SCNVector3] = []
    var uvs: [CGPoint] = []
    let slope = (rTop - rBot) / (yTop - yBot)
    let k = 1 / sqrt(1 + slope * slope)
    for (y, r, v) in [(yBot, rBot, CGFloat(0)), (yTop, rTop, CGFloat(1))] {
        for j in 0...segments {
            let t = Float(j) / Float(segments) * 2 * .pi
            let c = cos(t), s = sin(t)
            positions.append(SCNVector3(r * c, y, r * s))
            normals.append(SCNVector3(-c * k, slope * k, -s * k))  // faces the eye
            uvs.append(CGPoint(x: CGFloat(j) / CGFloat(segments), y: v))
        }
    }
    var indices: [UInt32] = []
    let row = UInt32(segments + 1)
    for j in 0..<UInt32(segments) {
        indices.append(contentsOf: [j, j + row, j + 1, j + 1, j + row, j + row + 1])
    }
    let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: positions),
                                    SCNGeometrySource(normals: normals),
                                    SCNGeometrySource(textureCoordinates: uvs)],
                          elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    geo.materials = [material]
    return SCNNode(geometry: geo)
}

/// Flat annulus with planar UVs (u,v map straight onto x,z) so a top-down
/// painted texture lands undistorted on the console work surface.
private func flatRingNode(inner: Float, outer: Float, segments: Int,
                          material: SCNMaterial) -> SCNNode {
    var positions: [SCNVector3] = []
    var normals: [SCNVector3] = []
    var uvs: [CGPoint] = []
    for r in [inner, outer] {
        for j in 0...segments {
            let t = Float(j) / Float(segments) * 2 * .pi
            let x = r * cos(t), z = r * sin(t)
            positions.append(SCNVector3(x, 0, z))
            normals.append(SCNVector3(0, 1, 0))
            uvs.append(CGPoint(x: CGFloat(x / outer + 1) / 2, y: CGFloat(z / outer + 1) / 2))
        }
    }
    var indices: [UInt32] = []
    let row = UInt32(segments + 1)
    for j in 0..<UInt32(segments) {
        indices.append(contentsOf: [j, j + 1, j + row, j + 1, j + row + 1, j + row])
    }
    let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: positions),
                                    SCNGeometrySource(normals: normals),
                                    SCNGeometrySource(textureCoordinates: uvs)],
                          elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    geo.materials = [material]
    return SCNNode(geometry: geo)
}

func buildCabInteriorNode() -> SCNNode {
    let root = SCNNode()
    root.name = "cabInterior"
    let staticRoot = SCNNode()

    // Palette — warm charcoal-green enamel and dark consoles.
    let mullionMat = pbrMaterial(UIColor(red: 0.12, green: 0.15, blue: 0.13, alpha: 1), roughness: 0.32)
    let frameMat = pbrMaterial(UIColor(red: 0.10, green: 0.12, blue: 0.11, alpha: 1), roughness: 0.45)
    let consoleMat = pbrMaterial(UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1), roughness: 0.60)
    let panelMat = pbrMaterial(UIColor(red: 0.13, green: 0.13, blue: 0.145, alpha: 1), roughness: 0.55)
    // A17: FAA cabs paint the ceiling matte black to kill glass reflections.
    let ceilMat = pbrMaterial(UIColor(white: 0.04, alpha: 1), roughness: 0.95)
    let floorMat = pbrMaterial(UIColor(red: 0.15, green: 0.14, blue: 0.13, alpha: 1), roughness: 0.85)
    let steelMat = pbrMaterial(UIColor(white: 0.35, alpha: 1), roughness: 0.5, metalness: 0.6)

    func bay(_ angle: Float) -> SCNNode {
        let n = SCNNode()
        n.eulerAngles.y = angle
        return n
    }
    let step = 2 * Float.pi / Float(kBays)

    // --- Glass band (NOT flattened: it needs renderingOrder + own material)
    let glassMat = SCNMaterial()
    glassMat.lightingModel = .blinn
    glassMat.diffuse.contents = UIColor(red: 0.04, green: 0.07, blue: 0.08, alpha: 0.055)
    glassMat.specular.contents = UIColor(white: 0.3, alpha: 1)
    glassMat.shininess = 60
    // No reflective map: spherical mapping paints view-locked bands on the
    // tilted panes. Presence comes from the faint diffuse tint + specular.
    glassMat.isDoubleSided = true
    glassMat.writesToDepthBuffer = false
    glassMat.blendMode = .alpha

    let glassBand = glassBandNode(material: glassMat)
    glassBand.renderingOrder = 950
    root.addChildNode(glassBand)

    // --- Mullions (slim, ~7 cm) at bay boundaries
    let mullionGeo = SCNBox(width: 0.072, height: 2.08, length: 0.11, chamferRadius: 0.015)
    mullionGeo.materials = [mullionMat]
    for i in 0..<kBays {
        let holder = bay(step * (Float(i) + 0.5))
        let m = SCNNode(geometry: mullionGeo)
        m.position = SCNVector3(0, 0.25, -(kGlassRadius + 0.1))
        m.eulerAngles.x = kGlassTilt
        holder.addChildNode(m)
        staticRoot.addChildNode(holder)
    }

    // --- Frame rings: sill below the glass, beam above it
    let sill = SCNNode(geometry: SCNTube(innerRadius: 2.12, outerRadius: 2.42, height: 0.08))
    sill.geometry?.materials = [frameMat]
    sill.position.y = -0.72
    staticRoot.addChildNode(sill)
    let beam = SCNNode(geometry: SCNTube(innerRadius: 2.72, outerRadius: 2.94, height: 0.14))
    beam.geometry?.materials = [mullionMat]
    beam.position.y = 1.24
    staticRoot.addChildNode(beam)
    let parapet = SCNNode(geometry: SCNTube(innerRadius: 2.32, outerRadius: 2.42, height: 0.95))
    parapet.geometry?.materials = [frameMat]
    parapet.position.y = -1.2
    staticRoot.addChildNode(parapet)

    // --- Ceiling: disc + soft overhang ring so the top of frame vignettes
    let ceiling = SCNNode(geometry: SCNCylinder(radius: 2.96, height: 0.07))
    ceiling.geometry?.materials = [ceilMat]
    ceiling.position.y = 1.44
    staticRoot.addChildNode(ceiling)
    let overhang = SCNNode(geometry: SCNTube(innerRadius: 2.02, outerRadius: 2.96, height: 0.18))
    overhang.geometry?.materials = [ceilMat]
    overhang.position.y = 1.31
    staticRoot.addChildNode(overhang)

    // --- Wrap-around console, top surface 0.5 m below the eye
    // D28: inner radius 1.38 so the lip overhangs (and hides) the strip ring.
    let consoleTop = SCNNode(geometry: SCNTube(innerRadius: 1.38, outerRadius: 2.25, height: 0.055))
    consoleTop.geometry?.materials = [consoleMat]
    consoleTop.position.y = -0.53
    staticRoot.addChildNode(consoleTop)
    // D29: painted work surface — panel seams, screws, taped charts, coffee ring.
    let deskMat = SCNMaterial()
    deskMat.lightingModel = .physicallyBased
    deskMat.diffuse.contents = ArtTextures.consoleTopSurface()
    deskMat.roughness.contents = 0.60
    deskMat.metalness.contents = 0.0
    let desk = flatRingNode(inner: 1.38, outer: 2.25, segments: 48, material: deskMat)
    desk.position.y = -0.501
    staticRoot.addChildNode(desk)
    let skirt = SCNNode(geometry: SCNTube(innerRadius: 2.2, outerRadius: 2.27, height: 0.55))
    skirt.geometry?.materials = [panelMat]
    skirt.position.y = -0.82
    staticRoot.addChildNode(skirt)
    let panelGeo = SCNBox(width: 0.87, height: 0.62, length: 0.05, chamferRadius: 0.015)
    panelGeo.materials = [panelMat]
    for i in 0..<10 {
        let holder = bay(2 * .pi / 10 * Float(i))
        let panel = SCNNode(geometry: panelGeo)
        panel.position = SCNVector3(0, -0.85, -1.36)
        panel.eulerAngles.x = -0.35
        holder.addChildNode(panel)
        staticRoot.addChildNode(holder)
    }

    // Warm amber backlit strip tucked under the console lip.
    let stripMat = SCNMaterial()
    stripMat.lightingModel = .constant
    stripMat.diffuse.contents = UIColor(red: 0.55, green: 0.30, blue: 0.10, alpha: 1)
    stripMat.emission.contents = UIColor(red: 0.30, green: 0.18, blue: 0.08, alpha: 1)  // D28
    let strip = SCNNode(geometry: SCNTube(innerRadius: 1.42, outerRadius: 1.455, height: 0.024))
    strip.geometry?.materials = [stripMat]
    strip.position.y = -0.575
    staticRoot.addChildNode(strip)

    // --- Floor + catwalk & railing outside the glass, all below sightline
    let floor = SCNNode(geometry: SCNCylinder(radius: 2.55, height: 0.06))
    floor.geometry?.materials = [floorMat]
    floor.position.y = -1.65
    staticRoot.addChildNode(floor)
    let catwalk = SCNNode(geometry: SCNTube(innerRadius: 2.45, outerRadius: 3.3, height: 0.06))
    catwalk.geometry?.materials = [pbrMaterial(UIColor(white: 0.2, alpha: 1), roughness: 0.8)]
    catwalk.position.y = -1.7
    staticRoot.addChildNode(catwalk)
    let rail = SCNNode(geometry: SCNTorus(ringRadius: 3.18, pipeRadius: 0.022))
    rail.geometry?.materials = [mullionMat]
    rail.position.y = -0.52
    staticRoot.addChildNode(rail)
    let midRail = SCNNode(geometry: SCNTorus(ringRadius: 3.18, pipeRadius: 0.014))
    midRail.geometry?.materials = [mullionMat]
    midRail.position.y = -1.05
    staticRoot.addChildNode(midRail)
    let postGeo = SCNCylinder(radius: 0.016, height: 1.18)
    postGeo.materials = [mullionMat]
    for i in 0..<kBays {
        let holder = bay(step * (Float(i) + 0.5))
        let post = SCNNode(geometry: postGeo)
        post.position = SCNVector3(0, -1.11, -3.18)
        holder.addChildNode(post)
        staticRoot.addChildNode(holder)
    }

    // --- Props on the console -------------------------------------------------

    // Clipboard, slightly askew (static). D30: bayed into the default frame corner.
    do {
        let holder = bay(-0.30)
        let group = SCNNode()
        group.position = SCNVector3(0, -0.5, -1.72)
        group.eulerAngles.y = 0.3
        let board = SCNNode(geometry: SCNBox(width: 0.24, height: 0.007, length: 0.33, chamferRadius: 0.004))
        board.geometry?.materials = [pbrMaterial(UIColor(red: 0.42, green: 0.30, blue: 0.19, alpha: 1), roughness: 0.7)]
        group.addChildNode(board)
        let paperMat = SCNMaterial()
        paperMat.lightingModel = .physicallyBased
        paperMat.diffuse.contents = ArtTextures.paperSheet()
        paperMat.roughness.contents = 0.9
        let paper = SCNNode(geometry: SCNBox(width: 0.215, height: 0.003, length: 0.30, chamferRadius: 0))
        paper.geometry?.materials = [paperMat]
        paper.position.y = 0.005
        group.addChildNode(paper)
        let clip = SCNNode(geometry: SCNBox(width: 0.055, height: 0.014, length: 0.03, chamferRadius: 0.006))
        clip.geometry?.materials = [steelMat]
        clip.position = SCNVector3(0, 0.008, -0.145)
        group.addChildNode(clip)
        holder.addChildNode(group)
        staticRoot.addChildNode(holder)
    }

    // Headset resting console-right, with a coiled-cable hint (static).
    // D30: bayed into the default frame corner opposite the mug.
    do {
        let holder = bay(-0.85)
        let group = SCNNode()
        group.position = SCNVector3(0, -0.49, -1.66)
        let padMat = pbrMaterial(UIColor(white: 0.12, alpha: 1), roughness: 0.75)
        let band = SCNNode(geometry: SCNTorus(ringRadius: 0.085, pipeRadius: 0.011))
        band.geometry?.materials = [padMat]
        band.eulerAngles = SCNVector3(1.25, 0.4, 0.15)
        group.addChildNode(band)
        for s in [Float(-1), Float(1)] {
            let cup = SCNNode(geometry: SCNSphere(radius: 0.036))
            (cup.geometry as? SCNSphere)?.segmentCount = 12
            cup.geometry?.materials = [padMat]
            cup.scale = SCNVector3(1, 0.65, 1)
            cup.position = SCNVector3(0.078 * s, -0.012, 0.025 * s)
            group.addChildNode(cup)
        }
        for i in 0..<3 {
            let loop = SCNNode(geometry: SCNTorus(ringRadius: 0.021, pipeRadius: 0.0045))
            loop.geometry?.materials = [padMat]
            loop.position = SCNVector3(0.12 + Float(i) * 0.035, -0.028, 0.05 + Float(i) * 0.012)
            loop.eulerAngles = SCNVector3(0.2, Float(i) * 0.5, 0.1)
            group.addChildNode(loop)
        }
        holder.addChildNode(group)
        staticRoot.addChildNode(holder)
    }

    // A17: wind/altimeter readout — dark panel, two amber 7-seg number groups.
    do {
        let holder = bay(0.40)
        let panel = SCNNode(geometry: SCNBox(width: 0.30, height: 0.11, length: 0.035, chamferRadius: 0.008))
        panel.geometry?.materials = [pbrMaterial(UIColor(white: 0.06, alpha: 1), roughness: 0.5)]
        panel.position = SCNVector3(0, -0.61, -1.58)
        panel.eulerAngles.x = 0.5
        let faceMat = SCNMaterial()
        faceMat.lightingModel = .constant
        faceMat.diffuse.contents = UIColor(white: 0.01, alpha: 1)
        faceMat.emission.contents = ArtTextures.windAltReadout()
        faceMat.emission.intensity = 0.7
        let face = SCNNode(geometry: SCNPlane(width: 0.27, height: 0.085))
        face.geometry?.materials = [faceMat]
        face.position = SCNVector3(0, 0, 0.019)
        panel.addChildNode(face)
        holder.addChildNode(panel)
        staticRoot.addChildNode(holder)
    }

    // A17: light gun on its hook mount — grey cone-nosed cylinder, nose down.
    do {
        let holder = bay(0.72)
        let group = SCNNode()
        group.position = SCNVector3(0, -0.50, -1.86)
        let grey = pbrMaterial(UIColor(white: 0.42, alpha: 1), roughness: 0.5, metalness: 0.3)
        let post = SCNNode(geometry: SCNCylinder(radius: 0.012, height: 0.30))
        post.geometry?.materials = [steelMat]
        post.position.y = 0.15
        group.addChildNode(post)
        let hook = SCNNode(geometry: SCNTorus(ringRadius: 0.022, pipeRadius: 0.005))
        hook.geometry?.materials = [steelMat]
        hook.eulerAngles.z = .pi / 2
        hook.position = SCNVector3(0.032, 0.29, 0)
        group.addChildNode(hook)
        let gun = SCNNode()
        gun.position = SCNVector3(0.055, 0.16, 0)
        gun.eulerAngles.z = 0.12   // hangs a touch off plumb
        let bodyCyl = SCNNode(geometry: SCNCylinder(radius: 0.034, height: 0.17))
        bodyCyl.geometry?.materials = [grey]
        gun.addChildNode(bodyCyl)
        let nose = SCNNode(geometry: SCNCone(topRadius: 0.034, bottomRadius: 0.012, height: 0.085))
        nose.geometry?.materials = [grey]
        nose.position.y = -0.127
        gun.addChildNode(nose)
        let grip = SCNNode(geometry: SCNBox(width: 0.02, height: 0.07, length: 0.035, chamferRadius: 0.006))
        grip.geometry?.materials = [pbrMaterial(UIColor(white: 0.14, alpha: 1), roughness: 0.7)]
        grip.position = SCNVector3(0, 0.055, 0.045)
        grip.eulerAngles.x = -0.35
        gun.addChildNode(grip)
        group.addChildNode(gun)
        holder.addChildNode(group)
        staticRoot.addChildNode(holder)
    }

    // A17: binoculars resting on the console.
    do {
        let holder = bay(1.05)
        let group = SCNNode()
        group.position = SCNVector3(0, -0.475, -1.70)
        group.eulerAngles = SCNVector3(1.35, 0.5, 0)   // lying down, slightly askew
        let shell = pbrMaterial(UIColor(white: 0.10, alpha: 1), roughness: 0.65)
        for s in [Float(-1), Float(1)] {
            let barrel = SCNNode(geometry: SCNCylinder(radius: 0.026, height: 0.13))
            barrel.geometry?.materials = [shell]
            barrel.position = SCNVector3(0.037 * s, 0, 0)
            group.addChildNode(barrel)
            let objective = SCNNode(geometry: SCNCylinder(radius: 0.030, height: 0.035))
            objective.geometry?.materials = [shell]
            objective.position = SCNVector3(0.037 * s, -0.055, 0)
            group.addChildNode(objective)
        }
        let bridge = SCNNode(geometry: SCNBox(width: 0.05, height: 0.05, length: 0.024, chamferRadius: 0.007))
        bridge.geometry?.materials = [shell]
        group.addChildNode(bridge)
        holder.addChildNode(group)
        staticRoot.addChildNode(holder)
    }

    // Coffee mug console-left — kept dynamic so its steam emitter lines up.
    do {
        let holder = bay(-0.55)
        let group = SCNNode()
        group.position = SCNVector3(0, -0.5, -1.68)
        // D38: true ceramic — tighter roughness with subtle kiln variation.
        let ceramic = pbrMaterial(UIColor(red: 0.52, green: 0.49, blue: 0.45, alpha: 1), roughness: 0.32)
        ceramic.roughness.contents = ArtTextures.ceramicRoughness()
        let cup = SCNNode(geometry: SCNCylinder(radius: 0.047, height: 0.115))
        (cup.geometry as? SCNCylinder)?.radialSegmentCount = 20
        cup.geometry?.materials = [ceramic]
        cup.position.y = 0.058
        group.addChildNode(cup)
        // Darker glaze ring where the dip left off at the lip.
        let glaze = pbrMaterial(UIColor(red: 0.30, green: 0.22, blue: 0.17, alpha: 1), roughness: 0.22)
        let lip = SCNNode(geometry: SCNTorus(ringRadius: 0.0445, pipeRadius: 0.0038))
        lip.geometry?.materials = [glaze]
        lip.position.y = 0.1155
        group.addChildNode(lip)
        let coffee = SCNNode(geometry: SCNCylinder(radius: 0.040, height: 0.004))
        coffee.geometry?.materials = [pbrMaterial(UIColor(red: 0.13, green: 0.07, blue: 0.03, alpha: 1), roughness: 0.12)]
        coffee.position.y = 0.113
        group.addChildNode(coffee)
        let handle = SCNNode(geometry: SCNTorus(ringRadius: 0.031, pipeRadius: 0.0085))
        handle.geometry?.materials = [ceramic]
        handle.eulerAngles.x = .pi / 2
        handle.position = SCNVector3(0.052, 0.06, 0)
        group.addChildNode(handle)

        // Thin steam — 8-ish particles, slow rise, gentle drift.
        let steam = SCNParticleSystem()
        steam.birthRate = 4
        steam.particleLifeSpan = 2.0
        steam.particleLifeSpanVariation = 0.5
        steam.particleVelocity = 0.085
        steam.particleVelocityVariation = 0.03
        steam.emittingDirection = SCNVector3(0, 1, 0)
        steam.spreadingAngle = 9
        steam.particleImage = ArtTextures.softPuff()
        steam.particleColor = UIColor(white: 1, alpha: 0.15)
        steam.blendMode = .alpha
        steam.acceleration = SCNVector3(0.012, 0.01, 0)
        let fade = CAKeyframeAnimation()
        fade.values = [0.0, 0.34, 0.0]
        fade.keyTimes = [0, 0.3, 1]
        fade.duration = 1
        let grow = CAKeyframeAnimation()
        grow.values = [0.015, 0.075]
        grow.keyTimes = [0, 1]
        grow.duration = 1
        steam.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade),
                                     .size: SCNParticlePropertyController(animation: grow)]
        let steamNode = SCNNode()
        steamNode.position = SCNVector3(0, 0.125, 0)
        steamNode.addParticleSystem(steam)
        group.addChildNode(steamNode)
        holder.addChildNode(group)
        root.addChildNode(holder)
    }

    // CRT scope — dim teal glow with a slow rotating sweep (dynamic).
    do {
        let holder = bay(-0.18)
        let housing = SCNNode(geometry: SCNBox(width: 0.34, height: 0.26, length: 0.26, chamferRadius: 0.025))
        housing.geometry?.materials = [panelMat]
        housing.position = SCNVector3(0, -0.66, -1.7)
        housing.eulerAngles.x = 0.42
        let faceMat = SCNMaterial()
        faceMat.lightingModel = .constant
        faceMat.diffuse.contents = UIColor(white: 0.02, alpha: 1)
        faceMat.emission.contents = ArtTextures.scopeFace()
        faceMat.emission.intensity = 0.55
        let face = SCNNode(geometry: SCNCylinder(radius: 0.105, height: 0.012))
        (face.geometry as? SCNCylinder)?.radialSegmentCount = 28
        face.geometry?.materials = [faceMat]
        face.eulerAngles.x = .pi / 2
        face.position = SCNVector3(0, 0.01, 0.135)
        housing.addChildNode(face)
        // Rotating sweep line.
        let rotator = SCNNode()
        rotator.position = SCNVector3(0, 0.01, 0.145)
        let sweepMat = SCNMaterial()
        sweepMat.lightingModel = .constant
        sweepMat.diffuse.contents = UIColor(red: 0.25, green: 1.0, blue: 0.85, alpha: 1)
        sweepMat.blendMode = .add
        sweepMat.writesToDepthBuffer = false
        let sweep = SCNNode(geometry: SCNPlane(width: 0.095, height: 0.006))
        sweep.geometry?.materials = [sweepMat]
        sweep.position.x = 0.05
        sweep.opacity = 0.5
        rotator.addChildNode(sweep)
        rotator.runAction(.repeatForever(.rotateBy(x: 0, y: 0, z: -.pi * 2, duration: 5.2)))
        housing.addChildNode(rotator)
        holder.addChildNode(housing)
        root.addChildNode(holder)
    }

    // Tiny blinking status LEDs on the console panels (dynamic).
    let ledColors: [UIColor] = [
        UIColor(red: 0.3, green: 1.0, blue: 0.4, alpha: 1),
        UIColor(red: 1.0, green: 0.7, blue: 0.2, alpha: 1),
        UIColor(red: 0.3, green: 1.0, blue: 0.4, alpha: 1),
        UIColor(red: 1.0, green: 0.25, blue: 0.2, alpha: 1),
        UIColor(red: 0.35, green: 0.8, blue: 1.0, alpha: 1),
        UIColor(red: 1.0, green: 0.7, blue: 0.2, alpha: 1),
    ]
    for (i, color) in ledColors.enumerated() {
        let holder = bay(Float(i) * 0.9 + 0.35)
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = color
        let led = SCNNode(geometry: SCNSphere(radius: 0.007))
        (led.geometry as? SCNSphere)?.segmentCount = 6
        led.geometry?.materials = [mat]
        led.position = SCNVector3(0.1 + Float(i % 3) * 0.06, -0.79, -1.395)
        let period = 0.7 + Double(i) * 0.31
        led.runAction(.repeatForever(.sequence([
            .fadeOpacity(to: 0.12, duration: period),
            .fadeOpacity(to: 1.0, duration: period * 0.6),
        ])))
        holder.addChildNode(led)
        root.addChildNode(holder)
    }

    // One very dim warm omni so console/props read at dusk. Scoped to
    // category 2 — it lights only the cab, never the airfield.
    let glow = SCNLight()
    glow.type = .omni
    glow.color = UIColor(red: 1.0, green: 0.84, blue: 0.66, alpha: 1)
    glow.intensity = 90
    glow.attenuationStartDistance = 0.3
    glow.attenuationEndDistance = 4.5
    glow.categoryBitMask = 2
    let glowNode = SCNNode()
    glowNode.light = glow
    glowNode.position = SCNVector3(0, 0.2, 0)
    root.addChildNode(glowNode)

    // Flatten the static furniture into one draw batch per material.
    root.addChildNode(staticRoot.flattenedClone())

    // Taps must pass through the cab to aircraft: category 2 everywhere,
    // and nothing in here casts shadows.
    root.enumerateHierarchy { n, _ in
        n.categoryBitMask = 2
        n.castsShadow = false
    }
    return root
}
