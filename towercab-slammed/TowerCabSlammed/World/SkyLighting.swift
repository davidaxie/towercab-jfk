import Foundation
import SceneKit
import UIKit
import simd

// =============================================================================
// GoldenHourSky — owns the entire look: gradient sky dome with a live sun disc
// and halo, warm key light with soft shadows, luminous cool fill (shadows are
// never crushed), warm exaggerated aerial haze, PBR environment light, the
// dusk switch-on of the airfield lights, and the HDR camera grade.
//
// The slice plays 17:30 → ~18:45 at 12×. Sunset lands at ~18:10; the field
// lights walk on just after. setTime() is called every frame: transform and
// scalar-intensity updates run every call; anything that boxes a value
// (colors, shader uniforms, env image) is bucketed so no visible stepping
// occurs but the hot path stays allocation-light.
//
// The dome sits INSIDE fogStartDistance (radius 2.15 km around the static cab)
// with depth writes off and renderingOrder -1000, so scene fog never eats the
// sky; distant ocean/terrain instead fog out toward the dome's horizon band,
// which is driven from the same palette — a seamless painted horizon.
// =============================================================================

final class GoldenHourSky: SkyDirector {

    // Sunset (sun elevation 0) in sim hours; edge lights follow just after.
    static let sunsetHour = 18.1667

    private let scene: SCNScene
    private let bank: AirfieldLightBank
    private let domeMaterial: SCNMaterial
    private let sunNode: SCNNode
    private let sunLight: SCNLight
    private let fillNode: SCNNode
    private let fillLight: SCNLight
    private let ambientLight: SCNLight
    private var lastColorBucket = Int.min
    private var lastEnvBucket = Int.min

    // MARK: Palette keyframes

    private struct SkyState {
        var sunColor: SIMD3<Double>
        var sunIntensity: Double
        var horizon: SIMD3<Double>
        var mid: SIMD3<Double>
        var zenith: SIMD3<Double>
        var ambientColor: SIMD3<Double>
        var ambientIntensity: Double
        var fillIntensity: Double
        var fog: SIMD3<Double>
        var fogEnd: Double
        var discGain: Double
        var haloGain: Double
        var haloPow: Double
        var envIntensity: Double

        static func lerp(_ a: SkyState, _ b: SkyState, _ t: Double) -> SkyState {
            func m(_ x: SIMD3<Double>, _ y: SIMD3<Double>) -> SIMD3<Double> { x + (y - x) * t }
            func s(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
            return SkyState(sunColor: m(a.sunColor, b.sunColor),
                            sunIntensity: s(a.sunIntensity, b.sunIntensity),
                            horizon: m(a.horizon, b.horizon),
                            mid: m(a.mid, b.mid),
                            zenith: m(a.zenith, b.zenith),
                            ambientColor: m(a.ambientColor, b.ambientColor),
                            ambientIntensity: s(a.ambientIntensity, b.ambientIntensity),
                            fillIntensity: s(a.fillIntensity, b.fillIntensity),
                            fog: m(a.fog, b.fog),
                            fogEnd: s(a.fogEnd, b.fogEnd),
                            discGain: s(a.discGain, b.discGain),
                            haloGain: s(a.haloGain, b.haloGain),
                            haloPow: s(a.haloPow, b.haloPow),
                            envIntensity: s(a.envIntensity, b.envIntensity))
        }
    }

