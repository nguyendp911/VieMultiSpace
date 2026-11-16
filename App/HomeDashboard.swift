import SwiftUI

/// Bảng điều khiển tổng quan ở trang chủ: tình trạng trao đổi reaction, bài theo dõi và sức khỏe tài khoản.
struct HomeDashboardCard: View {
    @EnvironmentObject private var library: SpaceLibrary
    @ObservedObject private var exchange = ReactionExchangeManager.shared
    @ObservedObject private var health = AccountHealthMonitor.shared
    @ObservedObject private var tracker = TrackedPostManager.shared

    private var pending: Int { exchange.pendingTaskCount }

    private var partnerDone24h: Int {
        let cutoff = Date().addingTimeInterval(-86_400)
        return exchange.pairs.filter { $0.partnerTaskStatus == "done" && $0.createdAt > cutoff }.count
    }

    private var totalReactions: Int { tracker.posts.reduce(0) { $0 + $1.reactionCount } }

    private var healthText: String {
        health.results.isEmpty ? "—" : (health.badCount == 0 ? "Tốt" : "\(health.badCount) lỗi")
    }

    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                tile("bolt.fill", "Đã thả hôm nay",
                     "\(ExchangeSafety.doneToday())/\(ExchangeSafety.dailyCap)",
                     color: ExchangeSafety.pausedUntil != nil ? .red : .green)
                tile("clock.badge.exclamationmark", "Lệnh đang chờ", "\(pending)",
                     color: pending > 0 ? .orange : .gray)
                tile("person.2.fill", "Đối tác thả (24h)", "\(partnerDone24h)", color: .blue)
                tile("star.fill", "Điểm uy tín", "\(exchange.reputation?.score ?? 100)", color: .yellow)
                tile("chart.bar.doc.horizontal", "Bài theo dõi · 👍", "\(tracker.posts.count) · \(totalReactions)", color: .teal)
                tile("heart.text.square", "Sức khỏe tài khoản", healthText,
                     color: health.badCount > 0 ? .red : .green)
            }

            if ExchangeSafety.pausedUntil != nil {
                Label("Đang tạm dừng an toàn do gặp lỗi bất thường", systemImage: "pause.circle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(health.results.values.filter { $0.status.isBad }.sorted { $0.name < $1.name }) { h in
                Label("\(h.name): \(h.status.title)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await health.checkAll(spaces: library.spaces) }
            } label: {
                HStack(spacing: 6) {
                    if health.isChecking { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "stethoscope") }
                    Text("Kiểm tra token / cookie")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SoftTintedButtonStyle(tint: .trackerPrimaryDark, isCompact: true))
            .disabled(health.isChecking)
        }
        .padding(.vertical, 4)
        .task {
            if ExchangeConfig.isConfigured && exchange.pairs.isEmpty {
                await exchange.refresh(spaces: library.spaces, runTasks: false)
            }
            if health.results.isEmpty {
                await health.checkAll(spaces: library.spaces)
            }
        }
    }

    private func tile(_ icon: String, _ title: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.18)).frame(width: 30, height: 30)
                Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.subheadline.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 11))
    }
}
