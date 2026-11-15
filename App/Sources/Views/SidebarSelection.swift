import SwiftUI

/// Which sidebar entry the detail column shows (Mac, iPad). The links open by destination, which SwiftUI doesn't
/// highlight, so each destination reports itself when it appears and the matching row marks itself.
@MainActor @Observable
final class SidebarSelection {
    static let shared = SidebarSelection()
    var current: String?
}

extension View {
    /// A sidebar row: highlighted while the detail column shows `id`.
    func sidebarRow(_ id: String) -> some View { modifier(SidebarRowModifier(id: id)) }

    /// A detail page opened from the sidebar: marks `id` as the current entry when it appears.
    func sidebarPage(_ id: String?) -> some View {
        onAppear { SidebarSelection.shared.current = id }
    }
}

private struct SidebarRowModifier: ViewModifier {
    let id: String
    @Environment(\.inSidebar) private var inSidebar

    func body(content: Content) -> some View {
        let marked = inSidebar && SidebarSelection.shared.current == id
        content
            .listRowBackground(marked ? RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.14)) : nil)
            .accessibilityAddTraits(marked ? .isSelected : [])
    }
}
