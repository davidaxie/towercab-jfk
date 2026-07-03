import Foundation
import SceneKit
import UIKit
import simd

// =============================================================================
// Cab cam (PRD §6.3) — pan/zoom with tuned inertia, 20°–110° FOV, strip-snap
// framing, pinch-about-centroid, and a two-finger double-tap home pose.
// The cab is the only viewpoint; no cuts.
// =============================================================================

final class CameraRig: NSObject {

    let cameraNode = SCNNode()
    private weak var view: SCNView?
    private let eye: V3

    // Look state (radians). Yaw 0 = -Z (north), positive clockwise.
    private var yaw: Double = 0
    private var pitch: Double = -0.06
    private var yawVelocity: Double = 0
    private var pitchVelocity: Double = 0
    private var fov: Double = 58

    // C16: up-clamp raised so the roofline, not the console, sets the limit.
    private let pitchRange = (-0.62)...(0.55)
    private let fovRange = 20.0...110.0

    // Strip-snap animation (C15: pure lerp of an eased t from a captured pose).
    private struct Pose { var yaw: Double; var pitch: Double; var fov: Double }
    private var snapStart: Pose?
    private var snapTarget: Pose?
    private var snapProgress: Double = 0

    private var homePose: Pose
    private var debugPosed = false

    init(airport: AirportLayout, mount: SCNNode) {
        self.eye = airport.towerCabEye

        // C9: the first frame is the approach corridor — runway sweeping the
        // lower third, ocean horizon and the inbound final as the hero.
        let approachDir = -airport.runway.dir22          // out over the water, NE
        let corridor2D = airport.runway.thresholdB + approachDir * 800
        let target = V3(corridor2D.x, 120, corridor2D.y)
        let d = target - eye
        let yaw0 = atan2(d.x, -d.z)
        let pitch0 = atan2(d.y, simd_length(SIMD2(d.x, d.z)))
        homePose = Pose(yaw: yaw0, pitch: min(max(pitch0, -0.62), 0.55), fov: 58)

        super.init()

        let camera = SCNCamera()
        camera.zNear = 0.35
        camera.zFar = 60000
        camera.fieldOfView = CGFloat(fov)
        cameraNode.camera = camera
        mount.addChildNode(cameraNode)

        yaw = homePose.yaw
        pitch = homePose.pitch
        fov = homePose.fov
        apply()
    }

    var camera: SCNCamera? { cameraNode.camera }

    func attachGestures(to view: SCNView) {
        self.view = view
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinch)
        // C26: two-finger double-tap = camera home (the panic gesture).
        let home = UITapGestureRecognizer(target: self, action: #selector(handleHomeTap(_:)))
        home.numberOfTapsRequired = 2
        home.numberOfTouchesRequired = 2
        view.addGestureRecognizer(home)
    }

    // MARK: - Per-frame

    func update(dt: Double) {
        if let start = snapStart, let target = snapTarget {
            snapProgress = min(1, snapProgress + dt / 0.4)   // 400 ms ease (PRD §2.3)
            let e = 1 - pow(1 - snapProgress, 3)
            yaw = start.yaw + angleDelta(from: start.yaw, to: target.yaw) * e
            pitch = start.pitch + (target.pitch - start.pitch) * e
            fov = start.fov + (target.fov - start.fov) * e
            if snapProgress >= 1 { snapStart = nil; snapTarget = nil }
        } else {
            // Flick-pan glides ~0.6 s to rest.
            yaw += yawVelocity * dt
            pitch += pitchVelocity * dt
            let damp = exp(-dt * 5.2)
            yawVelocity *= damp
            pitchVelocity *= damp
        }
        if !debugPosed {
            pitch = min(max(pitch, pitchRange.lowerBound), pitchRange.upperBound)
        }
        apply()
    }

    private func apply() {
        cameraNode.eulerAngles = SCNVector3(Float(pitch), Float(-yaw), 0)
        cameraNode.camera?.fieldOfView = CGFloat(fov)
    }

