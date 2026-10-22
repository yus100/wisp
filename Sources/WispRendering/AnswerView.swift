import AppKit
import SwiftUI
import WebKit

/// Offline Markdown and LaTeX with native panel sizing and external-link handling.
public struct AnswerView: View {
    private let text: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 24
    @State private var failed = false
    @State private var renderedText: String?

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        if failed {
            Text(text).font(.system(size: 14)).textSelection(.enabled)
                .preference(key: RenderedAnswersKey.self, value: [text])
        } else {
            AnswerContent(text: text, dark: colorScheme == .dark, height: $height, failed: $failed, renderedText: $renderedText)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: RenderedAnswersKey.self,
                            value: renderedText == text && abs(geometry.size.height - height) < 1 ? [text] : [])
                    })
        }
    }
}

/// Emitted after typesetting and native layout so history and final chunks can scroll to their actual end.
public struct RenderedAnswersKey: PreferenceKey {
    public static var defaultValue: [String] { [] }

    public static func reduce(value: inout [String], nextValue: () -> [String]) {
        value.append(contentsOf: nextValue())
    }
}

private struct AnswerContent: NSViewRepresentable {
    let text: String
    let dark: Bool
    @Binding var height: CGFloat
    @Binding var failed: Bool
    @Binding var renderedText: String?

    func makeNSView(context: Context) -> AnswerWebView {
        let view = AnswerWebView()
        view.onHeight = { height = $0 }
        view.onFailure = { failed = true }
        view.onRendered = { renderedText = $0 }
        return view
    }

    func updateNSView(_ view: AnswerWebView, context: Context) {
        view.onHeight = { height = $0 }
        view.onFailure = { failed = true }
        view.onRendered = { renderedText = $0 }
        view.render(text: text, dark: dark)
    }

    static func dismantleNSView(_ view: AnswerWebView, coordinator: ()) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "height")
        view.stopLoading()
    }
}

@MainActor
final class AnswerWebView: WKWebView, WKNavigationDelegate {
    var onHeight: ((CGFloat) -> Void)?
    var onFailure: (() -> Void)?
    var onRendered: ((String) -> Void)?
    var openLink: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private var pendingText = ""
    private var pendingDark = false
    private var ready = false
    private var lastRender: String?
    private var lastDark: Bool?

    static var documentURL: URL {
        let resources =
            Bundle.main.url(forResource: "Wisp_WispRendering", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? Bundle.module
        return resources.url(forResource: "index", withExtension: "html", subdirectory: "Resources")!
    }

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        super.init(frame: .zero, configuration: configuration)
        configuration.userContentController.add(HeightHandler(view: self), name: "height")
        navigationDelegate = self
        setValue(false, forKey: "drawsBackground")
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        loadDocument()
    }

    required init?(coder: NSCoder) { nil }

    private func loadDocument() {
        ready = false
        lastRender = nil
        lastDark = nil
        loadFileURL(Self.documentURL, allowingReadAccessTo: Self.documentURL.deletingLastPathComponent())
    }

    func render(text: String, dark: Bool) {
        pendingText = text
        pendingDark = dark
        guard ready, lastRender != text || lastDark != dark else { return }
        lastRender = text
        lastDark = dark
        // Pass data separately: answers can contain quotes, HTML, and closing script tags.
        callAsyncJavaScript(
            "await window.renderAnswer(text, dark)", arguments: ["text": text, "dark": dark],
            in: nil, in: .page
        ) { [weak self] result in
            guard let self, pendingText == text, pendingDark == dark else { return }
            switch result {
            case .success: onRendered?(text)
            case .failure: onFailure?()
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        render(text: pendingText, dark: pendingDark)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onFailure?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFailure?()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadDocument()
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url,
                ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
            {
                openLink(url)
            }
            decisionHandler(.cancel)
        } else {
            decisionHandler(navigationAction.request.url == Self.documentURL ? .allow : .cancel)
        }
    }

    private final class HeightHandler: NSObject, WKScriptMessageHandler {
        weak var view: AnswerWebView?

        init(view: AnswerWebView) { self.view = view }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let height = message.body as? Double, height.isFinite, height >= 0 else { return }
            view?.onHeight?(max(1, ceil(height)))
        }
    }
}
