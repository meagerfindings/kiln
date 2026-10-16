import SwiftUI

struct CommandPalette: View {
  @ObservedObject var document: DocumentController
  let select: (EditorCommand) -> Void
  @State private var query = ""
  @State private var selectedIndex = 0
  @FocusState private var searchFocused: Bool
  @Environment(\.colorScheme) private var colorScheme

  private var theme: AppTheme { AppTheme(dark: colorScheme == .dark) }
  private var matches: [EditorCommand] {
    EditorCommand.allCases.filter { command in
      guard command.isEnabled(document) else { return false }
      var characters = command.title.lowercased().makeIterator()
      return query.lowercased().filter { !$0.isWhitespace }.allSatisfy { target in
        while let next = characters.next() { if next == target { return true } }
        return false
      }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "command").foregroundStyle(theme.sage)
        TextField("What would you like to do?", text: $query)
          .textFieldStyle(.plain)
          .font(.system(size: 16))
          .focused($searchFocused)
          .onSubmit { runSelected() }
        Text("esc").font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.muted)
      }
      .padding(22)
      Rectangle().fill(theme.separator).frame(height: 1)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 3) {
            if matches.isEmpty {
              Text("No matching commands").foregroundStyle(theme.muted).padding(30)
            }
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
              Button {
                select(command)
              } label: {
                HStack(spacing: 12) {
                  Image(systemName: command.symbol).frame(width: 20).foregroundStyle(theme.sage)
                  Text(command.title)
                  Spacer()
                  Text(command.shortcutLabel).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.muted)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                  RoundedRectangle(cornerRadius: 6).fill(
                    index == selectedIndex ? theme.card : Color.clear)
                )
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .id(index)
            }
          }
          .padding(10)
        }
        .onChange(of: selectedIndex) { _, value in proxy.scrollTo(value) }
      }
      Rectangle().fill(theme.separator).frame(height: 1)
      HStack {
        Text("↑ ↓ to navigate · ↩ to run")
        Spacer()
        Text("\(matches.count) commands")
      }
      .font(.system(size: 10))
      .foregroundStyle(theme.muted)
      .padding(.horizontal, 22)
      .padding(.vertical, 12)
    }
    .frame(width: 520, height: 420)
    .foregroundStyle(theme.ink)
    .background(theme.surface)
    .onAppear { searchFocused = true }
    .onChange(of: query) { _, _ in selectedIndex = 0 }
    .onKeyPress(.downArrow) {
      move(1)
      return .handled
    }
    .onKeyPress(.upArrow) {
      move(-1)
      return .handled
    }
    .onExitCommand { document.showCommandPalette = false }
  }

  private func move(_ direction: Int) {
    guard !matches.isEmpty else { return }
    selectedIndex = (selectedIndex + direction + matches.count) % matches.count
  }

  private func runSelected() {
    guard matches.indices.contains(selectedIndex) else { return }
    select(matches[selectedIndex])
  }
}
