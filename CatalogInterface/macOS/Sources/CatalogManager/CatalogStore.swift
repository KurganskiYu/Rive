import Foundation
import RiveRuntime
import SwiftUI

@MainActor
final class CatalogStore: ObservableObject {
    @Published private(set) var interface: Rive?
    @Published private(set) var selected: CatalogEntry?
    @Published private(set) var selectedSet = "All"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var geometry: [String: CGFloat] = [:]
    @Published private(set) var checked: Set<String> = []
    @Published private(set) var selectionEventCount = 0
    @Published private(set) var actionCounts: [String: Int] = [:]
    @Published private(set) var lastActionMessage: String?
    @Published private(set) var previewMode = false
    private(set) var entries: [CatalogEntry] = []
    private(set) var instance: ViewModelInstance?
    private(set) var details: ViewModelInstance?
    private(set) var rows: [(entry: CatalogEntry, instance: ViewModelInstance)] = []
    private(set) var allRows: [(entry: CatalogEntry, instance: ViewModelInstance)] = []
    private(set) var parameters: [ViewModelInstance] = []
    private(set) var sets: [(label: String, instance: ViewModelInstance)] = []
    private(set) var buttons: [String: ViewModelInstance] = [:]
    private var groups: [String: String] = [:]
    private var worker: Worker?
    private var file: RiveRuntime.File?
    private var configuration: CatalogConfiguration?
    private var subscriptions: [Task<Void, Never>] = []
    private var selectionTask: Task<Void, Never>?
    private var scrollTask: Task<Void, Never>?
    private var wheelDeltas: [String: CGFloat] = [:]
    let canvasSize = CGSize(width: 934, height: 800)

