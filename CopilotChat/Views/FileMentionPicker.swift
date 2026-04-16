import SwiftUI

struct FileMentionPicker: View {
    let files: [FileMention]
    let onSelect: (FileMention) -> Void
    let query: String

    var body: some View {
        VStack(spacing: 0) {
            if files.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
        .background(Color.carbonSurface)
        .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: Carbon.radiusMedium)
                .stroke(Color.carbonBorder.opacity(0.5), lineWidth: 0.5)
        )
    }

    private var emptyState: some View {
        VStack(spacing: Carbon.spacingBase) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.title3)
                .foregroundStyle(Color.carbonTextTertiary)
            Text(query.isEmpty ? "No files indexed" : "No files match \"\(query)\"")
                .font(.carbonMono(.caption2))
                .foregroundStyle(Color.carbonTextTertiary)
        }
        .padding(.vertical, Carbon.spacingLoose)
        .frame(maxWidth: .infinity)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(files) { file in
                    Button {
                        onSelect(file)
                        Haptics.impact(.light)
                    } label: {
                        fileRow(file)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 240)
    }

    private func fileRow(_ file: FileMention) -> some View {
        HStack(spacing: Carbon.spacingRelaxed) {
            Image(systemName: file.systemImage)
                .font(.system(size: 14))
                .foregroundStyle(file.tintColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName)
                    .font(.carbonMono(.caption, weight: .medium))
                    .foregroundStyle(Color.carbonText)
                    .lineLimit(1)

                Text(file.relativePath)
                    .font(.carbonMono(.caption2))
                    .foregroundStyle(Color.carbonTextTertiary)
                    .lineLimit(1)
            }

            Spacer()

            if !file.fileExtension.isEmpty {
                Text(file.fileExtension.uppercased())
                    .font(.carbonMono(.caption2, weight: .bold))
                    .kerning(0.2)
                    .foregroundStyle(file.tintColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(file.tintColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))
            }
        }
        .padding(.horizontal, Carbon.messagePaddingH)
        .padding(.vertical, Carbon.spacingBase)
        .background(Color.carbonSurface)
    }
}