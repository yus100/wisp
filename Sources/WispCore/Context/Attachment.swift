import Foundation

/// Something the user handed Wisp along with a question: a file or folder, an image, or a screenshot
/// of the window they were looking at. The agent gets the path and opens it with its own file tools (it can
/// view images that way), so nothing needs to be uploaded separately.
public struct Attachment: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case file
        case folder
        case image
        /// A screenshot of an app's window; the associated value names the app.
        case window(String)
    }

    public let id: UUID
    public let url: URL
    public let kind: Kind

    public init(url: URL, kind: Kind, id: UUID = UUID()) {
        self.id = id
        self.url = url
        self.kind = kind
    }

    /// Short label for the chip and for the question in the conversation.
    public var label: String {
        switch kind {
        case .window(let app): "\(app) window"
        case .file, .folder, .image: url.lastPathComponent
        }
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "bmp"]

    /// An attachment for a path on disk: a folder, an image (by its extension), or any other file.
    public static func file(_ url: URL) -> Attachment {
        let isFolder = url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if isFolder { return Attachment(url: url, kind: .folder) }
        return Attachment(url: url, kind: imageExtensions.contains(url.pathExtension.lowercased()) ? .image : .file)
    }
}

/// Builds the prompt sent to the agent from what the user typed and what they attached.
public enum PromptComposer {
    public static func compose(_ text: String, attachments: [Attachment]) -> String {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attachments.isEmpty else { return question }
        let lines = attachments.map { attachment in
            switch attachment.kind {
            case .window(let app):
                "- Screenshot of the \(app) window the user was looking at: \(attachment.url.path) (an image; view it)"
            case .image:
                "- Image: \(attachment.url.path) (view it)"
            case .file:
                "- File: \(attachment.url.path)"
            case .folder:
                "- Folder: \(attachment.url.path)"
            }
        }
        let request = question.isEmpty ? "Take a look at what I attached." : question
        return request + "\n\nAttached (open these with your file tools):\n" + lines.joined(separator: "\n")
    }
}
