import SwiftUI

struct ModelTagsView: View {
    let model: ModelsDevModel
    var showFamily: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(model.displayContextWindow)
                .font(.carbonMono(.caption2))
                .foregroundStyle(Color.carbonTextTertiary)

            if model.isSubscriptonPlan {
                Text("PLAN")
                    .font(.carbonMono(.caption2, weight: .bold))
                    .kerning(0.2)
                    .foregroundStyle(Color.carbonAccent)
            } else if model.isFree {
                Text("FREE")
                    .font(.carbonMono(.caption2, weight: .bold))
                    .kerning(0.2)
                    .foregroundStyle(Color.carbonSuccess)
            } else {
                Text(model.displayCost)
                    .font(.carbonMono(.caption2))
                    .foregroundStyle(Color.carbonTextTertiary)
            }

            if model.reasoning {
                Text("REASON")
                    .font(.carbonMono(.caption2, weight: .bold))
                    .kerning(0.2)
                    .foregroundStyle(Color.carbonAccent)
            }

            if model.toolCall {
                Text("TOOLS")
                    .font(.carbonMono(.caption2, weight: .bold))
                    .kerning(0.2)
                    .foregroundStyle(Color.carbonSuccess)
            }

            if model.isVision {
                Text("VISION")
                    .font(.carbonMono(.caption2, weight: .bold))
                    .kerning(0.2)
                    .foregroundStyle(Color.carbonAccent)
            }

            if model.openWeights == true {
                Text("OPEN")
                    .font(.carbonMono(.caption2, weight: .bold))
                    .kerning(0.2)
                    .foregroundStyle(Color.blue)
            }

            if showFamily, let family = model.family {
                Text(family.uppercased())
                    .font(.carbonMono(.caption2))
                    .kerning(0.3)
                    .foregroundStyle(Color.carbonTextTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.carbonElevated)
                    .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))
            }
        }
    }
}
