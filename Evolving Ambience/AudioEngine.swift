import Foundation
import AVFoundation
import Combine

/// Protocol for loading audio files, allowing dependency injection for testing or alternative implementations.
public protocol AudioFileLoader {
    func loadAudioFile(named name: String, extension ext: String) -> AVAudioFile?
}

/// Default implementation of AudioFileLoader that loads files from the main bundle.
public struct DefaultAudioFileLoader: AudioFileLoader {
    public init() { }
    public func loadAudioFile(named name: String, extension ext: String) -> AVAudioFile? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            return nil
        }
        return try? AVAudioFile(forReading: url)
    }
}

/// A class that manages an ambient audio engine playing a bundled audio file in a loop with evolving effects.
/// 
/// This class is marked with @MainActor to ensure all properties and methods are main actor isolated,
/// providing thread safety and consistent state management without explicit synchronization.
@MainActor
public final class AmbientAudioEngine: ObservableObject {
    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode
    private let reverb: AVAudioUnitReverb
    private let delay: AVAudioUnitDelay
    private let filter: AVAudioUnitEQ

    // Colored noise bed (air)
    private var noiseNode: AVAudioSourceNode?
    private let noiseLowpass = AVAudioUnitEQ(numberOfBands: 1)
    @Published public var noiseEnabled: Bool = true
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
    private let textureTargetVolume: Float = 0.55

    /// Published texture current volume for UI observation of fades
    @Published public var textureCurrentVolume: Float = 0.0

    /// Texture playback state published for UI observation
    @Published public var textureState: TextureState = .idle

    public enum TextureState { case idle, fadingIn, playing, fadingOut, cooldown }

    // Synth bass pulse
    private var bassNode: AVAudioSourceNode?
    /// Bass frequency in Hz. Setting updates the oscillator immediately.
    public var bassFrequency: Double = 55 { // Hz
        didSet {
            if oldValue != bassFrequency {
                print("AmbientAudioEngine: bassFrequency changed to \(String(format: "%.2f", bassFrequency)) Hz")
                updateBassNode()
            }
        }
    }
    /// Bass beats per minute. Setting updates the oscillator immediately.
    public var bassBPM: Double = 60 { // beats per minute
        didSet {
            if oldValue != bassBPM {
                print("AmbientAudioEngine: bassBPM changed to \(String(format: "%.2f", bassBPM)) bpm")
                updateBassNode()
            }
        }
    }
    /// Bass gain (linear 0..1). Setting updates oscillator gain immediately.
    public var bassGain: Double = 0.35 { // linear gain 0..1
        didSet {
            if oldValue != bassGain {
                print("AmbientAudioEngine: bassGain changed to \(String(format: "%.3f", bassGain))")
                updateBassNode()
            }
        }
    }
    /// Bass enabled state to control bass on/off during playback
    private var bassEnabled: Bool = false {
        didSet {
            // Bass node is a source node producing audio automatically if attached and engine running.
            // So to "disable" bass, set bassGain = 0, to mute it.
            if bassEnabled {
                // Restore gain
                bassGain = bassGainBackup
            } else {
                // Backup current gain and mute bass
                bassGainBackup = bassGain
                bassGain = 0
            }
        }
    }
    private var bassGainBackup: Double = 0.35

    // Generative state
    
    /// Public struct representing a mood configuration, equatable to allow external modification and removal.
    public struct Mood: Equatable {
        public let name: String
        public let reverbRange: ClosedRange<Double>
        public let delayRange: ClosedRange<Double>
        public let cutoffRange: ClosedRange<Double>
        public let duration: ClosedRange<TimeInterval>
        // Bass parameters per mood
        public let bassFrequencyRange: ClosedRange<Double>
        public let bassGainRange: ClosedRange<Double>
        public let bassBPMRange: ClosedRange<Double>
        public init(name: String,
                    reverbRange: ClosedRange<Double>,
                    delayRange: ClosedRange<Double>,
                    cutoffRange: ClosedRange<Double>,
                    duration: ClosedRange<TimeInterval>,
                    bassFrequencyRange: ClosedRange<Double>,
                    bassGainRange: ClosedRange<Double>,
                    bassBPMRange: ClosedRange<Double>) {
            self.name = name
            self.reverbRange = reverbRange
            self.delayRange = delayRange
            self.cutoffRange = cutoffRange
            self.duration = duration
            self.bassFrequencyRange = bassFrequencyRange
            self.bassGainRange = bassGainRange
            self.bassBPMRange = bassBPMRange
        }
    }

