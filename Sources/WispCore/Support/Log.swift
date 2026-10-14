import Foundation

/// Plain-text logs, readable with `tail -f`. Off until the app calls `enable`, so tests and other
/// clients of WispCore never write into the user's log folder. Safe to call from any thread.
public enum Log {
    private static let queue = DispatchQueue(label: "wisp.log")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var directory: URL?

    /// Starts logging into `directory`, beginning `app.log` afresh once it passes 5 MB.
    public static func enable(in directory: URL) {
        lock.withLock { self.directory = directory }
        rotate(directory.appendingPathComponent("app.log"))
    }

    public static func info(_ message: String) {
        guard let url = lock.withLock({ directory })?.appendingPathComponent("app.log") else { return }
        let line = Data("\(Date().formatted(.iso8601)) \(message)\n".utf8)
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url)
            }
        }
    }

    /// A handle for a child process's stderr, appended to `fileName` in the log folder.
    public static func appendingHandle(for fileName: String) -> FileHandle {
        guard let url = lock.withLock({ directory })?.appendingPathComponent(fileName) else { return .nullDevice }
        rotate(url)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return .nullDevice }
        _ = try? handle.seekToEnd()
        return handle
    }

    private static func rotate(_ url: URL) {
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
