import Foundation
import UIKit

// =============================================================================
// Livery palettes + all code-generated art (no assets on disk).
// Fuselage textures map onto the lathe geometry in AircraftModels.swift:
//   u (image x) wraps the circumference, u = 0 at the BELLY, 0.25 = starboard,
//   0.5 = spine, 0.75 = port. v (image y) runs nose (0) → tail (1).
// =============================================================================

struct LiveryPalette {
    let body: UIColor
    let belly: UIColor?       // belly sweep painted into the fuselage texture
    let tail: UIColor         // vertical fin
    let cheat: UIColor?       // cheat line along the fuselage sides
    let accent: UIColor       // trim: stripes, wingtips, crest
    let nose: UIColor?        // colored nose cap
    let wingtip: UIColor?     // painted wingtip caps
    let accentStripe: Bool    // thin accent stripe tracing the belly sweep
    let roughness: CGFloat
    let metalness: CGFloat
}

extension Livery {
    var palette: LiveryPalette {
        switch self {
        case .islaTurquoise:
            return LiveryPalette(
                body: UIColor(red: 0.97, green: 0.97, blue: 0.96, alpha: 1),
                belly: UIColor(red: 0.04, green: 0.60, blue: 0.62, alpha: 1),
                tail: UIColor(red: 0.04, green: 0.60, blue: 0.62, alpha: 1),
                cheat: nil,
                accent: UIColor(red: 0.95, green: 0.89, blue: 0.68, alpha: 1),
                nose: nil, wingtip: nil, accentStripe: true,
                roughness: 0.38, metalness: 0.05)
        case .islaClassic:
            return LiveryPalette(
                body: UIColor(red: 0.93, green: 0.88, blue: 0.72, alpha: 1),
                belly: nil,
                tail: UIColor(red: 0.89, green: 0.41, blue: 0.08, alpha: 1),
                cheat: UIColor(red: 0.89, green: 0.41, blue: 0.08, alpha: 1),
                accent: UIColor(red: 0.89, green: 0.41, blue: 0.08, alpha: 1),
                nose: nil,
                wingtip: UIColor(red: 0.89, green: 0.41, blue: 0.08, alpha: 1),
                accentStripe: false,
                roughness: 0.44, metalness: 0.0)
        case .privateWhite:
            return LiveryPalette(
                body: UIColor(red: 0.96, green: 0.96, blue: 0.95, alpha: 1),
                belly: nil,
                tail: UIColor(red: 0.96, green: 0.96, blue: 0.95, alpha: 1),
                cheat: UIColor(red: 0.45, green: 0.09, blue: 0.14, alpha: 1),
                accent: UIColor(red: 0.45, green: 0.09, blue: 0.14, alpha: 1),
                nose: nil, wingtip: nil, accentStripe: false,
                roughness: 0.35, metalness: 0.05)
        case .privateSunburst:
            return LiveryPalette(
                body: UIColor(red: 0.97, green: 0.78, blue: 0.17, alpha: 1),
                belly: nil,
                tail: UIColor(red: 0.90, green: 0.43, blue: 0.05, alpha: 1),
                cheat: nil,
                accent: UIColor(red: 0.90, green: 0.43, blue: 0.05, alpha: 1),
                nose: UIColor(red: 0.90, green: 0.43, blue: 0.05, alpha: 1),
                wingtip: UIColor(red: 0.90, green: 0.43, blue: 0.05, alpha: 1),
                accentStripe: false,
                roughness: 0.40, metalness: 0.0)
        case .meridianVIP:
            return LiveryPalette(
                body: UIColor(red: 0.07, green: 0.10, blue: 0.22, alpha: 1),
                belly: nil,
                tail: UIColor(red: 0.07, green: 0.10, blue: 0.22, alpha: 1),
                cheat: UIColor(red: 0.86, green: 0.67, blue: 0.24, alpha: 1),
                accent: UIColor(red: 0.86, green: 0.67, blue: 0.24, alpha: 1),
                nose: nil, wingtip: nil, accentStripe: false,
                roughness: 0.18, metalness: 0.35)
        }
    }
}

private extension UIColor {
    /// D27: multiply RGB to deepen paint accents so they survive 400 m of haze.
    func deepened(_ factor: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * factor, green: g * factor, blue: b * factor, alpha: a)
    }
}

// MARK: - Generated textures

enum ArtTextures {
    private static var cache: [String: UIImage] = [:]

