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
}
