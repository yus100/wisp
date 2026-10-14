import Foundation

/// The environment of the user's interactive login shell.
///
/// Apps started from Finder or at login inherit launchd's minimal PATH, so the agent would not find
/// Homebrew, language toolchains, or `grok`. Running the shell once with `-ilc` picks up everything
/// `.zprofile` and `.zshrc` export, exactly as a new terminal tab would.
public enum ShellEnvironment {
    static let marker = "__WISP_ENV_BEGIN__"

    /// Variables that describe the probe shell itself rather than the user's setup.
    static let shellOwned: Set<String> = ["SHLVL", "_", "PWD", "OLDPWD"]
    /// Set when Wisp is launched from inside a grok session; the agent must not inherit them.
    static let enclosingSession = ["GROK_SESSION_ID", "GROK_AGENT"]

    public static func resolve(
        base: [String: String] = ProcessInfo.processInfo.environment,
        home: String = WispPaths.standard.home.path(percentEncoded: false),
        timeout: Duration = .seconds(10)
    ) async -> [String: String] {
        let shell = base["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        var captured: [String: String] = [:]
        do {
            let result = try await ProcessRunner.run(
                URL(filePath: shell),
                arguments: ["-ilc", "printf '%s' '\(marker)'; /usr/bin/env -0"],
                currentDirectory: URL(filePath: home),
                timeout: timeout)
            if result.timedOut {
                Log.info("shell environment: \(shell) timed out; using the launchd environment")
            }
            captured = parse(result.stdout)
        } catch {
            Log.info("shell environment: could not run \(shell): \(error.localizedDescription)")
        }
        return merge(base: base, captured: captured, home: home)
    }

    /// Parses `env -0` output that follows the marker; anything a shell profile printed earlier is ignored.
    static func parse(_ output: Data) -> [String: String] {
        guard let start = output.range(of: Data(marker.utf8)) else { return [:] }
        var values: [String: String] = [:]
        for entry in output[start.upperBound...].split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { continue }
            values[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return values
    }

    static func merge(base: [String: String], captured: [String: String], home: String) -> [String: String] {
        var environment = base
        for (key, value) in captured where !shellOwned.contains(key) {
            environment[key] = value
        }
        for key in enclosingSession {
            environment.removeValue(forKey: key)
        }
        var path = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for fallback in ["\(home)/.grok/bin", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        where !path.contains(fallback) {
            path.append(fallback)
        }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }

    /// Finds an executable on the environment's PATH.
    public static func which(_ name: String, in environment: [String: String]) -> String? {
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
