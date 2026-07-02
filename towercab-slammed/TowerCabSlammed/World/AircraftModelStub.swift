import Foundation
import SceneKit

// =============================================================================
// Aircraft-subsystem entry points wired into the WorldAPI factories.
// Implementations: AircraftModels.swift (airframes + entity animation),
// AircraftLiveries.swift (palettes + generated art), CabInterior.swift.
// =============================================================================

func makeAircraftImpl(kind: AircraftKind, livery: Livery) -> AircraftEntity {
    CraftEntity(kind: kind, livery: livery)
}

func buildCabInteriorImpl() -> SCNNode {
    buildCabInteriorNode()
}
