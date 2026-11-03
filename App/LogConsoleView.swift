import SwiftUI

// MARK: - Log Console View

struct LogConsoleView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var logger = AppLogger.shared
    @State private var filterLevel: LogLevel? = nil
    @State private var filterTag: String = "Tất cả"
    @State private var copied = false

    private var allTags: [String] {
        var seen = Set<String>()
        var tags = ["Tất cả"]
        for e in logger.entries {
            if !seen.contains(e.tag) { seen.insert(e.tag); tags.append(e.tag) }
        }
        return tags
    }

    private var filtered: [LogEntry] {
        logger.entries.filter { entry in
            let levelOK = filterLevel == nil || entry.level == filterLevel
            let tagOK = filterTag == "Tất cả" || entry.tag == filterTag
            return levelOK && tagOK
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // MARK: Filter Bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(title: "Tất cả", isSelected: filterLevel == nil) {
                            filterLevel = nil
                        }
                        ForEach(LogLevel.allCases, id: \.rawValue) { lvl in
                            FilterChip(
                                title: lvl.label,
                                color: lvl.color,
                                isSelected: filterLevel == lvl
                            ) {
                                filterLevel = (filterLevel == lvl) ? nil : lvl
                            }
                        }
                        Divider().frame(height: 24)
                        Picker("Tag", selection: $filterTag) {
                            ForEach(allTags, id: \.self) { tag in
                                Text(tag).tag(tag)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .background(.regularMaterial)

                Divider()

                if filtered.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "tray.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.tertiary)
                        Text("Chưa có nhật ký nào")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                        Text("Nhật ký sẽ xuất hiện khi bạn chạy các tính năng Auto, Sync, Proxy...")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered) { entry in
                        LogEntryRow(entry: entry)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .listRowSeparator(.hidden)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(entry.level.color.opacity(0.07))
                                    .padding(.vertical, 2)
                            )
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Nhật ký hoạt động")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Đóng") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = logger.allAsText()
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copied = false
                            }
                        } label: {
                            Label(
                                copied ? "Đã sao chép!" : "Sao chép",
                                systemImage: copied ? "checkmark" : "doc.on.doc"
                            )
                        }
                        .tint(copied ? .green : .blue)

                        Button(role: .destructive) {
                            logger.clear()
                        } label: {
                            Label("Xóa", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            }
        }
    }
}

// MARK: - Log Entry Row

struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: entry.level.symbol)
                    .foregroundStyle(entry.level.color)
                    .font(.caption.bold())

                Text(entry.tag.uppercased())
                    .font(.caption2.bold().monospaced())
                    .foregroundStyle(entry.level.color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(entry.level.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))

                Spacer()

                Text(entry.formattedTime)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            Text(entry.message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = entry.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let title: String
    var color: Color = .blue
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? color.opacity(0.18) : Color(uiColor: .secondarySystemFill))
                .foregroundStyle(isSelected ? color : .secondary)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(isSelected ? color : .clear, lineWidth: 1.2))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    LogConsoleView()
}

