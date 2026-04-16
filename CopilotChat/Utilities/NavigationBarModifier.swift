import SwiftUI

extension View {
    func carbonNavigationBar() -> some View {
        #if canImport(UIKit)
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.carbonSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }

    func carbonNavigationBarStyle() -> some View {
        #if canImport(UIKit)
        self
            .toolbarBackground(Color.carbonSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }
}

extension ToolbarItemPlacement {
    static var carbonLeading: ToolbarItemPlacement {
        #if canImport(UIKit)
        .topBarLeading
        #else
        .cancellationAction
        #endif
    }

    static var carbonTrailing: ToolbarItemPlacement {
        #if canImport(UIKit)
        .topBarTrailing
        #else
        .confirmationAction
        #endif
    }
}