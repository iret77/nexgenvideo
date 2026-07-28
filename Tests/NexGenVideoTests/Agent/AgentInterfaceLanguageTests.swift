import Testing
@testable import NexGenVideo

@Suite("Agent interface language")
struct AgentInterfaceLanguageTests {
    @Test("interface localization wins over host locale")
    func interfaceLocalizationWins() {
        let language = AgentInterfaceLanguage.resolve(
            preferredLocalizations: ["en"],
            developmentLocalization: "de"
        )

        #expect(language.identifier == "en")
        #expect(language.displayName == "English")
        #expect(language.instruction.contains("Do not infer a different language"))
        #expect(language.instruction.contains("only when the user explicitly asks"))
    }

    @Test("regional interface localization keeps its identifier")
    func regionalLocalization() {
        let language = AgentInterfaceLanguage.resolve(
            preferredLocalizations: ["de-DE"],
            developmentLocalization: "en"
        )

        #expect(language.identifier == "de-DE")
        #expect(language.displayName == "German")
    }

    @Test("Base falls back to the development localization")
    func baseFallsBack() {
        let language = AgentInterfaceLanguage.resolve(
            preferredLocalizations: ["Base"],
            developmentLocalization: "en"
        )

        #expect(language.identifier == "en")
    }
}