    /// Swing-and-frame a world point (re-tap of a selected strip, PRD §2.3).
    /// C6: zoom derives from the subtended size of the target, clamped so an
    /// airborne aircraft fills a readable fraction of the frame.
    func frame(worldPoint p: V3, targetSpan: Double = 12) {
        let d = p - eye
        let dist = max(simd_length(d), 40)
        let targetYaw = atan2(d.x, -d.z)
        let targetPitch = min(max(atan2(d.y, simd_length(SIMD2(d.x, d.z))),
                                  pitchRange.lowerBound), pitchRange.upperBound)
        let subtended = 2 * atan((targetSpan * 6) / (2 * dist)) * 180 / .pi
        let targetFov = min(max(subtended, 9), 55)
        beginSnap(to: Pose(yaw: targetYaw, pitch: targetPitch, fov: targetFov))
    }

    func goHome() {
        beginSnap(to: homePose)
    }

    /// True when the world point projects inside the view frustum (in front of
    /// the camera and on-screen with margin). Used to decide bloom anchoring.
    func isOnScreen(_ p: V3, in view: SCNView, margin: CGFloat = 60) -> Bool {
        let v = view.projectPoint(SCNVector3(p.x, p.y, p.z))
        guard v.z > 0 && v.z < 1 else { return false }
        let b = view.bounds.insetBy(dx: -margin, dy: -margin)
        return b.contains(CGPoint(x: CGFloat(v.x), y: CGFloat(v.y)))
    }

    private func beginSnap(to target: Pose) {
        snapStart = Pose(yaw: yaw, pitch: pitch, fov: fov)
        snapTarget = target
        snapProgress = 0
        yawVelocity = 0
        pitchVelocity = 0
    }

    /// Debug/screenshot pose (degrees). Debug poses may exceed the play clamp.
    func setPose(yawDeg: Double?, pitchDeg: Double?, fovDeg: Double?) {
        if let y = yawDeg { yaw = degToRad(y) }
        if let p = pitchDeg { pitch = min(max(degToRad(p), -1.55), 1.55); debugPosed = true }
        if let f = fovDeg { fov = min(max(f, fovRange.lowerBound), fovRange.upperBound) }
        yawVelocity = 0; pitchVelocity = 0
        snapStart = nil; snapTarget = nil
        apply()
    }

    // MARK: - Gestures

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let view = view else { return }
        snapStart = nil; snapTarget = nil
        let radPerPoint = degToRad(fov) / Double(view.bounds.height)
        switch g.state {
        case .changed:
            let t = g.translation(in: view)
            yaw -= Double(t.x) * radPerPoint
            pitch += Double(t.y) * radPerPoint
            pitch = min(max(pitch, pitchRange.lowerBound), pitchRange.upperBound)
            g.setTranslation(.zero, in: view)
            yawVelocity = 0; pitchVelocity = 0
            apply()
        case .ended:
            let v = g.velocity(in: view)
            yawVelocity = -Double(v.x) * radPerPoint
            pitchVelocity = Double(v.y) * radPerPoint
        default: break
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard g.state == .changed, let view = view else { return }
        snapStart = nil; snapTarget = nil
        let oldFov = fov
        fov = min(max(fov / Double(g.scale), fovRange.lowerBound), fovRange.upperBound)
        // C17: keep the point under the fingers fixed — shift look by the
        // centroid's angular offset scaled by the FOV change.
        let c = g.location(in: view)
        let radPerPointOld = degToRad(oldFov) / Double(view.bounds.height)
        let dx = Double(c.x - view.bounds.midX)
        let dy = Double(c.y - view.bounds.midY)
        let k = 1 - fov / oldFov
        yaw += dx * radPerPointOld * k
        pitch -= dy * radPerPointOld * k
        pitch = min(max(pitch, pitchRange.lowerBound), pitchRange.upperBound)
        g.scale = 1
        apply()
    }

    @objc private func handleHomeTap(_ g: UITapGestureRecognizer) {
        goHome()
    }
}