    func load(configuration: CatalogConfiguration) async throws {
        stop()
        self.configuration = configuration
        let worker = try await Worker()
        let data = try Data(contentsOf: configuration.root
            .appendingPathComponent("CatalogInterface/build/CatalogInterface.riv"))
        let file = try await RiveRuntime.File(source: .data(data), worker: worker)
        let root = try await file.createViewModelInstance(.viewModelDefault(from: .name("MainVM")))
        let artboard = try await file.createArtboard("CatalogInterface")
        let machine = try await artboard.createStateMachine("State Machine 1", binding: root)
        self.worker = worker
        self.file = file
        instance = root
        details = root.value(of: ViewModelInstanceProperty(path: "details"))
        interface = try await Rive(file: file, artboard: artboard, stateMachine: machine)
        selected = nil
        previewMode = false
        selectedSet = "All"
        checked = []
        groups = [:]
        rows = []
        allRows = []
        parameters = []
        sets = []
        buttons = [:]
        actionCounts = [:]
        selectionEventCount = 0
        errorMessage = nil
        lastActionMessage = nil
        try await clearList("projectsList", in: root)
        let tabCount = try await root.size(of: ListProperty(path: "setButtons"))
        for index in 0..<tabCount {
            let tab = root.value(of: ListProperty(path: "setButtons"), at: Int32(index))
            let label = try await tab.value(of: StringProperty(path: "label"))
            sets.append((label, tab))
            observe(tab, action: "set:\(label)")
        }
        for path in ["pushAllButton", "serverButton", "generateAllButton", "syncButton"] {
            let button = root.value(of: ViewModelInstanceProperty(path: path))
            buttons[path] = button
            button.setValue(of: NumberProperty(path: "buttonDimming"), to: 1)
            observe(button, action: path)
        }
        if let details {
            for path in ["triggerButton", "previewButton", "updateButton", "pushButton", "linkButton"] {
                let button = details.value(of: ViewModelInstanceProperty(path: path))
                buttons[path] = button
                button.setValue(of: NumberProperty(path: path == "triggerButton" || path == "previewButton" ? "dimming" : "buttonDimming"), to: 1)
                observe(button, action: path)
            }
            let modes = details.valueStream(of: BoolProperty(path: "previewMode"))
            subscriptions.append(Task { [weak self] in
                do {
                    for try await mode in modes {
                        guard !Task.isCancelled, let self else { return }
                        guard let selected, selected.hasPreview else {
                            if mode { details.setValue(of: BoolProperty(path: "previewMode"), to: false) }
                            continue
                        }
                        previewMode = mode
                        updateSourceLabels(entry: selected, preview: mode)
                        buttons["previewButton"]?.setValue(of: StringProperty(path: "buttonName"), to: mode ? "Main" : "Preview")
                    }
                } catch { if !Task.isCancelled { self?.report(error) } }
            })
        }
        for suffix in ["X", "Y", "Width", "Height"] {
            let path = "list" + suffix
            let values = root.valueStream(of: NumberProperty(path: path))
            subscriptions.append(Task { [weak self] in
                do {
                    for try await value in values {
                        guard !Task.isCancelled else { return }
                        self?.geometry[path] = CGFloat(value)
                    }
                } catch { if !Task.isCancelled { self?.report(error) } }
            })
            if let details {
                let viewport = details.valueStream(of: NumberProperty(path: "viewport" + suffix))
                subscriptions.append(Task { [weak self] in
                    do {
                        for try await value in viewport {
                            guard !Task.isCancelled else { return }
                            self?.geometry["parameters" + suffix] = CGFloat(value)
                        }
                    } catch { if !Task.isCancelled { self?.report(error) } }
                })
            }
        }
        machine.advance(by: 0)
        let snapshot = try await CatalogBridge.load(configuration)
        entries = snapshot.entries
        for entry in entries {
            let row = try await file.createViewModelInstance(.blank(from: .name("ProjectVM")))
            let labels: [(String, String)] = [
                ("name", entry.displayName), ("fileName", entry.src), ("artboard", entry.artboard),
                ("sizeX", entry.sizeX), ("sizeY", entry.sizeY),
                ("numberLabel", entry.number.map { String($0) } ?? ""),
                ("versionLabel", entry.version.map { "v\($0)" } ?? "unknown"),
                ("newerVersionLabel", ""),
                ("fileSizeLabel", entry.fileSize.map { String(($0 + 512) / 1024) } ?? "missing"),
                ("group", ""),
            ]
            for (path, value) in labels { row.setValue(of: StringProperty(path: path), to: value) }
            for badge in entry.tags {
                let tag = try await file.createViewModelInstance(.blank(from: .name("TagVM")))
                tag.setValue(of: StringProperty(path: "tag"), to: badge)
                row.appendInstance(tag, to: ListProperty(path: "tagsList"))
            }
            allRows.append((entry, row))
            observe(row, action: "row:\(entry.id)", trigger: "openDetails")
            observeCheckbox(row, entry: entry)
            observeGroup(row, entry: entry)
        }
        mountRows()
        if !snapshot.diagnostics.isEmpty {
            report(CatalogFailure(message: snapshot.diagnostics.map {
                "Row \($0.line), \($0.field): \($0.message)"
            }.joined(separator: "\n")))
        }
    }

