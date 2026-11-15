import SwiftUI

/// `.sheet` for the whole app. On the Mac a sheet otherwise opens at the iPad's small form size, cramped next to a
/// big window; there it opens as a page instead. iPhone and iPad behave exactly as with `.sheet`.
extension View {
    func appSheet<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                 @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) { content().macSheetSize() }
    }

    func appSheet<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                     @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        sheet(item: item, onDismiss: onDismiss) { content($0).macSheetSize() }
    }

    @ViewBuilder func macSheetSize() -> some View {
        #if targetEnvironment(macCatalyst)
        presentationSizing(.page)
        #else
        self
        #endif
    }
}
