import SwiftUI

// MARK: - 扫描报告
//
// 「先看再决定」的那张纸：把一个文件夹翻一遍，把找到的图**带着体积**摆出来，
// 让用户挑完再进列表。
//
// 阈值**先在本地草稿上改**，点「导入」才提交。
// 和调色室同一条规矩：滑杆一动就直写全局设置，会在用户还在比较的时候
// 就把事情定下来了，而且"应用"那颗按钮永远是假的。

// MARK: - 内容高度探针
//
// 内容区要不要滚、滚多高，取决于内容自己有多高 —— 而那个数只有量了才知道。
// 放在文件作用域（而不是塞进 `ScanSheet`）是因为 `PreferenceKey` 的
// `defaultValue` 必须是静态的。
private struct SheetContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ScanSheet: View {

    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var thresholdText = ""
    @State private var thresholdUnit: SizeUnit = .mb
    @FocusState private var thresholdFocused: Bool

    /// 内容区量出来的高度。见 `bodyHeight`。
    @State private var contentHeight: CGFloat = 0

    private var state: ScanState? { model.scan }

    // MARK: 外壳

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline

            // 内容区**可以滚，而且有上限**。
            //
            // 之前它是裸的 VStack，高度完全由内容决定。sheet 是挂在上沿往下长的，
            // 内容一高过屏幕能放下的高度，超出去的部分就被系统裁掉 ——
            // **裁掉的恰恰是最底下的页脚**：实测用户那张截图里，说明文字从
            // 「取消 / 导入」两颗按钮底下透出来，最下面一行整个看不见。
            //
            // 现在：内容比上限矮就照旧按内容收（大多数时候还是那个高度自适应的
            // sheet），超过上限就在里面滚，页脚永远钉在最下面。
            ScrollView(.vertical, showsIndicators: true) {
                Group {
                    if let state {
                        switch state.phase {
                        case .scanning(let done, let total):
                            scanning(done: done, total: total)
                        case .failed(let why):
                            failed(why)
                        case .ready:
                            report(state)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(minHeight: bodyFloor, alignment: .top)
                // 量内容自己的高度（ScrollView 里给的是"想要多高"，不受窗口限制）
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: SheetContentHeight.self, value: geo.size.height)
                    }
                )
            }
            .frame(height: bodyHeight)
            // "下面还有"的提示。
            //
            // macOS 的滚动条默认是 overlay 式的：**不滚就不出现**。所以
            // "内容区在内部滚动"这件事，在静止的画面上一点都看不出来 ——
            // 截图上就是最下面那张卡片被齐刷刷切掉一条边，看着更像渲染坏了，
            // 而不是"还有内容"。
            //
            // 26pt 的渐隐同时解决两件事：点出"下面还有"，且把那条硬切口化掉。
            // 只在真的滚得起来时才出现，内容装得下的时候它不存在。
            .overlay(alignment: .bottom) {
                if isScrollable {
                    LinearGradient(
                        colors: [Theme.glass.opacity(0), Theme.glass],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 26)
                    .allowsHitTesting(false)
                }
            }

