import SwiftUI

struct EchoButton: View {
    let label: String
    let icon: String?
    let action: () -> Void
    @State private var isPressed = false
    @EnvironmentObject var themeManager: ThemeManager

    init(_ label: String, icon: String? = nil, action: @escaping () -> Void) {
        self.label = label; self.icon = icon; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let icon {
                    Label(label, systemImage: icon)
                } else {
                    Text(label)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(themeManager.theme.accent.opacity(0.14))
            .foregroundColor(themeManager.theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}
