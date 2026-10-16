import WebKit

/// Keeps structural edits on the same native undo stack as WebKit typing.
@MainActor
final class StructuralEditUndo {
  weak var webView: WKWebView?
  let onError: (Error) -> Void

  init(webView: WKWebView, onError: @escaping (Error) -> Void) {
    self.webView = webView
    self.onError = onError
  }

  func record(_ id: Int, label: String) {
    webView?.undoManager?.registerUndo(withTarget: self) { target in
      target.apply(id, forward: false)
    }
    webView?.undoManager?.setActionName(label)
  }

  private func apply(_ id: Int, forward: Bool) {
    guard let webView else { return }
    webView.undoManager?.registerUndo(withTarget: self) { target in
      target.apply(id, forward: !forward)
    }
    webView.evaluateJavaScript(
      "window.kiln.applyStructuralChange(\(id), \(forward))", in: nil, in: .defaultClient
    ) { [weak self] result in
      if case .failure(let error) = result { self?.onError(error) }
    }
  }
}