    /// Published array of moods, configurable and observable at runtime.
    @Published public var moods: [Mood]

    /// Currently active mood, published for observing current mood changes
    @Published public var currentMood: Mood?

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
    /// Published gestureActive allows UI to react to swell/gesture events
    @Published public var gestureActive: Bool = false
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

    @Published public var volume: Float {
        didSet { engine.mainMixerNode.outputVolume = max(0, min(volume, 1)) }
    }
    @Published private(set) public var isPlaying: Bool

    public var atmosphereFileName = "atmosphere"
    public var atmosphereFileExtension = "wav"
    public var textureFileName = "chimes"
    public var textureFileExtension = "wav"

    // MARK: - Cached audio files to avoid repeated loading and failure spam
    private var cachedAtmosphereFile: AVAudioFile?
    private var cachedTextureFile: AVAudioFile?
    private var atmosphereFileLoadFailed = false
    private var textureFileLoadFailed = false

    // MARK: - Swift Concurrency Tasks for periodic modulation and texture control

    /// Task handling periodic modulation updates
    private var modulationTask: Task<Void, Never>?

    /// Task handling periodic texture playback control
    private var textureTask: Task<Void, Never>?

    /// Audio file loader instance for dependency injection and testability.
    private let audioFileLoader: AudioFileLoader

