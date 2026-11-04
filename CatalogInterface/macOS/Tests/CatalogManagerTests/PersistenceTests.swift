import Foundation
import XCTest
@testable import CatalogManager

final class PersistenceTests: XCTestCase {
    func testBridgeSaveAndConflictPreserveCatalogBytes() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RiveCatalogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("riv"), withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        for name in ["catalog_cli.py", "catalog_core.py", "catalog_persistence.py", "_navigation.py"] {
            try FileManager.default.copyItem(at: repository.appendingPathComponent(name), to: root.appendingPathComponent(name))
        }
        try Data("fixture".utf8).write(to: root.appendingPathComponent("riv/demo_v1.riv"))
        let table = root.appendingPathComponent("_videos.csv")
        let original = Data("src,size,preview,params...\r\ndemo_v1,80XLAYOUT,,future:keep,\r\n".utf8)
        try original.write(to: table)
        try Data("filename,name\r\ndemo,Original\r\nunused,Preserved\r\n".utf8).write(to: root.appendingPathComponent("_videos_names.csv"))
        let configuration = CatalogConfiguration(root: root, python: URL(fileURLWithPath: "/usr/bin/python3"))
        let snapshot = try await CatalogBridge.load(configuration)
        let entry = try XCTUnwrap(snapshot.entries.first)
        XCTAssertEqual(entry.sizeX, "80")
        XCTAssertEqual(entry.sizeY, "layout")
        let saved = try await CatalogBridge.save(configuration, revision: snapshot.revision,
                                                edits: [CatalogEdit(id: entry.id, name: "Новое, имя")])
        XCTAssertEqual(saved.entries.first?.name, "Новое, имя")
        XCTAssertEqual(try Data(contentsOf: table), original)
        try Data("{\"version\":1}\n".utf8).write(to: root.appendingPathComponent("_catalog.json"))
        do {
            _ = try await CatalogBridge.save(configuration, revision: saved.revision,
                                              edits: [CatalogEdit(id: entry.id, name: "Conflict")])
            XCTFail("An external metadata change must block saving.")
        } catch let error as CatalogFailure { XCTAssertEqual(error.code, "conflict") }
        let reloaded = try await CatalogBridge.load(configuration)
        XCTAssertEqual(reloaded.entries.first?.name, "Новое, имя")
    }
}