    // Golden hour → orange-rose sunset → violet dusk.
    private let keyHours: [Double] = [17.30, 17.90, 18.17, 18.45, 18.80]
    private let keyStates: [SkyState] = [
        SkyState(sunColor: SIMD3(1.00, 0.86, 0.62), sunIntensity: 1600,
                 horizon: SIMD3(1.02, 0.80, 0.54), mid: SIMD3(0.66, 0.60, 0.62), zenith: SIMD3(0.28, 0.42, 0.66),
                 ambientColor: SIMD3(0.58, 0.63, 0.80), ambientIntensity: 440, fillIntensity: 170,
                 fog: SIMD3(0.93, 0.77, 0.58), fogEnd: 32_000,
                 discGain: 1.9, haloGain: 0.60, haloPow: 30, envIntensity: 1.15),
        SkyState(sunColor: SIMD3(1.00, 0.68, 0.42), sunIntensity: 1250,
                 horizon: SIMD3(1.05, 0.68, 0.42), mid: SIMD3(0.74, 0.52, 0.52), zenith: SIMD3(0.22, 0.31, 0.57),
                 ambientColor: SIMD3(0.58, 0.60, 0.80), ambientIntensity: 420, fillIntensity: 150,
                 fog: SIMD3(0.94, 0.70, 0.52), fogEnd: 30_000,
                 discGain: 1.7, haloGain: 0.72, haloPow: 22, envIntensity: 1.05),
        SkyState(sunColor: SIMD3(1.00, 0.50, 0.30), sunIntensity: 620,
                 horizon: SIMD3(1.02, 0.55, 0.38), mid: SIMD3(0.68, 0.40, 0.52), zenith: SIMD3(0.16, 0.20, 0.46),
                 ambientColor: SIMD3(0.56, 0.55, 0.79), ambientIntensity: 390, fillIntensity: 120,
                 fog: SIMD3(0.88, 0.58, 0.48), fogEnd: 27_000,
                 discGain: 1.3, haloGain: 0.85, haloPow: 16, envIntensity: 0.92),
        SkyState(sunColor: SIMD3(1.00, 0.44, 0.36), sunIntensity: 90,
                 horizon: SIMD3(0.78, 0.42, 0.46), mid: SIMD3(0.44, 0.30, 0.48), zenith: SIMD3(0.11, 0.13, 0.34),
                 ambientColor: SIMD3(0.53, 0.51, 0.78), ambientIntensity: 330, fillIntensity: 80,
                 fog: SIMD3(0.66, 0.46, 0.50), fogEnd: 23_000,
                 discGain: 0.0, haloGain: 0.55, haloPow: 12, envIntensity: 0.74),
        SkyState(sunColor: SIMD3(1.00, 0.42, 0.38), sunIntensity: 0,
                 horizon: SIMD3(0.55, 0.34, 0.44), mid: SIMD3(0.30, 0.24, 0.42), zenith: SIMD3(0.07, 0.08, 0.24),
                 ambientColor: SIMD3(0.50, 0.49, 0.78), ambientIntensity: 290, fillIntensity: 55,
                 fog: SIMD3(0.48, 0.37, 0.47), fogEnd: 20_000,
                 discGain: 0.0, haloGain: 0.30, haloPow: 10, envIntensity: 0.60),
    ]

    // MARK: Init

    init(scene: SCNScene, airport: AirportLayout, bank: AirfieldLightBank) {
        self.scene = scene
        self.bank = bank

        // --- Sky dome ---
        let dome = SCNSphere(radius: 2150)
        dome.segmentCount = 48
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.cullMode = .front
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = false
        mat.shaderModifiers = [.fragment: GoldenHourSky.domeShader]
        dome.materials = [mat]
        domeMaterial = mat
        let domeNode = SCNNode(geometry: dome)
        domeNode.name = "skyDome"
        // Centered on the (static) cab so the whole dome stays inside fogStart.
        domeNode.position = SCNVector3(Float(airport.towerCabEye.x), 0, Float(airport.towerCabEye.z))
        domeNode.renderingOrder = -1000
        domeNode.castsShadow = false
        scene.rootNode.addChildNode(domeNode)

        // --- Sun key light ---
        sunLight = SCNLight()
        sunLight.type = .directional
        sunLight.castsShadow = true
        sunLight.shadowMapSize = CGSize(width: 2048, height: 2048)
        sunLight.shadowSampleCount = 8
        sunLight.shadowRadius = 3
        sunLight.shadowColor = UIColor(white: 0, alpha: 0.52)   // lifted, never crushed
        sunLight.shadowBias = 2
        sunLight.automaticallyAdjustsShadowProjection = false
        sunLight.orthographicScale = 760                        // covers runway + apron + rim
        sunLight.zNear = 1
        sunLight.zFar = 9000
        sunNode = SCNNode()
        sunNode.name = "sun"
        sunNode.light = sunLight
        scene.rootNode.addChildNode(sunNode)

        // --- Cool sky fill (opposite the sun, no shadows) ---
        fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.castsShadow = false
        fillLight.color = worldColor(0.52, 0.62, 0.88)
        fillNode = SCNNode()
        fillNode.name = "skyFill"
        fillNode.light = fillLight
        scene.rootNode.addChildNode(fillNode)

        // --- Ambient (high — this is a warm game) ---
        ambientLight = SCNLight()
        ambientLight.type = .ambient
        let ambientNode = SCNNode()
        ambientNode.name = "ambient"
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        // --- Fog: warm, exaggerated ~2× physical for painterly depth ---
        scene.fogStartDistance = 4200
        scene.fogEndDistance = 32_000
        scene.fogDensityExponent = 1.0
        scene.background.contents = worldColor(0.18, 0.14, 0.20)

        setTime(hourOfDay: 17.5)
    }

