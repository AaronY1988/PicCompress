import SwiftUI
import AppKit

/// 原图 vs 压缩结果的分屏对比。
///
/// 这块的意义在于把"画质有没有变差"从一句宣传变成可以自己验证的东西：
/// 拖动分界线看同一处细节，切到差异图看哪里变了，再看逐像素色差统计。
struct CompareView: View {
    let item: ImageItem
    @Environment(\.dismiss) private var dismiss

    enum Zoom: String, CaseIterable, Identifiable {
        case fit, actual, double
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fit: return "适应"
            case .actual: return "100%"
            case .double: return "200%"
            }
        }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case compare, diff
        var id: String { rawValue }
        var title: String { self == .compare ? "分屏对比" : "差异图" }
    }

    private enum DragMode { case divider, pan }

    @State private var source: CGImage?
    @State private var result: CGImage?
    @State private var stats: DiffStats?
    @State private var failed = false

    @State private var split: CGFloat = 0.5
    @State private var zoom: Zoom = .fit
    @State private var mode: Mode = .compare
    @State private var offset: CGSize = .zero
    @State private var dragMode: DragMode?
    @State private var panOrigin: CGSize = .zero

    private var backingScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            canvas
            hairline
            statsBar
            footer
        }
        .frame(width: 920, height: 640)
        // 霜白里**所有浮层都是同一块玻璃板**（右栏、五个 sheet 都是它）。
        // 这一张原来用 `Theme.window`（不透明底），留在这里会变成全 App
        // 唯一一块"实心"的浮层 —— 浮层只有一种长相。
        .background(Theme.glass)
        .task { await load() }
    }

    private var hairline: some View {
        Rectangle().fill(Theme.border).frame(height: 1)
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(item.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if item.graded {
                        HStack(spacing: 4) {
                            Image(systemName: "camera.filters")
                                .font(.system(size: 9, weight: .semibold))
                            Text("已调色")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        // 状态标记走中性浮起面。之前是红底红字，而列表里可能每一行
                        // 都挂着一个 —— 屏幕上的红一多，「开始压缩」就不显眼了。
                        // 「已调色」这三个字本身已经把话说清楚了，颜色只是装饰。
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 7)
                        .frame(height: 17)
                        .background(Capsule().fill(Theme.wash(0.11)))
                    }
                }

                HStack(spacing: 6) {
                    Text(Fmt.compact(item.originalBytes))
                        .foregroundStyle(Theme.textSecondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(Fmt.compact(item.outputBytes))
                        .foregroundStyle(Theme.good)
                    if let percent = item.savedPercent, percent > 0 {
                        Text("−\(percent)%")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.good)
                            .padding(.horizontal, 6)
                            .frame(height: 17)
                            .background(Capsule().fill(Theme.good.opacity(0.15)))
                    }
                }
                .font(.system(size: 11.5, weight: .medium))
            }

            Spacer()

            segmented(
                Mode.allCases.map { ($0.id, $0.title) },
                selected: mode.id
            ) { id in
                mode = Mode(rawValue: id) ?? .compare
                resetViewport()
            }

            segmented(
                Zoom.allCases.map { ($0.id, $0.title) },
                selected: zoom.id
            ) { id in
                zoom = Zoom(rawValue: id) ?? .fit
                offset = .zero
            }

            Button("关闭") { dismiss() }
                .buttonStyle(GhostButtonStyle())
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
    }

    private func segmented(
        _ items: [(String, String)],
        selected: String,
        action: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: 3) {
            ForEach(items, id: \.0) { id, title in
                let active = selected == id
                Button { action(id) } label: {
                    Text(title)
                        .font(.system(size: 11, weight: active ? .semibold : .regular))
                        // 选中态底下只是一层很淡的叠加色，不是品牌红。
                        // 所以文字不能写死白色 —— 亮色下那层叠加是灰的，白字会直接消失。
                        .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
                        .frame(height: 24)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(active ? Theme.wash(0.14) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.wash(0.05))
        )
    }

    // MARK: 画布

    private var canvas: some View {
        GeometryReader { geo in
            let box = CGSize(width: geo.size.width, height: geo.size.height)
            ZStack {
                Theme.backdrop

                if failed {
                    Text("读不出图片内容，无法对比")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    layers(box: box)
                    divider(box: box)
                }
            }
            .frame(width: box.width, height: box.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture(box: box))
        }
    }

    @ViewBuilder
    private func layers(box: CGSize) -> some View {
        if mode == .diff {
            if let image = stats?.diffImage {
                layer(image, box: box)
            } else {
                hint("正在逐像素比对…")
            }
        } else if let result {
            layer(result, box: box)

            if let source {
                layer(source, box: box)
                    .mask(alignment: .topLeading) {
                        Rectangle().frame(width: max(0, box.width * split))
                    }

                // 两侧标签
                // 角标压在照片上，底衬恒深 —— 用 Chip 里的恒定色，不跟界面外观翻。
                // 「已调色」以前是红色字：它只是在说明这张图带过调色，
                // 不是主操作也不是告警（真正的提醒在下面那行琥珀色小字里）。
                HStack {
                    tag("原图", tint: Chip.text)
                    Spacer()
                    tag(item.graded ? "压缩后 · 已调色" : "压缩后",
                        tint: item.graded ? Chip.text : Chip.good)
                }
                .padding(12)
                .allowsHitTesting(false)
            }
        } else {
            hint("正在解码…")
        }
    }

    private func layer(_ image: CGImage, box: CGSize) -> some View {
        let size = displaySize(image, box: box)
        return Image(nsImage: NSImage(cgImage: image, size: .zero))
            .interpolation(.high)
            .resizable()
            .frame(width: size.width, height: size.height)
            .frame(width: box.width, height: box.height)
            .offset(x: offset.width, y: offset.height)
    }

    private func displaySize(_ image: CGImage, box: CGSize) -> CGSize {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        switch zoom {
        case .fit:
            let scale = min(box.width / width, box.height / height, 3)
            return CGSize(width: width * scale, height: height * scale)
        case .actual:
            return CGSize(width: width / backingScale, height: height / backingScale)
        case .double:
            return CGSize(width: width * 2 / backingScale, height: height * 2 / backingScale)
        }
    }

    private func tag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(height: 21)
            .background(Capsule().fill(Chip.fill))
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.textSecondary)
    }

    @ViewBuilder
    private func divider(box: CGSize) -> some View {
        if mode == .compare, source != nil, result != nil {
            ZStack {
                Rectangle()
                    .fill(Chip.handleLine)
                    .frame(width: 1.5)

                Circle()
                    .fill(Chip.handle)
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Chip.handleMark)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
            }
            .frame(width: 34, height: box.height)
            .position(x: box.width * split, y: box.height / 2)
            .allowsHitTesting(false)
        }
    }

    // MARK: 拖拽

    private func dragGesture(box: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragMode == nil {
                    let dividerX = box.width * split
                    let nearDivider = abs(value.startLocation.x - dividerX) < 26
                    dragMode = (mode == .compare && nearDivider) ? .divider : .pan
                    panOrigin = offset
                }

                switch dragMode {
                case .divider:
                    split = min(1, max(0, value.location.x / max(1, box.width)))
                case .pan:
                    offset = CGSize(
                        width: panOrigin.width + value.translation.width,
                        height: panOrigin.height + value.translation.height
                    )
                case .none:
                    break
                }
            }
            .onEnded { _ in dragMode = nil }
    }

    private func resetViewport() {
        offset = .zero
        split = 0.5
    }

    // MARK: 色差统计

    private var statsBar: some View {
        HStack(spacing: 18) {
            if let stats {
                metric("平均色差", stats.meanText, tint: levelColor(stats.verdictLevel))
                metric("最大色差", "\(stats.maxDiff)", tint: levelColor(stats.verdictLevel))
                metric("明显变化像素", stats.changedText, tint: Theme.textSecondary)

                HStack(spacing: 7) {
                    // 挂了调色时不能照搬压缩画质的结论 —— 色差里绝大部分是调色
                    // 带来的，这时候说"建议提高质量档"是误导
                    // 这两处原本是 `accentSoft`（红）。但它们想表达的其实是**提醒**：
                    // "这个色差数字不能当压缩画质看"。红色在别处表示"这里是主操作"，
                    // 拿来当警示用会串味 —— 换成琥珀色，语义才对得上。
                    Image(systemName: item.graded
                          ? "info.circle.fill"
                          : (stats.verdictLevel == 0 ? "checkmark.seal.fill" : "info.circle.fill"))
                        .font(.system(size: 12))
                        .foregroundStyle(item.graded ? Theme.warn : levelColor(stats.verdictLevel))
                    Text(item.graded ? "已应用调色，色差主要来自调色" : stats.verdict)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                }

                Spacer()

                // 挂了调色时，色差里既有压缩损失也有调色的改动，
                // 不写清楚的话那句"肉眼分辨不出差别"会让人误解
                Text(item.graded ? "这个数字不能当压缩画质看" : stats.note)
                    .font(.system(size: 10))
                    .foregroundStyle(item.graded ? Theme.warn : Theme.textTertiary)
                    .lineLimit(1)
            } else {
                Text("正在计算色差…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background(Theme.panel)
    }

    private func metric(_ title: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
        }
    }

    private func levelColor(_ level: Int) -> Color {
        switch level {
        case 0: return Theme.good
        case 1: return Theme.good
        case 2: return Theme.warn
        default: return Theme.bad
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.draw")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            Text(mode == .compare
                 ? "拖动中间的分界线看同一处细节；在画面上拖动可以平移，缩放到 100% 以上更明显"
                 : "差异图把像素差值放大了 \(Int(ImageDiff.amplify)) 倍，越亮表示变化越大")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)

            Spacer()

            if item.outputURL != nil {
                Button("在访达中显示") {
                    if let url = item.outputURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    // MARK: 载入

    private func load() async {
        guard let output = item.outputURL else {
            failed = true
            return
        }
        let sourceURL = item.url

        let decoded = await Task.detached(priority: .userInitiated) {
            (ImageCompressor.fullImage(for: sourceURL), ImageCompressor.fullImage(for: output))
        }.value

        guard let a = decoded.0, let b = decoded.1 else {
            failed = true
            return
        }
        source = a
        result = b

        let computed = await Task.detached(priority: .utility) {
            ImageDiff.compare(a, b)
        }.value
        stats = computed
    }
}
