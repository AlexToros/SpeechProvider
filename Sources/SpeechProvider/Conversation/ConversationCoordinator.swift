import Combine
import Foundation

@available(macOS 26.4, *)
@MainActor
final class ConversationCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case listening
        case failed(String)

        var title: String {
            switch self {
            case .idle: "Готов к началу разговора"
            case .preparing: "Подготавливаю распознавание…"
            case .listening: "Слушаю разговор"
            case let .failed(message): message
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var modelPreparationProgress: Double?
    @Published private(set) var modelPreparationMessage = ""
    @Published private(set) var translationStatus = "Системный перевод ждёт запуска"
    @Published private(set) var translationPreparationProgress: Double?
    @Published private(set) var translationPreparationMessage = ""
    @Published private(set) var availableSources: [AudioSource] = []
    @Published var selectedSource: AudioSource = .system
    @Published var translationBackend: TranslationBackend {
        didSet {
            UserDefaults.standard.set(translationBackend.rawValue, forKey: "translationBackend")
            Task { [weak self] in await self?.translationBackendDidChange() }
        }
    }
    @Published private(set) var utterances: [Utterance] = []
    @Published var selectedRemoteLanguage: ConversationLanguage = .english {
        didSet {
            prepareTranslation(for: selectedRemoteLanguage.rawValue)
        }
    }
    @Published var selectedTargetLanguage: ConversationLanguage {
        didSet {
            prepareTranslation(for: selectedRemoteLanguage.rawValue)
        }
    }
    @Published var phrasePauseSeconds = 0.20 {
        didSet {
            Task { [remoteSegmenter, localSegmenter, phrasePauseSeconds] in
                await remoteSegmenter.setEndSilenceSeconds(phrasePauseSeconds)
                await localSegmenter.setEndSilenceSeconds(phrasePauseSeconds)
            }
        }
    }
    @Published var isOverlayVisible = false {
        didSet {
            if isOverlayVisible {
                overlay.show()
            } else {
                overlay.hide()
            }
        }
    }
    @Published var isOverlayAvailableForScreenCapture = false {
        didSet {
            overlay.setAvailableForScreenCapture(isOverlayAvailableForScreenCapture)
        }
    }

    private let systemCapture: SystemAudioCaptureService
    private let microphoneCapture: MicrophoneCaptureService
    private let remoteSegmenter: EnergyVADSegmenter
    private let localSegmenter: EnergyVADSegmenter
    private let scheduler: TranscriptionScheduler
    private let languageTracker: LanguageTracker
    private let overlay: OverlayWindowController
    private let nllbTranslation: NLLBTranslationService
    private let systemTranslation: AppleTranslationProvider
    private let modelPreparationEvents: AsyncStream<ModelPreparationProgress>?
    private let nllbPreparationEvents: AsyncStream<ModelPreparationProgress>

    private var systemCaptureTask: Task<Void, Never>?
    private var microphoneCaptureTask: Task<Void, Never>?
    private var transcriptionResultTask: Task<Void, Never>?
    private var modelPreparationTask: Task<Void, Never>?
    private var nllbPreparationTask: Task<Void, Never>?
    private var nllbPreparationObservationTask: Task<Void, Never>?
    private var translationTasks: [UUID: Task<Void, Never>] = [:]
    private var remoteTranslationOrder: [UUID] = []
    private var remoteTranslationOrderHead = 0
    private var readyRemoteTranslations: [UUID: String] = [:]
    private var conversationGeneration = 0

    init(
        systemCapture: SystemAudioCaptureService = .init(),
        microphoneCapture: MicrophoneCaptureService = .init(),
        transcriptionEngine: any BatchTranscriptionEngine = WhisperKitTranscriptionEngine(),
        nllbTranslation: NLLBTranslationService = .init(),
        overlay: OverlayWindowController? = nil
    ) {
        self.systemCapture = systemCapture
        self.microphoneCapture = microphoneCapture
        remoteSegmenter = EnergyVADSegmenter(
            speaker: .remote,
            configuration: .init(endSilenceSeconds: 0.20)
        )
        localSegmenter = EnergyVADSegmenter(
            speaker: .local,
            configuration: .init(endSilenceSeconds: 0.20)
        )
        scheduler = TranscriptionScheduler(engine: transcriptionEngine)
        languageTracker = LanguageTracker()
        self.nllbTranslation = nllbTranslation
        self.overlay = overlay ?? OverlayWindowController()
        systemTranslation = AppleTranslationProvider()
        modelPreparationEvents = (transcriptionEngine as? any TranscriptionPreparationProgressReporting)?.preparationProgress
        nllbPreparationEvents = nllbTranslation.preparationProgress
        selectedTargetLanguage = .systemDefault
        translationBackend = TranslationBackend(
            rawValue: UserDefaults.standard.string(forKey: "translationBackend") ?? ""
        ) ?? .system
    }

    func refreshSources() async {
        do {
            availableSources = try await systemCapture.availableSources()
            if !availableSources.contains(selectedSource) {
                selectedSource = .system
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func prepareDefaultTranslation() {
        guard translationBackend == .system else { return }
        let systemLanguage = selectedTargetLanguage.rawValue
        translationStatus = systemLanguage == "en"
            ? "Системный перевод загрузит только нужную пару"
            : "По умолчанию нужна только пара en ↔ \(systemLanguage)"
    }

    func prepareTranslation(for remoteLanguage: String) {
        if translationBackend == .system {
            translationStatus = "Системный перевод: \(remoteLanguage) → \(selectedTargetLanguage.rawValue)"
        } else {
            startNLLBPreparation()
        }
    }

    func start() async {
        guard state != .preparing, state != .listening else { return }
        state = .preparing
        startModelPreparationObservation()
        switch translationBackend {
        case .nllb:
            startNLLBPreparation()
        case .system:
            prepareDefaultTranslation()
        }

        do {
            try await scheduler.prepare()
            startTranscriptionResultTaskIfNeeded()
            let systemStream = systemCapture.chunks()
            let microphoneStream = microphoneCapture.chunks()
            startPipelineTasks(systemStream: systemStream, microphoneStream: microphoneStream)
            try microphoneCapture.start()
            try await systemCapture.start(source: selectedSource)
            modelPreparationProgress = nil
            state = .listening
        } catch {
            await stop()
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        systemCaptureTask?.cancel()
        microphoneCaptureTask?.cancel()
        modelPreparationTask?.cancel()
        systemCaptureTask = nil
        microphoneCaptureTask = nil
        modelPreparationTask = nil

        microphoneCapture.stop()
        await systemCapture.stop()
        await discardPendingConversationWork()
        if case .failed = state {
            return
        }
        state = .idle
    }

    func resetConversation() async {
        await discardPendingConversationWork()
        utterances.removeAll(keepingCapacity: true)
        overlay.clear()
    }

    func manualReplyTargetLanguage() async -> String {
        selectedRemoteLanguage.rawValue
    }

    private func startPipelineTasks(
        systemStream: AsyncStream<AudioChunk>,
        microphoneStream: AsyncStream<AudioChunk>
    ) {
        systemCaptureTask = Task { [remoteSegmenter, scheduler] in
            for await chunk in systemStream where !Task.isCancelled {
                if let segment = await remoteSegmenter.consume(chunk) {
                    await scheduler.submit(segment)
                }
            }
        }

        microphoneCaptureTask = Task { [localSegmenter, scheduler] in
            for await chunk in microphoneStream where !Task.isCancelled {
                if let segment = await localSegmenter.consume(chunk) {
                    await scheduler.submit(segment)
                }
            }
        }

    }

    private func startTranscriptionResultTaskIfNeeded() {
        guard transcriptionResultTask == nil else { return }
        transcriptionResultTask = Task { [weak self, results = scheduler.results] in
            for await result in results where !Task.isCancelled {
                await self?.consumeTranscriptionResult(result)
            }
        }
    }

    private func discardPendingConversationWork() async {
        conversationGeneration &+= 1
        translationTasks.values.forEach { $0.cancel() }
        translationTasks.removeAll(keepingCapacity: true)
        remoteTranslationOrder.removeAll(keepingCapacity: true)
        remoteTranslationOrderHead = 0
        readyRemoteTranslations.removeAll(keepingCapacity: true)
        await scheduler.resetConversation()
        await remoteSegmenter.resetConversation()
        await localSegmenter.resetConversation()
        await languageTracker.resetConversation()
    }

    private func startModelPreparationObservation() {
        modelPreparationTask?.cancel()
        guard let modelPreparationEvents else { return }
        modelPreparationTask = Task { [weak self] in
            for await progress in modelPreparationEvents where !Task.isCancelled {
                self?.updateModelPreparation(progress)
            }
        }
    }

    private func startNLLBPreparation() {
        guard nllbPreparationTask == nil else { return }
        translationStatus = "Подготавливаю локальную модель перевода…"
        startNLLBPreparationObservation()
        nllbPreparationTask = Task { [weak self, nllbTranslation] in
            do {
                try await nllbTranslation.prepare()
                self?.translationStatus = "Локальная модель перевода готова"
            } catch {
                self?.translationStatus = error.localizedDescription
            }
            self?.nllbPreparationTask = nil
        }
    }

    private func startNLLBPreparationObservation() {
        guard nllbPreparationObservationTask == nil else { return }
        nllbPreparationObservationTask = Task { [weak self, nllbPreparationEvents] in
            for await progress in nllbPreparationEvents where !Task.isCancelled {
                self?.translationPreparationProgress = progress.fractionCompleted
                self?.translationPreparationMessage = progress.message
            }
        }
    }

    private func translationBackendDidChange() async {
        switch translationBackend {
        case .nllb:
            startNLLBPreparation()
        case .system:
            prepareDefaultTranslation()
        }
    }

    private func updateModelPreparation(_ progress: ModelPreparationProgress) {
        modelPreparationProgress = progress.fractionCompleted
        modelPreparationMessage = progress.message
    }

    private func consumeTranscriptionResult(_ result: Result<TranscribedSegment, Error>) async {
        let resultGeneration = conversationGeneration
        switch result {
        case let .failure(error):
            guard resultGeneration == conversationGeneration else { return }
            state = .failed(error.localizedDescription)
        case let .success(transcribed):
            let language = await languageTracker.language(
                for: transcribed.segment.speaker,
                detected: transcribed.transcription.language,
                confidence: transcribed.transcription.languageConfidence
            )
            guard resultGeneration == conversationGeneration else { return }
            if transcribed.segment.speaker == .remote,
               let recognizedLanguage = ConversationLanguage(rawValue: language),
               selectedRemoteLanguage != recognizedLanguage {
                selectedRemoteLanguage = recognizedLanguage
            }
            var utterance = Utterance(
                speaker: transcribed.segment.speaker,
                startedAt: transcribed.segment.startedAt,
                endedAt: transcribed.segment.endedAt,
                originalText: transcribed.transcription.text,
                detectedLanguage: language,
                languageConfidence: transcribed.transcription.languageConfidence
            )

            if language == selectedTargetLanguage.rawValue {
                utterance.russianText = utterance.originalText
            }

            guard resultGeneration == conversationGeneration else { return }
            utterances.append(utterance)
            if utterance.speaker == .remote {
                remoteTranslationOrder.append(utterance.id)
                if let translatedText = utterance.russianText {
                    readyRemoteTranslations[utterance.id] = translatedText
                }
            }
            if utterances.count > 500 {
                utterances.removeFirst(utterances.count - 500)
            }
            guard language != selectedTargetLanguage.rawValue else {
                if utterance.speaker == .remote {
                    enqueueReadyOverlayTranslations()
                }
                return
            }
            startTranslation(
                for: utterance,
                sourceLanguage: language,
                targetLanguage: selectedTargetLanguage.rawValue,
                backend: translationBackend,
                conversationGeneration: resultGeneration
            )
        }
    }

    private func startTranslation(
        for utterance: Utterance,
        sourceLanguage: String,
        targetLanguage: String,
        backend: TranslationBackend,
        conversationGeneration: Int
    ) {
        let task = Task { @MainActor [weak self, nllbTranslation, systemTranslation] in
            defer {
                self?.translationTasks[utterance.id] = nil
            }
            do {
                let translatedText: String
                switch backend {
                case .nllb:
                    translatedText = try await nllbTranslation.translate(
                        text: utterance.originalText,
                        from: sourceLanguage,
                        to: targetLanguage
                    )
                case .system:
                    translatedText = try await systemTranslation.translate(
                        text: utterance.originalText,
                        from: sourceLanguage,
                        to: targetLanguage
                    )
                }
                guard !Task.isCancelled else { return }
                self?.applyTranslation(
                    translatedText,
                    to: utterance.id,
                    conversationGeneration: conversationGeneration
                )
            } catch {
                guard !Task.isCancelled,
                      self?.conversationGeneration == conversationGeneration else { return }
                self?.translationStatus = error.localizedDescription
            }
        }
        translationTasks[utterance.id] = task
    }

    private func applyTranslation(
        _ translatedText: String,
        to utteranceID: UUID,
        conversationGeneration: Int
    ) {
        guard conversationGeneration == self.conversationGeneration,
              let index = utterances.firstIndex(where: { $0.id == utteranceID }) else { return }
        utterances[index].russianText = translatedText
        if utterances[index].speaker == .remote {
            readyRemoteTranslations[utteranceID] = translatedText
            enqueueReadyOverlayTranslations()
        }
    }

    private func enqueueReadyOverlayTranslations() {
        while remoteTranslationOrderHead < remoteTranslationOrder.count {
            let utteranceID = remoteTranslationOrder[remoteTranslationOrderHead]
            guard let translatedText = readyRemoteTranslations.removeValue(forKey: utteranceID) else { break }
            overlay.enqueue(text: translatedText)
            remoteTranslationOrderHead += 1
        }

        if remoteTranslationOrderHead >= 32,
           remoteTranslationOrderHead * 2 >= remoteTranslationOrder.count {
            remoteTranslationOrder.removeFirst(remoteTranslationOrderHead)
            remoteTranslationOrderHead = 0
        }
    }
}
