import Foundation

struct DocumentRecoveryStore {
  let directoryURL: URL

  init(directory: URL? = nil) {
    self.directoryURL =
      directory
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
      .appendingPathComponent("Kiln", isDirectory: true)
      .appendingPathComponent("Recovery", isDirectory: true)
  }

  @discardableResult
  func write(original: Data, draft: Data, sourceURL: URL?, sessionID: UUID) throws -> URL {
    let fileManager = FileManager.default
    try createPrivateDirectory(at: directoryURL, with: fileManager)

    let sessionDirectory = directoryURL.appendingPathComponent(
      sessionID.uuidString, isDirectory: true)
    try createPrivateDirectory(at: sessionDirectory, with: fileManager)

    let originalURL = sessionDirectory.appendingPathComponent("original.html")
    if !fileManager.fileExists(atPath: originalURL.path) {
      try writeNewFile(original, to: originalURL)
    } else {
      try setPrivateFilePermissions(at: originalURL, with: fileManager)
    }

    try writeAtomically(draft, to: sessionDirectory.appendingPathComponent("draft.html"))

    let location = sourceURL?.path ?? "Untitled"
    try writeAtomically(
      Data((location + "\n").utf8),
      to: sessionDirectory.appendingPathComponent("location.txt")
    )

    return sessionDirectory
  }

  private func createPrivateDirectory(at url: URL, with fileManager: FileManager) throws {
    try fileManager.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  private func writeNewFile(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .withoutOverwriting)
    try setPrivateFilePermissions(at: url, with: FileManager.default)
  }

  private func writeAtomically(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try setPrivateFilePermissions(at: url, with: FileManager.default)
  }

  private func setPrivateFilePermissions(at url: URL, with fileManager: FileManager) throws {
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
