import SwiftUI

struct TerminalMessageView: View {
    let toolCallId: String
    @State private var tracker = TerminalSessionTracker.shared

    private var session: TerminalSessionTracker.TerminalSession? {
        tracker.session(forToolCallId: toolCallId)
    }

    var body: some View {
        if let session {
            VStack(alignment: .leading, spacing: Carbon.spacingRelaxed) {
                HStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .font(.caption)
                        .foregroundStyle(Color.carbonAccent)
                        .frame(width: 20, height: 20)
                        .background(Color.carbonAccent.opacity(0.15))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("TERMINAL")
                            .font(.carbonMono(.caption2, weight: .bold))
                            .kerning(0.8)
                            .foregroundStyle(Color.carbonAccent)
                        Text(session.command)
                            .font(.carbonMono(.caption2))
                            .foregroundStyle(Color.carbonTextSecondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        tracker.openWindow(forToolCallId: toolCallId)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption2)
                            Text("Open")
                                .font(.carbonMono(.caption2, weight: .semibold))
                        }
                        .foregroundStyle(Color.carbonAccent)
                    }
                    .buttonStyle(.plain)
                }

                Text(session.output.isEmpty ? session.statusLine : session.output)
                    .font(.carbonMono(.caption2))
                    .foregroundStyle(session.output.isEmpty ? Color.carbonTextTertiary : Color.carbonTextSecondary)
                    .lineLimit(10)
                    .textSelection(.enabled)
                    .padding(Carbon.spacingRelaxed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.carbonCodeBg)
                    .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: Carbon.radiusSmall)
                            .stroke(Color.carbonBorder.opacity(0.3), lineWidth: 0.5)
                    )
            }
            .padding(.horizontal, Carbon.messagePaddingH)
            .padding(.vertical, Carbon.spacingTight)
        }
    }
}
