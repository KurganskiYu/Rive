import Foundation
import RiveRuntime
import SwiftUI

@MainActor
final class CatalogStore: ObservableObject {
    @Published var interface: Rive?
    @Published var preview: Rive?
    @Published var selected: CatalogEntry?
    @Published var errorMessage: String?
    @Published var previewError: String?
    @Published var isLoading = false
    @Published var diagnostics: [CatalogDiagnostic] = []
    @Published var search = ""
    @Published private(set) var page = 0
    @Published private(set) var names: [String: String] = [:]
    @Published private(set) var checked: Set<String> = []
    @Published private(set) var selectionEventCount = 0

    private(set) var entries: [CatalogEntry] = []
    private(set) var instance: ViewModelInstance?
    private(set) var rows: [(entry: CatalogEntry, instance: ViewModelInstance)] = []
    private var file: RiveRuntime.File?
    private var worker: Worker?
    private var configuration: CatalogConfiguration?
    private var subscriptions: [Task<Void, Never>] = []
    private var pageTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    let pageSize = 16

    var filtered: [CatalogEntry] {
        entries.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search)
            || $0.src.localizedCaseInsensitiveContains(search) }
    }
    var pageCount: Int { max(1, (filtered.count + pageSize - 1) / pageSize) }

    func load(configuration: CatalogConfiguration) async throws {
        pageTask?.cancel()
        previewTask?.cancel()
        cancelSubscriptions()
        interface = nil
        preview = nil
        selected = nil
        errorMessage = nil
        previewError = nil
        rows = []
        names = [:]
        checked = []
        selectionEventCount = 0
        self.configuration = configuration
        let snapshot = try await CatalogBridge.load(configuration)
        entries = snapshot.entries
        diagnostics = snapshot.diagnostics
        let worker = try await Worker()
        let data = try Data(contentsOf: configuration.root
            .appendingPathComponent("CatalogInterface/build/CatalogInterface.riv"))
        let file = try await RiveRuntime.File(source: .data(data), worker: worker)
        let instance = try await file.createViewModelInstance(.blank(from: .name("MainVM")))
        let artboard = try await file.createArtboard("IntegrationHarness")
        let machine = try await artboard.createStateMachine("State Machine 1", binding: instance)
        self.worker = worker
        self.file = file
        self.instance = instance
        interface = try await Rive(file: file, artboard: artboard, stateMachine: machine)
        page = 0
        try await updateRows()
    }

    func start() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await load(configuration: CatalogConfiguration.current())
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func changePage(by offset: Int = 0, reset: Bool = false) {
        pageTask?.cancel()
        page = reset ? 0 : min(max(0, page + offset), pageCount - 1)
        pageTask = Task { [weak self] in
            do {
                try await self?.updateRows()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func updateRows() async throws {
        guard let file, let instance else {
            throw CatalogFailure(message: "The interface is not loaded.")
        }
        let visible = Array(filtered.dropFirst(page * pageSize).prefix(pageSize))
        var nextRows: [(entry: CatalogEntry, instance: ViewModelInstance)] = []
        for entry in visible {
            let row = try await file.createViewModelInstance(.blank(from: .name("ProjectVM")))
            row.setValue(of: StringProperty(path: "name"), to: names[entry.id] ?? entry.displayName)
            row.setValue(of: StringProperty(path: "fileName"), to: entry.src)
            row.setValue(of: StringProperty(path: "artboard"), to: entry.artboard)
            let size = entry.size.split(separator: "x", omittingEmptySubsequences: false)
            row.setValue(of: StringProperty(path: "sizeX"), to: String(size.first ?? ""))
            row.setValue(of: StringProperty(path: "sizeY"), to: size.count == 2 ? String(size[1]) : "?")
            row.setValue(of: StringProperty(path: "numberLabel"), to: entry.number.map(String.init) ?? "")
            row.setValue(of: StringProperty(path: "versionLabel"), to: entry.version.map { "v\($0)" } ?? "unknown")
            row.setValue(of: StringProperty(path: "newerVersionLabel"), to: "")
            row.setValue(of: StringProperty(path: "fileSizeLabel"),
                         to: entry.fileSize.map { String(($0 + 512) / 1024) } ?? "missing")
            row.setValue(of: BoolProperty(path: "selected"), to: entry.id == selected?.id)
            row.setValue(of: BoolProperty(path: "checked"), to: checked.contains(entry.id))
            row.setValue(of: StringProperty(path: "checkedLabel"), to: checked.contains(entry.id) ? "x" : "")
            var badges: [String] = []
            if entry.hasPreview { badges.append("Preview") }
            if entry.parameters.contains(where: { $0.kind == "font" }) { badges.append("Font") }
            if entry.parameters.contains(where: { ["num", "v_num"].contains($0.kind) }) { badges.append("Number") }
            if entry.parameters.contains(where: { ["bol", "v_bol"].contains($0.kind) }) { badges.append("Boolean") }
            if entry.parameters.contains(where: { $0.kind == "txt" }) { badges.append("String") }
            if entry.parameters.contains(where: { $0.kind == "enum" }) { badges.append("Enum") }
            if entry.trigger?.isEmpty == false { badges.append("Trigger") }
            if !entry.notes.isEmpty { badges.append("note") }
            for badge in badges {
                let tag = try await file.createViewModelInstance(.blank(from: .name("TagVM")))
                tag.setValue(of: StringProperty(path: "tag"), to: badge)
                row.appendInstance(tag, to: ListProperty(path: "tagsList"))
            }
            nextRows.append((entry, row))
        }
        try Task.checkCancellation()
        cancelSubscriptions()
        let list = ListProperty(path: "projectsList")
        for row in rows { instance.removeInstance(row.instance, from: list) }
        rows = nextRows
        for row in rows {
            observe(row.instance, entry: row.entry)
            instance.appendInstance(row.instance, to: list)
        }
        interface?.stateMachine.advance(by: 0)
    }

    private func observe(_ row: ViewModelInstance, entry: CatalogEntry) {
        let clicks = row.stream(of: TriggerProperty(path: "openDetails"))
        subscriptions.append(Task { [weak self] in
            do {
                for try await _ in clicks {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    selectionEventCount += 1
                    select(entry)
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = error.localizedDescription
            }
        })
        let changes = row.valueStream(of: BoolProperty(path: "checked"))
        subscriptions.append(Task { [weak self] in
            do {
                for try await value in changes {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    if value { checked.insert(entry.id) } else { checked.remove(entry.id) }
                    row.setValue(of: StringProperty(path: "checkedLabel"), to: value ? "x" : "")
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = error.localizedDescription
            }
        })
    }

    func select(_ entry: CatalogEntry) {
        selected = entry
        for row in rows {
            row.instance.setValue(of: BoolProperty(path: "selected"), to: row.entry.id == entry.id)
        }
        previewTask?.cancel()
        preview = nil
        previewError = nil
        guard entry.fileSize != nil else {
            previewError = "The animation source is missing or invalid. Check the catalog diagnostics."
            return
        }
        previewTask = Task { [weak self] in
            guard let self, let configuration, let worker else { return }
            do {
                let data = try Data(contentsOf: configuration.root
                    .appendingPathComponent("riv").appendingPathComponent(entry.src + ".riv"))
                let file = try await RiveRuntime.File(source: .data(data), worker: worker)
                let artboard = try await file.createArtboard(entry.artboard.isEmpty ? nil : entry.artboard)
                let machine = try await artboard.createStateMachine(entry.stateMachine)
                let rive = try await Rive(file: file, artboard: artboard, stateMachine: machine)
                try Task.checkCancellation()
                preview = rive
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, selected?.id == entry.id else { return }
                previewError = error.localizedDescription
            }
        }
    }

    func applyName(_ name: String, to entry: CatalogEntry) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "A display name cannot be empty."
            return
        }
        names[entry.id] = name
        rows.first(where: { $0.entry.id == entry.id })?.instance
            .setValue(of: StringProperty(path: "name"), to: name)
    }

    private func cancelSubscriptions() {
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
    }

    func stop() {
        pageTask?.cancel()
        previewTask?.cancel()
        cancelSubscriptions()
    }
}
