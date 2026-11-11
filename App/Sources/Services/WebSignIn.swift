import AuthenticationServices
import UIKit

/// The provider's sign-in page in Apple's secure sign-in sheet (real Safari: Google, Apple and passkeys work,
/// and an existing Safari login is reused). The CLI's own callback can't come back to the app, so the sheet
/// is closed by the user (or by us once the server reports success).
@MainActor
final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    /// Opens `url`; `closed` runs when the sheet goes away (finished, cancelled or closed by `close()`).
    func open(_ url: URL, closed: @escaping @MainActor () -> Void) {
        close()
        let s = ASWebAuthenticationSession(url: url, callback: .customScheme("deckhand")) { _, _ in
            Task { @MainActor in closed() }
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        session = s
        s.start()
    }

    func close() {
        session?.cancel()
        session = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}
