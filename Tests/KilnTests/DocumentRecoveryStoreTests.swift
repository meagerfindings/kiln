import Foundation
import XCTest

@testable import Kiln

final class DocumentRecoveryStoreTests: XCTestCase {
  func testRepeatedWritePreservesOriginalAndReplacesDraftExactly() throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let store = DocumentRecoveryStore(directory: temporaryDirectory)
    let sessionID = UUID()
    let sourceURL = URL(fileURLWithPath: "/tmp/Brief with spaces.html")
    let original = Data("<p>Original</p>".utf8)
    let firstDraft = Data("<p>First</p>".utf8)

    let sessionDirectory = try store.write(
      original: original, draft: firstDraft, sourceURL: sourceURL, sessionID: sessionID)
    XCTAssertEqual(
      try Data(contentsOf: sessionDirectory.appendingPathComponent("original.html")), original)
    XCTAssertEqual(
      try Data(contentsOf: sessionDirectory.appendingPathComponent("draft.html")), firstDraft)
    XCTAssertEqual(
      try String(
        contentsOf: sessionDirectory.appendingPathComponent("location.txt"), encoding: .utf8),
      sourceURL.path + "\n")

    let reopenedStore = DocumentRecoveryStore(directory: temporaryDirectory)
    let nextDraft = Data("<p>Draft 🌱 — café</p>\n".utf8)
    let reopenedSession = try reopenedStore.write(
      original: Data("replacement original".utf8),
      draft: nextDraft,
      sourceURL: sourceURL,
      sessionID: sessionID
    )

    XCTAssertEqual(reopenedSession, sessionDirectory)
    XCTAssertEqual(
      try Data(contentsOf: reopenedSession.appendingPathComponent("original.html")), original)
    XCTAssertEqual(
      try Data(contentsOf: reopenedSession.appendingPathComponent("draft.html")), nextDraft)
  }

  func testSessionsHaveSeparateRecoveryFilesAndUntitledLocation() throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let store = DocumentRecoveryStore(directory: temporaryDirectory)

    let firstSession = try store.write(
      original: Data("first original".utf8),
      draft: Data("first draft".utf8),
      sourceURL: nil,
      sessionID: UUID()
    )
    let secondSession = try store.write(
      original: Data("second original".utf8),
      draft: Data("second draft".utf8),
      sourceURL: nil,
      sessionID: UUID()
    )

    XCTAssertNotEqual(firstSession, secondSession)
    XCTAssertEqual(
      try Data(contentsOf: firstSession.appendingPathComponent("original.html")),
      Data("first original".utf8))
    XCTAssertEqual(
      try Data(contentsOf: secondSession.appendingPathComponent("original.html")),
      Data("second original".utf8))
    XCTAssertEqual(
      try String(
        contentsOf: firstSession.appendingPathComponent("location.txt"), encoding: .utf8),
      "Untitled\n")
    XCTAssertEqual(
      try String(
        contentsOf: secondSession.appendingPathComponent("location.txt"), encoding: .utf8),
      "Untitled\n")
  }

  func testRecoveryFilesAndDirectoriesHavePrivatePermissions() throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let sessionDirectory = try DocumentRecoveryStore(directory: temporaryDirectory).write(
      original: Data("original".utf8),
      draft: Data("draft".utf8),
      sourceURL: nil,
      sessionID: UUID()
    )

    XCTAssertEqual(try permissions(at: temporaryDirectory), 0o700)
    XCTAssertEqual(try permissions(at: sessionDirectory), 0o700)
    for name in ["original.html", "draft.html", "location.txt"] {
      XCTAssertEqual(try permissions(at: sessionDirectory.appendingPathComponent(name)), 0o600)
    }
  }

  func testWritePropagatesFilesystemFailure() throws {
    let temporaryDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let notADirectory = temporaryDirectory.appendingPathComponent("file")
    try Data("not a directory".utf8).write(to: notADirectory)
    let store = DocumentRecoveryStore(directory: notADirectory)

    XCTAssertThrowsError(
      try store.write(
        original: Data("original".utf8),
        draft: Data("draft".utf8),
        sourceURL: nil,
        sessionID: UUID()
      ))
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("KilnRecoveryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }

  private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }
}
