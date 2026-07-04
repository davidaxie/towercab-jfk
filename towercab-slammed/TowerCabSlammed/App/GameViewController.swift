import UIKit
import SceneKit
import SwiftUI
import simd

// =============================================================================
// GameViewController — owns the loop. CADisplayLink drives:
//   sim.advance (10 Hz fixed inside) → interpolated render states → entities
//   → HUD bridge updates → sky time (12x golden hour).
// Touch: camera gestures on the SCNView; strips/blooms live in SwiftUI over it.
// =============================================================================

final class GameViewController: UIViewController {

    private var scnView: SCNView!
    private var world: WorldAttachments!
    private var cameraRig: CameraRig!
    private var displayLink: CADisplayLink?

    private let airport = AirportLayout.kjfk
    private var engine: SimEngine?
    private var entities: [AircraftID: AircraftEntity] = [:]
    private let uiState = UIState()
    private let audio = AudioDirector()
    private var lastTimestamp: CFTimeInterval = 0

    // C2: every shift gets a fresh seed; RESTART SAME SEED replays the last.
    private var lastSeed: UInt64 = 0xCA7A11A
    private var isPaused = false

    // Golden hour: shift starts 17:30, runs 12x (PRD §6.4).
    private let shiftStartHour = 17.5
    private let timeScale = 12.0

    private var selectedAircraft: AircraftID?
    /// C5: the verb set is frozen while a bloom is open; only `enabled` mutates.
    private var frozenVerbs: [VerbOption] = []
    private var lastValidAnchor: CGPoint = .zero

    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var shouldAutorotate: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let scene = view.window?.windowScene, scene.interfaceOrientation.isPortrait {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in }
            setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        world = WorldBuilder.build(airport: airport)
        aircraftObserverEye = SIMD3<Float>(Float(airport.towerCabEye.x),
                                           Float(airport.towerCabEye.y),
                                           Float(airport.towerCabEye.z))

        scnView = SCNView(frame: view.bounds)
        scnView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scnView.scene = world.scene
        scnView.preferredFramesPerSecond = 60
        scnView.antialiasingMode = .multisampling4X
        scnView.rendersContinuously = true
        scnView.backgroundColor = .black
        view.addSubview(scnView)

        cameraRig = CameraRig(airport: airport, mount: world.cabMount)
        if let cam = cameraRig.camera { world.sky.configure(camera: cam) }
        scnView.pointOfView = cameraRig.cameraNode
        // Attach look/zoom gestures to the ROOT view (ancestor of both the scene
        // view and the SwiftUI HUD) so drags aren't swallowed by the HUD overlay.
        cameraRig.attachGestures(to: view)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        scnView.addGestureRecognizer(tap)

        // Static cab interior around the eye — parallax comes free with panning.
        let cabInterior = CabInteriorBuilder.build()
        cabInterior.name = "cabInterior"
        world.cabMount.addChildNode(cabInterior)

        // SwiftUI HUD overlay — transparent areas pass touches through.
        uiState.actions = self
        let hud = UIHostingController(rootView: HUDRootView(state: uiState))
        addChild(hud)
        hud.view.frame = view.bounds
        hud.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hud.view.backgroundColor = .clear
        view.addSubview(hud.view)
        hud.didMove(toParent: self)

        world.sky.setTime(hourOfDay: shiftStartHour)

        audio.start()

        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link