    /// Standard 8-bit sRGB range — the default `.automatic` range produces
    /// extended-range (16-bit) images on wide-gamut devices, whose Metal pixel
    /// format SceneKit rejects at draw time (invalid-MTLPixelFormat abort).
    static let stdFormat: UIGraphicsImageRendererFormat = {
        let f = UIGraphicsImageRendererFormat()
        f.preferredRange = .standard
        return f
    }()

    private static func image(_ key: String, _ make: () -> UIImage) -> UIImage {
        if let img = cache[key] { return img }
        let img = make()
        cache[key] = img
        return img
    }

    // MARK: Fuselage wrap

    static func fuselage(kind: AircraftKind, livery: Livery) -> UIImage {
        image("fus-\(kind.rawValue)-\(livery.rawValue)") {
            let W: CGFloat = 512, H: CGFloat = 512
            let pal = livery.palette
            return UIGraphicsImageRenderer(size: CGSize(width: W, height: H), format: ArtTextures.stdFormat).image { ctx in
                let cg = ctx.cgContext
                pal.body.setFill()
                cg.fill(CGRect(x: 0, y: 0, width: W, height: H))

                if let nose = pal.nose {
                    nose.setFill()
                    cg.fill(CGRect(x: 0, y: 0, width: W, height: H * 0.13))
                    nose.withAlphaComponent(0.45).setFill()
                    cg.fill(CGRect(x: 0, y: H * 0.13, width: W, height: H * 0.02))
                }

                // Belly sweep — symmetric strips at both texture edges (seam at belly).
                // (v, half-width fraction of circumference)
                let sweep: [(CGFloat, CGFloat)] =
                    [(0.02, 0.02), (0.10, 0.09), (0.30, 0.21), (0.55, 0.19), (0.80, 0.12), (0.99, 0.045)]
                if let belly = pal.belly {
                    belly.setFill()
                    for mirrored in [false, true] {
                        let p = UIBezierPath()
                        let xAt: (CGFloat) -> CGFloat = { w in mirrored ? W - w * W : w * W }
                        p.move(to: CGPoint(x: mirrored ? W : 0, y: 0))
                        for (v, w) in sweep { p.addLine(to: CGPoint(x: xAt(w), y: v * H)) }
                        p.addLine(to: CGPoint(x: mirrored ? W : 0, y: H))
                        p.close()
                        p.fill()
                    }
                }
                if pal.accentStripe {
                    pal.accent.deepened(0.85).setStroke()
                    for mirrored in [false, true] {
                        let p = UIBezierPath()
                        let xAt: (CGFloat) -> CGFloat = { w in mirrored ? W - (w * W + 9) : w * W + 9 }
                        p.move(to: CGPoint(x: xAt(sweep[0].1), y: sweep[0].0 * H))
                        for (v, w) in sweep.dropFirst() { p.addLine(to: CGPoint(x: xAt(w), y: v * H)) }
                        p.lineWidth = 5
                        p.stroke()
                    }
                }

                if let cheat = pal.cheat {
                    let uCheat: CGFloat = kind == .comet60 ? 0.225 : 0.245
                    // D27: doubled widths + deepened color so cheat lines carry at range.
                    cheat.deepened(0.85).setFill()
                    for u in [uCheat, 1 - uCheat] {
                        cg.fill(CGRect(x: W * u - 14, y: H * 0.05, width: 28, height: H * 0.93))
                        cg.fill(CGRect(x: W * u + 19, y: H * 0.07, width: 7, height: H * 0.90))
                    }
                }

                if kind == .comet60 {
                    let glass = UIColor(red: 0.02, green: 0.07, blue: 0.08, alpha: 1)
                    // Cabin windows — a row of ovals down each side.
                    for i in 0..<9 {
                        let y = H * (0.26 + CGFloat(i) * 0.045)
                        for u in [0.30, 0.70] as [CGFloat] {
                            let r = CGRect(x: W * u - 5, y: y, width: 10, height: 17)
                            if livery == .meridianVIP {
                                pal.accent.setFill()
                                cg.fillEllipse(in: r.insetBy(dx: -1.5, dy: -1.5))
                            }
                            glass.setFill()
                            cg.fillEllipse(in: r)
                            UIColor(white: 1, alpha: 0.35).setFill()
                            cg.fillEllipse(in: CGRect(x: r.minX + 2, y: r.minY + 2, width: 3, height: 4))
                        }
                    }
                    // Windscreen quads near the nose.
                    glass.setFill()
                    for mirrored in [false, true] {
                        let xAt: (CGFloat) -> CGFloat = { u in mirrored ? W - u * W : u * W }
                        let p = UIBezierPath()
                        p.move(to: CGPoint(x: xAt(0.33), y: H * 0.130))
                        p.addLine(to: CGPoint(x: xAt(0.365), y: H * 0.085))
                        p.addLine(to: CGPoint(x: xAt(0.455), y: H * 0.085))
                        p.addLine(to: CGPoint(x: xAt(0.445), y: H * 0.130))
                        p.close()
                        p.fill()
                    }
                }
            }
        }
    }

