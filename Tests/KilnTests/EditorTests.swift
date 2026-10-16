import AppKit
import WebKit
import XCTest

@testable import Kiln

final class KilnWebKitIntegrationTests: XCTestCase {
  @MainActor
  func testInjectedEditorSupportsEditingHistoryAndPreview() async throws {
    let harness = EditorHarness(testCase: self, source: try EditorHarness.editorSource())
    defer { harness.stop() }
    let ready = expectation(description: "editor posts ready")
    harness.onReady = { ready.fulfill() }

    try await harness.load()
    await fulfillment(of: [ready], timeout: 5)

    await harness.assertTrue("window.kiln.serialize().includes('Heading 42')")

    try await harness.beginEditing()
    try await harness.evaluate("window.kiln.focusHeading(1)")
    try await harness.evaluate(
      """
      const heading = document.querySelector('#chapter');
      const range = document.createRange();
      range.selectNodeContents(heading);
      range.setStart(heading.firstChild, 8);
      range.setEnd(heading.firstChild, 10);
      const selection = getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      document.execCommand('insertText', false, 'revised');
      """)
    await harness.assertString(
      "document.querySelector('#chapter').textContent", equals: "Heading revised")

    XCTAssertTrue(harness.undo(), "WebKit should expose an undo action for the editor edit")
    await harness.assertString(
      "document.querySelector('#chapter').textContent", equals: "Heading 42")
    XCTAssertTrue(harness.redo(), "WebKit should expose a redo action after undo")
    await harness.assertString(
      "document.querySelector('#chapter').textContent", equals: "Heading revised")

    try await harness.evaluate("window.kiln.setEditing(false)")
    await harness.assertString(
      "document.querySelector('#chapter').getAttribute('contenteditable')", equals: "false")
    try await harness.evaluate(
      """
      const heading = document.querySelector('#chapter');
      const range = document.createRange();
      range.selectNodeContents(heading);
      getSelection().removeAllRanges();
      getSelection().addRange(range);
      document.execCommand('insertText', false, 'must not appear');
      """)
    await harness.assertString(
      "document.querySelector('#chapter').textContent", equals: "Heading revised")
  }

  @MainActor
  func testListEnterCreatesSiblingItemsAtMiddleAndEnd() async throws {
    let harness = EditorHarness(testCase: self, source: try EditorHarness.editorSource())
    defer { harness.stop() }
    try await harness.load()
    try await harness.waitForReady()
    try await harness.beginEditing()

    try await harness.evaluate(
      """
      const item = document.querySelector('#middle-item');
      const range = document.createRange();
      range.setStart(item.firstChild, 3);
      range.collapse(true);
      getSelection().removeAllRanges();
      getSelection().addRange(range);
      document.execCommand('insertParagraph');
      """)
    await harness.assertNumber("document.querySelectorAll('#middle-list > li').length", equals: 3)
    await harness.assertString(
      "Array.from(document.querySelectorAll('#middle-list > li')).map(li => li.textContent).join('|')",
      equals: "mid|dle|right")

    try await harness.evaluate(
      """
      const paragraph = document.querySelector('#paragraph-item p');
      const range = document.createRange();
      range.setStart(paragraph.firstChild, 9);
      range.collapse(true);
      getSelection().removeAllRanges();
      getSelection().addRange(range);
      paragraph.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true, cancelable: true}));
      """)
    await harness.assertNumber(
      "document.querySelectorAll('#paragraph-list > li').length", equals: 2)
    await harness.assertString(
      "Array.from(document.querySelectorAll('#paragraph-list > li')).map(li => li.textContent.trim()).join('|')",
      equals: "paragraph|content")
    XCTAssertTrue(harness.undo())
    await harness.assertString(
      "document.querySelector('#paragraph-list').textContent", equals: "paragraph content")
    XCTAssertTrue(harness.redo())
    await harness.assertNumber(
      "document.querySelectorAll('#paragraph-list > li').length", equals: 2)

    try await harness.evaluate(
      """
      const items = document.querySelectorAll('#end-list > li');
      const last = items[items.length - 1];
      const range = document.createRange();
      range.selectNodeContents(last);
      range.collapse(false);
      getSelection().removeAllRanges();
      getSelection().addRange(range);
      document.execCommand('insertParagraph');
      """)
    await harness.assertNumber("document.querySelectorAll('#end-list > li').length", equals: 3)
    await harness.assertString(
      "document.querySelector('#end-list > li:last-child').textContent", equals: "")
  }

  @MainActor
  func testOutlineFocusAndChangeMessagesUseThePublicAPI() async throws {
    let harness = EditorHarness(testCase: self, source: try EditorHarness.editorSource())
    defer { harness.stop() }
    try await harness.load()
    try await harness.waitForReady()

    let outline = try await harness.json("window.kiln.outline()") as? [[String: Any]]
    XCTAssertEqual(outline?.map { $0["index"] as? Int }, [0, 1])
    XCTAssertEqual(outline?.map { $0["text"] as? String }, ["Title 17", "Heading 42"])
    XCTAssertEqual(outline?.map { $0["level"] as? Int }, [1, 2])

    try await harness.beginEditing()
    try await harness.evaluate("window.kiln.focusHeading(1)")

    try await harness.evaluate("document.execCommand('insertText', false, 'x')")
    await harness.assertString(
      "document.querySelector('#chapter').textContent", equals: "Heading 42x")
    await harness.waitForChange()
    XCTAssertTrue(harness.receivedChange)
    XCTAssertGreaterThan(harness.lastWordCount ?? 0, 0)
  }

