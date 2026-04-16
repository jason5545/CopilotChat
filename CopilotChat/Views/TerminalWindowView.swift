import SwiftUI

struct TerminalWindowView: View {
    @State private var tracker = TerminalSessionTracker.shared
    @Environment(\.dismiss) private var dismiss

    private var session: TerminalSessionTracker.TerminalSession? {
        guard let sessionId = tracker.focusedSessionId else { return nil }
        return tracker.session(forSessionId: sessionId)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    terminalBody(session)
                } else {
                    emptyState
                }
            }
            .background(Color.carbonBlack)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("TERMINAL")
                        .font(.carbonMono(.caption, weight: .bold))
                        .kerning(2.5)
                        .foregroundStyle(Color.carbonText)
                }
                ToolbarItem(placement: .carbonTrailing) {
                    Button("Done") {
                        tracker.isWindowPresented = false
                        dismiss()
                    }
                        .font(.carbonSans(.subheadline, weight: .medium))
                        .foregroundStyle(Color.carbonAccent)
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 860, minHeight: 560)
#endif
    }

    private func terminalBody(_ session: TerminalSessionTracker.TerminalSession) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Carbon.spacingRelaxed) {
                HStack(alignment: .top, spacing: Carbon.spacingRelaxed) {
                    VStack(alignment: .leading, spacing: Carbon.spacingTight) {
                        Text("COMMAND")
                            .font(.carbonMono(.caption2, weight: .bold))
                            .kerning(0.8)
                            .foregroundStyle(Color.carbonTextTertiary)
                        Text(session.command)
                            .font(.carbonMono(.caption))
                            .foregroundStyle(Color.carbonText)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    statusBadge(session.state)
                }

                VStack(alignment: .leading, spacing: Carbon.spacingTight) {
                    Text("WORKSPACE")
                        .font(.carbonMono(.caption2, weight: .bold))
                        .kerning(0.8)
                        .foregroundStyle(Color.carbonTextTertiary)
                    Text(session.workingDirectory)
                        .font(.carbonMono(.caption2))
                        .foregroundStyle(Color.carbonTextSecondary)
                        .textSelection(.enabled)
                }
            }
            .padding(Carbon.spacingLoose)
            .background(Color.carbonSurface)

            Rectangle()
                .fill(Color.carbonBorder.opacity(0.35))
                .frame(height: 0.5)

            ScrollView {
                Text(session.output.isEmpty ? session.statusLine : session.output)
                    .font(.carbonMono(.caption2))
                    .foregroundStyle(session.output.isEmpty ? Color.carbonTextTertiary : Color.carbonText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Carbon.spacingLoose)
            }
            .background(Color.carbonCodeBg)
        }
        .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: Carbon.radiusMedium)
                .stroke(Color.carbonBorder.opacity(0.4), lineWidth: 0.5)
        )
        .padding(Carbon.spacingLoose)
    }

    private var emptyState: some View {
        VStack(spacing: Carbon.spacingRelaxed) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.carbonTextTertiary)
            Text("No Terminal Session")
                .font(.carbonSerif(.title3, weight: .medium))
                .foregroundStyle(Color.carbonText)
            Text("Run a terminal command from Code mode to inspect output here.")
                .font(.carbonSans(.caption))
                .foregroundStyle(Color.carbonTextSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusBadge(_ state: TerminalSessionState) -> some View {
        let badge = statusBadgeStyle(for: state)

        return Text(badge.label)
            .font(.carbonMono(.caption2, weight: .bold))
            .kerning(0.8)
            .foregroundStyle(badge.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(badge.color.opacity(0.12))
            .clipShape(Capsule())
    }

    private func statusBadgeStyle(for state: TerminalSessionState) -> (label: String, color: Color) {
        switch state {
        case .running:
            return ("RUNNING", .carbonAccent)
        case .completed(let exitCode):
            return (exitCode == 0 ? "DONE" : "EXIT \(exitCode)", exitCode == 0 ? .carbonSuccess : .carbonWarning)
        case .failed:
            return ("FAILED", .carbonError)
        case .cancelled:
            return ("CANCELLED", .carbonTextTertiary)
        }
    }
}

#Preview {
    TerminalWindowView()
}
