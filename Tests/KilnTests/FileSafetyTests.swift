import AppKit
import XCTest

@testable import Kiln

final class FileSafetyTests: XCTestCase {
  @MainActor
  func testUnchangedSavePreservesBytesButImmediateEditSavesFreshContent() async throws {
    let original = Data("<!doctype html>\n<p class='copy'>Café &amp; tea</p>\n".utf8)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-\(UUID()).html")
    defer { try? FileManager.default.removeItem(at: url) }
    try original.write(to: url)
    let document = DocumentController()
    let editor = FileEditor(document: document)
    document.attach(editor: editor)
    document.requestOpen(url)
    try await waitUntil { document.hasDocument }
    let savedUnchanged = await document.save()
    XCTAssertTrue(savedUnchanged)
    XCTAssertEqual(try Data(contentsOf: url), original)

    // The last keystroke has not yet sent its change notification.
    editor.html = "<!DOCTYPE html><html><body><p>日本語 &amp; café</p></body></html>"
    let savedEdited = await document.save()
    XCTAssertTrue(savedEdited)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), editor.html)
    XCTAssertFalse(document.isDirty)
  }

  @MainActor
  func testExternalChangeRefusesSaveAndFailedSaveDoesNotClose() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-\(UUID()).html")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("<p>Original</p>".utf8).write(to: url)
    let document = DocumentController()
    let editor = FileEditor(document: document)
    document.attach(editor: editor)
    document.requestOpen(url)
    try await waitUntil { document.hasDocument }
    editor.html = "<p>My new words</p>"
    let external = Data("<p>The agent rewrote this file</p>".utf8)
    try external.write(to: url)

    var closed = false
    document.requestClose { closed = true }
    try await waitUntil { document.showUnsavedPrompt }
    document.resolveUnsavedPrompt(.save)
    try await waitUntil { document.errorMessage != nil }
    XCTAssertFalse(closed)
    XCTAssertTrue(document.isDirty)
    XCTAssertEqual(try Data(contentsOf: url), external)
    XCTAssertTrue(document.errorMessage?.contains("changed outside Kiln") == true)
  }

  @MainActor
  func testCancelAndUnreadableReplacementKeepCurrentDocument() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-\(UUID()).html")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("<p>Original</p>".utf8).write(to: url)
    let document = DocumentController()
    let editor = FileEditor(document: document)
    document.attach(editor: editor)
    document.requestOpen(url)
    try await waitUntil { document.hasDocument }
    editor.html = "<p>Unsent edits</p>"
    let missing = url.appendingPathExtension("missing")
    document.requestOpen(missing)
    try await waitUntil { document.showUnsavedPrompt }
    document.resolveUnsavedPrompt(.cancel)
    try await Task.sleep(nanoseconds: 10_000_000)
    XCTAssertEqual(document.fileURL, url)
    XCTAssertEqual(document.renderedHTML, editor.html)

    document.requestOpen(missing)
    try await waitUntil { document.showUnsavedPrompt }
    document.resolveUnsavedPrompt(.discard)
    try await waitUntil { document.errorMessage != nil }
    XCTAssertEqual(document.fileURL, url)
    XCTAssertEqual(document.renderedHTML, editor.html)
    XCTAssertTrue(document.isDirty)
  }

  @MainActor
  func testBrowserConfirmationSavesTheLatestEditorStateBeforeOpening() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-\(UUID()).html")
    defer { try? FileManager.default.removeItem(at: url) }
    let original = Data("<p>Original</p>".utf8)
    try original.write(to: url)
    let actions = FakeDocumentFileActions()
    let (document, editor) = try await openDocument(at: url, actions: actions)
    let latest = "<!DOCTYPE html><html><body><p>Latest unsent edit</p></body></html>"
    editor.html = latest

    document.requestBrowserOpen()
    try await waitUntil { document.showBrowserPrompt }
    // SwiftUI dismisses the alert before its asynchronous button action runs.
    document.showBrowserPrompt = false
    await document.confirmBrowserOpen()

    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), latest)
    XCTAssertEqual(actions.browserTargets, [url])
    XCTAssertEqual(actions.bytesAtBrowserOpen, [Data(latest.utf8)])
    XCTAssertFalse(document.isDirty)
    XCTAssertFalse(document.showBrowserPrompt)
  }

  @MainActor
  func testCancellingBrowserPromptDoesNotSaveOrOpen() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-\(UUID()).html")
    defer { try? FileManager.default.removeItem(at: url) }
    let original = Data("<p>Original bytes</p>".utf8)
    try original.write(to: url)
    let actions = FakeDocumentFileActions()
    let (document, editor) = try await openDocument(at: url, actions: actions)
    editor.html = "<p>Unsent edit that must not be saved</p>"

    document.requestBrowserOpen()
    try await waitUntil { document.showBrowserPrompt }
    document.showBrowserPrompt = false
    try await Task.sleep(nanoseconds: 20_000_000)

    XCTAssertEqual(try Data(contentsOf: url), original)
    XCTAssertTrue(actions.browserTargets.isEmpty)
  }

  @MainActor
  func testExternalChangeDuringBrowserConfirmationPreventsOpening() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-\(UUID()).html")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("<p>Original</p>".utf8).write(to: url)
    let actions = FakeDocumentFileActions()
    let (document, editor) = try await openDocument(at: url, actions: actions)
    editor.html = "<p>My unsent edit</p>"
    document.requestBrowserOpen()
    try await waitUntil { document.showBrowserPrompt }
    let external = Data("<p>External update</p>".utf8)
    try external.write(to: url)

    await document.confirmBrowserOpen()

    XCTAssertTrue(actions.browserTargets.isEmpty, "A failed save must prevent the external open")
    XCTAssertEqual(try Data(contentsOf: url), external)
    XCTAssertTrue(document.isDirty)
    XCTAssertTrue(document.errorMessage?.contains("changed outside Kiln") == true)
  }

  @MainActor
  func testRevealAndCopyUseSavedFileWithoutSavingUnsentEdits() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-\(UUID()).html")
    defer { try? FileManager.default.removeItem(at: url) }
    let original = Data("<p>Saved version</p>".utf8)
    try original.write(to: url)
    let actions = FakeDocumentFileActions()
    let (document, editor) = try await openDocument(at: url, actions: actions)
    editor.html = "<p>Latest editor state not yet saved</p>"

    document.revealInFinder()
    document.copyFilePath()

    XCTAssertEqual(actions.revealedTargets, [url])
    XCTAssertEqual(actions.copiedTargets, [url])
    XCTAssertEqual(try Data(contentsOf: url), original)
    XCTAssertEqual(document.fileActionStatus, "Path copied")

    let sampleURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "kiln-sample-\(UUID()).html")
    defer { try? FileManager.default.removeItem(at: sampleURL) }
    try Data("<p>Sample</p>".utf8).write(to: sampleURL)
    let sampleActions = FakeDocumentFileActions()
    let sample = DocumentController(fileActions: sampleActions)
    let sampleEditor = FileEditor(document: sample)
    sample.attach(editor: sampleEditor)
    sample.openSample(sampleURL)
    try await waitUntil { sample.hasDocument }
    sample.revealInFinder()
    sample.copyFilePath()

    XCTAssertNil(sample.fileURL)
    XCTAssertTrue(sampleActions.revealedTargets.isEmpty)
    XCTAssertTrue(sampleActions.copiedTargets.isEmpty)
  }

  @MainActor
  func testFileActionAdapterFailuresAreVisible() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-\(UUID()).html")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("<p>Original</p>".utf8).write(to: url)
    let actions = FakeDocumentFileActions()
    let (document, _) = try await openDocument(at: url, actions: actions)

    actions.browserError = FileActionFailure.browser
    document.requestBrowserOpen()
    try await waitUntil { document.showBrowserPrompt }
    await document.confirmBrowserOpen()
    XCTAssertTrue(document.errorMessage?.contains("fake browser failure") == true)

    actions.revealError = FileActionFailure.reveal
    document.revealInFinder()
    XCTAssertTrue(document.errorMessage?.contains("fake Finder failure") == true)

    actions.copyError = FileActionFailure.copy
    document.copyFilePath()
    XCTAssertTrue(document.errorMessage?.contains("fake clipboard failure") == true)
  }

  @MainActor
  func testSystemCopyPreservesUnicodeAndDoesNotClearClipboardForInvalidFiles() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("A café & note.html")
    try Data("<p>Safe local fixture</p>".utf8).write(to: url)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let actions = SystemDocumentFileActions(pasteboard: pasteboard)
    let unnormalized = folder.appendingPathComponent(
      "../\(folder.lastPathComponent)/\(url.lastPathComponent)")

    try actions.copyFilePath(unnormalized)
    XCTAssertEqual(pasteboard.string(forType: .string), url.path)
    for invalid in [
      folder, folder.appendingPathComponent("missing.html"), URL(string: "https://example.com")!,
    ] {
      XCTAssertThrowsError(try actions.copyFilePath(invalid))
      XCTAssertEqual(pasteboard.string(forType: .string), url.path)
    }
  }

  @MainActor
  private func openDocument(at url: URL, actions: FakeDocumentFileActions) async throws -> (
    DocumentController, FileEditor
  ) {
    let document = DocumentController(fileActions: actions)
    let editor = FileEditor(document: document)
    document.attach(editor: editor)
    document.requestOpen(url)
    try await waitUntil { document.hasDocument }
    return (document, editor)
  }

  @MainActor
  private func waitUntil(_ predicate: () -> Bool) async throws {
    for _ in 0..<200 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("Document action did not complete")
  }
}

