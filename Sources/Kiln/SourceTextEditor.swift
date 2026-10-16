import AppKit
import SwiftUI

enum SourceLanguage {
  case html
  case css
}

struct SourceTextEditor: NSViewRepresentable {
  @Binding var text: String
  let language: SourceLanguage
  let isEditable: Bool
  @Environment(\.colorScheme) private var colorScheme

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let textView = KilnSourceTextView()
    textView.delegate = context.coordinator
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.isGrammarCheckingEnabled = false
    textView.isEditable = isEditable
    textView.isSelectable = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainerInset = NSSize(width: 18, height: 16)
    textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
    textView.string = text
    textView.sourceCompletionHandler = { [weak textView] in textView?.complete(nil) }

    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor
    scrollView.documentView = textView
    context.coordinator.textView = textView
    context.coordinator.apply(language: language, colorScheme: colorScheme)
    context.coordinator.recolor()
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    coordinator.parent = self
    guard let textView = scrollView.documentView as? KilnSourceTextView else { return }
    textView.isEditable = isEditable
    coordinator.apply(language: language, colorScheme: colorScheme)

    // A binding echo from a native edit already matches. Only an actual external
    // replacement resets the native undo stack.
    guard textView.string != text else { return }
    let selection = textView.selectedRange()
    textView.undoManager?.disableUndoRegistration()
    textView.string = text
    textView.undoManager?.enableUndoRegistration()
    textView.undoManager?.removeAllActions()
    let newLength = (text as NSString).length
    let location = min(selection.location, newLength)
    let length = min(selection.length, newLength - location)
    textView.setSelectedRange(NSRange(location: location, length: length))
    coordinator.recolor()
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: SourceTextEditor
    fileprivate weak var textView: KilnSourceTextView?
    private var currentLanguage: SourceLanguage
    private var currentColorScheme: ColorScheme