    // MARK: SkyDirector

    func setTime(hourOfDay: Double) {
        let hour = min(max(hourOfDay, keyHours.first!), keyHours.last!)
        var state = keyStates[0]
        for i in 0..<(keyHours.count - 1) where hour >= keyHours[i] {
            let t = (hour - keyHours[i]) / (keyHours[i + 1] - keyHours[i])
            state = SkyState.lerp(keyStates[i], keyStates[i + 1], min(max(t, 0), 1))
        }

        // Sun geometry: ~14° WSW at 17:30, horizon at 18:10, below after.
        let elevationDeg: Double
        if hour <= GoldenHourSky.sunsetHour {
            elevationDeg = 14.0 * (GoldenHourSky.sunsetHour - hour) / (GoldenHourSky.sunsetHour - 17.5)
        } else {
            elevationDeg = -9.0 * (hour - GoldenHourSky.sunsetHour) / 0.5833
        }
        let azimuthDeg = 247.0 + (hour - 17.5) * 12.0
        let e = degToRad(elevationDeg), a = degToRad(azimuthDeg)
        let sunDir = SIMD3<Float>(Float(sin(a) * cos(e)), Float(sin(e)), Float(-cos(a) * cos(e)))

        // Per-frame (allocation-free): transforms + scalar intensities.
        sunNode.simdPosition = sunDir * 2600
        sunNode.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: -sunDir)
        // Below the horizon the key dies smoothly; ambient/fill carry the scene.
        let horizonFade = worldSmoothstep(-2.5, 1.5, elevationDeg)
        sunLight.intensity = CGFloat(state.sunIntensity * (0.25 + 0.75 * horizonFade))
        ambientLight.intensity = CGFloat(state.ambientIntensity)
        fillLight.intensity = CGFloat(state.fillIntensity)
        let fillDir = SIMD3<Float>(-sunDir.x, 0.55, -sunDir.z)
        fillNode.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: simd_normalize(-fillDir))
        scene.fogEndDistance = CGFloat(state.fogEnd)
        bank.update(hour: hour)

        // Bucketed (boxes values; ~1.7 Hz real time, visually continuous).
        let colorBucket = Int(hour * 500)
        if colorBucket != lastColorBucket {
            lastColorBucket = colorBucket
            sunLight.color = color(state.sunColor)
            ambientLight.color = color(state.ambientColor)
            scene.fogColor = color(state.fog * 0.97)
            setDome("skyHorizon", state.horizon)
            setDome("skyMid", state.mid)
            setDome("skyZenith", state.zenith)
            setDome("sunTint", SIMD3(state.sunColor.x, state.sunColor.y, state.sunColor.z))
            domeMaterial.setValue(NSValue(scnVector3: SCNVector3(sunDir.x, sunDir.y, sunDir.z)),
                                  forKey: "sunDirWorld")
            domeMaterial.setValue(NSNumber(value: cos(degToRad(0.95))), forKey: "sunDiscCos")
            domeMaterial.setValue(NSNumber(value: state.haloPow), forKey: "haloPow")
            domeMaterial.setValue(NSNumber(value: state.haloGain), forKey: "haloGain")
            domeMaterial.setValue(NSNumber(value: state.discGain), forKey: "discGain")
        }