@MainActor
private final class FileEditor: KilnEditorCommands {
  unowned let document: DocumentController
  var html = ""

  init(document: DocumentController) { self.document = document }
  func load(_ request: DocumentController.LoadRequest) {
    html = "<!DOCTYPE html><html><body><p>Normalized by WebKit</p></body></html>"
    document.documentDidLoad(requestID: request.id, success: true)
    document.editorDidBecomeReady(requestID: request.id, html: html, wordCount: 3, outline: [])
  }
  func setEditing(_ editing: Bool) {}
  func serialize() async throws -> String { html }
  func restore(html: String, baseURL: URL?) { self.html = html }
  func focusHeading(_ index: Int) {}
  func format(_ command: String, value: String?) {}
  func stylesheets() async throws -> [DocumentController.Stylesheet] { [] }
  func setStylesheet(_ id: String, css: String) async throws {}
}

@MainActor
private final class FakeDocumentFileActions: DocumentFileActions {
  private(set) var browserTargets: [URL] = []
  private(set) var bytesAtBrowserOpen: [Data] = []
  private(set) var revealedTargets: [URL] = []
  private(set) var copiedTargets: [URL] = []
  var browserError: Error?
  var revealError: Error?
  var copyError: Error?

  func openInBrowser(_ url: URL) async throws {
    browserTargets.append(url)
    if let browserError { throw browserError }
    bytesAtBrowserOpen.append(try Data(contentsOf: url))
  }

  func revealInFinder(_ url: URL) throws {
    revealedTargets.append(url)
    if let revealError { throw revealError }
  }

  func copyFilePath(_ url: URL) throws {
    copiedTargets.append(url)
    if let copyError { throw copyError }
  }
}

private enum FileActionFailure: LocalizedError {
  case browser, reveal, copy

  var errorDescription: String? {
    switch self {
    case .browser: return "fake browser failure"
    case .reveal: return "fake Finder failure"
    case .copy: return "fake clipboard failure"
    }
  }
}
