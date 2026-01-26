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

    @Published var volume: Float {
        didSet { engine.mainMixerNode.outputVolume = max(0, min(volume, 1)) }
    }
    private var timer: DispatchSourceTimer?
    @Published private(set) var isPlaying: Bool

    private let audioFileName = "atmosphere"
    private let audioFileExtension = "wav"

    /// Initializes the ambient audio engine, configures the audio session and audio nodes.
    init() {
        self.engine = AVAudioEngine()
        self.player = AVAudioPlayerNode()
        self.reverb = AVAudioUnitReverb()
        self.delay = AVAudioUnitDelay()
        self.filter = AVAudioUnitEQ(numberOfBands: 1)
        self.volume = 1.0
        self.isPlaying = false

        // Audio session configuration is not applicable on macOS.
        configureNodes()
        attachAndConnectNodes()
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

    private func attachAndConnectNodes() {
        engine.attach(player)
        engine.attach(delay)
        engine.attach(reverb)
        engine.attach(filter)

        let mainMixer = engine.mainMixerNode

        // player -> delay -> reverb -> filter -> mainMixer
        engine.connect(player, to: delay, format: nil)
        engine.connect(delay, to: reverb, format: nil)
        engine.connect(reverb, to: filter, format: nil)
        engine.connect(filter, to: mainMixer, format: nil)

        mainMixer.outputVolume = volume
    }

    private func loadAndScheduleLoop() {
        guard let url = Bundle.main.url(forResource: audioFileName, withExtension: audioFileExtension) else {
            print("AmbientAudioEngine: Audio file \(audioFileName).\(audioFileExtension) not found in bundle.")
            return
        }

        do {
            let audioFile = try AVAudioFile(forReading: url)
            scheduleLoop(audioFile: audioFile)
        } catch {
            print("AmbientAudioEngine: Failed to load audio file: \(error)")
        }
    }

    private func scheduleLoop(audioFile: AVAudioFile) {
        player.scheduleFile(audioFile, at: nil, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.scheduleLoop(audioFile: audioFile)
        })
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
        isPlaying = true
        startModulationTimer()
    }

    /// Stops the ambient audio playback and effect modulations.
    func stop() {
        if player.isPlaying {
            player.stop()
        }
        timer?.cancel()
        timer = nil
        isPlaying = false
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

            // WetDryMix modulation for reverb: base 30, ±20 over 60 seconds
            let reverbWetDryBase = 30.0
            let reverbWetDryRange = 20.0
            let reverbWetDryMix = reverbWetDryBase + sineWave(period: 60, amplitude: reverbWetDryRange)

            // Delay feedback modulation: base 20, ±15 over 120 seconds
            let delayFeedbackBase = 20.0
            let delayFeedbackRange = 15.0
            let delayFeedback = delayFeedbackBase + sineWave(period: 120, amplitude: delayFeedbackRange, offset: .pi / 4)

            // Filter cutoff frequency modulation: base 5000, ±3500 over 180 seconds
            let filterCutoffBase = 5000.0
            let filterCutoffRange = 3500.0
            let filterCutoff = filterCutoffBase + sineWave(period: 180, amplitude: filterCutoffRange, offset: .pi / 2)

            // Reverb wetDryMix modulation (secondary) over 90 seconds to add a slight effect
            let reverbWetDrySecondary = 5.0 * sin((2 * .pi / 90) * elapsedSeconds)

            DispatchQueue.main.async {
                self.reverb.wetDryMix = Float(max(0, min(100, reverbWetDryMix + reverbWetDrySecondary)))
                self.delay.feedback = Float(max(0, min(100, delayFeedback)))
                if let band = self.filter.bands.first {
                    band.frequency = Float(max(100, min(22000, filterCutoff)))
                }
            }
        }
        timer?.resume()
    }
}

