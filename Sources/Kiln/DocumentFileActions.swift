import AppKit
import Foundation

@MainActor
protocol DocumentFileActions {
  func openInBrowser(_ url: URL) async throws
  func revealInFinder(_ url: URL) throws
  func copyFilePath(_ url: URL) throws
}

@MainActor
struct SystemDocumentFileActions: DocumentFileActions {
  private let pasteboard: NSPasteboard

  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  func openInBrowser(_ url: URL) async throws {
    let fileURL = try validatedFileURL(url)
    guard let httpsURL = URL(string: "https://example.com"),
      let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: httpsURL)
    else {
      throw DocumentFileActionError.noDefaultBrowser
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      NSWorkspace.shared.open(
        [fileURL],
        withApplicationAt: applicationURL,
        configuration: NSWorkspace.OpenConfiguration()
      ) { _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  func revealInFinder(_ url: URL) throws {
    let fileURL = try validatedFileURL(url)
    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
  }

  func copyFilePath(_ url: URL) throws {
    let fileURL = try validatedFileURL(url)
    pasteboard.clearContents()
    guard pasteboard.setString(fileURL.path, forType: .string) else {
      throw DocumentFileActionError.pasteboardWriteFailed
    }
  }

  private func validatedFileURL(_ url: URL) throws -> URL {
    guard url.isFileURL else { throw DocumentFileActionError.notLocalFile }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      throw DocumentFileActionError.notRegularFile
    }

    let values = try url.resourceValues(forKeys: [.isRegularFileKey])
    guard values.isRegularFile == true else {
      throw DocumentFileActionError.notRegularFile
    }
    return url.standardizedFileURL
  }
}

private enum DocumentFileActionError: LocalizedError {
  case noDefaultBrowser
  case notLocalFile
  case notRegularFile
  case pasteboardWriteFailed

  var errorDescription: String? {
    switch self {
    case .noDefaultBrowser:
      return "No default browser is available to open this document."
    case .notLocalFile:
      return "This action requires a local file."
    case .notRegularFile:
      return "The document does not exist or is not a regular file."
    case .pasteboardWriteFailed:
      return "The file path could not be copied to the clipboard."
    }
  }
}
