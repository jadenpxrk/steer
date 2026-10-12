@preconcurrency import AVFoundation
import Speech

/// On-device dictation: SpeechAnalyzer's dictation model on iOS 26 and later, SFSpeechRecognizer before that. Audio never leaves the phone.
@MainActor
final class SpeechInputController: ObservableObject {
    static let willRecord = Notification.Name("app.steer.dictation.willRecord")
    static let didStopRecording = Notification.Name("app.steer.dictation.didStopRecording")
    @Published private(set) var transcript = ""
    @Published private(set) var isListening = false
    @Published private(set) var isStarting = false
    @Published private(set) var isFinal = false
    @Published var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// The iOS 26 session (`AnalyzerDictation`), typed loosely because of its availability.
    private var analyzerDictation: AnyObject?
    private var recordingID = UUID()
    private var language = ""
    private var ownsAudioSession = false

    func toggle(language: String = "") {
        if isListening || isStarting {
            Task { await finishListening() }
        } else {
            self.language = language
            requestPermissionAndStart()
        }
    }

    /// Stops at once, dropping speech not yet transcribed.
    func stop() {
        recordingID = UUID()
        isStarting = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        if #available(iOS 26, *), let session = analyzerDictation as? AnalyzerDictation {
            session.cancel()
        }
        analyzerDictation = nil
        let wasListening = isListening
        isListening = false
        if wasListening, !transcript.isEmpty { isFinal = true }
        if ownsAudioSession {
            ownsAudioSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            NotificationCenter.default.post(name: Self.didStopRecording, object: nil)
        }
    }

    /// Stops listening but lets the last words finish transcribing first.
    private func finishListening() async {
        if #available(iOS 26, *), let session = analyzerDictation as? AnalyzerDictation, isListening {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            await session.finish()
        }
        stop()
    }

    private func requestPermissionAndStart() {
        stop()
        let id = recordingID
        isStarting = true
        Task { [weak self] in
            guard let self else { return }
            guard await AVAudioApplication.requestRecordPermission() else {
                fail("Enable Microphone for Steer in Settings.", id: id)
                return
            }
            guard recordingID == id else { return }
            let status = await Self.speechAuthorization()
            guard recordingID == id else { return }
            guard status == .authorized else {
                fail("Enable Speech Recognition for Steer in Settings.", id: id)
                return
            }
            do {
                let locale = language.isEmpty ? Locale.current : Locale(identifier: language)
                if #available(iOS 26, *), let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
                    try await startAnalyzer(locale: supported, id: id)
                } else {
                    try startRecognizer(locale: locale, id: id)
                }
            } catch {
                fail(error.localizedDescription, id: id)
            }
        }
    }

    private func fail(_ message: String, id: UUID) {
        guard recordingID == id else { return }
        errorMessage = message
        stop()
    }

    /// Activates recording and returns the microphone's format, or throws when no microphone is usable.
    private func beginRecording() throws -> AVAudioFormat {
        NotificationCenter.default.post(name: Self.willRecord, object: nil)
        ownsAudioSession = true
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        transcript = ""
        isFinal = false
        errorMessage = nil
        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        // AVAudioEngine raises an Objective-C exception (uncatchable here) for a tap with an empty format, which is what
        // the input reports when no microphone is usable (another app or a call holds it, or a Simulator without one).
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechInputError.noMicrophone }
        return format
    }

    @available(iOS 26, *)
    private func startAnalyzer(locale: Locale, id: UUID) async throws {
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        // The model downloads once per language, managed by iOS.
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        guard recordingID == id else { return }
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechInputError.unavailable
        }
        guard recordingID == id else { return }
        let format = try beginRecording()
        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        guard let converter = AVAudioConverter(from: format, to: target) else { throw SpeechInputError.unavailable }
        Self.installTap(on: audioEngine.inputNode, format: format, converter: converter, target: target, feeding: continuation)
        audioEngine.prepare()
        try audioEngine.start()
        let session = AnalyzerDictation(transcriber: transcriber, input: continuation)
        analyzerDictation = session
        try await session.start(input: input) { [weak self] text in
            guard let self, self.recordingID == id else { return }
            self.transcript = text
        } failed: { [weak self] error in
            self?.fail(error.localizedDescription, id: id)
        }
        guard recordingID == id else { return }
        isStarting = false
        isListening = true
    }

    private func startRecognizer(locale: Locale, id: UUID) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechInputError.unavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechInputError.onDeviceUnavailable
        }
        let format = try beginRecording()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        Self.installTap(on: audioEngine.inputNode, format: format, feeding: request)
        audioEngine.prepare()
        try audioEngine.start()
        isStarting = false
        isListening = true
        task = Self.recognize(with: recognizer, request: request) { [weak self] text, isFinal, error in
            guard let self, self.recordingID == id else { return }
            if let text {
                self.transcript = text
                self.isFinal = isFinal
                if isFinal { self.stop() }
            }
            if let error, !self.isFinal {
                self.errorMessage = error
                self.stop()
            }
        }
    }

    // Speech and audio call these back on their own threads. Inside this main-actor class they would be main-actor
    // closures, which Swift 6 traps on when called from another thread.

    nonisolated private static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    nonisolated private static func installTap(
        on input: AVAudioInputNode, format: AVAudioFormat, feeding request: SFSpeechAudioBufferRecognitionRequest
    ) {
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    /// Converts microphone buffers to the analyzer's format as they arrive.
    @available(iOS 26, *)
    nonisolated private static func installTap(
        on input: AVAudioInputNode, format: AVAudioFormat, converter: AVAudioConverter, target: AVAudioFormat,
        feeding continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / format.sampleRate) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            _ = converter.convert(to: converted, error: nil) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            if converted.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: converted)) }
        }
    }

    nonisolated private static func recognize(
        with recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
        update: @escaping @MainActor (String?, Bool, String?) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let message = error?.localizedDescription
            Task { @MainActor in update(text, isFinal, message) }
        }
    }
}

/// One iOS 26 dictation run: the analyzer, its audio input, and the task collecting results.
/// Finished segments accumulate; the in-progress (volatile) segment is shown after them and replaced as it settles.
@available(iOS 26, *)
@MainActor
private final class AnalyzerDictation {
    private let transcriber: DictationTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var results: Task<Void, Never>?

    init(transcriber: DictationTranscriber, input: AsyncStream<AnalyzerInput>.Continuation) {
        self.transcriber = transcriber
        analyzer = SpeechAnalyzer(modules: [transcriber])
        self.input = input
    }

    func start(
        input stream: AsyncStream<AnalyzerInput>, update: @escaping @MainActor (String) -> Void,
        failed: @escaping @MainActor (Error) -> Void
    ) async throws {
        let transcriber = transcriber
        results = Task { @MainActor in
            var finished = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal { finished += text }
                    update(finished + (result.isFinal ? "" : text))
                }
            } catch is CancellationError {
            } catch {
                failed(error)
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Ends the audio and waits for the remaining speech to be transcribed.
    func finish() async {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await results?.value
    }

    func cancel() {
        input.finish()
        results?.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}

private enum SpeechInputError: LocalizedError {
    case unavailable
    case onDeviceUnavailable
    case noMicrophone

    var errorDescription: String? {
        switch self {
        case .unavailable: "Speech recognition is unavailable right now."
        case .onDeviceUnavailable: "On-device speech recognition isn't available for this language."
        case .noMicrophone: "No microphone input is available right now."
        }
    }
}
