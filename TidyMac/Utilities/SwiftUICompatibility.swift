import SwiftUI

extension View {
    /// Hides scroll indicators when supported (macOS 13+), no-op on older systems.
    @ViewBuilder
    func hideScrollIndicatorsIfAvailable() -> some View {
        if #available(macOS 13.0, *) {
            scrollIndicators(.hidden)
        } else {
            self
        }
    }

    /// Hides scroll content background when supported (macOS 13+), no-op on older systems.
    @ViewBuilder
    func hideScrollContentBackgroundIfAvailable() -> some View {
        if #available(macOS 13.0, *) {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}
