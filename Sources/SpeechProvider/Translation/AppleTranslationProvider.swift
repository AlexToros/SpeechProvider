import Foundation
import Translation

@available(macOS 26.4, *)
actor AppleTranslationProvider: TranslationProvider {
    private struct LanguagePair: Hashable {
        let source: Locale.Language
        let target: Locale.Language
    }

    func prepare() async throws {}

    func translate(text: String, from source: String, to target: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard source != target else { return trimmed }

        let pair = LanguagePair(
            source: Locale.Language(identifier: source),
            target: Locale.Language(identifier: target)
        )
        let session = try await session(for: pair)
        return try await session.translate(trimmed).targetText
    }

    private func session(for pair: LanguagePair) async throws -> TranslationSession {
        let availability = LanguageAvailability(preferredStrategy: .lowLatency)
        guard await availability.status(from: pair.source, to: pair.target) == .installed else {
            throw AppleTranslationError.languagePairNotInstalled
        }

        let session = TranslationSession(
            installedSource: pair.source,
            target: pair.target,
            preferredStrategy: .lowLatency
        )
        try await session.prepareTranslation()
        return session
    }
}

enum AppleTranslationError: LocalizedError {
    case languagePairNotInstalled

    var errorDescription: String? {
        switch self {
        case .languagePairNotInstalled:
            "Для этой языковой пары не установлен системный пакет перевода"
        }
    }
}
