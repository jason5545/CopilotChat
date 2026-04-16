import SwiftUI

struct ModelPickerView: View {
    let provider: ModelsDevProvider
    @Binding var selectedModelId: String?
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var filterFree = false
    @State private var filterTools = false
    @State private var filterReasoning = false
    @State private var filterVision = false
    @State private var filterOpenWeights = false
    @State private var sortBy: SortOption = .context
    @State private var groupByFamily = true

    enum SortOption: String, CaseIterable {
        case context = "Context"
        case price = "Price"
        case name = "Name"
    }

    // MARK: - Filtered & Sorted Models

    private var filteredModels: [ModelsDevModel] {
        var result = provider.sortedModels

        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(q) ||
                $0.id.lowercased().contains(q) ||
                ($0.family ?? "").lowercased().contains(q)
            }
        }

        if filterFree { result = result.filter { $0.isFree } }
        if filterTools { result = result.filter { $0.toolCall } }
        if filterReasoning { result = result.filter { $0.reasoning } }
        if filterVision { result = result.filter { $0.isVision } }
        if filterOpenWeights { result = result.filter { $0.openWeights == true } }

        switch sortBy {
        case .context:
            result.sort { $0.limit.context > $1.limit.context }
        case .price:
            result.sort { ($0.cost?.input ?? 0) < ($1.cost?.input ?? 0) }
        case .name:
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        return result
    }

    private var groupedModels: [(String, [ModelsDevModel])] {
        let models = filteredModels
        if groupByFamily {
            var groups: [String: [ModelsDevModel]] = [:]
            for model in models {
                let key = model.family ?? "Other"
                groups[key, default: []].append(model)
            }
            return groups.sorted { $0.key < $1.key }
        } else {
            return [("All Models", models)]
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                    .padding(.horizontal, Carbon.spacingRelaxed)
                    .padding(.top, Carbon.spacingBase)
                    .padding(.bottom, Carbon.spacingTight)

                filterChips
                    .padding(.horizontal, Carbon.spacingRelaxed)
                    .padding(.bottom, Carbon.spacingTight)

                sortBar
                    .padding(.horizontal, Carbon.spacingRelaxed)
                    .padding(.bottom, Carbon.spacingBase)

                Divider()
                    .background(Color.carbonBorder.opacity(0.4))

                modelList
            }
            .background(Color.carbonBlack)
            .carbonNavigationBarStyle()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(provider.name.uppercased())
                        .font(.carbonMono(.caption, weight: .bold))
                        .kerning(2.5)
                        .foregroundStyle(Color.carbonText)
                }
                ToolbarItem(placement: .carbonTrailing) {
                    Button { dismiss() } label: {
                        Text("Done")
                            .font(.carbonSans(.subheadline, weight: .medium))
                            .foregroundStyle(Color.carbonAccent)
                    }
                }
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(Color.carbonTextTertiary)

            TextField("Search models...", text: $searchText)
                .font(.carbonSans(.subheadline))
                .foregroundStyle(Color.carbonText)
                .autocorrectionDisabled()
                #if canImport(UIKit)
                .textInputAutocapitalization(.never)
                #endif

            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.carbonTextTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.carbonElevated)
        .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))
    }

    // MARK: - Filter Chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if !provider.isAPIBased {
                    filterChip(label: "Free", active: $filterFree, color: .carbonSuccess)
                }
                filterChip(label: "Tools", active: $filterTools, color: .carbonSuccess)
                filterChip(label: "Reason", active: $filterReasoning, color: .carbonAccent)
                filterChip(label: "Vision", active: $filterVision, color: .carbonAccent)
                filterChip(label: "Open Weights", active: $filterOpenWeights, color: .carbonSuccess)
            }
        }
    }

    private func filterChip(label: String, active: Binding<Bool>, color: Color) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                active.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: active.wrappedValue ? "checkmark" : "circle")
                    .font(.caption2)
                Text(label.uppercased())
                    .font(.carbonMono(.caption2, weight: .bold))
                    .kerning(0.3)
            }
            .foregroundStyle(active.wrappedValue ? Color.carbonBlack : color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(active.wrappedValue ? color : color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sort Bar

    private var sortBar: some View {
        HStack(spacing: 12) {
            Text("Sort:")
                .font(.carbonMono(.caption2))
                .foregroundStyle(Color.carbonTextTertiary)

            ForEach(SortOption.allCases, id: \.self) { option in
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    sortBy = option
                }
            } label: {
                    Text(option.rawValue)
                        .font(.carbonMono(.caption2, weight: sortBy == option ? .bold : .regular))
                        .kerning(0.2)
                        .foregroundStyle(sortBy == option ? Color.carbonAccent : Color.carbonTextTertiary)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    groupByFamily.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: groupByFamily ? "rectangle.split.3x1.fill" : "rectangle.split.3x1")
                        .font(.caption2)
                    Text("Group")
                        .font(.carbonMono(.caption2))
                }
                .foregroundStyle(groupByFamily ? Color.carbonAccent : Color.carbonTextTertiary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Model List

    private var modelList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                if filteredModels.isEmpty {
                    emptyState
                } else if groupByFamily {
                    ForEach(groupedModels, id: \.0) { family, models in
                        familySection(family: family, models: models)
                    }
                } else {
                    ForEach(filteredModels) { model in
                        modelRow(model: model)
                    }
                }
            }
            .padding(.bottom, 40)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(Color.carbonTextTertiary)
            Text("No models match your filters")
                .font(.carbonSans(.subheadline))
                .foregroundStyle(Color.carbonTextSecondary)
            Button("Clear Filters") {
                searchText = ""
                filterFree = false
                filterTools = false
                filterReasoning = false
                filterVision = false
                filterOpenWeights = false
            }
            .font(.carbonMono(.caption2, weight: .medium))
            .foregroundStyle(Color.carbonAccent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    @ViewBuilder
    private func familySection(family: String, models: [ModelsDevModel]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(family.uppercased())
                .font(.carbonMono(.caption2, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(Color.carbonTextTertiary)
                .padding(.horizontal, Carbon.spacingRelaxed)
                .padding(.vertical, Carbon.spacingBase)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.carbonSurface.opacity(0.5))

            ForEach(models) { model in
                modelRow(model: model)
            }
        }
    }

    private func modelRow(model: ModelsDevModel) -> some View {
        Button {
            selectedModelId = model.id
            dismiss()
        } label: {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(model.name)
                            .font(.carbonSans(.subheadline, weight: .medium))
                            .foregroundStyle(Color.carbonText)
                            .lineLimit(1)

                        if model.isFree && !model.isSubscriptonPlan {
                            Text("FREE")
                                .font(.carbonMono(.caption2, weight: .bold))
                                .kerning(0.2)
                                .foregroundStyle(Color.carbonSuccess)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.carbonSuccess.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: Carbon.radiusSmall))
                        }

                        if let family = model.family {
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

                    ModelTagsView(model: model)
                }

                Spacer()

                if selectedModelId == model.id {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(Color.carbonAccent)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(Color.carbonTextTertiary)
                }
            }
            .padding(.horizontal, Carbon.spacingRelaxed)
            .padding(.vertical, Carbon.spacingBase)
            .background(selectedModelId == model.id ? Color.carbonAccent.opacity(0.06) : Color.carbonSurface)
        }
        .buttonStyle(.plain)
    }

}

// MARK: - Preview

#Preview {
    let sampleProvider = ModelsDevProvider(
        id: "openrouter",
        name: "OpenRouter",
        env: ["OPENROUTER_API_KEY"],
        npm: "@openrouter/ai-sdk-provider",
        api: "https://openrouter.ai/api/v1",
        doc: "https://openrouter.ai/models",
        models: [:]
    )
    return ModelPickerView(provider: sampleProvider, selectedModelId: .constant("nvidia/nemotron-3-super-120b-a12b:free"))
        .preferredColorScheme(.dark)
}
