import AVFoundation
import SwiftUI

struct ReaderTypographySettingsPopover: View {
    @Bindable var settings: ReaderSettings
    var currentBookId: UUID? = nil
    var agentName: String = "AI 伴读"
    var isTranslating: Bool = false
    var translationProgress: Double = 0.0
    var bilingualQueueDescription: String = ""
    var hasBilingualQueueWork: Bool = false
    var onTranslateChapter: (() -> Void)? = nil
    var onTranslateFullBook: (() -> Void)? = nil

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
                            // 手动选主题 = 退出跟随，并把它记为当前明暗侧的偏好主题
                            settings.followSystemAppearance = false
                            settings.theme = theme
                            if theme.isDark {
                                settings.darkTheme = theme
                            } else {
                                settings.lightTheme = theme
                            }
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
                                            .stroke(settings.theme == theme ? Color.primary.opacity(0.7) : Color.primary.opacity(0.12),
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

                // 跟随系统外观：亮暗模式切换自动换对应的昼/夜主题
                Toggle(isOn: $settings.followSystemAppearance) {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.lefthalf.filled")
                            .foregroundStyle(Color.primary.opacity(0.75))
                        Text("跟随系统外观 (亮暗自动切换昼/夜主题)")
                            .font(.system(size: 11.5))
                    }
                }
                .help("开启后：系统进入深色模式自动用夜间主题，回到浅色用昼间主题；手动点主题卡即退出跟随")
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
                        .foregroundStyle(Color.primary.opacity(0.75))
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

            // Vertical Typesetting (中文古籍竖排)
            Toggle(isOn: Binding(
                get: { settings.isVertical },
                set: { _ in settings.toggleVertical(for: currentBookId) }
            )) {
                HStack(spacing: 4) {
                    Image(systemName: "text.alignright")
                        .foregroundStyle(Color.primary.opacity(0.75))
                    Text("竖排排版 (中文古籍传统版式)")
                        .font(.system(size: 11.5))
                }
            }
            .disabled(currentBookId == nil)
            .help(currentBookId == nil ? "打开一本书后可用" : "切换竖排/横排，按书记忆")

