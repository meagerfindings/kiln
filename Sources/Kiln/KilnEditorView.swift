import AppKit
import SwiftUI
import WebKit

struct KilnEditorView: NSViewRepresentable {
  @ObservedObject var document: DocumentController

  func makeCoordinator() -> Coordinator { Coordinator(document: document) }

  func makeNSView(context: Context) -> WKWebView {
    let contentController = WKUserContentController()
    contentController.add(context.coordinator, contentWorld: .defaultClient, name: "kiln")

    if let scriptURL = KilnResources.bundle.url(forResource: "editor", withExtension: "js"),
      let source = try? String(contentsOf: scriptURL, encoding: .utf8)
    {
      contentController.addUserScript(
        WKUserScript(
          source: source,
          injectionTime: .atDocumentEnd,
          forMainFrameOnly: true,
          in: .defaultClient
        ))
    } else {
      document.errorMessage = "Kiln couldn't load its editor script from the app resources."
    }

    let configuration = WKWebViewConfiguration()
    configuration.userContentController = contentController
    configuration.websiteDataStore = .nonPersistent()
    configuration.setURLSchemeHandler(
      context.coordinator.localFiles, forURLScheme: LocalDocumentScheme.scheme)
    // Disabling allowsContentJavaScript drops script nodes from the parser.
    // The local response's CSP blocks execution without destroying the HTML.
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

    let webView = WKWebView(frame: .zero, configuration: configuration)
    do {
      try NativeSpelling.configure(webView)
    } catch {
      document.errorMessage = "Couldn't configure spell-check: \(error.localizedDescription)"
    }
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    context.coordinator.webView = webView
    context.coordinator.structuralUndo = StructuralEditUndo(webView: webView) {
      [weak document] error in
      document?.errorMessage = "Couldn't undo the structural edit: \(error.localizedDescription)"
    }
    context.coordinator.installContentRules()
    document.attach(editor: context.coordinator)
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.document = document
    if let request = document.loadRequest, request.id != context.coordinator.lastLoadID {
      context.coordinator.load(request)
    }
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
    KilnEditorCommands
  {
    weak var webView: WKWebView?
    var document: DocumentController
    private(set) var lastLoadID: UUID?
    private var allowedDocumentURL: URL?
    private var rulesReady = false
    private var deferredLoad: DocumentController.LoadRequest?
    private var ruleList: WKContentRuleList?
    private var activeNavigation: WKNavigation?
    private var allowingInitialNavigation = false
    let localFiles = LocalDocumentScheme()
    var structuralUndo: StructuralEditUndo?

    init(document: DocumentController) { self.document = document }

    func installContentRules() {
      let rules = """
        [
          {"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}
        ]
        """
      WKContentRuleListStore.default().compileContentRuleList(
        forIdentifier: "KilnBlockRemoteResources", encodedContentRuleList: rules
      ) { [weak self] list, error in
        Task { @MainActor in
          guard let self else { return }
          if let error {
            self.document.errorMessage =
              "Kiln couldn't install its offline content rules: \(error.localizedDescription)"
            return
          }
          guard let list, let webView = self.webView else { return }
          webView.configuration.userContentController.add(list)
          self.ruleList = list
          self.rulesReady = true
          if let request = self.deferredLoad {
            self.deferredLoad = nil
            self.load(request)
          }
        }
      }
    }

    func load(_ request: DocumentController.LoadRequest) {
      guard rulesReady, let webView else {
        deferredLoad = request
        return
      }
      webView.undoManager?.removeAllActions()
      lastLoadID = request.id
      let localURL = localFiles.prepare(url: request.url, bytes: request.bytes)
      allowedDocumentURL = localURL
      allowingInitialNavigation = true
      activeNavigation = webView.load(URLRequest(url: localURL))
    }

    func setEditing(_ editing: Bool) {
      evaluate("window.kiln && window.kiln.setEditing(\(editing ? "true" : "false"))")
    }

    func serialize() async throws -> String {
      guard let webView else { throw EditorError.webViewUnavailable }
      guard let html = try await evaluate("window.kiln.serialize()", in: webView) as? String else {
        throw EditorError.invalidSerialization
      }
      return html
    }

    func restore(html: String, baseURL: URL?) {
      guard let webView, let baseURL else { return }
      lastLoadID = nil
      let localURL = localFiles.prepare(url: baseURL, bytes: Data(html.utf8))
      allowedDocumentURL = localURL
      allowingInitialNavigation = true
      activeNavigation = webView.load(URLRequest(url: localURL))
    }

    func focusHeading(_ index: Int) { evaluate("window.kiln.focusHeading(\(index))") }

    func stylesheets() async throws -> [DocumentController.Stylesheet] {
      guard let webView else { throw EditorError.webViewUnavailable }
      guard
        let json = try await evaluate("JSON.stringify(window.kiln.stylesheets())", in: webView)
          as? String
      else {
        throw EditorError.invalidSerialization
      }
      return try JSONDecoder().decode([DocumentController.Stylesheet].self, from: Data(json.utf8))
    }

    func setStylesheet(_ id: String, css: String) async throws {
      guard let webView else { throw EditorError.webViewUnavailable }
      let arguments = String(decoding: try JSONEncoder().encode([id, css]), as: UTF8.self)
      guard
        try await evaluate("window.kiln.setStylesheet(...\(arguments))", in: webView) as? Bool
          == true
      else {
        throw EditorError.invalidStylesheet
      }
    }

    func format(_ command: String, value: String?) {
      if let webView { webView.window?.makeFirstResponder(webView) }
      if command == "undo" {
        webView?.undoManager?.undo()
        return
      }
      if command == "redo" {
        webView?.undoManager?.redo()
        return
      }
      guard let encoded = try? JSONEncoder().encode([command, value ?? ""]),
        let quoted = String(data: encoded, encoding: .utf8), let webView
      else { return }
      Task { @MainActor in
        do {
          let result = try await evaluate("window.kiln.format(...\(quoted))", in: webView)
          if command == "createLink", result as? Bool != true {
            document.errorMessage =
              "Select some text and use an http, https, mailto, tel, or relative link."
          }
        } catch {
          document.errorMessage = "Couldn't format the selection: \(error.localizedDescription)"
        }
      }
    }

    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
        document.errorMessage = "The editor sent an invalid message."
        return
      }
      switch type {
      case "structuralEdit":
        if let id = body["id"] as? Int, let label = body["label"] as? String {
          structuralUndo?.record(id, label: label)
        }
      case "ready":
        let requestID = lastLoadID
        let count = (body["wordCount"] as? NSNumber)?.intValue ?? 0
        let outline = Self.parseOutline(body["outline"])
        Task { @MainActor in
          do {
            let html = try await self.serialize()
            let loadCommitted = self.document.editorDidBecomeReady(
              requestID: requestID, html: html, wordCount: count, outline: outline)
            if requestID == nil || loadCommitted {
              self.setEditing(self.document.isPageEditable)
            }
          } catch {
            self.document.errorMessage =
              "Couldn't initialize the HTML editor: \(error.localizedDescription)"
          }
        }
      case "change":
        let requestID = lastLoadID
        let count = (body["wordCount"] as? NSNumber)?.intValue ?? 0
        let outline = Self.parseOutline(body["outline"])
        Task { @MainActor in
          do {
            let html = try await self.serialize()
            guard self.lastLoadID == requestID, !self.document.isLoading else { return }
            self.document.editorDidChange(html: html, wordCount: count, outline: outline)
          } catch {
            self.document.errorMessage =
              "Couldn't read your latest edit: \(error.localizedDescription)"
          }
        }
      case "error":
        let description = body["message"] as? String ?? "Unknown editor error"
        document.errorMessage = "Editor script error: \(description)"
      default:
        document.errorMessage = "The editor sent an unknown message (\(type))."
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      guard navigation === activeNavigation else { return }
      activeNavigation = nil
      allowingInitialNavigation = false
      guard let requestID = lastLoadID else { return }
      if document.documentDidLoad(requestID: requestID, success: true) {
        setEditing(document.isPageEditable)
      }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      reportLoadFailure(error, navigation: navigation)
    }

    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      reportLoadFailure(error, navigation: navigation)
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      guard navigationAction.targetFrame?.isMainFrame == true,
        allowingInitialNavigation,
        navigationAction.navigationType != .formSubmitted,
        let target = navigationAction.request.url,
        target == allowedDocumentURL
      else {
        decisionHandler(.cancel)
        return
      }
      allowingInitialNavigation = false
      decisionHandler(.allow)
    }

