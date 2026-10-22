import AppKit
import SwiftUI
import Testing
import WebKit
import WispCore

@testable import Wisp

@Suite(.serialized) @MainActor
struct ConversationIntegrationTests {
    static let partial = #"The policy \(\pi(a\mid s)\) explores.\n\n\[H(\pi)=-\sum"#.replacingOccurrences(of: #"\n"#, with: "\n")
    static let answer =
        partial + #"_a \pi(a)\log\pi(a)\]"# + "\n\n"
        + (1...36).map {
            "Paragraph \($0): a completed answer with enough text to require native scrolling. " + #"\(x_i^2+\alpha\)"#
        }.joined(separator: "\n\n") + "\n\nEND OF ANSWER"

    static func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
    }

    static func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<240 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Native answer layout did not settle")
        throw Failure.timeout
    }

    enum Failure: Error { case timeout }

    static func conversation(_ text: String, finished: Bool = true) -> Conversation {
        var result = Conversation()
        result.begin("Explain policy entropy")
        result.apply(.messageChunk(text))
        if finished { result.finish(stopReason: "end_turn", model: nil) }
        return result
    }

    @Test(arguments: [false, true])
    func completedAndFinalChunkFollowNativeBottom(dark: Bool) async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ConversationView(conversation: Self.conversation(Self.answer), maxHeight: 280))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 720, height: 280),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await Self.wait {
            host.layoutSubtreeIfNeeded()
            return Self.descendants(host, WKWebView.self).first.map { $0.frame.height > 1000 } ?? false
        }
        let scroll = try #require(Self.descendants(host, NSScrollView.self).first { $0.documentView != nil })
        func bottom() -> Bool {
            guard let document = scroll.documentView else { return false }
            return document.bounds.height > 1000 && abs(document.bounds.maxY - scroll.documentVisibleRect.maxY) < 12
        }
        try await Self.wait { bottom() }
        let web = try #require(Self.descendants(host, WKWebView.self).first)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.katex').length") as? Int == 38)
        #expect(
            try await web.evaluateJavaScript("document.documentElement.dataset.theme") as? String == (dark ? "dark" : "light"))

        var streaming = Self.conversation(Self.partial, finished: false)
        host.rootView = ConversationView(conversation: streaming, maxHeight: 280)
        try await Self.wait { Self.descendants(host, WKWebView.self).first.map { $0.frame.height < 280 } ?? false }
        streaming.apply(.messageChunk(String(Self.answer.dropFirst(Self.partial.count))))
        streaming.finish(stopReason: "end_turn", model: nil)
        host.rootView = ConversationView(conversation: streaming, maxHeight: 280)
        try await Self.wait { bottom() }

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        let manualPosition = scroll.documentVisibleRect.minY
        window.setContentSize(NSSize(width: 620, height: 280))
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(abs(scroll.documentVisibleRect.minY - manualPosition) < 15)
        #expect(!bottom())
    }

    @Test(arguments: [false, true])
    func errorOnlyHistoryFollowsNativeBottom(dark: Bool) async throws {
        _ = NSApplication.shared
        var conversation = Conversation()
        for index in 0..<20 {
            conversation.begin("Question \(index)")
            conversation.fail("The request failed")
        }
        let host = NSHostingView(
            rootView:
                ConversationView(conversation: conversation, maxHeight: 280)
                .frame(width: 680, height: 300, alignment: .top))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 680, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await Self.wait {
            host.layoutSubtreeIfNeeded()
            guard let scroll = Self.descendants(host, NSScrollView.self).first,
                let document = scroll.documentView, document.bounds.height > 500
            else { return false }
            return abs(document.bounds.maxY - scroll.documentVisibleRect.maxY) < 12
        }
    }

    @Test(arguments: [false, true])
    func panelSnapshotContainsActualWebKitGlyphs(dark: Bool) async throws {
        _ = NSApplication.shared
        let scratch = URL(filePath: "/tmp/wisp-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let paths = WispPaths(home: scratch)
        let model = AppModel(configStore: ConfigStore(file: paths.configFile), paths: paths)
        let panel = PanelController(model: model)
        defer {
            panel.hide(returnFocus: false)
            model.shutdown()
        }
        panel.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        model.showSample(Self.conversation(#"\[H(\pi)=-\sum_a\pi(a)\log\pi(a)\]"#), catalog: ModelCatalog())
        panel.layOutOffscreen(maxConversationHeight: 300)
        let web = try #require(Self.descendants(panel.hostingView, WKWebView.self).first)
        try await Self.wait {
            (try? await web.evaluateJavaScript(
                "document.querySelectorAll('.katex').length === 1 && document.fonts.status === 'loaded'")) as? Bool == true
        }
        _ = try await web.evaluateJavaScript(
            "document.querySelectorAll('#answer, #answer *').forEach(e => e.style.setProperty('color','rgb(17,231,93)','important'))"
        )
        let bitmap = try #require(panel.renderContent())
        var glyphPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.3 && color.greenComponent > 0.65
                    && color.redComponent < 0.25 && color.blueComponent < 0.5
                {
                    glyphPixels += 1
                }
            }
        }
        #expect(glyphPixels > 100, "renderContent must composite WebKit's actual equation glyphs")
    }
}
