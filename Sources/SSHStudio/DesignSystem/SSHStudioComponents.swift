import SwiftUI

struct StudioBackdrop: View {
    var body: some View {
        SSHStudioColors.windowBackground
            .ignoresSafeArea()
    }
}

struct StudioGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: SSHStudioMetrics.controlCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: SSHStudioMetrics.controlCornerRadius)
                    .strokeBorder(SSHStudioColors.separator.opacity(configuration.isPressed ? 0.9 : 0.55), lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct TahoeMagnifyGlass: ViewModifier {
    let enabled: Bool
    let isActive: Bool
    let tint: Color
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(isActive ? tint.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}

extension View {
    func tahoeMagnifyGlass(
        enabled: Bool = true,
        isActive: Bool = false,
        tint: Color = .accentColor,
        cornerRadius: CGFloat = SSHStudioMetrics.controlCornerRadius,
        scale: CGFloat = 1,
        lift: CGFloat = 0,
        response: Double = 0,
        dampingFraction: Double = 1
    ) -> some View {
        modifier(TahoeMagnifyGlass(enabled: enabled, isActive: isActive, tint: tint, cornerRadius: cornerRadius))
    }
}

struct SSHStatusPill: View {
    let style: SSHStudioStatusStyle
    var showsTitle = true

    var body: some View {
        Label {
            if showsTitle {
                Text(style.title)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: style.systemImage)
                .symbolVariant(.none)
                .foregroundStyle(style.color)
        }
        .font(SSHStudioTypography.status)
        .foregroundStyle(.secondary)
        .accessibilityLabel(style.title)
    }
}

struct SSHConnectionStatusPill: View {
    @ObservedObject var service: SSHConnectionService
    var showsTitle = true

    var body: some View {
        SSHStatusPill(style: SSHStudioStatusStyle.connection(service.state), showsTitle: showsTitle)
    }
}

struct SSHStudioEmptyState: View {
    let title: String
    let message: String
    let systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: SSHStudioSpacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(spacing: SSHStudioSpacing.xs) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("k", modifiers: .command)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(SSHStudioSpacing.xl)
    }
}
