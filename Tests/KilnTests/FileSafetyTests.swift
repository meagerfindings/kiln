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
  func testAutosaveDebouncesBurstEditsAndPreservesUnchangedFileBytes() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("document.html")
    let recoveryRoot = root.appendingPathComponent("recovery", isDirectory: true)
    let original = Data("<!doctype html>\n<p class='copy'>Café &amp; tea</p>\n".utf8)
    try original.write(to: url)
    let document = DocumentController(
      autosaveDelayNanoseconds: 120_000_000, recoveryDirectory: recoveryRoot)
    let editor = FileEditor(document: document)
    document.attach(editor: editor)
    document.requestOpen(url)
    try await waitUntil { document.hasDocument }

    try await Task.sleep(nanoseconds: 250_000_000)
    XCTAssertEqual(try Data(contentsOf: url), original)
    XCTAssertFalse(document.isDirty)

    editor.edit("<p>first burst version</p>")
    try await Task.sleep(nanoseconds: 40_000_000)
    editor.edit("<p>second burst version</p>")
    try await Task.sleep(nanoseconds: 40_000_000)
    let latest = "<!DOCTYPE html><html><body><p>latest burst version</p></body></html>"
    editor.edit(latest)
    XCTAssertEqual(
      try Data(contentsOf: url), original, "Autosave should wait for the burst to go idle")

    try await waitUntil {
      (try? Data(contentsOf: url)) == Data(latest.utf8) && !document.isDirty
    }
    XCTAssertEqual(try Data(contentsOf: url), Data(latest.utf8))
    XCTAssertTrue(document.saveProblem == nil)
    XCTAssertNotNil(document.recoveryURL)
  }

  @MainActor
  func testAutosaveConflictKeepsLatestRecoveryDraftUntilExplicitRetry() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("document.html")
    let recoveryRoot = root.appendingPathComponent("recovery", isDirectory: true)
    let original = Data("<p>original bytes</p>".utf8)
    try original.write(to: url)
    let document = DocumentController(
      autosaveDelayNanoseconds: 80_000_000, recoveryDirectory: recoveryRoot)
    let editor = FileEditor(document: document)
    document.attach(editor: editor)
    document.requestOpen(url)
    try await waitUntil { document.hasDocument }

    editor.edit("<p>draft before conflict</p>")
    let external = Data("<p>external edit</p>".utf8)
    try external.write(to: url)
    try await waitUntil { document.saveProblem != nil }
    XCTAssertEqual(try Data(contentsOf: url), external)
    let firstProblem = document.saveProblem
    document.errorMessage = nil  // Dismiss the first warning before continuing to type.

    let latest = "<p>latest recovery draft</p>"
    editor.edit(latest)
    try await Task.sleep(nanoseconds: 220_000_000)
    XCTAssertEqual(try Data(contentsOf: url), external, "A conflict must pause automatic writes")
    XCTAssertEqual(
      document.saveProblem, firstProblem, "Further edits must not raise repeated save alerts")
    XCTAssertNil(document.errorMessage)
    let recoveryURL = try XCTUnwrap(document.recoveryURL)
    XCTAssertEqual(
      try Data(contentsOf: recoveryURL.appendingPathComponent("original.html")), original)
    XCTAssertEqual(
      try Data(contentsOf: recoveryURL.appendingPathComponent("draft.html")), Data(latest.utf8))
    XCTAssertEqual(
      try String(contentsOf: recoveryURL.appendingPathComponent("location.txt"), encoding: .utf8),
      url.path + "\n")

    try original.write(to: url)
    let retrySucceeded = await document.save()
    XCTAssertTrue(retrySucceeded, "Explicit save should retry after the original bytes return")
    XCTAssertEqual(try Data(contentsOf: url), Data(latest.utf8))
    XCTAssertFalse(document.isDirty)
    XCTAssertNil(document.saveProblem)
  }

  @MainActor
  func testRawHTMLSourceAutosavesWithoutApplyingOrReplacingTheLoadedDocument() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("source.html")
    let original = Data("<!DOCTYPE html><html><body><p>Normalized by WebKit</p></body></html>".utf8)
    try original.write(to: url)
    let document = DocumentController(
      autosaveDelayNanoseconds: 80_000_000,
      recoveryDirectory: root.appendingPathComponent("recovery", isDirectory: true))
    let editor = FileEditor(document: document)
    document.attach(editor: editor)
    document.requestOpen(url)
    try await waitUntil { document.hasDocument }
    await document.showSource(.html)
    let requestID = try XCTUnwrap(document.loadRequest?.id)
    let renderedBefore = editor.html
    let unfinished = "<!doctype html><html><body><p>unfinished <b>markup"
    document.editSource(unfinished)

    try await waitUntil {
      (try? Data(contentsOf: url)) == Data(unfinished.utf8) && !document.isDirty
    }
    XCTAssertEqual(try Data(contentsOf: url), Data(unfinished.utf8))
    XCTAssertEqual(document.loadRequest?.id, requestID, "Autosave must not start a WebKit load")
    XCTAssertEqual(editor.html, renderedBefore, "Autosave must not apply the source draft")
    XCTAssertTrue(document.hasSourceDraft, "The source draft remains pending Apply")
    XCTAssertFalse(document.isDirty, "Saved raw source is no longer a disk-dirty document")
  }

  @MainActor
  func testSampleAutosavePromptsForLocationOnceAndKeepsRecoveryDraft() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sampleURL = root.appendingPathComponent("sample.html")
    let sampleBytes = Data("<p>sample source</p>".utf8)
    try sampleBytes.write(to: sampleURL)
    var destinationRequests = 0
    var selectedDestination: URL?
    var whileChoosing: (() -> Void)?
    let document = DocumentController(
      autosaveDelayNanoseconds: 60_000_000,
      recoveryDirectory: root.appendingPathComponent("recovery", isDirectory: true),
      chooseSaveDestination: {
        destinationRequests += 1
        whileChoosing?()
        return selectedDestination
      })
    let editor = FileEditor(document: document)
    document.attach(editor: editor)
    document.openSample(sampleURL)
    try await waitUntil { document.hasDocument }

    editor.edit("<p>first sample draft</p>")
    try await waitUntil { document.recoveryURL != nil }
    let latest = "<p>latest sample draft</p>"
    editor.edit(latest)
    try await Task.sleep(nanoseconds: 180_000_000)

    XCTAssertEqual(
      destinationRequests, 1, "A cancelled location choice should not be repeated per edit")
    XCTAssertNil(document.fileURL)
    XCTAssertEqual(
      try Data(contentsOf: sampleURL), sampleBytes, "Autosave must not overwrite sample input")
    let recoveryURL = try XCTUnwrap(document.recoveryURL)
    XCTAssertEqual(
      try Data(contentsOf: recoveryURL.appendingPathComponent("draft.html")), Data(latest.utf8))

    selectedDestination = root.appendingPathComponent("chosen.html")
    whileChoosing = { editor.html = "<p>Latest unsent edit during save panel</p>" }
    let saved = await document.save()
    XCTAssertTrue(saved)
    let destination = try XCTUnwrap(selectedDestination)
    XCTAssertEqual(document.fileURL, destination)
    XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), editor.html)
    editor.edit("<p>Now autosaved to my chosen location</p>")
    try await waitUntil {
      (try? String(contentsOf: destination, encoding: .utf8)) == editor.html && !document.isDirty
    }
    XCTAssertEqual(destinationRequests, 2)
    XCTAssertEqual(try Data(contentsOf: sampleURL), sampleBytes)
  }

  @MainActor
  func testRecoveryFailurePausesAutosaveWithoutOverwritingTheDocument() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("document.html")
    let recoveryRoot = root.appendingPathComponent("blocked")
    let original = Data("<p>Original bytes</p>".utf8)
    try original.write(to: url)
    try Data("Not a directory".utf8).write(to: recoveryRoot)
    let document = DocumentController(
      autosaveDelayNanoseconds: 60_000_000, recoveryDirectory: recoveryRoot)
    let editor = FileEditor(document: document)
    document.attach(editor: editor)
    document.requestOpen(url)
    try await waitUntil { document.hasDocument }
    editor.edit("<p>Keep this in memory</p>")
    try await waitUntil { document.saveProblem != nil }
    XCTAssertEqual(try Data(contentsOf: url), original)
    XCTAssertTrue(document.isDirty)
    XCTAssertEqual(document.saveState, "Couldn’t save")
    XCTAssertNil(document.recoveryURL)

    // Repair the test-owned path. A manual save explicitly retries the failed operation.
    try FileManager.default.removeItem(at: recoveryRoot)
    let saved = await document.save()
    XCTAssertTrue(saved)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), editor.html)
    XCTAssertEqual(document.saveState, "Saved")
    XCTAssertNil(document.saveProblem)
  }

  @MainActor
  func testSwitchingDocumentsCancelsPendingAutosaveForThePreviousFile() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let firstURL = root.appendingPathComponent("first.html")
    let secondURL = root.appendingPathComponent("second.html")
    let firstBytes = Data("<p>first saved bytes</p>".utf8)
    let secondBytes = Data("<p>second saved bytes</p>".utf8)
    try firstBytes.write(to: firstURL)
    try secondBytes.write(to: secondURL)
    let document = DocumentController(
      autosaveDelayNanoseconds: 300_000_000,
      recoveryDirectory: root.appendingPathComponent("recovery", isDirectory: true))
    let editor = FileEditor(document: document)
    document.attach(editor: editor)
    document.requestOpen(firstURL)
    try await waitUntil { document.hasDocument }
    editor.edit("<p>must not land in second file</p>")

    document.requestOpen(secondURL)
    try await waitUntil { document.showUnsavedPrompt }
    document.resolveUnsavedPrompt(.discard)
    try await waitUntil { document.fileURL == secondURL && !document.isLoading }
    try await Task.sleep(nanoseconds: 400_000_000)

    XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
    XCTAssertEqual(try Data(contentsOf: secondURL), secondBytes)
    XCTAssertEqual(document.fileURL, secondURL)
  }

  @MainActor
  func testSaveAcceptsALateNotificationForTheSameCapturedContent() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("document.html")
    try Data("<p>Original</p>".utf8).write(to: url)
    let document = DocumentController(recoveryDirectory: root.appendingPathComponent("recovery"))
    let editor = FileEditor(document: document)
    document.attach(editor: editor)
    document.requestOpen(url)
    try await waitUntil { document.hasDocument }

    // WebKit has the last keystroke, but its change notification is still in flight.
    let latest = "<p>Latest words</p>"
    editor.html = latest
    editor.suspendNextSerialization()
    let saving = Task { await document.save() }
    try await waitUntil { editor.serializationIsSuspended }
    editor.edit(latest)
    editor.resumeSerialization()

    let saved = await saving.value
    XCTAssertTrue(saved)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), latest)
    XCTAssertFalse(document.isDirty)
  }

  @MainActor
  func testOlderSuspendedAutosaveCannotMarkANewerEditSaved() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("document.html")
    let original = Data("<p>original</p>".utf8)
    try original.write(to: url)
    let document = DocumentController(
      autosaveDelayNanoseconds: 220_000_000,
      recoveryDirectory: root.appendingPathComponent("recovery", isDirectory: true))
    let editor = FileEditor(document: document)
    document.attach(editor: editor)
    document.requestOpen(url)
    try await waitUntil { document.hasDocument }

    document.errorMessage = "An unrelated earlier Finder action failed"
    editor.suspendNextSerialization()
    editor.edit("<p>older captured edit</p>")
    try await waitUntil { editor.serializationIsSuspended }
    editor.edit("<p>newer edit</p>")
    editor.resumeSerialization()
    try await Task.sleep(nanoseconds: 60_000_000)
    XCTAssertEqual(try Data(contentsOf: url), original)
    XCTAssertTrue(document.isDirty, "An old capture must not mark the newer edit saved")
    XCTAssertNil(document.saveProblem, "A superseded capture is not a save failure")

    try await waitUntil {
      (try? Data(contentsOf: url)) == Data("<p>newer edit</p>".utf8) && !document.isDirty
    }
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
  private func makeTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "kiln-autosave-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
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
  private var shouldSuspendSerialization = false
  private var suspendedSnapshot = ""
  private var serializationContinuation: CheckedContinuation<String, Never>?
  private(set) var serializationIsSuspended = false

  init(document: DocumentController) { self.document = document }
  func load(_ request: DocumentController.LoadRequest) {
    html = "<!DOCTYPE html><html><body><p>Normalized by WebKit</p></body></html>"
    document.documentDidLoad(requestID: request.id, success: true)
    document.editorDidBecomeReady(requestID: request.id, html: html, wordCount: 3, outline: [])
  }
  func setEditing(_ editing: Bool) {}
  func serialize() async throws -> String {
    let snapshot = html
    guard shouldSuspendSerialization else { return snapshot }
    shouldSuspendSerialization = false
    suspendedSnapshot = snapshot
    serializationIsSuspended = true
    return await withCheckedContinuation { serializationContinuation = $0 }
  }
  func edit(_ html: String) {
    self.html = html
    document.editorDidChange(html: html, wordCount: 3, outline: [])
  }
  func suspendNextSerialization() { shouldSuspendSerialization = true }
  func resumeSerialization() {
    serializationIsSuspended = false
    serializationContinuation?.resume(returning: suspendedSnapshot)
    serializationContinuation = nil
  }
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
