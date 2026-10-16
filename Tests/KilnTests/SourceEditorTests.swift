import AppKit
import SwiftUI
import XCTest

@testable import Kiln

final class SourceEditorTests: XCTestCase {
  @MainActor
  func testSyntaxColorsSurviveTypingAndSwiftUIBindingEcho() throws {
    let harness = SourceEditorHarness(text: #"<div class="copy">text</div>"#, language: .html)
    defer { harness.close() }
    let textView = try harness.textView()

    let tagColorBefore = try XCTUnwrap(
      textView.textStorage?.attribute(
        .foregroundColor, at: 1, effectiveRange: nil) as? NSColor)
    let attributeColorBefore = try XCTUnwrap(
      textView.textStorage?.attribute(
        .foregroundColor, at: 5, effectiveRange: nil) as? NSColor)
    let stringColorBefore = try XCTUnwrap(
      textView.textStorage?.attribute(
        .foregroundColor, at: 12, effectiveRange: nil) as? NSColor)
    XCTAssertFalse(tagColorBefore.isEqual(attributeColorBefore))
    XCTAssertFalse(tagColorBefore.isEqual(stringColorBefore))
    XCTAssertFalse(attributeColorBefore.isEqual(stringColorBefore))

    let end = (textView.string as NSString).length
    textView.setSelectedRange(NSRange(location: end, length: 0))
    textView.insertText("!", replacementRange: textView.selectedRange())
    harness.flushSwiftUI()

    XCTAssertEqual(harness.model.text, #"<div class="copy">text</div>!"#)
    XCTAssertEqual(textView.string, harness.model.text)
    XCTAssertEqual(textView.selectedRange(), NSRange(location: end + 1, length: 0))
    XCTAssertTrue(
      tagColorBefore.isEqual(
        textView.textStorage?.attribute(
          .foregroundColor, at: 1, effectiveRange: nil) as? NSColor))
    XCTAssertTrue(
      attributeColorBefore.isEqual(
        textView.textStorage?.attribute(
          .foregroundColor, at: 5, effectiveRange: nil) as? NSColor))
    XCTAssertTrue(
      stringColorBefore.isEqual(
        textView.textStorage?.attribute(
          .foregroundColor, at: 12, effectiveRange: nil) as? NSColor))
  }

  @MainActor
  func testNativeEditingUndoAndRedoUpdateTheBinding() throws {
    let original = "body { color: red; }"
    let harness = SourceEditorHarness(text: original, language: .css)
    defer { harness.close() }
    let textView = try harness.textView()
    let insertionPoint = (original as NSString).range(of: "red").location + 3
    textView.setSelectedRange(NSRange(location: insertionPoint, length: 0))
    textView.insertText("blue", replacementRange: textView.selectedRange())
    harness.flushSwiftUI()

    let edited = "body { color: redblue; }"
    XCTAssertEqual(harness.model.text, edited)
    XCTAssertTrue(try XCTUnwrap(textView.undoManager).canUndo)

    XCTAssertTrue(textView.tryToPerform(NSSelectorFromString("undo:"), with: nil))
    harness.flushSwiftUI()
    XCTAssertEqual(harness.model.text, original)
    XCTAssertEqual(textView.string, original)

    XCTAssertTrue(textView.tryToPerform(NSSelectorFromString("redo:"), with: nil))
    harness.flushSwiftUI()
    XCTAssertEqual(harness.model.text, edited)
    XCTAssertEqual(textView.string, edited)

    harness.model.text = "p { margin: 0; }"
    harness.flushSwiftUI()
    XCTAssertEqual(textView.string, "p { margin: 0; }")
    XCTAssertFalse(try XCTUnwrap(textView.undoManager).canUndo)
  }

  @MainActor
  func testNativeCompletionAcceptsOpeningAndClosingTagsWithoutDuplicatingPrefix() throws {
    let harness = SourceEditorHarness(text: "<", language: .html)
    defer { harness.close() }
    let textView = try harness.textView()
    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    let openingRange = textView.rangeForUserCompletion
    var openingSelectedIndex = 0
    let openingCompletions =
      textView.completions(
        forPartialWordRange: openingRange, indexOfSelectedItem: &openingSelectedIndex) ?? []
    XCTAssertTrue(openingCompletions.contains("div>"))
    textView.insertCompletion(
      "div>", forPartialWordRange: openingRange, movement: NSReturnTextMovement, isFinal: true)
    harness.flushSwiftUI()
    XCTAssertEqual(harness.model.text, "<div>")

    harness.model.text = "</"
    harness.flushSwiftUI()
    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    let closingRange = textView.rangeForUserCompletion
    var closingSelectedIndex = 0
    let closingCompletions =
      textView.completions(
        forPartialWordRange: closingRange, indexOfSelectedItem: &closingSelectedIndex) ?? []
    XCTAssertTrue(closingCompletions.contains("div>"))
    textView.insertCompletion(
      "div>", forPartialWordRange: closingRange, movement: NSReturnTextMovement, isFinal: true)
    harness.flushSwiftUI()
    XCTAssertEqual(harness.model.text, "</div>")
  }

  @MainActor
  func testSwitchingToCSSDisablesHTMLTagCompletion() throws {
    let harness = SourceEditorHarness(text: "", language: .html)
    defer { harness.close() }
    let textView = try harness.textView()

    harness.setLanguage(.css)
    textView.insertText("<", replacementRange: textView.selectedRange())
    var selectedIndex = 0
    let completions =
      textView.completions(
        forPartialWordRange: textView.rangeForUserCompletion, indexOfSelectedItem: &selectedIndex)
      ?? []
    XCTAssertFalse(completions.contains("div>"))
    XCTAssertTrue(completions.isEmpty)
  }
}

@MainActor
private final class SourceEditorModel: ObservableObject {
  @Published var text: String

  init(text: String) { self.text = text }
}

@MainActor
private struct SourceEditorRoot: View {
  @ObservedObject var model: SourceEditorModel
  var language: SourceLanguage

  var body: some View {
    SourceTextEditor(text: $model.text, language: language, isEditable: true)
      .frame(width: 620, height: 420)
  }
}

@MainActor
private final class SourceEditorHarness {
  let model: SourceEditorModel
  let hostingView: NSHostingView<SourceEditorRoot>
  let window: NSWindow
  private(set) var language: SourceLanguage

  init(text: String, language: SourceLanguage) {
    self.model = SourceEditorModel(text: text)
    self.language = language
    self.hostingView = NSHostingView(rootView: SourceEditorRoot(model: model, language: language))
    self.window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    window.makeKeyAndOrderFront(nil)
    hostingView.layoutSubtreeIfNeeded()
    flushSwiftUI()
  }

  func textView(file: StaticString = #filePath, line: UInt = #line) throws -> NSTextView {
    flushSwiftUI()
    guard let textView = findTextView(in: hostingView) else {
      XCTFail("The NSHostingView did not create an NSTextView", file: file, line: line)
      throw NSError(domain: "KilnSourceEditorTests", code: 1)
    }
    window.makeFirstResponder(textView)
    return textView
  }

  func setLanguage(_ language: SourceLanguage) {
    self.language = language
    hostingView.rootView = SourceEditorRoot(model: model, language: language)
    flushSwiftUI()
  }

  func flushSwiftUI() {
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
    hostingView.layoutSubtreeIfNeeded()
  }

  func close() {
    if let textView = findTextView(in: hostingView) {
      textView.undoManager?.removeAllActions()
      textView.delegate = nil
    }
    window.contentView = nil
    window.close()
  }

  private func findTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    for child in view.subviews {
      if let textView = findTextView(in: child) { return textView }
    }
    return nil
  }
}
