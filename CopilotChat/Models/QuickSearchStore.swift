import Foundation
import Observation

@Observable
@MainActor
final class QuickSearchStore {
    enum OpenIntent: Equatable {
        case general
        case addProject
    }

    var isPresented = false
    var openIntent: OpenIntent = .general

    func present(_ intent: OpenIntent = .general) {
        openIntent = intent
        isPresented = true
    }

    func dismiss() {
        isPresented = false
        openIntent = .general
    }

    func toggle(_ intent: OpenIntent = .general) {
        if isPresented {
            dismiss()
        } else {
            present(intent)
        }
    }
}
