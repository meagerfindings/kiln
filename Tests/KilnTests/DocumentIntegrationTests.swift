import AppKit
import SwiftUI
import WebKit
import XCTest

@testable import Kiln

final class DocumentIntegrationTests: XCTestCase {
  @MainActor
  func testPointerClickReachesEditablePage() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "kiln-clicks-\(UUID()).html")
    try Data("<p style=\"font-size:24px;margin:40px\">Editable copy</p>".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let harness = NativeDocumentHarness()
    defer { harness.close() }
    harness.document.requestOpen(file)
    try await harness.waitUntil { harness.document.hasDocument && !harness.document.isLoading }
    let web = try XCTUnwrap(harness.web)
    let bounds =
      try await harness.js(
        """
        (() => { const r = document.createRange(); r.selectNodeContents(document.querySelector('p'));
          const b = r.getBoundingClientRect(); return {x: b.x + b.width / 2, y: b.y + b.height / 2}; })()
        """) as? [String: Double]
    let point = try XCTUnwrap(bounds)
    let x = try XCTUnwrap(point["x"])
    let y = try XCTUnwrap(point["y"])
    let pageLocation = web.convert(
      NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y), to: nil)

    // SwiftPM doesn't activate an app. Use AppKit's real hit-testing to choose the mouse
    // target, rather than focusing WKWebView directly and bypassing blocking overlays.
    let content = try XCTUnwrap(harness.window.contentView)
    let parent = try XCTUnwrap(content.superview)
    let target = try XCTUnwrap(content.hitTest(parent.convert(pageLocation, from: nil)))
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = try XCTUnwrap(
        NSEvent.mouseEvent(
          with: type, location: pageLocation, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: harness.window.windowNumber,
          context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      if type == .leftMouseDown {
        target.mouseDown(with: event)
      } else {
        target.mouseUp(with: event)
      }
    }
    try await harness.waitUntil {
      try await harness.js("document.activeElement === document.querySelector('p')") as? Bool
        == true
    }
    // Route typing through the window too: directly focusing WKWebView would hide a blocked click.
    let key = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: harness.window.windowNumber,
        context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false,
        keyCode: 6))
    harness.window.sendEvent(key)
    try await harness.waitUntil {
      try await harness.js("document.querySelector('p').textContent.includes('z')") as? Bool == true
    }
    let text = try await harness.js("document.querySelector('p').textContent") as? String
    XCTAssertEqual(text?.replacingOccurrences(of: "z", with: ""), "Editable copy")
    try await harness.waitUntil { harness.document.isDirty }
  }

  @MainActor
  func testNativeSpellingStartsEnabledHonorsToggleAndExcludesSource() async throws {
    _ = NSApplication.shared
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: "didConfigureProseSpelling")
    let probe = WKWebView()
    func menuItem(_ action: Selector, in web: WKWebView) -> NSMenuItem {
      let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
      _ = web.validateUserInterfaceItem(item)
      return item
    }
    let spelling = #selector(NSTextView.toggleContinuousSpellChecking(_:))
    let replacement = #selector(NSTextView.toggleAutomaticTextReplacement(_:))
    let previousSpelling = menuItem(spelling, in: probe).state
    let previousReplacement = menuItem(replacement, in: probe).state
    defer {
      for (action, state) in [(spelling, previousSpelling), (replacement, previousReplacement)] {
        if menuItem(action, in: probe).state != state {
          NSApp.sendAction(action, to: probe, from: nil)
        }
      }
      if let previous {
        defaults.set(previous, forKey: "didConfigureProseSpelling")
      } else {
        defaults.removeObject(forKey: "didConfigureProseSpelling")
      }
    }
    defaults.removeObject(forKey: "didConfigureProseSpelling")
    if previousSpelling == .on { NSApp.sendAction(spelling, to: probe, from: nil) }
    if previousReplacement == .off { NSApp.sendAction(replacement, to: probe, from: nil) }

    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "kiln-spelling-\(UUID()).html")
    try Data("<html lang=\"en\"><body><p></p></body></html>".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let harness = NativeDocumentHarness()
    defer { harness.close() }
    harness.document.requestOpen(file)
    try await harness.waitUntil { harness.document.hasDocument && !harness.document.isLoading }
    let web = try XCTUnwrap(harness.web)
    XCTAssertEqual(menuItem(spelling, in: web).state, .on)
    XCTAssertEqual(menuItem(replacement, in: web).state, .off)
    harness.window.makeFirstResponder(web)
    _ = try await harness.js("document.querySelector('p').focus()")
    for character in "mispelled " { web.insertText(String(character)) }
    XCTAssertTrue(NSApp.sendAction(#selector(NSTextView.checkSpelling(_:)), to: web, from: nil))
    try await harness.waitUntil {
      try await harness.js("getSelection().toString()") as? String == "mispelled"
    }
    let copy = try await harness.js("document.querySelector('p').textContent") as? String
    XCTAssertEqual(copy?.replacingOccurrences(of: "\u{a0}", with: " "), "mispelled ")

    XCTAssertTrue(NSApp.sendAction(spelling, to: web, from: nil))
    XCTAssertEqual(menuItem(spelling, in: web).state, .off)
    let reopened = NativeDocumentHarness()
    defer { reopened.close() }
    reopened.document.requestOpen(file)
    try await reopened.waitUntil { reopened.document.hasDocument && !reopened.document.isLoading }
    XCTAssertEqual(menuItem(spelling, in: try XCTUnwrap(reopened.web)).state, .off)

    await harness.document.showSource(.html)
    try await harness.waitUntil {
      NativeDocumentHarness.descendant(NSTextView.self, in: harness.view) != nil
    }
    let code = try XCTUnwrap(NativeDocumentHarness.descendant(NSTextView.self, in: harness.view))
    XCTAssertFalse(code.isContinuousSpellCheckingEnabled)
    XCTAssertFalse(code.isAutomaticSpellingCorrectionEnabled)
    XCTAssertFalse(code.isAutomaticTextReplacementEnabled)
    XCTAssertFalse(code.validateUserInterfaceItem(menuItem(spelling, in: web)))
    XCTAssertNil(harness.document.errorMessage)
  }

  @MainActor
  func testCodeEditsPreviewAndSaveThroughTheRealBridgeWithoutLosingPendingChanges() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "kiln-source-\(UUID()).html")
    let original = Data(
      """
      <!doctype html><html><head><style id="primary">h1 { color: rgb(50, 60, 70); }</style>
      <style media="print">p { color: black; }</style></head><body><h1>Before</h1><p>Copy stays here.</p></body></html>
      """.utf8)
    try original.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let harness = NativeDocumentHarness()
    defer { harness.close() }
    let document = harness.document
    document.requestOpen(file)
    try await harness.waitUntil { document.hasDocument && !document.isLoading }

    await document.showSource(.css)
    XCTAssertTrue(document.sourceVisible)
    XCTAssertFalse(document.isDirty, "Inspecting code must not edit the file")
    let savedUnchanged = await document.save()
    XCTAssertTrue(savedUnchanged)
    XCTAssertEqual(try Data(contentsOf: file), original)
    document.editSource("h1 { color: rgb(13, 71, 111); }")
    let savedCSS = await document.save()  // Before the debounce has had time to fire.
    XCTAssertTrue(savedCSS)
    XCTAssertFalse(document.isDirty)
    XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("rgb(13, 71, 111)"))
    let color =
      try await harness.js("getComputedStyle(document.querySelector('h1')).color") as? String
    XCTAssertEqual(color, "rgb(13, 71, 111)")

    await document.showSource(.html)
    document.editSource(
      document.sourceText.replacingOccurrences(of: "Before", with: "After — café"))
    XCTAssertTrue(document.isDirty)
    var closed = false
    document.requestClose { closed = true }
    try await harness.waitUntil { document.showUnsavedPrompt }
    XCTAssertFalse(closed)
    document.resolveUnsavedPrompt(.cancel)
    XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("Before"))
    let savedHTML = await document.save()
    XCTAssertTrue(savedHTML)
    XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("After — café"))
    XCTAssertFalse(document.isDirty)
    await document.closeSource()
    XCTAssertFalse(document.sourceVisible)
    let previousID = document.loadRequest?.id
    document.requestOpen(file)
    try await harness.waitUntil { document.loadRequest?.id != previousID && !document.isLoading }
    let heading = try await harness.js("document.querySelector('h1').textContent") as? String
    XCTAssertEqual(heading, "After — café")
    XCTAssertNil(document.errorMessage)
  }

  @MainActor
  func testCSSAndPageEditsCoexistAndLockProtectsBothEditors() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "kiln-live-\(UUID()).html")
    try Data("<style>p { color: red; }</style><p>Original copy</p>".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let harness = NativeDocumentHarness()
    defer { harness.close() }
    let document = harness.document
    document.requestOpen(file)
    try await harness.waitUntil { document.hasDocument && !document.isLoading }
    await document.showSource(.css)
    document.editSource("p { color: rgb(31, 81, 41); }")
    let changed =
      try await harness.js(
        """
        (() => {
          const p = document.querySelector('p'); p.focus();
          const r = document.createRange(); r.selectNodeContents(p);
          getSelection().removeAllRanges(); getSelection().addRange(r);
          return document.execCommand('insertText', false, 'Edited on the page');
        })()
        """) as? Bool
    XCTAssertEqual(changed, true)
    let saved = await document.save()
    XCTAssertTrue(saved)
    let bytes = try String(contentsOf: file, encoding: .utf8)
    XCTAssertTrue(bytes.contains("Edited on the page"))
    XCTAssertTrue(bytes.contains("rgb(31, 81, 41)"))

    document.setEditingLocked(true)
    try await harness.waitUntil {
      NativeDocumentHarness.descendant(NSTextView.self, in: harness.view)?.isEditable == false
    }
    let locked = try await harness.js("document.querySelector('p').isContentEditable") as? Bool
    XCTAssertEqual(locked, false)
    document.editSource("p { color: blue; }")
    XCTAssertEqual(document.sourceText, "p { color: rgb(31, 81, 41); }")
    XCTAssertFalse(document.isDirty)
    document.setEditingLocked(false)
    try await harness.waitUntil {
      try await harness.js("document.querySelector('p').isContentEditable") as? Bool == true
    }
    try await harness.waitUntil {
      NativeDocumentHarness.descendant(NSTextView.self, in: harness.view)?.isEditable == true
    }

    await document.showSource(.html)
    try await harness.waitUntil {
      try await harness.js("document.querySelector('p').isContentEditable") as? Bool == false
    }
    XCTAssertTrue(document.sourceText.contains("Edited on the page"))
    await document.closeSource()
    try await harness.waitUntil {
      try await harness.js("document.querySelector('p').isContentEditable") as? Bool == true
    }
    XCTAssertFalse(document.isDirty)
    XCTAssertNil(document.errorMessage)
  }
}

@MainActor
final class NativeDocumentHarness {
  let document: DocumentController
  let view: NSHostingView<KilnWindow>
  let window: NSWindow

  init(width: CGFloat = 1120, height: CGFloat = 900, document: DocumentController? = nil) {
    _ = NSApplication.shared
    self.document = document ?? DocumentController()
    view = NSHostingView(rootView: KilnWindow(document: self.document))
    window = NSWindow(
      contentRect: NSRect(x: 40, y: 40, width: width, height: height),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
  }

  var web: WKWebView? { Self.descendant(WKWebView.self, in: view) }
  func close() { window.orderOut(nil) }

  func waitUntil(_ predicate: () async throws -> Bool) async throws {
    for _ in 0..<200 {
      if try await predicate() { return }
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    throw NSError(
      domain: "KilnTests", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Native document operation timed out"])
  }

  func js(_ source: String) async throws -> Any? {
    let web = try XCTUnwrap(web)
    return try await withCheckedThrowingContinuation { continuation in
      web.evaluateJavaScript(source, in: nil, in: .defaultClient) { continuation.resume(with: $0) }
    }
  }

  static func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let found = view as? T { return found }
    return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
  }
}
