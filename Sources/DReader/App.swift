import SwiftUI

@main
struct DReaderApp: App {
    @State private var viewModel = ReaderViewModel()

    var body: some Scene {
        WindowGroup {
            ReaderMainView(vm: viewModel)
                .frame(minWidth: 980, idealWidth: 1260, minHeight: 680, idealHeight: 820)
        }
        .defaultSize(width: 1260, height: 820)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            SidebarCommands()

            CommandGroup(replacing: .newItem) {
                Button("打开本地 EPUB 电子书...") {
                    viewModel.showImportOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("在线数字书库探索中心...") {
                    viewModel.openOnlineLibrary()
                }
                .keyboardShortcut("l", modifiers: .command)

                Button("微信读书划线与想法同步...") {
                    viewModel.showWeChatSyncModal = true
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])

                Button("全书库划线与思考回顾中心...") {
                    viewModel.showGlobalNotebooksModal = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button(viewModel.readAloud.state == .playing ? "暂停整章朗读" : "开始整章朗读 (听书)") {
                    viewModel.toggleChapterReadAloud()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("今日划线 Mastery 复习...") {
                    viewModel.showReviewSessionModal = true
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("返回书架大厅") {
                    viewModel.returnToBookshelf()
                }
                .keyboardShortcut("b", modifiers: .command)
            }

            CommandMenu("阅读") {
                Button("上一页 (翻页)") {
                    viewModel.scrollPage(direction: -1)
                }
                .keyboardShortcut(.pageUp, modifiers: [])

                Button("下一页 (翻页)") {
                    viewModel.scrollPage(direction: 1)
                }
                .keyboardShortcut(.pageDown, modifiers: [])

                Divider()

                Button("上一章") {
                    viewModel.prevChapter()
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(viewModel.currentBook?.currentChapterIndex ?? 0 <= 0)

                Button("下一章") {
                    viewModel.nextChapter()
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(viewModel.currentBook?.currentChapterIndex ?? 0 >= (viewModel.currentBook?.chapters.count ?? 1) - 1)

                Divider()

                Button("增大字号") {
                    if viewModel.settings.fontSize < 32 {
                        viewModel.settings.fontSize += 1
                    }
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("减小字号") {
                    if viewModel.settings.fontSize > 14 {
                        viewModel.settings.fontSize -= 1
                    }
                }
                .keyboardShortcut("-", modifiers: .command)

                Divider()

                Button(viewModel.settings.pageLayout == .spread ? "切换为单页排版" : "切换为双页对开排版") {
                    withAnimation {
                        viewModel.settings.pageLayout = viewModel.settings.pageLayout == .spread ? .single : .spread
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button(viewModel.settings.isZenMode ? "退出禅意模式" : "进入全屏禅意模式") {
                    withAnimation {
                        viewModel.settings.isZenMode.toggle()
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)

                Button("切换白天 / 夜间阅读主题") {
                    withAnimation {
                        let s = viewModel.settings
                        if s.followSystemAppearance {
                            // 跟随模式下：把当前侧的偏好主题翻到另一侧亮暗（保留跟随，改的是自动切换的目标）
                            if s.theme.isDark {
                                s.darkTheme = s.darkTheme.isDark ? .white : .dark
                            } else {
                                s.lightTheme = s.lightTheme.isDark ? .gray : .sepia
                            }
                            s.applySystemAppearance()
                        } else {
                            s.theme = s.theme.isDark ? .white : .dark
                        }
                    }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Divider()

                Button(viewModel.settings.isBilingualEnabled ? "关闭双语段落对照" : "开启双语段落对照") {
                    viewModel.toggleBilingualMode()
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("AI 智能全章双语翻译") {
                    viewModel.translateCurrentChapterWithAgent()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()

                Button(viewModel.settings.chineseScriptMode == .simplified ? "恢复原版繁体字形" : "一键将繁体转换为简体") {
                    withAnimation {
                        if viewModel.settings.chineseScriptMode == .simplified {
                            viewModel.settings.chineseScriptMode = .original
                        } else {
                            viewModel.settings.chineseScriptMode = .simplified
                        }
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Divider()

                Button("切换 AI 伴读面板") {
                    withAnimation {
                        viewModel.isAIPanelVisible.toggle()
                    }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
    }
}
