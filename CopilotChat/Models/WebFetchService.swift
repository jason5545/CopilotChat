import Foundation

/// Built-in web fetching service that allows the agent to browse web pages.
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

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Mozilla/5.0 (compatible; CopilotChat/1.0)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html, application/json, text/plain;q=0.9, */*;q=0.5",
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

        guard let html = String(data: trimmedData, encoding: .utf8)
                ?? String(data: trimmedData, encoding: .ascii) else {
            throw WebFetchError.decodingFailed
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("application/json") || contentType.contains("text/plain") {
            return truncateResult(html)
        }

        return truncateResult(extractText(from: html))
    }

    // MARK: - HTML to Text

    /// Extract readable text from HTML by stripping tags, scripts, styles, and decoding entities.
    private static func extractText(from html: String) -> String {
        var text = html

        // Remove script and style blocks entirely
        let blockPatterns = [
            "<script[^>]*>[\\s\\S]*?</script>",
            "<style[^>]*>[\\s\\S]*?</style>",
            "<noscript[^>]*>[\\s\\S]*?</noscript>",
            "<!--[\\s\\S]*?-->",
        ]
        for pattern in blockPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                text = regex.stringByReplacingMatches(
                    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
            }
        }

        // Insert newlines before block-level tags for readability
        let blockTags = ["<br", "<p[ >]", "<div[ >]", "<li[ >]", "<h[1-6][ >]", "<tr[ >]", "<blockquote"]
        for tag in blockTags {
            if let regex = try? NSRegularExpression(pattern: tag, options: .caseInsensitive) {
                text = regex.stringByReplacingMatches(
                    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\n")
            }
        }

        // Strip all remaining HTML tags
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            text = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }

        // Decode common HTML entities
        text = decodeHTMLEntities(text)

        // Collapse whitespace
        text = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return text
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        let entities: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'", "&#39;": "'",
            "&nbsp;": " ", "&ndash;": "-", "&mdash;": "--",
            "&laquo;": "\"", "&raquo;": "\"",
            "&copy;": "(c)", "&reg;": "(R)",
            "&hellip;": "...",
        ]
        var result = text
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Decode numeric entities like &#123; and &#x1F4A9;
        if let regex = try? NSRegularExpression(pattern: "&#x?([0-9a-fA-F]+);", options: []) {
            let nsRange = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, range: nsRange).reversed()
            for match in matches {
                guard let fullRange = Range(match.range, in: result),
                      let codeRange = Range(match.range(at: 1), in: result) else { continue }
                let codeStr = String(result[codeRange])
                let isHex = result[fullRange].hasPrefix("&#x")
                if let codePoint = UInt32(codeStr, radix: isHex ? 16 : 10),
                   let scalar = Unicode.Scalar(codePoint) {
                    result.replaceSubrange(fullRange, with: String(scalar))
                }
            }
        }
        return result
    }

    /// Truncate to a reasonable size for LLM context.
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

        var errorDescription: String? {
            switch self {
            case .invalidURL(let url): "Invalid URL: \(url)"
            case .invalidResponse: "Invalid response from server."
            case .httpError(let code): "HTTP error \(code)"
            case .decodingFailed: "Failed to decode response body."
            }
        }
    }
}
