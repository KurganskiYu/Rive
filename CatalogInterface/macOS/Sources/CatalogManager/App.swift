import RiveRuntime
import SwiftUI

@main
struct CatalogManagerApp: App {
    @StateObject private var store = CatalogStore()

    var body: some Scene {
        WindowGroup("Rive Catalog - integration prototype") {
            CatalogView(store: store)
                .frame(minWidth: 980, minHeight: 620)
                .task { await store.start() }
                .onDisappear { store.stop() }
        }
        .defaultSize(width: 1100, height: 700)
    }
}

struct CatalogView: View {
    @ObservedObject var store: CatalogStore
    @State private var editing = false
    @State private var draftName = ""
    @State private var editingEntry: CatalogEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read-only integration prototype: names are temporary drafts; CSV, import, generation, publish and sync are not enabled.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Search animations", text: $store.search)
                    .onChange(of: store.search) { _ in store.changePage(reset: true) }
                Button("Previous") { store.changePage(by: -1) }.disabled(store.page == 0)
                Text("\(store.page + 1) / \(store.pageCount)")
                Button("Next") { store.changePage(by: 1) }.disabled(store.page + 1 >= store.pageCount)
                Button("Reload") { Task { await store.start() } }
            }
            .disabled(store.isLoading || store.interface == nil)
            if let error = store.errorMessage {
                HStack {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Button("Retry") { Task { await store.start() } }
                }
            }
            HSplitView {
                ZStack {
                    Color(red: 0.22, green: 0.24, blue: 0.29)
                    if let interface = store.interface {
                        RiveUIViewRepresentable(rive: interface)
                            .aspectRatio(578.0 / 480.0, contentMode: .fit)
                    } else if store.isLoading {
                        ProgressView("Loading catalog and Rive runtime")
                    }
                }
                .frame(minWidth: 578)
                VStack(alignment: .leading, spacing: 10) {
                    if let entry = store.selected {
                        HStack {
                            Text(store.names[entry.id] ?? entry.displayName).font(.headline)
                            Button("Edit name") {
                                editingEntry = entry
                                draftName = store.names[entry.id] ?? entry.displayName
                                editing = true
                            }
                            .popover(isPresented: $editing) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Display-name draft").font(.headline)
                                    TextField("Name", text: $draftName)
                                        .frame(width: 280)
                                    Text("Not saved to CSV. Reload discards drafts.")
                                        .font(.caption).foregroundStyle(.secondary)
                                    HStack {
                                        Button("Cancel") { editing = false }
                                        Button("Apply draft") {
                                            if let editingEntry {
                                                store.applyName(draftName, to: editingEntry)
                                            }
                                            editing = false
                                        }.disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    }
                                }.padding()
                            }
                        }
                        Text(entry.src).font(.caption).textSelection(.enabled)
                        Text("Artboard: \(entry.artboard.isEmpty ? "(runtime default)" : entry.artboard)")
                        Text("State machine: \(entry.stateMachine)")
                        Text("Preview uses authored values; CSV defaults are not applied yet.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let preview = store.preview {
                            RiveUIViewRepresentable(rive: preview)
                                .frame(minHeight: 180, maxHeight: 300)
                        } else if let error = store.previewError {
                            Text("Preview failed: \(error)").foregroundStyle(.red)
                                .textSelection(.enabled)
                        } else {
                            ProgressView("Loading animation")
                        }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Configured parameters (read-only)").font(.subheadline)
                                ForEach(Array(entry.parameters.enumerated()), id: \.offset) { _, parameter in
                                    Text(parameter.token).font(.caption).textSelection(.enabled)
                                }
                                ForEach(Array(entry.notes.enumerated()), id: \.offset) { _, note in
                                    Text("Note: \(note)").font(.caption).textSelection(.enabled)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text("Click a Rive row to select an animation. Its checkbox is independent.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding().frame(minWidth: 300)
            }
            .onChange(of: store.selected?.id) { _ in editing = false }
            Text("\(store.entries.count) animations; \(store.checked.count) checked; \(store.names.count) temporary name drafts")
                .font(.caption).foregroundStyle(.secondary)
            if !store.diagnostics.isEmpty {
                DisclosureGroup("\(store.diagnostics.count) catalog diagnostics") {
                    ScrollView {
                        ForEach(Array(store.diagnostics.enumerated()), id: \.offset) { _, issue in
                            Text("\(issue.severity): row \(issue.line), \(issue.field): \(issue.message)")
                                .font(.caption).textSelection(.enabled)
                        }
                    }.frame(maxHeight: 100)
                }
            }
        }.padding()
    }
}
