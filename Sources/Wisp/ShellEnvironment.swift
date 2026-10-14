import Foundation

/// The environment of the user's interactive login shell.
///
/// Apps started from Finder or at login get launchd's minimal PATH, so the agent would not find
/// Homebrew, language toolchains, or `grok` itself. Running the shell once with `-ilc` picks up
/// everything `.zprofile` and `.zshrc` export, the same way a terminal session would.
enum ShellEnvironment {
    private static let marker = "__WISP_ENV__"

    static func resolve(timeout: TimeInterval = 10) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf '%s' '\(marker)'; /usr/bin/env -0"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        var captured: [String: String] = [:]
        do {
            try process.run()
            let deadline = DispatchTime.now() + timeout
            let done = DispatchSemaphore(value: 0)
            var data = Data()
            DispatchQueue.global().async {
                data = out.fileHandleForReading.readDataToEndOfFile()
                done.signal()
            }
            if done.wait(timeout: deadline) == .timedOut {
                process.terminate()
                appLog("shell env: timed out after \(timeout)s; using launchd environment")
            } else if let range = data.range(of: Data(marker.utf8)) {
                let payload = data[range.upperBound...]
                for entry in payload.split(separator: 0) {
                    guard let text = String(data: Data(entry), encoding: .utf8),
                          let eq = text.firstIndex(of: "=") else { continue }
                    captured[String(text[..<eq])] = String(text[text.index(after: eq)...])
                }
            }
        } catch {
            appLog("shell env: failed to run \(shell): \(error)")
        }

        for (key, value) in captured where !["SHLVL", "_", "PWD", "OLDPWD"].contains(key) {
            env[key] = value
        }
        // Never leak the identity of an enclosing grok session into the agent we spawn.
        for key in ["GROK_SESSION_ID", "GROK_AGENT"] { env.removeValue(forKey: key) }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallbacks = ["\(home)/.grok/bin", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        var path = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for dir in fallbacks where !path.contains(dir) { path.append(dir) }
        env["PATH"] = path.joined(separator: ":")
        return env
    }

    /// Finds an executable on the given PATH.
    static func which(_ name: String, env: [String: String]) -> String? {
        for dir in (env["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
