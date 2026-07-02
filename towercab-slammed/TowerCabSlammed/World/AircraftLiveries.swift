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

// MARK: - Generated textures

enum ArtTextures {
    private static var cache: [String: UIImage] = [:]

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
            return UIGraphicsImageRenderer(size: CGSize(width: W, height: H)).image { ctx in
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
                    pal.accent.setStroke()
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
                    cheat.setFill()
                    for u in [uCheat, 1 - uCheat] {
                        cg.fill(CGRect(x: W * u - 7, y: H * 0.05, width: 14, height: H * 0.93))
                        cg.fill(CGRect(x: W * u + 12, y: H * 0.07, width: 3.5, height: H * 0.90))
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
            return UIGraphicsImageRenderer(size: CGSize(width: s, height: s)).image { ctx in
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
            return UIGraphicsImageRenderer(size: CGSize(width: s, height: s)).image { ctx in
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
            return UIGraphicsImageRenderer(size: CGSize(width: s, height: s)).image { ctx in
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

    // MARK: Cab art

    /// Very faint dusk gradient used as the cab-glass reflection map.
    static func duskReflection() -> UIImage {
        image("duskReflection") {
            let W: CGFloat = 128, H: CGFloat = 128
            return UIGraphicsImageRenderer(size: CGSize(width: W, height: H)).image { ctx in
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
            return UIGraphicsImageRenderer(size: CGSize(width: s, height: s)).image { ctx in
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
            return UIGraphicsImageRenderer(size: CGSize(width: W, height: H)).image { ctx in
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
