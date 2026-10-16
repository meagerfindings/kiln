import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves one selected document and nearby assets without a localhost server.
/// Response-header CSP preserves script nodes but prevents their execution.
final class LocalDocumentScheme: NSObject, WKURLSchemeHandler {
  static let scheme = "kiln-local"
  static let contentPolicy =
    "default-src 'none'; script-src 'none'; style-src 'unsafe-inline' kiln-local: data:; img-src kiln-local: data:; font-src kiln-local: data:; media-src kiln-local: data:; frame-src 'none'; object-src 'none'; connect-src 'none'; form-action 'none'; base-uri 'none'"

  private var root: URL?
  private var documentURL: URL?
  private var documentBytes = Data()
  private var host = ""

  func prepare(url: URL, bytes: Data) -> URL {
    root = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
    documentBytes = bytes
    host = UUID().uuidString.lowercased()
    var components = URLComponents()
    components.scheme = Self.scheme
    components.host = host
    components.path = "/" + url.lastPathComponent
    let local = components.url!
    documentURL = local
    return local
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    do {
      guard let url = urlSchemeTask.request.url, url.host == host, let root else {
        throw CocoaError(.fileReadNoPermission)
      }
      let bytes: Data
      let mime: String
      if url.path == documentURL?.path {
        bytes = documentBytes
        mime = "text/html; charset=utf-8"
      } else {
        let asset = root.appendingPathComponent(url.path).resolvingSymlinksInPath()
          .standardizedFileURL
        guard asset.path.hasPrefix(root.path + "/") else {
          throw CocoaError(.fileReadNoPermission)
        }
        bytes = try Data(contentsOf: asset)
        mime =
          UTType(filenameExtension: asset.pathExtension)?.preferredMIMEType
          ?? "application/octet-stream"
      }
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: [
          "Content-Type": mime,
          "Content-Security-Policy": Self.contentPolicy,
          "X-Content-Type-Options": "nosniff",
          "Cache-Control": "no-store",
        ])!
      urlSchemeTask.didReceive(response)
      urlSchemeTask.didReceive(bytes)
      urlSchemeTask.didFinish()
    } catch {
      urlSchemeTask.didFailWithError(error)
    }
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    // Responses complete synchronously on WebKit's calling thread.
  }
}
