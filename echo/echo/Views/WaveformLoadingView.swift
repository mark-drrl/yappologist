import SwiftUI

struct WaveformLoadingView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @State private var phase: Double = 0

    private let barCount = 12
    private let baseHeight: CGFloat = 10
    private let maxHeight: CGFloat = 50

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(themeManager.theme.accent.opacity(0.7 + 0.3 * barValue(i)))
                    .frame(width: 5, height: baseHeight + (maxHeight - baseHeight) * barValue(i))
                    .animation(
                        .easeInOut(duration: 0.5)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.07),
                        value: phase
                    )
            }
        }
        .frame(height: maxHeight + 10)
        .onAppear { phase = 1 }
    }

    private func barValue(_ i: Int) -> Double {
        let t = phase * .pi + Double(i) * .pi / Double(barCount - 1)
        return (sin(t) + 1) / 2
    }
}
