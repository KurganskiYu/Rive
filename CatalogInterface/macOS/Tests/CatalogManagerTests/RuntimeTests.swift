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
    func testAuthoredSceneRowsTagsAndSelectedParameters() async throws {
        let store = CatalogStore()
        defer { store.stop() }
        try await store.load(configuration: configuration)
        XCTAssertEqual(store.rows.count, 118)
        XCTAssertEqual(store.sets.map(\.label), ["All", "Welltory", "Personal", "Crew Mingle"])
        let root = try XCTUnwrap(store.instance)
        let count = try await root.size(of: ListProperty(path: "projectsList"))
        XCTAssertEqual(count, store.entries.count)
        for row in store.rows {
            let tags = try await row.instance.size(of: ListProperty(path: "tagsList"))
            XCTAssertEqual(tags, row.entry.tags.count)
            for index in 0..<tags {
                let tag = row.instance.value(of: ListProperty(path: "tagsList"), at: Int32(index))
                let value = try await tag.value(of: StringProperty(path: "tag"))
                XCTAssertEqual(value, row.entry.tags[index])
                XCTAssertEqual(value.count, 1)
            }
        }
        let entry = try XCTUnwrap(store.entries.first { !$0.parameters.isEmpty })
        store.select(entry)
        try await waitUntil { store.parameters.count == entry.parameters.count + entry.notes.count }
        let details = try XCTUnwrap(store.details)
        let source = try await details.value(of: StringProperty(path: "fileName"))
        XCTAssertEqual(source, entry.src)
        let label = try await details.value(of: StringProperty(path: "artboardLabel"))
        XCTAssertEqual(label, "artboard: \(entry.artboard.isEmpty ? "(runtime default)" : entry.artboard)")
        for (index, parameter) in entry.parameters.enumerated() {
            let model = store.parameters[index]
            let name = try await model.value(of: StringProperty(path: "paramName"))
            let token = try await model.value(of: StringProperty(path: "rawToken"))
            let value = try await model.value(of: StringProperty(path: "configuredDefault"))
            XCTAssertEqual(name, parameter.name)
            XCTAssertEqual(token, parameter.token)
            XCTAssertEqual(value, parameter.defaultValue ?? "")
        }
        let last = try XCTUnwrap(store.entries.last)
        store.select(entry)
        store.select(last)
        try await waitUntil { store.parameters.count == last.parameters.count + last.notes.count }
        let finalSource = try await details.value(of: StringProperty(path: "fileName"))
        XCTAssertEqual(finalSource, last.src)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testOriginalRowGesturesAndIndependentCheckboxes() async throws {
        let (store, surface, window) = try await mounted()
        defer { window.close(); store.stop() }
        let x = store.rect("list").minX
        let y = 800 - store.rect("list").minY - 12
        try click(surface.interfaceView, window: window, x: x + 120, y: y)
        try await waitUntil { store.selected?.id == store.entries[0].id }
        try click(surface.interfaceView, window: window, x: x + 120, y: y - 28)
        try await waitUntil { store.selected?.id == store.entries[1].id }
        try click(surface.interfaceView, window: window, x: x + 10, y: y)
        try await waitUntil { store.checked.contains(store.entries[0].id) }
        XCTAssertEqual(store.selected?.id, store.entries[1].id)
        XCTAssertEqual(store.selectionEventCount, 2)
    }

    @MainActor
    func testExtractedSetTabsAndManualGroupBinding() async throws {
        let (store, surface, window) = try await mounted()
        defer { window.close(); store.stop() }
        let row = try XCTUnwrap(store.allRows.first)
        row.instance.setValue(of: StringProperty(path: "group"), to: "Welltory;Personal")
        try await Task.sleep(nanoseconds: 100_000_000)
        try click(surface.interfaceView, window: window, x: 150, y: 758)
        try await waitUntil { store.selectedSet == "Welltory" && store.rows.count == 1 }
        XCTAssertEqual(store.rows.first?.entry.id, row.entry.id)
        try click(surface.interfaceView, window: window, x: 255, y: 758)
        try await waitUntil { store.selectedSet == "Personal" && store.rows.count == 1 }
        try click(surface.interfaceView, window: window, x: 380, y: 758)
        try await waitUntil { store.selectedSet == "Crew Mingle" && store.rows.isEmpty }
        try click(surface.interfaceView, window: window, x: 74, y: 758)
        try await waitUntil { store.selectedSet == "All" && store.rows.count == 118 }
        XCTAssertEqual(store.allRows.first?.instance, row.instance)
        XCTAssertEqual(store.actionCounts["set:Welltory"], 1)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testPreparedNestedButtonPressAndActionBinding() async throws {
        let (store, surface, window) = try await mounted()
        defer { window.close(); store.stop() }
        let button = try XCTUnwrap(store.buttons["serverButton"])
        try mouse(surface.interfaceView, window: window, type: .leftMouseDown, x: 230, y: 40)
        try await Task.sleep(nanoseconds: 50_000_000)
        let pressed = try await button.value(of: BoolProperty(path: "pressed"))
        XCTAssertTrue(pressed)
        try mouse(surface.interfaceView, window: window, type: .leftMouseUp, x: 230, y: 40)
        try await waitUntil { store.actionCounts["serverButton"] == 1 }
        let released = try await button.value(of: BoolProperty(path: "pressed"))
        XCTAssertFalse(released)
        XCTAssertNotNil(store.errorMessage, "Backend operations must not pretend to be implemented.")
    }

    @MainActor
    func testPreparedTriggerAndMainPreviewButtons() async throws {
        let (store, surface, window) = try await mounted()
        defer { window.close(); store.stop() }
        let entry = try XCTUnwrap(store.entries.first { $0.hasPreview && $0.trigger?.isEmpty == false })
        store.select(entry)
        try await waitUntil { store.parameters.count == entry.parameters.count + entry.notes.count }
        try click(surface.interfaceView, window: window, x: 867, y: 327)
        try await waitUntil { store.previewMode }
        let details = try XCTUnwrap(store.details)
        let artboard = try await details.value(of: StringProperty(path: "artboardLabel"))
        XCTAssertEqual(artboard, "artboard: preview")
        let preview = try XCTUnwrap(store.buttons["previewButton"])
        let buttonLabel = try await preview.value(of: StringProperty(path: "buttonName"))
        XCTAssertEqual(buttonLabel, "Main")
        try click(surface.interfaceView, window: window, x: 867, y: 327)
        try await waitUntil { !store.previewMode }
        try click(surface.interfaceView, window: window, x: 875, y: 355)
        try await waitUntil { store.actionCounts["triggerButton"] == 1 }
        XCTAssertTrue(store.lastActionMessage?.contains(entry.trigger ?? "") == true)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testDeferredPreviewSlotReportsOriginalRootCoordinates() async throws {
        let (store, _, window) = try await mounted()
        defer { window.close(); store.stop() }
        let details = try XCTUnwrap(store.details)
        for (path, expected) in [("screenX", Float(610)), ("screenY", 28),
                                 ("screenWidth", 296), ("screenHeight", 400)] {
            let value = try await details.value(of: NumberProperty(path: path))
            XCTAssertEqual(value, expected, accuracy: 1)
        }
        XCTAssertGreaterThan(store.rect("parameters").height, 0)
        XCTAssertGreaterThan(store.rect("parameters").minY, 480)
    }

    @MainActor
    func testRiveScrollAndLastRowSelection() async throws {
        let (store, surface, window) = try await mounted()
        defer { window.close(); store.stop() }
        let viewport = store.rect("list")
        XCTAssertEqual(viewport.minX, 16, accuracy: 1)
        XCTAssertEqual(viewport.minY, 85, accuracy: 1)
        XCTAssertEqual(viewport.width, 578, accuracy: 1)
        let root = try XCTUnwrap(store.instance)
        let extent = try await root.value(of: NumberProperty(path: "contentHeight"))
        XCTAssertGreaterThan(CGFloat(extent), viewport.height * 4)
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                         wheelCount: 1, wheel1: -100_000, wheel2: 0, wheel3: 0))
        let screen = try XCTUnwrap(NSScreen.main)
        event.location = CGPoint(x: viewport.midX, y: screen.frame.maxY - (800 - viewport.midY))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        surface.interfaceView.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
        try await Task.sleep(nanoseconds: 150_000_000)
        let offset = try await root.value(of: NumberProperty(path: "scrollOffset"))
        XCTAssertEqual(CGFloat(offset), -(CGFloat(extent) - viewport.height), accuracy: 1)
        try click(surface.interfaceView, window: window, x: viewport.minX + 120, y: 800 - viewport.maxY + 40)
        try await waitUntil { store.selected?.id == store.entries.last?.id }
        XCTAssertEqual(store.rows.count, 118)
    }

    @MainActor
    func testStandaloneExecutableOpensWindow() async throws {
        let process = Process()
        process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("CatalogManager")
        process.currentDirectoryURL = configuration.root
        process.arguments = ["--root", configuration.root.path, "--python", configuration.python.path]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "DYLD_FRAMEWORK_PATH")
        environment.removeValue(forKey: "DYLD_LIBRARY_PATH")
        process.environment = environment
        let logs = Pipe()
        process.standardOutput = logs
        process.standardError = logs
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        var visible = false
        for _ in 0..<100 {
            guard process.isRunning else { break }
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            visible = windows.contains { $0[kCGWindowOwnerPID as String] as? Int == Int(process.processIdentifier) && $0[kCGWindowLayer as String] as? Int == 0 }
            if visible { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if !visible {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            XCTFail("No standalone app window: \(String(decoding: logs.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
        }
    }

    @MainActor
    private func mounted() async throws -> (CatalogStore, CatalogSurface, NSWindow) {
        _ = NSApplication.shared
        let store = CatalogStore()
        try await store.load(configuration: configuration)
        let surface = CatalogSurface(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 934, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        window.orderFront(nil)
        try await waitUntil { !surface.interfaceView.subviews.isEmpty && store.rect("list").width > 0 }
        surface.layoutSubtreeIfNeeded()
        store.interface?.stateMachine.advance(by: 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        return (store, surface, window)
    }

    @MainActor
    private func click(_ view: RiveUIView, window: NSWindow, x: CGFloat, y: CGFloat) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] { try mouse(view, window: window, type: type, x: x, y: y) }
    }

    @MainActor
    private func mouse(_ view: RiveUIView, window: NSWindow, type: NSEvent.EventType, x: CGFloat, y: CGFloat) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CatalogFailure(message: "The authored Rive interaction was not received within three seconds.")
    }
}
