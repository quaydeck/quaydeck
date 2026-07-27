import Foundation

/// The result of asking a local port whether it speaks HTTP.
public struct HealthResult: Hashable, Sendable {
    public let respondsHTTP: Bool
    public let title: String?
    public let status: Int?

    public init(respondsHTTP: Bool, title: String?, status: Int?) {
        self.respondsHTTP = respondsHTTP
        self.title = title
        self.status = status
    }

    public static let noResponse = HealthResult(respondsHTTP: false, title: nil, status: nil)
}

public protocol HealthProbing: Sendable {
    func probe(port: Int) async -> HealthResult
}

/// Declines every HTTP redirect, so a probe of localhost can never turn into a
/// request to somewhere else.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RefuseRedirects()

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // nil means "do not follow", and the redirect response itself is returned.
        completionHandler(nil)
    }
}

/// Fetches the page title and status of a local server.
///
/// Uses "localhost" rather than 127.0.0.1 so a server bound only to [::1] still
/// answers, and never follows the response beyond the first 40KB, which is all a
/// `<title>` can reasonably need.
public struct HealthProbe: HealthProbing {
    private let timeout: TimeInterval
    private let userAgent: String

    public init(timeout: TimeInterval = 1.5, userAgent: String = "Quaydeck") {
        self.timeout = timeout
        self.userAgent = userAgent
    }

    public func probe(port: Int) async -> HealthResult {
        guard let url = URL(string: "http://localhost:\(port)/") else { return .noResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 0.5
        configuration.httpCookieStorage = nil
        // Redirects are refused rather than followed. URLSession follows them by
        // default, so a local server answering 302 to an external URL would make
        // Quaydeck fetch it, quietly breaking the promise that nothing leaves the
        // machine. Refusing keeps that promise true rather than merely intended.
        let session = URLSession(configuration: configuration,
                                 delegate: RefuseRedirects.shared,
                                 delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .noResponse }
            let slice = data.prefix(40_000)
            let html = String(data: slice, encoding: .utf8) ?? String(data: slice, encoding: .isoLatin1)
            return HealthResult(respondsHTTP: true,
                                title: html.flatMap(Self.extractTitle),
                                status: http.statusCode)
        } catch {
            return .noResponse
        }
    }

    // MARK: - Title extraction

    static func extractTitle(_ html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let close = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let end = html.range(of: "</title>", options: .caseInsensitive,
                                   range: close.upperBound..<html.endIndex)
        else { return nil }

        var title = String(html[close.upperBound..<end.lowerBound])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while title.contains("  ") {
            title = title.replacingOccurrences(of: "  ", with: " ")
        }
        return title.isEmpty ? nil : decodeEntities(title)
    }

    static func decodeEntities(_ text: String) -> String {
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&mdash;": "-", "&ndash;": "-", "&nbsp;": " ",
        ]
        var result = text
        for (entity, character) in entities {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }
}
