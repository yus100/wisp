import Foundation
import Testing

@testable import WispCore

@Suite struct ShellEnvironmentTests {
    @Test func parseIgnoresProfileNoiseBeforeTheMarker() {
        let output = Data("Welcome to zsh!\n\(ShellEnvironment.marker)PATH=/opt/homebrew/bin:/usr/bin\0EDITOR=vim\0EMPTY=\0MULTI=a=b\0".utf8)
        let parsed = ShellEnvironment.parse(output)
        #expect(parsed["PATH"] == "/opt/homebrew/bin:/usr/bin")
        #expect(parsed["EDITOR"] == "vim")
        #expect(parsed["EMPTY"] == "")
        #expect(parsed["MULTI"] == "a=b")
        #expect(parsed["Welcome to zsh!\n"] == nil)
    }

    @Test func parseWithoutMarkerIsEmpty() {
        #expect(ShellEnvironment.parse(Data("PATH=/bin\0".utf8)).isEmpty)
    }

    @Test func mergeDropsShellAndSessionVariablesAndAddsFallbackPaths() {
        let merged = ShellEnvironment.merge(
            base: ["PATH": "/usr/bin:/bin", "GROK_SESSION_ID": "abc", "HOME": "/Users/me"],
            captured: ["PATH": "/opt/homebrew/bin:/usr/bin", "SHLVL": "2", "GROK_AGENT": "1", "XAI_ROOT": "/x"],
            home: "/Users/me")
        #expect(merged["SHLVL"] == nil)
        #expect(merged["GROK_SESSION_ID"] == nil)
        #expect(merged["GROK_AGENT"] == nil)
        #expect(merged["XAI_ROOT"] == "/x")
        let path = merged["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(path.first == "/opt/homebrew/bin")
        #expect(path.contains("/Users/me/.grok/bin"))
        #expect(path.filter { $0 == "/opt/homebrew/bin" }.count == 1)
    }

    @Test func resolveReadsARealShell() async {
        let environment = await ShellEnvironment.resolve(base: ["SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"], home: "/tmp")
        #expect(environment["PATH"]?.contains("/usr/bin") == true)
    }
}

@Suite struct ProcessRunnerTests {
    @Test func capturesOutputAndStatus() async throws {
        let result = try await ProcessRunner.run(URL(filePath: "/bin/sh"), arguments: ["-c", "echo out; echo err >&2; exit 3"])
        #expect(result.status == 3)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "out\n")
        #expect(result.stderrText == "err")
        #expect(!result.succeeded)
    }

    @Test func timesOut() async throws {
        let start = ContinuousClock.now
        let result = try await ProcessRunner.run(URL(filePath: "/bin/sleep"), arguments: ["5"], timeout: .milliseconds(200))
        #expect(result.timedOut)
        #expect(ContinuousClock.now - start < .seconds(3))
    }
}