  @MainActor
  func testModeTogglesDoNotChangeTheSerializedDocumentOrNotifyAChange() async throws {
    let harness = EditorHarness(testCase: self, source: try EditorHarness.editorSource())
    defer { harness.stop() }
    try await harness.load()
    try await harness.waitForReady()
    guard let before = try await harness.string("window.kiln.serialize()") else {
      throw NSError(
        domain: "KilnWebKitIntegrationTests", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "serialize() returned no HTML before mode toggle"])
    }

    try await harness.beginEditing()
    try await harness.evaluate("window.kiln.setEditing(false)")
    try await Task.sleep(nanoseconds: 200_000_000)

    guard let after = try await harness.string("window.kiln.serialize()") else {
      throw NSError(
        domain: "KilnWebKitIntegrationTests", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "serialize() returned no HTML after mode toggle"])
    }
    XCTAssertEqual(after, before)
    XCTAssertFalse(
      harness.receivedChange, "Toggling edit mode alone must not report a document change")
  }

  @MainActor
  func testSerializationPreservesDocumentDataAndDoesNotExecuteArtifactPayload() async throws {
    let harness = EditorHarness(testCase: self, source: try EditorHarness.editorSource())
    defer { harness.stop() }
    try await harness.load()
    try await harness.waitForReady()
    try await harness.beginEditing()
    try await harness.evaluate(
      """
      const heading = document.querySelector('#chapter');
      const range = document.createRange();
      range.selectNodeContents(heading);
      range.setStart(heading.firstChild, 9);
      range.setEnd(heading.firstChild, 10);
      getSelection().removeAllRanges();
      getSelection().addRange(range);
      document.execCommand('insertText', false, '3');
      """)

    guard let serialized = try await harness.string("window.kiln.serialize()") else {
      throw NSError(
        domain: "KilnWebKitIntegrationTests", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "serialize() returned no HTML"])
    }
    let exportedURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("kiln-export-\(UUID().uuidString).html")
    defer { try? FileManager.default.removeItem(at: exportedURL) }
    try Data(serialized.utf8).write(to: exportedURL)
    let roundTrip = try String(contentsOf: exportedURL, encoding: .utf8)

    for fragment in [
      "<style id=\"book-style\"", "body { color: #123456; }",
      "<script id=\"inert\" type=\"application/json\">",
      "\"key\":\"value\"",
      "window.kilnPayloadRan = '<tag' && document.documentElement.setAttribute('data-payload-ran', 'yes');",
      "<!-- preserve this comment -->", "<svg", "viewBox=\"0 0 9 7\"",
      "<a href=\"https://example.test/kiln\"", "data-preserve=\"left-unequal-right\"",
      "name=\"kiln-meta\"",
    ] {
      XCTAssertTrue(
        roundTrip.contains(fragment), "Serialized export lost expected fragment: \(fragment)")
    }
    XCTAssertTrue(
      roundTrip.contains("Heading 43"),
      "Serialization must retain the edit rather than restoring the original document")
    XCTAssertFalse(
      roundTrip.contains("contenteditable"), "Serialized output must not contain editing attributes"
    )
    XCTAssertFalse(
      roundTrip.contains("data-kiln-editing"), "Serialized output must not contain editor markers")
    XCTAssertFalse(
      roundTrip.contains("data-kiln-editor-style"),
      "Serialized output must not contain injected editor styles")
    await harness.assertFalse("document.documentElement.hasAttribute('data-payload-ran')")
  }

  @MainActor
  func testFormatCommandChangesTheDocument() async throws {
    let harness = EditorHarness(testCase: self, source: try EditorHarness.editorSource())
    defer { harness.stop() }
    try await harness.load()
    try await harness.waitForReady()
    try await harness.beginEditing()
    try await harness.evaluate(
      """
      const paragraph = document.querySelector('#format-me');
      const range = document.createRange();
      range.selectNodeContents(paragraph);
      getSelection().removeAllRanges();
      getSelection().addRange(range);
      window.kiln.format('bold');
      """)
    await harness.assertString(
      "document.querySelector('#format-me > b').textContent", equals: "format target")
  }

  @MainActor
  func testMarkdownHeadingAndListShortcutsPreserveDocumentContent() async throws {
    let harness = EditorHarness(testCase: self, source: try EditorHarness.editorSource())
    defer { harness.stop() }
    try await harness.load(
      html: """
        <!doctype html><html><body>
        <p id="heading-1" class="keep one">one remains</p>
        <p id="heading-2" class="keep two">two <em>remains</em></p>
        <p id="heading-3" class="keep three">three remains</p>
        <p id="heading-4" class="keep four">four remains</p>
        <p id="heading-5" class="keep five">five remains</p>
        <h2 id="heading-6" class="keep six">six remains</h2>
        <p id="loaded">## existing document text</p>
        <p id="dash">dash item</p>
        <p id="star">star item</p>
        <p id="ordered">ordered item</p>
        </body></html>
        """)
    try await harness.waitForReady()
    try await harness.beginEditing()

    let classSuffixes = ["one", "two", "three", "four", "five", "six"]
    for level in 1...6 {
      try await harness.placeCaret(in: "#heading-\(level)")
      try await harness.type(String(repeating: "#", count: level) + " ")
      await harness.assertString(
        "document.querySelector('#heading-\(level)').localName", equals: "h\(level)")
      await harness.assertString(
        "document.querySelector('#heading-\(level)').textContent",
        equals: "\(classSuffixes[level - 1]) remains")
      await harness.assertString(
        "document.querySelector('#heading-\(level)').getAttribute('class')",
        equals: "keep \(classSuffixes[level - 1])")
    }
    await harness.assertString(
      "document.querySelector('#heading-2 em').textContent", equals: "remains")
    XCTAssertTrue(harness.undo())
    await harness.assertString("document.querySelector('#heading-6').localName", equals: "h2")
    await harness.assertString(
      "document.querySelector('#heading-6').textContent", equals: "###### six remains")
    XCTAssertTrue(harness.redo())
    await harness.assertString("document.querySelector('#heading-6').localName", equals: "h6")
    await harness.assertString("document.querySelector('#loaded').localName", equals: "p")
    await harness.assertString(
      "document.querySelector('#loaded').textContent", equals: "## existing document text")

    for (id, shortcut, list, itemText) in [
      ("dash", "- ", "ul", "dash item"),
      ("star", "* ", "ul", "star item"),
      ("ordered", "1. ", "ol", "ordered item"),
    ] {
      try await harness.placeCaret(in: "#\(id)")
      try await harness.type(shortcut)
      await harness.assertString(
        "document.querySelector('#\(id)').closest('ul, ol').localName", equals: list)
      await harness.assertString(
        "document.querySelector('#\(id)').textContent", equals: itemText)
      await harness.assertTrue("document.querySelector('#\(id)').closest('li') !== null")
    }

    guard let exported = try await harness.string("window.kiln.serialize()") else {
      XCTFail("serialize() returned no HTML after Markdown block shortcuts")
      return
    }
    for snippet in [
      "<h6 id=\"heading-6\" class=\"keep six\">six remains</h6>",
      "<ul", "<ol", "dash item", "star item", "ordered item",
    ] {
      XCTAssertTrue(exported.contains(snippet), "Serialized HTML lost \(snippet)")
    }
    XCTAssertFalse(exported.contains("data-kiln-editing"))
  }

  @MainActor
  func testMarkdownInlineShortcutsAreSemanticAndUndoable() async throws {
    let harness = EditorHarness(testCase: self, source: try EditorHarness.editorSource())
    defer { harness.stop() }
    try await harness.load(
      html: """
        <!doctype html><html><body>
        <p id="double-star"></p><p id="double-underscore"></p>
        <p id="single-star"></p><p id="single-underscore"></p>
        <p id="html-text"></p><p id="weighted" style="font-weight: 700"></p>
        </body></html>
        """)
    try await harness.waitForReady()
    try await harness.beginEditing()

    try await harness.placeCaret(in: "#double-star")
    try await harness.type("**bold**")
    let boldText = "document.querySelector('#double-star').textContent.replace(/\\u00a0/g, ' ')"
    await harness.assertString(boldText, equals: "**bold**")
    try await harness.type(" ")
    await harness.assertString(
      "document.querySelector('#double-star > strong').textContent", equals: "bold")
    await harness.assertString(boldText, equals: "bold ")
    XCTAssertTrue(harness.undo(), "Native Undo should restore the literal Markdown shortcut")
    await harness.assertString(boldText, equals: "**bold** ")
    await harness.assertNumber(
      "document.querySelectorAll('#double-star > strong').length", equals: 0)
    XCTAssertTrue(harness.redo(), "Native Redo should reapply the Markdown shortcut")
    await harness.assertString(
      "document.querySelector('#double-star > strong').textContent", equals: "bold")
    try await harness.type("next")
    await harness.assertString(boldText, equals: "bold next")
    await harness.assertString(
      "document.querySelector('#double-star > strong').textContent", equals: "bold")
    XCTAssertTrue(harness.undo())
    await harness.assertString(boldText, equals: "bold ")
    XCTAssertTrue(harness.undo())
    await harness.assertString(boldText, equals: "**bold** ")
    XCTAssertTrue(harness.redo())
    await harness.assertString(
      "document.querySelector('#double-star > strong').textContent", equals: "bold")
    XCTAssertTrue(harness.redo())
    await harness.assertString(boldText, equals: "bold next")

    for (id, markdown, tag, text) in [
      ("double-underscore", "__bold__", "strong", "bold"),
      ("single-star", "*italic*", "em", "italic"),
      ("single-underscore", "_italic_", "em", "italic"),
      (
        "html-text", "**<img src=x onerror=document.documentElement.dataset.payloadRan=1>**",
        "strong", "<img src=x onerror=document.documentElement.dataset.payloadRan=1>"
      ),
    ] {
      try await harness.placeCaret(in: "#\(id)")
      try await harness.type(markdown + " ")
      await harness.assertString(
        "document.querySelector('#\(id) > \(tag)').textContent", equals: text)
      await harness.assertString(
        "document.querySelector('#\(id)').textContent.replace(/\\u00a0/g, ' ')", equals: text + " ")
    }
    await harness.assertNumber("document.querySelectorAll('#html-text img').length", equals: 0)
    await harness.assertFalse("document.documentElement.hasAttribute('data-payload-ran')")
    try await harness.placeCaret(in: "#weighted")
    try await harness.type("**heavy** next")
    await harness.assertString(
      "document.querySelector('#weighted').textContent.replace(/\\u00a0/g, ' ')",
      equals: "heavy next")
    await harness.assertString(
      "document.querySelector('#weighted strong').textContent", equals: "heavy")
    await harness.assertString(
      "getComputedStyle(getSelection().anchorNode.parentElement).fontWeight", equals: "700")

    guard let exported = try await harness.string("window.kiln.serialize()") else {
      XCTFail("serialize() returned no HTML after inline Markdown shortcuts")
      return
    }
    XCTAssertTrue(exported.contains("<strong>bold</strong>"))
    XCTAssertTrue(exported.contains("<em>italic</em>"))
    XCTAssertFalse(exported.contains("**bold**"))
    XCTAssertFalse(exported.contains("__bold__"))
    XCTAssertFalse(exported.contains("*italic*"))
    XCTAssertFalse(exported.contains("_italic_"))
  }

  @MainActor
  func testMarkdownShortcutsIgnoreLiteralContextsAndPlainTextPaste() async throws {
    let harness = EditorHarness(testCase: self, source: try EditorHarness.editorSource())
    defer { harness.stop() }
    try await harness.load(
      html: """
        <!doctype html><html><body>
        <pre id="pre"></pre><p><code id="code">left right</code></p>
        <p id="escaped"></p><p id="intraword"></p><p id="incomplete"></p>
        <p id="locked"></p><p id="paste"></p><p id="paste-close">**keep**</p>
        </body></html>
        """)
    try await harness.waitForReady()
    try await harness.beginEditing()

    for (selector, text, expected) in [
      ("#pre", "**code** ", "**code** "),
      ("#code", "**code** ", "left**code**  right"),
      ("#escaped", "\\**escaped** ", "\\**escaped** "),
      ("#intraword", "word_under_score_ ", "word_under_score_ "),
      ("#incomplete", "**unfinished ", "**unfinished "),
    ] {
      try await harness.placeCaret(in: selector, textOffset: selector == "#code" ? 4 : nil)
      try await harness.type(text)
      await harness.assertString(
        "document.querySelector('\(selector)').textContent.replace(/\\u00a0/g, ' ')",
        equals: expected)
      await harness.assertNumber(
        "document.querySelectorAll('\(selector) strong, \(selector) em').length", equals: 0)
    }

    try await harness.evaluate("window.kiln.setEditing(false)")
    try await harness.placeCaret(in: "#locked")
    try await harness.type("# locked")
    await harness.assertString("document.querySelector('#locked').textContent", equals: "")
    await harness.assertString("document.querySelector('#locked').localName", equals: "p")

    try await harness.beginEditing()
    try await harness.placeCaret(in: "#paste")
    let pasted = "**<img src=x onerror=document.documentElement.dataset.payloadRan=1>**"
    let pasteLiteral = try Self.javaScriptLiteral(pasted)
    try await harness.evaluate(
      """
      const target = document.querySelector('#paste');
      const transfer = new DataTransfer();
      transfer.setData('text/plain', \(pasteLiteral));
      transfer.setData('text/html', \(pasteLiteral));
      target.dispatchEvent(new ClipboardEvent('paste', {
        bubbles: true, cancelable: true, clipboardData: transfer
      }));
      """)
    await harness.assertString("document.querySelector('#paste').textContent", equals: pasted)
    await harness.assertNumber("document.querySelectorAll('#paste img').length", equals: 0)
    await harness.assertNumber(
      "document.querySelectorAll('#paste strong, #paste em').length", equals: 0)
    try await Task.sleep(nanoseconds: 200_000_000)
    await harness.assertFalse("document.documentElement.hasAttribute('data-payload-ran')")
    guard let exported = try await harness.string("window.kiln.serialize()") else {
      XCTFail("serialize() returned no HTML after a Markdown-looking plain-text paste")
      return
    }
    XCTAssertTrue(exported.contains("**&lt;img"))
    XCTAssertTrue(exported.contains("&gt;**"))
    XCTAssertFalse(exported.contains("<img"))

    try await harness.placeCaret(in: "#paste-close", textOffset: 8)
    try await harness.evaluate(
      """
      const transfer = new DataTransfer();
      transfer.setData('text/plain', ' ');
      document.querySelector('#paste-close').dispatchEvent(new ClipboardEvent('paste', {
        bubbles: true, cancelable: true, clipboardData: transfer
      }));
      """)
    await harness.assertString(
      "document.querySelector('#paste-close').textContent.replace(/\\u00a0/g, ' ')",
      equals: "**keep** ")
    await harness.assertNumber("document.querySelectorAll('#paste-close strong').length", equals: 0)
  }

  @MainActor
  func testPasteReplacesSelectedTextWithoutInterpretingHTML() async throws {
    let harness = EditorHarness(testCase: self, source: try EditorHarness.editorSource())
    defer { harness.stop() }
    try await harness.load()
    try await harness.waitForReady()
    try await harness.beginEditing()
    try await harness.evaluate(
      """
      const paragraph = document.querySelector('#format-me');
      const range = document.createRange();
      range.setStart(paragraph.firstChild, 7);
      range.setEnd(paragraph.firstChild, 13);
      getSelection().removeAllRanges();
      getSelection().addRange(range);
      const transfer = new DataTransfer();
      transfer.setData('text/plain', 'replacement');
      transfer.setData('text/html', `<img src=x onerror="document.documentElement.setAttribute('data-payload-ran', 'yes')">`);
      paragraph.dispatchEvent(new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: transfer }));
      """)
    await harness.assertString(
      "document.querySelector('#format-me').textContent", equals: "format replacement")
    await harness.assertNumber("document.querySelectorAll('#format-me img').length", equals: 0)
    await harness.assertFalse("document.documentElement.hasAttribute('data-payload-ran')")
  }

  @MainActor
  func testStylesheetAPIInspectsUpdatesAndCreatesOneOverrideWithoutNoopChanges() async throws {
    let harness = EditorHarness(testCase: self, source: try EditorHarness.editorSource())
    defer { harness.stop() }
    try await harness.load()
    try await harness.waitForReady()
    try await harness.beginEditing()

    let inventory = "JSON.stringify(window.kiln.stylesheets().map(sheet => sheet.id))"
    let inventoryValue = try await harness.string(inventory)
    let originalInventory = try XCTUnwrap(inventoryValue)
    await harness.assertNumber("window.kiln.stylesheets().length", equals: 3)
    await harness.assertNumber(
      "new Set(window.kiln.stylesheets().map(sheet => sheet.id)).size", equals: 3)
    await harness.assertTrue(
      "window.kiln.stylesheets().every(sheet => typeof sheet.label === 'string' && sheet.label.length > 0 && typeof sheet.css === 'string')"
    )
    await harness.assertTrue(
      "!window.kiln.stylesheets().some(sheet => sheet.id === 'data-kiln-editor-style')")

    harness.resetChange()
    await harness.assertTrue(
      "window.kiln.setStylesheet(window.kiln.stylesheets()[0].id, window.kiln.stylesheets()[0].css)"
    )
    await harness.assertString(inventory, equals: originalInventory)
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertFalse(
      harness.receivedChange,
      "Inspection and a no-op stylesheet update must not mark the document dirty")

    let dangerousCSS = """
      body { color: rgb(35, 69, 103); }
      body::after { content: '</style><script id="style-breakout">document.documentElement.setAttribute("data-css-payload-ran", "yes")</script><style>'; }
      """
    let cssLiteral = try Self.javaScriptLiteral(dangerousCSS)
    await harness.assertTrue("window.kiln.setStylesheet('new', \(cssLiteral))")
    await harness.assertTrue("window.kiln.setStylesheet('new', \(cssLiteral))")
    await harness.waitForChange()
    XCTAssertTrue(
      harness.receivedChange, "A real stylesheet update should notify the document change")

    await harness.assertNumber(
      "document.querySelectorAll('style:not([data-kiln-editor-style])').length", equals: 3)
    await harness.assertString(
      "Array.from(document.querySelectorAll('style:not([data-kiln-editor-style])')).slice(0, 2).map(style => style.id).join('|')",
      equals: "book-style|secondary-style")
    await harness.assertString(inventory, equals: originalInventory)
    await harness.assertString("getComputedStyle(document.body).color", equals: "rgb(35, 69, 103)")
    await harness.assertString(
      "document.querySelector('#book-style').getAttribute('media')", equals: "screen")
    await harness.assertString(
      "document.querySelector('#book-style').getAttribute('data-owner')", equals: "first")
    await harness.assertString(
      "document.querySelector('#secondary-style').getAttribute('media')", equals: "print")
    await harness.assertString(
      "document.querySelector('#secondary-style').getAttribute('data-owner')", equals: "keep")

    guard let serialized = try await harness.string("window.kiln.serialize()") else {
      XCTFail("serialize() returned no HTML after stylesheet update")
      return
    }
    XCTAssertTrue(serialized.contains("rgb(35, 69, 103)"))
    XCTAssertTrue(
      serialized.contains("#654321"),
      "Updating one stylesheet must preserve the other embedded stylesheet")
    let parsed = try Self.javaScriptLiteral(serialized)
    await harness.assertNumber(
      "new DOMParser().parseFromString(\(parsed), 'text/html').querySelectorAll('script').length",
      equals: 2)
    await harness.assertTrue(
      "new DOMParser().parseFromString(\(parsed), 'text/html').querySelectorAll('style').length === 3"
    )
    await harness.assertTrue(
      "Array.from(new DOMParser().parseFromString(\(parsed), 'text/html').querySelectorAll('style')).at(-1).textContent.includes('body::after')"
    )
    await harness.assertTrue(
      "Array.from(new DOMParser().parseFromString(\(parsed), 'text/html').querySelectorAll('style')).at(-1).textContent.includes('rgb(35, 69, 103)')"
    )
    await harness.assertFalse("document.documentElement.hasAttribute('data-css-payload-ran')")

    do {
      try await harness.evaluate(
        "window.kiln.setStylesheet('missing-style', 'body { color: red; }')")
      XCTFail("An unknown stylesheet id should be rejected")
    } catch {
      // Unknown ids are rejected by throwing rather than silently creating another override.
    }
  }

  @MainActor
  func testFormatSupportsUnderlineBlocksAndOnlySafeLinks() async throws {
    let harness = EditorHarness(testCase: self, source: try EditorHarness.editorSource())
    defer { harness.stop() }
    try await harness.load()
    try await harness.waitForReady()
    try await harness.beginEditing()

    try await harness.evaluate(
      """
      const paragraph = document.querySelector('#format-me');
      const range = document.createRange();
      range.selectNodeContents(paragraph);
      getSelection().removeAllRanges();
      getSelection().addRange(range);
      window.kiln.format('underline');
      """)
    await harness.assertString(
      "document.querySelector('#format-me u').textContent", equals: "format target")

    for (command, tag) in [
      ("heading1", "h1"), ("heading2", "h2"), ("heading3", "h3"), ("paragraph", "p"),
    ] {
      try await harness.evaluate(
        """
        const block = Array.from(document.querySelectorAll('p, h1, h2, h3')).find(element => element.textContent === 'format target');
        const range = document.createRange();
        range.selectNodeContents(block);
        getSelection().removeAllRanges();
        getSelection().addRange(range);
        window.kiln.format('\(command)');
        """)
      await harness.assertTrue(
        "Array.from(document.querySelectorAll('\(tag)')).some(element => element.textContent === 'format target')"
      )
      await harness.assertNumber("document.querySelectorAll('p h1, p h2, p h3').length", equals: 0)
      await harness.assertString("document.querySelector('#format-me').localName", equals: tag)
      if command == "heading1" {
        XCTAssertTrue(harness.undo())
        await harness.assertString("document.querySelector('#format-me').localName", equals: "p")
        XCTAssertTrue(harness.redo())
        await harness.assertString("document.querySelector('#format-me').localName", equals: "h1")
      }
    }
    await harness.assertFalse("window.kiln.serialize().includes('data-kiln-editing')")

    for (command, expectedList) in [
      ("insertUnorderedList", "ul"), ("insertOrderedList", "ol"), ("insertOrderedList", "none"),
    ] {
      try await harness.evaluate("window.kiln.format('\(command)')")
      await harness.assertNumber(
        "document.querySelectorAll('p ul, p ol, ul > ol, ol > ul').length", equals: 0)
      await harness.assertString(
        "document.querySelector('#format-me').closest('ul, ol')?.localName ?? 'none'",
        equals: expectedList)
      await harness.assertTrue("document.querySelector('#format-me').isContentEditable")
    }
    await harness.assertNumber("document.querySelectorAll('#format-me').length", equals: 1)
    XCTAssertTrue(harness.undo())
    await harness.assertString(
      "document.querySelector('#format-me').closest('ul, ol')?.localName", equals: "ol")
    XCTAssertTrue(harness.redo())
    await harness.assertTrue("document.querySelector('#format-me').closest('ul, ol') === null")
    await harness.assertFalse("window.kiln.serialize().includes('data-kiln-editing')")

    try await harness.evaluate(
      """
      const paragraph = document.querySelector('#link-target');
      const range = document.createRange();
      range.selectNodeContents(paragraph);
      getSelection().removeAllRanges();
      getSelection().addRange(range);
      window.kiln.format('createLink', 'https://example.test/safe');
      """)
    await harness.assertString(
      "document.querySelector('#link-target a').getAttribute('href')",
      equals: "https://example.test/safe")

    for unsafeURL in ["javascript:alert(1)", "data:text/html,<script>alert(1)</script>"] {
      do {
        try await harness.evaluate(
          """
          const paragraph = document.querySelector('#unsafe-link-target');
          const range = document.createRange();
          range.selectNodeContents(paragraph);
          getSelection().removeAllRanges();
          getSelection().addRange(range);
          window.kiln.format('createLink', \(try Self.javaScriptLiteral(unsafeURL)));
          """)
      } catch {
        // Rejecting an unsafe URL by throwing is acceptable.
      }
    }
    await harness.assertNumber(
      "document.querySelectorAll('#unsafe-link-target a').length", equals: 0)
    await harness.assertFalse(
      "Array.from(document.querySelectorAll('a')).some(link => /^(javascript|data):/i.test(link.href))"
    )
  }

  private static func javaScriptLiteral(_ value: String) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    return String(decoding: data, as: UTF8.self)
  }

  @MainActor
  func testRelativeAssetsLoadButFilesOutsideTheDocumentFolderDoNot() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = temporary.appendingPathComponent("document/assets")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try Data("h1 { color: rgb(41, 73, 112); }".utf8).write(
      to: folder.appendingPathComponent("theme.css"))
    try Data(
      "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"7\" height=\"11\"><rect width=\"7\" height=\"11\" fill=\"red\"/></svg>"
        .utf8
    )
    .write(to: folder.appendingPathComponent("picture.svg"))
    let outside = temporary.appendingPathComponent("private.css")
    try Data("h1 { font-style: italic; }".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: folder.appendingPathComponent("escape.css"), withDestinationURL: outside)
    let harness = EditorHarness(testCase: self, source: try EditorHarness.editorSource())
    defer { harness.stop() }
    try await harness.load(
      html: """
        <!doctype html><html><head>
        <link rel="stylesheet" href="assets/theme.css">
        <link rel="stylesheet" href="assets/escape.css">
        </head><body onload="document.documentElement.setAttribute('data-event-ran','yes')">
        <h1>Local artifact</h1><img id="local" src="assets/picture.svg">
        <img id="remote" src="https://example.invalid/blocked.png">
        </body></html>
        """, url: temporary.appendingPathComponent("document/report.html"))
    try await harness.waitForReady()
    for _ in 0..<100 {
      if try await harness.boolean("document.querySelector('#local').complete") { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    await harness.assertNumber("document.querySelector('#local').naturalWidth", equals: 7)
    await harness.assertNumber("document.querySelector('#local').naturalHeight", equals: 11)
    await harness.assertString(
      "getComputedStyle(document.querySelector('h1')).color", equals: "rgb(41, 73, 112)")
    await harness.assertString(
      "getComputedStyle(document.querySelector('h1')).fontStyle", equals: "normal")
    await harness.assertNumber("document.querySelector('#remote').naturalWidth", equals: 0)
    await harness.assertFalse("document.documentElement.hasAttribute('data-event-ran')")
    await harness.assertTrue("window.kiln.serialize().includes('src=\"assets/picture.svg\"')")
  }
}

