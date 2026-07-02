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

    private let airport = AirportLayout.kavx
    private var engine: SimEngine?
    private var entities: [AircraftID: AircraftEntity] = [:]
    private let uiState = UIState()
    private var lastTimestamp: CFTimeInterval = 0

    // Golden hour: shift starts 17:30, runs 12x (PRD §6.4).
    private let shiftStartHour = 17.5
    private let timeScale = 12.0

    private var selectedAircraft: AircraftID?

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
        cameraRig.attachGestures(to: scnView)

        // Static cab interior around the eye — parallax comes free with panning.
        let cabInterior = CabInteriorBuilder.build()
        cabInterior.name = "cabInterior"
        world.cabMount.addChildNode(cabInterior)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        scnView.addGestureRecognizer(tap)

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

        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link

        applyDebugArguments()
    }

    /// Screenshot/dev harness: -autostart begins a shift immediately;
    /// -hour <h> pins the sky clock (e.g. -hour 18.3); -ff <s> fast-forwards
    /// the sim that many seconds after autostart.
    private func applyDebugArguments() {
        let args = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> Double? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return Double(args[i + 1])
        }
        if let h = value(after: "-hour") {
            debugPinnedHour = h
            world.sky.setTime(hourOfDay: h)
        }
        if args.contains("-yaw") || args.contains("-pitch") || args.contains("-fov") {
            cameraRig.setPose(yawDeg: value(after: "-yaw"),
                              pitchDeg: value(after: "-pitch"),
                              fovDeg: value(after: "-fov"))
        }
        // -hide token1,token2 hides any node whose name contains a token.
        if let i = args.firstIndex(of: "-hide"), i + 1 < args.count {
            let tokens = args[i + 1].lowercased().split(separator: ",").map(String.init)
            world.scene.rootNode.enumerateHierarchy { node, _ in
                if let name = node.name?.lowercased(),
                   tokens.contains(where: { name.contains($0) }) {
                    node.isHidden = true
                }
            }
        }
        if args.contains("-nobloom") {
            cameraRig.camera?.bloomIntensity = 0
        }
        if args.contains("-autopilot") { autopilotEnabled = true }
        if args.contains("-autostart") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                self.startShift()
                if let ff = value(after: "-ff"), let engine = self.engine {
                    // advance() clamps dt (hitch guard) — step fixed ticks.
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
    private var autopilotEnabled = false
    private var lastAutopilotAt: Double = -1

    /// Demo/dev controller: issues sensible clearances through the same path
    /// as verb taps, so the whole loop (badges, streak, score) can run hands-off.
    private func runAutopilot(_ engine: SimEngine) {
        let snapshot = engine.current
        func legal(_ id: AircraftID, _ command: Command) -> Bool {
            guard let st = snapshot.aircraft.first(where: { $0.id == id }) else { return false }
            return engine.legalCommands(for: st).contains(command)
        }
        let arrivalClose = snapshot.aircraft.contains {
            $0.phase == .shortFinal || $0.phase == .flare ||
            ($0.phase == .finalApproach && $0.clearedToLand)
        }
        for ac in snapshot.aircraft {
            switch ac.phase {
            case .finalApproach, .shortFinal:
                if !ac.clearedToLand, legal(ac.id, .clearedToLand) {
                    engine.apply(CommandEnvelope(aircraft: ac.id, command: .clearedToLand,
                                                 timestamp: engine.simTime))
                }
            case .holdingShort:
                if !arrivalClose, legal(ac.id, .clearedForTakeoff(immediate: false)) {
                    engine.apply(CommandEnvelope(aircraft: ac.id,
                                                 command: .clearedForTakeoff(immediate: false),
                                                 timestamp: engine.simTime))
                }
            case .lineUpWait:
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

        guard let engine = engine else { return }

        let events = engine.advance(by: dt)
        for event in events { handle(event) }
        if autopilotEnabled && engine.simTime - lastAutopilotAt > 0.6 {
            lastAutopilotAt = engine.simTime
            runAutopilot(engine)
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
            entity.update(s, dt: dt)
        }
        for (id, entity) in entities where !live.contains(id) {
            entity.node.removeFromParentNode()
            entities.removeValue(forKey: id)
        }

        // Sky clock: sim time at 12x (unless pinned for screenshots).
        world.sky.setTime(hourOfDay: debugPinnedHour
            ?? (shiftStartHour + engine.simTime * timeScale / 3600.0))

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
            strips.append(StripModel(
                id: ac.id,
                callsign: ac.callsign.display,
                typeLabel: ac.kind.displayType,
                phaseLabel: ac.phase.stripLabel,
                tone: tone,
                isArrival: ac.phase.isArrivalFlow,
                isSelected: ac.id == selectedAircraft,
                gapSeconds: ac.gapSeconds.map { Int(max(0, $0.rounded())) },
                urgency: ac.urgency,
                delayLevel: min(ac.delaySeconds / 120.0, 1.0)))
        }
        // Rail caps at 9 visible (PRD §2.3); HUD shows "+N" for overflow.
        uiState.strips = strips

        uiState.score = snapshot.score
        uiState.streakMultiplier = snapshot.streakMultiplier
        uiState.shiftPhase = snapshot.shiftPhase
        let remaining = max(0, Int(snapshot.shiftTimeRemaining.rounded()))
        uiState.shiftClock = String(format: "%d:%02d", remaining / 60, remaining % 60)
        let gust = snapshot.wind.gustKts > snapshot.wind.speedKts + 3
            ? "G\(Int(snapshot.wind.gustKts))" : ""
        uiState.windText = "\(Int(snapshot.wind.directionDeg))° \(Int(snapshot.wind.speedKts))\(gust)"
        let clockHour = shiftStartHour + engine.simTime * timeScale / 3600.0
        uiState.localTimeText = String(format: "%02d:%02d", Int(clockHour) % 24,
                                       Int(clockHour.truncatingRemainder(dividingBy: 1) * 60))

        // Keep the bloom anchored to its aircraft.
        if let bloom = uiState.bloom {
            if let s = states.first(where: { $0.id == bloom.aircraftID }) {
                var b = bloom
                b.anchor = project(s.position)
                if let st = snapshot.aircraft.first(where: { $0.id == bloom.aircraftID }) {
                    b.verbs = verbOptions(for: st, engine: engine)
                }
                uiState.bloom = b
            } else {
                uiState.bloom = nil
                selectedAircraft = nil
            }
        }

        // Expire toasts.
        let now = Date()
        uiState.toasts.removeAll { now.timeIntervalSince($0.createdAt) > 2.6 }
    }

    private func handle(_ event: SimEvent) {
        switch event {
        case .radio(let call):
            let speaker: String
            let isTower: Bool
            switch call.speaker {
            case .tower: speaker = "TWR"; isTower = true
            case .pilot(let id):
                speaker = engine?.current.aircraft.first(where: { $0.id == id })?.callsign.display ?? "?"
                isTower = false
            }
            uiState.radioLog.append(RadioLine(speaker: speaker, text: call.text, isTower: isTower))
            if uiState.radioLog.count > 5 { uiState.radioLog.removeFirst() }
        case .badge(let award):
            uiState.toasts.append(BadgeToast(
                text: "\(award.badge.label) +\(award.points)",
                isSave: award.badge == .save || award.badge == .lateSave))
        case .streakChanged(let m):
            uiState.streakMultiplier = m
        case .selfPreservation(_, let penalty):
            uiState.toasts.append(BadgeToast(text: "PILOT'S CALL \(penalty)", isSave: false))
        case .shiftEnded(let report):
            uiState.screen = .score(ShiftReportBox(report))
        case .aircraftRemoved(let id):
            if selectedAircraft == id { selectedAircraft = nil; uiState.bloom = nil }
        default:
            break
        }
    }

    // MARK: - Selection & verbs

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard let engine = engine else { return }
        let p = g.location(in: scnView)
        // Category 1 only — cab interior/glass is category 2 and must not eat taps.
        let hits = scnView.hitTest(p, options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                .categoryBitMask: 1,
                                                .ignoreHiddenNodes: true])
        var tappedID: AircraftID?
        for hit in hits {
            var node: SCNNode? = hit.node
            while let n = node {
                if let name = n.name, name.hasPrefix("AC"), let raw = Int(name.dropFirst(2)) {
                    tappedID = AircraftID(raw)
                    break
                }
                node = n.parent
            }
            if tappedID != nil { break }
        }
        if let id = tappedID {
            openBloom(for: id)
        } else {
            uiState.bloom = nil
            selectedAircraft = nil
        }
    }

    private func openBloom(for id: AircraftID) {
        guard let engine = engine,
              let state = engine.current.aircraft.first(where: { $0.id == id }) else { return }
        selectedAircraft = id
        uiState.bloom = BloomModel(
            aircraftID: id,
            callsign: state.callsign.display,
            anchor: project(state.position),
            verbs: verbOptions(for: state, engine: engine))
    }

    private func verbOptions(for state: AircraftState, engine: SimEngine) -> [VerbOption] {
        engine.legalCommands(for: state).prefix(6).map { cmd in
            let style: VerbOption.Style
            switch cmd {
            case .goAround: style = .save
            case .holdPosition, .clearedForTakeoff(immediate: true): style = .caution
            default: style = .standard
            }
            return VerbOption(command: cmd, style: style)
        }
    }

    private func project(_ world: V3) -> CGPoint {
        let v = scnView.projectPoint(SCNVector3(world.x, world.y, world.z))
        return CGPoint(x: CGFloat(v.x), y: CGFloat(v.y))
    }
}

// MARK: - GameActions (HUD → game)

extension GameViewController: GameActions {

    func startShift() {
        entities.values.forEach { $0.node.removeFromParentNode() }
        entities.removeAll()
        engine = SimEngine(airport: airport, seed: 0xCA7A11A)
        uiState.screen = .playing
        uiState.radioLog = []
        uiState.toasts = []
        uiState.bloom = nil
        selectedAircraft = nil
        lastTimestamp = 0
    }

    func restartShift() { startShift() }

    func stripTapped(_ id: AircraftID) {
        openBloom(for: id)
    }

    func stripDoubleTapped(_ id: AircraftID) {
        guard let s = engine?.renderStates(alpha: 1).first(where: { $0.id == id }) else { return }
        cameraRig.frame(worldPoint: s.position)
    }

    func verbSelected(_ id: AircraftID, command: Command) {
        guard let engine = engine else { return }
        engine.apply(CommandEnvelope(aircraft: id, command: command, timestamp: engine.simTime))
        uiState.bloom = nil
        selectedAircraft = nil
    }

    func bloomDismissed() {
        uiState.bloom = nil
        selectedAircraft = nil
    }
}
