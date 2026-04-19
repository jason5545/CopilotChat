import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct WorkspaceSelectorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var workspaceManager = WorkspaceManager.shared
    @State private var refreshID = UUID()

    private var savedWorkspaces: [WorkspaceManager.SavedWorkspace] {
        workspaceManager.savedWorkspaces.filter { !$0.isCurrent }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if workspaceManager.hasWorkspace {
                        currentWorkspaceRow
                    } else {
                        noWorkspaceRow
                    }
                } header: {
                    CarbonSectionHeader(title: "Workspace")
                } footer: {
                    Text("Select a project folder to enable file editing tools. The app will retain access to this folder until you remove it.")
                        .font(.carbonSans(.caption))
                        .foregroundStyle(Color.carbonTextSecondary)
                }

                if !savedWorkspaces.isEmpty {
                    Section {
                        ForEach(savedWorkspaces) { workspace in
                            Button {
                                if workspaceManager.switchWorkspace(to: workspace.id) {
                                    dismiss()
                                }
                            } label: {
                                savedWorkspaceRow(workspace)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.carbonSurface)
                        }
                    } header: {
                        CarbonSectionHeader(title: "Saved Projects")
                    } footer: {
                        Text("Projects appear here after you choose them once on this device.")
                            .font(.carbonSans(.caption))
                            .foregroundStyle(Color.carbonTextSecondary)
                    }
                }
            }
            .id(refreshID)
            .scrollContentBackground(.hidden)
            .background(Color.carbonBlack)
            .navigationTitle("Workspace")
            .carbonNavigationBar()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("WORKSPACE")
                        .font(.carbonMono(.caption, weight: .bold))
                        .kerning(2.5)
                        .foregroundStyle(Color.carbonText)
                }
                ToolbarItem(placement: doneToolbarPlacement) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.carbonSans(.subheadline, weight: .medium))
                    .foregroundStyle(Color.carbonAccent)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .workspaceDidChange)) { _ in
            refreshID = UUID()
            dismiss()
        }
#if os(macOS)
        .frame(minWidth: 720, minHeight: 520)
#endif
    }

    private var doneToolbarPlacement: ToolbarItemPlacement { .carbonTrailing }

    private var currentWorkspaceRow: some View {
        VStack(alignment: .leading, spacing: Carbon.spacingRelaxed) {
            HStack {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(Color.carbonAccent)

                VStack(alignment: .leading, spacing: Carbon.spacingTight) {
                    Text(workspaceManager.workspaceName ?? "Unknown")
                        .font(.carbonSans(.subheadline, weight: .semibold))
                        .foregroundStyle(Color.carbonText)

                    if let url = workspaceManager.currentURL {
                        Text(url.path)
                            .font(.carbonMono(.caption))
                            .foregroundStyle(Color.carbonTextTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button {
                    workspaceManager.clearWorkspace()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.carbonTextTertiary)
                }
            }

            Button {
                openFolderPicker()
            } label: {
                HStack {
                    Image(systemName: "folder.badge.plus")
                    Text("Change Folder")
                }
                .font(.carbonMono(.subheadline, weight: .medium))
                .foregroundStyle(Color.carbonAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Carbon.spacingRelaxed)
                .background(Color.carbonElevated)
                .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))
            }
        }
        .padding(.vertical, Carbon.spacingBase)
    }

    private var noWorkspaceRow: some View {
        VStack(spacing: Carbon.spacingLoose) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(Color.carbonTextTertiary)

            Text("No Workspace Selected")
                .font(.carbonSans(.subheadline, weight: .semibold))
                .foregroundStyle(Color.carbonText)

            Text("Select a project folder to enable file editing tools")
                .font(.carbonSans(.caption))
                .foregroundStyle(Color.carbonTextSecondary)
                .multilineTextAlignment(.center)

            Button {
                openFolderPicker()
            } label: {
                HStack {
                    Image(systemName: "folder.badge.plus")
                    Text("Select Folder")
                }
                .font(.carbonMono(.subheadline, weight: .medium))
                .foregroundStyle(Color.carbonBlack)
                .padding(.horizontal, Carbon.spacingLoose)
                .padding(.vertical, Carbon.spacingRelaxed)
                .background(Color.carbonAccent)
                .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Carbon.spacingWide)
    }

    private func savedWorkspaceRow(_ workspace: WorkspaceManager.SavedWorkspace) -> some View {
        HStack(spacing: Carbon.spacingRelaxed) {
            Image(systemName: "folder")
                .font(.subheadline)
                .foregroundStyle(Color.carbonTextSecondary)

            VStack(alignment: .leading, spacing: Carbon.spacingTight) {
                Text(workspace.title)
                    .font(.carbonSans(.subheadline, weight: .semibold))
                    .foregroundStyle(Color.carbonText)

                if let subtitle = workspace.subtitle {
                    Text(subtitle)
                        .font(.carbonMono(.caption))
                        .foregroundStyle(Color.carbonTextTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption)
                .foregroundStyle(Color.carbonTextTertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func openFolderPicker() {
        #if canImport(UIKit)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else {
            return
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        workspaceManager.selectWorkspace(from: topVC)
        #elseif canImport(AppKit)
        guard let window = NSApp.keyWindow else { return }
        workspaceManager.selectWorkspace(from: window.contentViewController ?? NSViewController())
        #endif
    }
}

#Preview {
    WorkspaceSelectorView()
}
