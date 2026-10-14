import Foundation

/// Opens Grok Build sessions in Ghostty through the bundled `ghostty-grok` script (AppleScript under the hood).
/// The agent calls the same script when you ask it to start a dev session.
enum Ghostty {
    static var scriptPath: String {
        Bundle.main.resourceURL?.appendingPathComponent("ghostty-grok").path
            ?? "/Applications/Wisp.app/Contents/Resources/ghostty-grok"
    }

    static func open(cwd: String, resume: String? = nil, prompt: String? = nil, target: String, env: [String: String],
                     completion: @escaping (String?) -> Void) {
        var arguments = ["--cwd", cwd]
        if let resume { arguments += ["--resume", resume] }
        if let prompt, !prompt.isEmpty { arguments += ["--prompt", prompt] }
        if target == "tab" { arguments.append("--tab") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: scriptPath)
        process.arguments = arguments
        process.environment = env
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { proc in
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                completion(proc.terminationStatus == 0 ? nil : (message.isEmpty ? "Could not open Ghostty." : message))
            }
        }
        do {
            try process.run()
        } catch {
            completion("Could not run \(scriptPath): \(error.localizedDescription)")
        }
    }
}
