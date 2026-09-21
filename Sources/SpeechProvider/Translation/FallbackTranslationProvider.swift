import Foundation

actor FallbackTranslationProvider: TranslationProvider {
    private let primary: any TranslationProvider
    private let fallback: any TranslationProvider

    init(primary: any TranslationProvider, fallback: any TranslationProvider) {
        self.primary = primary
        self.fallback = fallback
    }

    func prepare() async throws {
        try await primary.prepare()
    }

    func translate(text: String, from source: String, to target: String) async throws -> String {
        do {
            return try await primary.translate(text: text, from: source, to: target)
        } catch {
            return try await fallback.translate(text: text, from: source, to: target)
        }
    }
}
