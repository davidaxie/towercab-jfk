import AVFoundation
import simd

// =============================================================================
// AudioDirector — the whole soundscape, synthesized in code (no assets on disk,
// matching the rest of the slice). Programmer audio to be replaced by the
// contracted audio designer per PRD §5; the point here is to prove the pillar
// ("the radio is the star") and give a human tester something to hear.
//
// Buses:
//   • Ambient wind bed — filtered noise, level/brightness track wind + gusts.
//   • Per-aircraft engines — mono voices into an AVAudioEnvironmentNode for 3D
//     pan + distance; piston chop vs jet whine by type, throttle by phase, and
//     a manual doppler pitch shift from the closing rate (flybys drop in pitch).
//   • Radio + cues — pre-synthesized one-shot buffers (tower/pilot crackle,
//     touchdown chirp, badge ding, red-band alarm) scheduled on sim events.
//
// Everything degrades to silence if the audio engine fails to start — audio is
// never allowed to take the game down (PRD: silent play is full parity).
// =============================================================================

/// Per-voice parameters written on the main thread, read on the audio thread.
/// Plain scalars: races are benign (no tearing that can crash on 64-bit), and
/// a frame of staleness is inaudible.
private final class EngineParams {
    var baseFreq: Double = 90      // fundamental, Hz
    var level: Float = 0           // 0…1 target amplitude
    var noiseMix: Float = 0.3      // broadband component
    var propHz: Double = 72        // blade-pass chop (0 ⇒ jet, no chop)
    var pitchMul: Double = 1       // doppler multiplier
    var alive = true
}

private final class WindParams {
    var level: Float = 0.06
    var cutoff: Float = 0.10       // one-pole coefficient (brighter with gusts)
    var gustLevel: Float = 0
}

final class AudioDirector {

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let cuePlayer = AVAudioPlayerNode()
    private var sampleRate: Double = 48_000
    private(set) var running = false

    // Ambient wind
    private var windNode: AVAudioSourceNode?
    private let wind = WindParams()

    // Engine voices, one mono source node per live aircraft.
    private struct Voice {
        let node: AVAudioSourceNode
        let params: EngineParams
        var lastPos: V3
        var haveLast: Bool
    }
    private var voices: [AircraftID: Voice] = [:]
    private let maxVoices = 10

    // One-shot cue buffers.
    private var cues: [String: AVAudioPCMBuffer] = [:]

    private var listenerPos = V3(0, 0, 0)
    private var muted = false

    // Verification: RMS of the master mix (see `meterRMS`).
    private(set) var meterRMS: Float = 0

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // .ambient respects the mute switch — the game is fully playable
            // silent, headset is the enhanced experience (PRD §5.9).
            try session.setCategory(.ambient, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            NSLog("[audio] session setup failed: \(error) — continuing silent")
        }

        sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if sampleRate <= 0 { sampleRate = 48_000 }
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        // Environment (3D) → main mixer.
        engine.attach(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        environment.distanceAttenuationParameters.referenceDistance = 25
        environment.distanceAttenuationParameters.maximumDistance = 6_000
        environment.distanceAttenuationParameters.rolloffFactor = 0.7
        environment.renderingAlgorithm = .HRTF

        // Wind bed → main mixer (non-spatial).
        let windNode = makeWindNode(format: mono)
        self.windNode = windNode
        engine.attach(windNode)
        engine.connect(windNode, to: engine.mainMixerNode, format: mono)

        // Cue player → main mixer. Connect with the MONO format so the
        // mono cue buffers match the player's output channel count (the mixer
        // upmixes to stereo); a nil format negotiates stereo and would trip
        // AVAudioPlayerNode's channel-count assertion on scheduleBuffer.
        engine.attach(cuePlayer)
        engine.connect(cuePlayer, to: engine.mainMixerNode, format: mono)

        buildCues()

        // Master meter tap (verification; also cheap headroom guard).
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            guard let self = self, let ch = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            var sum: Float = 0
            for f in 0..<n { let s = ch[0][f]; sum += s * s }
            self.meterRMS = n > 0 ? (sum / Float(n)).squareRoot() : 0
        }
        engine.mainMixerNode.outputVolume = 0.85

