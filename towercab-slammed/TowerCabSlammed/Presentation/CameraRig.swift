import Foundation
import SceneKit
import UIKit

// =============================================================================
// Cab cam (PRD §6.3) — pan/zoom with tuned inertia, 20°–110° FOV, plus
// strip-snap framing. The cab is the only viewpoint; no cuts.
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
    private var fov: Double = 62

    private let pitchRange = (-0.62)...(0.42)     // don't stare at the console or the sky
    private let fovRange = 20.0...110.0

    // Strip-snap animation
    private var snapTarget: (yaw: Double, pitch: Double, fov: Double)?
    private var snapProgress: Double = 0

    init(airport: AirportLayout, mount: SCNNode) {
        self.eye = airport.towerCabEye
        super.init()

        let camera = SCNCamera()
        camera.zNear = 0.35
        camera.zFar = 30000
        camera.fieldOfView = CGFloat(fov)
        cameraNode.camera = camera
        mount.addChildNode(cameraNode)

        // Default: look at the runway midpoint.
        let target = V3(0, 0, 0)
        let d = target - eye
        yaw = atan2(d.x, -d.z)
        pitch = atan2(d.y, simd_length(SIMD2(d.x, d.z))) * 0.6
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
    }

    // MARK: - Per-frame

    func update(dt: Double) {
        if var t = snapTarget {
            snapProgress = min(1, snapProgress + dt / 0.4)   // 400 ms ease (PRD §2.3)
            let e = 1 - pow(1 - snapProgress, 3)
            yaw += angleDelta(from: yaw, to: t.yaw) * e
            pitch += (t.pitch - pitch) * e
            fov += (t.fov - fov) * e
            if snapProgress >= 1 { snapTarget = nil }
            t = (yaw, pitch, fov)
        } else {
            // Flick-pan glides ~0.6 s to rest.
            yaw += yawVelocity * dt
            pitch += pitchVelocity * dt
            let damp = exp(-dt * 5.2)
            yawVelocity *= damp
            pitchVelocity *= damp
        }
        pitch = min(max(pitch, pitchRange.lowerBound), pitchRange.upperBound)
        apply()
    }

    private func apply() {
        cameraNode.eulerAngles = SCNVector3(Float(pitch), Float(-yaw), 0)
        cameraNode.camera?.fieldOfView = CGFloat(fov)
    }

    /// Debug/screenshot pose (degrees). Yaw uses the world heading convention.
    func setPose(yawDeg: Double?, pitchDeg: Double?, fovDeg: Double?) {
        if let y = yawDeg { yaw = degToRad(y) }
        if let p = pitchDeg { pitch = min(max(degToRad(p), pitchRange.lowerBound), pitchRange.upperBound) }
        if let f = fovDeg { fov = min(max(f, fovRange.lowerBound), fovRange.upperBound) }
        yawVelocity = 0; pitchVelocity = 0
        snapTarget = nil
        apply()
    }

    /// Swing-and-frame an aircraft (double-tap a strip, PRD §2.3).
    func frame(worldPoint p: V3) {
        let d = p - eye
        let targetYaw = atan2(d.x, -d.z)
        let dist = simd_length(SIMD2(d.x, d.z))
        let targetPitch = atan2(d.y, dist)
        let targetFov = min(max(18_00.0 / max(dist, 60), 24), 55)  // closer = wider
        snapTarget = (targetYaw, targetPitch, targetFov)
        snapProgress = 0
    }

    // MARK: - Gestures

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let view = view else { return }
        snapTarget = nil
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
        guard g.state == .changed else { return }
        snapTarget = nil
        fov = min(max(fov / Double(g.scale), fovRange.lowerBound), fovRange.upperBound)
        g.scale = 1
        apply()
    }
}
