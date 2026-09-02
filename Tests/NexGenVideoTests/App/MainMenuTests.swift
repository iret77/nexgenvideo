import AppKit
import Testing
@testable import NexGenVideo

@Suite("Main menu")
@MainActor
struct MainMenuTests {
    @Test func importMediaUsesCommandIAndResponderChain() throws {
        let mainMenu = MainMenuBuilder.buildMenu()
        let fileMenu = try #require(mainMenu.items.first { $0.submenu?.title == "File" }?.submenu)
        let importItem = try #require(fileMenu.items.first { $0.title == "Import Media…" })

        #expect(importItem.action == #selector(EditorActions.importMedia(_:)))
        #expect(importItem.target == nil)
        #expect(importItem.keyEquivalent == "i")
        #expect(importItem.keyEquivalentModifierMask == [.command])
    }

    @Test func agentConversationActionsUseDistinctGlobalShortcuts() throws {
        let mainMenu = MainMenuBuilder.buildMenu()
        let agentMenu = try #require(
            mainMenu.items.first { $0.submenu?.title == "Agent" }?.submenu
        )
        let expected: [(String, Selector, String)] = [
            ("New Conversation", #selector(EditorActions.newAgentConversation(_:)), "n"),
            ("Conversation History", #selector(EditorActions.showAgentConversationHistory(_:)), "h"),
            ("Previous Conversation", #selector(EditorActions.selectPreviousAgentConversation(_:)), "["),
            ("Next Conversation", #selector(EditorActions.selectNextAgentConversation(_:)), "]"),
            ("Close Conversation", #selector(EditorActions.closeAgentConversation(_:)), "w"),
        ]

        for (title, action, key) in expected {
            let item = try #require(agentMenu.items.first { $0.title == title })
            #expect(item.action == action)
            #expect(item.target == nil)
            #expect(item.keyEquivalent == key)
            #expect(item.keyEquivalentModifierMask == [.command, .shift])
        }
    }
}