    init(_ parent: SourceTextEditor) {
      self.parent = parent
      self.currentLanguage = parent.language
      self.currentColorScheme = parent.colorScheme
      super.init()
      for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
        NotificationCenter.default.addObserver(
          self, selector: #selector(historyDidChange), name: name, object: nil)
      }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func historyDidChange(_ notification: Notification) {
      guard let textView, let manager = notification.object as? UndoManager,
        manager === textView.undoManager
      else { return }
      // AppKit's native undo can change the storage without textDidChange.
      parent.text = textView.string
      recolor()
    }

    func apply(language: SourceLanguage, colorScheme: ColorScheme) {
      let needsRecolor = currentLanguage != language || currentColorScheme != colorScheme
      currentLanguage = language
      currentColorScheme = colorScheme
      guard let textView else { return }
      textView.language = language
      textView.backgroundColor = .textBackgroundColor
      if needsRecolor { recolor() }
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? KilnSourceTextView else { return }
      parent.text = textView.string
      recolor()

      guard currentLanguage == .html else { return }
      let text = textView.string as NSString
      let caret = textView.selectedRange().location
      guard caret <= text.length, caret > 0 else { return }
      let beforeCaret = text.substring(to: caret)
      if beforeCaret.hasSuffix("<") || beforeCaret.hasSuffix("</") {
        textView.complete(nil)
      }
    }

    func textView(
      _ textView: NSTextView,
      completions words: [String],
      forPartialWordRange charRange: NSRange,
      indexOfSelectedItem index: UnsafeMutablePointer<Int>?
    ) -> [String] {
      guard currentLanguage == .html, let textView = textView as? KilnSourceTextView else {
        return []
      }
      let source = textView.string as NSString
      let caret = textView.selectedRange().location
      guard caret <= source.length else { return [] }
      let beforeCaret = source.substring(to: caret)
      guard let openingTag = beforeCaret.range(of: "<", options: .backwards) else { return [] }
      let trailing = String(beforeCaret[openingTag.upperBound...])
      guard !trailing.contains(">") else { return [] }

      let prefix: String
      if trailing.hasPrefix("/") {
        prefix = String(trailing.dropFirst())
      } else {
        prefix = trailing
      }
      guard !prefix.contains(where: { $0.isWhitespace || $0 == "/" }) else { return [] }
      let candidates = Self.htmlTags.filter { $0.hasPrefix(prefix.lowercased()) }.map { "\($0)>" }
      index?.pointee = 0
      return candidates
    }

    func recolor() {
      guard let textView, let storage = textView.textStorage, storage.length > 0 else { return }
      let fullRange = NSRange(location: 0, length: storage.length)
      let typingAttributes = textView.typingAttributes
      let baseFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
      let colors = SyntaxColors(colorScheme: currentColorScheme)

      textView.undoManager?.disableUndoRegistration()
      storage.beginEditing()
      storage.setAttributes(
        [.font: baseFont, .foregroundColor: NSColor.labelColor], range: fullRange)
      switch currentLanguage {
      case .html:
        Self.apply(#"</?\s*([A-Za-z][A-Za-z0-9:-]*)"#, group: 1, color: colors.tag, to: storage)
        Self.apply(
          #"\s([A-Za-z_:][A-Za-z0-9_:.-]*)(?=\s*=)"#, group: 1, color: colors.attribute, to: storage
        )
        Self.apply(
          #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, group: 0, color: colors.string, to: storage)
        Self.apply(#"<!--[\s\S]*?-->"#, group: 0, color: colors.comment, to: storage)
      case .css:
        Self.apply(#"(^|})\s*([^{}]+)(?=\{)"#, group: 2, color: colors.selector, to: storage)
        Self.apply(
          #"(?:^|[;{])\s*([-_A-Za-z][-_A-Za-z0-9]*)(?=\s*:)"#, group: 1, color: colors.property,
          to: storage)
        Self.apply(#":\s*([^;{}]+)"#, group: 1, color: colors.value, to: storage)
        Self.apply(
          #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, group: 0, color: colors.string, to: storage)
        Self.apply(#"/\*[\s\S]*?\*/"#, group: 0, color: colors.comment, to: storage)
      }
      storage.endEditing()
      textView.typingAttributes = typingAttributes.merging(
        [.font: baseFont, .foregroundColor: NSColor.labelColor]) { _, new in new }
      textView.undoManager?.enableUndoRegistration()
    }

    private static func apply(
      _ pattern: String,
      group: Int,
      color: NSColor,
      to storage: NSTextStorage
    ) {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
      else {
        return
      }
      let text = storage.string as NSString
      for match in regex.matches(
        in: text as String, range: NSRange(location: 0, length: text.length))
      {
        let range = match.range(at: group)
        guard range.location != NSNotFound, range.length > 0 else { continue }
        storage.addAttribute(.foregroundColor, value: color, range: range)
      }
    }

    private static let htmlTags = [
      "a", "article", "aside", "audio", "blockquote", "body", "br", "button", "canvas", "caption",
      "code", "col", "dd", "details", "dialog", "div", "dl", "dt", "em", "fieldset", "figcaption",
      "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr",
      "html", "iframe", "img", "input", "label", "legend", "li", "link", "main", "meta", "nav",
      "ol", "option", "p", "pre", "script", "section", "select", "small", "source", "span",
      "strong",
      "style", "summary", "svg", "table", "tbody", "td", "textarea", "tfoot", "th", "thead", "tr",
      "ul", "video",
    ]
  }
}

@MainActor
private final class KilnSourceTextView: NSTextView {
  var sourceCompletionHandler: (() -> Void)?
  var language: SourceLanguage = .html

  override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    if [
      #selector(NSTextView.toggleContinuousSpellChecking(_:)),
      #selector(NSTextView.toggleGrammarChecking(_:)),
      #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)),
      #selector(NSTextView.toggleAutomaticTextReplacement(_:)),
      #selector(NSTextView.checkSpelling(_:)),
      #selector(NSTextView.showGuessPanel(_:)),
    ].contains(item.action) {
      return false
    }
    return super.validateUserInterfaceItem(item)
  }

  override var rangeForUserCompletion: NSRange {
    guard language == .html else { return super.rangeForUserCompletion }
    let source = string as NSString
    let caret = selectedRange().location
    guard caret <= source.length else { return NSRange(location: NSNotFound, length: 0) }
    let prefix = source.substring(to: caret) as NSString
    let range = prefix.range(of: #"(?<=<)/?[A-Za-z0-9:-]*$"#, options: .regularExpression)
    guard range.location != NSNotFound else { return range }
    let closing = prefix.substring(with: range).hasPrefix("/") ? 1 : 0
    return NSRange(location: range.location + closing, length: range.length - closing)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 49 && event.modifierFlags.contains(.control) {
      sourceCompletionHandler?()
      return
    }
    super.keyDown(with: event)
  }

  override func insertTab(_ sender: Any?) {
    insertText("  ", replacementRange: selectedRange())
  }

  override func insertNewline(_ sender: Any?) {
    let source = string as NSString
    let selection = selectedRange()
    let lineStart = source.lineRange(
      for: NSRange(location: min(selection.location, source.length), length: 0)
    ).location
    let beforeCaret = source.substring(
      with: NSRange(location: lineStart, length: selection.location - lineStart))
    let indentation = String(beforeCaret.prefix(while: { $0 == " " || $0 == "\t" }))
    let lastNonWhitespace = beforeCaret.last(where: { $0 != " " && $0 != "\t" })
    let extraIndent = lastNonWhitespace == "{" ? "  " : ""
    insertText("\n\(indentation)\(extraIndent)", replacementRange: selection)
  }
}

private struct SyntaxColors {
  let tag: NSColor
  let attribute: NSColor
  let string: NSColor
  let comment: NSColor
  let selector: NSColor
  let property: NSColor
  let value: NSColor

  init(colorScheme: ColorScheme) {
    if colorScheme == .dark {
      tag = NSColor(srgbRed: 0.83, green: 0.58, blue: 0.86, alpha: 1)
      attribute = NSColor(srgbRed: 0.93, green: 0.70, blue: 0.46, alpha: 1)
      string = NSColor(srgbRed: 0.62, green: 0.79, blue: 0.57, alpha: 1)
      comment = NSColor(srgbRed: 0.56, green: 0.61, blue: 0.57, alpha: 1)
      selector = NSColor(srgbRed: 0.83, green: 0.58, blue: 0.86, alpha: 1)
      property = NSColor(srgbRed: 0.61, green: 0.74, blue: 0.94, alpha: 1)
      value = NSColor(srgbRed: 0.93, green: 0.70, blue: 0.46, alpha: 1)
    } else {
      tag = NSColor(srgbRed: 0.48, green: 0.27, blue: 0.56, alpha: 1)
      attribute = NSColor(srgbRed: 0.57, green: 0.34, blue: 0.17, alpha: 1)
      string = NSColor(srgbRed: 0.25, green: 0.43, blue: 0.22, alpha: 1)
      comment = NSColor(srgbRed: 0.44, green: 0.48, blue: 0.45, alpha: 1)
      selector = NSColor(srgbRed: 0.48, green: 0.27, blue: 0.56, alpha: 1)
      property = NSColor(srgbRed: 0.18, green: 0.35, blue: 0.59, alpha: 1)
      value = NSColor(srgbRed: 0.57, green: 0.34, blue: 0.17, alpha: 1)
    }
  }
}