            // Zen Mode
            Toggle(isOn: $settings.isZenMode) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .foregroundStyle(Color.primary.opacity(0.75))
                    Text("沉浸模式 (隐藏边栏与顶栏)")
                        .font(.system(size: 11.5))
                }
            }

            // Line Guide (行引导线)
            Toggle(isOn: $settings.isLineGuide) {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(Color.primary.opacity(0.75))
                    Text("行引导线 (跟随视线，防长行串行)")
                        .font(.system(size: 11.5))
                }
            }
            .help("Apple Books 同款：鼠标所在文本行显示一条淡引导线，方便通读古籍长行")

            // 页边批注
            Toggle(isOn: $settings.isMarginNotes) {
                HStack(spacing: 4) {
                    Image(systemName: "text.quote")
                        .foregroundStyle(Color.primary.opacity(0.75))
                    Text("页边批注 (有思考的划线贴在两侧)")
                        .font(.system(size: 11.5))
                }
            }
            .help("Tufte margin notes：横排阅读时，划线下的思考直接以批注卡显示在正文两侧空白")

            // 批注字号（楷体夹批相对正文的比例档位）
            VStack(alignment: .leading, spacing: 6) {
                Text("批注字号 (相对正文)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Picker("", selection: $settings.marginNoteTextScale) {
                    ForEach(ReaderSettings.MarginNoteTextScale.allCases) { scale in
                        Text(scale.rawValue).tag(scale)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!settings.isMarginNotes)
            }

            // 仿真翻页
            Toggle(isOn: $settings.isPageTurnAnimation) {
                HStack(spacing: 4) {
                    Image(systemName: "book.pages")
                        .foregroundStyle(Color.primary.opacity(0.75))
                    Text("仿真翻页 (旧页整幅滑出，纸书手感)")
                        .font(.system(size: 11.5))
                }
            }
            .help("空格/方向键翻页时，旧页以完整纸面平移滑出而不是滚动跳变")

            Divider()
                .opacity(0.3)

            // Chinese Script Conversion Section (繁简字形转换)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "character")
                            .foregroundStyle(Color.primary.opacity(0.75))
                        Text("中文简繁转换")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    Spacer()
                    Text(settings.chineseScriptMode.rawValue)
                        .font(.system(size: 10))
                        .foregroundStyle(settings.chineseScriptMode != .original ? Color.primary.opacity(0.8) : Color.secondary)
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

            // Read-Aloud Engine Section (听书引擎)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "headphones")
                        .foregroundStyle(Color.primary.opacity(0.75))
                    Text("听书音色")
                        .font(.system(size: 11.5, weight: .semibold))
                    Spacer()
                    Picker("", selection: $settings.readAloudEngine) {
                        ForEach(ReaderSettings.ReadAloudEngine.allCases) { engine in
                            Text(engine.rawValue).tag(engine)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 190)
                }

                if settings.readAloudEngine == .qwen {
                    qwenStatusArea
                } else if settings.readAloudEngine == .piper {
                    piperStatusArea
                } else {
                    // AI 大模型语音：OpenAI 兼容 TTS 配置
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("端点")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            TextField("https://api.siliconflow.cn/v1", text: $settings.aiTTSEndpoint)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10.5, design: .monospaced))
                        }
                        HStack(spacing: 6) {
                            Text("密钥")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            SecureField("sk-...", text: $settings.aiTTSAPIKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10.5, design: .monospaced))
                        }
                        HStack(spacing: 6) {
                            Text("模型")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            TextField("FunAudioLLM/CosyVoice2-0.5B", text: $settings.aiTTSModel)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10.5, design: .monospaced))
                        }
                        HStack(spacing: 6) {
                            Text("音色")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            TextField("FunAudioLLM/CosyVoice2-0.5B:anna", text: $settings.aiTTSVoice)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10.5, design: .monospaced))
                        }
                        Text("兼容 OpenAI /v1/audio/speech 接口（硅基流动 CosyVoice2 提供拟人音色）。请求失败时尝试 Piper 本地引擎；两个引擎都失败会停止朗读并显示原因。")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()
                .opacity(0.3)

            // Bilingual Interlinear Reading Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "character.book.closed.fill")
                            .foregroundStyle(Color.primary.opacity(0.75))
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
                            Text("对照版式:")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: $settings.bilingualMode) {
                                ForEach(BilingualDisplayMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 150)
                        }

                        if settings.bilingualMode == .sideBySide,
                           settings.isVertical || settings.pageLayout == .spread {
                            Text("竖排或双页对开排版下自动回退为段落下对照")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary.opacity(0.85))
                        }

                        HStack(spacing: 4) {
                            Text("翻译驱动:")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(agentName)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.primary.opacity(0.75))
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
                                    Text("当前章批翻")
                                }
                                .font(.system(size: 11, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4.5)
                                .background(Color.primary.opacity(0.07))
                                .foregroundStyle(Color.primary.opacity(0.75))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }

                        if let onFullBook = onTranslateFullBook {
                            Button {
                                onFullBook()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "books.vertical.fill")
                                    Text("AI 双语翻译全书")
                                }
                                .font(.system(size: 11, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4.5)
                                .background(Color.primary.opacity(0.07))
                                .foregroundStyle(Color.primary.opacity(0.75))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }

                        // 章接力状态:后台正在扫到第几章(开双语即自动接力)
                        if hasBilingualQueueWork, !isTranslating {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 8.5))
                                Text(bilingualQueueDescription)
                                    .font(.system(size: 9.5))
                            }
                            .foregroundStyle(.secondary)
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

    // MARK: - Qwen 本地引擎状态区

    @ViewBuilder
    private var qwenStatusArea: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("中文音色")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $settings.qwenVoice) {
                    ForEach(ReaderSettings.QwenVoice.allCases) { voice in
                        Text(voice.rawValue).tag(voice)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 178)
            }
            HStack(spacing: 5) {
                Image(systemName: QwenInstallation.status() == .ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(QwenInstallation.status() == .ready ? .green : .orange)
                Text(QwenInstallation.status().rawValue)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Text("Qwen 1.7B CustomVoice 6bit · 本地生成，不上传正文。首次加载需要数秒；不可用时仅回退 Piper。")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Piper 本地引擎状态区

    @ObservedObject private var piperInstaller = PiperInstaller.shared

    @ViewBuilder
    private var piperStatusArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if piperInstaller.isInstalled {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Text("Piper 引擎已就绪（花言 · 中文女声，完全离线）")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            } else if piperInstaller.isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ProgressView(value: piperInstaller.downloadProgress ?? 0)
                            .progressViewStyle(.linear)
                        Text("\(Int((piperInstaller.downloadProgress ?? 0) * 100))%")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(piperInstaller.statusText)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("首次使用需联网下载一次（引擎 18MB + 中文语音模型 63MB），之后永久离线、免费、无风控")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await piperInstaller.install() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("下载 Piper 本地语音引擎")
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.75))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            if let err = piperInstaller.lastError {
                Text(err)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
            }
        }
    }
}