@MainActor
private final class EditorHarness: NSObject, WKScriptMessageHandler {
  let initialDocument = """
    <!doctype html>
    <html lang="en" data-preserve="left-unequal-right">
    <head>
      <meta name="kiln-meta" content="book metadata">
      <style id="book-style" media="screen" data-owner="first">body { color: #123456; }</style>
      <style id="secondary-style" title="Print rules" media="print" data-owner="keep">h1 { color: #654321; }</style>
      <script id="inert" type="application/json">{"key":"value"}</script>
      <script>window.kilnPayloadRan = '<tag' && document.documentElement.setAttribute('data-payload-ran', 'yes');</script>
    </head>
    <body>
      <!-- preserve this comment -->
      <h1 id="title" data-rank="first">Title 17</h1>
      <h2 id="chapter" aria-label="chapter-heading">Heading 42</h2>
      <ul id="middle-list"><li id="middle-item">middle</li><li>right</li></ul>
      <ul id="end-list"><li>first</li><li>last</li></ul>
      <ul id="paragraph-list"><li id="paragraph-item"><p>paragraph content</p></li></ul>
      <p id="format-me">format target</p>
      <p id="link-target">safe link target</p>
      <p id="unsafe-link-target">unsafe link target</p>
      <svg id="mark" viewBox="0 0 9 7" role="img"><title>mark</title><path d="M1 2h3"/></svg>
      <a href="https://example.test/kiln" rel="noopener">linked</a>
    </body>
    </html>
    """

