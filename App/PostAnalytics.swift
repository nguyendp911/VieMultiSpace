import SwiftUI
import Charts
import UIKit

// MARK: - Lịch sử thống kê từng bài (để vẽ biểu đồ, so sánh, báo động)

struct PostStatSnapshot: Codable, Hashable, Identifiable {
    var date: Date
    var reactions: Int
    var comments: Int
    var shares: Int
    var id: Date { date }
}

final class PostStatsHistory {
    static let shared = PostStatsHistory()

    private let lock = NSLock()
    private var store: [String: [PostStatSnapshot]] = [:]
    private let maxPerPost = 300

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("post_stats_history.json")
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: [PostStatSnapshot]].self, from: data) {
            store = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func snapshots(for id: UUID) -> [PostStatSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return store[id.uuidString] ?? []
    }

    func last(for id: UUID) -> PostStatSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return store[id.uuidString]?.last
    }

    /// Ghi thêm một mốc. Bỏ qua nếu số liệu không đổi và mốc trước chưa quá 6 giờ.
    func append(id: UUID, reactions: Int, comments: Int, shares: Int) {
        lock.lock(); defer { lock.unlock() }
        var list = store[id.uuidString] ?? []
        if let last = list.last,
           last.reactions == reactions, last.comments == comments, last.shares == shares,
           Date().timeIntervalSince(last.date) < 6 * 3600 {
            return
        }
        list.append(PostStatSnapshot(date: Date(), reactions: reactions, comments: comments, shares: shares))
        if list.count > maxPerPost { list.removeFirst(list.count - maxPerPost) }
        store[id.uuidString] = list
        persist()
    }

    func remove(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        store[id.uuidString] = nil
        persist()
    }

    /// Chênh lệch so với mốc gần nhất cách đây ít nhất `days` ngày (hoặc mốc đầu tiên nếu lịch sử ngắn hơn).
    func delta(for id: UUID, days: Double, currentReactions: Int, currentComments: Int, currentShares: Int)
        -> (reactions: Int, comments: Int, shares: Int)? {
        let list = snapshots(for: id)
        guard !list.isEmpty else { return nil }
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        let base = list.last(where: { $0.date <= cutoff }) ?? list[0]
        return (currentReactions - base.reactions, currentComments - base.comments, currentShares - base.shares)
    }
}

// MARK: - Báo động: tụt tương tác / tăng đột biến

enum PostAlertEngine {
    static func evaluate(label: String, old: PostStatSnapshot, reactions: Int, comments: Int, shares: Int) -> [String] {
        var alerts: [String] = []
        if old.reactions >= 10, reactions <= Int(Double(old.reactions) * 0.8) {
            alerts.append("⚠️ \(label): reaction tụt \(old.reactions) → \(reactions)")
        }
        if old.comments >= 10, comments <= Int(Double(old.comments) * 0.8) {
            alerts.append("⚠️ \(label): bình luận tụt \(old.comments) → \(comments)")
        }
        if reactions - old.reactions >= max(20, old.reactions / 2) {
            alerts.append("🔥 \(label): reaction tăng đột biến \(old.reactions) → \(reactions)")
        }
        if comments - old.comments >= max(10, old.comments / 2) {
            alerts.append("🔥 \(label): bình luận tăng đột biến \(old.comments) → \(comments)")
        }
        if shares - old.shares >= max(10, old.shares / 2) {
            alerts.append("🔥 \(label): chia sẻ tăng đột biến \(old.shares) → \(shares)")
        }
        return alerts
    }

    static func label(for post: TrackedPostItem) -> String {
        let text = post.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Bài \(post.postId.suffix(6))" }
        return String(text.prefix(28))
    }
}

// MARK: - Biểu đồ tăng trưởng

struct PostGrowthChartView: View {
    let post: TrackedPostItem
    @Environment(\.dismiss) private var dismiss

    enum Metric: String, CaseIterable, Identifiable {
        case reactions = "Reaction"
        case comments = "Bình luận"
        case shares = "Chia sẻ"
        var id: String { rawValue }
    }

    @State private var metric: Metric = .reactions

    private var snaps: [PostStatSnapshot] { PostStatsHistory.shared.snapshots(for: post.id) }

    private func value(_ s: PostStatSnapshot) -> Int {
        switch metric {
        case .reactions: return s.reactions
        case .comments: return s.comments
        case .shares: return s.shares
        }
    }

    private var current: Int {
        switch metric {
        case .reactions: return post.reactionCount
        case .comments: return post.commentCount
        case .shares: return post.shareCount
        }
    }

