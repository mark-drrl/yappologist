import SwiftUI

/// Window background that adapts to the active theme.
struct ThemeBackground: View {
    let theme: AppTheme

    var body: some View {
        switch theme {
        case .cute:
            CuteBackground()
        case .light, .dark:
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
        }
    }
}

/// Pastel gradient with apples scattered all around — the "cute" theme.
struct CuteBackground: View {
    private let apples = AppleDeco.scatter()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 1.00, green: 0.93, blue: 0.96), // soft pink
                    Color(red: 0.95, green: 0.93, blue: 1.00), // lavender
                    Color(red: 1.00, green: 0.96, blue: 0.90), // peach
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            GeometryReader { geo in
                ForEach(apples) { a in
                    Text("🍎")
                        .font(.system(size: a.size))
                        .rotationEffect(.degrees(a.rotation))
                        .opacity(a.opacity)
                        .position(x: a.x * geo.size.width,
                                  y: a.y * geo.size.height)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

struct AppleDeco: Identifiable {
    let id = UUID()
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let rotation: Double
    let opacity: Double

    /// A fixed, hand-tuned scatter so the apples feel intentional, not random.
    static func scatter() -> [AppleDeco] {
        let raw: [(CGFloat, CGFloat, CGFloat, Double, Double)] = [
            (0.06, 0.10, 30, -18, 0.18),
            (0.92, 0.08, 24,  22, 0.15),
            (0.20, 0.30, 18,  10, 0.12),
            (0.78, 0.26, 34, -12, 0.18),
            (0.50, 0.06, 20,   6, 0.14),
            (0.10, 0.55, 26,  16, 0.16),
            (0.88, 0.48, 22, -20, 0.14),
            (0.34, 0.72, 30,  14, 0.17),
            (0.66, 0.78, 18, -8,  0.12),
            (0.04, 0.86, 24,  20, 0.16),
            (0.94, 0.84, 32, -16, 0.18),
            (0.48, 0.92, 22,  9,  0.14),
            (0.24, 0.92, 16, -14, 0.11),
            (0.72, 0.58, 20,  18, 0.13),
        ]
        return raw.map { AppleDeco(x: $0.0, y: $0.1, size: $0.2, rotation: $0.3, opacity: $0.4) }
    }
}
