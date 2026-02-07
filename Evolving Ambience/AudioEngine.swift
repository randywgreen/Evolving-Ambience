import Foundation
import AVFoundation
import Combine

/// A class that manages an ambient audio engine playing a bundled audio file in a loop with evolving effects.
final class AmbientAudioEngine: ObservableObject {
    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode
    private let reverb: AVAudioUnitReverb
    private let delay: AVAudioUnitDelay
    private let filter: AVAudioUnitEQ

    // Colored noise bed (air)
    private var noiseNode: AVAudioSourceNode?
    private let noiseLowpass = AVAudioUnitEQ(numberOfBands: 1)
    @Published var noiseEnabled: Bool = true
    private var noiseGain: Float = 0.05 // very low level
    private var noiseCutoffBase: Double = 8000 // Hz
    private var noiseCutoffRange: Double = 3000 // +/- range for modulation

    // Submix mixers for per-node panning
    private let atmosphereMixer = AVAudioMixerNode()
    private let textureMixer = AVAudioMixerNode()

    // Pan modulation state (-1.0 left to +1.0 right)
    private var atmospherePanDrift: Double = 0
    private var texturePanDrift: Double = 0

    // Texture player and scheduling state
    private let texturePlayer = AVAudioPlayerNode()
    private var textureFile: AVAudioFile?
    private var textureTargetVolume: Float = 0.55
    private var textureCurrentVolume: Float = 0.0
    private var textureState: TextureState = .idle

    private enum TextureState { case idle, fadingIn, playing, fadingOut, cooldown }

    // Synth bass pulse
    private var bassNode: AVAudioSourceNode?
    private var bassFrequency: Double = 55 { // Hz
        didSet {
            if oldValue != bassFrequency {
                print("AmbientAudioEngine: bassFrequency changed to \(String(format: "%.2f", bassFrequency)) Hz")
            }
        }
    }
    private var bassBPM: Double = 60 // beats per minute
    private var bassGain: Double = 0.35 // linear gain 0..1

    // Generative state
    private struct Mood {
        let name: String
        let reverbRange: ClosedRange<Double>
        let delayRange: ClosedRange<Double>
        let cutoffRange: ClosedRange<Double>
        let duration: ClosedRange<TimeInterval>
        // Bass parameters per mood
        let bassFrequencyRange: ClosedRange<Double>
        let bassGainRange: ClosedRange<Double>
        let bassBPMRange: ClosedRange<Double>
    }

    private let moods: [Mood] = [
        Mood(
            name: "Calm",
            reverbRange: 20...40,
            delayRange: 10...25,
            cutoffRange: 4000...7000,
            duration: 45...90,
            bassFrequencyRange: 40...52,   // deeper
            bassGainRange: 0.20...0.35,    // softer
            bassBPMRange: 50...60          // slower to moderate
        ),
        Mood(
            name: "Misty",
            reverbRange: 35...55,
            delayRange: 15...30,
            cutoffRange: 2500...5500,
            duration: 60...120,
            bassFrequencyRange: 45...58,
            bassGainRange: 0.22...0.38,
            bassBPMRange: 55...65
        ),
        Mood(
            name: "Dense",
            reverbRange: 50...70,
            delayRange: 25...45,
            cutoffRange: 1500...4000,
            duration: 45...75,
            bassFrequencyRange: 50...65,   // a bit higher to cut through
            bassGainRange: 0.30...0.45,    // slightly louder
            bassBPMRange: 60...75          // faster
        ),
        Mood(
            name: "Sparkly",
            reverbRange: 25...45,
            delayRange: 10...30,
            cutoffRange: 6000...12000,
            duration: 30...60,
            bassFrequencyRange: 48...60,
            bassGainRange: 0.22...0.38,
            bassBPMRange: 58...70
        )
    ]

    private var currentMood: Mood?
    private var moodChangeDeadline = Date()

    // Targets and current values for easing
    private var targetReverb: Double = 30
    private var targetDelay: Double = 20
    private var targetCutoff: Double = 5000

    private var currentReverb: Double = 30
    private var currentDelay: Double = 20
    private var currentCutoff: Double = 5000

    // Random-walk drift values
    private var reverbDrift: Double = 0
    private var delayDrift: Double = 0
    private var filterDrift: Double = 0