        applyDebugArguments()
    }

    // MARK: - Debug harness

    /// -autostart, -seed <n>, -ff <s>, -autopilot, -openbloom, -hour <h>,
    /// -yaw/-pitch/-fov <deg>, -campos x,y,z, -hide a,b, -stats, -nobloom
    private func applyDebugArguments() {
        let args = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> Double? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return Double(args[i + 1])
        }
        if let s = value(after: "-seed") { lastSeed = UInt64(s) }
        if let h = value(after: "-hour") {
            debugPinnedHour = h
            world.sky.setTime(hourOfDay: h)
        }
        if args.contains("-yaw") || args.contains("-pitch") || args.contains("-fov") {
            cameraRig.setPose(yawDeg: value(after: "-yaw"),
                              pitchDeg: value(after: "-pitch"),
                              fovDeg: value(after: "-fov"))
        }
        if let i = args.firstIndex(of: "-campos"), i + 1 < args.count {
            let p = args[i + 1].split(separator: ",").compactMap { Double($0) }
            if p.count == 3 {
                world.cabMount.position = SCNVector3(p[0], p[1], p[2])
            }
        }
        if let i = args.firstIndex(of: "-hide"), i + 1 < args.count {
            let tokens = args[i + 1].lowercased().split(separator: ",").map(String.init)
            world.scene.rootNode.enumerateHierarchy { node, _ in
                if let name = node.name?.lowercased(),
                   tokens.contains(where: { name.contains($0) }) {
                    node.isHidden = true
                }
            }
        }
        if args.contains("-stats") { scnView.showsStatistics = true }
        if args.contains("-audiolog") { audioLog = true }
        if args.contains("-nobloom") { cameraRig.camera?.bloomIntensity = 0 }
        if args.contains("-autopilot") { autopilotEnabled = true }
        // -follow <phaseKeyword> [KINDLABEL]: lock the camera onto the first
        // aircraft whose strip phase matches (e.g. "rolling", "climbing",
        // "landing", "final", "downwind"), optionally filtered by kind (CM60),
        // and track it for close-up movement screenshots.
        if let i = args.firstIndex(of: "-follow"), i + 1 < args.count {
            debugFollowKeyword = args[i + 1].lowercased()
            if i + 2 < args.count, !args[i + 2].hasPrefix("-") {
                debugFollowKind = args[i + 2].uppercased()
            }
        }
        // -turntable <KIND> [PHASE]: skip the shift; float one posed, slowly
        // spinning aircraft in front of the cab to inspect the rig (surfaces,
        // fans, gear, wheels, attitude) without fighting traffic timing.
        if let i = args.firstIndex(of: "-turntable"), i + 1 < args.count {
            let kl = args[i + 1].uppercased()
            // Match a debug type keyword to a real AircraftKind (by display code
            // or a legacy CM/VL/LK shorthand); default to the everyman C172.
            turntableKind = AircraftKind.allCases.first { kl.contains($0.spec.display) }
                ?? (kl.contains("CM") ? .challenger350
                    : (kl.contains("VL") ? .sr22 : .c172))
            if i + 2 < args.count, !args[i + 2].hasPrefix("-") {
                turntablePhase = phaseFromKeyword(args[i + 2].lowercased())
            }
            let liv: Livery = turntableKind.engineIsJet ? .meridianVIP : .privateWhite
            let e = CraftEntity(kind: turntableKind, livery: liv)
            // Offset to the NE so the fixed centre mullion doesn't cross it.
            turntablePos = V3(airport.towerCabEye.x + 26, airport.towerCabEye.y - 3,
                              airport.towerCabEye.z - 34)
            world.aircraftContainer.addChildNode(e.node)
            turntableEntity = e
            uiState.screen = .playing   // drop the start-screen overlay
        }
        if args.contains("-autostart") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                self.beginShift(seed: self.lastSeed)
                if let ff = value(after: "-ff"), let engine = self.engine {
                    for i in 0..<Int(ff * 10) {
                        for event in engine.advance(by: 0.1) { self.handle(event) }
                        if self.autopilotEnabled && i % 5 == 0 { self.runAutopilot(engine) }
                    }
                    self.uiState.radioLog.removeAll()
                    self.uiState.toasts.removeAll()
                }
                if args.contains("-openbloom"), let engine = self.engine,
                   let target = engine.current.aircraft.first(where: { $0.phase.isAirborne }) {
                    self.openBloom(for: target.id)
                }
            }
        }
    }

    private var debugPinnedHour: Double?
    private var debugFollowKeyword: String?
    private var debugFollowKind: String?
    private var debugFollowID: AircraftID?
    private var turntableEntity: AircraftEntity?
    private var turntableKind: AircraftKind = .challenger350
    private var turntablePhase: FlightPhase = .flare
    private var turntablePos = V3(0, 0, 0)
    private var turntableYaw = 0.0
    private var autopilotEnabled = false
    private var lastAutopilotAt: Double = -1
    private var audioLog = false
    private var audioLogFrame = 0

    private func phaseFromKeyword(_ k: String) -> FlightPhase {
        switch k {
        case "flare", "landing":            return .flare
        case "final", "short", "shortfinal": return .shortFinal
        case "climb", "climbing":           return .climbingOut
        case "roll", "rolling", "takeoff":  return .takeoffRoll
        case "rollout":                     return .rollout
        case "downwind":                    return .downwind
        case "taxi":                        return .taxiToRunway
        default:                            return .flare
        }
    }

    /// Demo/dev controller: issues sensible clearances through the same path
    /// as verb taps, so the whole loop (badges, streak, score) can run hands-off.
    private func runAutopilot(_ engine: SimEngine) {
        let snapshot = engine.current
        func legal(_ id: AircraftID, _ command: Command) -> Bool {
            guard let st = snapshot.aircraft.first(where: { $0.id == id }) else { return false }
            return engine.legalCommands(for: st).contains(command)
        }
        let arrivalClose = snapshot.aircraft.contains {
            $0.phase == .shortFinal || $0.phase == .flare || $0.phase == .rollout ||
            ($0.phase == .finalApproach && $0.clearedToLand)
        }
        for ac in snapshot.aircraft {
            switch ac.phase {
            case .finalApproach, .shortFinal:
                if !ac.clearedToLand, legal(ac.id, .clearedToLand) {
                    engine.apply(CommandEnvelope(aircraft: ac.id, command: .clearedToLand,
                                                 timestamp: engine.simTime))
                }
            case .holdingShort, .lineUpWait:
                if !arrivalClose, legal(ac.id, .clearedForTakeoff(immediate: false)) {
                    engine.apply(CommandEnvelope(aircraft: ac.id,
                                                 command: .clearedForTakeoff(immediate: false),
                                                 timestamp: engine.simTime))
                }
            case .parkedArrival, .departedHandoff:
                if legal(ac.id, .handoff) {
                    engine.apply(CommandEnvelope(aircraft: ac.id, command: .handoff,
                                                 timestamp: engine.simTime))
                }
            default:
                break
            }
        }
    }

    // MARK: - Loop

    @objc private func step(_ link: CADisplayLink) {
        let dt = lastTimestamp == 0 ? 1.0 / 60.0 : min(link.targetTimestamp - lastTimestamp, 0.25)
        lastTimestamp = link.targetTimestamp

        cameraRig.update(dt: dt)

        // Turntable inspection mode: pose + slowly spin one aircraft, no sim.
        if let tt = turntableEntity {
            turntableYaw += dt * 0.5
            let liv: Livery = turntableKind.engineIsJet ? .meridianVIP : .privateWhite
            let grounded = turntablePhase == .rollout || turntablePhase == .takeoffRoll
                || turntablePhase == .taxiToRunway
            let st = AircraftRenderState(
                id: AircraftID(0), kind: turntableKind, livery: liv,
                phase: turntablePhase, position: turntablePos, heading: turntableYaw,
                bank: grounded ? 0 : 0.30,
                pitch: turntablePhase == .flare ? 0.14 : (grounded ? 0.02 : 0.08),
                crab: 0, throttle: 0.85, speed: grounded ? 30 : 60, velocity: .zero,
                gearDown: turntablePhase != .climbingOut, landingLightsOn: false, band: .green)
            tt.update(st, dt: dt)
            cameraRig.frame(worldPoint: turntablePos,
                            targetSpan: turntableKind.wingspanMeters * 1.5)
            return
        }

        guard let engine = engine else { return }

        if !isPaused {
            let events = engine.advance(by: dt)
            for event in events { handle(event) }
            if autopilotEnabled && engine.simTime - lastAutopilotAt > 0.6 {
                lastAutopilotAt = engine.simTime
                runAutopilot(engine)
            }
        }

        // Sync entities with interpolated states.
        let states = engine.renderStates(alpha: engine.interpolationAlpha)
        var live = Set<AircraftID>()
        for s in states {
            live.insert(s.id)
            let entity = entities[s.id] ?? {
                let e = AircraftModelFactory.make(kind: s.kind, livery: s.livery)
                e.node.name = "AC\(s.id.raw)"
                world.aircraftContainer.addChildNode(e.node)
                entities[s.id] = e
                return e
            }()
            if !isPaused { entity.update(s, dt: dt) }
        }
        for (id, entity) in entities where !live.contains(id) {
            entity.node.removeFromParentNode()
            entities.removeValue(forKey: id)
            audio.removeEngine(id: id)
        }

        // Audio: listener tracks the cab camera; engines + wind track the sim.
        let f = cameraRig.cameraNode.worldFront, u = cameraRig.cameraNode.worldUp
        audio.updateListener(position: airport.towerCabEye,
                             forward: V3(Double(f.x), Double(f.y), Double(f.z)),
                             up: V3(Double(u.x), Double(u.y), Double(u.z)))
        if !isPaused {
            let w = engine.current.wind
            audio.setWind(speedKts: w.speedKts, gustKts: w.gustKts, dt: dt)
            for s in states {
                audio.updateEngine(id: s.id, kind: s.kind, phase: s.phase,
                                   position: s.position, speed: s.speed, dt: dt)
            }
        }
        if audioLog {
            audioLogFrame += 1
            if audioLogFrame % 60 == 0 {
                NSLog(String(format: "[audiolog] running=%@ rms=%.5f voices=%d",
                             audio.running ? "Y" : "N", audio.meterRMS, states.count))
            }
        }

        // Sky clock: sim time at 12x (unless pinned for screenshots).
        if !isPaused {
            world.sky.setTime(hourOfDay: debugPinnedHour
                ?? (shiftStartHour + engine.simTime * timeScale / 3600.0))
        }

        // Debug: track an aircraft matching -follow for movement screenshots.
        if let kw = debugFollowKeyword {
            if debugFollowID == nil || !states.contains(where: { $0.id == debugFollowID }) {
                debugFollowID = states.first(where: {
                    $0.phase.stripLabel.lowercased().contains(kw) &&
                    (debugFollowKind == nil || $0.kind.displayType == debugFollowKind)
                })?.id
            }
            if let fid = debugFollowID, let fs = states.first(where: { $0.id == fid }) {
                cameraRig.frame(worldPoint: fs.position,
                                targetSpan: fs.kind.wingspanMeters * 2.6)
            }
        }

        syncHUD(engine: engine, states: states)
    }

    private func syncHUD(engine: SimEngine, states: [AircraftRenderState]) {
        let snapshot = engine.current

        var strips: [StripModel] = []
        for ac in snapshot.aircraft where ac.phase != .removed {
            let tone: StripTone
            if ac.phase == .parkedArrival || ac.phase == .departedHandoff {
                tone = .complete
            } else {
                switch ac.band {
                case .green: tone = .normal
                case .amber: tone = .attention
                case .red: tone = .alarm
                }
            }
            // C8: quantize per-frame floats so strip equality is stable enough
            // to avoid re-rendering the whole rail 60×/s.
            let urgency = ac.urgency.map { (($0 * 20).rounded()) / 20 }
            strips.append(StripModel(
                id: ac.id,
                callsign: ac.callsign.display,
                typeLabel: ac.kind.displayType,
                phaseLabel: ac.phase.stripLabel,
                tone: tone,
                isArrival: ac.phase.isArrivalFlow,
                isSelected: ac.id == selectedAircraft,
                gapSeconds: ac.gapSeconds.map { Int(max(0, $0.rounded())) },
                urgency: urgency,
                delayLevel: ((min(ac.delaySeconds / 120.0, 1.0) * 20).rounded()) / 20))
        }
        if uiState.strips != strips { uiState.strips = strips }

        if uiState.score != snapshot.score { uiState.score = snapshot.score }
        if uiState.streakMultiplier != snapshot.streakMultiplier {
            uiState.streakMultiplier = snapshot.streakMultiplier
        }
        if uiState.shiftPhase != snapshot.shiftPhase { uiState.shiftPhase = snapshot.shiftPhase }

        // B22: overtime renders as +m:ss while the last strips resolve.
        let remaining = snapshot.shiftTimeRemaining
        let clock: String
        if remaining >= 0 || snapshot.shiftPhase == .ended {
            let r = max(0, Int(remaining.rounded()))
            clock = String(format: "%d:%02d", r / 60, r % 60)
        } else {
            let o = Int((-remaining).rounded())
            clock = String(format: "+%d:%02d", o / 60, o % 60)
        }
        if uiState.shiftClock != clock { uiState.shiftClock = clock }

        let gust = snapshot.wind.gustKts > snapshot.wind.speedKts + 3
            ? "G\(Int(snapshot.wind.gustKts))" : ""
        let wind = "\(Int(snapshot.wind.directionDeg))° \(Int(snapshot.wind.speedKts))\(gust)"
        if uiState.windText != wind { uiState.windText = wind }

        let clockHour = debugPinnedHour ?? (shiftStartHour + engine.simTime * timeScale / 3600.0)
        let local = String(format: "%02d:%02d", Int(clockHour) % 24,
                           Int(clockHour.truncatingRemainder(dividingBy: 1) * 60))
        if uiState.localTimeText != local { uiState.localTimeText = local }

        // Keep the bloom anchored to its aircraft; freeze verbs (C4/C5).
        if let bloom = uiState.bloom {
            if let s = states.first(where: { $0.id == bloom.aircraftID }),
               let st = snapshot.aircraft.first(where: { $0.id == bloom.aircraftID }) {
                var b = bloom
                if let anchor = projectValid(s.position) {
                    lastValidAnchor = anchor
                    b.anchor = anchor
                } else {
                    b.anchor = lastValidAnchor
                }
                let legal = Set(engine.legalCommands(for: st))
                let updated = frozenVerbs.map {
                    VerbOption(command: $0.command, style: $0.style,
                               enabled: legal.contains($0.command))
                }
                if updated != b.verbs { b.verbs = updated }
                if b != bloom { uiState.bloom = b }
            } else {
                uiState.bloom = nil
                selectedAircraft = nil
            }
        }

        let now = Date()
        if uiState.toasts.contains(where: { now.timeIntervalSince($0.createdAt) > 2.6 }) {
            uiState.toasts.removeAll { now.timeIntervalSince($0.createdAt) > 2.6 }
        }
    }

    private func handle(_ event: SimEvent) {
        switch event {
        case .radio(let call):
            let speaker: String
            let isTower: Bool
            switch call.speaker {
            case .tower:
                speaker = call.speakerLabel.isEmpty ? "TWR" : call.speakerLabel
                isTower = true
            case .pilot(let id):
                // B17: prefer the emit-time label — the aircraft may be gone.
                speaker = call.speakerLabel.isEmpty
                    ? (engine?.current.aircraft.first(where: { $0.id == id })?.callsign.display ?? "—")
                    : call.speakerLabel
                isTower = false
            }
            uiState.radioLog.append(RadioLine(speaker: speaker, text: call.text, isTower: isTower))
            if uiState.radioLog.count > 8 { uiState.radioLog.removeFirst() }
            audio.playRadio(isTower: isTower)
        case .movementCompleted(_, _, let isLanding):
            if isLanding { audio.playTouchdown() }
        case .bandChanged(_, let band):
            if band == .red { audio.playAlarm() }
        case .badge(let award):
            let isSave = award.badge == .save || award.badge == .lateSave
            audio.playBadge(isSave: isSave)
            pushToast(BadgeToast(
                text: "\(award.badge.label) +\(award.points)",
                isSave: isSave))
        case .streakChanged(let m):
            uiState.streakMultiplier = m
        case .selfPreservation(_, let penalty):
            pushToast(BadgeToast(text: "PILOT'S CALL \(penalty)", isSave: false))
        case .shiftEnded(let report):
            uiState.screen = .score(ShiftReportBox(report))
        case .aircraftRemoved(let id):
            if selectedAircraft == id { closeBloom() }
        default:
            break
        }
    }

    /// C20: newest first, hard cap 3.
    private func pushToast(_ toast: BadgeToast) {
        uiState.toasts.insert(toast, at: 0)
        if uiState.toasts.count > 3 { uiState.toasts.removeLast(uiState.toasts.count - 3) }
    }

    // MARK: - Selection & verbs

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard engine != nil else { return }
        let p = g.location(in: scnView)
        // C18: forgiving picking — probe a small cross around the touch.
        let probes = [CGPoint.zero, CGPoint(x: 22, y: 0), CGPoint(x: -22, y: 0),
                      CGPoint(x: 0, y: 22), CGPoint(x: 0, y: -22)]
        for off in probes {
            let q = CGPoint(x: p.x + off.x, y: p.y + off.y)
            if let id = aircraftHit(at: q) {
                openBloom(for: id)
                return
            }
        }
        bloomDismissed()   // C28: one dismissal path
    }

    private func aircraftHit(at point: CGPoint) -> AircraftID? {
        // Category 1 only — cab interior/glass is category 2 and must not eat taps.
        let hits = scnView.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                    .categoryBitMask: 1,
                                                    .ignoreHiddenNodes: true])
        for hit in hits {
            var node: SCNNode? = hit.node
            while let n = node {
                if let name = n.name, name.hasPrefix("AC"), let raw = Int(name.dropFirst(2)) {
                    return AircraftID(raw)
                }
                node = n.parent
            }
        }
        return nil
    }

    private func openBloom(for id: AircraftID) {
        guard let engine = engine,
              let state = engine.current.aircraft.first(where: { $0.id == id }) else { return }
        selectedAircraft = id
        frozenVerbs = verbOptions(for: state, engine: engine)

        // C4: if the aircraft is off-screen, swing the camera to it first; the
        // bloom rides along as the aircraft enters frame (no cuts, PRD law).
        if !cameraRig.isOnScreen(state.position, in: scnView) {
            cameraRig.frame(worldPoint: state.position,
                            targetSpan: state.kind.wingspanMeters)
        }
        let anchor = projectValid(state.position) ?? lastValidAnchor
        lastValidAnchor = anchor
        uiState.bloom = BloomModel(
            aircraftID: id,
            callsign: state.callsign.display,
            anchor: anchor,
            verbs: frozenVerbs)
    }

    private func closeBloom() {
        uiState.bloom = nil
        selectedAircraft = nil
        frozenVerbs = []
    }

    private func verbOptions(for state: AircraftState, engine: SimEngine) -> [VerbOption] {
        engine.legalCommands(for: state).prefix(6).map { cmd in
            let style: VerbOption.Style
            switch cmd {
            case .goAround: style = .save
            case .holdPosition, .clearedForTakeoff(immediate: true): style = .caution
            default: style = .standard
            }
            return VerbOption(command: cmd, style: style, enabled: true)
        }
    }

    /// C4: nil when behind the camera or far outside the view.
    private func projectValid(_ world: V3) -> CGPoint? {
        let v = scnView.projectPoint(SCNVector3(world.x, world.y, world.z))
        guard v.z > 0 && v.z < 1 else { return nil }
        let p = CGPoint(x: CGFloat(v.x), y: CGFloat(v.y))
        guard scnView.bounds.insetBy(dx: -120, dy: -120).contains(p) else { return nil }
        return p
    }

    private func beginShift(seed: UInt64) {
        lastSeed = seed
        entities.values.forEach { $0.node.removeFromParentNode() }
        entities.removeAll()
        audio.removeAllEngines()
        audio.setMuted(false)
        engine = SimEngine(airport: airport, seed: seed)
        isPaused = false
        uiState.paused = false
        uiState.screen = .playing
        uiState.radioLog = []
        uiState.toasts = []
        closeBloom()
        lastTimestamp = 0
        lastAutopilotAt = -1
    }
}

