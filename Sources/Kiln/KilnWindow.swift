import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct KilnWindow: View {
  @ObservedObject var document: DocumentController
  @AppStorage("appearance") private var appearance = AppAppearance.system
  @Environment(\.colorScheme) private var colorScheme
  @State private var paletteSelection: EditorCommand?

  private var theme: AppTheme { AppTheme(dark: (appearance.colorScheme ?? colorScheme) == .dark) }
  private var ink: Color { theme.ink }
  private var mutedInk: Color { theme.muted }
  private var sage: Color { theme.sage }
  private var sidebar: Color { theme.sidebar }

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Rectangle().fill(theme.separator).frame(height: 1)
      HStack(spacing: 0) {
        if !document.sourceVisible {
          sidebarView.frame(width: 250)
          Rectangle().fill(theme.separator).frame(width: 1)
        }
        KilnEditorView(document: document)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(theme.surface)
        if document.sourceVisible {
          Rectangle().fill(theme.separator).frame(width: 1)
          SourcePanel(document: document).frame(width: 400)
        }
      }
      footer
    }
    .foregroundStyle(ink)
    .background(theme.surface)
    .preferredColorScheme(appearance.colorScheme)
    .sheet(
      isPresented: $document.showCommandPalette,
      onDismiss: {
        paletteSelection?.perform(document)
        paletteSelection = nil
      }
    ) {
      CommandPalette(document: document) { command in
        paletteSelection = command
        document.showCommandPalette = false
      }
    }
    .background {
      WindowCloseGuard(document: document)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
    .alert("Unsaved changes", isPresented: $document.showUnsavedPrompt) {
      Button("Save") { document.resolveUnsavedPrompt(.save) }
      Button("Discard Changes", role: .destructive) { document.resolveUnsavedPrompt(.discard) }
      Button("Cancel", role: .cancel) { document.resolveUnsavedPrompt(.cancel) }
    } message: {
      Text("Save your edits before continuing?")
    }
    .alert("Open in your browser?", isPresented: $document.showBrowserPrompt) {
      Button("Save and Open") { Task { await document.confirmBrowserOpen() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Your latest edits will be saved first. Outside this editor, the file’s scripts can run and load internet resources. Only continue if you trust this HTML."
      )
    }
    .alert(
      "Kiln couldn’t complete that action",
      isPresented: Binding(
        get: { document.errorMessage != nil },
        set: { if !$0 { document.errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) { document.errorMessage = nil }
    } message: {
      Text(document.errorMessage ?? "An unknown error occurred.")
    }
    .dropDestination(for: URL.self) { urls, _ in document.receiveDrop(urls) }
  }

  private var toolbar: some View {
    HStack(spacing: 14) {
      Button(action: document.openPanel) {
        Label("Open", systemImage: "folder")
      }
      .buttonStyle(.plain)
      .keyboardShortcut("o", modifiers: .command)
      .help("Open an HTML file")
      .disabled(document.isFileActionBusy)

      Rectangle().fill(theme.separator).frame(width: 1, height: 22)

      VStack(alignment: .leading, spacing: 2) {
        Text(document.displayName)
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
        HStack(spacing: 5) {
          Circle().fill(document.isDirty ? Color.orange : sage).frame(width: 6, height: 6)
          Text(document.saveState).font(.system(size: 10)).foregroundStyle(mutedInk)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .help(document.fileURL?.path ?? "Save this document to give it a file location")

      if document.isEditingLocked {
        Button {
          document.setEditingLocked(false)
        } label: {
          Label("Locked", systemImage: "lock.fill").font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(mutedInk)
        .help("Unlock Editing · ⌥⌘L")
        .disabled(document.isFileActionBusy)
      }

      HStack(spacing: 16) {
        ForEach(EditorCommand.fileActions) { command in
          Button {
            command.perform(document)
          } label: {
            Label(
              command.title,
              systemImage:
                command == .copyFilePath && document.fileActionStatus != nil
                ? "checkmark" : command.symbol
            )
            .labelStyle(.iconOnly)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier(command.rawValue)
          .help(
            command == .openBrowser || document.fileURL != nil
              ? "\(command.title) · \(command.shortcutLabel)"
              : "Save the document first to use \(command.title)"
          )
          .disabled(!command.isEnabled(document))
        }
      }

      Rectangle().fill(theme.separator).frame(width: 1, height: 22)

      Menu {
        ForEach(EditorCommand.formatting) { command in
          Button(command.title, systemImage: command.symbol) { command.perform(document) }
        }
        Divider()
        Button("Undo", systemImage: "arrow.uturn.backward") { document.format("undo") }
        Button("Redo", systemImage: "arrow.uturn.forward") { document.format("redo") }
      } label: {
        Image(systemName: "textformat")
          .frame(width: 30, height: 30)
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .help("Formatting")
      .disabled(!document.canFormat)

      Button {
        Task {
          if document.sourceVisible {
            await document.closeSource()
          } else {
            await document.showSource(.css)
          }
        }
      } label: {
        Image(systemName: "curlybraces").foregroundStyle(document.sourceVisible ? sage : ink)
      }
      .buttonStyle(.plain)
      .help("HTML & CSS editor")
      .disabled(
        !document.hasDocument || document.isLoading || document.sourceIsBusy
          || document.isFileActionBusy)

      Button {
        document.showCommandPalette = true
      } label: {
        Image(systemName: "command")
      }
      .buttonStyle(.plain)
      .help("Command palette · ⌘P")

      Button("Save") { Task { _ = await document.save() } }
        .buttonStyle(.borderedProminent)
        .tint(Color(red: 0.35, green: 0.48, blue: 0.39))
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!EditorCommand.save.isEnabled(document))

      Menu {
        Button("Save As…") { Task { _ = await document.saveAs() } }
          .keyboardShortcut("s", modifiers: [.command, .shift])
          .disabled(!EditorCommand.saveAs.isEnabled(document))
        Button(document.isEditingLocked ? "Unlock Editing" : "Lock Editing") {
          document.setEditingLocked(!document.isEditingLocked)
        }
        .disabled(!document.hasDocument || document.isFileActionBusy)
        Divider()
        Picker("Appearance", selection: $appearance) {
          ForEach(AppAppearance.allCases) { option in Text(option.title).tag(option) }
        }
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 28, height: 30)
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .help("More file actions")
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 10)
    .background(theme.surface)
  }

  private var sidebarView: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 9) {
        Image(systemName: "doc.text.image")
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(sage)
        Text("Kiln")
          .font(.system(size: 19, weight: .semibold, design: .serif))
          .tracking(-0.4)
      }
      .padding(.horizontal, 20)
      .padding(.top, 22)
      .padding(.bottom, 26)

      Text("DOCUMENT")
        .font(.system(size: 9, weight: .semibold))
        .tracking(1.1)
        .foregroundStyle(mutedInk)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)

      HStack(spacing: 9) {
        Image(systemName: "doc.richtext")
          .font(.system(size: 14))
          .foregroundStyle(sage)
        VStack(alignment: .leading, spacing: 3) {
          Text(document.displayName)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
          Text(
            document.fileURL?.deletingLastPathComponent().lastPathComponent ?? "No save location"
          )
          .font(.system(size: 10))
          .foregroundStyle(mutedInk)
          .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(RoundedRectangle(cornerRadius: 6).fill(theme.card))
      .padding(.horizontal, 12)

      Text("OUTLINE")
        .font(.system(size: 9, weight: .semibold))
        .tracking(1.1)
        .foregroundStyle(mutedInk)
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 9)

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          if document.headings.isEmpty {
            Text(document.hasDocument ? "No headings yet" : "Open an HTML file")
              .font(.system(size: 11))
              .foregroundStyle(mutedInk)
              .padding(.horizontal, 20)
              .padding(.vertical, 7)
          }
          ForEach(document.headings) { heading in
            Button {
              document.focusHeading(heading.index)
            } label: {
              Text(heading.text)
                .font(.system(size: 11, weight: heading.level <= 2 ? .medium : .regular))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, CGFloat(max(0, min(heading.level - 1, 4))) * 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(heading.text)
            .padding(.horizontal, 12)
          }
        }
      }

      Spacer(minLength: 10)
      HStack(spacing: 7) {
        Image(systemName: "lock.shield")
        Text("Local files · No account")
      }
      .font(.system(size: 10))
      .foregroundStyle(mutedInk)
      .padding(.horizontal, 18)
      .padding(.bottom, 16)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(sidebar)
  }

  private var footer: some View {
    HStack {
      Text(document.fileActionStatus ?? editingHint)
        .font(.system(size: 10))
        .foregroundStyle(mutedInk)
      Spacer()
      Text("\(document.wordCount) words")
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .foregroundStyle(mutedInk)
    }
    .padding(.horizontal, 16)
    .frame(height: 30)
    .background(theme.surface)
    .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 1) }
  }

  private var editingHint: String {
    if document.isFileActionBusy { return "Opening the saved file in your browser…" }
    if document.isEditingLocked { return "Editing locked · ⌥⌘L to unlock" }
    if document.sourceVisible && document.sourceLanguage == .html {
      return "HTML draft · Close code to edit the page"
    }
    if document.sourceVisible { return "Edit the page or CSS · Changes stay on this device" }
    return "Click text to edit · Changes stay on this device"
  }
}

private struct WindowCloseGuard: NSViewRepresentable {
  let document: DocumentController

  func makeCoordinator() -> Coordinator { Coordinator(document: document) }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { context.coordinator.install(for: view.window) }
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.install(for: view.window)
  }

  final class Coordinator: NSObject, NSWindowDelegate {
    weak var document: DocumentController?
    weak var window: NSWindow?
    private var approvedClose = false

    init(document: DocumentController) { self.document = document }

    func install(for window: NSWindow?) {
      guard let window, self.window !== window else { return }
      self.window = window
      window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
      if approvedClose {
        approvedClose = false
        return true
      }
      guard let document, document.hasDocument else { return true }
      document.requestClose { [weak self, weak sender] in
        self?.approvedClose = true
        sender?.performClose(nil)
      }
      return false
    }
  }
}
