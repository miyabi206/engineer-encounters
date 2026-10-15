import AuthenticationServices
import Foundation
import UIKit

/// The runner owns browser presentation only; the backend owns PKCE and callback validation.
@MainActor
protocol GitHubWebAuthenticationRunning: AnyObject {
    func authenticate(at address: URL, callbackScheme: String) async throws -> URL
    func cancel()
}

@MainActor
final class SystemGitHubWebAuthenticationRunner: NSObject, GitHubWebAuthenticationRunning,
    ASWebAuthenticationPresentationContextProviding {
    private var attempt: UUID?
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var anchor: UIWindow?

    func authenticate(at address: URL, callbackScheme: String) async throws -> URL {
        guard attempt == nil else { throw GitHubWebAuthenticationError.pending }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow) else {
            throw GitHubWebAuthenticationError.failed
        }
        try Task.checkCancellation()
        let id = UUID()
        attempt = id
        anchor = window
        return try await withTaskCancellationHandler {
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(url: address, callbackURLScheme: callbackScheme) { [weak self] callback, error in
                    // Callback addresses and provider errors never enter diagnostics.
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    Task { @MainActor in
                        if cancelled { self?.finish(.failure(CancellationError()), id: id) }
                        else if let callback { self?.finish(.success(callback), id: id) }
                        else { self?.finish(.failure(GitHubWebAuthenticationError.failed), id: id) }
                    }
                }
                session.prefersEphemeralWebBrowserSession = true
                session.presentationContextProvider = self
                self.session = session
                if !session.start() { finish(.failure(GitHubWebAuthenticationError.failed), id: id) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.attempt == id { self?.cancel() }
            }
        }
    }

    func cancel() {
        session?.cancel()
        if let id = attempt { finish(.failure(CancellationError()), id: id) }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Kept alive for the entire authentication session.
        anchor!
    }

    private func finish(_ result: Result<URL, any Error>, id: UUID) {
        guard attempt == id else { return }
        attempt = nil
        let continuation = continuation
        self.continuation = nil
        session = nil
        anchor = nil
        continuation?.resume(with: result)
    }
}

enum GitHubWebAuthenticationError: Error { case pending, failed }