    // Gesture state
    private var gestureActive: Bool = false
    private var gestureEndTime: Date = .distantPast

    // Time-based variety events
    private enum TimeEventState { case idle, active, cooling }
    private var stutterState: TimeEventState = .idle
    private var swellState: TimeEventState = .idle
    private var stutterStart: Date = .distantPast
    private var stutterDuration: TimeInterval = 0
    private var stutterCoolUntil: Date = .distantPast
    private var swellStart: Date = .distantPast
    private var swellDuration: TimeInterval = 0
    private var swellCoolUntil: Date = .distantPast

    @Published var volume: Float {
        didSet { engine.mainMixerNode.outputVolume = max(0, min(volume, 1)) }
    }
    @Published private(set) var isPlaying: Bool

    var atmosphereFileName = "atmosphere"
    var atmosphereFileExtension = "wav"
    var textureFileName = "chimes"
    var textureFileExtension = "wav"

    // MARK: - Swift Concurrency Tasks for periodic modulation and texture control

    /// Task handling periodic modulation updates
    private var modulationTask: Task<Void, Never>?

    /// Task handling periodic texture playback control
    private var textureTask: Task<Void, Never>?

    /// Initializes the ambient audio engine, configures the audio session and audio nodes.
    init() {
        self.engine = AVAudioEngine()
        self.player = AVAudioPlayerNode()
        self.reverb = AVAudioUnitReverb()
        self.delay = AVAudioUnitDelay()
        self.filter = AVAudioUnitEQ(numberOfBands: 1)
        self.volume = 0.5
        self.isPlaying = false

        // Audio session configuration is not applicable on macOS.
        configureNodes()
        attachAndConnectNodes()
        chooseNextMood()
    }

    @available(iOS, unavailable)
    @available(tvOS, unavailable)
    @available(watchOS, unavailable)
    private func configureAudioSession() {
        // AVAudioSession is unavailable on macOS. No configuration needed for macOS playback.
    }

    private func configureNodes() {
        // Reverb preset and initial wetDryMix
        reverb.loadFactoryPreset(.cathedral)
        reverb.wetDryMix = 30.0

        // Delay time and feedback
        delay.delayTime = 1.0
        delay.feedback = 20.0
        delay.wetDryMix = 20.0

        // Initialize subtle delay wet mix for occasional stutters
        delay.wetDryMix = 12.0
        // Baseline reverb pre-delay for swells
        reverb.loadFactoryPreset(.cathedral)

        // Filter - low pass band configuration
        if let band = filter.bands.first {
            band.filterType = .lowPass
            band.frequency = 5000.0
            band.bypass = false
            band.bandwidth = 1.0
            band.gain = 0.0
        }

        // Noise low-pass configuration
        if let nband = noiseLowpass.bands.first {
            nband.filterType = .lowPass
            nband.frequency = Float(noiseCutoffBase)
            nband.bandwidth = 0.7
            nband.gain = 0.0
            nband.bypass = false
        }
        noiseLowpass.globalGain = 0.0
        noiseLowpass.bypass = !noiseEnabled
    }

