import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import WebKit

/// Built-in web fetching service that allows the agent to browse web pages.
/// Uses WKWebView for HTML pages to support JavaScript-rendered (CSR) content.
@MainActor
enum WebFetchService {

    /// Maximum response body size in bytes (512 KB).
    private static let maxBodyBytes = 512 * 1024

    private static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"

    private static var sharedWebView: WKWebView?

    private static func getSharedWebView() -> WKWebView {
        if let existing = sharedWebView { return existing }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        webView.customUserAgent = mobileUserAgent

        #if canImport(UIKit)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(webView)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.rootViewController = UIViewController()
        window.rootViewController?.view = webView
        window.makeKeyAndVisible()
        offscreenWindowUIKit = window
        #endif

        sharedWebView = webView
        return webView
    }

    #if canImport(UIKit)
    private static var offscreenWindowUIKit: UIWindow?
    #endif

    // MARK: - Public API

    /// Fetch the text content of a web page at the given URL.
    static func fetch(url urlString: String) async throws -> String {
        guard let url = validatedURL(urlString) else {
            throw WebFetchError.invalidURL(urlString)
        }

        if try await shouldUseWebView(for: url) {
            return try await fetchWithWebView(url: url)
        } else {
            return try await fetchWithURLSession(url: url)
        }
    }

    /// Take a screenshot of a web page. Returns a text description and JPEG image data.
    static func screenshot(url urlString: String) async throws -> (description: String, imageData: Data) {
        guard let url = validatedURL(urlString) else {
            throw WebFetchError.invalidURL(urlString)
        }

        let webView = try await loadWebView(url: url)

        // Get page title for description
        let title = (try? await webView.evaluateJavaScript("document.title")) as? String ?? ""

        // Take snapshot
        let snapshotConfig = WKSnapshotConfiguration()
        let image = try await webView.takeSnapshot(configuration: snapshotConfig)

        let jpegData: Data
        #if canImport(UIKit)
        guard let data = image.jpegData(compressionQuality: 0.65) else {
            throw WebFetchError.screenshotFailed
        }
        jpegData = data
        #elseif canImport(AppKit)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.65]) else {
            throw WebFetchError.screenshotFailed
        }
        jpegData = data
        #endif

        let desc = title.isEmpty
            ? "Screenshot captured (\(Int(image.size.width))x\(Int(image.size.height)))"
            : "Screenshot of \"\(title)\" (\(Int(image.size.width))x\(Int(image.size.height)))"

        return (desc, jpegData)
    }

    // MARK: - URL Validation

    private static func validatedURL(_ urlString: String) -> URL? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    // MARK: - Content-Type Check

    private static func shouldUseWebView(for url: URL) async throws -> Bool {
        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"
        headRequest.setValue(mobileUserAgent, forHTTPHeaderField: "User-Agent")
        headRequest.timeoutInterval = 15

        if let (_, headResponse) = try? await URLSession.shared.data(for: headRequest),
           let http = headResponse as? HTTPURLResponse,
           let contentType = http.value(forHTTPHeaderField: "Content-Type") {
            if !contentType.contains("text/html") && !contentType.contains("application/xhtml") {
                return false
            }
        }
        return true
    }

    // MARK: - Shared WKWebView Loader

    /// Create a WKWebView, load the URL, wait for JS to render, and return the ready webView.
    private static func loadWebView(url: URL, viewportSize: CGSize = CGSize(width: 390, height: 844)) async throws -> WKWebView {
        let webView = getSharedWebView()

        let request = URLRequest(url: url, timeoutInterval: 30)

        // Load and wait for navigation to finish
        let success: Bool = try await withCheckedThrowingContinuation { continuation in
            let delegate = WebViewNavigationDelegate(continuation: continuation)
            webView.navigationDelegate = delegate
            objc_setAssociatedObject(webView, "navDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            webView.load(request)
        }

        guard success else {
            throw WebFetchError.invalidResponse
        }

        // Give JS extra time to render (CSR frameworks like React/Next.js need this)
        try await Task.sleep(for: .milliseconds(1500))

        return webView
    }

    // MARK: - WKWebView Text Extraction

    private static func fetchWithWebView(url: URL) async throws -> String {
        let webView = try await loadWebView(url: url)

        let js = """
        (function() {
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
        request.setValue(mobileUserAgent, forHTTPHeaderField: "User-Agent")
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
        case screenshotFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL(let url): "Invalid URL: \(url)"
            case .invalidResponse: "Invalid response from server."
            case .httpError(let code): "HTTP error \(code)"
            case .decodingFailed: "Failed to decode response body."
            case .emptyContent: "Page returned empty content."
            case .screenshotFailed: "Failed to capture screenshot."
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
