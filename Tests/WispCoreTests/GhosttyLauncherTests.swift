import Foundation
import Testing

@testable import WispCore

/// Runs the real `Resources/ghostty-grok` in `--dry-run` mode, so nothing opens.
@Suite struct GhosttyLauncherTests {
    static let script = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Resources/ghostty-grok")

    func launcher(_ environment: [String: String] = [:]) -> GhosttyLauncher {
        GhosttyLauncher(script: Self.script, environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"].merging(environment) { $1 })
    }

    @Test func resumeTypesTheSessionID() async throws {
        let output = try await launcher().describe(.init(directory: "/tmp", resume: "01a13c51-f1a9", target: .tab))
        #expect(output.contains("command: grok --resume 01a13c51-f1a9\n"))
        #expect(output.contains("target: tab"))
    }

    @Test func promptsTravelInTheEnvironmentAfterADoubleDash() async throws {
        let prompt = "-starts with a dash\nand has \"quotes\", $HOME, and `ticks`"
        let output = try await launcher(["WISP_GROK": "/opt/my grok/grok"]).describe(.init(directory: "/tmp", prompt: prompt, target: .window))
        #expect(output.contains(#"command: /opt/my\ grok/grok -- "$WISP_PROMPT""#))
        #expect(output.contains("WISP_PROMPT: \(prompt)"))
        #expect(output.contains("target: window"))
    }

    @Test func rejectsUnsafeSessionIDsAndMissingDirectories() async throws {
        let unsafe = try await launcher().describe(.init(directory: "/tmp", resume: "x; rm -rf ~", target: .window))
        #expect(unsafe.contains("not a session ID"))
        await #expect(throws: GhosttyLauncher.Failure.failed("no such directory: /nonexistent")) {
            try await launcher().open(.init(directory: "/nonexistent", target: .window))
        }
    }

    /// The quick-answer rules tell the agent to pass briefs through a quoted heredoc; run that exact form in zsh.
    @Test func agentStyleHeredocBriefsReachTheScriptVerbatim() async throws {
        let rules = QuickAnswerRules.text(workingDirectory: "/tmp", ghosttyScript: Self.script.path)
        #expect(rules.contains("'\(Self.script.path)' --cwd <project dir> --prompt \"$(cat <<'BRIEF'"))
        let brief = "Fix `make test` and $(whoami)'s \"quoted\" bug\nsecond line"
        let command = "'\(Self.script.path)' --dry-run --cwd /tmp --prompt \"$(cat <<'BRIEF'\n\(brief)\nBRIEF\n)\""
        let result = try await ProcessRunner.run(URL(filePath: "/bin/zsh"), arguments: ["-c", command], environment: ["HOME": NSHomeDirectory()])
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("WISP_PROMPT: \(brief)\n"))
    }

    @Test func defaultsComeFromTheEnvironment() async throws {
        let output = try await launcher(["WISP_GHOSTTY_TARGET": "tab"]).describe(.init(directory: "~", target: .window))
        #expect(output.contains("target: window"), "an explicit --window beats the environment default")
        let script = try await ProcessRunner.run(Self.script, arguments: ["--dry-run"], environment: ["HOME": "/tmp", "WISP_GHOSTTY_TARGET": "tab"])
        #expect(String(decoding: script.stdout, as: UTF8.self).contains("target: tab"))
    }
}