  private unowned let testCase: XCTestCase
  private let window: NSWindow
  private let webView: WKWebView
  private let localFiles = LocalDocumentScheme()
  private var structuralUndo: StructuralEditUndo!
  var onReady: (() -> Void)?
  private(set) var receivedChange = false
  private(set) var lastWordCount: Int?
  private var didPostReady = false
  private var changeExpectation: XCTestExpectation?

  init(testCase: XCTestCase, source: String) {
    self.testCase = testCase
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(localFiles, forURLScheme: LocalDocumentScheme.scheme)
    configuration.userContentController = WKUserContentController()
    let userScript = WKUserScript(
      source: source,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true,
      in: .defaultClient
    )
    configuration.userContentController.addUserScript(userScript)
    webView = WKWebView(frame: .zero, configuration: configuration)
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.contentView = webView
    webView.frame = window.contentView?.bounds ?? .zero
    webView.autoresizingMask = [.width, .height]
    super.init()
    structuralUndo = StructuralEditUndo(webView: webView) { error in
      XCTFail("Structural undo failed: \(error)")
    }
    configuration.userContentController.add(self, contentWorld: .defaultClient, name: "kiln")
    window.makeKeyAndOrderFront(nil)
  }

  func load(html: String? = nil, url: URL = URL(fileURLWithPath: "/tmp/kiln-fixture.html"))
    async throws
  {
    let localURL = localFiles.prepare(url: url, bytes: Data((html ?? initialDocument).utf8))
    webView.load(URLRequest(url: localURL))
  }