    /// Initializes the ambient audio engine with an injectable audio file loader for testability.
    /// - Parameter audioFileLoader: An implementation of AudioFileLoader. Defaults to the real bundle loader.
    public init(audioFileLoader: AudioFileLoader = DefaultAudioFileLoader()) {
        self.audioFileLoader = audioFileLoader
        self.engine = AVAudioEngine()
        self.player = AVAudioPlayerNode()
        self.reverb = AVAudioUnitReverb()
        self.delay = AVAudioUnitDelay()
        self.filter = AVAudioUnitEQ(numberOfBands: 1)
        self.volume = 0.5
        self.isPlaying = false

        // Initialize default moods with public struct
        self.moods = [
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

        // Platform-dependent audio session configuration:
        // On macOS, AVAudioSession is not used and is skipped.
        // On iOS/tvOS/watchOS, configure AVAudioSession for playback.
        configureAudioSession()

        // Create and attach bass and noise nodes once to improve reuse and avoid detachment on stop/start.
        self.bassNode = makeBassNode(frequency: bassFrequency, bpm: bassBPM, gain: bassGain)
        self.noiseNode = makePinkNoiseNode(level: Double(noiseGain))

        attachAndConnectNodes()
        configureNodes()
        chooseNextMood()
    }

    #if os(macOS)
    /// On macOS, AVAudioSession is unavailable; no configuration needed.
    private func configureAudioSession() {
        // AVAudioSession is unavailable on macOS. No configuration needed for macOS playback.
    }
    #else
    /// Configure AVAudioSession for playback on iOS/tvOS/watchOS.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true, options: [])
        } catch {
            print("AmbientAudioEngine: Failed to configure AVAudioSession: \(error)")
        }
    }
    #endif

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

    private func updateBassNode() {
        // Remove old bass node and recreate with updated parameters
        if let bass = bassNode {
            if engine.attachedNodes.contains(bass) {
                engine.detach(bass)
            }
        }
        bassNode = makeBassNode(frequency: bassFrequency, bpm: bassBPM, gain: bassGain)
        if let bass = bassNode {
            engine.attach(bass)
            engine.connect(bass, to: engine.mainMixerNode, format: nil)
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

        // Attach bass and noise nodes created once at init
        if let bass = bassNode {
            engine.attach(bass)
        }
        if let noise = noiseNode {
            engine.attach(noise)
        }
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
        if let bass = bassNode {
            engine.connect(bass, to: mainMixer, format: nil)
        }

        // Noise chain: noise -> noiseLowpass -> mainMixer
        if let noise = noiseNode {
            engine.connect(noise, to: noiseLowpass, format: nil)
        }
        engine.connect(noiseLowpass, to: mainMixer, format: nil)

        mainMixer.outputVolume = volume

        // Honor noise enabled state
        noiseLowpass.bypass = !noiseEnabled
    }

    // MARK: - Audio file loading with caching and failure suppression

    /// Loads and schedules the atmosphere loop file, caching it to avoid repeated disk access and error logs.
    private func loadAndScheduleLoop() {
        // If cached file is available, use it
        if let cached = cachedAtmosphereFile {
            scheduleLoop(audioFile: cached)
            return
        }
        // If previously failed to load, skip trying again to avoid spamming logs
        if atmosphereFileLoadFailed { return }

        guard let audioFile = audioFileLoader.loadAudioFile(named: atmosphereFileName, extension: atmosphereFileExtension) else {
            if !atmosphereFileLoadFailed {
                print("AmbientAudioEngine: Audio file \(atmosphereFileName).\(atmosphereFileExtension) not found in bundle.")
                atmosphereFileLoadFailed = true
            }
            return
        }

        cachedAtmosphereFile = audioFile
        atmosphereFileLoadFailed = false
        scheduleLoop(audioFile: audioFile)
    }

    /// Loads the texture audio file once and caches it.
    private func loadTextureFile() {
        // Already have cached texture file, do nothing
        if cachedTextureFile != nil || textureFileLoadFailed { return }

        guard let audioFile = audioFileLoader.loadAudioFile(named: textureFileName, extension: textureFileExtension) else {
            if !textureFileLoadFailed {
                print("AmbientAudioEngine: texture file \(textureFileName).\(textureFileExtension) not found in bundle.")
                textureFileLoadFailed = true
            }
            return
        }
        cachedTextureFile = audioFile
        textureFileLoadFailed = false
    }

    /// Schedules the atmosphere loop using cached audio file.
    private func scheduleLoop(audioFile: AVAudioFile) {
        player.scheduleFile(audioFile, at: nil, completionHandler: { [weak self] in
            // Schedule next loop iteration safely without retain cycles
            guard let self = self else { return }
            Task { @MainActor in
                if let cachedFile = self.cachedAtmosphereFile {
                    self.scheduleLoop(audioFile: cachedFile)
                }
            }
        })
    }

    /// Schedules texture playback only if cached file is available.
    private func scheduleTextureIfNeeded() {
        guard let file = cachedTextureFile else { return }
        // If the player has no pending buffers, schedule once from start
        if texturePlayer.outputFormat(forBus: 0).channelCount > 0 { /* noop for format access */ }
        texturePlayer.stop()
        texturePlayer.scheduleFile(file, at: nil, completionHandler: nil)
        texturePlayer.volume = textureCurrentVolume
    }

    /// Starts the ambient audio engine and begins playback with evolving effects.
    public func start() {
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

        // Enable bass before starting playback
        bassEnabled = true

        // Always schedule at least once before the first play
        loadAndScheduleLoop()
        print("AmbientAudioEngine: Scheduled loop and starting playback.")

        player.play()
        // Start noise and bass nodes if needed (noiseNode and bassNode are source nodes, they produce audio on their own)
        if let noise = noiseNode {
            // noiseNode is connected to engine; no explicit start needed
            _ = noise
        }
        if let bass = bassNode {
            // bassNode is connected to engine; no explicit start needed
            _ = bass
        }
        isPlaying = true
        engine.mainMixerNode.outputVolume = 1.0
        startModulationTask()
        startTextureTask()
    }

    /// Stops the ambient audio playback and effect modulations.
    public func stop() {
        // Disable bass before stopping playback
        bassEnabled = false

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
        engine.mainMixerNode.outputVolume = 0.0

        // Instead of detaching and nil-ing nodes on stop, just let them remain attached for reuse.
        // Noise and bass nodes do not have .stop() method; they run as part of the engine graph.
        // Stopping engine or stopping player is sufficient to halt audible output.
    }

    /// Sets the output volume of the audio engine.
    /// - Parameter value: Volume level between 0.0 and 1.0.
    public func setVolume(_ value: Float) {
        let clamped = max(0, min(value, 1))
        volume = clamped
        engine.mainMixerNode.outputVolume = clamped
    }

    /// Tears down the audio engine and releases resources.
    public func teardown() {
        stop()

        cachedAtmosphereFile = nil
        cachedTextureFile = nil
        atmosphereFileLoadFailed = false
        textureFileLoadFailed = false

        // Detach and nil noiseNode and bassNode on full teardown
        if let nn = noiseNode {
            engine.detach(nn)
            noiseNode = nil
        }

        if let bass = bassNode {
            engine.detach(bass)
            bassNode = nil
        }

        engine.stop()
    }

    @MainActor
    deinit {
        // Cancel any running tasks and teardown to avoid leaks
        modulationTask?.cancel()
        textureTask?.cancel()
        teardown()
    }

    private func chooseNextMood() {
        // Pick a random mood from the moods array and update published currentMood
        let newMood = moods.randomElement()
        currentMood = newMood
        let moodName = newMood?.name ?? "nil"
        print("currentMood: \(moodName)")
        guard let m = newMood else { return }
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

    /// Exponential smoothing approach to smoothly update current value towards target.
    /// This blends the current value with the target by a smoothing factor (alpha).
    /// A higher alpha means faster response; typical values are 0.05 to 0.2.
    private func approach(_ current: Double, _ target: Double, alpha: Double) -> Double {
        current + (target - current) * alpha
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
    /// Published properties updated here enable Combine subscribers to react to real-time changes.
    private func startModulationTask() {
        modulationTask?.cancel()
        modulationTask = Task { [weak self] in
            guard let self = self else { return }
            // Loop runs every ~500 ms while not cancelled
            while !Task.isCancelled {

                // Compute elapsed time in seconds for LFOs and modulations
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
                self.randomWalk(&self.atmospherePanDrift, step: 0.005, min: -0.35, max: 0.35)
                self.randomWalk(&self.texturePanDrift, step: 0.003, min: -0.15, max: 0.15)

                // Mood timing and target updates
                let nowDate: Date = Date()
                if nowDate >= self.moodChangeDeadline {
                    self.chooseNextMood()
                }

                // Smoothly approach mood targets using exponential smoothing
                let smoothingAlpha: Double = 0.02
                self.currentReverb = self.approach(self.currentReverb, self.targetReverb, alpha: smoothingAlpha)
                self.currentDelay  = self.approach(self.currentDelay,  self.targetDelay,  alpha: smoothingAlpha)
                self.currentCutoff = self.approach(self.currentCutoff, self.targetCutoff, alpha: smoothingAlpha)

                // Occasional gesture trigger (low probability)
                if !self.gestureActive {
                    let r: Double = Double.random(in: 0.0...1.0)
                    if r < 0.02 { self.triggerReverbSwell() }
                }
                if self.gestureActive && nowDate >= self.gestureEndTime {
                    self.gestureActive = false
                    if let m = self.currentMood { self.targetReverb = Double.random(in: m.reverbRange) }
                }

                // Slow pan LFOs (atmosphere roams more)
                let twoPi: Double = 2.0 * Double.pi
                let atmospherePanOmega: Double = twoPi / 150.0
                let texturePanOmega: Double = twoPi / 120.0
                let atmospherePanLFO: Double = 0.5 * sin(atmospherePanOmega * elapsedSeconds)
                let texturePanLFO: Double = 0.2 * sin(texturePanOmega * elapsedSeconds + (Double.pi / 3.0))

                // Combine and clamp pan values for submixes
                let atmosphereCombined: Double = atmospherePanLFO + self.atmospherePanDrift
                let textureCombined: Double = texturePanLFO + self.texturePanDrift
                let finalAtmospherePanD: Double = clamp(atmosphereCombined, -1.0, 1.0)
                let finalTexturePanD: Double = clamp(textureCombined, -1.0, 1.0)
                let finalAtmospherePanF: Float = Float(finalAtmospherePanD)
                let finalTexturePanF: Float = Float(finalTexturePanD)

                // Compose final values
                let reverbSum: Double = reverbWetDryMix + reverbWetDrySecondary + self.reverbDrift + self.currentReverb
                let delaySum: Double  = delayFeedback + self.delayDrift + self.currentDelay
                let cutoffSum: Double = filterCutoff + self.filterDrift + self.currentCutoff

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
                if self.stutterState == .idle && now >= self.stutterCoolUntil {
                    let chance: Double = Double.random(in: 0.0...1.0)
                    if chance < 0.015 {
                        self.stutterState = .active
                        self.stutterStart = now
                        self.stutterDuration = Double.random(in: 0.18...0.35)
                    }
                }
                // Try to trigger swell if idle and not cooling
                if self.swellState == .idle && now >= self.swellCoolUntil {
                    let chance: Double = Double.random(in: 0.0...1.0)
                    if chance < 0.008 {
                        self.swellState = .active
                        self.swellStart = now
                        self.swellDuration = Double.random(in: 1.2...2.2)
                    }
                }

                // Compute current envelopes
                var stutterWetBoost: Double = 0.0
                if self.stutterState == .active {
                    let t: TimeInterval = now.timeIntervalSince(self.stutterStart)
                    let denom: Double = max(0.05, self.stutterDuration)
                    let p: Double = max(0.0, min(1.0, t / denom))
                    // quick up and down (triangle)
                    if p < 0.5 {
                        stutterWetBoost = p / 0.5
                    } else {
                        let tail: Double = (p - 0.5) / 0.5
                        stutterWetBoost = max(0.0, 1.0 - tail)
                    }
                    if t >= self.stutterDuration {
                        self.stutterState = .cooling
                        self.stutterCoolUntil = now.addingTimeInterval(Double.random(in: 12.0...25.0))
                        stutterWetBoost = 0.0
                    }
                } else if self.stutterState == .cooling {
                    if now >= self.stutterCoolUntil { self.stutterState = .idle }
                }

                var swellWet: Double = 0.0
                var swellPreDelay: Double = 0.0
                if self.swellState == .active {
                    let t: TimeInterval = now.timeIntervalSince(self.swellStart)
                    let denom: Double = max(0.2, self.swellDuration)
                    let p: Double = max(0.0, min(1.0, t / denom))
                    // ease-in-out for smoother swell
                    let eased: Double = 0.5 - 0.5 * cos(p * Double.pi)
                    swellWet = 0.02 * eased // up to +8% wet
                    swellPreDelay = 0.020 + 0.025 * eased // add ~20-45 ms pre-delay
                    if t >= self.swellDuration {
                        self.swellState = .cooling
                        self.swellCoolUntil = now.addingTimeInterval(Double.random(in: 30.0...60.0))
                        swellWet = 0.0
                        swellPreDelay = 0.0
                    }
                } else if self.swellState == .cooling {
                    if now >= self.swellCoolUntil { self.swellState = .idle }
                }

                // Apply values directly since we're main actor isolated
                self.reverb.wetDryMix = finalReverbF
                self.delay.feedback = finalDelayF
                if let band = self.filter.bands.first {
                    band.frequency = finalCutoffF
                }
                // Per-node pan via AVAudioMixerNode submixes
                self.atmosphereMixer.pan = finalAtmospherePanF
                self.textureMixer.pan = finalTexturePanF

                // Noise bed slow modulation (very subtle)
                if self.noiseEnabled, let nband = self.noiseLowpass.bands.first {
                    // Very slow LFOs
                    let volOmega: Double = (2.0 * Double.pi) / 240.0
                    let cutoffOmega: Double = (2.0 * Double.pi) / 300.0
                    let volLFO: Double = 0.5 + 0.5 * sin(volOmega * elapsedSeconds)
                    let cutoffLFO: Double = sin(cutoffOmega * elapsedSeconds + 0.7)
                    let targetCut: Double = self.noiseCutoffBase + self.noiseCutoffRange * cutoffLFO
                    let clampedCut: Double = max(1000.0, min(20000.0, targetCut))
                    nband.frequency = Float(clampedCut)
                    // Set output volume on the EQ node to control noise level
                    let noiseGainLinear: Double = Double(self.noiseGain)
                    let globalGain: Double = (noiseGainLinear * volLFO) * 10.0
                    self.noiseLowpass.globalGain = Float(globalGain)
                }

                // Apply micro-stutter: temporarily bump delay wet mix slightly
                let baseWet: Float = 12.0
                let stutterBoost: Float = 10.0 * Float(stutterWetBoost) // up to +10%
                self.delay.wetDryMix = baseWet + stutterBoost

                // Apply diffuse reverse swell: modulate reverb wet and pre-delay
                // Preserve the evolving wetDryMix by adding a small swell component
                let swellWetAdd: Float = Float(swellWet * 100.0) // convert to percent
                let newWet: Float = max(0.0, min(100.0, self.reverb.wetDryMix + swellWetAdd))
                self.reverb.wetDryMix = newWet
                // AVAudioUnitReverb doesn't expose a preDelay parameter. Approximate it by nudging
                // the existing delay node's delay time around its 1.0s baseline during swells.
                self.delay.delayTime = 1.0 + swellPreDelay

                // Sleep for ~500 ms, but respond to cancellation immediately
                try? await Task.sleep(nanoseconds: 500_000_000)

                if Task.isCancelled { break }
            }
        }
    }

    /// Starts the texture playback control loop using Swift Concurrency Task instead of GCD timers.
    /// Updates published textureState and textureCurrentVolume for UI observation and reactive updates.
    private func startTextureTask() {
        textureTask?.cancel()
        textureTask = Task { [weak self] in
            guard let self = self else { return }
            var nextActionTime = Date()
            var fadeStartTime = Date()
            var fadeDuration: TimeInterval = 0

            // Loop runs every ~250 ms
            while !Task.isCancelled {
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
                            fadeDuration = Double.random(in: 1.0...3.0)
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
                        nextActionTime = now.addingTimeInterval(Double.random(in: 12.0...28.0))
                    }

                case .playing:
                    if now >= nextActionTime {
                        self.textureState = .fadingOut
                        fadeStartTime = now
                        fadeDuration = Double.random(in: 3.0...7.0)
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

                // Sleep for ~250 ms, but respond to cancellation immediately
                try? await Task.sleep(nanoseconds: 250_000_000)

                if Task.isCancelled { break }
            }
        }
    }

    // MARK: - Public runtime configuration methods
    /// Adds a new mood to the moods list.
    /// - Parameter mood: The Mood to add.
    public func addMood(_ mood: Mood) {
        if !moods.contains(mood) {
            moods.append(mood)
        }
    }

    /// Removes a mood by name from the moods list.
    /// - Parameter named: The name of the mood to remove.
    public func removeMood(named name: String) {
        moods.removeAll { $0.name == name }
    }

    /// Replaces the entire moods list with a new list.
    /// - Parameter moods: The new array of Mood objects.
    public func replaceMoods(with moods: [Mood]) {
        self.moods = moods
    }

    /// Sets noise parameters for color and gain.
    /// - Parameters:
    ///   - gain: Linear gain (0..1) for noise level.
    ///   - cutoffBase: Base cutoff frequency in Hz for noise low-pass filter.
    ///   - cutoffRange: Range (+/-) in Hz for cutoff modulation.
    public func setNoiseParameters(gain: Float, cutoffBase: Double, cutoffRange: Double) {
        noiseGain = gain
        noiseCutoffBase = cutoffBase
        noiseCutoffRange = cutoffRange

        if let nband = noiseLowpass.bands.first {
            nband.frequency = Float(noiseCutoffBase)
        }
        noiseLowpass.globalGain = noiseGain * 10.0
    }
}