    func start() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do { try await load(configuration: CatalogConfiguration.current()) }
        catch { if !Task.isCancelled { report(error) } }
    }

    private func clearList(_ path: String, in owner: ViewModelInstance) async throws {
        let list = ListProperty(path: path)
        let count = try await owner.size(of: list)
        for _ in 0..<count {
            owner.removeInstance(owner.value(of: list, at: 0), from: list)
        }
    }

    private func observe(_ model: ViewModelInstance, action: String, trigger: String = "activate") {
        let events = model.stream(of: TriggerProperty(path: trigger))
        subscriptions.append(Task { [weak self] in
            do {
                for try await _ in events {
                    guard !Task.isCancelled else { return }
                    self?.handle(action)
                }
            } catch { if !Task.isCancelled { self?.report(error) } }
        })
    }

    private func observeCheckbox(_ row: ViewModelInstance, entry: CatalogEntry) {
        let values = row.valueStream(of: BoolProperty(path: "checked"))
        subscriptions.append(Task { [weak self] in
            do {
                for try await value in values {
                    guard !Task.isCancelled, let self else { return }
                    if value { checked.insert(entry.id) } else { checked.remove(entry.id) }
                    row.setValue(of: StringProperty(path: "checkedLabel"), to: value ? "x" : "")
                }
            } catch { if !Task.isCancelled { self?.report(error) } }
        })
    }

    private func observeGroup(_ row: ViewModelInstance, entry: CatalogEntry) {
        let values = row.valueStream(of: StringProperty(path: "group"))
        subscriptions.append(Task { [weak self] in
            do {
                for try await value in values {
                    guard !Task.isCancelled, let self else { return }
                    guard value != groups[entry.id, default: ""] else { continue }
                    groups[entry.id] = value
                    mountRows()
                }
            } catch { if !Task.isCancelled { self?.report(error) } }
        })
    }

    private func handle(_ action: String) {
        actionCounts[action, default: 0] += 1
        if action.hasPrefix("set:") {
            selectedSet = String(action.dropFirst(4))
            mountRows()
        } else if action.hasPrefix("row:") {
            let id = String(action.dropFirst(4))
            guard let entry = entries.first(where: { $0.id == id }) else {
                report(CatalogFailure(message: "The selected animation is no longer in the catalog."))
                return
            }
            selectionEventCount += 1
            select(entry)
        } else if action == "previewButton" {
            return
        } else if action == "triggerButton" {
            guard let trigger = selected?.trigger, !trigger.isEmpty else { return }
            lastActionMessage = "Trigger requested: \(trigger). Animation playback is deferred."
            NSLog("Catalog: %@", lastActionMessage ?? "")
        } else {
            report(CatalogFailure(message: "\(action): backend operation is not enabled in the scene-wiring iteration."))
        }
    }

    private func mountRows() {
        guard let instance else { return }
        let list = ListProperty(path: "projectsList")
        for row in rows { instance.removeInstance(row.instance, from: list) }
        rows = allRows.filter {
            selectedSet == "All" || groups[$0.entry.id, default: ""].split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }.contains(selectedSet)
        }
        for row in rows { instance.appendInstance(row.instance, to: list) }
        for tab in sets { tab.instance.setValue(of: BoolProperty(path: "selected"), to: tab.label == selectedSet) }
        instance.setValue(of: NumberProperty(path: "scrollOffset"), to: 0)
        if let selected, !rows.contains(where: { $0.entry.id == selected.id }) { clearSelection() }
        interface?.stateMachine.advance(by: 0)
    }

    func select(_ entry: CatalogEntry) {
        selectionTask?.cancel()
        selected = entry
        previewMode = false
        errorMessage = nil
        for row in allRows { row.instance.setValue(of: BoolProperty(path: "selected"), to: row.entry.id == entry.id) }
        details?.setValue(of: BoolProperty(path: "previewMode"), to: false)
        details?.setValue(of: NumberProperty(path: "scrollOffset"), to: 0)
        buttons["previewButton"]?.setValue(of: StringProperty(path: "buttonName"), to: "Preview")
        buttons["triggerButton"]?.setValue(of: NumberProperty(path: "dimming"), to: entry.trigger?.isEmpty == false ? 0 : 1)
        buttons["previewButton"]?.setValue(of: NumberProperty(path: "dimming"), to: entry.hasPreview ? 0 : 1)
        updateSourceLabels(entry: entry, preview: false)
        selectionTask = Task { [weak self] in
            guard let self, let file, let details else { return }
            do {
                var next: [ViewModelInstance] = []
                let types = ["num": "Number", "v_num": "Number", "bol": "Boolean", "v_bol": "Boolean",
                             "txt": "String", "enum": "Enum", "font": "Font"]
                for parameter in entry.parameters {
                    let model = try await file.createViewModelInstance(.blank(from: .name("ParameterVM")))
                    model.setValue(of: StringProperty(path: "paramName"), to: parameter.name)
                    model.setValue(of: EnumProperty(path: "paramType"), to: types[parameter.kind] ?? "File")
                    model.setValue(of: StringProperty(path: "configuredDefault"), to: parameter.defaultValue ?? "")
                    model.setValue(of: StringProperty(path: "rawToken"), to: parameter.token)
                    model.setValue(of: StringProperty(path: "kind"), to: parameter.kind)
                    next.append(model)
                }
                for note in entry.notes {
                    let model = try await file.createViewModelInstance(.blank(from: .name("ParameterVM")))
                    model.setValue(of: StringProperty(path: "paramName"), to: "note")
                    model.setValue(of: EnumProperty(path: "paramType"), to: "note")
                    model.setValue(of: StringProperty(path: "noteProp"), to: note)
                    model.setValue(of: StringProperty(path: "configuredDefault"), to: note)
                    model.setValue(of: StringProperty(path: "kind"), to: "note")
                    next.append(model)
                }
                try Task.checkCancellation()
                for model in parameters { details.removeInstance(model, from: ListProperty(path: "parameters")) }
                parameters = next
                for model in next { details.appendInstance(model, to: ListProperty(path: "parameters")) }
                interface?.stateMachine.advance(by: 0)
            } catch { if !Task.isCancelled { report(error) } }
        }
    }

    private func clearSelection() {
        selectionTask?.cancel()
        selected = nil
        previewMode = false
        for row in allRows { row.instance.setValue(of: BoolProperty(path: "selected"), to: false) }
        if let details {
            for model in parameters { details.removeInstance(model, from: ListProperty(path: "parameters")) }
            details.setValue(of: StringProperty(path: "fileName"), to: rows.isEmpty ? "No animations in this group" : "Select an animation")
            details.setValue(of: StringProperty(path: "artboardLabel"), to: "artboard: -")
        }
        parameters = []
        for key in ["triggerButton", "previewButton"] { buttons[key]?.setValue(of: NumberProperty(path: "dimming"), to: 1) }
    }

    private func updateSourceLabels(entry: CatalogEntry, preview: Bool) {
        let sibling = configuration?.root.appendingPathComponent("riv/\(entry.src)_preview.riv")
        let source = preview && sibling.map({ FileManager.default.fileExists(atPath: $0.path) }) == true ? entry.src + "_preview" : entry.src
        details?.setValue(of: StringProperty(path: "fileName"), to: source)
        details?.setValue(of: StringProperty(path: "artboardLabel"), to:
            "artboard: \(preview ? "preview" : entry.artboard.isEmpty ? "(runtime default)" : entry.artboard)")
    }

    func rect(_ prefix: String) -> CGRect {
        CGRect(x: geometry[prefix + "X"] ?? 0, y: geometry[prefix + "Y"] ?? 0,
               width: geometry[prefix + "Width"] ?? 0, height: geometry[prefix + "Height"] ?? 0)
    }

    func scroll(by delta: CGFloat, at point: CGPoint) {
        guard let root = instance else { return }
        let isList = rect("list").contains(point)
        let owner: ViewModelInstance
        let key: String
        if isList { owner = root; key = "list" }
        else if let details, rect("parameters").contains(point) { owner = details; key = "parameters" }
        else { return }
        wheelDeltas[key, default: 0] += delta
        guard scrollTask == nil else { return }
        scrollTask = Task { [weak self] in
            guard let self else { return }
            defer { scrollTask = nil }
            do {
                while !wheelDeltas.isEmpty {
                    let deltas = wheelDeltas
                    wheelDeltas = [:]
                    for (target, amount) in deltas {
                        let model = target == "list" ? root : self.details ?? owner
                        let content = try await model.value(of: NumberProperty(path: "contentHeight"))
                        let viewport = target == "list" ? Float(rect("list").height) :
                            try await model.value(of: NumberProperty(path: "viewportHeight"))
                        let current = try await model.value(of: NumberProperty(path: "scrollOffset"))
                        try Task.checkCancellation()
                        model.setValue(of: NumberProperty(path: "scrollOffset"), to:
                            min(0, max(-max(0, content - viewport), current + Float(amount))))
                        interface?.stateMachine.advance(by: 0)
                    }
                }
            } catch { if !Task.isCancelled { report(error) } }
        }
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
        NSLog("Catalog: %@", error.localizedDescription)
        details?.setValue(of: StringProperty(path: "fileName"), to: "Catalog operation unavailable")
        details?.setValue(of: StringProperty(path: "artboardLabel"), to: error.localizedDescription)
    }

    func stop() {
        selectionTask?.cancel()
        scrollTask?.cancel()
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
    }
}