        do {
            try engine.start()
            cuePlayer.play()
            running = true
            NSLog("[audio] engine started @ \(Int(sampleRate)) Hz")
        } catch {
            NSLog("[audio] engine start failed: \(error) — continuing silent")
        }
    }

    func setMuted(_ m: Bool) {
        muted = m
        engine.mainMixerNode.outputVolume = m ? 0 : 0.85
    }

    // MARK: - Per-frame updates

    /// Listener follows the cab camera (position + forward/up from the POV node).
    func updateListener(position: V3, forward: V3, up: V3) {
        guard running else { return }
        listenerPos = position
        environment.listenerPosition = AVAudio3DPoint(x: Float(position.x),
                                                      y: Float(position.y),
                                                      z: Float(position.z))
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: Float(forward.x), y: Float(forward.y), z: Float(forward.z)),
            up: AVAudio3DVector(x: Float(up.x), y: Float(up.y), z: Float(up.z)))
    }

    func setWind(speedKts: Double, gustKts: Double, dt: Double) {
        let base = Float(min(1, 0.04 + speedKts / 45))
        wind.level += (base * 0.5 - wind.level) * Float(min(1, dt * 2))
        wind.cutoff = Float(min(0.5, 0.08 + speedKts / 120))
        // A slow gust swell when the gust spread is wide.
        let gustTarget: Float = gustKts > speedKts + 3 ? 0.25 : 0.0
        wind.gustLevel += (gustTarget - wind.gustLevel) * Float(min(1, dt * 0.5))
    }

    /// Update (or spawn) the engine voice for one aircraft from its render state.
    func updateEngine(id: AircraftID, kind: AircraftKind, phase: FlightPhase,
                      position: V3, speed: Double, dt: Double) {
        guard running else { return }
        let voice = voices[id] ?? spawnVoice(for: id)
        guard let v = voices[id] else { _ = voice; return }
        let p = v.params

        // Throttle/level by phase.
        let (levelTarget, freqScale): (Float, Double)
        switch phase {
        case .takeoffRoll:            (levelTarget, freqScale) = (0.9, 1.15)
        case .climbingOut, .goingAround: (levelTarget, freqScale) = (0.85, 1.1)
        case .departedHandoff:        (levelTarget, freqScale) = (0.5, 1.05)
        case .inboundFinal, .finalApproach, .shortFinal, .downwind, .base, .orbiting:
                                      (levelTarget, freqScale) = (0.55, 0.95)
        case .flare:                  (levelTarget, freqScale) = (0.4, 0.9)
        case .rollout:                (levelTarget, freqScale) = (0.5, 0.85)
        case .taxiToRunway, .taxiToApron, .exitingRunway, .lineUpWait:
                                      (levelTarget, freqScale) = (0.32, 0.8)
        case .holdingShort, .startingUp, .parkedArrival:
                                      (levelTarget, freqScale) = (0.22, 0.75)
        case .removed:                (levelTarget, freqScale) = (0, 0.7)
        }

        // Type character — driven by the spec engine class so all 16 types map
        // without a per-case list. Prop chop for piston/turboprop, jet whine
        // (no blade chop) for jets. Bigger metal idles a touch lower/louder.
        let idle: Double
        switch kind.spec.engine {
        case .piston:
            idle = kind.spec.wingspanM > 14 ? 88 : 78   // DC-3 vs light singles
            p.propHz = 82; p.noiseMix = 0.28
        case .turboprop:
            idle = 120; p.propHz = 104; p.noiseMix = 0.34   // turbine whine + prop
        case .jet:
            idle = 210; p.propHz = 0; p.noiseMix = 0.55     // jet: whine, no chop
        }
        p.baseFreq = idle * freqScale * (1 + Double(min(speed, 90)) / 260)
        p.level += (levelTarget - p.level) * Float(min(1, dt * 3))

        // Manual doppler from radial closing rate toward the listener.
        var pitch = 1.0
        if v.haveLast, dt > 0 {
            let vel = (position - v.lastPos) / dt
            let toL = listenerPos - position
            let dist = simd_length(toL)
            if dist > 1 {
                let vr = simd_dot(vel, toL / dist)   // + = approaching
                let c = 340.0
                pitch = c / max(80, c - max(-120, min(120, vr)))
            }
        }
        p.pitchMul += (pitch - p.pitchMul) * min(1, dt * 6)

        // 3D position.
        v.node.position = AVAudio3DPoint(x: Float(position.x), y: Float(position.y), z: Float(position.z))
        voices[id]?.lastPos = position
        voices[id]?.haveLast = true

        cullVoicesIfNeeded()
    }

    func removeEngine(id: AircraftID) {
        guard let v = voices.removeValue(forKey: id) else { return }
        v.params.alive = false
        engine.detach(v.node)
    }

    func removeAllEngines() {
        for (_, v) in voices { v.params.alive = false; engine.detach(v.node) }
        voices.removeAll()
    }

    // MARK: - Cues

    func playRadio(isTower: Bool) { schedule(isTower ? "radioTwr" : "radioPilot", gain: 0.9) }
    func playTouchdown() { schedule("chirp", gain: 0.8) }
    func playBadge(isSave: Bool) { schedule(isSave ? "dingSave" : "ding", gain: 0.7) }
    func playAlarm() { schedule("alarm", gain: 0.7) }

    private func schedule(_ key: String, gain: Float) {
        guard running, !muted, let buf = cues[key] else { return }
        cuePlayer.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        cuePlayer.volume = gain
    }

    // MARK: - Voice factory

    private func spawnVoice(for id: AircraftID) -> Voice {
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let params = EngineParams()
        let node = makeEngineNode(params: params, format: mono)
        engine.attach(node)
        engine.connect(node, to: environment, format: mono)
        node.renderingAlgorithm = .HRTF
        node.reverbBlend = 0.1
        let v = Voice(node: node, params: params, lastPos: .zero, haveLast: false)
        voices[id] = v
        return v
    }

    /// If we exceed the voice budget, drop the farthest.
    private func cullVoicesIfNeeded() {
        guard voices.count > maxVoices else { return }
        let sorted = voices.sorted {
            let a = $0.value.lastPos, b = $1.value.lastPos
            return simd_length(a - listenerPos) < simd_length(b - listenerPos)
        }
        for (id, _) in sorted.dropFirst(maxVoices) { removeEngine(id: id) }
    }

    // MARK: - Synthesis: continuous voices

    private func makeEngineNode(params: EngineParams, format: AVAudioFormat) -> AVAudioSourceNode {
        var phase = 0.0, propPhase = 0.0, lp = 0.0
        var rng: UInt32 = 0x2545F491
        let sr = sampleRate
        return AVAudioSourceNode(format: format) { _, _, frameCount, abl in
            let ablPtr = UnsafeMutableAudioBufferListPointer(abl)
            guard let out = ablPtr.first?.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            let level = params.level
            let base = params.baseFreq * params.pitchMul
            let noiseMix = params.noiseMix
            let propHz = params.propHz
            let twoPi = 2.0 * Double.pi
            for i in 0..<Int(frameCount) {
                // Two detuned partials + broadband noise → resonant one-pole LPF.
                phase += twoPi * base / sr
                if phase > twoPi { phase -= twoPi }
                let tone = sin(phase) * 0.6 + sin(phase * 2.01) * 0.25
                rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
                let noise = (Double(rng) / Double(UInt32.max)) * 2 - 1
                var s = tone * (1 - Double(noiseMix)) + noise * Double(noiseMix)
                lp += (s - lp) * 0.35            // soften
                s = lp
                // Prop blade-pass chop (skip for jets, propHz == 0).
                if propHz > 0 {
                    propPhase += twoPi * propHz / sr
                    if propPhase > twoPi { propPhase -= twoPi }
                    s *= 0.65 + 0.35 * (0.5 + 0.5 * sin(propPhase))
                }
                out[i] = Float(s) * level * 0.5
            }
            return noErr
        }
    }

    private func makeWindNode(format: AVAudioFormat) -> AVAudioSourceNode {
        var lp = 0.0, lp2 = 0.0, gustPhase = 0.0
        var rng: UInt32 = 0x9E3779B9
        let sr = sampleRate
        let params = wind
        return AVAudioSourceNode(format: format) { _, _, frameCount, abl in
            let ablPtr = UnsafeMutableAudioBufferListPointer(abl)
            guard let out = ablPtr.first?.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            let level = params.level, cutoff = Double(params.cutoff), gust = params.gustLevel
            for i in 0..<Int(frameCount) {
                rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
                let noise = (Double(rng) / Double(UInt32.max)) * 2 - 1
                lp += (noise - lp) * cutoff          // brown-ish
                lp2 += (lp - lp2) * 0.5
                gustPhase += 2 * Double.pi * 0.08 / sr
                let gustEnv = 0.5 + 0.5 * sin(gustPhase)
                let amp = Double(level) + Double(gust) * gustEnv
                out[i] = Float(lp2 * amp)
            }
            return noErr
        }
    }

    // MARK: - Synthesis: one-shot cues

    private func buildCues() {
        cues["radioTwr"] = radioBuffer(centerHz: 1400, bright: 0.55, dur: 0.32)
        cues["radioPilot"] = radioBuffer(centerHz: 1050, bright: 0.35, dur: 0.30)
        cues["chirp"] = touchdownBuffer()
        cues["ding"] = dingBuffer(f1: 880, f2: 1320, teal: false)
        cues["dingSave"] = dingBuffer(f1: 1245, f2: 1660, teal: true)
        cues["alarm"] = alarmBuffer()
    }

    private func newBuffer(_ seconds: Double) -> (AVAudioPCMBuffer, UnsafeMutablePointer<Float>, Int) {
        let n = AVAudioFrameCount(seconds * sampleRate)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        buf.frameLength = n
        return (buf, buf.floatChannelData![0], Int(n))
    }

    /// Squelch-in click → band-limited static + faint carrier → squelch-out.
    private func radioBuffer(centerHz: Double, bright: Double, dur: Double) -> AVAudioPCMBuffer {
        let (buf, p, n) = newBuffer(dur)
        var rng: UInt32 = 0x1234567
        var bp = 0.0, bp2 = 0.0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
            let noise = (Double(rng) / Double(UInt32.max)) * 2 - 1
            // crude bandpass toward centerHz
            let k = centerHz / sampleRate * 6
            bp += (noise - bp) * min(0.9, k)
            bp2 += (bp - bp2) * 0.4
            let band = (bp - bp2)
            let carrier = sin(2 * .pi * centerHz * t) * 0.12
            // envelope: fast click in, body, click out
            let env: Double
            if t < 0.012 { env = t / 0.012 }
            else if t > dur - 0.03 { env = max(0, (dur - t) / 0.03) }
            else { env = 1 }
            let click = (t < 0.01 || t > dur - 0.012) ? noise * 0.5 : 0
            p[i] = Float((band * (0.5 + bright) + carrier + click) * env * 0.5)
        }
        return buf
    }

    private func touchdownBuffer() -> AVAudioPCMBuffer {
        let dur = 0.22
        let (buf, p, n) = newBuffer(dur)
        var rng: UInt32 = 0xBEEF01
        for i in 0..<n {
            let t = Double(i) / sampleRate
            rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
            let noise = (Double(rng) / Double(UInt32.max)) * 2 - 1
            let chirp = sin(2 * .pi * (520 - 260 * t / dur) * t) * 0.3   // downward
            let env = exp(-t * 16)
            p[i] = Float((noise * 0.6 + chirp) * env * 0.6)
        }
        return buf
    }

    private func dingBuffer(f1: Double, f2: Double, teal: Bool) -> AVAudioPCMBuffer {
        let dur = 0.45
        let (buf, p, n) = newBuffer(dur)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let s = sin(2 * .pi * f1 * t) * 0.5 + sin(2 * .pi * f2 * t) * (teal ? 0.4 : 0.3)
            let env = exp(-t * (teal ? 6 : 8))
            p[i] = Float(s * env * 0.5)
        }
        return buf
    }

    private func alarmBuffer() -> AVAudioPCMBuffer {
        let dur = 0.5
        let (buf, p, n) = newBuffer(dur)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let pulse = 0.5 + 0.5 * sin(2 * .pi * 6 * t)   // 6 Hz throb
            let tone = sin(2 * .pi * 220 * t) > 0 ? 1.0 : -1.0   // low square
            let env = min(1, t / 0.02) * max(0, (dur - t) / 0.1)
            p[i] = Float(tone * 0.28 * pulse * env)
        }
        return buf
    }
}
