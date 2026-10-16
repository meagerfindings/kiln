import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
  case system, light, dark

  var id: String { rawValue }
  var title: String { rawValue.capitalized }
  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

struct AppTheme {
  let dark: Bool
  var ink: Color {
    dark ? Color(red: 0.89, green: 0.91, blue: 0.88) : Color(red: 0.20, green: 0.23, blue: 0.21)
  }
  var muted: Color {
    dark ? Color(red: 0.62, green: 0.66, blue: 0.62) : Color(red: 0.43, green: 0.47, blue: 0.43)
  }
  var sage: Color {
    dark ? Color(red: 0.64, green: 0.77, blue: 0.65) : Color(red: 0.35, green: 0.48, blue: 0.39)
  }
  var surface: Color {
    dark ? Color(red: 0.12, green: 0.14, blue: 0.13) : Color(red: 0.985, green: 0.98, blue: 0.96)
  }
  var sidebar: Color {
    dark ? Color(red: 0.10, green: 0.12, blue: 0.11) : Color(red: 0.95, green: 0.945, blue: 0.92)
  }
  var card: Color { dark ? Color.white.opacity(0.06) : Color.white.opacity(0.75) }
  var separator: Color { dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08) }
}
