import Foundation
import WispCore

/// Owns `config.json`: loads it, reloads it whenever it changes on disk, and saves the model picker's choices.
@MainActor
final class ConfigStore {
    private(set) var config: WispConfig
    /// Set while the file on disk does not parse; Wisp then runs on defaults and will not overwrite it.
    private(set) var problem: String?

    /// Called after any change, from disk or from `update`, with the previous and new config.
    var onChange: ((_ old: WispConfig, _ new: WispConfig, _ fromDisk: Bool) -> Void)?
    /// Called when the file on disk stops parsing.
    var onReloadProblem: ((_ problem: String) -> Void)?

    private let file: URL
    /// The file actually watched: `file` with any symlink resolved.
    private var watchedFile: URL { file.resolvingSymlinksInPath() }
    private var directoryWatch: DispatchSourceFileSystemObject?
    private var fileWatch: DispatchSourceFileSystemObject?

    init(file: URL) {
        self.file = file
        (config, problem) = WispConfig.load(from: file)
        watch()
    }

    /// Saves a change made inside Wisp. Refuses while the file has an error, so a typo is never replaced by defaults.
    func update(_ change: (inout WispConfig) -> Void) throws {
        if let problem { throw ConfigError(message: "Fix config.json first: \(problem)") }
        var updated = config
        change(&updated)
        guard updated != config else { return }
        try updated.save(to: file)
        let old = config
        config = updated
        onChange?(old, updated, false)
    }

    struct ConfigError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Watching

    /// Read-only: a file that is briefly missing (editors that delete, then write) leaves the config as is.
    private func reload() {
        switch WispConfig.read(from: file) {
        case .missing:
            return
        case .invalid(let message):
            if message != problem { onReloadProblem?(message) }
            problem = message
        case .loaded(let loaded):
            problem = nil
            guard loaded != config else { return }
            let old = config
            config = loaded
            onChange?(old, loaded, true)
        }
    }

    /// Editors either rewrite the file in place or replace it, so watch both the file and its folder,
    /// and re-arm the file watch whenever the file is replaced.
    private func watch() {
        let directory = watchedFile.deletingLastPathComponent()
        directoryWatch = makeSource(path: directory.path, events: [.write]) { [weak self] in
            self?.rewatchFile()
            self?.reload()
        }
        rewatchFile()
    }

    private func rewatchFile() {
        fileWatch?.cancel()
        fileWatch = makeSource(path: watchedFile.path, events: [.write, .extend, .delete, .rename]) { [weak self] in
            self?.reload()
        }
    }

    private func makeSource(
        path: String, events: DispatchSource.FileSystemEvent, handler: @escaping @MainActor () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}