    private func delta(days: Double) -> String {
        guard let d = PostStatsHistory.shared.delta(
            for: post.id, days: days,
            currentReactions: post.reactionCount, currentComments: post.commentCount, currentShares: post.shareCount
        ) else { return "—" }
        let v: Int
        switch metric {
        case .reactions: v = d.reactions
        case .comments: v = d.comments
        case .shares: v = d.shares
        }
        return v > 0 ? "+\(v)" : "\(v)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(PostAlertEngine.label(for: post)).font(.subheadline.bold())

                    Picker("", selection: $metric) {
                        ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 10) {
                        statTile("Hiện tại", "\(current)")
                        statTile("24 giờ", delta(days: 1))
                        statTile("7 ngày", delta(days: 7))
                    }

                    if snaps.count < 2 {
                        Text("Chưa đủ dữ liệu để vẽ biểu đồ. Hãy bấm \"Thống kê\" vài lần ở các thời điểm khác nhau, mỗi lần cập nhật sẽ thêm một mốc.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        Chart(snaps) { s in
                            LineMark(x: .value("Thời gian", s.date), y: .value(metric.rawValue, value(s)))
                                .foregroundStyle(Color.trackerPrimaryDark)
                                .interpolationMethod(.monotone)
                            PointMark(x: .value("Thời gian", s.date), y: .value(metric.rawValue, value(s)))
                                .foregroundStyle(Color.trackerPrimaryDark)
                        }
                        .frame(height: 240)
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }

                    if !snaps.isEmpty {
                        Text("Các mốc gần đây").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(snaps.suffix(8).reversed()) { s in
                            HStack {
                                Text(s.date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                                Spacer()
                                Text("👍 \(s.reactions)  💬 \(s.comments)  ↗ \(s.shares)").font(.caption.monospacedDigit())
                            }
                        }
                    }
                }
                .padding(14)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Biểu đồ tăng trưởng")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } } }
        }
    }

    private func statTile(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Xuất báo cáo CSV / PDF

struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

enum PostReportExporter {
    private struct Row {
        let account: String
        let postId: String
        let url: String
        let caption: String
        let reactions: Int
        let comments: Int
        let shares: Int
        let synced: String
        let dReactions: String
        let dComments: String
        let dShares: String
    }

    private static func signed(_ v: Int?) -> String {
        guard let v else { return "" }
        return v > 0 ? "+\(v)" : "\(v)"
    }

    private static func rows(for posts: [TrackedPostItem]) -> [Row] {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy HH:mm"
        return posts.map { p in
            let d = PostStatsHistory.shared.delta(
                for: p.id, days: 7,
                currentReactions: p.reactionCount, currentComments: p.commentCount, currentShares: p.shareCount
            )
            return Row(
                account: p.spaceName,
                postId: p.postId,
                url: p.postUrl,
                caption: String(p.caption.replacingOccurrences(of: "\n", with: " ").prefix(120)),
                reactions: p.reactionCount,
                comments: p.commentCount,
                shares: p.shareCount,
                synced: p.lastSyncedAt.map { f.string(from: $0) } ?? "",
                dReactions: signed(d?.reactions),
                dComments: signed(d?.comments),
                dShares: signed(d?.shares)
            )
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmm"
        return f.string(from: Date())
    }

    static func csv(posts: [TrackedPostItem]) -> URL? {
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["Tài khoản,Post ID,Link,Nội dung,Reaction,Bình luận,Chia sẻ,Cập nhật lúc,Δ Reaction 7 ngày,Δ Bình luận 7 ngày,Δ Chia sẻ 7 ngày"]
        for r in rows(for: posts) {
            lines.append([
                esc(r.account), esc(r.postId), esc(r.url), esc(r.caption),
                "\(r.reactions)", "\(r.comments)", "\(r.shares)", esc(r.synced),
                r.dReactions, r.dComments, r.dShares
            ].joined(separator: ","))
        }
        // BOM để Excel đọc đúng tiếng Việt
        let text = "\u{FEFF}" + lines.joined(separator: "\r\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BaoCaoTuongTac_\(stamp()).csv")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    static func pdf(posts: [TrackedPostItem]) -> URL? {
        let page = CGRect(x: 0, y: 0, width: 842, height: 595) // A4 ngang
        let data = rows(for: posts)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BaoCaoTuongTac_\(stamp()).pdf")

        let titleAttr: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 18)]
        let headAttr: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 9)]
        let cellAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8.5)]

        // Cột: tiêu đề, x, rộng
        let cols: [(String, CGFloat, CGFloat)] = [
            ("Tài khoản", 30, 110), ("Nội dung", 145, 290), ("Reaction", 440, 50), ("Cmt", 495, 40),
            ("Share", 540, 40), ("Δ React 7d", 585, 60), ("Δ Cmt 7d", 650, 55), ("Δ Share 7d", 710, 60), ("Cập nhật", 775, 60)
        ]

        let renderer = UIGraphicsPDFRenderer(bounds: page)
        do {
            try renderer.writePDF(to: url) { ctx in
                var y: CGFloat = 0
                func newPage() {
                    ctx.beginPage()
                    "Báo cáo tương tác bài viết".draw(at: CGPoint(x: 30, y: 24), withAttributes: titleAttr)
                    let f = DateFormatter()
                    f.dateFormat = "dd/MM/yyyy HH:mm"
                    "Xuất lúc \(f.string(from: Date())) · \(data.count) bài".draw(
                        at: CGPoint(x: 30, y: 48), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.gray]
                    )
                    for c in cols { c.0.draw(at: CGPoint(x: c.1, y: 72), withAttributes: headAttr) }
                    y = 90
                }
                newPage()
                for r in data {
                    if y > page.height - 40 { newPage() }
                    let values = [r.account, r.caption, "\(r.reactions)", "\(r.comments)", "\(r.shares)",
                                  r.dReactions, r.dComments, r.dShares, r.synced]
                    for (i, c) in cols.enumerated() {
                        let rect = CGRect(x: c.1, y: y, width: c.2 - 4, height: 22)
                        (values[i] as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                                     attributes: cellAttr, context: nil)
                    }
                    y += 24
                }
            }
            return url
        } catch {
            return nil
        }
    }
}
