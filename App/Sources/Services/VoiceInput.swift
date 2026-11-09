import AVFoundation
import Foundation
import Observation
@preconcurrency import WhisperKit

/// Optional on-device speech-to-text with Whisper. Nothing is downloaded until the user installs it;
/// the microphone button only appears once the model is on the device.
@MainActor
@Observable
final class VoiceInput {
    static let shared = VoiceInput()

    /// Whisper large-v3 (2024-09-30), ~627 MB, runs on A15 and newer.
    static let model = "openai_whisper-large-v3-v20240930_626MB"
    static let approximateSize = "627 MB"
    static let vocabulary = "nginx, systemctl, journalctl, Docker, docker compose, git, GitHub, SSH, sudo, apt, npm, Node.js, Python, Postgres, Redis, Kubernetes, Codex, Claude Code, tmux, cron, curl, localhost, YAML, JSON, deploy, Logs."

    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case installed
        case failed(String)
    }

    private(set) var state: State = .notInstalled
    private(set) var isRecording = false
    private(set) var isTranscribing = false
    private(set) var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var meter: Task<Void, Never>?
    private var whisper: WhisperKit?
    private var downloadTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private let folderKey = "voice.modelFolder"

    private init() {
        if let path = defaults.string(forKey: folderKey), FileManager.default.fileExists(atPath: path) {
            state = .installed
        }
    }

    var isInstalled: Bool { state == .installed }

    private var downloadBase: URL {
        let base = URL.applicationSupportDirectory.appending(path: "Whisper", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = base
        try? url.setResourceValues(values)
        return base
    }

    func install() {
        guard downloadTask == nil else { return }
        state = .downloading(0)
        downloadTask = Task {
            do {
                let folder = try await WhisperKit.download(
                    variant: Self.model, downloadBase: downloadBase, useBackgroundSession: false,
                    progressCallback: { progress in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in
                            if case .downloading = VoiceInput.shared.state { VoiceInput.shared.state = .downloading(fraction) }
                        }
                    })
                defaults.set(folder.path, forKey: folderKey)
                state = .installed
            } catch is CancellationError {
                state = .notInstalled
            } catch {
                state = .failed(error.localizedDescription)
            }
            downloadTask = nil
        }
    }

    func cancelInstall() {
        downloadTask?.cancel()
        downloadTask = nil
        state = .notInstalled
    }

    func remove() {
        whisper = nil
        try? FileManager.default.removeItem(at: downloadBase)
        defaults.removeObject(forKey: folderKey)
        state = .notInstalled
    }

    // MARK: Recording

    /// Starts recording. Returns false if the microphone is not allowed.
    func startRecording() async -> Bool {
        guard isInstalled, !isRecording else { return false }
        guard await AVAudioApplication.requestRecordPermission() else { return false }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appending(path: "deckhand-voice.wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else { return false }
            self.recorder = recorder
            isRecording = true
            meter = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let r = self.recorder else { break }
                    r.updateMeters()
                    self.level = max(0, min(1, (r.averagePower(forChannel: 0) + 50) / 50))
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
            // Load the model while the user speaks so transcription starts right away.
            Task { try? await loadModel() }
            return true
        } catch {
            return false
        }
    }

    func cancelRecording() {
        meter?.cancel()
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Stops recording and returns the transcript.
    func stopAndTranscribe() async throws -> String {
        guard let recorder else { return "" }
        meter?.cancel()
        recorder.stop()
        self.recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isTranscribing = true
        defer { isTranscribing = false }

        let path = recorder.url.path
        defer { try? FileManager.default.removeItem(atPath: path) }
        return try await transcribe(fileAt: path)
    }

    /// Transcribes an audio file (any format AVFoundation reads).
    func transcribe(fileAt path: String) async throws -> String {
        let whisper = try await loadModel()
        let buffer = try AudioProcessor.loadAudio(fromPath: path)
        let samples = AudioProcessor.convertBufferToArray(buffer: buffer)
        var options = DecodingOptions(
            task: .transcribe, language: nil, usePrefillPrompt: true, detectLanguage: true,
            skipSpecialTokens: true, withoutTimestamps: true)
        if let tokenizer = whisper.tokenizer {
            // Bias recognition towards the words people say to a server agent.
            options.promptTokens = tokenizer.encode(text: " " + Self.vocabulary)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func loadModel() async throws -> WhisperKit {
        if let whisper { return whisper }
        guard let folder = defaults.string(forKey: folderKey) else { throw CocoaError(.fileNoSuchFile) }
        let config = WhisperKitConfig(model: Self.model, modelFolder: folder, verbose: false, prewarm: false, load: true, download: false)
        let kit = try await WhisperKit(config)
        whisper = kit
        return kit
    }
}
