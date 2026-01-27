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

    // Texture player and scheduling state
    private let texturePlayer = AVAudioPlayerNode()
    private var textureFile: AVAudioFile?
    private var textureTimer: DispatchSourceTimer?
    private var textureTargetVolume: Float = 0.6
    private var textureCurrentVolume: Float = 0.0
    private var textureState: TextureState = .idle

    private enum TextureState { case idle, fadingIn, playing, fadingOut, cooldown }

    // Synth bass pulse
    private var bassNode: AVAudioSourceNode?
    private var bassFrequency: Double = 55 // Hz
    private var bassBPM: Double = 60 // beats per minute
    private var bassGain: Double = 0.35 // linear gain 0..1

    // Generative state
    private struct Mood {
        let name: String
        let reverbRange: ClosedRange<Double>
        let delayRange: ClosedRange<Double>
        let cutoffRange: ClosedRange<Double>
        let duration: ClosedRange<TimeInterval>
    }

    private let moods: [Mood] = [
        Mood(name: "Calm",    reverbRange: 20...40, delayRange: 10...25, cutoffRange: 4000...7000, duration: 45...90),
        Mood(name: "Misty",   reverbRange: 35...55, delayRange: 15...30, cutoffRange: 2500...5500, duration: 60...120),
        Mood(name: "Dense",   reverbRange: 50...70, delayRange: 25...45, cutoffRange: 1500...4000, duration: 45...75),
        Mood(name: "Sparkly", reverbRange: 25...45, delayRange: 10...30, cutoffRange: 6000...12000, duration: 30...60)
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

    @Published var volume: Float {
        didSet { engine.mainMixerNode.outputVolume = max(0, min(volume, 1)) }
    }
    private var timer: DispatchSourceTimer?
    @Published private(set) var isPlaying: Bool

    var atmosphereFileName = "atmosphere"
    var atmosphereFileExtension = "wav"
    var textureFileName = "chimes"
    var textureFileExtension = "wav"

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

        // Filter - low pass band configuration
        if let band = filter.bands.first {
            band.filterType = .lowPass
            band.frequency = 5000.0
            band.bypass = false
            band.bandwidth = 1.0
            band.gain = 0.0
        }
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

    private func attachAndConnectNodes() {
        engine.attach(player)
        engine.attach(delay)
        engine.attach(reverb)
        engine.attach(filter)
        engine.attach(texturePlayer)

        // Create and attach bass synth node
        let bass = makeBassNode(frequency: bassFrequency, bpm: bassBPM, gain: bassGain)
        self.bassNode = bass
        engine.attach(bass)

        let mainMixer = engine.mainMixerNode

        // player -> delay -> reverb -> filter -> mainMixer
        engine.connect(player, to: delay, format: nil)
        engine.connect(delay, to: reverb, format: nil)
        engine.connect(reverb, to: filter, format: nil)
        engine.connect(filter, to: mainMixer, format: nil)

        // Texture straight to mixer; dry by default
        engine.connect(texturePlayer, to: mainMixer, format: nil)

        // Bass goes straight to main mixer (dry). You can route through effects if desired.
        engine.connect(bass, to: mainMixer, format: nil)

        mainMixer.outputVolume = volume
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
        // Bass source node runs as part of the engine graph; nothing to schedule.
        _ = bassNode // keep strong ref
        isPlaying = true
        startModulationTimer()
        startTextureTimer()
    }

    /// Stops the ambient audio playback and effect modulations.
    func stop() {
        if player.isPlaying {
            player.stop()
        }
        timer?.cancel()
        timer = nil

        textureTimer?.cancel()
        textureTimer = nil
        if texturePlayer.isPlaying { texturePlayer.stop() }
        textureState = .idle
        textureCurrentVolume = 0
        texturePlayer.volume = 0

        isPlaying = false

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

    private func startModulationTimer() {
        timer?.cancel()
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
        timer?.schedule(deadline: .now(), repeating: 0.5, leeway: .milliseconds(100))

        let startTime = DispatchTime.now()

        timer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
            let elapsedSeconds = Double(elapsed) / 1_000_000_000

            // Sine wave modulators with different periods and amplitudes
            func sineWave(period: Double, amplitude: Double, offset: Double = 0) -> Double {
                return amplitude * sin((2 * .pi / period) * elapsedSeconds + offset)
            }

            // Base modulations (as before)
            let reverbWetDryBase = 30.0
            let reverbWetDryRange = 20.0
            let reverbWetDryMix = reverbWetDryBase + sineWave(period: 60, amplitude: reverbWetDryRange)

            let delayFeedbackBase = 20.0
            let delayFeedbackRange = 15.0
            let delayFeedback = delayFeedbackBase + sineWave(period: 120, amplitude: delayFeedbackRange, offset: .pi / 4)

            let filterCutoffBase = 5000.0
            let filterCutoffRange = 3500.0
            let filterCutoff = filterCutoffBase + sineWave(period: 180, amplitude: filterCutoffRange, offset: .pi / 2)

            let reverbWetDrySecondary = 5.0 * sin((2 * .pi / 90) * elapsedSeconds)

            // Random-walk drifts for organic variation
            randomWalk(&reverbDrift, step: 0.05, min: -10, max: 10)
            randomWalk(&delayDrift, step: 0.03, min: -8, max: 8)
            randomWalk(&filterDrift, step: 10, min: -800, max: 800)

            // Mood timing and target updates
            if Date() >= moodChangeDeadline {
                chooseNextMood()
            }

            // Smoothly approach mood targets; small rate for slow easing
            currentReverb = approach(currentReverb, targetReverb, rate: 0.02)
            currentDelay  = approach(currentDelay,  targetDelay,  rate: 0.02)
            currentCutoff = approach(currentCutoff, targetCutoff, rate: 0.02)

            // Occasional gesture trigger (low probability)
            if !gestureActive && Double.random(in: 0...1) < 0.02 { // ~2% chance per tick
                triggerReverbSwell()
            }
            if gestureActive && Date() >= gestureEndTime {
                gestureActive = false
                // Nudge target back toward current mood reverb center
                if let m = currentMood {
                    targetReverb = Double.random(in: m.reverbRange)
                }
            }

            // Compose final values: base LFOs + secondary + drift + mood-eased centers
            let finalReverb = max(0, min(100, (reverbWetDryMix + reverbWetDrySecondary + reverbDrift + currentReverb) / 2))
            let finalDelay  = max(0, min(100, (delayFeedback + delayDrift + currentDelay) / 2))
            let finalCutoff = max(100, min(22000, (filterCutoff + filterDrift + currentCutoff) / 2))

            DispatchQueue.main.async {
                self.reverb.wetDryMix = Float(finalReverb)
                self.delay.feedback = Float(finalDelay)
                if let band = self.filter.bands.first {
                    band.frequency = Float(finalCutoff)
                }
            }
        }
        timer?.resume()
    }

    private func startTextureTimer() {
        textureTimer?.cancel()
        let queue = DispatchQueue.global(qos: .background)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        textureTimer = timer
        timer.schedule(deadline: .now(), repeating: 0.25, leeway: .milliseconds(50))
        // Randomized control variables
        var nextActionTime = Date()
        var fadeStartTime = Date()
        var fadeDuration: TimeInterval = 0

        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let now = Date()

            switch self.textureState {
            case .idle:
                // Randomly decide to start after a random delay (1-10s)
                if now >= nextActionTime {
                    // 10% chance each tick to begin a fade-in sequence
                    if Double.random(in: 0...1) < 0.1 {
                        self.loadTextureFile()
                        self.scheduleTextureIfNeeded()
                        if !self.texturePlayer.isPlaying { self.texturePlayer.play() }
                        self.textureState = .fadingIn
                        fadeStartTime = now
                        fadeDuration = Double.random(in: 2.0...6.0)
                        nextActionTime = .distantFuture
                    } else {
                        nextActionTime = now.addingTimeInterval(Double.random(in: 1...10))
                    }
                }

            case .fadingIn:
                let t = now.timeIntervalSince(fadeStartTime)
                let progress = min(1.0, max(0.0, t / max(0.1, fadeDuration)))
                self.textureCurrentVolume = Float(progress) * self.textureTargetVolume
                self.texturePlayer.volume = self.textureCurrentVolume
                if progress >= 1.0 {
                    self.textureState = .playing
                    // Decide random play time before fading out
                    nextActionTime = now.addingTimeInterval(Double.random(in: 5.0...20.0))
                }

            case .playing:
                if now >= nextActionTime {
                    self.textureState = .fadingOut
                    fadeStartTime = now
                    fadeDuration = Double.random(in: 2.0...6.0)
                }

            case .fadingOut:
                let t = now.timeIntervalSince(fadeStartTime)
                let progress = min(1.0, max(0.0, t / max(0.1, fadeDuration)))
                self.textureCurrentVolume = (1.0 - Float(progress)) * self.textureTargetVolume
                self.texturePlayer.volume = self.textureCurrentVolume
                if progress >= 1.0 {
                    self.texturePlayer.stop()
                    self.textureState = .cooldown
                    // Ensure at least 20 seconds of silence
                    nextActionTime = now.addingTimeInterval(20.0 + Double.random(in: 0...20.0))
                }

            case .cooldown:
                // Wait for cooldown to expire, then return to idle
                if now >= nextActionTime {
                    self.textureState = .idle
                    self.textureCurrentVolume = 0
                    self.texturePlayer.volume = 0
                }
            }
        }
        timer.resume()
    }
}

