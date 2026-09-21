import Foundation

actor NLLBTranslationProvider: TranslationProvider {
    struct Configuration: Sendable {
        var pythonExecutable: String
        var modelDirectory: String
        var beamSize: Int

        static func developmentDefault(root: URL) -> Configuration {
            Configuration(
                pythonExecutable: root.appendingPathComponent(".venv/bin/python3").path,
                modelDirectory: root.appendingPathComponent("Models/nllb-200-distilled-600M-ct2").path,
                beamSize: 1
            )
        }

        static func applicationSupportDefault() -> Configuration {
            let root = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("SpeechProvider", isDirectory: true)
            return Configuration(
                pythonExecutable: root.appendingPathComponent("nllb-venv/bin/python3").path,
                modelDirectory: root.appendingPathComponent("Models/nllb-200-distilled-600M-ct2").path,
                beamSize: 1
            )
        }
    }

    private struct WorkerRequest: Encodable {
        let id: String
        let text: String
        let source: String
        let target: String
        let beamSize: Int
    }

    private struct WorkerResponse: Decodable {
        let id: String
        let translation: String?
        let error: String?
    }

    private let configuration: Configuration
    private var process: Process?
    private var input: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<String, Error>] = [:]

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func prepare() async throws {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: configuration.pythonExecutable) else {
            throw TranslationError.workerNotInstalled(configuration.pythonExecutable)
        }
        guard FileManager.default.fileExists(atPath: configuration.modelDirectory) else {
            throw TranslationError.modelNotInstalled(configuration.modelDirectory)
        }
        guard let workerURL = Bundle.module.url(forResource: "nllb_worker", withExtension: "py") else {
            throw TranslationError.workerResourceMissing
        }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.pythonExecutable)
        process.arguments = [
            workerURL.path,
            "--model", configuration.modelDirectory,
        ]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        self.process = process
        input = inputPipe.fileHandleForWriting

        readerTask = Task { [weak self] in
            do {
                for try await line in outputPipe.fileHandleForReading.bytes.lines {
                    await self?.consume(line: line)
                }
                await self?.failAll(with: TranslationError.workerStopped)
            } catch {
                await self?.failAll(with: error)
            }
        }
    }

    func translate(text: String, from source: String, to target: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard source != target else { return trimmed }
        if process == nil {
            try await prepare()
        }
        guard let input else { throw TranslationError.workerStopped }

        let id = UUID().uuidString
        let request = WorkerRequest(
            id: id,
            text: trimmed,
            source: source,
            target: target,
            beamSize: configuration.beamSize
        )
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try input.write(contentsOf: payload)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func consume(line: String) {
        guard
            let data = line.data(using: .utf8),
            let response = try? JSONDecoder().decode(WorkerResponse.self, from: data),
            let continuation = pending.removeValue(forKey: response.id)
        else {
            return
        }

        if let translation = response.translation {
            continuation.resume(returning: translation)
        } else {
            continuation.resume(throwing: TranslationError.workerFailure(response.error ?? "unknown error"))
        }
    }

    private func failAll(with error: Error) {
        let continuations = pending.values
        pending.removeAll(keepingCapacity: true)
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
        process = nil
        input = nil
    }
}

actor NLLBTranslationService: TranslationProvider, PreparationProgressReporting {
    nonisolated let preparationProgress: AsyncStream<ModelPreparationProgress>

    private let configuration: NLLBTranslationProvider.Configuration
    private let continuation: AsyncStream<ModelPreparationProgress>.Continuation
    private let provider: NLLBTranslationProvider
    private var preparationTask: Task<Void, Error>?

    init(configuration: NLLBTranslationProvider.Configuration = .applicationSupportDefault()) {
        self.configuration = configuration
        provider = NLLBTranslationProvider(configuration: configuration)
        let stream = AsyncStream<ModelPreparationProgress>.makeStream()
        preparationProgress = stream.stream
        continuation = stream.continuation
    }

    func prepare() async throws {
        if let preparationTask {
            return try await preparationTask.value
        }

        let task = Task { [weak self] in
            guard let self else { return }
            try await self.installAndPrepare()
        }
        preparationTask = task
        do {
            try await task.value
            preparationTask = nil
        } catch {
            preparationTask = nil
            throw error
        }
    }

    func translate(text: String, from source: String, to target: String) async throws -> String {
        try await prepare()
        return try await provider.translate(text: text, from: source, to: target)
    }

    private func installAndPrepare() async throws {
        if isInstalled {
            continuation.yield(.init(fractionCompleted: 1, message: "Локальная модель перевода готова"))
            try await provider.prepare()
            return
        }

        continuation.yield(.init(fractionCompleted: nil, message: "Скачиваю и устанавливаю локальную модель перевода…"))
        try await runInstaller()
        continuation.yield(.init(fractionCompleted: nil, message: "Загружаю локальную модель перевода…"))
        try await provider.prepare()
        continuation.yield(.init(fractionCompleted: 1, message: "Локальная модель перевода готова"))
    }

    private var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: configuration.pythonExecutable)
            && FileManager.default.fileExists(atPath: configuration.modelDirectory)
    }

    private func runInstaller() async throws {
        guard let scriptURL = Bundle.module.url(forResource: "setup_nllb", withExtension: "sh") else {
            throw TranslationError.workerResourceMissing
        }
        let root = URL(fileURLWithPath: configuration.modelDirectory)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path, root.path]
        try process.run()

        await process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TranslationError.workerFailure("Не удалось установить локальную модель перевода")
        }
    }
}

private extension Process {
    func waitUntilExit() async {
        await withCheckedContinuation { continuation in
            terminationHandler = { _ in continuation.resume() }
        }
    }
}

enum TranslationError: LocalizedError {
    case workerNotInstalled(String)
    case modelNotInstalled(String)
    case workerResourceMissing
    case workerStopped
    case workerFailure(String)

    var errorDescription: String? {
        switch self {
        case let .workerNotInstalled(path):
            "Python worker не установлен: \(path)"
        case let .modelNotInstalled(path):
            "Модель NLLB не установлена: \(path)"
        case .workerResourceMissing:
            "Ресурс nllb_worker.py не найден"
        case .workerStopped:
            "Процесс локального перевода остановлен"
        case let .workerFailure(message):
            "Ошибка локального перевода: \(message)"
        }
    }
}