    private func makeBassNode(frequency: Double, bpm: Double, gain: Double) -> AVAudioSourceNode {
        var phase: Double = 0
        var time: Double = 0
        var cachedSampleRate: Double = 0
        let twoPi = 2.0 * Double.pi
        let beatPeriod = 60.0 / max(1.0, bpm)
        let attack: Double = 0.01
        let decay: Double = 0.22

        let node = AVAudioSourceNode { _, refTime, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)

            // Determine sample rate from the output format only once
            if cachedSampleRate == 0, let format = abl.first?.mData?.assumingMemoryBound(to: Float.self) {
                // Fallback to common sample rates if format is not informative; AVAudioEngine will set real rate
                cachedSampleRate = 44100
                _ = format // silence unused warning
            }
            if cachedSampleRate == 0 {
                cachedSampleRate = 44100
            }

            for frame in 0..<frames {
                // Sine oscillator
                let sample = sin(phase)

                // Simple per-beat envelope (attack/decay, then silence until next beat)
                let tInBeat = time.truncatingRemainder(dividingBy: beatPeriod)
                let env: Double
                if tInBeat < attack {
                    env = tInBeat / attack
                } else if tInBeat < attack + decay {
                    let d = (tInBeat - attack) / decay
                    env = max(0.0, 1.0 - d)
                } else {
                    env = 0.0
                }

                let out = Float(sample * env * gain)

                phase += twoPi * frequency / cachedSampleRate
                if phase >= twoPi { phase -= twoPi }
                time += 1.0 / cachedSampleRate

                for buffer in abl {
                    let ptr = buffer.mData!.assumingMemoryBound(to: Float.self)
                    ptr[frame] = out
                }
            }
            return noErr
        }
        return node
    }

    private func makePinkNoiseNode(level: Double) -> AVAudioSourceNode {
        // Voss-McCartney pink noise approximation using several white noise sources summed with different update rates
        let numRows = 16
        var rows = Array(repeating: 0.0, count: numRows)
        var runningSum = 0.0
        var counter: UInt64 = 0
        let scale = level
        let node = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            for frame in 0..<frames {
                counter &+= 1
                // Determine which rows to update based on trailing zeros
                var c = counter
                var i = 0
                while (c & 1) == 0 && i < numRows {
                    runningSum -= rows[i]
                    rows[i] = Double.random(in: -1.0...1.0)
                    runningSum += rows[i]
                    c >>= 1
                    i += 1
                }
                let white = Double.random(in: -1.0...1.0)
                let pink = (runningSum + white) / Double(numRows + 1)
                let sample = Float(pink * scale)
                for buffer in abl {
                    let ptr = buffer.mData!.assumingMemoryBound(to: Float.self)
                    ptr[frame] = sample
                }
            }
            return noErr
        }
        return node
    }

    private func attachAndConnectNodes() {
        engine.attach(player)
        engine.attach(delay)
        engine.attach(reverb)
        engine.attach(filter)
        engine.attach(texturePlayer)

        engine.attach(atmosphereMixer)
        engine.attach(textureMixer)

        // Create and attach bass synth node
        let bass = makeBassNode(frequency: bassFrequency, bpm: bassBPM, gain: bassGain)
        self.bassNode = bass
        engine.attach(bass)

        // Attach and connect noise chain
        let noise = makePinkNoiseNode(level: Double(noiseGain))
        self.noiseNode = noise
        engine.attach(noise)
        engine.attach(noiseLowpass)

        let mainMixer = engine.mainMixerNode

        // Atmosphere chain: player -> atmosphereMixer -> delay -> reverb -> filter -> mainMixer
        engine.connect(player, to: atmosphereMixer, format: nil)
        engine.connect(atmosphereMixer, to: delay, format: nil)
        engine.connect(delay, to: reverb, format: nil)
        engine.connect(reverb, to: filter, format: nil)
        engine.connect(filter, to: mainMixer, format: nil)

        // Texture chain via textureMixer
        engine.connect(texturePlayer, to: textureMixer, format: nil)
        engine.connect(textureMixer, to: mainMixer, format: nil)
        textureMixer.outputVolume = 1.2

        // Bass goes straight to main mixer (dry). You can route through effects if desired.
        engine.connect(bass, to: mainMixer, format: nil)

        // Noise chain: noise -> noiseLowpass -> mainMixer
        engine.connect(noise, to: noiseLowpass, format: nil)
        engine.connect(noiseLowpass, to: mainMixer, format: nil)

        mainMixer.outputVolume = volume

        // Honor noise enabled state
        noiseLowpass.bypass = !noiseEnabled
    }

    private func loadAndScheduleLoop() {
        guard let url = Bundle.main.url(forResource: atmosphereFileName, withExtension: atmosphereFileExtension) else {
            print("AmbientAudioEngine: Audio file \(atmosphereFileName).\(atmosphereFileExtension) not found in bundle.")
            return
        }

        do {
            let audioFile = try AVAudioFile(forReading: url)
            scheduleLoop(audioFile: audioFile)
        } catch {
            print("AmbientAudioEngine: Failed to load audio file: \(error)")
        }
    }

    private func loadTextureFile() {
        guard textureFile == nil else { return }
        guard let url = Bundle.main.url(forResource: textureFileName, withExtension: textureFileExtension) else {
            print("AmbientAudioEngine: texture file \(textureFileName).\(textureFileExtension) not found in bundle.")
            return
        }
        do {
            textureFile = try AVAudioFile(forReading: url)
        } catch {
            print("AmbientAudioEngine: Failed to load texture (\(textureFileName).\(textureFileExtension)): \(error)")
        }
    }

    private func scheduleLoop(audioFile: AVAudioFile) {
        player.scheduleFile(audioFile, at: nil, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.scheduleLoop(audioFile: audioFile)
        })
    }

    private func scheduleTextureIfNeeded() {
        guard let file = textureFile else { return }
        // If the player has no pending buffers, schedule once from start
        if texturePlayer.outputFormat(forBus: 0).channelCount > 0 { /* noop for format access */ }
        texturePlayer.stop()
        texturePlayer.scheduleFile(file, at: nil, completionHandler: nil)
        texturePlayer.volume = textureCurrentVolume
    }

    /// Starts the ambient audio engine and begins playback with evolving effects.
    func start() {
        // Ensure engine is running
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                print("AmbientAudioEngine: Failed to start engine: \(error)")
                return
            }
        }

        // Avoid re-starting if already playing
        guard !player.isPlaying else {
            print("AmbientAudioEngine: Player already playing.")
            return
        }

        // Always schedule at least once before the first play
        loadAndScheduleLoop()
        print("AmbientAudioEngine: Scheduled loop and starting playback.")

        player.play()
        _ = noiseNode // keep strong ref
        // Bass source node runs as part of the engine graph; nothing to schedule.
        _ = bassNode // keep strong ref
        isPlaying = true
        startModulationTask()
        startTextureTask()
    }

    /// Stops the ambient audio playback and effect modulations.
    func stop() {
        if player.isPlaying {
            player.stop()
        }

        modulationTask?.cancel()
        modulationTask = nil

        textureTask?.cancel()
        textureTask = nil

        if texturePlayer.isPlaying { texturePlayer.stop() }
        textureState = .idle
        textureCurrentVolume = 0
        texturePlayer.volume = 0

        isPlaying = false

        if let nn = noiseNode {
            engine.detach(nn)
            noiseNode = nil
        }

        // Recreate bass node next time to reset its phase/time
        if let bass = bassNode {
            engine.detach(bass)
            bassNode = nil
        }
    }

    /// Sets the output volume of the audio engine.
    /// - Parameter value: Volume level between 0.0 and 1.0.
    func setVolume(_ value: Float) {
        let clamped = max(0, min(value, 1))
        volume = clamped
        engine.mainMixerNode.outputVolume = clamped
    }

    /// Tears down the audio engine and releases resources.
    func teardown() {
        stop()
        engine.stop()
    }

    deinit {
        teardown()
    }

    private func chooseNextMood() {
        currentMood = moods.randomElement()
        let moodName = currentMood?.name ?? "nil"
        print("currentMood: \(moodName)")
        guard let m = currentMood else { return }
        let dur = TimeInterval.random(in: m.duration)
        moodChangeDeadline = Date().addingTimeInterval(dur)
        targetReverb = Double.random(in: m.reverbRange)
        targetDelay = Double.random(in: m.delayRange)
        targetCutoff = Double.random(in: m.cutoffRange)

        // Update bass parameters per mood
        bassFrequency = Double.random(in: m.bassFrequencyRange)
        print("AmbientAudioEngine: mood \(m.name) set bassFrequency to \(String(format: "%.2f", bassFrequency)) Hz")
        bassGain = Double.random(in: m.bassGainRange)
        bassBPM = Double.random(in: m.bassBPMRange)
    }

    private func approach(_ current: Double, _ target: Double, rate: Double) -> Double {
        current + (target - current) * rate
    }

    private func randomWalk(_ value: inout Double, step: Double, min: Double, max: Double) {
        value += Double.random(in: -step...step)
        if value < min { value = min }
        if value > max { value = max }
    }

    private func triggerReverbSwell(duration: TimeInterval = 4.0, amount: Double = 8.0) {
        guard !gestureActive else { return }
        gestureActive = true
        gestureEndTime = Date().addingTimeInterval(duration)
        // Temporarily bump the target reverb; easing will carry us there and back
        targetReverb = min(100.0, targetReverb + amount)
    }

    // MARK: - Swift Concurrency based modulation and texture control

    /// Starts the modulation loop using Swift Concurrency Task instead of GCD timers.
    private func startModulationTask() {
        modulationTask?.cancel()
        modulationTask = Task {
            // Loop runs every ~500 ms while not cancelled
            while !Task.isCancelled {
                let startTime = DispatchTime.now()

                // Compute elapsed time in seconds for LFOs and modulations
                // For continuous phase, track elapsed time since task start
                // We'll use Date for now since no startTime is persisted across loops
                let elapsedSeconds = Date().timeIntervalSince1970

                @inline(__always)
                func sineWave(period: Double, amplitude: Double, offset: Double = 0.0, t: Double) -> Double {
                    let omega: Double = (2.0 * Double.pi) / period
                    let angle: Double = (omega * t) + offset
                    return amplitude * sin(angle)
                }
                @inline(__always)
                func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { return max(lo, min(hi, x)) }

                // Base modulations
                let reverbWetDryBase: Double = 30.0
                let reverbWetDryRange: Double = 20.0
                let reverbPrimary: Double = sineWave(period: 60.0, amplitude: reverbWetDryRange, t: elapsedSeconds)
                let reverbWetDryMix: Double = reverbWetDryBase + reverbPrimary

                let delayFeedbackBase: Double = 20.0
                let delayFeedbackRange: Double = 15.0
                let delayPrimary: Double = sineWave(period: 120.0, amplitude: delayFeedbackRange, offset: Double.pi / 4.0, t: elapsedSeconds)
                let delayFeedback: Double = delayFeedbackBase + delayPrimary

                let filterCutoffBase: Double = 5000.0
                let filterCutoffRange: Double = 3500.0
                let filterPrimary: Double = sineWave(period: 180.0, amplitude: filterCutoffRange, offset: Double.pi / 2.0, t: elapsedSeconds)
                let filterCutoff: Double = filterCutoffBase + filterPrimary

                let reverbWetDrySecondary: Double = 5.0 * sin(((2.0 * Double.pi) / 90.0) * elapsedSeconds)

                // Pan random-walk drifts for organic stereo movement
                randomWalk(&atmospherePanDrift, step: 0.005, min: -0.35, max: 0.35)
                randomWalk(&texturePanDrift, step: 0.003, min: -0.15, max: 0.15)

                // Mood timing and target updates
                let nowDate: Date = Date()
                if nowDate >= moodChangeDeadline {
                    chooseNextMood()
                }

                // Smoothly approach mood targets; small rate for slow easing
                let approachRate: Double = 0.02
                currentReverb = approach(currentReverb, targetReverb, rate: approachRate)
                currentDelay  = approach(currentDelay,  targetDelay,  rate: approachRate)
                currentCutoff = approach(currentCutoff, targetCutoff, rate: approachRate)

                // Occasional gesture trigger (low probability)
                if !gestureActive {
                    let r: Double = Double.random(in: 0.0...1.0)
                    if r < 0.02 { triggerReverbSwell() }
                }
                if gestureActive && nowDate >= gestureEndTime {
                    gestureActive = false
                    if let m = currentMood { targetReverb = Double.random(in: m.reverbRange) }
                }

                // Slow pan LFOs (atmosphere roams more)
                let twoPi: Double = 2.0 * Double.pi
                let atmospherePanOmega: Double = twoPi / 150.0
                let texturePanOmega: Double = twoPi / 120.0
                let atmospherePanLFO: Double = 0.5 * sin(atmospherePanOmega * elapsedSeconds)
                let texturePanLFO: Double = 0.2 * sin(texturePanOmega * elapsedSeconds + (Double.pi / 3.0))

                // Combine and clamp pan values for submixes
                let atmosphereCombined: Double = atmospherePanLFO + atmospherePanDrift
                let textureCombined: Double = texturePanLFO + texturePanDrift
                let finalAtmospherePanD: Double = clamp(atmosphereCombined, -1.0, 1.0)
                let finalTexturePanD: Double = clamp(textureCombined, -1.0, 1.0)
                let finalAtmospherePanF: Float = Float(finalAtmospherePanD)
                let finalTexturePanF: Float = Float(finalTexturePanD)

                // Compose final values
                let reverbSum: Double = reverbWetDryMix + reverbWetDrySecondary + reverbDrift + currentReverb
                let delaySum: Double  = delayFeedback + delayDrift + currentDelay
                let cutoffSum: Double = filterCutoff + filterDrift + currentCutoff

                let reverbAveraged: Double = reverbSum / 2.0
                let delayAveraged: Double  = delaySum / 2.0
                let cutoffAveraged: Double = cutoffSum / 2.0

                let finalReverbD: Double = clamp(reverbAveraged, 0.0, 100.0)
                let finalDelayD: Double  = clamp(delayAveraged, 0.0, 100.0)
                let finalCutoffD: Double = clamp(cutoffAveraged, 100.0, 22_000.0)

                let finalReverbF: Float = Float(finalReverbD)
                let finalDelayF: Float  = Float(finalDelayD)
                let finalCutoffF: Float = Float(finalCutoffD)

                // Time-based variety: micro-stutter echoes and diffuse reverse swells
                let now: Date = Date()
                // Try to trigger stutter if idle and not cooling
                if stutterState == .idle && now >= stutterCoolUntil {
                    let chance: Double = Double.random(in: 0.0...1.0)
                    if chance < 0.015 {
                        stutterState = .active
                        stutterStart = now
                        stutterDuration = Double.random(in: 0.18...0.35)
                    }
                }
                // Try to trigger swell if idle and not cooling
                if swellState == .idle && now >= swellCoolUntil {
                    let chance: Double = Double.random(in: 0.0...1.0)
                    if chance < 0.008 {
                        swellState = .active
                        swellStart = now
                        swellDuration = Double.random(in: 1.2...2.2)
                    }
                }

                // Compute current envelopes
                var stutterWetBoost: Double = 0.0
                if stutterState == .active {
                    let t: TimeInterval = now.timeIntervalSince(stutterStart)
                    let denom: Double = max(0.05, stutterDuration)
                    let p: Double = max(0.0, min(1.0, t / denom))
                    // quick up and down (triangle)
                    if p < 0.5 {
                        stutterWetBoost = p / 0.5
                    } else {
                        let tail: Double = (p - 0.5) / 0.5
                        stutterWetBoost = max(0.0, 1.0 - tail)
                    }
                    if t >= stutterDuration {
                        stutterState = .cooling
                        stutterCoolUntil = now.addingTimeInterval(Double.random(in: 12.0...25.0))
                        stutterWetBoost = 0.0
                    }
                } else if stutterState == .cooling {
                    if now >= stutterCoolUntil { stutterState = .idle }
                }

                var swellWet: Double = 0.0
                var swellPreDelay: Double = 0.0
                if swellState == .active {
                    let t: TimeInterval = now.timeIntervalSince(swellStart)
                    let denom: Double = max(0.2, swellDuration)
                    let p: Double = max(0.0, min(1.0, t / denom))
                    // ease-in-out for smoother swell
                    let eased: Double = 0.5 - 0.5 * cos(p * Double.pi)
                    swellWet = 0.02 * eased // up to +8% wet
                    swellPreDelay = 0.020 + 0.025 * eased // add ~20-45 ms pre-delay
                    if t >= swellDuration {
                        swellState = .cooling
                        swellCoolUntil = now.addingTimeInterval(Double.random(in: 30.0...60.0))
                        swellWet = 0.0
                        swellPreDelay = 0.0
                    }
                } else if swellState == .cooling {
                    if now >= swellCoolUntil { swellState = .idle }
                }

                // Apply values on main actor for thread safety
                await MainActor.run {
                    reverb.wetDryMix = finalReverbF
                    delay.feedback = finalDelayF
                    if let band = filter.bands.first {
                        band.frequency = finalCutoffF
                    }
                    // Per-node pan via AVAudioMixerNode submixes
                    atmosphereMixer.pan = finalAtmospherePanF
                    textureMixer.pan = finalTexturePanF

                    // Noise bed slow modulation (very subtle)
                    if noiseEnabled, let nband = noiseLowpass.bands.first {
                        // Very slow LFOs
                        let volOmega: Double = (2.0 * Double.pi) / 240.0
                        let cutoffOmega: Double = (2.0 * Double.pi) / 300.0
                        let volLFO: Double = 0.5 + 0.5 * sin(volOmega * elapsedSeconds)
                        let cutoffLFO: Double = sin(cutoffOmega * elapsedSeconds + 0.7)
                        let targetCut: Double = noiseCutoffBase + noiseCutoffRange * cutoffLFO
                        let clampedCut: Double = max(1000.0, min(20000.0, targetCut))
                        nband.frequency = Float(clampedCut)
                        // Set output volume on the EQ node to control noise level
                        let noiseGainLinear: Double = Double(noiseGain)
                        let globalGain: Double = (noiseGainLinear * volLFO) * 10.0
                        noiseLowpass.globalGain = Float(globalGain)
                    }

                    // Apply micro-stutter: temporarily bump delay wet mix slightly
                    let baseWet: Float = 12.0
                    let stutterBoost: Float = 10.0 * Float(stutterWetBoost) // up to +10%
                    delay.wetDryMix = baseWet + stutterBoost

                    // Apply diffuse reverse swell: modulate reverb wet and pre-delay
                    // Preserve the evolving wetDryMix by adding a small swell component
                    let swellWetAdd: Float = Float(swellWet * 100.0) // convert to percent
                    let newWet: Float = max(0.0, min(100.0, reverb.wetDryMix + swellWetAdd))
                    reverb.wetDryMix = newWet
                    // AVAudioUnitReverb doesn't expose a preDelay parameter. Approximate it by nudging
                    // the existing delay node's delay time around its 1.0s baseline during swells.
                    delay.delayTime = 1.0 + swellPreDelay
                }

                // Sleep for ~500 ms, but respond to cancellation immediately
                try? await Task.sleep(nanoseconds: 500_000_000)

                if Task.isCancelled { break }
            }
        }
    }

    /// Starts the texture playback control loop using Swift Concurrency Task instead of GCD timers.
    private func startTextureTask() {
        textureTask?.cancel()
        textureTask = Task {
            var nextActionTime = Date()
            var fadeStartTime = Date()
            var fadeDuration: TimeInterval = 0

            // Loop runs every ~250 ms
            while !Task.isCancelled {
                let now = Date()

                switch textureState {
                case .idle:
                    // Randomly decide to start after a random delay (1-10s)
                    if now >= nextActionTime {
                        // 10% chance each tick to begin a fade-in sequence
                        if Double.random(in: 0...1) < 0.1 {
                            loadTextureFile()
                            scheduleTextureIfNeeded()
                            if !texturePlayer.isPlaying { texturePlayer.play() }
                            textureState = .fadingIn
                            fadeStartTime = now
                            fadeDuration = Double.random(in: 1.0...3.0)
                            nextActionTime = .distantFuture
                        } else {
                            nextActionTime = now.addingTimeInterval(Double.random(in: 1...10))
                        }
                    }

                case .fadingIn:
                    let t = now.timeIntervalSince(fadeStartTime)
                    let progress = min(1.0, max(0.0, t / max(0.1, fadeDuration)))
                    textureCurrentVolume = Float(progress) * textureTargetVolume
                    await MainActor.run {
                        texturePlayer.volume = textureCurrentVolume
                    }
                    if progress >= 1.0 {
                        textureState = .playing
                        // Decide random play time before fading out
                        nextActionTime = now.addingTimeInterval(Double.random(in: 12.0...28.0))
                    }

                case .playing:
                    if now >= nextActionTime {
                        textureState = .fadingOut
                        fadeStartTime = now
                        fadeDuration = Double.random(in: 3.0...7.0)
                    }

                case .fadingOut:
                    let t = now.timeIntervalSince(fadeStartTime)
                    let progress = min(1.0, max(0.0, t / max(0.1, fadeDuration)))
                    textureCurrentVolume = (1.0 - Float(progress)) * textureTargetVolume
                    await MainActor.run {
                        texturePlayer.volume = textureCurrentVolume
                    }
                    if progress >= 1.0 {
                        await MainActor.run {
                            texturePlayer.stop()
                        }
                        textureState = .cooldown
                        // Ensure at least 20 seconds of silence
                        nextActionTime = now.addingTimeInterval(20.0 + Double.random(in: 0...20.0))
                    }

                case .cooldown:
                    // Wait for cooldown to expire, then return to idle
                    if now >= nextActionTime {
                        textureState = .idle
                        textureCurrentVolume = 0
                        await MainActor.run {
                            texturePlayer.volume = 0
                        }
                    }
                }

                // Sleep for ~250 ms, but respond to cancellation immediately
                try? await Task.sleep(nanoseconds: 250_000_000)

                if Task.isCancelled { break }
            }
        }
    }
}