// MARK: - GameActions (HUD → game)

extension GameViewController: GameActions {

    func startShift() {
        beginShift(seed: UInt64.random(in: 1...UInt64.max))
    }

    func restartShift() {
        beginShift(seed: lastSeed)
    }

    func togglePause() {
        guard engine != nil else { return }
        isPaused.toggle()
        uiState.paused = isPaused
        audio.setMuted(isPaused)
    }

    func stripTapped(_ id: AircraftID) {
        // C1: first tap selects + opens the bloom instantly; a second tap on
        // the already-selected strip answers "where is he" by framing it.
        if id == selectedAircraft {
            if let s = engine?.renderStates(alpha: 1).first(where: { $0.id == id }) {
                cameraRig.frame(worldPoint: s.position,
                                targetSpan: Double(s.kind.wingspanMeters))
            }
        } else {
            openBloom(for: id)
        }
    }

    func stripDoubleTapped(_ id: AircraftID) {
        guard let s = engine?.renderStates(alpha: 1).first(where: { $0.id == id }) else { return }
        cameraRig.frame(worldPoint: s.position, targetSpan: Double(s.kind.wingspanMeters))
    }

    func verbSelected(_ id: AircraftID, command: Command) {
        guard let engine = engine else { return }
        engine.apply(CommandEnvelope(aircraft: id, command: command, timestamp: engine.simTime))
        closeBloom()
    }

    func bloomDismissed() {
        closeBloom()
    }
}
