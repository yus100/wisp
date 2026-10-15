import AppKit
import WispCore

/// What goes with a question besides its text: attachments (files, images, window screenshots) and
/// slash commands (grok's built-ins, skills, and workflows).
extension AppModel {
    // MARK: Slash commands

    /// Commands matching what is typed, shown under the input.
    var suggestions: [SlashCommand] {
        SlashCommand.suggestions(for: input, in: commands)
    }

    func moveSuggestionSelection(by offset: Int) {
        let count = suggestions.count
        guard count > 0 else { return }
        selectedSuggestion = (selectedSuggestion + offset + count) % count
    }

    /// Fills in the highlighted command, ready for arguments.
    func acceptSuggestion(_ command: SlashCommand? = nil) {
        guard let chosen = command ?? suggestions[safe: selectedSuggestion] else { return }
        input = "/\(chosen.name) "
    }

    /// The input already names the highlighted command in full, so Return should run it.
    var highlightedCommandIsTyped: Bool {
        guard let highlighted = suggestions[safe: selectedSuggestion] else { return false }
        return input.lowercased() == "/" + highlighted.name.lowercased()
    }

    func updateCommands(_ list: [SlashCommand]) {
        guard !list.isEmpty, list != commands else { return }
        commands = list
        selectedSuggestion = 0
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: paths.commandsFile, options: .atomic)
        }
    }

    static func loadCommands(from file: URL) -> [SlashCommand] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([SlashCommand].self, from: data)) ?? []
    }

    // MARK: Attachments

    func attach(files: [URL]) {
        let new = files.filter { url in !attachments.contains { $0.url == url } }.map(Attachment.file)
        attachments.append(contentsOf: new)
        notice = nil
    }

    /// Saves pasted or dropped image data as a PNG and attaches it.
    func attach(image: NSImage) {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        let file = Self.newFile(named: "Pasted image", in: paths.attachments)
        do {
            try png.write(to: file)
            attachments.append(Attachment(url: file, kind: .image))
            notice = nil
        } catch {
            notice = Notice("Could not save the image: \(error.localizedDescription)")
        }
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    /// Name of the app whose window "Attach Window" would capture.
    var contextAppName: String? {
        contextApp?.localizedName
    }

    /// Captures the window of the app that was in front when the panel opened.
    func attachContextWindow() {
        guard !isCapturingWindow else { return }
        guard let app = contextApp, !app.isTerminated else {
            notice = Notice("There's no window to attach. Open Wisp from the app you want to show it.")
            return
        }
        let directory = paths.attachments
        let generation = attachmentGeneration
        isCapturingWindow = true
        Task {
            defer { isCapturingWindow = false }
            do {
                let file = try await WindowCapture.capture(app, into: directory)
                // Sent or started over while capturing: the screenshot belonged to that question.
                guard generation == attachmentGeneration else {
                    try? FileManager.default.removeItem(at: file)
                    return
                }
                attachments.append(Attachment(url: file, kind: .window(app.localizedName ?? "App")))
                notice = nil
            } catch let failure as WindowCapture.Failure {
                notice = Notice(
                    failure.localizedDescription, actionTitle: failure.settingsURL == nil ? nil : "Open Settings",
                    actionURL: failure.settingsURL)
            } catch {
                notice = Notice("Could not capture the window: \(error.localizedDescription)")
            }
        }
    }

    /// Removes pasted images and screenshots older than a week, in the background. Runs at launch and
    /// whenever the panel opens.
    func pruneOldAttachments() {
        let directory = paths.attachments
        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
            let files =
                (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]))
                ?? []
            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < cutoff { try? fileManager.removeItem(at: file) }
            }
        }
    }

    /// `<name> <timestamp>.png` in `directory`, numbered if two are saved within the same second.
    nonisolated static func newFile(named name: String, in directory: URL) -> URL {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: ".")
        var file = directory.appending(path: "\(name) \(stamp).png")
        var number = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = directory.appending(path: "\(name) \(stamp) \(number).png")
            number += 1
        }
        return file
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
