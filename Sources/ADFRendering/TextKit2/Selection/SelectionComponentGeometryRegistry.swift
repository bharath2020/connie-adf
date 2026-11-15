import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// The visual outline a semantic ADF component presents when its complete
/// selectable text is covered by the current range.
enum SelectionComponentShape: Sendable, Hashable {
    case roundedRectangle(cornerRadius: CGFloat)
}

/// Live component surfaces, keyed by semantic ADF node ID.
///
/// Like `RowGeometryRegistry`, this is deliberately a plain, non-observed
/// class. SwiftUI containers register lightweight anchor views as they
/// materialize; the active UIKit selection session queries them on demand.
/// Range drags therefore never invalidate a panel, code block, table cell, or
/// lazy document row.
@MainActor
final class SelectionComponentGeometryRegistry {
    var onGeometryChange: (() -> Void)?

    private struct Entry {
        let componentID: String
        let shape: SelectionComponentShape
        weak var view: ADFPlatformView?
    }

    private var entries: [Entry] = []

    func register(
        componentID: String,
        shape: SelectionComponentShape,
        view: ADFPlatformView
    ) {
        evictDead()
        entries.removeAll { $0.view === view }
        entries.append(Entry(componentID: componentID, shape: shape, view: view))
        onGeometryChange?()
    }

    func unregister(view: ADFPlatformView) {
        entries.removeAll { $0.view == nil || $0.view === view }
        onGeometryChange?()
    }

    func geometryDidChange(for view: ADFPlatformView) {
        guard entries.contains(where: { $0.view === view }) else { return }
        onGeometryChange?()
    }

    func liveEntries(
        for componentIDs: Set<String>
    ) -> [(componentID: String, shape: SelectionComponentShape, view: ADFPlatformView)] {
        evictDead()
        return entries.compactMap { entry in
            guard componentIDs.contains(entry.componentID), let view = entry.view else {
                return nil
            }
            return (entry.componentID, entry.shape, view)
        }
    }

    private func evictDead() {
        entries.removeAll { $0.view == nil }
    }
}

private struct SelectionComponentGeometryRegistryKey: EnvironmentKey {
    static let defaultValue: SelectionComponentGeometryRegistry? = nil
}

extension EnvironmentValues {
    var adfSelectionComponentGeometryRegistry: SelectionComponentGeometryRegistry? {
        get { self[SelectionComponentGeometryRegistryKey.self] }
        set { self[SelectionComponentGeometryRegistryKey.self] = newValue }
    }
}

extension View {
    /// Registers this view's actual rendered bounds as a semantic selection
    /// component. The registration is inert when document selection is off.
    func adfSelectionComponent(
        id: String?,
        cornerRadius: CGFloat
    ) -> some View {
        modifier(SelectionComponentGeometryModifier(
            componentID: id,
            shape: .roundedRectangle(cornerRadius: cornerRadius)
        ))
    }
}

private struct SelectionComponentGeometryModifier: ViewModifier {
    let componentID: String?
    let shape: SelectionComponentShape

    @Environment(\.adfSelectionComponentGeometryRegistry) private var registry

    func body(content: Content) -> some View {
        content.background {
            #if os(iOS)
            if let componentID, let registry {
                SelectionComponentGeometryAnchor(
                    componentID: componentID,
                    shape: shape,
                    registry: registry
                )
                .allowsHitTesting(false)
            }
            #endif
        }
    }
}

#if os(iOS)
private struct SelectionComponentGeometryAnchor: UIViewRepresentable {
    let componentID: String
    let shape: SelectionComponentShape
    let registry: SelectionComponentGeometryRegistry

    func makeUIView(context: Context) -> SelectionComponentAnchorView {
        let view = SelectionComponentAnchorView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.update(componentID: componentID, shape: shape, registry: registry)
        return view
    }

    func updateUIView(_ view: SelectionComponentAnchorView, context: Context) {
        view.update(componentID: componentID, shape: shape, registry: registry)
    }

    static func dismantleUIView(
        _ view: SelectionComponentAnchorView,
        coordinator: ()
    ) {
        view.unregister()
    }
}

private final class SelectionComponentAnchorView: UIView {
    private weak var registry: SelectionComponentGeometryRegistry?
    private var componentID = ""
    private var shape = SelectionComponentShape.roundedRectangle(cornerRadius: 0)
    private var registered = false
    private var lastSize = CGSize.zero

    func update(
        componentID: String,
        shape: SelectionComponentShape,
        registry: SelectionComponentGeometryRegistry
    ) {
        let registrationChanged = self.registry !== registry
            || self.componentID != componentID
            || self.shape != shape
        if registrationChanged, registered {
            self.registry?.unregister(view: self)
            registered = false
        }
        self.registry = registry
        self.componentID = componentID
        self.shape = shape
        registerIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            unregister()
        } else {
            registerIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        registry?.geometryDidChange(for: self)
    }

    func unregister() {
        guard registered else { return }
        registry?.unregister(view: self)
        registered = false
    }

    private func registerIfNeeded() {
        guard window != nil, !registered, let registry, !componentID.isEmpty else {
            return
        }
        registry.register(componentID: componentID, shape: shape, view: self)
        registered = true
    }
}
#endif
