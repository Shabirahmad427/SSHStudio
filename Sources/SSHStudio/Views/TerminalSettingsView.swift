import SwiftUI
import AppKit

struct TerminalSettingsView: View {
    @ObservedObject var settings = TerminalSettings.shared
    @Environment(\.dismiss) private var dismiss

    private let monoFonts: [(label: String, name: String)] = NSFontManager.shared
        .availableFontFamilies
        .compactMap { family in
            guard let members = NSFontManager.shared.availableMembers(ofFontFamily: family),
                  let member = members.first(where: {
                      guard let name = $0[0] as? String,
                            let style = $0[1] as? String,
                            let font = NSFont(name: name, size: 15)
                      else { return false }
                      return font.isFixedPitch && style.lowercased().contains("regular")
                  }),
                  let name = member[0] as? String
            else { return nil }
            return (label: family, name: name)
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "terminal.fill")
                    .foregroundColor(.accentColor)
                    .font(.title2)
                Text("Terminal Settings")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding()
            .background(.bar)

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // Font
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Font", systemImage: "textformat.size")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.secondary)

                            HStack {
                                Text("Size")
                                Spacer()
                                HStack(spacing: 4) {
                                    Button {
                                        if settings.fontSize > 8 { settings.fontSize -= 1 }
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)

                                    Text("\(Int(settings.fontSize)) pt")
                                        .monospacedDigit()
                                        .frame(width: 44, alignment: .center)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color(.controlBackgroundColor))
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                                    Button {
                                        if settings.fontSize < 36 { settings.fontSize += 1 }
                                    } label: {
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundColor(.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            // Slider
                            HStack {
                                Text("A").font(.system(size: 12, design: .monospaced))
                                Slider(value: $settings.fontSize, in: 8...36, step: 1)
                                Text("A").font(.system(size: 18, design: .monospaced))
                            }
                            .foregroundColor(.secondary)

                            Picker("Font Family", selection: $settings.fontName) {
                                Text("System Monospace").tag("")
                                Divider()
                                ForEach(monoFonts, id: \.name) { font in
                                    Text(font.label).tag(font.name)
                                }
                            }
                            .pickerStyle(.menu)

                            Picker("Font Weight", selection: $settings.fontWeight) {
                                ForEach(TerminalFontWeight.allCases, id: \.self) {
                                    Text($0.rawValue).tag($0)
                                }
                            }
                            .pickerStyle(.segmented)

                            // Preview
                            Text("user@server:~$ ssh studio\n0123456789  ABCDEFG  abcdefg")
                                .font(Font(settings.resolvedFont))
                                .foregroundColor(Color(settings.resolvedForeground))
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(settings.resolvedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .padding(4)
                    }

                    // Color Theme
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Color Theme", systemImage: "paintpalette.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.secondary)

                            LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 3), spacing: 8) {
                                ForEach(TerminalTheme.themes) { theme in
                                    ThemeChip(
                                        theme: theme,
                                        isSelected: !settings.useCustomColors && settings.themeID == theme.id
                                    ) {
                                        settings.themeID = theme.id
                                        settings.useCustomColors = false
                                    }
                                }
                            }
                        }
                        .padding(4)
                    }

                    // Custom Colors
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Custom Colors", systemImage: "eyedropper.halffull")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Toggle("", isOn: $settings.useCustomColors)
                                    .labelsHidden()
                            }

                            if settings.useCustomColors {
                                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                                    GridRow {
                                        Text("Background").foregroundColor(.secondary)
                                        ColorPicker("", selection: $settings.backgroundColor)
                                            .labelsHidden()
                                    }
                                    GridRow {
                                        Text("Text").foregroundColor(.secondary)
                                        ColorPicker("", selection: $settings.textColor)
                                            .labelsHidden()
                                    }
                                    GridRow {
                                        Text("Cursor").foregroundColor(.secondary)
                                        ColorPicker("", selection: $settings.cursorColor)
                                            .labelsHidden()
                                    }
                                    GridRow {
                                        Text("Selection").foregroundColor(.secondary)
                                        ColorPicker("", selection: $settings.selectionColor)
                                            .labelsHidden()
                                    }
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .padding(4)
                        .animation(.spring(duration: 0.25), value: settings.useCustomColors)
                    }
                }
                .padding()
            }
        }
        .frame(width: 500, height: 680)
    }
}

// MARK: - Theme Chip

private struct ThemeChip: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(theme.background))
                        .frame(height: 36)
                    HStack(spacing: 2) {
                        ForEach([NSColor.systemGreen, NSColor.systemYellow, NSColor.systemRed, theme.foreground], id: \.self) { c in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Color(c))
                                .frame(width: 12, height: 4)
                        }
                    }
                    .padding(4)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                            .background(Color.white.clipShape(Circle()))
                            .offset(x: -4, y: 4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(4)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : (hovered ? Color.primary.opacity(0.3) : Color.clear), lineWidth: 2)
                )

                Text(theme.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
