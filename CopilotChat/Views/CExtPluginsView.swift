import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct CExtPluginsView: View {
    @State private var cExtManager = CExtPluginManager.shared
    @State private var showDocumentPicker = false
    @State private var isLoading = false

    var body: some View {
        List {
            Section {
                if cExtManager.loadedPlugins.isEmpty && !isLoading {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "puzzlepiece.extension")
                                .font(.largeTitle)
                                .foregroundStyle(Color.carbonTextTertiary)
                            Text("No plugins loaded")
                                .font(.carbonSans(.subheadline))
                                .foregroundStyle(Color.carbonTextTertiary)
                        }
                        .padding(.vertical, 40)
                        Spacer()
                    }
                    .listRowBackground(Color.carbonSurface)
                } else {
                    ForEach(cExtManager.loadedPlugins) { plugin in
                        pluginRow(plugin)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            let plugin = cExtManager.loadedPlugins[index]
                            cExtManager.unloadPlugin(pluginId: plugin.id)
                        }
                    }
                }
            } header: {
                CarbonSectionHeader(title: "Loaded Plugins")
            } footer: {
                Text(".cex plugins run in a JavaScript sandbox with limited access to network, clipboard, and notifications.")
                    .font(.carbonMono(.caption2))
                    .foregroundStyle(Color.carbonTextTertiary)
            }

            Section {
                Button {
                    showDocumentPicker = true
                } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text("Import from Files...")
                            .font(.carbonSans(.subheadline))
                    }
                    .foregroundStyle(Color.carbonAccent)
                }
                .listRowBackground(Color.carbonSurface)
            } header: {
                CarbonSectionHeader(title: "Add Plugins")
            } footer: {
                Text("Import .cex plugin bundles from the Files app. Each plugin must contain a manifest.json and index.js.")
                    .font(.carbonMono(.caption2))
                    .foregroundStyle(Color.carbonTextTertiary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.carbonBlack)
        .navigationTitle("Community Plugins")
        .carbonNavigationBarStyle()
        .overlay {
            if isLoading {
                ProgressView()
                    .tint(.white)
            }
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView { url in
                Task {
                    await cExtManager.loadPlugin(from: url.path)
                }
            }
        }
        .alert("Error", isPresented: .constant(cExtManager.lastError != nil)) {
            Button("OK") {
                cExtManager.lastError = nil
            }
        } message: {
            Text(cExtManager.lastError ?? "")
        }
    }

    private func pluginRow(_ plugin: CExtPluginManager.LoadedCExtPlugin) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name)
                        .font(.carbonSans(.subheadline, weight: .medium))
                        .foregroundStyle(Color.carbonText)
                    Text("v\(plugin.version)")
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonTextTertiary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { plugin.isEnabled },
                    set: { cExtManager.setEnabled(pluginId: plugin.id, enabled: $0) }
                ))
                .labelsHidden()
                .tint(Color.carbonAccent)
            }

            if !plugin.description.isEmpty {
                Text(plugin.description)
                    .font(.carbonSans(.caption))
                    .foregroundStyle(Color.carbonTextSecondary)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                ForEach(plugin.tools, id: \.self) { tool in
                    Text(tool)
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.carbonElevated)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.carbonSurface)
    }
}

#if canImport(UIKit)
struct DocumentPickerView: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }

            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }

            let destDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cex-imports")
                .appendingPathComponent(url.lastPathComponent)

            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destDir)

            do {
                try FileManager.default.copyItem(at: url, to: destDir)
                onPick(destDir)
            } catch {
                print("Failed to copy plugin: \(error)")
            }
        }
    }
}
#elseif canImport(AppKit)
struct DocumentPickerView: NSViewRepresentable {
    let onPick: (URL) -> Void

    func makeNSView(context: Context) -> NSView {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            onPick(url)
        }
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
