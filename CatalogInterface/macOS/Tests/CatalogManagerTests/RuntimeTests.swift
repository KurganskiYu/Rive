import AppKit
import RiveRuntime
import XCTest
@testable import CatalogManager

final class RuntimeTests: XCTestCase {
    private var configuration: CatalogConfiguration {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return CatalogConfiguration(root: root, python: URL(fileURLWithPath: "/usr/bin/python3"))
    }

    @MainActor
    func testCatalogBridgeAndNativeListBindings() async throws {
        let store = CatalogStore()
        defer { store.stop() }
        let snapshot = try await CatalogBridge.load(configuration)
        try await store.load(configuration: configuration)
        XCTAssertEqual(store.entries.count, snapshot.entries.count)
        XCTAssertGreaterThan(store.entries.count, store.pageSize)
        XCTAssertTrue(store.diagnostics.isEmpty)
        let root = try XCTUnwrap(store.instance)
        let size = try await root.size(of: ListProperty(path: "projectsList"))
        XCTAssertEqual(size, store.pageSize)
        let first = try XCTUnwrap(store.rows.first)
        let second = store.rows[1]
        let firstName = try await first.instance.value(of: StringProperty(path: "name"))
        XCTAssertEqual(firstName, first.entry.displayName)
        store.applyName("Native draft test", to: first.entry)
        let draft = try await first.instance.value(of: StringProperty(path: "name"))
        let secondName = try await second.instance.value(of: StringProperty(path: "name"))
        XCTAssertEqual(draft, "Native draft test")
        XCTAssertEqual(secondName, second.entry.displayName)
        root.swapInstance(atIndex: 0, withIndex: 1, in: ListProperty(path: "projectsList"))
        let moved = root.value(of: ListProperty(path: "projectsList"), at: 1)
        let movedName = try await moved.value(of: StringProperty(path: "name"))
        XCTAssertEqual(movedName, "Native draft test")
        root.removeInstance(first.instance, from: ListProperty(path: "projectsList"))
        let reducedSize = try await root.size(of: ListProperty(path: "projectsList"))
        XCTAssertEqual(reducedSize, store.pageSize - 1)
    }

    @MainActor
    func testNativePointerSelectionAndCheckbox() async throws {
        _ = NSApplication.shared
        let store = CatalogStore()
        defer { store.stop() }
        try await store.load(configuration: configuration)
        let rive = try XCTUnwrap(store.interface)
        let view = RiveUIView(rive: rive)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 578, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: 578, height: 480)
        window.contentView = view
        defer { window.close() }
        window.orderFront(nil)
        try await waitUntil { !view.subviews.isEmpty }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        rive.stateMachine.advance(by: 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        try click(view, window: window, x: 120, y: 468)
        rive.stateMachine.advance(by: 0)
        try await waitUntil { store.selected != nil }
        XCTAssertEqual(store.selected?.id, store.rows[0].entry.id)
        try click(view, window: window, x: 120, y: 440)
        rive.stateMachine.advance(by: 0)
        try await waitUntil { store.selected?.id == store.rows[1].entry.id }
        let firstSelected = try await store.rows[0].instance.value(of: BoolProperty(path: "selected"))
        let secondSelected = try await store.rows[1].instance.value(of: BoolProperty(path: "selected"))
        XCTAssertFalse(firstSelected)
        XCTAssertTrue(secondSelected)
        try click(view, window: window, x: 10, y: 468)
        rive.stateMachine.advance(by: 0)
        try await waitUntil { store.checked.contains(store.rows[0].entry.id) }
        XCTAssertEqual(store.selected?.id, store.rows[1].entry.id)
        XCTAssertEqual(store.selectionEventCount, 2)
        try click(view, window: window, x: 120, y: 468)
        rive.stateMachine.advance(by: 0)
        try await waitUntil { store.selectionEventCount >= 3 && store.selected?.id == store.rows[0].entry.id }
        XCTAssertEqual(store.selectionEventCount, 3)
        try await waitUntil { store.preview != nil || store.previewError != nil }
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.previewError)
        XCTAssertNotNil(store.preview)
    }

    @MainActor
    private func click(_ view: RiveUIView, window: NSWindow, x: CGFloat, y: CGFloat) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            ))
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CatalogFailure(message: "Native pointer action was not received within one second.")
    }
}