    func webView(
      _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? { nil }

    func webView(
      _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
      initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
    ) { completionHandler() }
    func webView(
      _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
      initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
    ) { completionHandler(false) }
    func webView(
      _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
      defaultText: String?, initiatedByFrame frame: WKFrameInfo,
      completionHandler: @escaping (String?) -> Void
    ) { completionHandler(nil) }

    private func evaluate(_ javascript: String) {
      guard let webView else { return }
      Task { @MainActor in
        do { _ = try await evaluate(javascript, in: webView) } catch {
          document.errorMessage = "Editor command failed: \(error.localizedDescription)"
        }
      }
    }

    private func evaluate(_ javascript: String, in webView: WKWebView) async throws -> Any? {
      try await withCheckedThrowingContinuation { continuation in
        webView.evaluateJavaScript(javascript, in: nil, in: .defaultClient) { result in
          continuation.resume(with: result)
        }
      }
    }

    private func reportLoadFailure(_ error: Error, navigation: WKNavigation?) {
      guard navigation === activeNavigation, let requestID = lastLoadID else { return }
      activeNavigation = nil
      allowingInitialNavigation = false
      document.documentDidLoad(
        requestID: requestID, success: false,
        message: "Couldn't render the HTML: \(error.localizedDescription)")
    }

    private static func parseOutline(_ value: Any?) -> [DocumentController.Heading]? {
      guard let rows = value as? [[String: Any]] else { return nil }
      return rows.compactMap { row in
        guard let index = (row["index"] as? NSNumber)?.intValue,
          let text = row["text"] as? String,
          let level = (row["level"] as? NSNumber)?.intValue
        else { return nil }
        return DocumentController.Heading(index: index, text: text, level: level)
      }
    }

    enum EditorError: LocalizedError {
      case webViewUnavailable, invalidSerialization, invalidStylesheet
      var errorDescription: String? {
        switch self {
        case .webViewUnavailable: "The editor view is unavailable."
        case .invalidSerialization: "The editor returned an invalid HTML document."
        case .invalidStylesheet: "The selected stylesheet is no longer available."
        }
      }
    }
  }
}
