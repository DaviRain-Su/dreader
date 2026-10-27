import SwiftUI

struct RealisticBookshelfView: View {
    let books: [EPUBBook]
    let onSelectBook: (EPUBBook) -> Void
    let onImportEPUB: () -> Void

    @State private var searchText: String = ""

    private var filteredBooks: [EPUBBook] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return books
        }
        return books.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.author.localizedCaseInsensitiveContains(searchText)
        }
    }

    // Chunk books into shelves of 4
    private var shelfRows: [[EPUBBook]] {
        stride(from: 0, to: filteredBooks.count, by: 4).map {
            Array(filteredBooks[$0..<min($0 + 4, filteredBooks.count)])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top Bookshelf Navigation Bar
            bookshelfTopBar

            Divider()
                .opacity(0.2)

            // Scrollable Wooden Bookshelf Racks
            ScrollView {
                VStack(spacing: 36) {
                    // Ceiling Warm Ambient Light
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 12)

                    if shelfRows.isEmpty {
                        emptyShelfPlaceholder
                    } else {
                        ForEach(Array(shelfRows.enumerated()), id: \.offset) { index, rowBooks in
                            SingleShelfRowView(
                                books: rowBooks,
                                isLastRow: index == shelfRows.count - 1,
                                onSelectBook: onSelectBook,
                                onImportEPUB: onImportEPUB
                            )
                        }
                    }

                    Spacer(minLength: 48)
                }
                .padding(.horizontal, 32)
                .padding(.top, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                // Dark Mahogany / Espresso Library Wall Texture
                LinearGradient(
                    colors: [
                        Color(hex: "#1F1511"),
                        Color(hex: "#180F0C"),
                        Color(hex: "#120B08")
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Warm Ceiling Chandelier Spotlight
                RadialGradient(
                    colors: [
                        Color(hex: "#FFEDD5").opacity(0.08),
                        Color.clear
                    ],
                    center: .top,
                    startRadius: 40,
                    endRadius: 750
                )
            }
            .ignoresSafeArea()
        )
    }

    // MARK: - Top Bar
    private var bookshelfTopBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color(hex: "#E5C07B"))

                VStack(alignment: .leading, spacing: 1) {
                    Text("DReader")
                        .font(.system(size: 15, weight: .bold, design: .serif))
                        .foregroundStyle(Color(hex: "#F5E6C8"))
                    Text("私人典藏书架 · \(books.count) 卷藏书")
                        .font(.system(size: 10, design: .serif))
                        .foregroundStyle(Color(hex: "#CBB393").opacity(0.8))
                }
            }

            Spacer()

            // Search Bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "#CBB393").opacity(0.6))

                TextField("在书架中搜索书名或作者...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "#F5E6C8"))

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(hex: "#CBB393").opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(width: 240)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(hex: "#E5C07B").opacity(0.25), lineWidth: 0.5)
            )

            // Import Button
            Button(action: onImportEPUB) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                    Text("导入 EPUB 电子书")
                        .font(.system(size: 12, weight: .medium, design: .serif))
                }
                .foregroundStyle(Color(hex: "#1E120A"))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    LinearGradient(
                        colors: [Color(hex: "#F3D084"), Color(hex: "#D4AF37")],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            .help("导入本地 EPUB 文件 (⌘ + O)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.25))
    }

    // MARK: - Empty Shelf Placeholder
    private var emptyShelfPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48))
                .foregroundStyle(Color(hex: "#E5C07B").opacity(0.4))
                .padding(.top, 40)

            Text("书架上暂时空空如也")
                .font(.system(size: 16, weight: .medium, design: .serif))
                .foregroundStyle(Color(hex: "#F5E6C8").opacity(0.8))

            Button("从电脑导入第一本 EPUB 电子书") {
                onImportEPUB()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: "#D4AF37"))
            .foregroundStyle(Color(hex: "#1E120A"))
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }
}

// MARK: - Single Shelf Row with Solid Wooden Plank
private struct SingleShelfRowView: View {
    let books: [EPUBBook]
    let isLastRow: Bool
    let onSelectBook: (EPUBBook) -> Void
    let onImportEPUB: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Books standing on top of shelf
            HStack(alignment: .bottom, spacing: 28) {
                ForEach(books) { book in
                    RealisticBookItemView(book: book) {
                        onSelectBook(book)
                    }
                }

                // If last row and there is space, show "+ 放入新书" slot
                if isLastRow && books.count < 4 {
                    AddBookSlotView(onImport: onImportEPUB)
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 2) // Sits directly on shelf surface

            // Physical Wooden Shelf Plank (实体厚质胡桃木架板)
            VStack(spacing: 0) {
                // Shelf Top Surface Depth (层板上平面)
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: "#5A3824"), // Light specular reflection on edge
                                Color(hex: "#3D2416"),
                                Color(hex: "#2C180E")
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 10)
                    .overlay(
                        // Top Highlight line simulating light catching the shelf lip
                        Rectangle()
                            .fill(Color(hex: "#8C5839").opacity(0.75))
                            .frame(height: 0.5),
                        alignment: .top
                    )

                // Shelf Front Beveled Edge (层板前立面)
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "#22130B"), Color(hex: "#160C06")],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 14)
                    .overlay(
                        // Bottom Bevel shadow
                        Rectangle()
                            .fill(Color.black.opacity(0.45))
                            .frame(height: 1),
                        alignment: .bottom
                    )

                // Deep Drop Shadow cast onto wall below
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.65),
                        Color.black.opacity(0.35),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 18)
            }
        }
    }
}

// MARK: - Add Book Slot
private struct AddBookSlotView: View {
    let onImport: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onImport) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        Color(hex: "#E5C07B").opacity(isHovered ? 0.6 : 0.25),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    .background(Color.black.opacity(isHovered ? 0.25 : 0.12))
                    .frame(width: 140, height: 204)

                VStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(Color(hex: "#E5C07B").opacity(isHovered ? 0.9 : 0.5))

                    Text("放入新书")
                        .font(.system(size: 12, weight: .medium, design: .serif))
                        .foregroundStyle(Color(hex: "#F5E6C8").opacity(isHovered ? 0.9 : 0.6))

                    Text("支持拖入 .epub")
                        .font(.system(size: 9))
                        .foregroundStyle(Color(hex: "#CBB393").opacity(0.4))
                }
            }
            .offset(y: isHovered ? -4 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("导入本地 EPUB 电子书到书架")
    }
}
