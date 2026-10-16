import AppKit
import SwiftUI

@main
struct KilnApp: App {
  @NSApplicationDelegateAdaptor(KilnApplicationDelegate.self) private var appDelegate
  @StateObject private var document = DocumentController()
  @AppStorage("appearance") private var appearance = AppAppearance.system

  var body: some Scene {
    Window("Kiln", id: "main") {
      KilnWindow(document: document)
        .frame(minWidth: 900, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
          appDelegate.document = document
          guard !document.hasDocument, !document.isLoading else { return }
          if let url = appDelegate.pendingURL {
            appDelegate.pendingURL = nil
            document.requestOpen(url)
          } else if let path = CommandLine.arguments.dropFirst().first,
            ["html", "htm"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
          {
            document.requestOpen(URL(fileURLWithPath: path))
          } else {
            loadWelcomeDocument()
          }
        }
    }
    .defaultSize(width: 1120, height: 900)
    .commands {
      TextEditingCommands()
      CommandGroup(replacing: .newItem) {
        ForEach([EditorCommand.open, .save, .saveAs]) { command in
          Button(command.title) { command.perform(document) }
            .keyboardShortcut(command.key, modifiers: command.modifiers)
            .disabled(!command.isEnabled(document))
        }
        Divider()
        ForEach(EditorCommand.fileActions) { command in
          Button(command.title) { command.perform(document) }
            .keyboardShortcut(command.key, modifiers: command.modifiers)
            .disabled(!command.isEnabled(document))
        }
        Divider()
        Button("Show Recovery Copy in Finder") { document.revealRecovery() }
          .disabled(document.recoveryURL == nil)
      }
      CommandGroup(replacing: .printItem) {
        Button("Command Palette…") { document.showCommandPalette = true }
          .keyboardShortcut("p", modifiers: .command)
      }
      CommandMenu("Format") {
        ForEach(EditorCommand.formatting) { command in
          Button(command.title) { command.perform(document) }
            .keyboardShortcut(command.key, modifiers: command.modifiers)
            .disabled(!command.isEnabled(document))
        }
      }
      CommandMenu("View") {
        let lockCommand: EditorCommand = document.isEditingLocked ? .unlockEditing : .lockEditing
        Button(lockCommand.title) { lockCommand.perform(document) }
          .keyboardShortcut(lockCommand.key, modifiers: lockCommand.modifiers)
          .disabled(!lockCommand.isEnabled(document))
        Divider()
        ForEach([EditorCommand.editCSS, .editHTML, .closeCode]) { command in
          Button(command.title) { command.perform(document) }
            .keyboardShortcut(command.key, modifiers: command.modifiers)
            .disabled(!command.isEnabled(document))
        }
        Divider()
        Picker("Appearance", selection: $appearance) {
          ForEach(AppAppearance.allCases) { option in Text(option.title).tag(option) }
        }
      }
    }
  }

  private func loadWelcomeDocument() {
    guard let url = KilnResources.bundle.url(forResource: "Welcome", withExtension: "html") else {
      document.errorMessage = "Kiln couldn't find its bundled Welcome.html sample."
      return
    }
    document.openSample(url)
  }
}

@MainActor
final class KilnApplicationDelegate: NSObject, NSApplicationDelegate {
  weak var document: DocumentController?
  var pendingURL: URL?
  private var approvedTermination = false

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !approvedTermination, let document, document.hasDocument else { return .terminateNow }
    document.requestQuit { [weak self] in
      self?.approvedTermination = true
      NSApp.terminate(nil)
    }
    return .terminateCancel
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    guard let url = urls.first else { return }
    if let document { document.requestOpen(url) } else { pendingURL = url }
  }
}
