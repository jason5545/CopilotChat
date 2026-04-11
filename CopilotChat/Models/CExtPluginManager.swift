import Foundation
import UIKit

@MainActor
final class CExtPluginManager: ObservableObject {
    static let shared = CExtPluginManager()

    @Published private(set) var loadedPlugins: [LoadedCExtPlugin] = []
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    struct LoadedCExtPlugin: Identifiable {
        let id: String
        let name: String
        let version: String
        let description: String
        let bundlePath: String
        var isEnabled: Bool
        let tools: [String]
    }

    private var pluginLoaders: [String: JavaScriptCorePluginLoader] = [:]
    private var pluginInstances: [String: CExtPlugin] = [:]

    private init() {}

    func loadPlugin(from path: String, id: String? = nil) async {
        isLoading = true
        lastError = nil

        do {
            let loader = JavaScriptCorePluginLoader()
            let result = try await loader.load(from: path)

            let pluginId = id ?? result.id

            let loaded = LoadedCExtPlugin(
                id: pluginId,
                name: result.name,
                version: result.version,
                description: result.description,
                bundlePath: path,
                isEnabled: true,
                tools: result.tools.map(\.name)
            )

            if let existingIndex = loadedPlugins.firstIndex(where: { $0.id == pluginId }) {
                loadedPlugins[existingIndex] = loaded
            } else {
                loadedPlugins.append(loaded)
            }

            pluginLoaders[pluginId] = loader
            let plugin = CExtPlugin(
                id: pluginId,
                name: result.name,
                version: result.version,
                bundlePath: path
            )
            pluginInstances[pluginId] = plugin

            await registerInPluginRegistry(pluginId: pluginId)
        } catch {
            lastError = "Failed to load plugin: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func setEnabled(pluginId: String, enabled: Bool) {
        if let index = loadedPlugins.firstIndex(where: { $0.id == pluginId }) {
            loadedPlugins[index].isEnabled = enabled
            PluginRegistry.shared.setEnabled(pluginId: "cext.\(pluginId)", enabled: enabled)
        }
    }

    func unloadPlugin(pluginId: String) {
        loadedPlugins.removeAll { $0.id == pluginId }
        pluginLoaders.removeValue(forKey: pluginId)
        pluginInstances.removeValue(forKey: pluginId)
        PluginRegistry.shared.setEnabled(pluginId: "cext.\(pluginId)", enabled: false)
    }

    private func registerInPluginRegistry(pluginId: String) async {
        guard let plugin = pluginInstances[pluginId] else { return }

        let input = PluginInput(deviceId: UIDevice.current.identifierForVendor?.uuidString ?? "unknown")

        do {
            let hooks = try await plugin.configure(with: input)

            PluginRegistry.shared.registerExternalPlugin(
                pluginId: "cext.\(pluginId)",
                hooks: hooks,
                toolNames: hooks.tools.map(\.name)
            )

            setEnabled(pluginId: pluginId, enabled: true)
        } catch {
            lastError = "Failed to register plugin: \(error.localizedDescription)"
        }
    }
}
