import AVFoundation
import Foundation

/// Detects loud transient sounds (like golf ball impacts) using the device microphone.
/// Designed for hands-free slow-motion replay triggering.
final class AudioImpactDetector {

    // MARK: - Callbacks

    /// Called on the main thread when an impact is detected
    var onImpactDetected: (() -> Void)?

    /// Called with current audio level (0.0-1.0) for optional visual feedback
    var onAudioLevel: ((Float) -> Void)?

    // MARK: - Configuration

    /// Sensitivity from 0.0 (low - ignores more sounds) to 1.0 (high - triggers easily)
    /// Higher sensitivity = lower threshold = triggers more easily
    var sensitivity: Float = 0.5 {
        didSet {
            sensitivity = max(0.0, min(1.0, sensitivity))
            updateThreshold()
        }
    }

    /// Cooldown period to prevent rapid re-triggers (e.g., from swing echo or follow-through)
    var cooldownPeriod: TimeInterval = 4.0

    // MARK: - Private Properties

    private var audioEngine: AVAudioEngine?
    private var isRunning = false
    private var lastTriggerTime: Date?

    // Threshold is inversely related to sensitivity
    // Low sensitivity (0.0) -> high threshold (0.8) - only very loud sounds
    // High sensitivity (1.0) -> low threshold (0.1) - most sounds trigger
    private var threshold: Float = 0.4

    // Track recent audio levels to detect sudden spikes (transients)
    private var recentLevels: [Float] = []
    private let recentLevelsCount = 5

    // MARK: - Public Methods

    func start() {
        guard !isRunning else { return }

        // Configure audio session for recording
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)
        } catch {
            print("AudioImpactDetector: Failed to configure audio session: \(error)")
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Install tap to monitor audio levels
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        do {
            try engine.start()
            audioEngine = engine
            isRunning = true
            print("AudioImpactDetector: Started listening (sensitivity: \(sensitivity), threshold: \(threshold))")
        } catch {
            print("AudioImpactDetector: Failed to start audio engine: \(error)")
        }
    }

    func stop() {
        guard isRunning, let engine = audioEngine else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        isRunning = false
        recentLevels.removeAll()
        print("AudioImpactDetector: Stopped")
    }

    // MARK: - Private Methods

    private func updateThreshold() {
        // Map sensitivity (0-1) to threshold (0.7 - 0.05)
        // Lower sensitivity = higher threshold = harder to trigger
        // Higher sensitivity = lower threshold = easier to trigger
        threshold = 0.7 - (sensitivity * 0.65)
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(from: 0, to: Int(buffer.frameLength), by: buffer.stride).map { channelDataValue[$0] }

        // Calculate RMS (root mean square) for this buffer
        let rms = sqrt(channelDataValueArray.map { $0 * $0 }.reduce(0, +) / Float(buffer.frameLength))

        // Also calculate peak for transient detection
        let peak = channelDataValueArray.map { abs($0) }.max() ?? 0

        // Use combination of RMS and peak for better transient detection
        let level = max(rms * 2, peak) // Weight peak higher for transient detection

        // Report level for UI feedback
        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(min(1.0, level))
        }

        // Track recent levels for spike detection
        recentLevels.append(level)
        if recentLevels.count > recentLevelsCount {
            recentLevels.removeFirst()
        }

        // Detect transient: current level significantly higher than recent average
        guard recentLevels.count >= recentLevelsCount else { return }

        let recentAverage = recentLevels.dropLast().reduce(0, +) / Float(recentLevels.count - 1)
        let currentLevel = recentLevels.last ?? 0

        // Transient detection: current level must be above threshold AND significantly higher than recent average
        let isTransient = currentLevel > threshold && currentLevel > recentAverage * 3.0

        if isTransient {
            handlePotentialImpact(level: currentLevel)
        }
    }

    private func handlePotentialImpact(level: Float) {
        // Check cooldown
        if let lastTrigger = lastTriggerTime {
            let elapsed = Date().timeIntervalSince(lastTrigger)
            if elapsed < cooldownPeriod {
                return // Still in cooldown
            }
        }

        // Trigger detected!
        lastTriggerTime = Date()
        print("AudioImpactDetector: Impact detected! Level: \(String(format: "%.3f", level)), Threshold: \(String(format: "%.3f", threshold))")

        DispatchQueue.main.async { [weak self] in
            self?.onImpactDetected?()
        }
    }
}
