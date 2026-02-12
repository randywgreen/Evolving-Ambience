import Foundation
import AVFoundation
import Combine

/// A class that manages an ambient audio engine playing a bundled audio file in a loop with evolving effects.
/// 
/// This class is marked with @MainActor to ensure all properties and methods are main actor isolated,
/// providing thread safety and consistent state management without explicit synchronization.
@MainActor
public final class AmbientAudioEngine: ObservableObject {
    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode
    private let reverb = AVAudioUnitReverb()
    private let eq = AVAudioUnitEQ(numberOfBands: 1)
    private let delay = AVAudioUnitDelay()

    /// Reverb wet/dry mix in percent (0..100). Adjusts the reverb unit immediately when set.
    public var reverbWetDryMix: Float = 30 {
        didSet {
            let clamped = max(0, min(reverbWetDryMix, 100))
            if clamped != reverb.wetDryMix { reverb.wetDryMix = clamped }
        }
    }
    /// Reverb preset used for the atmosphere loop.
    public var reverbPreset: AVAudioUnitReverbPreset = .largeHall {
        didSet { reverb.loadFactoryPreset(reverbPreset) }
    }

    /// Delay parameters for the atmosphere loop
    public var delayTime: Double = 0.45 { // seconds
        didSet { delay.delayTime = max(0.0, min(delayTime, 2.0)) }
    }
    public var delayFeedback: Float = 18 { // percent 0..100
        didSet { delay.feedback = max(0, min(delayFeedback, 100)) }
    }
    public var delayLowPassCutoff: Float = 6000 { // Hz
        didSet { delay.lowPassCutoff = max(10, min(delayLowPassCutoff, 20000)) }
    }
    public var delayWetDryMix: Float = 15 { // percent 0..100
        didSet { delay.wetDryMix = max(0, min(delayWetDryMix, 100)) }
    }

    /// Low-pass sweep controls
    public var lpMinCutoff: Float = 4000 // Hz
    public var lpMaxCutoff: Float = 10000 // Hz
    public var lpSweepEnabled: Bool = true
    private var lpSweepTask: Task<Void, Never>?

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

    @Published public var volume: Float {
        didSet { engine.mainMixerNode.outputVolume = max(0, min(volume, 1)) }
    }
    @Published private(set) public var isPlaying: Bool

    public var atmosphereFileName = "atmosphere"
    public var atmosphereFileExtension = "wav"

    // MARK: - Cached audio files to avoid repeated loading and failure spam
    private var cachedAtmosphereFile: AVAudioFile?
    private var atmosphereFileLoadFailed = false
    private var fadeTask: Task<Void, Never>?

    /// Ramps the main mixer output volume to a target over a duration.
    private func rampMixerVolume(to target: Float, duration: TimeInterval) {
        fadeTask?.cancel()
        let startVolume = engine.mainMixerNode.outputVolume
        let clampedTarget = max(0, min(target, 1))
        guard duration > 0 else {
            engine.mainMixerNode.outputVolume = clampedTarget
            return
        }
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = 60
            let stepDuration = duration / Double(steps)
            for i in 1...steps {
                if Task.isCancelled { return }
                let t = Float(i) / Float(steps)
                let eased = t * t * (3 - 2 * t) // smoothstep easing
                let newVol = startVolume + (clampedTarget - startVolume) * eased
                self.engine.mainMixerNode.outputVolume = newVol
                try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
            }
            self.engine.mainMixerNode.outputVolume = clampedTarget
        }
    }

    public init() {
        self.engine = AVAudioEngine()
        self.player = AVAudioPlayerNode()
        reverb.loadFactoryPreset(reverbPreset)
        reverb.wetDryMix = reverbWetDryMix

        // Configure EQ low-pass band
        if let band = eq.bands.first {
            band.filterType = .lowPass
            band.frequency = (lpMinCutoff + lpMaxCutoff) / 2
            band.bypass = false
            band.bandwidth = 0.5
            band.gain = 0
        }
        // Configure delay
        delay.delayTime = delayTime
        delay.feedback = delayFeedback
        delay.lowPassCutoff = delayLowPassCutoff
        delay.wetDryMix = delayWetDryMix

        self.volume = 0.25
        self.isPlaying = false

        // Platform-dependent audio session configuration:
        // On macOS, AVAudioSession is not used and is skipped.
        // On iOS/tvOS/watchOS, configure AVAudioSession for playback.
        configureAudioSession()

        // Create and attach bass node once to improve reuse and avoid detachment on stop/start.
        self.bassNode = makeBassNode(frequency: bassFrequency, bpm: bassBPM, gain: bassGain)

        attachAndConnectNodes()
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

    private func attachAndConnectNodes() {
        engine.attach(player)
        engine.attach(reverb)
        engine.attach(eq)
        engine.attach(delay)
        if let bass = bassNode { engine.attach(bass) }
        let mainMixer = engine.mainMixerNode
        engine.connect(player, to: eq, format: nil)
        engine.connect(eq, to: delay, format: nil)
        engine.connect(delay, to: reverb, format: nil)
        engine.connect(reverb, to: mainMixer, format: nil)
        if let bass = bassNode { engine.connect(bass, to: mainMixer, format: nil) }
        mainMixer.outputVolume = volume
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

        guard let url = Bundle.main.url(forResource: atmosphereFileName, withExtension: atmosphereFileExtension),
              let audioFile = try? AVAudioFile(forReading: url) else {
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

        engine.mainMixerNode.outputVolume = 0.0
        player.play()

        lpSweepTask?.cancel()
        if lpSweepEnabled, let band = eq.bands.first {
            lpSweepTask = Task { @MainActor [weak self] in
                guard let self else { return }
                var t: Double = 0
                while self.isPlaying && !Task.isCancelled {
                    t += 0.02
                    let normalized = Float((sin(t * 0.05) + 1) / 2) // 0..1
                    let cutoff = lpMinCutoff + (lpMaxCutoff - lpMinCutoff) * normalized
                    band.frequency = cutoff
                    try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
                }
            }
        }

        rampMixerVolume(to: volume, duration: 2.5)
        isPlaying = true
    }

    /// Stops the ambient audio playback and effect modulations.
    public func stop() {
        // Disable bass before stopping playback
        fadeTask?.cancel()
        lpSweepTask?.cancel()
        lpSweepTask = nil
        bassEnabled = false

        if player.isPlaying {
            player.stop()
        }

        isPlaying = false
        engine.mainMixerNode.outputVolume = 0.0

        // Instead of detaching and nil-ing nodes on stop, just let them remain attached for reuse.
        // Bass node runs as part of the engine graph.
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
        atmosphereFileLoadFailed = false

        if let bass = bassNode {
            engine.detach(bass)
            bassNode = nil
        }

        engine.detach(reverb)
        engine.detach(eq)
        engine.detach(delay)

        engine.stop()
    }

    @MainActor
    deinit {
        teardown()
    }
}

