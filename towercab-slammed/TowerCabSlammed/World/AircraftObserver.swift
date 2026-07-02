import Foundation
import simd

/// The fixed cab-eye position, used by aircraft entities to scale light halos
/// with distance (screen-constant "pearls" on final). Set once at world build.
var aircraftObserverEye = SIMD3<Float>(0, 0, 0)
