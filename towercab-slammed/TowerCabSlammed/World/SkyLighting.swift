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
// The dome sits INSIDE fogStartDistance (radius 1.35 km around the static cab,
// fog starts at 1.4 km) with depth writes off and renderingOrder -1000, so
// scene fog never eats the sky; distant ocean/terrain instead fog out toward
// the dome's horizon color itself (D8) — a seamless painted horizon.
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

    // Optional cool-white fill from the rising moon at dusk (scoped, no shadow).
    private let moonLight: SCNLight
    private let moonNode: SCNNode

    // Marine-layer slabs handed over by the world builder so the sky can tint them
    // to golden hour each color bucket (they are otherwise flat cold-white).
    private var marineLayerMaterials: [SCNMaterial] = []

    // MARK: Palette keyframes

    private struct SkyState {
        var sunColor: SIMD3<Double>
        var sunIntensity: Double
        var horizon: SIMD3<Double>
        var mid: SIMD3<Double>
        var upperMid: SIMD3<Double>   // 4th stop between mid and zenith (kills the flat top)
        var zenith: SIMD3<Double>
        var ambientColor: SIMD3<Double>
        var ambientIntensity: Double
        var fillIntensity: Double
        var fogEnd: Double
        var discGain: Double
        var haloGain: Double
        var haloPow: Double
        var envIntensity: Double
        // New look drivers (all lerped, all feed shader uniforms):
        var horizonGlow: Double       // 360° warm low-sky band strength
        var hazeColor: SIMD3<Double>  // luminous atmospheric band over the sea
        var hazeGain: Double
        var cloudLit: SIMD3<Double>   // warm-lit cloud tops/bellies near the sun
        var cloudShadow: SIMD3<Double> // cool cloud undersides away from the sun
        var cloudGain: Double         // overall cloud coverage/opacity
        var starGain: Double          // emerging dusk stars
        var moonColor: SIMD3<Double>
        var moonGain: Double

        static func lerp(_ a: SkyState, _ b: SkyState, _ t: Double) -> SkyState {
            func m(_ x: SIMD3<Double>, _ y: SIMD3<Double>) -> SIMD3<Double> { x + (y - x) * t }
            func s(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
            return SkyState(sunColor: m(a.sunColor, b.sunColor),
                            sunIntensity: s(a.sunIntensity, b.sunIntensity),
                            horizon: m(a.horizon, b.horizon),
                            mid: m(a.mid, b.mid),
                            upperMid: m(a.upperMid, b.upperMid),
                            zenith: m(a.zenith, b.zenith),
                            ambientColor: m(a.ambientColor, b.ambientColor),
                            ambientIntensity: s(a.ambientIntensity, b.ambientIntensity),
                            fillIntensity: s(a.fillIntensity, b.fillIntensity),
                            fogEnd: s(a.fogEnd, b.fogEnd),
                            discGain: s(a.discGain, b.discGain),
                            haloGain: s(a.haloGain, b.haloGain),
                            haloPow: s(a.haloPow, b.haloPow),
                            envIntensity: s(a.envIntensity, b.envIntensity),
                            horizonGlow: s(a.horizonGlow, b.horizonGlow),
                            hazeColor: m(a.hazeColor, b.hazeColor),
                            hazeGain: s(a.hazeGain, b.hazeGain),
                            cloudLit: m(a.cloudLit, b.cloudLit),
                            cloudShadow: m(a.cloudShadow, b.cloudShadow),
                            cloudGain: s(a.cloudGain, b.cloudGain),
                            starGain: s(a.starGain, b.starGain),
                            moonColor: m(a.moonColor, b.moonColor),
                            moonGain: s(a.moonGain, b.moonGain))
        }
    }

    // Golden hour → orange-rose sunset → violet dusk.
    // D6: 17:30 is genuinely GOLDEN (warm mid, warmer ambient, hotter sun).
    // D9: aerial haze doubled — fogEnd 18 km day → 14 km dusk (start 1.4 km).
    // D10: dusk ambient floor lifted (never crushed): 18.45 → 430, 18.80 → 380,
    //      fill floor 100.
    private let keyHours: [Double] = [17.30, 17.90, 18.17, 18.45, 18.80]
    private let keyStates: [SkyState] = [
        // 17:30 — full golden hour. Warm all around the low sky, deepening blue up
        // top, soft coral-lit clouds. Sun high enough (~14°) that clouds barely glow.
        SkyState(sunColor: SIMD3(1.00, 0.82, 0.55), sunIntensity: 1750,
                 horizon: SIMD3(1.02, 0.80, 0.54), mid: SIMD3(0.72, 0.62, 0.55),
                 upperMid: SIMD3(0.50, 0.55, 0.66), zenith: SIMD3(0.30, 0.44, 0.70),
                 ambientColor: SIMD3(0.66, 0.64, 0.74), ambientIntensity: 400, fillIntensity: 170,
                 fogEnd: 18_000,
                 discGain: 1.25, haloGain: 0.60, haloPow: 30, envIntensity: 1.15,
                 horizonGlow: 0.16,
                 hazeColor: SIMD3(1.00, 0.86, 0.68), hazeGain: 0.28,
                 cloudLit: SIMD3(1.02, 0.90, 0.74), cloudShadow: SIMD3(0.62, 0.60, 0.66),
                 cloudGain: 0.55,
                 starGain: 0.0, moonColor: SIMD3(0.80, 0.82, 0.90), moonGain: 0.0),
        // 17:54 — golden deepening to amber. Clouds start catching warm underlight.
        SkyState(sunColor: SIMD3(1.00, 0.68, 0.42), sunIntensity: 1250,
                 horizon: SIMD3(1.05, 0.68, 0.42), mid: SIMD3(0.74, 0.52, 0.52),
                 upperMid: SIMD3(0.44, 0.42, 0.60), zenith: SIMD3(0.20, 0.30, 0.60),
                 ambientColor: SIMD3(0.62, 0.60, 0.78), ambientIntensity: 420, fillIntensity: 150,
                 fogEnd: 17_000,
                 discGain: 1.20, haloGain: 0.72, haloPow: 22, envIntensity: 1.05,
                 horizonGlow: 0.24,
                 hazeColor: SIMD3(1.04, 0.76, 0.54), hazeGain: 0.34,
                 cloudLit: SIMD3(1.06, 0.78, 0.54), cloudShadow: SIMD3(0.54, 0.48, 0.58),
                 cloudGain: 0.62,
                 starGain: 0.0, moonColor: SIMD3(0.82, 0.83, 0.90), moonGain: 0.0),
        // 18:10 — sunset, sun on the horizon. Peak coral/rose. Cloud bellies blaze.
        SkyState(sunColor: SIMD3(1.00, 0.50, 0.30), sunIntensity: 620,
                 horizon: SIMD3(1.02, 0.55, 0.38), mid: SIMD3(0.68, 0.40, 0.52),
                 upperMid: SIMD3(0.36, 0.30, 0.54), zenith: SIMD3(0.15, 0.19, 0.48),
                 ambientColor: SIMD3(0.58, 0.55, 0.77), ambientIntensity: 400, fillIntensity: 125,
                 fogEnd: 16_000,
                 discGain: 1.10, haloGain: 0.85, haloPow: 16, envIntensity: 0.92,
                 horizonGlow: 0.32,
                 hazeColor: SIMD3(1.02, 0.60, 0.44), hazeGain: 0.40,
                 cloudLit: SIMD3(1.08, 0.62, 0.42), cloudShadow: SIMD3(0.44, 0.36, 0.50),
                 cloudGain: 0.66,
                 starGain: 0.04, moonColor: SIMD3(0.84, 0.84, 0.92), moonGain: 0.10),
        // 18:27 — afterglow. Sun just below; warm band lingers, first stars, low moon.
        SkyState(sunColor: SIMD3(1.00, 0.44, 0.36), sunIntensity: 90,
                 horizon: SIMD3(0.78, 0.42, 0.46), mid: SIMD3(0.44, 0.30, 0.48),
                 upperMid: SIMD3(0.24, 0.20, 0.42), zenith: SIMD3(0.11, 0.13, 0.34),
                 ambientColor: SIMD3(0.60, 0.52, 0.72), ambientIntensity: 430, fillIntensity: 110,
                 fogEnd: 15_000,
                 discGain: 0.45, haloGain: 0.62, haloPow: 13, envIntensity: 0.74,
                 horizonGlow: 0.28,
                 hazeColor: SIMD3(0.86, 0.48, 0.46), hazeGain: 0.36,
                 cloudLit: SIMD3(0.86, 0.48, 0.42), cloudShadow: SIMD3(0.30, 0.26, 0.40),
                 cloudGain: 0.60,
                 starGain: 0.34, moonColor: SIMD3(0.86, 0.86, 0.94), moonGain: 0.42),
        // 18:48 — dusk. Violet zenith, faint warm rim on the water, stars + soft moon.
        SkyState(sunColor: SIMD3(1.00, 0.42, 0.38), sunIntensity: 0,
                 horizon: SIMD3(0.55, 0.34, 0.44), mid: SIMD3(0.30, 0.24, 0.42),
                 upperMid: SIMD3(0.17, 0.16, 0.34), zenith: SIMD3(0.10, 0.11, 0.28),
                 ambientColor: SIMD3(0.58, 0.52, 0.74), ambientIntensity: 380, fillIntensity: 100,
                 fogEnd: 14_000,
                 discGain: 0.0, haloGain: 0.34, haloPow: 11, envIntensity: 0.60,
                 horizonGlow: 0.20,
                 hazeColor: SIMD3(0.60, 0.40, 0.48), hazeGain: 0.30,
                 cloudLit: SIMD3(0.52, 0.38, 0.46), cloudShadow: SIMD3(0.20, 0.19, 0.32),
                 cloudGain: 0.50,
                 starGain: 0.62, moonColor: SIMD3(0.88, 0.88, 0.96), moonGain: 0.60),
    ]

    // MARK: Init

    init(scene: SCNScene, airport: AirportLayout, bank: AirfieldLightBank) {
        self.scene = scene
        self.bank = bank

        // --- Sky dome (inside fogStart 1400 so fog never eats the sky) ---
        let dome = SCNSphere(radius: 1350)
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

        // --- Moon fill (cool, faint, no shadow) — fades in only at dusk ---
        moonLight = SCNLight()
        moonLight.type = .directional
        moonLight.castsShadow = false
        moonLight.color = worldColor(0.62, 0.70, 0.92)
        moonLight.intensity = 0
        moonNode = SCNNode()
        moonNode.name = "moon"
        moonNode.light = moonLight
        scene.rootNode.addChildNode(moonNode)

        // --- Fog: warm, exaggerated ~2× physical for painterly depth (D9) ---
        scene.fogStartDistance = 1400
        scene.fogEndDistance = 18_000
        // D9b: softer distance rolloff over the ocean so the haze band reads as depth.
        scene.fogDensityExponent = 1.3
        scene.background.contents = worldColor(0.18, 0.14, 0.20)

        // Constant sun-disc angular size — set ONCE (it never changes).
        // ~0.72° stylized radius: large enough to read, small enough to feel real
        // now that a proper soft limb + bloom sells the glow.
        domeMaterial.setValue(NSNumber(value: cos(degToRad(0.72))), forKey: "sunDiscCos")
        // Constant moon-disc size (a touch larger than the sun for the low dusk moon).
        domeMaterial.setValue(NSNumber(value: cos(degToRad(0.90))), forKey: "moonDiscCos")

        setTime(hourOfDay: 17.5)
    }

    // MARK: World-builder hook

    /// The world builder hands over the marine-layer slab materials so the sky can
    /// tint them to golden hour every color bucket (otherwise they stay flat white).
    /// Purely a look hook — safe to skip; the sky degrades gracefully without it.
    func registerMarineLayer(materials: [SCNMaterial]) {
        marineLayerMaterials = materials
        lastColorBucket = Int.min   // force a tint on the next setTime()
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

        // Moon: low in the ESE (opposite quadrant from the WSW sunset), rising
        // slowly through dusk. Geometry is a pure function of `hour` (deterministic).
        let moonElevDeg = 6.0 + (hour - 17.5) * 5.0        // ~6° → ~13° over the slice
        let moonAzDeg = 108.0 + (hour - 17.5) * 3.0         // ESE, drifting east
        let me = degToRad(moonElevDeg), ma = degToRad(moonAzDeg)
        let moonDir = SIMD3<Float>(Float(sin(ma) * cos(me)), Float(sin(me)), Float(-cos(ma) * cos(me)))
        moonNode.simdPosition = moonDir * 2500
        moonNode.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: -moonDir)
        moonLight.intensity = CGFloat(state.moonGain * 55.0)

        // Cloud drift: a slow, wrapping phase from the sim clock (12× real). Feeding
        // the hour keeps it deterministic and frame-rate independent.
        domeMaterial.setValue(NSNumber(value: (hour - 17.5) * 0.16), forKey: "cloudTime")

        // Bucketed (boxes values; ~1.7 Hz real time, visually continuous).
        let colorBucket = Int(hour * 500)
        if colorBucket != lastColorBucket {
            lastColorBucket = colorBucket
            sunLight.color = color(state.sunColor)
            ambientLight.color = color(state.ambientColor)
            moonLight.color = color(state.moonColor)
            // D8: fog IS the dome horizon color — a seamless painted horizon.
            scene.fogColor = color(state.horizon)
            setDome("skyHorizon", state.horizon)
            setDome("skyMid", state.mid)
            setDome("skyUpperMid", state.upperMid)
            setDome("skyZenith", state.zenith)
            setDome("sunTint", SIMD3(state.sunColor.x, state.sunColor.y, state.sunColor.z))
            setDome("hazeColor", state.hazeColor)
            setDome("cloudLit", state.cloudLit)
            setDome("cloudShadow", state.cloudShadow)
            setDome("moonTint", state.moonColor)
            domeMaterial.setValue(NSValue(scnVector3: SCNVector3(sunDir.x, sunDir.y, sunDir.z)),
                                  forKey: "sunDirWorld")
            domeMaterial.setValue(NSValue(scnVector3: SCNVector3(moonDir.x, moonDir.y, moonDir.z)),
                                  forKey: "moonDirWorld")
            domeMaterial.setValue(NSNumber(value: state.haloPow), forKey: "haloPow")
            domeMaterial.setValue(NSNumber(value: state.haloGain), forKey: "haloGain")
            // Disc dies with the sun's GEOMETRY (horizonFade), not an arbitrary
            // keyframe — so a warm reddened disc survives the horizon kiss.
            domeMaterial.setValue(NSNumber(value: state.discGain * (0.35 + 0.65 * horizonFade)),
                                  forKey: "discGain")
            domeMaterial.setValue(NSNumber(value: state.horizonGlow), forKey: "horizonGlow")
            domeMaterial.setValue(NSNumber(value: state.hazeGain), forKey: "hazeGain")
            domeMaterial.setValue(NSNumber(value: state.cloudGain), forKey: "cloudGain")
            domeMaterial.setValue(NSNumber(value: state.starGain), forKey: "starGain")
            domeMaterial.setValue(NSNumber(value: state.moonGain), forKey: "moonGain")

            // Tint the offshore marine layer to the same light (if the world builder
            // handed the slabs over). Warm top-lit near sunset → cool blue-grey at dusk.
            if !marineLayerMaterials.isEmpty {
                let tint = color(SIMD3(min(state.cloudLit.x * 0.55 + state.horizon.x * 0.45, 1),
                                       min(state.cloudLit.y * 0.55 + state.horizon.y * 0.45, 1),
                                       min(state.cloudLit.z * 0.55 + state.horizon.z * 0.45, 1)))
                for m in marineLayerMaterials { m.multiply.contents = tint }
            }
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
        camera.exposureOffset = -0.12       // D6: lift out of the grey

        camera.averageGray = 0.18
        camera.whitePoint = 1.05
        camera.bloomThreshold = 1.35   // whites must not glow — bloom is for lights and sun
        camera.bloomIntensity = 0.5
        camera.bloomBlurRadius = 14
        camera.screenSpaceAmbientOcclusionIntensity = 0.7
        camera.screenSpaceAmbientOcclusionRadius = 4
        camera.vignettingPower = 1.0
        camera.vignettingIntensity = 0.55
        camera.colorFringeStrength = 0.35   // D34: halved — keep texture edges crisp
        camera.colorFringeIntensity = 0.18
        camera.saturation = 1.12            // D6: golden, not milky
        camera.contrast = 0.09
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

    /// Full golden-hour dome: 4-stop gradient + 360° warm horizon band + anti-sun
    /// counter-glow + procedural fbm clouds lit warm-from-below + a soft bloom-fed
    /// sun disc that survives the horizon kiss + a luminous sea haze band + emerging
    /// dusk stars + a low cool moon. Uniforms only — no texture ever regenerates.
    private static let domeShader = """
    #pragma arguments
    float3 skyZenith;
    float3 skyUpperMid;
    float3 skyMid;
    float3 skyHorizon;
    float3 sunDirWorld;
    float3 sunTint;
    float3 hazeColor;
    float3 cloudLit;
    float3 cloudShadow;
    float3 moonDirWorld;
    float3 moonTint;
    float sunDiscCos;
    float moonDiscCos;
    float haloPow;
    float haloGain;
    float discGain;
    float horizonGlow;
    float hazeGain;
    float cloudGain;
    float cloudTime;
    float starGain;
    float moonGain;
    #pragma body

    // --- Procedural noise: hash → value noise → 3-octave fbm, all in-shader ---
    #define SKY_HASH(p) fract(sin(dot((p), float2(127.1, 311.7))) * 43758.5453)

    float3 wp = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    float3 camPos = scn_frame.inverseViewTransform[3].xyz;
    float3 dir = normalize(wp - camPos);

    // --- 4-stop vertical gradient (horizon → mid → upperMid → zenith) ---
    float yy = clamp(dir.y, -0.05, 1.0);
    float t = pow(clamp(yy * 1.06 + 0.035, 0.0, 1.0), 0.44);
    float3 sky = mix(skyHorizon, skyMid, smoothstep(0.02, 0.34, t));
    sky = mix(sky, skyUpperMid, smoothstep(0.30, 0.66, t));
    sky = mix(sky, skyZenith, smoothstep(0.60, 1.0, t));
    // Gentle zenith deepening so the top is never a flat wash.
    sky *= mix(1.0, 0.88, smoothstep(0.55, 1.0, t));

    // --- 360° warm horizon band (independent of sun azimuth) ---
    float band = pow(1.0 - clamp(dir.y * 3.0, 0.0, 1.0), 2.0);
    sky += skyHorizon * band * horizonGlow;

    // --- Anti-sun counter-glow (the subtle opposite-horizon lift) ---
    float cc = clamp(dot(dir, -sunDirWorld), 0.0, 1.0);
    sky += skyMid * pow(cc, 4.0) * 0.06;

    // --- Luminous aerial-haze band hugging the sea horizon ---
    float haze = exp(-abs(dir.y) * 14.0) * hazeGain;
    sky = mix(sky, hazeColor, clamp(haze, 0.0, 1.0));

    // --- Procedural high clouds (upper hemisphere only, warm-lit from the sun) ---
    // Project the view direction onto a flat "cloud plane" high above; drift it.
    float above = smoothstep(0.10, 0.32, dir.y);          // fade in above the horizon
    if (above > 0.001 && cloudGain > 0.001) {
        float2 cuv = dir.xz / max(dir.y, 0.16) * 1.7;      // planar cloud coords
        cuv += float2(cloudTime, cloudTime * 0.6);         // slow drift
        // 3-octave value-noise fbm.
        float f = 0.0, amp = 0.5;
        float2 p = cuv;
        for (int o = 0; o < 3; o++) {
            float2 ip = floor(p);
            float2 fp = fract(p);
            fp = fp * fp * (3.0 - 2.0 * fp);
            float a = SKY_HASH(ip + float2(0.0, 0.0));
            float b = SKY_HASH(ip + float2(1.0, 0.0));
            float cch = SKY_HASH(ip + float2(0.0, 1.0));
            float d = SKY_HASH(ip + float2(1.0, 1.0));
            float n = mix(mix(a, b, fp.x), mix(cch, d, fp.x), fp.y);
            f += n * amp;
            p *= 2.02;
            amp *= 0.5;
        }
        // Threshold into soft mass; coverage rides cloudGain.
        float cover = smoothstep(0.52, 0.86, f) * above;
        // Warm underside where the cloud faces the sun; cool where it doesn't.
        float sunFace = clamp(dot(dir, sunDirWorld) * 0.5 + 0.5, 0.0, 1.0);
        float3 cloudCol = mix(cloudShadow, cloudLit, pow(sunFace, 1.5));
        sky = mix(sky, cloudCol, clamp(cover * cloudGain, 0.0, 0.95));
    }

    // --- Emerging dusk stars (upper hemisphere, only when starGain > 0) ---
    if (starGain > 0.001) {
        float2 suv = floor(dir.xz / max(dir.y, 0.18) * 60.0);
        float sh = SKY_HASH(suv);
        float star = step(0.985, sh) * smoothstep(0.15, 0.55, dir.y);
        // twinkle a touch by hashing a second axis (static — no per-frame shimmer)
        float bright = SKY_HASH(suv + 7.3);
        sky += float3(0.9, 0.92, 1.0) * star * starGain * (0.6 + 0.4 * bright);
    }

    // --- Sun disc: soft limb + hot core (blooms) + subtle anisotropic streak ---
    float c = clamp(dot(dir, sunDirWorld), 0.0, 1.0);
    float halo = pow(c, haloPow) * haloGain;
    float wide = pow(c, 5.0) * 0.13;
    float midHalo = pow(c, 200.0) * 0.8;
    // Vertical smear: stretch the near-sun glow along the view-up axis for a sunset streak.
    float vstreak = pow(c, 40.0) * clamp(1.0 - abs(dir.y - sunDirWorld.y) * 5.0, 0.0, 1.0) * 0.4;
    float disc = smoothstep(sunDiscCos - 0.010, sunDiscCos + 0.010, c) * discGain;
    // Hot core pushes the disc peak above bloomThreshold (1.35) so it actually blooms.
    float3 col = sky + sunTint * (halo + wide + midHalo + vstreak + disc * 1.6);

    // --- Moon disc + faint cool halo (low ESE, dusk only) ---
    if (moonGain > 0.001) {
        float mc = clamp(dot(dir, moonDirWorld), 0.0, 1.0);
        float mhalo = pow(mc, 60.0) * 0.35;
        float mdisc = smoothstep(moonDiscCos - 0.010, moonDiscCos + 0.010, mc);
        col += moonTint * (mhalo + mdisc) * moonGain;
    }

    _output.color = float4(col, 1.0);
    #undef SKY_HASH
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
