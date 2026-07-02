import Foundation
import SceneKit

// =============================================================================
// World-building contract — "Luminous Diorama" (PRD §6).
//
// WorldBuilder.build() assembles the entire static scene: sky + sun rig,
// Catalina mesa + Pacific, runway/taxiways/apron with markings, tower + cab
// interior frame, and returns the attachment points the game loop needs.
// AircraftModelFactory mints one node per aircraft kind; AircraftEntity
// animates it from AircraftRenderState each frame.
// =============================================================================

public struct WorldAttachments {
    public let scene: SCNScene
    /// Parent for all aircraft entities.
    public let aircraftContainer: SCNNode
    /// Where the camera lives — positioned at AirportLayout.towerCabEye.
    /// The camera node itself is added by CameraRig; this is its mount.
    /// The cab interior (CabInteriorBuilder) is attached here at integration.
    public let cabMount: SCNNode
    /// Drives time-of-day (12x during shifts, §6.4).
    public let sky: SkyDirector

    public init(scene: SCNScene, aircraftContainer: SCNNode, cabMount: SCNNode, sky: SkyDirector) {
        self.scene = scene
        self.aircraftContainer = aircraftContainer
        self.cabMount = cabMount
        self.sky = sky
    }
}

/// Owns the sun, sky, fog, and grade for a continuously moving golden hour.
public protocol SkyDirector: AnyObject {
    /// hourOfDay in [0, 24). The slice plays 17:30 → ~18:45 at 12x.
    func setTime(hourOfDay: Double)
    /// One-time hook: the world look owns exposure/HDR/bloom/grade on the camera.
    func configure(camera: SCNCamera)
}

public enum WorldBuilder {
    /// Implemented by the world subsystem (Terrain/AirportGeometry/SkyLighting).
    public static func build(airport: AirportLayout) -> WorldAttachments {
        buildWorldImpl(airport: airport)
    }
}

/// One live aircraft in the scene. Created via AircraftModelFactory.
public protocol AircraftEntity: AnyObject {
    var node: SCNNode { get }
    /// Called every frame with the interpolated sim state (world coords).
    func update(_ state: AircraftRenderState, dt: TimeInterval)
}

public enum AircraftModelFactory {
    /// Implemented by the aircraft subsystem (AircraftModels.swift).
    public static func make(kind: AircraftKind, livery: Livery) -> AircraftEntity {
        makeAircraftImpl(kind: kind, livery: livery)
    }
}

public enum CabInteriorBuilder {
    /// The tower cab interior — STATIC geometry surrounding the camera eye
    /// (origin = eye position; camera pans inside it, so mullions/console
    /// parallax naturally). Implemented by the aircraft/cab subsystem.
    public static func build() -> SCNNode {
        buildCabInteriorImpl()
    }
}
