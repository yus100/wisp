import AppKit
import WispCore

/// Renders the README screenshots from sample data with the real panel views, offscreen:
/// `Wisp render-screenshots <directory>` (or `make screenshots`). Nothing is shown and no agent runs.
@MainActor
enum Screenshots {
    static func render(into directory: URL) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .darkAqua)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let samples: [(String, Sample)] = [
                ("panel.png", .init(conversation: diskSpace)),
                ("math.png", .init(conversation: entropy)),
                ("handoff.png", .init(conversation: devSession)),
                ("context.png", .init(conversation: { Conversation(paths: $0) }, compose: researchWithContext)),
                (
                    "history.png",
                    .init(
                        conversation: { Conversation(paths: $0) }, history: pastConversations,
                        compose: { $0.showHistory(refreshing: false) })
                ),
            ]
            for (name, sample) in samples {
                let file = directory.appending(path: name)
                try render(sample).write(to: file)
                print("Wrote \(file.path)")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Wisp: could not render screenshots: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private struct RenderFailure: LocalizedError {
        var errorDescription: String? { "the panel did not lay out" }
    }

    private struct Sample {
        var conversation: (WispPaths) -> Conversation
        /// Saved conversations: title, folder under home, and how long ago, newest first.
        var history: [(String, String, TimeInterval)] = []
        /// Fills in the input row: typed text, attachments, slash commands.
        var compose: (AppModel) -> Void = { _ in }
    }

    private static func render(_ sample: Sample) throws -> Data {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "wisp-screenshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let paths = WispPaths(home: scratch)
        var config = WispConfig()
        config.model = "grok-4-fast"
        config.reasoningEffort = "low"
        try config.save(to: paths.configFile)
        var history = SessionHistory(file: paths.historyFile)
        for (index, (title, folder, age)) in sample.history.enumerated().reversed() {
            let directory = paths.expand(folder.isEmpty ? "~" : "~/" + folder)
            history.record("sample-\(index)", title: title, directory: directory, at: Date().addingTimeInterval(-age))
        }

        let model = AppModel(configStore: ConfigStore(file: paths.configFile), paths: paths)
        model.showSample(
            sample.conversation(paths), catalog: ModelCatalog(models: [.init(id: "grok-4-fast", name: "Grok 4 Fast")]))
        sample.compose(model)
        let panel = PanelController(model: model)
        panel.hostingView.appearance = NSAppearance(named: .darkAqua)
        panel.layOutOffscreen(maxConversationHeight: 600)
        guard let content = panel.renderContent(scale: 2), let png = hero(around: content) else { throw RenderFailure() }
        return png
    }

    /// A question that shows off file access, a tool step, and a formatted answer.
    private static func diskSpace(_ paths: WispPaths) -> Conversation {
        var conversation = Conversation(paths: paths)
        conversation.begin("what's eating my disk space?")
        conversation.apply(
            .toolCall(ToolCall(id: "1", title: "Execute `du -sh ~/* | sort -h | tail -4`", status: "completed")))
        conversation.apply(
            .messageChunk(
                """
                Four folders hold most of it:

                | Folder | Size |
                |---|---|
                | ~/Library | 48 GB |
                | ~/Movies | 21 GB |
                | ~/Downloads | 9.4 GB |
                | ~/Documents | 6.1 GB |

                About 14 GB of `~/Library` is Xcode's build cache. Want me to clear it?
                """))
        conversation.finish(stopReason: "end_turn", model: "grok-4-fast")
        return conversation
    }

    private static func entropy(_ paths: WispPaths) -> Conversation {
        var conversation = Conversation(paths: paths)
        conversation.begin("What does entropy do in reinforcement learning?")
        conversation.apply(
            .messageChunk(
                #"""
                The policy \(\pi(a\mid s)\) assigns probabilities to actions. Its entropy measures how spread out those probabilities are:

                \[H(\pi(\cdot\mid s))=-\sum_a \pi(a\mid s)\log\pi(a\mid s)\]

                An entropy bonus rewards exploration alongside task reward:

                \[J(\theta)=\mathbb E_{\tau\sim\pi_\theta}[\sum_{t=0}^{T-1}\gamma^t(r_t+\alpha H(\pi_\theta(\cdot\mid s_t)))]\]

                **Higher entropy** means more varied actions; **lower entropy** means a more concentrated policy.
                """#))
        conversation.finish(stopReason: "end_turn", model: "grok-4-fast")
        return conversation
    }

    /// Asking for real work: the agent finds the project and opens a full coding session in Ghostty.
    private static func devSession(_ paths: WispPaths) -> Conversation {
        var conversation = Conversation(paths: paths)
        conversation.begin("start a dev session in my portfolio site and add a dark mode toggle")
        conversation.apply(.toolCall(ToolCall(id: "1", title: "Search “portfolio”", status: "completed")))
        conversation.apply(
            .toolCall(
                ToolCall(id: "2", title: "Run `ghostty-grok --cwd ~/code/portfolio --prompt …`", status: "completed")))
        conversation.apply(
            .messageChunk(
                "Opened a Grok Build session in Ghostty at `~/code/portfolio` with the brief: add a dark mode toggle "
                    + "to the header that follows the system setting and remembers the choice."))
        conversation.finish(stopReason: "end_turn", model: "grok-4-fast")
        return conversation
    }

    /// A window and a file attached, and a skill being picked from the slash-command list.
    private static func researchWithContext(_ model: AppModel) {
        model.attachments = [
            Attachment(url: URL(filePath: "/tmp/Safari window.png"), kind: .window("Safari")),
            .file(URL(filePath: "/tmp/competitor-pricing.pdf")),
        ]
        model.commands = [
            SlashCommand(name: "deep-research", description: "Research with parallel agents and write a cited report"),
            SlashCommand(name: "design", description: "Write a design doc and review it until it holds up"),
            SlashCommand(name: "code-review", description: "Review your branch or uncommitted changes"),
            SlashCommand(name: "compact", description: "Compress conversation history to save context"),
        ]
        model.input = "/de"
    }

    /// The history list (⌘Y) with a week of conversations.
    private static let pastConversations: [(String, String, TimeInterval)] = [
        ("What's eating my disk space", "", 4 * 60),
        ("Dark mode toggle for the portfolio site", "code/portfolio", 2 * 3600),
        ("Summarize the competitor pricing PDF", "", 26 * 3600),
        ("Why CI fails on macOS 15 runners", "code/wisp", 2 * 86400),
        ("Train times from SF to Tahoe this weekend", "", 4 * 86400),
        ("Rename vacation photos by date taken", "Pictures", 8 * 86400),
    ]

    /// The panel on a dark backdrop with the glow from the app icon, at the content's 2x scale.
    private static func hero(around content: NSBitmapImageRep) -> Data? {
        let panelSize = content.size
        let margin = CGSize(width: 140, height: 110)
        let canvas = CGSize(width: panelSize.width + margin.width * 2, height: panelSize.height + margin.height * 2)
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        bitmap.size = canvas

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.scaleBy(x: 2, y: 2)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
            CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
        }

        // Backdrop: night sky with a teal glow rising behind the panel.
        let backdrop = CGPath(roundedRect: CGRect(origin: .zero, size: canvas), cornerWidth: 28, cornerHeight: 28, transform: nil)
        context.addPath(backdrop)
        context.clip()
        context.drawLinearGradient(
            gradient([(0, color(0x231C46)), (0.6, color(0x0F0C22)), (1, color(0x06050D))]),
            start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
        let glow = CGPoint(x: canvas.width * 0.62, y: canvas.height * 0.62)
        context.drawRadialGradient(
            gradient([(0, color(0x2DD4BF, 0.35)), (0.5, color(0x6366F1, 0.12)), (1, color(0x6366F1, 0))]),
            startCenter: glow, startRadius: 0, endCenter: glow, endRadius: canvas.width * 0.55, options: [])

        // The panel: dark glass, a hairline border, and a soft shadow.
        let frame = CGRect(origin: CGPoint(x: margin.width, y: margin.height), size: panelSize)
        let shape = CGPath(
            roundedRect: frame, cornerWidth: PanelController.cornerRadius, cornerHeight: PanelController.cornerRadius,
            transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -24), blur: 70, color: color(0x000000, 0.6))
        context.addPath(shape)
        context.setFillColor(color(0x1E1C2A, 0.96))
        context.fillPath()
        context.restoreGState()
        context.addPath(shape)
        context.setStrokeColor(color(0xFFFFFF, 0.09))
        context.setLineWidth(1)
        context.strokePath()
        content.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)

        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
