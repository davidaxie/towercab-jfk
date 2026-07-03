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
// Glass band head/sill geometry — single source of truth for the rake so the
// frame members and the lathed band can never drift apart.
private let kGlassSillY: Float = -0.72
private let kGlassHeadY: Float = 1.22
private let kGlassSillR: Float = kGlassRadius              // sill radius (bottom)
private let kGlassHeadR: Float = kGlassRadius + (kGlassHeadY - kGlassSillY) * 0.26795  // ≈3.02, tan(15°)
// Positive x-euler on a -Z-facing post leans its TOP outward (+Z→ away from eye),
// matching the band whose radius grows with height. Derived from the band radii.
private let kGlassTilt: Float = atan((kGlassHeadR - kGlassSillR) / (kGlassHeadY - kGlassSillY))  // ≈ +0.262

/// D1: one lathed truncated-cone glass band (sill r 2.5 @ y −0.72 → head
/// r ~3.02 @ y +1.22, matching the 15° top-out rake). A single surface can't
/// double-blend at bay seams, which is what painted the two sky shafts.
private func glassBandNode(material: SCNMaterial) -> SCNNode {
    let segments = 36
    let yBot: Float = kGlassSillY, yTop: Float = kGlassHeadY
    let rBot: Float = kGlassSillR
    let rTop: Float = kGlassHeadR   // ≈ 3.02, from the shared rake constant
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
    // Slightly warmer, marginally more present tint than the old near-invisible
    // 0.055 wash — pulled a touch toward the horizon so the panes read as glass.
    glassMat.diffuse.contents = UIColor(red: 0.06, green: 0.08, blue: 0.09, alpha: 0.09)
    glassMat.specular.contents = UIColor(white: 0.3, alpha: 1)
    glassMat.shininess = 60
    // The authored warm dusk gradient (blue→rose→orange) drives the sheen. It is
    // a flat gradient image, NOT a spherical env map, so it does NOT paint the
    // view-locked bands the old reflective map did (why that was removed). A steep
    // fresnel concentrates it at the grazing pane edges — glass at the frame, clear
    // over the runway sightline — and a faint emission carries a warm glow at true
    // dusk independent of the sun.
    let dusk = ArtTextures.duskReflection()
    glassMat.reflective.contents = dusk
    glassMat.reflective.intensity = 0.6
    glassMat.fresnelExponent = 2.2
    glassMat.emission.contents = dusk
    glassMat.emission.intensity = 0.12
    glassMat.isDoubleSided = true
    glassMat.writesToDepthBuffer = false
    glassMat.blendMode = .alpha

    let glassBand = glassBandNode(material: glassMat)
    glassBand.renderingOrder = 950
    root.addChildNode(glassBand)

    // --- Mullions (slim, ~7 cm) at bay boundaries.
    // The post must RAKE with the band (kGlassTilt is now +, top leans outward)
    // and sit at the band's mid-height radius so it lies flush against the glass
    // at every height instead of crossing the plane. Mid-height y = 0.25.
    let mullionMidY: Float = 0.25
    let mullionSlope = (kGlassHeadR - kGlassSillR) / (kGlassHeadY - kGlassSillY)
    // Radius of the band at mid-height, pulled ~4 cm eye-side so the post sits
    // just inboard of the pane (glass faces the eye).
    let mullionR = kGlassSillR + (mullionMidY - kGlassSillY) * mullionSlope - 0.04
    let mullionGeo = SCNBox(width: 0.072, height: 2.08, length: 0.11, chamferRadius: 0.015)
    mullionGeo.materials = [mullionMat]
    for i in 0..<kBays {
        let holder = bay(step * (Float(i) + 0.5))
        let m = SCNNode(geometry: mullionGeo)
        m.position = SCNVector3(0, mullionMidY, -mullionR)
        m.eulerAngles.x = kGlassTilt
        holder.addChildNode(m)
        staticRoot.addChildNode(holder)
    }

    // --- Horizontal equipment rail / muntin across the glass (parallax + framing).
    // Real cab windows all carry a horizontal muntin; it also gives the eye a
    // continuous near-field line to parallax against between the 9 mullion seams.
    // Placed low (below eye level) so it rides the lower third of the glass and
    // never crosses the runway sightline at the home pose.
    let railY: Float = -0.05
    let railR = kGlassSillR + (railY - kGlassSillY) * mullionSlope   // track the band
    let rail0 = SCNNode(geometry: SCNTube(innerRadius: CGFloat(railR - 0.035),
                                          outerRadius: CGFloat(railR + 0.035),
                                          height: 0.05))
    rail0.geometry?.materials = [mullionMat]
    rail0.position.y = railY
    staticRoot.addChildNode(rail0)
    // Short angled corner gussets where each mullion meets the head beam, adding
    // a second parallax cue up near the frame corners.
    let gussetGeo = SCNBox(width: 0.05, height: 0.20, length: 0.05, chamferRadius: 0.01)
    gussetGeo.materials = [mullionMat]
    for i in 0..<kBays {
        let holder = bay(step * (Float(i) + 0.5))
        let g = SCNNode(geometry: gussetGeo)
        let gY: Float = 1.05
        let gR = kGlassSillR + (gY - kGlassSillY) * mullionSlope - 0.05
        g.position = SCNVector3(0, gY, -gR)
        g.eulerAngles.x = kGlassTilt + 0.5   // canted like a corner brace
        holder.addChildNode(g)
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

    // Keep the matte-black anti-glare intent but give the ceiling READ so a
    // pan to the up-clamp shows a real cab ceiling, not a missing-geometry void:
    // a warm metal trim ring where the overhang meets the head beam, plus a few
    // dim recessed warm downlights set into the disc.
    let trimRing = SCNNode(geometry: SCNTorus(ringRadius: 2.85, pipeRadius: 0.02))
    trimRing.geometry?.materials = [pbrMaterial(UIColor(red: 0.28, green: 0.24, blue: 0.20, alpha: 1),
                                                roughness: 0.4, metalness: 0.5)]
    trimRing.position.y = 1.25
    staticRoot.addChildNode(trimRing)
    let downMat = SCNMaterial()
    downMat.lightingModel = .constant
    downMat.diffuse.contents = UIColor(red: 0.14, green: 0.10, blue: 0.06, alpha: 1)
    downMat.emission.contents = UIColor(red: 1.0, green: 0.72, blue: 0.42, alpha: 1)
    downMat.emission.intensity = 0.15
    let downGeo = SCNCylinder(radius: 0.05, height: 0.012)
    downGeo.radialSegmentCount = 16
    downGeo.materials = [downMat]
    for i in 0..<3 {
        let holder = bay(Float(i) * (2 * .pi / 3) + 0.4)
        let d = SCNNode(geometry: downGeo)
        d.position = SCNVector3(0, 1.40, -1.7)
        holder.addChildNode(d)
        staticRoot.addChildNode(holder)
    }

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
            // Foam eyecup ring on the outer face of each cup.
            let eyecup = SCNNode(geometry: SCNTorus(ringRadius: 0.028, pipeRadius: 0.006))
            eyecup.geometry?.materials = [padMat]
            eyecup.eulerAngles.x = .pi / 2
            eyecup.position = SCNVector3(0.078 * s, -0.033, 0.025 * s)
            group.addChildNode(eyecup)
        }
        // Coiled cable descending from the left cup down to the console lip —
        // an actual connected chain, not free-floating rings. Each loop steps
        // down and outward so the eye reads a cable running off the desk edge.
        for i in 0..<5 {
            let t = Float(i)
            let loop = SCNNode(geometry: SCNTorus(ringRadius: 0.019, pipeRadius: 0.0045))
            loop.geometry?.materials = [padMat]
            loop.position = SCNVector3(0.09 + t * 0.028, -0.03 - t * 0.024, 0.05 + t * 0.02)
            loop.eulerAngles = SCNVector3(0.25 + t * 0.08, t * 0.45, 0.1)
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
        let gripMat = pbrMaterial(UIColor(white: 0.14, alpha: 1), roughness: 0.7)
        let grip = SCNNode(geometry: SCNBox(width: 0.02, height: 0.07, length: 0.035, chamferRadius: 0.006))
        grip.geometry?.materials = [gripMat]
        grip.position = SCNVector3(0, 0.055, 0.045)
        grip.eulerAngles.x = -0.35
        gun.addChildNode(grip)
        // Trigger-guard loop just ahead of the grip so it reads as a gun.
        let guard0 = SCNNode(geometry: SCNTorus(ringRadius: 0.018, pipeRadius: 0.004))
        guard0.geometry?.materials = [gripMat]
        guard0.eulerAngles = SCNVector3(1.2, 0, 0)
        guard0.position = SCNVector3(0, 0.03, 0.03)
        gun.addChildNode(guard0)
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
        // Near-black glass with a low roughness so the objective lenses catch a
        // faint golden-hour glint instead of reading as flat plastic caps.
        let lensGlass = pbrMaterial(UIColor(red: 0.03, green: 0.05, blue: 0.06, alpha: 1),
                                    roughness: 0.12, metalness: 0.2)
        for s in [Float(-1), Float(1)] {
            let barrel = SCNNode(geometry: SCNCylinder(radius: 0.026, height: 0.13))
            barrel.geometry?.materials = [shell]
            barrel.position = SCNVector3(0.037 * s, 0, 0)
            group.addChildNode(barrel)
            let objective = SCNNode(geometry: SCNCylinder(radius: 0.030, height: 0.035))
            objective.geometry?.materials = [shell]
            objective.position = SCNVector3(0.037 * s, -0.055, 0)
            group.addChildNode(objective)
            // Recessed objective lens disc at the far face of each barrel.
            let lens = SCNNode(geometry: SCNCylinder(radius: 0.024, height: 0.004))
            lens.geometry?.materials = [lensGlass]
            lens.position = SCNVector3(0.037 * s, -0.073, 0)
            group.addChildNode(lens)
        }
        let bridge = SCNNode(geometry: SCNBox(width: 0.05, height: 0.05, length: 0.024, chamferRadius: 0.007))
        bridge.geometry?.materials = [shell]
        group.addChildNode(bridge)
        // Center focus wheel between the barrels.
        let focus = SCNNode(geometry: SCNCylinder(radius: 0.011, height: 0.03))
        focus.geometry?.materials = [steelMat]
        focus.eulerAngles.z = .pi / 2
        focus.position = SCNVector3(0, 0.028, 0)
        group.addChildNode(focus)
        // A thin strap hint draping off one side (a flattened torus arc).
        let strap = SCNNode(geometry: SCNTorus(ringRadius: 0.05, pipeRadius: 0.004))
        strap.geometry?.materials = [pbrMaterial(UIColor(white: 0.06, alpha: 1), roughness: 0.85)]
        strap.scale = SCNVector3(1, 1, 0.25)
        strap.eulerAngles = SCNVector3(1.3, 0.6, 0)
        strap.position = SCNVector3(-0.06, 0.02, -0.03)
        group.addChildNode(strap)
        holder.addChildNode(group)
        staticRoot.addChildNode(holder)
    }

    // --- Dress the rest of the 360° console so panning left/behind is not bare.
    // Every group below is static (parented into staticRoot via a bay() holder)
    // so it flattens into the static draw batch. Warm-charcoal palette, at most
    // one emissive face per group so they read as equipment, not decoration.

    // Second radio stack — three stacked panel boxes with knobs + a lit face.
    do {
        let holder = bay(2.4)
        let group = SCNNode()
        group.position = SCNVector3(0, -0.5, -1.66)
        for i in 0..<3 {
            let box = SCNNode(geometry: SCNBox(width: 0.26, height: 0.052, length: 0.20, chamferRadius: 0.006))
            box.geometry?.materials = [panelMat]
            box.position.y = 0.03 + Float(i) * 0.056
            group.addChildNode(box)
            // Two small steel knobs on the right of each unit.
            for k in 0..<2 {
                let knob = SCNNode(geometry: SCNCylinder(radius: 0.011, height: 0.014))
                knob.geometry?.materials = [steelMat]
                knob.eulerAngles.x = .pi / 2
                knob.position = SCNVector3(0.075 + Float(k) * 0.03, 0.03 + Float(i) * 0.056, 0.10)
                group.addChildNode(knob)
            }
        }
        // One amber lit face on the top unit.
        let faceMat = SCNMaterial()
        faceMat.lightingModel = .constant
        faceMat.diffuse.contents = UIColor(white: 0.02, alpha: 1)
        faceMat.emission.contents = UIColor(red: 0.85, green: 0.55, blue: 0.18, alpha: 1)
        faceMat.emission.intensity = 0.4
        let radioFace = SCNNode(geometry: SCNPlane(width: 0.11, height: 0.026))
        radioFace.geometry?.materials = [faceMat]
        radioFace.position = SCNVector3(-0.05, 0.142, 0.101)
        group.addChildNode(radioFace)
        holder.addChildNode(group)
        staticRoot.addChildNode(holder)
    }

    // Paper flight-strip tray — a shallow steel tray with a fan of colored slabs.
    do {
        let holder = bay(3.1)
        let group = SCNNode()
        group.position = SCNVector3(0, -0.5, -1.62)
        group.eulerAngles.y = 0.12
        let tray = SCNNode(geometry: SCNBox(width: 0.30, height: 0.014, length: 0.10, chamferRadius: 0.004))
        tray.geometry?.materials = [steelMat]
        group.addChildNode(tray)
        let stripColors: [UIColor] = [
            UIColor(red: 0.86, green: 0.84, blue: 0.78, alpha: 1),   // manila
            UIColor(red: 0.80, green: 0.86, blue: 0.82, alpha: 1),   // pale green
            UIColor(red: 0.88, green: 0.80, blue: 0.74, alpha: 1),   // pale pink
            UIColor(red: 0.84, green: 0.84, blue: 0.80, alpha: 1),
        ]
        for (i, c) in stripColors.enumerated() {
            let strip = SCNNode(geometry: SCNBox(width: 0.24, height: 0.003, length: 0.028, chamferRadius: 0))
            strip.geometry?.materials = [pbrMaterial(c, roughness: 0.9)]
            strip.position = SCNVector3(Float(i) * 0.004, 0.009 + Float(i) * 0.0035, -0.028 + Float(i) * 0.019)
            strip.eulerAngles.y = Float(i) * 0.03 - 0.03
            group.addChildNode(strip)
        }
        holder.addChildNode(group)
        staticRoot.addChildNode(holder)
    }

    // Desk mic on a gooseneck — weighted base, curved steel neck, box handset.
    do {
        let holder = bay(-2.2)
        let group = SCNNode()
        group.position = SCNVector3(0, -0.5, -1.60)
        let base = SCNNode(geometry: SCNCylinder(radius: 0.045, height: 0.02))
        base.geometry?.materials = [pbrMaterial(UIColor(white: 0.08, alpha: 1), roughness: 0.5)]
        base.position.y = 0.01
        group.addChildNode(base)
        // Gooseneck approximated by a few short steel segments arcing forward.
        func neckPos(_ t: Float) -> SCNVector3 { SCNVector3(0, 0.045 + t * 0.045, t * t * 0.008) }
        for i in 0..<5 {
            let t = Float(i)
            let seg = SCNNode(geometry: SCNCylinder(radius: 0.006, height: 0.05))
            seg.geometry?.materials = [steelMat]
            seg.position = neckPos(t)
            seg.eulerAngles.x = t * 0.16
            group.addChildNode(seg)
        }
        let tip = neckPos(4)
        let head = SCNNode(geometry: SCNSphere(radius: 0.022))
        (head.geometry as? SCNSphere)?.segmentCount = 12
        head.geometry?.materials = [pbrMaterial(UIColor(white: 0.10, alpha: 1), roughness: 0.7)]
        head.position = SCNVector3(tip.x, tip.y + 0.03, tip.z + 0.02)
        group.addChildNode(head)
        holder.addChildNode(group)
        staticRoot.addChildNode(holder)
    }

    // Pen/pencil cup — a small steel cup with a few slim pencils leaning out.
    do {
        let holder = bay(-1.5)
        let group = SCNNode()
        group.position = SCNVector3(0, -0.5, -1.64)
        let cup = SCNNode(geometry: SCNTube(innerRadius: 0.024, outerRadius: 0.028, height: 0.075))
        cup.geometry?.materials = [pbrMaterial(UIColor(white: 0.30, alpha: 1), roughness: 0.4, metalness: 0.5)]
        cup.position.y = 0.037
        group.addChildNode(cup)
        let base = SCNNode(geometry: SCNCylinder(radius: 0.026, height: 0.006))
        base.geometry?.materials = [pbrMaterial(UIColor(white: 0.30, alpha: 1), roughness: 0.4, metalness: 0.5)]
        base.position.y = 0.003
        group.addChildNode(base)
        let penColors: [UIColor] = [
            UIColor(red: 0.75, green: 0.55, blue: 0.15, alpha: 1),   // pencil yellow
            UIColor(red: 0.15, green: 0.15, blue: 0.16, alpha: 1),   // black pen
            UIColor(red: 0.55, green: 0.18, blue: 0.14, alpha: 1),   // red pen
        ]
        for (i, c) in penColors.enumerated() {
            let pen = SCNNode(geometry: SCNCylinder(radius: 0.0035, height: 0.13))
            pen.geometry?.materials = [pbrMaterial(c, roughness: 0.55)]
            pen.position = SCNVector3(Float(i) * 0.006 - 0.006, 0.07, 0)
            pen.eulerAngles = SCNVector3(0.12 * Float(i) - 0.06, 0, 0.16 * Float(i) - 0.16)
            group.addChildNode(pen)
        }
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

    // Warm instrument backlight: sits just above the console front and rakes
    // warm light UP onto the props, the underside of the beam/overhang, and the
    // inner glass — the way real cab instrument glow works — instead of a flat
    // fill coincident with the eye. Scoped to category 2 so the airfield is
    // never touched.
    let glow = SCNLight()
    glow.type = .omni
    glow.color = UIColor(red: 1.0, green: 0.82, blue: 0.62, alpha: 1)
    glow.intensity = 55
    glow.attenuationStartDistance = 0.25
    glow.attenuationEndDistance = 3.0
    glow.categoryBitMask = 2
    let glowNode = SCNNode()
    glowNode.light = glow
    glowNode.position = SCNVector3(0, -0.35, -1.4)
    root.addChildNode(glowNode)

    // A second, cool-neutral omni high near the ceiling so the matte-black
    // anti-glare disc catches a faint sky-fill and does not read as a dead void
    // when the player pans up to the pitch clamp. Also category 2.
    let ceilFill = SCNLight()
    ceilFill.type = .omni
    ceilFill.color = UIColor(red: 0.62, green: 0.68, blue: 0.80, alpha: 1)
    ceilFill.intensity = 25
    ceilFill.attenuationStartDistance = 0.3
    ceilFill.attenuationEndDistance = 3.2
    ceilFill.categoryBitMask = 2
    let ceilFillNode = SCNNode()
    ceilFillNode.light = ceilFill
    ceilFillNode.position = SCNVector3(0, 1.0, 0)
    root.addChildNode(ceilFillNode)

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
