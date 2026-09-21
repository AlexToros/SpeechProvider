import Combine
import Foundation

@available(macOS 26.4, *)
@MainActor
final class ManualTranslationController: ObservableObject {
    @Published var input = ""
    @Published private(set) var output = ""
    @Published private(set) var isTranslating = false
    @Published private(set) var errorMessage = ""

    private let systemTranslation = AppleTranslationProvider()
    private let nllbTranslation = NLLBTranslationService()

    func translate(to targetLanguage: String, backend: TranslationBackend) async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isTranslating else { return }

        isTranslating = true
        errorMessage = ""
        defer { isTranslating = false }

        do {
            switch backend {
            case .system:
                output = try await systemTranslation.translate(text: text, from: "ru", to: targetLanguage)
            case .nllb:
                output = try await nllbTranslation.translate(text: text, from: "ru", to: targetLanguage)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
