import AppKit
import WebKit

@MainActor
enum NativeSpelling {
  static func configure(_ webView: WKWebView) throws {
    let defaults = UserDefaults.standard
    // Initialize once, then let the native menu persist the user's on/off choice.
    // Do not read or write WebKit's undocumented preference keys.
    if !defaults.bool(forKey: "didConfigureProseSpelling") {
      try set(
        #selector(NSTextView.toggleContinuousSpellChecking(_:)), enabled: true, in: webView,
        requiresAvailability: true)
      defaults.set(true, forKey: "didConfigureProseSpelling")
    }
    // Unlike autocorrect="off", this also prevents macOS text replacement shortcuts.
    try set(
      #selector(NSTextView.toggleAutomaticTextReplacement(_:)), enabled: false, in: webView)
  }

  private static func set(
    _ action: Selector, enabled: Bool, in webView: WKWebView,
    requiresAvailability: Bool = false
  ) throws {
    guard webView.responds(to: action) else { throw ConfigurationError.unavailable }
    let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
    item.target = webView
    let available = webView.validateUserInterfaceItem(item)
    if requiresAvailability && !available { throw ConfigurationError.unavailable }
    // Text Replacement's checkmark reflects its setting even before a caret exists.
    // Its menu availability only reflects whether there is currently editable text.
    if (item.state == .on) != enabled {
      guard NSApp.sendAction(action, to: webView, from: item) else {
        throw ConfigurationError.unavailable
      }
    }
    _ = webView.validateUserInterfaceItem(item)
    guard (item.state == .on) == enabled else { throw ConfigurationError.unavailable }
  }

  private enum ConfigurationError: LocalizedError {
    case unavailable
    var errorDescription: String? {
      "macOS didn't make the requested spelling controls available."
    }
  }
}
