import RiveRuntime
import SwiftUI

@main
struct CatalogManagerApp: App {
    @StateObject private var store = CatalogStore()

    var body: some Scene {
        WindowGroup("Rive Catalog") {
            CatalogView(store: store)
                .frame(minWidth: 700, minHeight: 600)
                .task { await store.start() }
                .onDisappear { store.stop() }
        }
        .defaultSize(width: 934, height: 800)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

struct CatalogView: View {
    @ObservedObject var store: CatalogStore

    var body: some View {
        CatalogSurfaceRepresentable(store: store)
    }
}
