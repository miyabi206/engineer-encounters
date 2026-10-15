import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP bytes and status; diagnostics never expose response material.
public struct HTTPResponse: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) { self.data = data; self.statusCode = statusCode }
    public var description: String { "HTTPResponse(statusCode: \(statusCode), <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Injected HTTP seam for Auth and remote procedures.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
    /// Credential-bearing requests must return redirects without following them.
    func sendWithoutRedirects(_ request: URLRequest) async throws -> HTTPResponse
}

extension HTTPTransport {
    /// Reject redirects before interpreting any untrusted application error or credential body.
    func sendCredentialRequest(_ request: URLRequest) async throws -> HTTPResponse {
        let response = try await sendWithoutRedirects(request)
        guard !(300..<400).contains(response.statusCode) else { throw BackendError.transportFailure }
        return response
    }
}

/// Foundation transport with no provider SDK dependency.
public struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func sendWithoutRedirects(_ request: URLRequest) async throws -> HTTPResponse {
        try await send(request, delegate: RefuseRedirects())
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await sendCredentialRequest(request)
    }

    private func send(_ request: URLRequest, delegate: (any URLSessionTaskDelegate)?) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request, delegate: delegate)
            guard let response = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
            return HTTPResponse(data: data, statusCode: response.statusCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BackendError {
            throw error
        } catch {
            throw BackendError.transportFailure
        }
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
