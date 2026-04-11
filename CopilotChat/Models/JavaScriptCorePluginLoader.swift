import Foundation
import UIKit
import UserNotifications
import JavaScriptCore

struct CExtManifest: Codable {
    let id: String
    let name: String
    let version: String
    let description: String?
    let permissions: Permissions

    struct Permissions: Codable {
        let network: [String]
        let clipboard: Bool
        let notification: Bool
        let openURL: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            network = try container.decodeIfPresent([String].self, forKey: .network) ?? []
            clipboard = try container.decodeIfPresent(Bool.self, forKey: .clipboard) ?? false
            notification = try container.decodeIfPresent(Bool.self, forKey: .notification) ?? false
            openURL = try container.decodeIfPresent(Bool.self, forKey: .openURL) ?? false
        }

        enum CodingKeys: String, CodingKey {
            case network, clipboard, notification, openURL
        }
    }
}

struct CExtToolDefinition {
    let name: String
    let description: String
    let args: [Arg]?

    struct Arg {
        let name: String
        let type: String
        let description: String?
        let required: Bool
    }
}

struct CExtPluginResult {
    let id: String
    let name: String
    let version: String
    let description: String
    let tools: [CExtToolDefinition]
    let manifest: CExtManifest
}

enum CExtLoadError: LocalizedError {
    case bundleNotFound(String)
    case invalidManifest(String)
    case noIndexJS
    case evaluationFailed(String)
    case invalidToolSchema(String)

    var errorDescription: String? {
        switch self {
        case .bundleNotFound(let path): "Plugin bundle not found: \(path)"
        case .invalidManifest(let detail): "Invalid manifest.json: \(detail)"
        case .noIndexJS: "No index.js found in bundle"
        case .evaluationFailed(let msg): "JS evaluation failed: \(msg)"
        case .invalidToolSchema(let name): "Invalid tool schema for: \(name)"
        }
    }
}

private func syncFetch(url: String, optionsJson: String?) -> String {
    guard let requestUrl = URL(string: url) else {
        return "{\"error\":\"Invalid URL\"}"
    }

    var options: [String: Any] = [:]
    if let optionsJson, let data = optionsJson.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        options = parsed
    }

    var request = URLRequest(url: requestUrl)
    request.httpMethod = options["method"] as? String ?? "GET"
    if let headers = options["headers"] as? [String: String] {
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    }
    if let body = options["body"] {
        if let s = body as? String { request.httpBody = s.data(using: .utf8) }
        else if let d = try? JSONSerialization.data(withJSONObject: body) { request.httpBody = d }
    }

    var result: [String: Any] = ["ok": false]
    let sem = DispatchSemaphore(value: 0)
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { sem.signal() }
        guard let data, let http = response as? HTTPURLResponse else {
            result["error"] = error?.localizedDescription ?? "Unknown"
            return
        }
        let hdrs = http.allHeaderFields.reduce(into: [String: String]()) { r, p in
            if let k = p.key as? String, let v = p.value as? String { r[k] = v }
        }
        result["ok"] = (200...299).contains(http.statusCode)
        result["status"] = http.statusCode
        let ct = hdrs["content-type"] ?? ""
        if ct.contains("json") {
            if let j = try? JSONSerialization.jsonObject(with: data) { result["json"] = j }
            if let t = String(data: data, encoding: .utf8) { result["text"] = t }
        } else {
            result["text"] = String(data: data, encoding: .utf8) ?? ""
        }
    }
    task.resume()
    _ = sem.wait(timeout: .now() + 30)

    if let d = try? JSONSerialization.data(withJSONObject: result),
       let s = String(data: d, encoding: .utf8) { return s }
    return "{}"
}

@MainActor
final class JavaScriptCorePluginLoader {
    private var context: JSContext!
    private nonisolated(unsafe) var toolHandlers: [String: @Sendable (String) async throws -> ToolResult] = [:]
    private var pluginId: String = ""
    private var manifest: CExtManifest!
    private var allowedDomains: Set<String> = []

    func load(from bundlePath: String) async throws -> CExtPluginResult {
        let bundleURL = URL(fileURLWithPath: bundlePath)

        guard FileManager.default.fileExists(atPath: bundlePath) else {
            throw CExtLoadError.bundleNotFound(bundlePath)
        }

        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw CExtLoadError.invalidManifest("Cannot read manifest.json")
        }

        guard let loaded = try? JSONDecoder().decode(CExtManifest.self, from: manifestData) else {
            throw CExtLoadError.invalidManifest("Cannot parse JSON")
        }
        manifest = loaded
        pluginId = manifest.id
        allowedDomains = Set(manifest.permissions.network.map { raw in
            if raw == "*" { return "*" }
            return URL(string: raw)?.host ?? raw
        })

