import SwiftUI
import AppKit

@available(macOS 26.4, *)
@main
struct SpeechProviderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var bootstrapper = AppBootstrapper()

    var body: some Scene {
        WindowGroup("Speech Provider") {
            if let coordinator = bootstrapper.coordinator {
                ContentView(coordinator: coordinator)
            } else {
                LaunchScreenView(bootstrapper: bootstrapper)
            }
        }
        .defaultSize(width: 620, height: 420)
    }
}

@available(macOS 26.4, *)
private struct ContentView: View {
    @ObservedObject var coordinator: ConversationCoordinator
    @StateObject private var manualTranslation = ManualTranslationController()
    @State private var followsConversation = true

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Picker("Звук собеседника", selection: $coordinator.selectedSource) {
                    ForEach(coordinator.availableSources) { source in
                        Text(source.title).tag(source)
                    }
                }
                .frame(maxWidth: .infinity)

                Button {
                    Task { await coordinator.refreshSources() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Обновить источники")
            }

            HStack(spacing: 20) {
                Toggle("Overlay", isOn: $coordinator.isOverlayVisible)
                    .toggleStyle(.switch)
                Toggle("В видеозахвате", isOn: $coordinator.isOverlayAvailableForScreenCapture)
                    .toggleStyle(.switch)
                Spacer()
            }

            if coordinator.state == .preparing {
                VStack(alignment: .leading, spacing: 6) {
                    if let progress = coordinator.modelPreparationProgress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView()
                    }
                    Text(coordinator.modelPreparationMessage.isEmpty
                        ? "Подготавливаю распознавание…"
                        : coordinator.modelPreparationMessage
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Начать") {
                    Task { await coordinator.start() }
                }
                .disabled(coordinator.availableSources.isEmpty || isBusy || isListening)

                Button("Остановить") {
                    Task { await coordinator.stop() }
                }
                .disabled(!isListening)

                Button("Новый разговор") {
                    Task { await coordinator.resetConversation() }
                }
                .disabled(coordinator.utterances.isEmpty)
            }

            Picker("Язык собеседника", selection: $coordinator.selectedRemoteLanguage) {
                ForEach(ConversationLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }

            Picker("Переводить на", selection: $coordinator.selectedTargetLanguage) {
                ForEach(ConversationLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Длина фразы")
                    Spacer()
                    Text(String(format: "%.2f с", coordinator.phrasePauseSeconds))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $coordinator.phrasePauseSeconds, in: 0.20...1.20, step: 0.05)
                Text("Меньше — переводить по более коротким паузам")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Picker("Перевод", selection: $coordinator.translationBackend) {
                ForEach(TranslationBackend.allCases) { backend in
                    Text(backend.title).tag(backend)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(coordinator.translationStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if coordinator.translationBackend == .nllb,
                   !coordinator.translationPreparationMessage.isEmpty {
                    if let progress = coordinator.translationPreparationProgress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView()
                    }
                    Text(coordinator.translationPreparationMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(coordinator.utterances) { utterance in
                                UtteranceRow(utterance: utterance)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(ConversationScroll.bottomID)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onScrollPhaseChange { _, newPhase, context in
                        // Content growth is not a user scroll. Only update the
                        // follow mode when a real scrolling interaction settles.
                        guard newPhase == .idle else { return }
                        let geometry = context.geometry
                        followsConversation = geometry.contentOffset.y + geometry.containerSize.height
                            >= geometry.contentSize.height - 2
                    }

                    if !followsConversation {
                        Button {
                            followsConversation = true
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(ConversationScroll.bottomID, anchor: .bottom)
                            }
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.headline)
                                .padding(9)
                        }
                        .buttonStyle(.plain)
                        .background(.regularMaterial, in: Circle())
                        .padding(10)
                        .help("Вернуться к новым репликам")
                    }
                }
                .onChange(of: coordinator.utterances.count) { _, _ in
                    guard followsConversation else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(ConversationScroll.bottomID, anchor: .bottom)
                    }
                }
                .onAppear {
                    DispatchQueue.main.async {
                        proxy.scrollTo(ConversationScroll.bottomID, anchor: .bottom)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack(alignment: .bottom) {
                TextField("Перевести на язык собеседника", text: $manualTranslation.input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await translateManualReply() }
                    }
                Button("Перевести") {
                    Task { await translateManualReply() }
                }
                .disabled(manualTranslation.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manualTranslation.isTranslating)
            }
            if !manualTranslation.output.isEmpty {
                Text(manualTranslation.output)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if !manualTranslation.errorMessage.isEmpty {
                Text(manualTranslation.errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .task {
            await coordinator.refreshSources()
        }
        .frame(minWidth: 560, minHeight: 620)
    }

    private var isBusy: Bool {
        coordinator.state == .preparing
    }

    private func translateManualReply() async {
        let targetLanguage = await coordinator.manualReplyTargetLanguage()
        await manualTranslation.translate(
            to: targetLanguage,
            backend: coordinator.translationBackend
        )
    }

    private var isListening: Bool {
        coordinator.state == .listening
    }

}

private enum ConversationScroll {
    static let bottomID = "conversation-bottom"
}

@available(macOS 26.4, *)
@MainActor
private final class AppBootstrapper: ObservableObject {
    enum State {
        case preparing
        case failed(String)
    }

    @Published private(set) var state: State = .preparing
    @Published private(set) var progress: Double?
    @Published private(set) var message = "Запускаю распознавание…"
    @Published private(set) var coordinator: ConversationCoordinator?

    private let engine = WhisperKitTranscriptionEngine()
    private var preparationTask: Task<Void, Never>?

    init() {
        prepareWhisper()
    }

    func prepareWhisper() {
        guard preparationTask == nil else { return }
        state = .preparing
        progress = nil
        let events = engine.preparationProgress
        preparationTask = Task { [weak self, engine] in
            let observer = Task { [weak self, events] in
                for await update in events where !Task.isCancelled {
                    self?.progress = update.fractionCompleted
                    self?.message = update.message
                }
            }
            defer {
                observer.cancel()
                self?.preparationTask = nil
            }

            do {
                try await engine.prepare()
                self?.message = "Распознавание готово"
                self?.coordinator = ConversationCoordinator(transcriptionEngine: engine)
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }
}

@available(macOS 26.4, *)
private struct LaunchScreenView: View {
    @ObservedObject var bootstrapper: AppBootstrapper

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.indigo.opacity(0.8), .blue.opacity(0.55), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 22) {
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.white)

                Text("Speech Provider")
                    .font(.title.bold())
                    .foregroundStyle(.white)

                switch bootstrapper.state {
                case .preparing:
                    VStack(spacing: 10) {
                        if bootstrapper.progress != nil {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                        } else {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                        }
                        Text(bootstrapper.message)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.82))
                            .multilineTextAlignment(.center)
                        Text("Проверка и подготовка модели может занять несколько минут.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.66))
                            .multilineTextAlignment(.center)
                    }
                    .frame(width: 360)
                case let .failed(message):
                    VStack(spacing: 12) {
                        Text(message)
                            .foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.center)
                        Button("Повторить") {
                            bootstrapper.prepareWhisper()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(width: 360)
                }
            }
            .padding(44)
        }
        .frame(minWidth: 620, minHeight: 420)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private struct UtteranceRow: View {
    let utterance: Utterance

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(utterance.speaker == .remote ? "Собеседник" : "Вы", systemImage: utterance.speaker == .remote ? "person.wave.2" : "mic")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(utterance.originalText)
                .font(.callout)
            if let russianText = utterance.russianText, russianText != utterance.originalText {
                Text(russianText)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