  func stop() {
    webView.stopLoading()
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: "kiln", contentWorld: .defaultClient)
    window.orderOut(nil)
  }

  func beginEditing() async throws {
    guard window.makeFirstResponder(webView) else {
      throw NSError(
        domain: "KilnWebKitIntegrationTests", code: 5,
        userInfo: [
          NSLocalizedDescriptionKey: "Could not make the WKWebView first responder before editing"
        ])
    }
    try await evaluate("window.kiln.setEditing(true)")
  }

  func placeCaret(in selector: String, textOffset: Int? = nil) async throws {
    let serializedSelector = try JSONSerialization.data(
      withJSONObject: selector, options: [.fragmentsAllowed])
    let selectorLiteral = String(decoding: serializedSelector, as: UTF8.self)
    try await evaluate(
      """
      const target = document.querySelector(\(selectorLiteral));
      const range = document.createRange();
      range.selectNodeContents(target);
      \(textOffset.map { "range.setStart(target.firstChild, \($0));" } ?? "")
      range.collapse(true);
      const selection = getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      """)
  }

  func type(_ text: String) async throws {
    for character in text {
      let literal = String(decoding: try JSONEncoder().encode(String(character)), as: UTF8.self)
      try await evaluate("document.execCommand('insertText', false, \(literal))")
    }
  }

  func undo() -> Bool {
    guard let undoManager = webView.undoManager, undoManager.canUndo else { return false }
    undoManager.undo()
    return true
  }

  func redo() -> Bool {
    guard let undoManager = webView.undoManager, undoManager.canRedo else { return false }
    undoManager.redo()
    return true
  }

  func waitForReady() async throws {
    guard !didPostReady else { return }
    let ready = testCase.expectation(description: "editor posts ready")
    onReady = { ready.fulfill() }
    await testCase.fulfillment(of: [ready], timeout: 5)
  }

  func waitForChange() async {
    if receivedChange { return }
    let changed = testCase.expectation(description: "editor posts change")
    changeExpectation = changed
    await testCase.fulfillment(of: [changed], timeout: 5)
  }

  func resetChange() {
    receivedChange = false
    lastWordCount = nil
  }

  func assertString(
    _ expression: String, equals expected: String, file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      let actual = try await string(expression)
      XCTAssertEqual(actual, expected, file: file, line: line)
    } catch {
      XCTFail("JavaScript evaluation failed: \(error)", file: file, line: line)
    }
  }

  func assertNumber(
    _ expression: String, equals expected: Int, file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      let actual = try await number(expression)
      XCTAssertEqual(actual, expected, file: file, line: line)
    } catch {
      XCTFail("JavaScript evaluation failed: \(error)", file: file, line: line)
    }
  }

  func assertTrue(_ expression: String, file: StaticString = #filePath, line: UInt = #line) async {
    do {
      let actual = try await boolean(expression)
      XCTAssertTrue(actual, file: file, line: line)
    } catch {
      XCTFail("JavaScript evaluation failed: \(error)", file: file, line: line)
    }
  }

  func assertFalse(_ expression: String, file: StaticString = #filePath, line: UInt = #line) async {
    do {
      let actual = try await boolean(expression)
      XCTAssertFalse(actual, file: file, line: line)
    } catch {
      XCTFail("JavaScript evaluation failed: \(error)", file: file, line: line)
    }
  }

  func evaluate(_ expression: String) async throws {
    _ = try await evaluateJavaScript("(() => { \(expression) })()")
  }

  func string(_ expression: String) async throws -> String? {
    try await evaluateJavaScript(expression) as? String
  }

  func number(_ expression: String) async throws -> Int? {
    try await evaluateJavaScript(expression) as? Int
  }

  func boolean(_ expression: String) async throws -> Bool {
    try await evaluateJavaScript(expression) as? Bool ?? false
  }

  func json(_ expression: String) async throws -> Any? {
    guard let serialized = try await evaluateJavaScript("JSON.stringify(\(expression))") as? String
    else { return nil }
    return try JSONSerialization.jsonObject(with: Data(serialized.utf8))
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
      return
    }
    switch type {
    case "structuralEdit":
      if let id = body["id"] as? Int, let label = body["label"] as? String {
        structuralUndo.record(id, label: label)
      }
    case "ready":
      didPostReady = true
      onReady?()
    case "change":
      receivedChange = true
      lastWordCount = body["wordCount"] as? Int
      changeExpectation?.fulfill()
      changeExpectation = nil
    default:
      break
    }
  }

  private func evaluateJavaScript(_ source: String) async throws -> Any? {
    try await withCheckedThrowingContinuation { continuation in
      webView.evaluateJavaScript(source, in: nil, in: .defaultClient) { result in
        continuation.resume(with: result)
      }
    }
  }

  static func editorSource() throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let candidates = [
      packageRoot.appendingPathComponent("Sources/Kiln/Resources/editor.js"),
      packageRoot.appendingPathComponent("Resources/editor.js"),
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
        "Sources/Kiln/Resources/editor.js"),
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
        "Resources/editor.js"),
    ]
    guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    else {
      throw NSError(
        domain: "KilnWebKitIntegrationTests", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Could not locate Resources/editor.js. Checked: \(candidates.map(\.path).joined(separator: ", "))"
        ])
    }
    return try String(contentsOf: url, encoding: .utf8)
  }
}
