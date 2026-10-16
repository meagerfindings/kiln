import SwiftUI

struct SourcePanel: View {
  @ObservedObject var document: DocumentController
  @Environment(\.colorScheme) private var colorScheme

  private var theme: AppTheme { AppTheme(dark: colorScheme == .dark) }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "curlybraces").foregroundStyle(theme.sage)
        Text("Make it yours").font(.system(size: 14, weight: .semibold, design: .serif))
        Spacer()
        Button {
          Task { await document.closeSource() }
        } label: {
          Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .help("Apply changes and close code")
        .disabled(document.sourceIsBusy || document.isLoading)
      }
      .padding(18)

      Picker(
        "Source language",
        selection: Binding(
          get: { document.sourceLanguage },
          set: { language in Task { await document.showSource(language) } }
        )
      ) {
        Text("CSS").tag(SourceLanguage.css)
        Text("HTML").tag(SourceLanguage.html)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 16)
      .disabled(document.sourceIsBusy || document.isLoading)

      if document.sourceLanguage == .css {
        Picker(
          "Stylesheet",
          selection: Binding(
            get: { document.stylesheetID },
            set: { id in Task { await document.selectStylesheet(id) } }
          )
        ) {
          ForEach(document.stylesheets) { sheet in Text(sheet.label).tag(sheet.id) }
        }
        .labelsHidden()
        .padding(16)
        .disabled(document.sourceIsBusy || document.isLoading)
      } else {
        HStack {
          Text("DOCUMENT SOURCE").font(.system(size: 9, weight: .semibold)).tracking(1)
          Spacer()
          Text("HTML").font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(theme.muted)
        .padding(16)
      }

      Rectangle().fill(theme.separator).frame(height: 1)
      SourceTextEditor(
        text: Binding(get: { document.sourceText }, set: document.editSource),
        language: document.sourceLanguage,
        isEditable: !document.isLoading && !document.sourceIsBusy
          && !document.isEditingLocked && !document.isFileActionBusy
      )
      .id("\(document.sourceLanguage)-\(document.stylesheetID)")
      Rectangle().fill(theme.separator).frame(height: 1)

      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 6) {
          Circle().fill(theme.sage).frame(width: 5, height: 5)
          Text(document.sourceLanguage == .css ? "Live CSS preview" : "Apply to refresh preview")
            .font(.system(size: 11, weight: .medium))
          Spacer()
          if document.sourceLanguage == .html {
            Button("Apply HTML") { Task { _ = await document.applySource() } }
              .disabled(!document.hasSourceDraft || document.isLoading || document.sourceIsBusy)
          }
        }
        Text(
          document.sourceLanguage == .css
            ? "Autosaves with your HTML. Linked CSS files stay untouched. ⌘S saves now."
            : "Autosaves exactly as typed. Apply refreshes page undo history; saving does not. Tags: ⌃Space."
        )
        .font(.system(size: 10))
        .foregroundStyle(theme.muted)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(16)
    }
    .foregroundStyle(theme.ink)
    .background(theme.surface)
    .disabled(document.isFileActionBusy)
  }
}
