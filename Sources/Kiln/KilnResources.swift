import Foundation

enum KilnResources {
  static let bundle: Bundle = {
    // Signed apps keep resources inside Contents/Resources; SwiftPM's generated
    // accessor instead looks in the app root or the development build directory.
    if let url = Bundle.main.url(forResource: "Kiln_Kiln", withExtension: "bundle"),
      let bundle = Bundle(url: url)
    {
      return bundle
    }
    return .module
  }()
}