        let indexURL = bundleURL.appendingPathComponent("index.js")
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            throw CExtLoadError.noIndexJS
        }
        let jsCode = try String(contentsOf: indexURL, encoding: .utf8)

        context = JSContext()!
        context.exceptionHandler = { _, ex in print("[.cex] \(ex?.toString() ?? "")") }

        let bridge = _Bridge()
        bridge.pluginId = pluginId
        bridge.allowedDomains = allowedDomains
        bridge.hasClipboard = manifest.permissions.clipboard
        bridge.hasNotification = manifest.permissions.notification
        bridge.hasOpenURL = manifest.permissions.openURL
        context.setObject(bridge, forKeyedSubscript: "bridge" as NSString)
        context.evaluateScript("function tool(c){return c;}")

        guard let result = context.evaluateScript(jsCode) else {
            throw CExtLoadError.evaluationFailed("nil result")
        }
        if let ex = context.exception { throw CExtLoadError.evaluationFailed(ex.toString()) }

        guard let dict = result.toDictionary() as? [String: Any] else {
            throw CExtLoadError.evaluationFailed("not an object")
        }

        let tools = try parseTools(dict)
        registerHandlers(tools: tools)

        return CExtPluginResult(id: manifest.id, name: manifest.name, version: manifest.version,
                                description: manifest.description ?? "", tools: tools, manifest: manifest)
    }

    private func parseTools(_ dict: [String: Any]) throws -> [CExtToolDefinition] {
        guard let arr = dict["tools"] as? [[String: Any]] else { return [] }
        return try arr.map { t in
            guard let name = t["name"] as? String, let desc = t["description"] as? String else {
                throw CExtLoadError.invalidToolSchema("missing name/desc")
            }
            var args: [CExtToolDefinition.Arg] = []
            if let list = t["args"] as? [[String: Any]] {
                for a in list {
                    if let n = a["name"] as? String, let ty = a["type"] as? String {
                        args.append(.init(name: n, type: ty, description: a["description"] as? String,
                                          required: a["required"] as? Bool ?? true))
                    }
                }
            }
            return CExtToolDefinition(name: name, description: desc, args: args.isEmpty ? nil : args)
        }
    }

    private func registerHandlers(tools: [CExtToolDefinition]) {
        let pid = pluginId
        let domains = allowedDomains
        let hasClip = manifest.permissions.clipboard
        let hasNotif = manifest.permissions.notification
        let hasOpen = manifest.permissions.openURL

        for tool in tools {
            let fnName = tool.name

            toolHandlers[fnName] = { @Sendable argsJSON in
                await withCheckedContinuation { cont in
                    let ctx = JSContext()!
                    ctx.exceptionHandler = { _, ex in
                        cont.resume(returning: ToolResult(text: "JS: \(ex?.toString() ?? "error")"))
                    }

                    let b = _Bridge()
                    b.pluginId = pid
                    b.allowedDomains = domains
                    b.hasClipboard = hasClip
                    b.hasNotification = hasNotif
                    b.hasOpenURL = hasOpen
                    ctx.setObject(b, forKeyedSubscript: "bridge" as NSString)
                    ctx.evaluateScript("function tool(c){return c;}")

                    let escaped = argsJSON
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "'", with: "\\'")
                        .replacingOccurrences(of: "\n", with: "\\n")
                        .replacingOccurrences(of: "\r", with: "\\r")

                    let js = """
                    (function(){
                        try {
                            var r = typeof \(fnName)==='function' ? \(fnName)(\(escaped)) : null;
                            return r !== null && r !== undefined ? String(r) : 'null';
                        } catch(e) { return 'Error: ' + e.message; }
                    })()
                    """
                    let r = ctx.evaluateScript(js)
                    if let ex = ctx.exception {
                        cont.resume(returning: ToolResult(text: "Error: \(ex.toString())"))
                    } else {
                        cont.resume(returning: ToolResult(text: r?.toString() ?? "null"))
                    }
                }
            }
        }
    }

    nonisolated func handler(for name: String) -> (@Sendable (String) async throws -> ToolResult)? {
        toolHandlers[name]
    }
}

@objc
final class _Bridge: NSObject {
    var pluginId = ""
    var allowedDomains: Set<String> = []
    var hasClipboard = false
    var hasNotification = false
    var hasOpenURL = false

    @objc func fetch(_ url: String, _ options: String?) -> String {
        guard let u = URL(string: url), let host = u.host else { return "{\"error\":\"bad url\"}" }
        if !allowedDomains.contains("*") && !allowedDomains.contains(host) {
            return "{\"error\":\"domain blocked: \(host)\"}"
        }
        return syncFetch(url: url, optionsJson: options)
    }

    @objc func clipboardRead() -> String {
        hasClipboard ? (UIPasteboard.general.string ?? "") : ""
    }

    @objc func clipboardWrite(_ text: String) {
        if hasClipboard { UIPasteboard.general.string = text }
    }

    @objc func notify(_ title: String, _ body: String) {
        guard hasNotification else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        UNUserNotificationCenter.current().add(.init(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    @objc func openURL(_ s: String) {
        guard hasOpenURL, let u = URL(string: s) else { return }
        Task { @MainActor in await UIApplication.shared.open(u) }
    }

    @objc func deviceInfo() -> [String: String] {
        ["platform": "ios", "version": UIDevice.current.systemVersion,
         "model": UIDevice.current.model, "name": UIDevice.current.name, "pluginId": pluginId]
    }
}
