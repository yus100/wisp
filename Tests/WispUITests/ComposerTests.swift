import AppKit
import Testing
import WispCore

@testable import Wisp

@Suite(.serialized) @MainActor
struct ComposerTests {
    @Test func deletionEditsTheFieldEditor() {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        text.isRichText = false
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 400, height: 80),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = text
        defer { window.close() }

        text.string = "hello world"
        text.setSelectedRange(NSRange(location: 5, length: 0))
        PromptEditing.apply(.toStart, to: text)
        #expect(text.string == " world")

        text.string = "one\ntwo more"
        text.setSelectedRange(NSRange(location: 4, length: 0))
        PromptEditing.apply(.toStart, to: text)
        #expect(text.string == "two more")

        text.string = "👋 hello"
        text.setSelectedRange(NSRange(location: 2, length: 0))
        PromptEditing.apply(.toStart, to: text)
        #expect(text.string == " hello")

        text.string = "hello"
        text.setSelectedRange(NSRange(location: 1, length: 3))
        PromptEditing.apply(.toStart, to: text)
        #expect(text.string == "o")

        text.string = "stay"
        text.setSelectedRange(NSRange(location: 0, length: 0))
        PromptEditing.apply(.toStart, to: text)
        #expect(text.string == "stay")

        text.string = "hello world"
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        PromptEditing.apply(.wordBackward, to: text)
        // Cocoa's word deletion removes the word and leaves the space before it.
        #expect(text.string == "hello ")
    }

    @Test func modelMenuListsThirdPartyModelsAndTheirEfforts() throws {
        let scratch = URL(filePath: "/tmp/wisp-menu-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let paths = WispPaths(home: scratch)
        var config = WispConfig()
        config.launchAtLogin = false
        config.notifyWhenDone = false
        config.remoteControl = false
        try config.save(to: paths.configFile)
        let model = AppModel(configStore: ConfigStore(file: paths.configFile), paths: paths)
        defer { model.shutdown() }
        model.showSample(
            Conversation(),
            catalog: ModelCatalog(
                models: [
                    .init(
                        id: "grok-4.7", name: "Grok 4.7", efforts: ["low", "high"], defaultEffort: "high",
                        supportsReasoning: true, group: "Grok", effortLabels: ["high": "High"]),
                    .init(
                        id: "claude-opus-5-5", name: "Claude Opus 5.5", efforts: ["medium", "max"], defaultEffort: "medium",
                        supportsReasoning: true, group: "Anthropic", effortLabels: ["medium": "Medium", "max": "Max"]),
                    .init(id: "gemini-4-argon", name: "Gemini 4 Argon", supportsReasoning: false, group: "Google"),
                    .init(id: "cursor-helios-alpha", name: "Cursor Helios Alpha", supportsReasoning: false, group: "Cursor"),
                    .init(
                        id: "cursor-helios-alpha-staging", name: "Cursor Helios Alpha", supportsReasoning: false, group: "Cursor"),
                ],
                defaultModelID: "grok-4.7"))

        let titles = ModelMenu.make(for: model).items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles.contains("Grok"))
        #expect(titles.contains("Anthropic"))
        #expect(titles.contains("Google"))
        #expect(titles.contains("Grok 4.7   (Grok Build default)"))
        #expect(titles.contains("Claude Opus 5.5"))
        #expect(titles.contains("Gemini 4 Argon"))
        #expect(titles.contains("Cursor Helios Alpha · cursor-helios-alpha"))
        #expect(titles.contains("Cursor Helios Alpha · cursor-helios-alpha-staging"))
        #expect(titles.contains("Reasoning effort"))
        #expect(titles.contains("Low"))
        #expect(titles.contains("High"))
        #expect(!titles.contains("Max"))
        #expect(!titles.contains("Medium"))

        model.selectModel("claude-opus-5-5")
        #expect(model.config.model == "claude-opus-5-5")
        #expect(model.config.reasoningEffort == "medium")
        #expect(model.modelLabel == "Claude Opus 5.5 · Medium")
        let claude = ModelMenu.make(for: model).items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(claude.contains("Medium"))
        #expect(claude.contains("Max"))
        #expect(!claude.contains("Low"))

        model.selectModel("gemini-4-argon")
        #expect(model.modelLabel == "Gemini 4 Argon")
        #expect(model.config.reasoningEffort == "medium")
        let gemini = ModelMenu.make(for: model).items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(!gemini.contains("Reasoning effort"))

        model.selectModel("retired-model")
        #expect(model.config.model == "retired-model")
        #expect(model.effectiveModelID == "grok-4.7")
        // Medium is Claude's. Grok's list has no medium, so the chip shows the low effort the session would use.
        #expect(model.modelLabel == "Grok 4.7 · Low")
    }
}
