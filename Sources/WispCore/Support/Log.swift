import Foundation

/// Plain-text logs under `~/Library/Logs/Wisp`, readable with `tail -f`. Safe to call from any thread.
public enum Log {
    private static let queue = DispatchQueue(label: "wisp.log")

    public static func info(_ message: String) {
        write(message, to: "app.log")
    }

    static func write(_ message: String, to fileName: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        queue.async {
            let url = WispPaths.standard.logs.appendingPathComponent(fileName)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// A handle for a child process's stderr, appended to `fileName` and rotated past 5 MB.
    public static func appendingHandle(for fileName: String) -> FileHandle {
        let url = WispPaths.standard.logs.appendingPathComponent(fileName)
        let fileManager = FileManager.default
        if let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000 {
            try? fileManager.removeItem(at: url)
        }
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return .nullDevice }
        _ = try? handle.seekToEnd()
        return handle
    }
}
