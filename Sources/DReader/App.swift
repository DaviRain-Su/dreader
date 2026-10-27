import SwiftUI

@main
struct DReaderApp: App {
    @State private var viewModel = ReaderViewModel()

    var body: some Scene {
        WindowGroup {
            ReaderMainView(vm: viewModel)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            SidebarCommands()

            CommandGroup(replacing: .newItem) {
                Button("打开 EPUB 电子书...") {
                    viewModel.showImportOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)

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
