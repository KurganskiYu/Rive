import AppKit
import RiveRuntime
import SwiftUI

struct CatalogSurfaceRepresentable: NSViewRepresentable {
    @ObservedObject var store: CatalogStore
    func makeNSView(context: Context) -> CatalogSurface { CatalogSurface(store: store) }
    func updateNSView(_ nsView: CatalogSurface, context: Context) { nsView.synchronize() }
}

@MainActor
final class CatalogSurface: NSView, RiveUIViewDelegate {
    let interfaceView = RiveUIView(rive: nil)
    private let store: CatalogStore
    private weak var sizedWindow: NSWindow?

    init(store: CatalogStore) {
        self.store = store
        super.init(frame: .zero)
        interfaceView.delegate = self
        addSubview(interfaceView)
        synchronize()
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); synchronize() }
    func synchronize() {
        interfaceView.rive = store.interface
        if store.interface != nil, let window, sizedWindow !== window {
            sizedWindow = window
            window.setContentSize(store.canvasSize)
        }
        needsLayout = true
    }
    override func layout() { super.layout(); interfaceView.frame = bounds }

    override func scrollWheel(with event: NSEvent) {
        let scale = min(bounds.width / store.canvasSize.width, bounds.height / store.canvasSize.height)
        guard scale > 0 else { return }
        let location = convert(event.locationInWindow, from: nil)
        let origin = CGPoint(x: (bounds.width - store.canvasSize.width * scale) / 2,
                             y: (bounds.height - store.canvasSize.height * scale) / 2)
        let point = CGPoint(x: (location.x - origin.x) / scale,
                            y: (bounds.height - location.y - origin.y) / scale)
        store.scroll(by: event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 20) / scale, at: point)
    }
    func view(_ view: RiveUIView, didReceiveError error: RiveUIViewError) {
        store.report(error)
    }
}
