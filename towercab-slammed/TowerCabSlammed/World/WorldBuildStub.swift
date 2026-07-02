import Foundation
import SceneKit

// =============================================================================
// World assembly — "Luminous Diorama" Catalina at golden hour (PRD §6).
//
// Orchestrates the world subsystem:
//   Terrain.swift          — ocean, mesa + cliffs, interior ridges, mainland
//   AirportGeometry.swift  — runway/taxiways/apron riding the midfield hump
//   GroundDetails.swift    — PAPI, edge lights, windsock, buildings, tower
//   SkyLighting.swift      — sun, dome, fog, env light, camera grade, dusk
//
// Static geometry arrives pre-flattened from its builders (< ~40 nodes total).
// =============================================================================

func buildWorldImpl(airport: AirportLayout) -> WorldAttachments {
    let scene = SCNScene()
    scene.rootNode.name = "world"

    WorldTerrainBuilder.build(into: scene.rootNode, airport: airport)
    WorldAirportBuilder.build(into: scene.rootNode, airport: airport)

    let lightBank = AirfieldLightBank()
    WorldDetailsBuilder.build(into: scene.rootNode, airport: airport, bank: lightBank)

    // Sky last: it owns every light in the scene and primes the 17:30 look.
    let sky = GoldenHourSky(scene: scene, airport: airport, bank: lightBank)

    let aircraftContainer = SCNNode()
    aircraftContainer.name = "aircraft"
    scene.rootNode.addChildNode(aircraftContainer)

    let cabMount = SCNNode()
    cabMount.name = "cabMount"
    cabMount.position = SCNVector3(Float(airport.towerCabEye.x),
                                   Float(airport.towerCabEye.y),
                                   Float(airport.towerCabEye.z))
    scene.rootNode.addChildNode(cabMount)

    return WorldAttachments(scene: scene, aircraftContainer: aircraftContainer,
                            cabMount: cabMount, sky: sky)
}