            hairline
            footer
        }
        .frame(width: 560)
        // sheet 自己就是一块**浮起的玻璃板** —— 这是霜白里"浮层"的唯一长相。
        .background(Theme.glass)
        .onAppear { syncThreshold() }
        .onPreferenceChange(SheetContentHeight.self) { contentHeight = $0 }
    }

    /// 内容区实际给多高：内容多高就多高，但封顶。
    ///
    /// 首帧还没量出来时用 `bodyFloor` 兜一下，避免先渲成一个 0 高度的空壳
    /// 再跳开 —— 那一下是很明显的闪。
    private var bodyHeight: CGFloat {
        min(max(contentHeight, bodyFloor), Self.maxBodyHeight)
    }

    /// 内容装不下 = 里面在滚。滚动提示只在真的滚起来时出现。
    ///
    /// 判断放在这里而不是各调用处，是因为"装得下"的定义就在上一行：
    /// 内容比封顶矮时，`bodyHeight` 等于内容自己，那就不该有提示。
    private var isScrollable: Bool {
        contentHeight > bodyHeight + 1
    }

    /// 内容区的天花板。
    ///
    /// 一个 sheet 是**从父窗口上沿往下长**的，所以它能用多少高度 =
    /// 「父窗口上沿到屏幕下沿」那一段，减去头部和页脚 —— 而不是屏幕总高。
    ///
    /// 原来这里是一个死数 `screen - 320`：本机 visibleFrame 764pt，算出来
    /// 只有 444pt，于是内容长的那一屏**永远在滚**，哪怕窗口贴着屏幕顶端、
    /// 下面明明有富余。死数的问题在于它对"窗口在哪儿"一无所知，
    /// 而矮屏上又必须保守 —— 于是两种情况下它都选错。
    ///
    /// 改完这条之后，`maxBodyHeight` 仍然**永远不会让 sheet 长出屏幕**：
    /// 窗口上沿在 `anchorY`，往下到屏幕下沿就是 `anchorY - screen.minY`，
    /// 减掉固定的 chrome 就是内容能用的全部。
    ///
    /// `PICCOMPRESS_SCAN_CAP` 是开发期的压顶开关，只为让"内容比屏幕高"
    /// 这一屏能被**真的看到** —— 本机窗口摆在偏上的位置时算出来够装下，
    /// 不压一下根本滚不起来，那段修法就等于没验过。
    private static var maxBodyHeight: CGFloat {
        if let raw = ProcessInfo.processInfo.environment["PICCOMPRESS_SCAN_CAP"],
           let value = Double(raw), value >= 100 {
            return value
        }
        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let anchorY = NSApp.windows
            .first { !$0.isSheet && $0.isVisible && $0.contentView != nil }?
            .frame.maxY ?? screen.maxY
        // 头部 66 + 页脚 62 + 两条 hairline + 余量（窗口投影、坐标取整）
        let chrome: CGFloat = 66 + 62 + 2 + 10
        return max(240, anchorY - screen.minY - chrome)
    }

    private var hairline: some View {
        Rectangle().fill(Theme.border).frame(height: 1)
    }

    /// 内容区的地板高度。
    ///
    /// 只有**进度态**需要它：那一屏的字每秒都在变（"正在扫 128 / 940"），
    /// 不给个固定高度，窗口就会跟着数字一位一位地抖。
    ///
    /// 其余各屏一律按内容收 —— 一句"扫描没能完成"下面拖着几百点的空白，
    /// 读起来像"下面还有东西没加载出来"，而这块界面本来就正是"下面该有东西"
    /// 的地方（正常时会有一份完整报告），留白在这里是会被误读的。
    private var bodyFloor: CGFloat {
        guard let phase = state?.phase else { return 240 }
        switch phase {
        case .scanning: return 240
        case .ready, .failed: return 0
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if let caption = state?.source.caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 15)
    }

    private var title: String { "扫描文件夹" }

    // MARK: 扫描中

    /// 文件夹扫描给不出进度（要遍历完才知道总数），所以这里只有一句"正在扫"，
    /// 进度条只在拿到总数时才出现。
    private func scanning(done: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(total > 0
                     ? "正在扫 \(done) / \(total)…"
                     : "正在扫…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textPrimary)
            }
            if total > 0 {
                bar(fraction: Double(done) / Double(max(1, total)))
            }
            Text("只读体积和文件名，一张图都还没有加载进来。")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func bar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.wash(0.08))
                Capsule()
                    .fill(Theme.accentGradient)
                    .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
    }

    // MARK: 出错

    private func failed(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.bad)
                Text("扫描没能完成")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            Text(why)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 报告

    @ViewBuilder
    private func report(_ state: ScanState) -> some View {
        let current = reportValue(state)

        VStack(alignment: .leading, spacing: 16) {
            summary(current)

            // 「这次有多少没问到」紧跟在做结论的数字旁边。
            //
            // 放最底下的话要滚很久才看得见 —— 而这恰恰是用户
            // **在调阈值之前**就该知道的事：下面这些数字里有多少是猜的。
            // 不拦路，但必须在场。
            if !state.notes.isEmpty {
                notes(state.notes)
            }

            thresholdField
            outcome(current)

            // 照片多到一定程度才给这个选项：三张图谈"分批"是噪声，
            // 而几百上千张的时候它是**用户最需要先回答的那个问题**。
            if current.kept.count > BatchPlan.smallestOption {
                batchField(current)
            }

            if !current.keptGroups.isEmpty {
                formatBreakdown(current)
            }
        }
    }

    /// 扫描的"诚实缺口" —— 哪些数字是没问出来、只能降级的。
    ///
    /// 用琥珀不用红：它不是错误，路还能走。也不能用灰 ——
    /// 这块界面里到处都是灰色说明文字，会被眼睛直接跳过，
    /// 而"有 320 张读不到体积"是不该被跳过的一句。
    private func notes(_ list: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(list, id: \.self) { note in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.warn)
                        .padding(.top, 1.5)
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Frost.radiusChip, style: .continuous)
                .fill(Theme.wash(0.05))
        )
    }

    private func summary(_ report: ScanReport) -> some View {
        HStack(spacing: 6) {
            Text("找到")
                .foregroundStyle(Theme.textTertiary)
            Text("\(report.total)")
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textPrimary)
            Text("张图片 ·")
                .foregroundStyle(Theme.textTertiary)
            Text(Fmt.size(report.totalBytes))
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textPrimary)

            // 把"翻到了几层"也说出来。
            //
            // 用户的原话是"有些子文件夹里有文件，有些里面有图片" —— 他担心的正是
            // 递归有没有真的走到底。写一个数字，比让他去列表里逐条核对强得多。
            if report.folderCount > 1 {
                Text("· 来自 \(report.folderCount) 个子文件夹")
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5))
        .monospacedDigit()
    }

    /// 阈值输入。
    ///
    /// 这里**允许 0**，而且 0 的含义写在脸上（"全部都要"）——
    /// 因为在设置面板那个「目标体积」输入框里 0 是非法值，
    /// 两个框长得像、约束却相反，不写清楚用户会以为打错了。
    ///
    /// 措辞是"不小于"而不是"大于"：`ScanReport.kept` 用的是 `bytes >= threshold`，
    /// 正好一张 1.00 MB 的图写"大于 1 MB"就该被筛掉、写"不小于"才该留下。
    /// 右边那颗「≥ 1 MB」也是这个意思 —— 两句话必须说同一件事。
    private var thresholdField: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("只收不小于")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)

                TextField("", text: $thresholdText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 62)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: Frost.radiusChip, style: .continuous)
                            .fill(Theme.wash(0.06))
                    )
                    .focused($thresholdFocused)

                ForEach(SizeUnit.allCases) { unit in
                    ChoiceChip(title: unit.title, selected: thresholdUnit == unit) {
                        thresholdUnit = unit
                    }
                    .frame(width: 46)
                }

                Text("的图片")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)

                Spacer(minLength: 0)

                Text(thresholdNote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(parsedThreshold == nil ? Theme.bad : Theme.textTertiary)
            }

            // 常驻这一行，不是"用到才出现"。
            //
            // 0 在这里是合法值（= 不筛），而设置面板里那个长得很像的
            // 「目标体积」输入框是**不许填 0** 的 —— 两个框长一样、规矩相反，
            // 不把这条写在脸上，用户第一次来只会以为打错了。
            Text(parsedThreshold == 0 ? "0 = 不筛，全都收进来" : "填 0 就不筛")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// 输入框右边那句"这行数字算成了多少"。
    ///
    /// **必须和输入框用同一套单位制** —— 走 `SizeText`（1024 进制），
    /// 因为它就是解析输入的那个函数。这里原来用的是 `Fmt.size`（十进制，
    /// 那个是给**磁盘文件体积**用的，跟 Finder 对齐），于是输入框里打「4」、
    /// 右边却写着「≥ 4.2 MB」，同一个意思摆出两个数，用户只能怀疑自己看错了。
    ///
    /// 两套进制各有各的地方，但不能混在同一句话里。
    private var thresholdNote: String {
        guard let bytes = parsedThreshold else { return "数值不对" }
        return bytes == 0 ? "全部都要" : SizeText.thresholdLabel(bytes)
    }

    /// 这行是**整个报告最要紧的一句**：筛完还剩多少、筛掉了多少。
    ///
    /// 只写"符合条件 42 张"，用户不知道剩下那些去哪了 —— 会怀疑是不是漏扫了。
    /// 两边都写出来，"筛"才是一个他能放心的动作。
    private func outcome(_ report: ScanReport) -> some View {
        HStack(spacing: 6) {
            Text("符合条件")
                .foregroundStyle(Theme.textTertiary)
            Text("\(report.kept.count) 张")
                .fontWeight(.bold)
                .foregroundStyle(Theme.textPrimary)

            // 一张都没收进来时**不写这个体积**。
            //
            // 它算出来是 0，而 `Fmt.size(0)` 返回的是一根破折号 ——
            // 于是这一行会读成「符合条件 0 张 · —（体积不够 8745 张）」。
            // 那根破折号不是"零"，它是一个占位符，而这里根本没有需要占的位。
            if !report.kept.isEmpty {
                Text("· \(Fmt.size(report.keptBytes))")
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.textPrimary)
            }

            if let reasons = skipReasons(report) {
                Text(reasons)
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .monospacedDigit()
    }

    private func skipReasons(_ report: ScanReport) -> String? {
        guard !report.skipped.isEmpty else { return nil }
        return "（体积不够 \(Fmt.count(report.skipped.count)) 张 · "
            + "\(Fmt.size(report.skippedBytes))）"
    }

    /// 分批压缩的档位。
    ///
    /// 只在张数够多时出现（见调用处）。它是这一屏唯一一个**关于"待会儿怎么跑"
    /// 而不是"收哪些图"**的问题，所以放在"符合条件 N 张"的正下方 ——
    /// 用户刚看完那个数字，紧接着就被问"这些要一次跑完还是分几批"，
    /// 是这个问题最该被问出来的时刻。
    private func batchField(_ report: ScanReport) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("分批压缩")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)

                ForEach(BatchPlan.options, id: \.self) { size in
                    ChoiceChip(
                        title: BatchPlan.label(size),
                        selected: model.settings.batchSize == size
                    ) {
                        model.settings.batchSize = size
                    }
                    .frame(width: 84)
                }

                Spacer(minLength: 0)
            }

            // 这一行要同时说清两件事：**怎么分批**和**分批不影响什么**。
            // 后者比前者重要 —— 用户看到"分批"最容易担心的是
            // "是不是会分几次压、压出来两次不一样"，而答案是不会。
            Text(batchHint(report.kept.count))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .monospacedDigit()
        }
    }

    private func batchHint(_ total: Int) -> String {
        let size = model.settings.batchSize
        guard size > 0, total > size else {
            return "一次跑完；跑起来之后也可以叫停，已经压好的都留着"
        }
        return "共 \(BatchPlan.count(total: total, size: size)) 批，"
            + "每批之间可以停下来看看结果 · 不影响画质，只是把活切成几段"
    }

    private func formatBreakdown(_ report: ScanReport) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("按格式")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)

            ForEach(report.keptGroups.prefix(5)) { group in
                HStack(spacing: 8) {
                    Text(group.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 54, alignment: .leading)
                    Text("\(group.count) 张")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 52, alignment: .trailing)
                    Text(Fmt.size(group.bytes))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 70, alignment: .trailing)
                    Spacer(minLength: 0)
                }
                .monospacedDigit()
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Frost.radiusCard, style: .continuous)
                .fill(Theme.card)
                .shadow(color: Theme.shadow, radius: 9, y: 3)
        )
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 11) {
            if let state, case .ready = state.phase {
                let current = reportValue(state)
                Text(footnote(current))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 8)

            Button("取消") { model.cancelScan() }
                .buttonStyle(GhostButtonStyle())
                .disabled(isBusy)

            primaryButton
        }
        .padding(.horizontal, 22)
        .frame(height: 62)
    }

    private func footnote(_ report: ScanReport) -> String {
        if report.kept.isEmpty {
            if report.total == 0 { return "这个文件夹里没有图片" }
            // 一张都没收进来时，最该说的是**为什么**。
            return "把数值调小一点就能收进来"
        }
        // `.max` 而不是 `.first`：候选是按**路径**排的（同一个目录扫两次顺序要一致），
        // 而"最大的一张"跟路径一点关系都没有 —— 拿 first 会挑出字母序最靠前那张，
        // 图上写着 2.6 MB 而列表里明明有 5.3 MB 的。
        if let biggest = report.kept.max(by: { $0.bytes < $1.bytes }) {
            return "最大的一张 \(biggest.name) · \(Fmt.size(biggest.bytes))"
        }
        return ""
    }

    /// 主按钮：**每一屏都要指向此刻真正能走的那一步**。
    ///
    /// 之前这里在非就绪态一律摆一颗灰掉的「导入」当占位 —— 于是在"扫描失败"
    /// 那一屏上，用户面对的是一颗写着"导入"、按不动、也说不清按下去会发生
    /// 什么的按钮；而那一屏**确实有**一个该做的动作。
    /// 占位不该占在整张窗口最显眼的位置上。
    @ViewBuilder
    private var primaryButton: some View {
        if let state {
            switch state.phase {
            case .ready:
                readyButton(state)

            case .failed:
                Button("重试") { retry() }
                    .buttonStyle(PrimaryButtonStyle())

            case .scanning:
                // 正在跑：旁边那颗「取消」就是此刻全部需要的操作，不再多给一颗
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func readyButton(_ state: ScanState) -> some View {
        let current = reportValue(state)

        if current.kept.isEmpty {
            // 真的没有下一步可走（这张列表里没有一张够条件）。
            // 文案要**说实话**，别再写一个"导入这 0 张"—— 那既不是动作也不是解释。
            Button("没有符合条件的图片") {}
                .buttonStyle(PrimaryButtonStyle())
                .disabled(true)
        } else {
            Button {
                commit(current)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("导入这 \(current.kept.count) 张")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    /// 原样再扫一次。来源还在 `ScanState` 里，不用回上层去问。
    private func retry() {
        guard case .folder(let url) = state?.source else { return }
        model.beginFolderScan(at: url)
    }

    private var isBusy: Bool {
        guard let phase = state?.phase else { return true }
        switch phase {
        case .scanning: return true
        default: return false
        }
    }

    // MARK: 草稿

    private func reportValue(_ state: ScanState) -> ScanReport {
        var value = ScanReport(source: state.source, candidates: state.candidates)
        value.threshold = parsedThreshold ?? 0
        return value
    }

    /// 解不出来给 `nil`（界面上标"数值不对"），**不是 0** —— 见 `SizeText.bytes`。
    private var parsedThreshold: Int64? {
        SizeText.bytes(thresholdText, unit: thresholdUnit)
    }

    private func syncThreshold() {
        let field = SizeText.field(model.settings.scanMinBytes)
        thresholdText = field.text
        thresholdUnit = field.unit
    }

    private func commit(_ report: ScanReport) {
        thresholdFocused = false
        // 阈值写进设置：下次打开报告时还是这个数。
        // 它只影响**默认勾选谁**，不影响已经在列表里的图。
        model.settings.scanMinBytes = report.threshold
        model.confirmScan(report.kept)
    }
}
