import AppKit
import Testing
import WebKit
import WispCore

@testable import WispRendering

@Suite(.serialized) @MainActor
struct AnswerRenderingTests {
    private static let inline = #"\(\pi(a\mid s)\)"#
    private static let entropy = #"\[H(\pi(\cdot\mid s))=-\sum_a \pi(a\mid s)\log\pi(a\mid s)\]"#
    private static let objective =
        #"\[J(\theta)=\mathbb E_{\tau\sim\pi_\theta}[\sum_{t=0}^{T-1}\gamma^t(r_t+\alpha H(\pi_\theta(\cdot\mid s_t)))]\]"#
    private static let answer = "## Entropy\n\nThe policy " + inline + " explores.\n\n" + entropy + "\n\n" + objective

    private func makeView(width: CGFloat = 680) async throws -> AnswerWebView {
        _ = NSApplication.shared
        let view = AnswerWebView()
        view.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        try await wait(view, "typeof window.renderAnswer === 'function'")
        return view
    }

    private func wait(_ view: WKWebView, _ predicate: String) async throws {
        for _ in 0..<200 {
            if (try? await view.evaluateJavaScript(predicate)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Timed out waiting for \(predicate)")
        throw RenderFailure.timeout
    }

    private enum RenderFailure: Error { case timeout }

    private func render(_ view: AnswerWebView, _ text: String, dark: Bool = false) async throws {
        view.render(text: text, dark: dark)
        // This is queued after the production render call in the same WebKit process.
        _ = try await view.evaluateJavaScript("document.getElementById('answer').innerHTML")
        _ = try await view.callAsyncJavaScript("await document.fonts.ready", in: nil, contentWorld: .page)
    }

    private func count(_ view: WKWebView, _ selector: String) async throws -> Int {
        try await view.callAsyncJavaScript(
            "return document.querySelectorAll(selector).length", arguments: ["selector": selector],
            in: nil, contentWorld: .page) as! Int
    }

    @Test func reproductionTypesetsAndLoadsBundledFonts() async throws {
        let view = try await makeView()
        try await render(view, Self.answer)
        #expect(try await count(view, ".katex") == 3)
        #expect(try await count(view, ".katex-display") == 2)
        #expect(try await count(view, "math annotation") == 3)
        #expect(try await count(view, ".math-source, .katex-error") == 0)
        let fonts = try await view.evaluateJavaScript("document.fonts.check('14px KaTeX_Main')") as? Bool
        #expect(fonts == true)
        #expect(try await count(view, "h2") == 1)
    }

    @Test func delimitersMarkdownCodeAndCurrency() async throws {
        let view = try await makeView()
        try await render(
            view,
            #"""
            **Bold** and *italic* with $x^2$ and \(y_i\).
            $$\frac{1}{2}$$
            \[
            \begin{pmatrix}a & b \\ c & d\end{pmatrix}
            \]
            - List \(x\)
            > Quote \(y\)

            | Formula | Meaning |
            |---|---|
            | $z$ | value |

            `$x$ \(raw\)`
            ```latex
            \[raw\]
            $$raw$$
            ```
            ~~~
            \(also raw\)
            ~~~

                \(indented code\)

            Costs $5 and $10, $2.50 or $1,000. Escaped \$20. Amount $5$.
            """#)
        #expect(try await count(view, ".katex") == 7)
        #expect(try await count(view, ".katex-display") == 2)
        #expect(try await count(view, "strong, em") == 2)
        #expect(try await count(view, "pre code") == 3)
        #expect(try await count(view, "code .katex") == 0)
        #expect(try await count(view, "table .katex, li .katex, blockquote .katex") == 3)
        let text = try await view.evaluateJavaScript("document.body.textContent") as! String
        #expect(text.contains("Costs $5 and $10, $2.50 or $1,000. Escaped $20. Amount $5$."))
        #expect(text.contains(#"$x$ \(raw\)"#))
    }

    @Test func paragraphStartCodeEscapesAndNumericMath() async throws {
        let view = try await makeView()
        for source in [#"`$$x$$`"#, #"`\[x\]`"#, #"> `$$x$$`"#, #"> `\[x\]`"#] {
            try await render(view, source)
            #expect(try await count(view, "code") == 1)
            #expect(try await count(view, ".katex") == 0)
        }
        for fence in ["`", "``"] {
            for math in ["$$x$$", #"\[x\]"#] {
                try await render(view, fence + "foo\n" + math + "\nbar" + fence)
                #expect(try await count(view, "code") == 1)
                #expect(try await count(view, ".katex") == 0)
            }
        }
        for source in [#"\\[x\]"#, #"\$\$x\$\$"#] {
            try await render(view, source)
            #expect(try await count(view, ".katex") == 0)
        }
        try await render(view, #"$2 + 2 = 4$ and $0 \leq p \leq 1$"#)
        #expect(try await count(view, ".katex") == 2)
        try await render(view, "Prose\n" + Self.entropy + "\nAfter")
        #expect(try await count(view, ".katex-display") == 1)
    }

    @Test func streamingEveryBoundaryAndHistoryReplay() async throws {
        let view = try await makeView()
        var live = Conversation()
        live.begin("Explain entropy")
        for character in Self.answer {
            live.apply(.messageChunk(String(character)))
            let source = live.turns[0].answer
            try await render(view, source)
            let closed = source.components(separatedBy: #"\)"#).count + source.components(separatedBy: #"\]"#).count - 2
            #expect(try await count(view, ".katex") == closed)
        }
        live.finish(stopReason: "end_turn", model: nil)
        try await render(view, live.turns[0].answer)
        let completed = try await view.evaluateJavaScript("document.getElementById('answer').innerHTML") as! String
        #expect(try await count(view, ".katex") == 3)

        var replay = Conversation()
        replay.replay(.userMessageChunk("Explain entropy", promptIndex: 0))
        replay.replay(.messageChunk(Self.answer))
        replay.replay(.turnCompleted(stopReason: "end_turn"))
        #expect(replay.turns[0].answer == live.turns[0].answer)
        // History replaces the view when the user leaves and reopens the conversation.
        let reopened = try await makeView()
        try await render(reopened, replay.turns[0].answer)
        let restored = try await reopened.evaluateJavaScript("document.getElementById('answer').innerHTML") as! String
        #expect(restored == completed)

        for source in [#"Before \(\pi("#, #"\[\frac{1}{"#, "$$x^", #"\[\unknowncommand{x}\]"#] {
            try await render(view, source)
            #expect(try await count(view, ".math-source") == 1)
            let text = try await view.evaluateJavaScript("document.body.textContent") as! String
            #expect(text.contains(source))
        }
        try await render(view, "```latex\n" + Self.entropy)
        #expect(try await count(view, "pre code") == 1)
        #expect(try await count(view, ".katex") == 0)
        try await render(view, "")
        #expect(try await count(view, "#answer > *") == 0)
    }

    @Test func appearanceResizeOverflowSelectionAndLinks() async throws {
        let view = try await makeView()
        var reportedHeight: CGFloat = 0
        view.onHeight = { reportedHeight = $0 }
        let long = "\\[" + Array(repeating: "x_i^2", count: 50).joined(separator: "+") + "\\]"
        let inline = #"\("# + Array(repeating: "x_i^2", count: 50).joined(separator: "+") + #"\)"#
        let code = String(repeating: "verbatim ", count: 100)
        let table =
            "| " + Array(repeating: "Column", count: 20).joined(separator: " | ") + " |\n| "
            + Array(repeating: "---", count: 20).joined(separator: " | ") + " |"
        let text =
            Self.answer + "\n\n" + long + "\n\n" + inline + "\n\n```\n" + code + "\n```\n\n" + table
            + "\n\n[Docs](https://example.com)"
        try await render(view, text)
        let light = try await view.evaluateJavaScript("getComputedStyle(document.body).color") as! String
        try await render(view, text, dark: true)
        let dark = try await view.evaluateJavaScript("getComputedStyle(document.body).color") as! String
        #expect(light != dark)
        for width in [680.0, 320.0, 900.0] {
            view.setFrameSize(NSSize(width: width, height: 800))
            try await Task.sleep(for: .milliseconds(100))
            let fits =
                try await view.evaluateJavaScript(
                    "document.documentElement.scrollWidth <= window.innerWidth") as! Bool
            #expect(fits)
            let scrolls =
                try await view.evaluateJavaScript(
                    """
                    (() => {
                        const block = document.querySelectorAll('.katex-display')[2];
                        block.scrollLeft = 100;
                        return block.scrollWidth > block.clientWidth && block.scrollLeft > 0;
                    })()
                    """) as! Bool
            #expect(scrolls)
            let otherOverflows =
                try await view.evaluateJavaScript(
                    """
                    [...document.querySelectorAll('pre, table, p > .katex')]
                        .filter(element => element.scrollWidth > element.clientWidth)
                        .filter(element => { element.scrollLeft = 50; return element.scrollLeft > 0; }).length
                    """) as! Int
            #expect(otherOverflows >= 1)
            let inlineFits =
                try await view.evaluateJavaScript(
                    """
                    (() => {
                        const inline = [...document.querySelectorAll('p > .katex')].at(-1);
                        return inline.clientHeight > 40 || inline.scrollWidth > inline.clientWidth;
                    })()
                    """) as! Bool
            #expect(inlineFits)
            let actualHeight =
                try await view.evaluateJavaScript(
                    "Math.ceil(document.getElementById('answer').getBoundingClientRect().height)") as! Double
            #expect(abs(reportedHeight - actualHeight) <= 1)
        }
        _ = try await view.evaluateJavaScript(
            """
            const range = document.createRange();
            range.selectNodeContents(document.getElementById('answer'));
            getSelection().removeAllRanges(); getSelection().addRange(range);
            """)
        let selection = try await view.evaluateJavaScript("getSelection().toString()") as! String
        #expect(selection.contains("Entropy"))
        #expect(selection.contains("Docs"))
        var opened: URL?
        view.openLink = { opened = $0 }
        _ = try await view.evaluateJavaScript("document.querySelector('a').click()")
        try await Task.sleep(for: .milliseconds(100))
        #expect(opened?.absoluteString == "https://example.com/")
        #expect(view.url == AnswerWebView.documentURL)

        if let directory = ProcessInfo.processInfo.environment["WISP_RENDER_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for dark in [false, true] {
                try await render(view, Self.answer, dark: dark)
                view.setFrameSize(NSSize(width: 680, height: 300))
                let image = try await view.takeSnapshot(configuration: nil)
                let bitmap = NSBitmapImageRep(data: try #require(image.tiffRepresentation))
                let png = try #require(bitmap?.representation(using: .png, properties: [:]))
                try png.write(to: URL(filePath: directory).appending(path: dark ? "dark.png" : "light.png"))
            }
        }
    }

    @Test func untrustedMarkupCannotExecuteOrFetch() async throws {
        let view = try await makeView()
        try await render(
            view,
            #"""
            <script>window.pwned = true</script>
            <img src="https://example.com/tracker" onerror="window.pwned=true">
            [Bad](javascript:alert(1)) ![remote](https://example.com/image.png)
            \(\href{javascript:alert(1)}{click}\)
            \(\includegraphics{https://example.com/image.png}\)
            """#)
        #expect(try await count(view, "#answer script, #answer img, #answer iframe, #answer a") == 0)
        let safe = try await view.evaluateJavaScript("window.pwned === undefined") as! Bool
        #expect(safe)
    }
}