    // MARK: Light sprites

    static func halo(key: String, color: UIColor) -> UIImage {
        image("halo-\(key)") {
            let s: CGFloat = 128
            return UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: ArtTextures.stdFormat).image { ctx in
                let cg = ctx.cgContext
                let c = CGPoint(x: s / 2, y: s / 2)
                let colors = [UIColor.white.withAlphaComponent(0.95).cgColor,
                              color.withAlphaComponent(0.55).cgColor,
                              color.withAlphaComponent(0.16).cgColor,
                              color.withAlphaComponent(0).cgColor] as CFArray
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors, locations: [0, 0.12, 0.42, 1])!
                cg.drawRadialGradient(grad, startCenter: c, startRadius: 0,
                                      endCenter: c, endRadius: s / 2, options: [])
            }
        }
    }

    /// Semi-transparent radial-blur disc for a spinning propeller.
    static func propBlur() -> UIImage {
        image("propBlur") {
            let s: CGFloat = 256
            return UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: ArtTextures.stdFormat).image { ctx in
                let cg = ctx.cgContext
                let c = CGPoint(x: s / 2, y: s / 2)
                let gray = UIColor(white: 0.28, alpha: 1)
                let colors = [gray.withAlphaComponent(0).cgColor,
                              gray.withAlphaComponent(0.10).cgColor,
                              gray.withAlphaComponent(0.17).cgColor,
                              gray.withAlphaComponent(0.30).cgColor,
                              gray.withAlphaComponent(0).cgColor] as CFArray
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors, locations: [0.0, 0.22, 0.55, 0.86, 1.0])!
                cg.drawRadialGradient(grad, startCenter: c, startRadius: 0,
                                      endCenter: c, endRadius: s / 2, options: [])
                // Circumferential streaks — the motion-blur read.
                for i in 0..<26 {
                    let f = CGFloat(i)
                    let radius = s * (0.16 + fmod(f * 0.617, 1.0) * 0.32)
                    let start = f * 1.9
                    let alpha = 0.03 + fmod(f * 0.271, 1.0) * 0.05
                    let p = UIBezierPath(arcCenter: c, radius: radius,
                                         startAngle: start, endAngle: start + 1.6, clockwise: true)
                    p.lineWidth = 1.6
                    UIColor(white: 0.55, alpha: alpha).setStroke()
                    p.stroke()
                }
                // Bright prop-tip arc.
                let tip = UIBezierPath(arcCenter: c, radius: s * 0.465,
                                       startAngle: 0, endAngle: .pi * 2, clockwise: true)
                tip.lineWidth = 3.5
                UIColor(white: 0.8, alpha: 0.22).setStroke()
                tip.stroke()
            }
        }
    }

    /// Soft round sprite for smoke / steam particles.
    static func softPuff() -> UIImage {
        image("softPuff") {
            let s: CGFloat = 128
            return UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: ArtTextures.stdFormat).image { ctx in
                let cg = ctx.cgContext
                let c = CGPoint(x: s / 2, y: s / 2)
                let colors = [UIColor(white: 1, alpha: 0.85).cgColor,
                              UIColor(white: 1, alpha: 0.30).cgColor,
                              UIColor(white: 1, alpha: 0).cgColor] as CFArray
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors, locations: [0, 0.45, 1])!
                cg.drawRadialGradient(grad, startCenter: c, startRadius: 0,
                                      endCenter: c, endRadius: s / 2, options: [])
            }
        }
    }

    /// D24: soft radial contact-shadow blob planted under every aircraft.
    static func contactShadow() -> UIImage {
        image("contactShadow") {
            let s: CGFloat = 128
            return UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: ArtTextures.stdFormat).image { ctx in
                let cg = ctx.cgContext
                let c = CGPoint(x: s / 2, y: s / 2)
                let colors = [UIColor.black.withAlphaComponent(1.0).cgColor,
                              UIColor.black.withAlphaComponent(0.75).cgColor,
                              UIColor.black.withAlphaComponent(0.28).cgColor,
                              UIColor.black.withAlphaComponent(0).cgColor] as CFArray
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors, locations: [0, 0.35, 0.7, 1])!
                cg.drawRadialGradient(grad, startCenter: c, startRadius: 0,
                                      endCenter: c, endRadius: s / 2, options: [])
            }
        }
    }

    // MARK: Cab art

    /// D29: console work surface, painted top-down (planar UVs on the desk ring).
    /// Panel seams, screw dots, two taped chart rectangles, one coffee ring.
    static func consoleTopSurface() -> UIImage {
        image("consoleTop") {
            let s: CGFloat = 512
            let c = CGPoint(x: s / 2, y: s / 2)
            let rOuter = s / 2                      // maps to console outer radius 2.25
            let rInner = rOuter * 1.38 / 2.25
            return UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: ArtTextures.stdFormat).image { ctx in
                let cg = ctx.cgContext
                UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1).setFill()
                cg.fill(CGRect(x: 0, y: 0, width: s, height: s))
                // Faint brushed variation.
                for i in 0..<40 {
                    let f = CGFloat(i)
                    let a = f * 0.813
                    UIColor(white: 0.5 + fmod(f * 0.37, 1) * 0.3,
                            alpha: 0.015 + fmod(f * 0.53, 1) * 0.02).setStroke()
                    let p = UIBezierPath(arcCenter: c,
                                         radius: rInner + fmod(f * 0.61, 1) * (rOuter - rInner),
                                         startAngle: a, endAngle: a + 0.8 + fmod(f * 0.29, 1),
                                         clockwise: true)
                    p.lineWidth = 1.5 + fmod(f * 0.43, 1) * 3
                    p.stroke()
                }
                // Radial panel seams every 36° with screw dots flanking them.
                let seam = UIColor(white: 0.02, alpha: 0.55)
                let screwLit = UIColor(white: 0.45, alpha: 0.5)
                let screwDark = UIColor(white: 0.0, alpha: 0.45)
                for i in 0..<10 {
                    let a = CGFloat(i) / 10 * 2 * .pi + 0.05
                    let ca = cos(a), sa = sin(a)
                    let p = UIBezierPath()
                    p.move(to: CGPoint(x: c.x + ca * rInner, y: c.y + sa * rInner))
                    p.addLine(to: CGPoint(x: c.x + ca * rOuter, y: c.y + sa * rOuter))
                    p.lineWidth = 1.6
                    seam.setStroke()
                    p.stroke()
                    for t in [0.25, 0.55, 0.85] as [CGFloat] {
                        let r = rInner + t * (rOuter - rInner)
                        for side in [-1.0, 1.0] as [CGFloat] {
                            let sx = c.x + ca * r - sa * side * 7
                            let sy = c.y + sa * r + ca * side * 7
                            screwDark.setFill()
                            cg.fillEllipse(in: CGRect(x: sx - 2.2, y: sy - 2.2, width: 4.4, height: 4.4))
                            screwLit.setFill()
                            cg.fillEllipse(in: CGRect(x: sx - 1.1, y: sy - 1.8, width: 2.0, height: 2.0))
                        }
                    }
                }
                // Circumferential seam mid-desk.
                seam.setStroke()
                let ring = UIBezierPath(arcCenter: c, radius: rInner + 0.55 * (rOuter - rInner),
                                        startAngle: 0, endAngle: 2 * .pi, clockwise: true)
                ring.lineWidth = 1.2
                ring.stroke()
                // Two taped chart rectangles (paper + tape corners).
                func chart(at angle: CGFloat, rot: CGFloat, w: CGFloat, h: CGFloat) {
                    let r = rInner + 0.5 * (rOuter - rInner)
                    let p = CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r)
                    cg.saveGState()
                    cg.translateBy(x: p.x, y: p.y)
                    cg.rotate(by: angle + .pi / 2 + rot)
                    UIColor(red: 0.85, green: 0.83, blue: 0.76, alpha: 0.9).setFill()
                    cg.fill(CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                    UIColor(red: 0.35, green: 0.45, blue: 0.55, alpha: 0.5).setStroke()
                    for i in 0..<4 {
                        let line = UIBezierPath()
                        line.move(to: CGPoint(x: -w / 2 + 5, y: -h / 2 + 8 + CGFloat(i) * 9))
                        line.addLine(to: CGPoint(x: w / 2 - 5, y: -h / 2 + 8 + CGFloat(i) * 9))
                        line.lineWidth = 1
                        line.stroke()
                    }
                    UIColor(white: 0.75, alpha: 0.55).setFill()
                    for (tx, ty) in [(-w / 2, -h / 2), (w / 2 - 12, h / 2 - 6)] {
                        cg.fill(CGRect(x: tx - 2, y: ty - 2, width: 14, height: 8))
                    }
                    cg.restoreGState()
                }
                // Default view looks toward -Z (v < 0.5 → top of image after flip;
                // decorative, so approximate placement is fine).
                chart(at: -.pi / 2 - 0.45, rot: 0.12, w: 62, h: 46)
                chart(at: -.pi / 2 + 0.62, rot: -0.2, w: 48, h: 40)
                // Coffee ring stain near the mug bay.
                let stainC = CGPoint(x: c.x + cos(-.pi / 2 - 0.9) * (rInner + 0.35 * (rOuter - rInner)),
                                     y: c.y + sin(-.pi / 2 - 0.9) * (rInner + 0.35 * (rOuter - rInner)))
                UIColor(red: 0.32, green: 0.20, blue: 0.10, alpha: 0.30).setStroke()
                let stain = UIBezierPath(arcCenter: stainC, radius: 11,
                                         startAngle: 0.4, endAngle: 2 * .pi + 0.1, clockwise: true)
                stain.lineWidth = 3
                stain.stroke()
            }
        }
    }

    /// A17: amber seven-segment-style wind + altimeter groups on a dark panel.
    static func windAltReadout() -> UIImage {
        image("windAlt") {
            let W: CGFloat = 256, H: CGFloat = 84
            return UIGraphicsImageRenderer(size: CGSize(width: W, height: H), format: ArtTextures.stdFormat).image { ctx in
                let cg = ctx.cgContext
                UIColor(white: 0.015, alpha: 1).setFill()
                cg.fill(CGRect(x: 0, y: 0, width: W, height: H))
                let amber = UIColor(red: 1.0, green: 0.62, blue: 0.14, alpha: 1)
                let ghost = amber.withAlphaComponent(0.10)
                let font = UIFont.monospacedDigitSystemFont(ofSize: 34, weight: .bold)
                let small = UIFont.systemFont(ofSize: 11, weight: .semibold)
                func draw(_ text: String, _ color: UIColor, _ f: UIFont, _ at: CGPoint) {
                    (text as NSString).draw(at: at, withAttributes: [.font: f, .foregroundColor: color])
                }
                // Ghost segments behind the live digits — the unlit 7-seg glass.
                draw("888 88", ghost, font, CGPoint(x: 14, y: 26))
                draw("88.88", ghost, font, CGPoint(x: 150, y: 26))
                draw("240 08", amber, font, CGPoint(x: 14, y: 26))
                draw("29.92", amber, font, CGPoint(x: 150, y: 26))
                draw("WIND °/KT", amber.withAlphaComponent(0.5), small, CGPoint(x: 16, y: 8))
                draw("ALTIMETER", amber.withAlphaComponent(0.5), small, CGPoint(x: 152, y: 8))
            }
        }
    }

    /// D38: subtle kiln-glaze roughness variation for the mug, mean ≈ 0.32.
    static func ceramicRoughness() -> UIImage {
        image("ceramicRough") {
            let s: CGFloat = 64
            return UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: ArtTextures.stdFormat).image { ctx in
                let cg = ctx.cgContext
                UIColor(white: 0.32, alpha: 1).setFill()
                cg.fill(CGRect(x: 0, y: 0, width: s, height: s))
                for i in 0..<90 {
                    let f = CGFloat(i)
                    let x = fmod(f * 17.31, s)
                    let y = fmod(f * 29.7, s)
                    let r = 2.5 + fmod(f * 0.83, 1) * 5
                    UIColor(white: 0.32 + (fmod(f * 0.57, 1) - 0.5) * 0.12,
                            alpha: 0.35).setFill()
                    cg.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                }
            }
        }
    }

    /// Very faint dusk gradient used as the cab-glass reflection map.
    static func duskReflection() -> UIImage {
        image("duskReflection") {
            let W: CGFloat = 128, H: CGFloat = 128
            return UIGraphicsImageRenderer(size: CGSize(width: W, height: H), format: ArtTextures.stdFormat).image { ctx in
                let cg = ctx.cgContext
                let colors = [UIColor(red: 0.18, green: 0.26, blue: 0.48, alpha: 0.05).cgColor,
                              UIColor(red: 0.55, green: 0.38, blue: 0.42, alpha: 0.05).cgColor,
                              UIColor(red: 0.95, green: 0.58, blue: 0.30, alpha: 0.07).cgColor,
                              UIColor(red: 0.18, green: 0.14, blue: 0.18, alpha: 0.04).cgColor] as CFArray
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors, locations: [0, 0.45, 0.62, 1])!
                cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0),
                                      end: CGPoint(x: 0, y: H), options: [])
                UIColor(red: 1.0, green: 0.65, blue: 0.35, alpha: 0.06).setFill()
                cg.fill(CGRect(x: 0, y: H * 0.61, width: W, height: 1.5))
            }
        }
    }

    /// Teal CRT scope face — rings, sweep-fade wedge baked out, a few blips.
    static func scopeFace() -> UIImage {
        image("scopeFace") {
            let s: CGFloat = 256
            return UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: ArtTextures.stdFormat).image { ctx in
                let cg = ctx.cgContext
                let c = CGPoint(x: s / 2, y: s / 2)
                UIColor(red: 0.015, green: 0.07, blue: 0.06, alpha: 1).setFill()
                cg.fill(CGRect(x: 0, y: 0, width: s, height: s))
                let teal = UIColor(red: 0.15, green: 0.85, blue: 0.72, alpha: 1)
                for r in [30, 60, 90, 116] as [CGFloat] {
                    let ring = UIBezierPath(arcCenter: c, radius: r,
                                            startAngle: 0, endAngle: .pi * 2, clockwise: true)
                    ring.lineWidth = r > 100 ? 2.5 : 1.2
                    teal.withAlphaComponent(r > 100 ? 0.5 : 0.30).setStroke()
                    ring.stroke()
                }
                teal.withAlphaComponent(0.18).setStroke()
                for a in stride(from: CGFloat(0), to: .pi * 2, by: .pi / 4) {
                    let p = UIBezierPath()
                    p.move(to: c)
                    p.addLine(to: CGPoint(x: c.x + cos(a) * 116, y: c.y + sin(a) * 116))
                    p.lineWidth = 1
                    p.stroke()
                }
                teal.setFill()
                for (bx, by, r) in [(0.31, 0.42, 3.2), (0.62, 0.30, 2.6), (0.57, 0.68, 3.6), (0.40, 0.61, 2.2)] {
                    cg.fillEllipse(in: CGRect(x: s * CGFloat(bx) - CGFloat(r), y: s * CGFloat(by) - CGFloat(r),
                                              width: CGFloat(r) * 2, height: CGFloat(r) * 2))
                }
                cg.fillEllipse(in: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5))
                // Vignette so the tube reads curved.
                let vig = [UIColor.black.withAlphaComponent(0).cgColor,
                           UIColor.black.withAlphaComponent(0.55).cgColor] as CFArray
                let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: vig, locations: [0.72, 1])!
                cg.drawRadialGradient(grad, startCenter: c, startRadius: 0,
                                      endCenter: c, endRadius: s / 2, options: [])
            }
        }
    }

    /// Lined paper for the clipboard — a flight-strip log sheet.
    static func paperSheet() -> UIImage {
        image("paperSheet") {
            let W: CGFloat = 128, H: CGFloat = 168
            return UIGraphicsImageRenderer(size: CGSize(width: W, height: H), format: ArtTextures.stdFormat).image { ctx in
                let cg = ctx.cgContext
                UIColor(red: 0.95, green: 0.94, blue: 0.90, alpha: 1).setFill()
                cg.fill(CGRect(x: 0, y: 0, width: W, height: H))
                UIColor(red: 0.35, green: 0.42, blue: 0.5, alpha: 0.8).setFill()
                cg.fill(CGRect(x: 10, y: 16, width: W - 20, height: 2.5))
                for i in 0..<10 {
                    let y = 30 + CGFloat(i) * 13
                    UIColor(white: 0.55, alpha: 0.4).setFill()
                    cg.fill(CGRect(x: 10, y: y, width: W - 20, height: 1))
                    // Handwriting hints.
                    UIColor(red: 0.22, green: 0.26, blue: 0.38, alpha: 0.65).setFill()
                    var x: CGFloat = 12 + fmod(CGFloat(i) * 7.3, 14)
                    while x < W - 34 {
                        let w = 8 + fmod(x * 3.1, 16)
                        if fmod(x + CGFloat(i) * 5, 3) > 0.9 {
                            cg.fill(CGRect(x: x, y: y - 6, width: w, height: 2.4))
                        }
                        x += w + 6
                    }
                }
            }
        }
    }
}
