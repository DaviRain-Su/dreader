import SwiftUI

struct ReaderTypographySettingsPopover: View {
    @Bindable var settings: ReaderSettings
    var agentName: String = "AI 伴读"
    var isTranslating: Bool = false
    var translationProgress: Double = 0.0
    var onTranslateChapter: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Text("阅读排版与外观")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Apple Books 质感")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
            }

            // Theme Palette Cards
            VStack(alignment: .leading, spacing: 6) {
                Text("主题配色")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    ForEach(ReaderTheme.allCases) { theme in
                        Button {
                            settings.theme = theme
                        } label: {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color(hex: theme.backgroundColorHex))
                                    .frame(width: 40, height: 32)
                                    .overlay(
                                        Text("Aa")
                                            .font(.system(size: 12, weight: .bold, design: .serif))
                                            .foregroundStyle(Color(hex: theme.textColorHex))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .stroke(settings.theme == theme ? Color.purple : Color.primary.opacity(0.12),
                                                    lineWidth: settings.theme == theme ? 2 : 0.8)
                                    )
                                    .shadow(color: Color.black.opacity(settings.theme == theme ? 0.15 : 0.04), radius: 3, x: 0, y: 1.5)

                                Text(theme.rawValue)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(settings.theme == theme ? .primary : .secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()
                .opacity(0.3)

            // Font Family Selector with live typeface preview
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("字体排印")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(settings.fontFamily.shortName)
                        .font(settings.fontFamily.previewFont)
                        .foregroundStyle(Color.purple)
                }

                Menu {
                    ForEach(ReaderFontFamily.allCases) { f in
                        Button {
                            settings.fontFamily = f
                        } label: {
                            HStack {
                                Text(f.displayName)
                                if settings.fontFamily == f {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(settings.fontFamily.displayName)
                            .font(settings.fontFamily.previewFont)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }

            Divider()
                .opacity(0.3)

            // Font Size (Apple Books style +/- and slider)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("字号大小")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(settings.fontSize)) pt")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }

                HStack(spacing: 8) {
                    Button {
                        if settings.fontSize > 14 { settings.fontSize -= 1 }
                    } label: {
                        Text("A")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 24)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)

                    Slider(value: $settings.fontSize, in: 14...32, step: 1)

                    Button {
                        if settings.fontSize < 32 { settings.fontSize += 1 }
                    } label: {
                        Text("A")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 28, height: 24)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Line Height
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("行间距")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2f 倍", settings.lineHeight))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }

                Slider(value: $settings.lineHeight, in: 1.4...2.4, step: 0.05)
            }

            // Reading Column Width
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("版心宽度")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(settings.maxWidth)) px")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }

                Slider(value: $settings.maxWidth, in: 560...920, step: 20)
                    .disabled(settings.pageLayout == .spread)
            }

            Divider()
                .opacity(0.3)

            // Page Layout
            VStack(alignment: .leading, spacing: 6) {
                Text("版面布局")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Picker("", selection: $settings.pageLayout) {
                    ForEach(ReaderPageLayout.allCases) { layout in
                        Label(layout.rawValue, systemImage: layout.icon).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Justify alignment
            Toggle(isOn: $settings.isJustified) {
                Text("两端对齐排版 (优质齐头齐尾排印)")
                    .font(.system(size: 11.5))
            }

            // Zen Mode
            Toggle(isOn: $settings.isZenMode) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .foregroundStyle(.purple)
                    Text("沉浸模式 (隐藏边栏与顶栏)")
                        .font(.system(size: 11.5))
                }
            }

            Divider()
                .opacity(0.3)

            // Chinese Script Conversion Section (繁简字形转换)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "character")
                            .foregroundStyle(.purple)
                        Text("中文简繁转换")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    Spacer()
                    Text(settings.chineseScriptMode.rawValue)
                        .font(.system(size: 10))
                        .foregroundStyle(settings.chineseScriptMode != .original ? Color.purple : Color.secondary)
                }

                Picker("", selection: $settings.chineseScriptMode) {
                    ForEach(ChineseScriptMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Divider()
                .opacity(0.3)

            // Bilingual Interlinear Reading Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "character.book.closed.fill")
                            .foregroundStyle(.purple)
                        Text("双语对照模式")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    Spacer()
                    Toggle("", isOn: $settings.isBilingualEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }

                if settings.isBilingualEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Text("翻译驱动:")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(agentName)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.purple)
                        }

                        if isTranslating {
                            HStack(spacing: 6) {
                                ProgressView(value: translationProgress)
                                    .progressViewStyle(.linear)
                                Text("\(Int(translationProgress * 100))%")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        } else if let onTranslate = onTranslateChapter {
                            Button {
                                onTranslate()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "sparkles")
                                    Text("一键全章 AI 双语翻译")
                                }
                                .font(.system(size: 11, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4.5)
                                .background(Color.purple.opacity(0.12))
                                .foregroundStyle(.purple)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }
        }
        .padding(16)
        .frame(width: 310)
        .background(.ultraThinMaterial)
    }
}
