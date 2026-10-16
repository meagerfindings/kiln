import SwiftUI

enum EditorCommand: String, CaseIterable, Identifiable {
  case open, save, saveAs, editCSS, editHTML, closeCode
  case openBrowser, revealInFinder, copyFilePath, lockEditing, unlockEditing
  case bold, italic, underline, link, heading1, heading2, heading3, paragraph, bullets, numbering

  var id: String { rawValue }
  var title: String {
    switch self {
    case .open: "Open HTML file…"
    case .save: "Save document"
    case .saveAs: "Save a copy…"
    case .editCSS: "Edit CSS"
    case .editHTML: "Edit HTML source"
    case .closeCode: "Return to the page"
    case .openBrowser: "Open in Browser…"
    case .revealInFinder: "Reveal in Finder"
    case .copyFilePath: "Copy File Path"
    case .lockEditing: "Lock Editing"
    case .unlockEditing: "Unlock Editing"
    case .bold: "Bold"
    case .italic: "Italic"
    case .underline: "Underline"
    case .link: "Insert link…"
    case .heading1: "Heading 1"
    case .heading2: "Heading 2"
    case .heading3: "Heading 3"
    case .paragraph: "Normal paragraph"
    case .bullets: "Bulleted list"
    case .numbering: "Numbered list"
    }
  }

  var isFormatting: Bool { Self.formatting.contains(self) }
  static let fileActions: [Self] = [.openBrowser, .revealInFinder, .copyFilePath]
  static let formatting: [Self] = [
    .bold, .italic, .underline, .link, .heading1, .heading2, .heading3, .paragraph, .bullets,
    .numbering,
  ]

  var symbol: String {
    switch self {
    case .open: "folder"
    case .save, .saveAs: "square.and.arrow.down"
    case .editCSS: "paintbrush.pointed"
    case .editHTML: "chevron.left.forwardslash.chevron.right"
    case .closeCode: "doc.richtext"
    case .openBrowser: "globe"
    case .revealInFinder: "doc.viewfinder"
    case .copyFilePath: "doc.on.doc"
    case .lockEditing: "lock"
    case .unlockEditing: "lock.open"
    case .bold: "bold"
    case .italic: "italic"
    case .underline: "underline"
    case .link: "link"
    case .bullets: "list.bullet"
    case .numbering: "list.number"
    default: "textformat"
    }
  }

  var key: KeyEquivalent {
    switch self {
    case .open: "o"
    case .save, .saveAs: "s"
    case .editCSS: "e"
    case .editHTML: "h"
    case .closeCode: "e"
    case .openBrowser: "b"
    case .revealInFinder: "r"
    case .copyFilePath: "c"
    case .lockEditing, .unlockEditing: "l"
    case .bold: "b"
    case .italic: "i"
    case .underline: "u"
    case .link: "k"
    case .heading1: "1"
    case .heading2: "2"
    case .heading3: "3"
    case .paragraph: "0"
    case .bullets: "8"
    case .numbering: "7"
    }
  }

  var modifiers: EventModifiers {
    switch self {
    case .saveAs, .editCSS, .editHTML, .bullets, .numbering: [.command, .shift]
    case .heading1, .heading2, .heading3, .paragraph, .closeCode,
      .openBrowser, .revealInFinder, .copyFilePath, .lockEditing, .unlockEditing:
      [.command, .option]
    default: .command
    }
  }

  var shortcutLabel: String {
    let prefix = modifiers.contains(.option) ? "⌥⌘" : modifiers.contains(.shift) ? "⇧⌘" : "⌘"
    return prefix + String(key.character).uppercased()
  }

  @MainActor func isEnabled(_ document: DocumentController) -> Bool {
    guard !document.isLoading, !document.sourceIsBusy, !document.isFileActionBusy else {
      return false
    }
    if isFormatting { return document.canFormat }
    if self == .open { return true }
    if self == .closeCode { return document.sourceVisible }
    if self == .revealInFinder || self == .copyFilePath { return document.fileURL != nil }
    if self == .lockEditing { return document.hasDocument && !document.isEditingLocked }
    if self == .unlockEditing { return document.hasDocument && document.isEditingLocked }
    return document.hasDocument
  }

  @MainActor func perform(_ document: DocumentController) {
    guard isEnabled(document) else { return }
    switch self {
    case .open: document.openPanel()
    case .save: Task { _ = await document.save() }
    case .saveAs: Task { _ = await document.saveAs() }
    case .editCSS: Task { await document.showSource(.css) }
    case .editHTML: Task { await document.showSource(.html) }
    case .closeCode: Task { await document.closeSource() }
    case .openBrowser: document.requestBrowserOpen()
    case .revealInFinder: document.revealInFinder()
    case .copyFilePath: document.copyFilePath()
    case .lockEditing: document.setEditingLocked(true)
    case .unlockEditing: document.setEditingLocked(false)
    case .link: document.insertLink()
    case .bullets: document.format("insertUnorderedList")
    case .numbering: document.format("insertOrderedList")
    default: document.format(rawValue)
    }
  }
}