        // Environment light: tiny equirect gradient, refreshed every ~3.6 s real.
        let envBucket = Int(hour * 100)
        if envBucket != lastEnvBucket {
            lastEnvBucket = envBucket
            scene.lightingEnvironment.contents = GoldenHourSky.environmentImage(
                zenith: state.zenith, mid: state.mid, horizon: state.horizon,
                sunColor: state.sunColor, sunAzimuthDeg: azimuthDeg,
                sunBoost: 0.9 * max(0, horizonFade))
            scene.lightingEnvironment.intensity = CGFloat(state.envIntensity)
        }
    }

    /// The world look owns the full camera grade — HDR, bloom, SSAO, vignette,
    /// fringe, saturation/contrast, grain, and the clip range for a 30 km world.
    func configure(camera: SCNCamera) {
        camera.zNear = 0.25
        camera.zFar = 60_000
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.22
        camera.averageGray = 0.18
        camera.whitePoint = 1.05
        camera.bloomThreshold = 1.35   // whites must not glow — bloom is for lights and sun
        camera.bloomIntensity = 0.5
        camera.bloomBlurRadius = 14
        camera.screenSpaceAmbientOcclusionIntensity = 0.7
        camera.screenSpaceAmbientOcclusionRadius = 4
        camera.vignettingPower = 1.0
        camera.vignettingIntensity = 0.55
        camera.colorFringeStrength = 0.7
        camera.colorFringeIntensity = 0.35
        camera.saturation = 1.06
        camera.contrast = 0.05
        camera.grainIntensity = 0.07
        camera.grainScale = 1.6
        camera.grainIsColored = false
    }

    // MARK: Helpers

    private func color(_ v: SIMD3<Double>) -> UIColor {
        worldColor(min(v.x, 1), min(v.y, 1), min(v.z, 1))
    }

    private func setDome(_ key: String, _ v: SIMD3<Double>) {
        domeMaterial.setValue(NSValue(scnVector3: SCNVector3(Float(v.x), Float(v.y), Float(v.z))),
                              forKey: key)
    }

    /// Gradient sky with sun disc + halo, evaluated per pixel on the dome.
    /// Uniforms only — no texture ever regenerates for the sky itself.
    private static let domeShader = """
    #pragma arguments
    float3 skyZenith;
    float3 skyMid;
    float3 skyHorizon;
    float3 sunDirWorld;
    float3 sunTint;
    float sunDiscCos;
    float haloPow;
    float haloGain;
    float discGain;
    #pragma body
    float3 wp = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    float3 camPos = scn_frame.inverseViewTransform[3].xyz;
    float3 dir = normalize(wp - camPos);
    float yy = clamp(dir.y, -0.05, 1.0);
    float t = pow(clamp(yy * 1.06 + 0.035, 0.0, 1.0), 0.44);
    float3 sky = mix(skyHorizon, skyMid, smoothstep(0.02, 0.45, t));
    sky = mix(sky, skyZenith, smoothstep(0.38, 1.0, t));
    float c = clamp(dot(dir, sunDirWorld), 0.0, 1.0);
    float halo = pow(c, haloPow) * haloGain;
    float wide = pow(c, 5.0) * 0.13;
    float disc = smoothstep(sunDiscCos - 0.00040, sunDiscCos + 0.00040, c) * discGain;
    float3 col = sky + sunTint * (halo + wide + disc);
    _output.color = float4(col, 1.0);
    """

    /// 64×32 equirect gradient so PBR gets warm sky bounce (cheap, bucketed).
    private static func environmentImage(zenith: SIMD3<Double>, mid: SIMD3<Double>,
                                         horizon: SIMD3<Double>, sunColor: SIMD3<Double>,
                                         sunAzimuthDeg: Double, sunBoost: Double) -> CGImage? {
        let w = 64, h = 32
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        // Equirect: image center column ≈ -Z (north); azimuth increases eastward.
        let sunU = (sunAzimuthDeg / 360.0) + 0.5
        for y in 0..<h {
            let v = Double(y) / Double(h - 1)          // 0 = up, 1 = down
            let elevation = 90.0 - v * 180.0
            var base: SIMD3<Double>
            if elevation >= 0 {
                let t = pow(elevation / 90.0, 0.55)
                base = t < 0.5 ? horizon + (mid - horizon) * (t * 2)
                               : mid + (zenith - mid) * ((t - 0.5) * 2)
            } else {
                let t = min(1, -elevation / 40.0)
                base = horizon * 0.55 + (SIMD3(0.05, 0.13, 0.16) - horizon * 0.55) * t
            }
            for x in 0..<w {
                let u = Double(x) / Double(w - 1)
                var du = abs(u - sunU)
                du = min(du, 1 - du)
                let azFall = exp(-du * du * 90.0)
                let elFall = exp(-pow((elevation - 8.0) / 26.0, 2))
                let warm = sunColor * (sunBoost * azFall * elFall)
                var c = base + warm
                let i = (y * w + x) * 4
                c = SIMD3(min(c.x, 1), min(c.y, 1), min(c.z, 1))
                bytes[i] = UInt8(pow(c.x, 1 / 2.2) * 255)
                bytes[i + 1] = UInt8(pow(c.y, 1 / 2.2) * 255)
                bytes[i + 2] = UInt8(pow(c.z, 1 / 2.2) * 255)
            }
        }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}
