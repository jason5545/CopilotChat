import Foundation
import WebKit

/// Built-in web fetching service that allows the agent to browse web pages.
/// Uses WKWebView for HTML pages to support JavaScript-rendered (CSR) content.
@MainActor
enum WebFetchService {

    /// Maximum response body size in bytes (512 KB).
    private static let maxBodyBytes = 512 * 1024

    /// Fetch the text content of a web page at the given URL.
    static func fetch(url urlString: String) async throws -> String {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw WebFetchError.invalidURL(urlString)
        }

        // First, do a HEAD request to check content type
        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"
        headRequest.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        headRequest.timeoutInterval = 15

        // Try HEAD to determine content type; fall back to WebView for HTML
        var useWebView = true
        if let (_, headResponse) = try? await URLSession.shared.data(for: headRequest),
           let http = headResponse as? HTTPURLResponse,
           let contentType = http.value(forHTTPHeaderField: "Content-Type") {
            // Only use plain URLSession for non-HTML content (JSON, plain text, etc.)
            if !contentType.contains("text/html") && !contentType.contains("application/xhtml") {
                useWebView = false
            }
        }

        if useWebView {
            return try await fetchWithWebView(url: url)
        } else {
            return try await fetchWithURLSession(url: url)
        }
    }

    // MARK: - WKWebView Rendering

    /// Load a page in a headless WKWebView, wait for JS to render, then extract text.
    private static func fetchWithWebView(url: URL) async throws -> String {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1080, height: 1920), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"

        let request = URLRequest(url: url, timeoutInterval: 30)

        // Load and wait for navigation to finish
        let navigationResult: Bool = try await withCheckedThrowingContinuation { continuation in
            let delegate = WebViewNavigationDelegate(continuation: continuation)
            webView.navigationDelegate = delegate
            // Prevent delegate from being deallocated
            objc_setAssociatedObject(webView, "navDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            webView.load(request)
        }

        guard navigationResult else {
            throw WebFetchError.invalidResponse
        }

        // Give JS extra time to render (CSR frameworks like React/Next.js need this)
        try await Task.sleep(for: .seconds(2))

        // Extract rendered text content from DOM
        let js = """
        (function() {
            // Remove script, style, noscript elements
            document.querySelectorAll('script, style, noscript, nav, footer, header').forEach(e => e.remove());
            return document.body ? document.body.innerText : '';
        })();
        """
        let text = try await webView.evaluateJavaScript(js) as? String ?? ""

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebFetchError.emptyContent
        }

        return truncateResult(text)
    }

    // MARK: - URLSession Fallback (non-HTML)

    private static func fetchWithURLSession(url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json, text/plain;q=0.9, */*;q=0.5",
                         forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw WebFetchError.invalidResponse
        }
        guard (200..<400).contains(http.statusCode) else {
            throw WebFetchError.httpError(http.statusCode)
        }

        let trimmedData = data.count > maxBodyBytes
            ? data.prefix(maxBodyBytes)
            : data

        guard let text = String(data: trimmedData, encoding: .utf8)
                ?? String(data: trimmedData, encoding: .ascii) else {
            throw WebFetchError.decodingFailed
        }

        return truncateResult(text)
    }

    // MARK: - Truncation

    private static let maxResultChars = 20_000

    private static func truncateResult(_ text: String) -> String {
        guard text.count > maxResultChars else { return text }
        let idx = text.index(text.startIndex, offsetBy: maxResultChars)
        return String(text[..<idx]) + "\n\n[...content truncated at \(maxResultChars) characters]"
    }

    // MARK: - Errors

    enum WebFetchError: LocalizedError {
        case invalidURL(String)
        case invalidResponse
        case httpError(Int)
        case decodingFailed
        case emptyContent

        var errorDescription: String? {
            switch self {
            case .invalidURL(let url): "Invalid URL: \(url)"
            case .invalidResponse: "Invalid response from server."
            case .httpError(let code): "HTTP error \(code)"
            case .decodingFailed: "Failed to decode response body."
            case .emptyContent: "Page returned empty content."
            }
        }
    }
}

// MARK: - WKWebView Navigation Delegate

private final class WebViewNavigationDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Error>?

    init(continuation: CheckedContinuation<Bool, Error>) {
        self.continuation = continuation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(returning: true)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
