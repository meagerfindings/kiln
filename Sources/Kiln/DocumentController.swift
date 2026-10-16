import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DocumentController: ObservableObject {
  enum UnsavedChoice {
    case save, discard, cancel
  }

  struct Heading: Identifiable, Equatable {
    let index: Int
    let text: String
    let level: Int
    var id: Int { index }
  }

  struct LoadRequest: Equatable {
    let id: UUID
    let url: URL
    let bytes: Data
  }

  struct Stylesheet: Identifiable, Decodable {
    let id: String
    let label: String
    let css: String
  }

  @Published private(set) var fileURL: URL?
  @Published private(set) var sourceURL: URL?
  @Published private(set) var displayName = "Untitled.html"
  @Published private(set) var isDirty = false
  @Published private(set) var wordCount = 0
  @Published private(set) var headings: [Heading] = []
  @Published private(set) var loadRequest: LoadRequest?
  @Published var errorMessage: String?
  @Published var showUnsavedPrompt = false
  @Published private(set) var isEditingLocked = false
  @Published private(set) var sourceVisible = false
  @Published private(set) var sourceLanguage: SourceLanguage = .css
  @Published private(set) var sourceText = ""
  @Published private(set) var stylesheets: [Stylesheet] = []
  @Published private(set) var stylesheetID = "new"
  @Published private(set) var sourceIsBusy = false
  @Published var showCommandPalette = false
  @Published var showBrowserPrompt = false
  @Published private(set) var isFileActionBusy = false
  @Published private(set) var fileActionStatus: String?

  private(set) var originalBytes = Data()
  private(set) var originalHTML = ""
  private(set) var renderedHTML = ""
  private var baselineSerializedHTML = ""
  private var pendingURL: URL?
  private var pendingQuit = false
  private var pendingClose = false
  private var loadCandidate:
    (requestID: UUID, url: URL, bytes: Data, html: String, hasSaveDestination: Bool)?
  private var navigationFinishedID: UUID?
  private var readyDocument: (requestID: UUID, html: String, wordCount: Int, outline: [Heading]?)?
  private var editor: KilnEditorCommands?
  private var onQuitApproved: (() -> Void)?
  private var onCloseApproved: (() -> Void)?
  private var sourceBaseline = ""
  private var cssTask: Task<Void, Never>?
  private var sourceRevision = 0
  private var draftLoadID: UUID?
  private var draftContinuation: CheckedContinuation<Bool, Never>?
  private let fileActions: any DocumentFileActions
  private var fileStatusTask: Task<Void, Never>?

  init(fileActions: (any DocumentFileActions)? = nil) {
    self.fileActions = fileActions ?? SystemDocumentFileActions()
  }

  var saveState: String { isDirty ? "Edited" : (fileURL == nil ? "Sample" : "Saved") }
  var hasDocument: Bool { !renderedHTML.isEmpty }
  var isLoading: Bool { loadCandidate != nil }
  var hasSourceDraft: Bool { sourceVisible && sourceText != sourceBaseline }
  var isPageEditable: Bool {
    hasDocument && !isEditingLocked && !isLoading && !isFileActionBusy
      && (!sourceVisible || sourceLanguage == .css)
  }
  var canFormat: Bool { isPageEditable && !sourceIsBusy }

  func showSource(_ language: SourceLanguage) async {
    guard hasDocument, !isLoading, !sourceIsBusy, !isFileActionBusy else { return }
    sourceIsBusy = true
    defer { sourceIsBusy = false }
    guard await synchronizeFromEditor(), let editor else { return }
    do {
      if language == .css {
        stylesheets = try await editor.stylesheets()
        let selected =
          stylesheets.first(where: { $0.id == stylesheetID && $0.id != "new" })
          ?? stylesheets.first
        stylesheetID = selected?.id ?? "new"
        sourceText = selected?.css ?? ""
      } else {
        sourceText = renderedHTML
      }
      sourceLanguage = language
      sourceBaseline = sourceText
      sourceVisible = true
      // CSS updates a style node; only full HTML drafts can overwrite page edits.
      editor.setEditing(isPageEditable)
    } catch {
      errorMessage = "Couldn't open the code editor: \(error.localizedDescription)"
    }
  }

  func selectStylesheet(_ id: String) async {
    guard !sourceIsBusy, !isLoading, !isFileActionBusy, id != stylesheetID, let editor else {
      return
    }
    sourceIsBusy = true
    defer { sourceIsBusy = false }
    do {
      try await flushCSSChanges()
      stylesheets = try await editor.stylesheets()
      guard let selected = stylesheets.first(where: { $0.id == id }) else { return }
      stylesheetID = id
      sourceText = selected.css
      sourceBaseline = sourceText
    } catch {
      errorMessage = "Couldn't switch stylesheets: \(error.localizedDescription)"
    }
  }

  func editSource(_ text: String) {
    guard !sourceIsBusy, !isLoading, !isEditingLocked, !isFileActionBusy else { return }
    sourceText = text
    sourceRevision += 1
    isDirty = hasSourceDraft || renderedHTML != baselineSerializedHTML
    cssTask?.cancel()
    guard sourceLanguage == .css else { return }
    cssTask = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
      guard let self else { return }
      do { try await self.flushCSSChanges() } catch {
        self.errorMessage = "Couldn't preview the CSS: \(error.localizedDescription)"
      }
    }
  }

  func closeSource() async {
    guard !sourceIsBusy, !isLoading, !isFileActionBusy else { return }
    sourceIsBusy = true
    defer { sourceIsBusy = false }
    guard await synchronizeFromEditor() else { return }
    sourceVisible = false
    editor?.setEditing(isPageEditable)
  }

  @discardableResult
  func applySource() async -> Bool {
    guard !isLoading, let editor else { return false }
    do { try await flushCSSChanges() } catch {
      errorMessage = "Couldn't apply the CSS: \(error.localizedDescription)"
      return false
    }
    guard sourceLanguage == .html, hasSourceDraft, let url = sourceURL else { return true }
    let request = LoadRequest(id: UUID(), url: url, bytes: Data(sourceText.utf8))
    draftLoadID = request.id
    loadCandidate = (request.id, url, request.bytes, sourceText, fileURL != nil)
    navigationFinishedID = nil
    readyDocument = nil
    return await withCheckedContinuation { continuation in
      draftContinuation = continuation
      loadRequest = request
      editor.load(request)
    }
  }

  private func flushCSSChanges() async throws {
    cssTask?.cancel()
    cssTask = nil
    guard sourceVisible, sourceLanguage == .css, hasSourceDraft, let editor else { return }
    let revision = sourceRevision
    let text = sourceText
    try await editor.setStylesheet(stylesheetID, css: text)
    if revision == sourceRevision { sourceBaseline = text }
  }

  func attach(editor: KilnEditorCommands) {
    self.editor = editor
    if let request = loadRequest { editor.load(request) }
    editor.setEditing(isPageEditable)
  }

  func setEditingLocked(_ locked: Bool) {
    isEditingLocked = locked
    editor?.setEditing(isPageEditable)
  }

  func requestBrowserOpen() {
    guard hasDocument, !isLoading, !sourceIsBusy, !isFileActionBusy else { return }
    showBrowserPrompt = true
  }

  func confirmBrowserOpen() async {
    guard hasDocument, !isLoading, !sourceIsBusy, !isFileActionBusy else { return }
    showBrowserPrompt = false
    isFileActionBusy = true
    editor?.setEditing(false)
    defer {
      isFileActionBusy = false
      editor?.setEditing(isPageEditable)
    }
    // Save also reads the latest keystroke and flushes pending CSS/HTML drafts.
    guard await save(), let url = fileURL else { return }
    do {
      try await fileActions.openInBrowser(url)
    } catch {
      errorMessage = "Couldn't open the browser: \(error.localizedDescription)"
    }
  }

  func revealInFinder() {
    guard let url = fileURL, !isLoading, !isFileActionBusy else { return }
    do {
      try fileActions.revealInFinder(url)
    } catch {
      errorMessage = "Couldn't reveal the file in Finder: \(error.localizedDescription)"
    }
  }

  func copyFilePath() {
    guard let url = fileURL, !isLoading, !isFileActionBusy else { return }
    fileStatusTask?.cancel()
    fileActionStatus = nil
    do {
      try fileActions.copyFilePath(url)
      fileActionStatus = "Path copied"
      fileStatusTask = Task { [weak self] in
        do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
        self?.fileActionStatus = nil
      }
    } catch {
      errorMessage = "Couldn't copy the file path: \(error.localizedDescription)"
    }
  }

  func setOnQuitApproved(_ action: @escaping () -> Void) { onQuitApproved = action }
  func setOnCloseApproved(_ action: @escaping () -> Void) { onCloseApproved = action }

  func openPanel() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType.html, UTType(filenameExtension: "htm")].compactMap { $0 }
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "Choose an HTML document to open in Kiln."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    requestOpen(url)
  }

  func openCommandLineDocumentIfPresent() {
    guard let path = CommandLine.arguments.dropFirst().first,
      path.lowercased().hasSuffix(".html") || path.lowercased().hasSuffix(".htm")
    else { return }
    requestOpen(URL(fileURLWithPath: path))
  }

  func requestOpen(_ url: URL) {
    guard !isFileActionBusy else { return }
    guard url.isFileURL else {
      errorMessage = "Kiln can only open local HTML files."
      return
    }
    Task {
      guard await synchronizeFromEditor() else { return }
      pendingURL = url
      continueAfterUnsavedChanges()
    }
  }

  func openSample(_ url: URL) {
    requestLoad(url, hasSaveDestination: false)
  }

  func requestClose(_ action: @escaping () -> Void) {
    onCloseApproved = action
    Task {
      guard await synchronizeFromEditor() else { return }
      pendingClose = true
      continueAfterUnsavedChanges()
    }
  }

  func requestQuit(_ action: @escaping () -> Void) {
    onQuitApproved = action
    Task {
      guard await synchronizeFromEditor() else { return }
      pendingQuit = true
      continueAfterUnsavedChanges()
    }
  }

  func resolveUnsavedPrompt(_ choice: UnsavedChoice) {
    showUnsavedPrompt = false
    Task {
      switch choice {
      case .cancel:
        clearPendingAction()
      case .discard:
        performPendingAction()
      case .save:
        guard await save() else {
          clearPendingAction()
          return
        }
        performPendingAction()
      }
    }
  }

  @discardableResult
  func documentDidLoad(requestID: UUID, success: Bool, message: String? = nil) -> Bool {
    guard loadRequest?.id == requestID else { return false }
    guard success, loadCandidate?.requestID == requestID else {
      errorMessage = message ?? "The HTML document could not be rendered."
      loadRequest = nil
      loadCandidate = nil
      navigationFinishedID = nil
      readyDocument = nil
      if !renderedHTML.isEmpty { editor?.restore(html: renderedHTML, baseURL: sourceURL) }
      draftLoadID = nil
      draftContinuation?.resume(returning: false)
      draftContinuation = nil
      return false
    }

    navigationFinishedID = requestID
    return commitLoadedDocumentIfReady()
  }

  @discardableResult
  func editorDidBecomeReady(requestID: UUID?, html: String, wordCount: Int, outline: [Heading]?)
    -> Bool
  {
    if let requestID, loadCandidate?.requestID == requestID {
      readyDocument = (requestID, html, wordCount, outline)
      return commitLoadedDocumentIfReady()
    }
    self.wordCount = max(0, wordCount)
    if let outline { headings = outline }
    return false
  }

  func editorDidChange(html: String, wordCount: Int, outline: [Heading]?) {
    renderedHTML = html
    self.wordCount = max(0, wordCount)
    if let outline { headings = outline }
    isDirty = html != baselineSerializedHTML || hasSourceDraft
  }

  func replaceOutline(_ outline: [Heading]) { headings = outline }
  func focusHeading(_ index: Int) { editor?.focusHeading(index) }
  func format(_ command: String) {
    guard canFormat else { return }
    editor?.format(command, value: nil)
  }

  func insertLink() {
    guard canFormat else { return }
    let alert = NSAlert()
    alert.messageText = "Link the selected text"
    alert.informativeText = "Enter a web address, email link, or relative URL."
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    field.placeholderString = "https://example.com"
    alert.accessoryView = field
    alert.addButton(withTitle: "Insert Link")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    editor?.format("createLink", value: field.stringValue)
  }

  @discardableResult
  func save() async -> Bool {
    guard await synchronizeFromEditor() else { return false }
    guard let destination = fileURL else { return await saveAs() }
    return write(to: destination, checkExternalChanges: true)
  }

  @discardableResult
  func saveAs() async -> Bool {
    guard await synchronizeFromEditor() else { return false }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.html]
    panel.nameFieldStringValue = displayName == "Untitled.html" ? "Untitled.html" : displayName
    panel.message = "Save this HTML document."
    guard panel.runModal() == .OK, let destination = panel.url else { return false }
    if sourceURL?.deletingLastPathComponent().standardizedFileURL
      != destination.deletingLastPathComponent().standardizedFileURL
    {
      let warning = NSAlert()
      warning.messageText = "Relative assets will stay in their original folder"
      warning.informativeText =
        "Kiln does not copy nearby images or stylesheets. Relative URLs will resolve from the new folder and may stop working. Copy those assets alongside the saved HTML."
      warning.addButton(withTitle: "Save HTML Only")
      warning.addButton(withTitle: "Cancel")
      guard warning.runModal() == .alertFirstButtonReturn else { return false }
    }
    guard write(to: destination, checkExternalChanges: false) else { return false }
    fileURL = destination
    sourceURL = destination
    displayName = destination.lastPathComponent
    return true
  }

  func receiveDrop(_ urls: [URL]) -> Bool {
    guard let url = urls.first, ["html", "htm"].contains(url.pathExtension.lowercased()) else {
      return false
    }
    requestOpen(url)
    return true
  }

  private func requestLoad(_ url: URL, hasSaveDestination: Bool = true) {
    do {
      let bytes = try Data(contentsOf: url)
      guard let html = String(data: bytes, encoding: .utf8) else {
        throw CocoaError(
          .fileReadInapplicableStringEncoding,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Kiln opens UTF-8 HTML only. This file uses a different or invalid text encoding."
          ])
      }
      let request = LoadRequest(id: UUID(), url: url, bytes: bytes)
      loadCandidate = (request.id, url, bytes, html, hasSaveDestination)
      navigationFinishedID = nil
      readyDocument = nil
      loadRequest = request
      editor?.load(request)
    } catch {
      errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
    }
  }

  @discardableResult
  private func write(to destination: URL, checkExternalChanges: Bool) -> Bool {
    let bytes: Data
    if !isDirty {
      bytes = originalBytes
    } else {
      bytes = Data(renderedHTML.utf8)
    }

    do {
      var currentBytes: Data?
      if checkExternalChanges {
        currentBytes = try Data(contentsOf: destination)
        guard currentBytes == originalBytes else {
          errorMessage =
            "\(destination.lastPathComponent) changed outside Kiln. Save As to keep your edits without overwriting the newer file."
          return false
        }
      }
      if currentBytes != bytes {
        try bytes.write(to: destination, options: .atomic)
      }
      originalBytes = bytes
      originalHTML = renderedHTML
      baselineSerializedHTML = renderedHTML
      isDirty = hasSourceDraft
      errorMessage = nil
      return true
    } catch {
      errorMessage = "Couldn't save \(destination.lastPathComponent): \(error.localizedDescription)"
      return false
    }
  }

  private func continueAfterUnsavedChanges() {
    guard isDirty else {
      performPendingAction()
      return
    }
    showUnsavedPrompt = true
  }

  private func commitLoadedDocumentIfReady() -> Bool {
    guard let candidate = loadCandidate,
      navigationFinishedID == candidate.requestID,
      let ready = readyDocument,
      ready.requestID == candidate.requestID
    else { return false }

    let isDraft = draftLoadID == candidate.requestID
    if !isDraft {
      sourceURL = candidate.url
      fileURL = candidate.hasSaveDestination ? candidate.url : nil
      displayName = candidate.hasSaveDestination ? candidate.url.lastPathComponent : "Untitled.html"
      originalBytes = candidate.bytes
      originalHTML = candidate.html
      baselineSerializedHTML = ready.html
      sourceVisible = false
      cssTask?.cancel()
      fileStatusTask?.cancel()
      fileActionStatus = nil
      showBrowserPrompt = false
    }
    renderedHTML = ready.html
    sourceText = ready.html
    sourceBaseline = ready.html
    wordCount = ready.wordCount
    headings = ready.outline ?? []
    isDirty = ready.html != baselineSerializedHTML
    errorMessage = nil
    loadCandidate = nil
    navigationFinishedID = nil
    readyDocument = nil
    draftLoadID = nil
    draftContinuation?.resume(returning: true)
    draftContinuation = nil
    return true
  }

  private func performPendingAction() {
    if let url = pendingURL {
      pendingURL = nil
      requestLoad(url)
    }
    if pendingClose {
      pendingClose = false
      onCloseApproved?()
    }
    if pendingQuit {
      pendingQuit = false
      onQuitApproved?()
    }
  }

  private func clearPendingAction() {
    pendingURL = nil
    pendingClose = false
    pendingQuit = false
  }

  private func synchronizeFromEditor() async -> Bool {
    guard !isLoading else { return false }
    guard hasDocument, let editor else { return true }
    guard await applySource() else { return false }
    do {
      let html = try await editor.serialize()
      renderedHTML = html
      isDirty = html != baselineSerializedHTML || hasSourceDraft
      return true
    } catch {
      errorMessage =
        "Couldn't safely continue because the latest editor contents couldn't be read: \(error.localizedDescription)"
      return false
    }
  }
}

@MainActor
protocol KilnEditorCommands: AnyObject {
  func load(_ request: DocumentController.LoadRequest)
  func setEditing(_ editing: Bool)
  func serialize() async throws -> String
  func restore(html: String, baseURL: URL?)
  func focusHeading(_ index: Int)
  func format(_ command: String, value: String?)
  func stylesheets() async throws -> [DocumentController.Stylesheet]
  func setStylesheet(_ id: String, css: String) async throws
}
