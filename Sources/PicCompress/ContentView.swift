import SwiftUI
import UniformTypeIdentifiers

/// 窗口顶部留给交通灯的那一条净空。
///
/// **左右两栏都要让开它**，所以这个数字只在这里定义一次 ——
/// 两处各写一个 28，改的时候漏一处，那一栏的第一行就跑到灯底下去了。
let titleBarInset: CGFloat = 28

// MARK: - 主界面
//
// 改版（方案一「工作台」）的三条主线：
//
// 1. **窗口高度由内容决定**。旧版被右侧七组表单撑到 940，左边三张图只占顶部三分之一，
//    下面 600 多像素全是空的 —— 容器比内容大，是最刺眼的地方。
//    现在设置收进三张卡（第三张默认收起），高度 700；列表底下那片空白
//    改成了可拖入区，不再是死黑。
//
// 2. **品牌红只给主操作**。旧版屏幕上同时有六处红（按画质 / 高质量胶囊 /
//    保持原格式 / 保留原格式 / 暗色选中 / 调色室），六个红等于没有红。
//    现在选中态一律走中性浮起面，红色只剩「开始压缩」。
//
// 3. **间距分三级**：组内 8 / 组间 12 / 大区块 18。旧版清一色 10px，
//    从头到尾一条直线，眼睛没有落点。

struct ContentView: View {
    @StateObject private var model = AppModel()
    @StateObject private var bridge = ServiceBridge.shared
    @Environment(\.openWindow) private var openWindow
    @State private var isTargeted = false
    @State private var showOverwriteAlert = false

    var body: some View {
        VStack(spacing: 0) {
            // 左右两栏**并列**，没有谁压在谁头上。
            //
            // 霜白这一版两栏是**一虚一实**：左栏直接长在渐变画布上（透明），
            // 右栏是一块四周留了边的玻璃板。两者之间不再画线 ——
            // 板子的边缘自己就把两栏分开了（见下面的注释）。
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    titleBarGap
                    // 批次条归左栏：它说的是"这批图片"的事，
                    // 而右栏是参数区 —— 数字跟着图片走，参数跟着面板走。
                    if !model.items.isEmpty {
                        batchBar
                    }
                    browser
                }

                // 右栏是**一整块浮起的玻璃板**，四周留出边距让它真正"浮"在画布上。
                //
                // 两栏之间原来那条 1pt 竖线撤了：玻璃板自己的边缘（1px 白环 + 柔影）
                // 已经把两栏分开了，再补一条线只是在重复说同一件事 ——
                // 而且那条线要贯到窗口最上沿，会从板子的圆角外面穿过去。
                SettingsPanel(model: model)
                    .frame(width: Frost.railWidth - Frost.railInset)
                    .clipShape(RoundedRectangle(cornerRadius: Frost.radiusPanel,
                                                style: .continuous))
                    .frostPanel(Frost.radiusPanel)
                    .padding(.vertical, Frost.railInset)
                    .padding(.trailing, Frost.railInset)
            }
            hairline
            footer
        }
        .frame(minWidth: 980, minHeight: 620)
        // 标题栏是隐藏的，但系统仍然会在顶部留出 28pt 的安全区（就是红绿灯那一行）。
        // 不收回来，整个界面就会凭空矮一截，而左上角那块位置白白空着 ——
        // 让内容顶上去，再由左栏自己的 `titleBarInset` 让出这一条净空。
        //
        // **右栏不用让**：交通灯在窗口左上角，而那三颗灯离右栏还有几百点远，
        // 所以玻璃板上沿只让出 `railInset` 那 10pt。
        .ignoresSafeArea(edges: .top)
        // 霜白的**前提**：整窗铺一层冷调渐变（蓝紫两处光斑）。
        // 右栏那块玻璃板背后必须有东西可透 —— 背后若是空的，半透明底
        // 就只是一块灰板子，"浮起"这件事根本看不出来。
        //
        // `ignoresSafeArea` **必须写在这个 View 上**，不能只靠上面那句。
        // 这里踩过一次：`.background(Theme.window)` 走的是 **ShapeStyle 重载**，
        // 它默认就忽略安全区，所以颜色能一直铺到窗口最上沿；换成 `FrostCanvas()`
        // 这个 View 之后走的是另一条重载，**不忽略安全区** —— 顶部那 28pt 的
        // 交通灯让位区就空了出来，抓图上是一片透明（实测 alpha 0，改造前是 255）。
        .background(FrostCanvas().ignoresSafeArea())
        // 再垫一层不透明的兜底色。渐变那层已经把整窗盖住了，这一层只是保证
        // **窗口任何时刻都不是透明的** —— 缩放、切换外观的那一帧也不会闪。
        .background(Theme.window)
        // 外观由窗口自己拥有，见 `WindowConfigurator`。
        // 两个 sheet（对比视图、调色室）是挂在这个窗口上的子窗口，
        // 会从父窗口继承外观 —— 所以这一处设好，它们跟着对。
        .background(WindowConfigurator(mode: model.settings.appearance))
        .onAppear {
            // 关窗后点程序坞图标时，让 AppDelegate 能重新建出窗口
            AppDelegate.reopenWindow = { openWindow(id: WindowID.main) }
            DebugSnapshot.schedule(model: model)
            DebugSnapshot.scheduleReopenTest()
        }
        .onReceive(bridge.$incomingURLs) { urls in
            guard !urls.isEmpty else { return }
            model.add(urls: urls)
            bridge.consume()
        }
        .sheet(item: $model.comparing) { item in
            CompareView(item: item)
        }
        .sheet(isPresented: $model.showingGradeStudio) {
            GradeStudioView(model: model)
        }
        // 扫描报告。用 `isPresented` 而不是 `item:`：`ScanState` 里的进度
        // 每一秒都在变，而 `item:` 是靠标识判断"还是不是同一个东西"的 ——
        // 拿它挂一个持续变化的值，窗口会在扫描过程中被反复重建。
        .sheet(isPresented: scanBinding) {
            ScanSheet(model: model)
        }
        // 压完那份统计。它是**一次性的**（`RunReport` 里有 UUID），
        // 用 `item:` 正合适：新的一轮跑完自然换一个新报告。
        .sheet(item: $model.runReport, onDismiss: { model.reportDismissed() }) { report in
            StatsSheet(model: model, report: report)
        }
        .alert(overwriteTitle, isPresented: $showOverwriteAlert) {
            Button("取消", role: .cancel) {}
            Button(model.settings.effectiveGrade.isActive ? "我明白，替换" : "替换",
                   role: .destructive) { model.requestStart() }
        } message: {
            Text(overwriteMessage)
        }
        .alert("压缩完成", isPresented: serviceAlertBinding) {
            Button("好") { bridge.serviceSummary = nil }
            if let folder = model.lastOutputFolder {
                Button("显示结果") {
                    NSWorkspace.shared.open(folder)
                    bridge.serviceSummary = nil
                }
            }
        } message: {
            Text(bridge.serviceSummary ?? "")
        }
    }

    private var serviceAlertBinding: Binding<Bool> {
        Binding(
            get: { bridge.serviceSummary != nil },
            set: { if !$0 { bridge.serviceSummary = nil } }
        )
    }

    private var scanBinding: Binding<Bool> {
        Binding(
            get: { model.scan != nil },
            set: { if !$0 { model.cancelScan() } }
        )
    }

    // MARK: 覆盖原图的确认文案
    //
    // 挂了调色的覆盖是**另一回事**：平时覆盖只是"换成更小的同一张图"，
    // 挂了 LUT 就是"原图的像素被改掉了"。这两件事的确认语气必须不一样，
    // 所以标题、按钮文案、正文全都分开写。

    private var overwriteTitle: String {
        model.settings.effectiveGrade.isActive
            ? "确认替换原图，并应用调色？"
            : "确认直接替换原图？"
    }

    private var overwriteMessage: String {
        if model.settings.effectiveGrade.isActive {
            return """
            这次不只是把图压小 —— 当前的调色会一起写进原文件，原始像素会被永久改掉。
            调色是不可逆的，建议先复制一份原图，或者把输出方式换成「原目录加后缀」。

            只有确实变小的图片才会被替换。
            """
        }
        return "压缩结果会写回原文件。只有确实变小的图片才会被替换，没有变小的会原样保留。"
    }

    private var hairline: some View {
        Rectangle().fill(Theme.border).frame(height: 1)
    }

    // MARK: 交通灯让位
    //
    // 窗口没有标题栏（`titlebarAppearsTransparent` + 内容从窗口最顶端铺起），
    // 但系统那六颗灯还是浮在左上角，所以顶部必须让出一条净空 ——
    // 这 28pt 不是装饰，是**交通灯占掉的地**，不能再小。
    //
    // 让位区上空无一物了。原来这里有 52pt 的一条栏：标识 + 「图片批量压缩」+ 一颗「＋」。
    // 三样都撤了，各自有各自的理由：
    //
    // - **标识**：程序坞和 ⌘Tab 已经在显示它，窗口里再来一遍是冗余。
    //   中间试过四条路救它（缩小 / 换极简标记 / 收进胶囊 / 放大成线条版），
    //   最后选的是干脆不放。矢量定义留在 `AppLogo.swift`，没删。
    // - **标题**：窗口只有一个，标题说的又是程序坞里那个名字。写在这儿，
    //   唯一的作用是把 28pt 的让位区撑成一条真正的"栏"。
    // - **「＋」**：左栏末尾就有一条「拖更多图片到这里 / 选择文件…」，
    //   空态里还有一颗「选择文件…」。同一件事三个入口，多出来的那两个
    //   只是在跟主操作抢注意力 —— 删掉它，顶栏正好整条清空。
    //
    // 于是"顶栏"这个概念没有了，只剩下面这条让位。省下 24pt。
    private var titleBarGap: some View {
        Color.clear.frame(height: titleBarInset)
    }

    // MARK: 批次条

    /// 顶栏之下那一条：**这批多大、会压到多大**。
    ///
    /// 这里最要紧的不是数字，而是**数字是怎么来的**，三种状态必须能分辨：
    ///
    /// - 全压完了 → 用真实汇总，标「本次实测」
    /// - 还有没压的 → 拿最大的一张按当前设置真压一遍、按体积外推，标出抽样自哪张
    /// - 量不出来 → 右边整段留空（或写"正在量"），**绝不摆一个占位的数字**
    ///
    /// 最后一条是这个应用一直以来的规矩：够不到就说够不到。
    /// 一个看着精确的假数字比空着糟糕得多，因为它是用户决定按不按下去的依据。
    private var batchBar: some View {
        HStack(spacing: 9) {
            HStack(spacing: 9) {
                Text("\(model.items.count) 张")
                    .foregroundStyle(Theme.textPrimary)
                    .fontWeight(.semibold)
                Text("·")
                    .foregroundStyle(Theme.textTertiary)
                Text(Fmt.size(model.totalOriginalBytes))
                    .foregroundStyle(Theme.textPrimary)
                    .fontWeight(.semibold)
            }

            if let projected = model.projectedBatchBytes, projected > 0 {
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 1)

                Text(Fmt.size(projected))
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)

                savingPill(Fmt.savePercent(from: model.totalOriginalBytes, to: projected))
            } else if model.estimating {
                Text("正在量…")
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 8)

            Text(sourceNote)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                // 截尾而不是截中：前半段「按『高质量 85%』」是这句话的主干，
                // 扔掉它就只剩一个孤零零的文件名
                .truncationMode(.tail)
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .padding(.horizontal, Frost.padX)
        // 底下那道分隔线撤了。这一条说的是"这批图片"的事，它和下面的列表
        // 本来就是一件事，画条线反而把它读成了另一个区块。
        .frame(height: 42)
    }

    /// 「省 48%」那枚绿胶囊 —— 和底部 `savedBlock` 是同一套语言，
    /// 因为说的是同一件事，只是发生在压之前和压之后。
    private func savingPill(_ percent: Int) -> some View {
        Text("省 \(percent)%")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Theme.good)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(Theme.good.opacity(0.15)))
    }

    /// 右端那行来源说明。这条里**最该被看见的字**就是它 ——
    /// 同一个「5.8 MB」，是压出来的还是推出来的，可信度差得很远。
    private var sourceNote: String {
        if model.remaining == 0, model.projectedBatchBytes != nil {
            return "按「\(parameterSummary)」· 本次实测"
        }
        if let estimate = model.estimate {
            return "按「\(parameterSummary)」· \(estimate.sampleText)"
        }
        return "当前：\(parameterSummary)"
    }

    /// 这个数字是按什么参数算出来的。
    ///
    /// 写出来，"改完参数数字跟着变"才是可解释的；不写，它就只是屏幕上
    /// 一个会自己跳动的数，用户分不清那是重算还是抖动。
    private var parameterSummary: String {
        var parts: [String] = []

        if model.settings.sizeGoal == .quality {
            let percent = Int((model.settings.quality * 100).rounded())
            let preset = StrengthPreset.nearest(to: model.settings.quality)
            parts.append(preset.map { "\($0.title) \(percent)%" } ?? "\(percent)%")
        } else {
            parts.append("≤\(Fmt.compact(model.settings.targetBytes))")
        }

        // 和芯片、抽屉摘要**同源**（`FormatChoice.shortTitle`）—— 指路的名字
        // 和被指的那颗控件必须一个字不差。原来这里手抄了三个 `case`，
        // 加档位时漏一支是最容易发生、也最难自己发现的事。
        // `原格式` 不写进来：这一行说的是"我改了什么"，没改的那一项不占位置。
        if model.settings.format != .keep {
            parts.append(model.settings.format.shortTitle)
        }

        if model.settings.maxDimension > 0 {
            parts.append("≤\(model.settings.maxDimension)px")
        }
        if model.settings.effectiveGrade.isActive {
            parts.append("含调色")
        }

        return parts.joined(separator: " · ")
    }

    // MARK: 中部

    private var browser: some View {
        ZStack {
            // 不再自己铺一层不透明底色 —— 列表就长在画布上，
            // 铺了的话渐变到这儿就断了，右栏那块玻璃也就没了可透的东西。
            Color.clear

            if model.items.isEmpty {
                emptyState
            } else {
                // 左栏两段：列表（占满、内部滚动、末尾跟着导入条）/ 智能推荐横幅。
                //
                // 关键是**列表要吃掉所有剩余高度** —— 改版前是"列表 + 一个贪心
                // 撑开的虚线框"，那个框在有内容之后会把列表没吃掉的空白全吞下去
                // （实测 371pt，占左栏 65%），里面只有一行 12px 的灰字。
                VStack(spacing: 0) {
                    if let recommendation = model.visibleRecommendation {
                        recommendationBanner(recommendation)
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                    }
                    fileList
                }
            }

            if isTargeted {
                RoundedRectangle(cornerRadius: Frost.radiusCard, style: .continuous)
                    .strokeBorder(
                        Theme.accent,
                        style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: Frost.radiusCard, style: .continuous)
                            .fill(Theme.accent.opacity(0.07))
                    )
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            model.handleDrop(providers: providers)
        }
    }

    // MARK: 智能推荐

    private func recommendationBanner(_ recommendation: Recommendation) -> some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: Frost.radiusChip, style: .continuous)
                    .fill(Theme.wash(0.07))
                // 原来这个图标是红的。但它是块**提示**的装饰，不是可点的主操作 ——
                // 红在这里只是"醒目"，而醒目这件事上面那行文案已经做完了。
                // 改中性、提亮到 primary：看得见，但不跟底下的「开始压缩」抢。
                Image(systemName: recommendation.kind.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("这批图片主要是\(recommendation.kind.title)，建议换一套参数")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                Text("\(recommendation.reason)　\(recommendation.savingText)"
                     + "（涉及 \(recommendation.affectedCount)/\(recommendation.totalCount) 张）")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            Button("应用推荐") { model.applyRecommendation() }
                .buttonStyle(GhostButtonStyle())

            Button {
                model.dismissRecommendation()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Frost.radiusCard, style: .continuous)
                .fill(Theme.card)
                .shadow(color: Theme.shadow, radius: 9, y: 3)
        )
    }

    // MARK: 空状态

    /// 改版前这里是一个 104px 的 App 图标加一圈红色光晕 ——
    /// 那跟程序坞里那个图标是同一个东西，等于把桌面上的画又贴在窗口里；
    /// 而真正有用的信息（能拖什么、能不能拖文件夹、能右键）被压在
    /// 倒数第二行 10.5px 的灰字里。
    ///
    /// 现在：不重复程序坞图标，三条实用信息提成一行看得清的小字，
    /// 外面套一圈虚线框 —— 和列表底部那个"拖更多图片到这里"是同一套语言，
    /// 整块区域在两种状态下都是拖放目标。
    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(Theme.wash(0.06))
                    .frame(width: 62, height: 62)
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
            }

            Text("把图片拖到这里")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 14)

            HStack(spacing: 16) {
                fact("checkmark", "JPG · PNG · HEIC · TIFF · WebP")
                fact("folder", "文件夹会递归读取")
                fact("cursorarrow.click.2", "支持访达「快速操作」")
            }
            .padding(.top, 11)

            // 三颗都是 ghost：空态这一屏的"主操作"是**把图拖进来**，
            // 而不是这三颗里的任何一颗。给它们上品牌红，等于把
            // "该做什么"的答案从拖放区挪到了一颗次级按钮上。
            HStack(spacing: 9) {
                Button("选择文件…") { model.chooseFiles() }
                    .buttonStyle(GhostButtonStyle())

                Button("扫描文件夹…") { model.beginFolderScan() }
                    .buttonStyle(GhostButtonStyle())
                    .help("递归扫一遍，按体积挑出大图，确认之后再导入")
            }
            .padding(.top, 18)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Frost.radiusCard, style: .continuous)
                .strokeBorder(
                    Theme.dashed,
                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                )
                .padding(14)
                // 拖进来的时候外层会画一圈品牌红虚线，这两圈叠在一起太吵，
                // 所以自己先退下去
                .opacity(isTargeted ? 0 : 1)
        )
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
            Text(text)
                .font(.system(size: 10.5))
        }
        .foregroundStyle(Theme.textTertiary)
    }

    // MARK: 文件列表

    private var fileList: some View {
        GeometryReader { geo in
            ScrollView {
                // **必须是 `LazyVStack`**。这里原来是普通 `VStack`：
                // 它会把 `model.items` 里的每一行都**立刻造出来**——
                // 两千张就是两千个 `ImageRow`，每个都持有 `@ObservedObject`
                // 订阅，于是 `AppModel` 每一次 `@Published`（压缩时每张都发）
                // 都要把两千行重新求值一遍。
                //
                // 实测（`Scripts/measure-import.sh`，2000 张）：
                // 普通 VStack 峰值 1127MB、CPU 长时间 550~600%；
                // 换成惰性之后只造屏幕上真正看得见的那十来行。
                LazyVStack(spacing: Frost.rowGap) {
                    ForEach(model.items) { item in
                        ImageRow(item: item, model: model)
                    }
                    dropBar
                }
                .padding(.horizontal, Frost.padX)
                .padding(.top, 2)
                .padding(.bottom, 12)
                // 内容比视口矮时把这一沓撑到视口高度，但**子视图仍然靠顶排** ——
                // 于是列表底下那片空白就是留白本身，而不是被某个框框住的空盒子。
                .frame(minHeight: geo.size.height, alignment: .top)
            }
        }
    }

    /// 「继续加图」那一条。虚线**只包它**，而且它紧跟列表最后一行。
    ///
    /// 改版前这里是一整片虚线区域：列表底下所有空白都归它，实测 371pt
    /// （占左栏 65%），里面只有一行 12px 的灰字。那是为"空态"设计的尺寸，
    /// 有内容之后没跟着变 —— 还描了边，等于把这块空明确地画了出来。
    ///
    /// 现在两处都改了：高度回到 46pt，位置紧跟列表末尾。
    /// **不贴底**是有意的 —— 贴底会让它读起来像另一个区块，
    /// 而它其实是列表的自然延续（"这就是我，还想再加几张？"）。
    ///
    /// 顺便把它做成真的能点（原来只是个装饰，写着"选择文件…"却点不动）。
    private var dropBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.textTertiary)

            Text("拖更多图片到这里")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)

            Spacer(minLength: 8)

            // 两个入口各管一件事，谁也不遮谁：
            // 有明确目标 → 选择文件；不知道该挑哪个 → 先扫一遍。
            // 「扫描」那一颗单独存在的理由是它**先给报告再导入**，
            // 和"选择文件"直接塞进列表不是一回事。
            Button("选择文件…") { model.chooseFiles() }
                .buttonStyle(GhostButtonStyle())

            Button("扫描文件夹…") { model.beginFolderScan() }
                .buttonStyle(GhostButtonStyle())
                .help("递归扫一遍，按体积挑出大图，确认之后再导入")
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: Frost.radiusCard, style: .continuous)
                .fill(Theme.wash(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Frost.radiusCard, style: .continuous)
                .strokeBorder(
                    Theme.dashed,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
        )
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 11) {
            if model.isRunning {
                progressBlock
            } else if model.totalSavedBytes > 0 {
                savedBlock
            } else {
                Text(model.items.isEmpty
                     ? "还没有添加图片"
                     : (model.remaining > 0 ? "\(model.remaining) 张待压缩" : "全部处理完了"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer(minLength: 8)

            if model.isRunning {
                // 跑起来之后「清空」不该还在那儿（按下去只会毁掉正在跑的这一轮），
                // 它换成**唯一该有的那个出口**：停止。
                //
                // 停止在批边界生效 —— 已经压好的结果全部保留，不做回滚：
                // 那是用户已经等出来的东西，凭什么替他扔掉。
                if model.runBatchSize > 0 {
                    Button(pauseTitle) { model.requestPause() }
                        .buttonStyle(GhostButtonStyle())
                        .help(model.isPaused
                              ? "接着跑下一批"
                              : "跑完这一批就停在那儿，等你说了再继续")
                }

                Button("停止") { model.stopRun() }
                    .buttonStyle(GhostButtonStyle())
                    .help("跑完这一批就收工，已经压好的全部保留")

            } else if !model.items.isEmpty {
                Button {
                    model.clear()
                } label: {
                    HStack(spacing: 6) {
                        // 「开始压缩」有 `bolt.fill`，清空原来是一串光秃秃的字 ——
                        // 两颗并排时左轻右重，看着像随手放的。
                        // 补个图标，但它仍然是 ghost 层级（不填色、不加重），
                        // 不能因此比主操作显眼。
                        Image(systemName: "trash")
                            .font(.system(size: 10.5, weight: .medium))
                        Text("清空")
                    }
                }
                .buttonStyle(GhostButtonStyle())
            }

            // 「这次压缩会不会带上调色」必须写在按钮旁边。
            //
            // 调色是全局参数、会作用到整批，但这件事在主窗口里一直是隐形的 ——
            // 用户只能在调色室里看到它，回到主窗口按「开始压缩」时心里没底：
            // 到底带没带、带了几张？尤其覆盖模式下这是不可逆的，更要说清楚。
            if !model.isRunning, !model.items.isEmpty {
                gradingChip
            }

            // 压完之后，想改个参数再跑一遍是很正常的动作 ——
            // 降级成 ghost 放在主按钮旁边，但**必须存在**（见 `primaryButton`）。
            if !model.isRunning, !model.items.isEmpty, model.remaining == 0 {
                Button("重新压缩") { model.restart() }
                    .buttonStyle(GhostButtonStyle())
                    .help("用当前参数把这一批重新跑一遍")
            }

            primaryButton
        }
        .padding(.horizontal, Frost.padX)
        .frame(height: 58)
    }

    /// 主按钮 —— 它永远指向**此刻最该做的下一步**。
    ///
    /// 改版前它的禁用条件里带着 `model.remaining == 0`：压完之后它会把自己
    /// 关掉，用户刚干完活却面对一颗灰按钮，唯一的出路是旁边那颗次要的
    /// 「显示结果」。**这是一条死路**，而且是把人往次要操作上赶。
    ///
    /// 现在的规则：还有待压的 → 「开始压缩」；全压完了 → 「打开输出文件夹」
    /// （那才是此刻真正该做的事，原来的「显示结果」直接并进主按钮）；
    /// 一个输出都没有（全部跳过 / 失败）→ 「重新压缩」；
    /// **正在跑 → 这一格空着**（见下）。
    @ViewBuilder
    private var primaryButton: some View {
        if model.isRunning {
            // 正在跑的时候，这一格**不摆东西**。
            //
            // 原来这里是一颗灰掉的「处理中」：它是**状态**，不是动作，
            // 却占着一屏里最显眼的那一格 —— 看着就是一颗点不动的按钮，
            // 而那正是上面这条死路的老毛病换了个说法。
            //
            // 扫描报告那边为同一件事写过一条：正在跑时旁边那颗「取消」
            // 就是此刻全部需要的操作，不再多给一颗。这里同理 ——
            // 「跑到第几批、一共几批」左边那行和进度条已经在说，
            // 多一个「处理中」只会让"我按的那一下生效没有"更难回答。
            //
            // 红色跟着一起收走：那一格没有主操作，就不该有品牌红。
            EmptyView()

        } else if model.items.isEmpty || model.remaining > 0 {
            Button {
                if model.settings.outputMode == .overwrite {
                    showOverwriteAlert = true
                } else {
                    model.requestStart()
                }
            } label: {
                primaryLabel("bolt.fill", "开始压缩")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.items.isEmpty)

        } else if let folder = model.lastOutputFolder {
            Button {
                NSWorkspace.shared.open(folder)
            } label: {
                primaryLabel("folder", "打开输出文件夹")
            }
            .buttonStyle(PrimaryButtonStyle())
            .help(folder.path)

        } else {
            Button {
                model.restart()
            } label: {
                primaryLabel("arrow.clockwise", "重新压缩")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func primaryLabel(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
            Text(text)
        }
    }

    /// 压缩按钮左边那枚小胶囊：这批图会不会带上调色。
    @ViewBuilder
    private var gradingChip: some View {
        if model.settings.effectiveGrade.isActive {
            chipLabel(icon: "camera.filters", text: "\(model.items.count) 张含调色", tint: Theme.textSecondary)
                .help("这 \(model.items.count) 张都会先调色再压缩。想改参数回「调色室」，想撤掉用那边的「取消全部调色」")
        } else if model.settings.gradeBlockedByPristine {
            // 挂着调色、但被「无损保真」档挡住 —— 不写出来的话，
            // 用户会以为调色跟着一起压了，拿到图才发现颜色没变
            chipLabel(icon: "exclamationmark.triangle.fill",
                      text: "调色被档位挡住", tint: Theme.warn)
                .help("「无损保真」档承诺像素不变，和调色互斥。当前压缩不会带调色")
        }
    }

    private func chipLabel(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .semibold))
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(Theme.wash(0.09)))
    }

    /// 结果数字是**这个应用唯一的产出**，改版前它塞在左下角跟「清空」抢一行。
    /// 现在放大到 19px 圆体 + 绿色胶囊，让它成为底部的主角。
    private var savedBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("共省下")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.textTertiary)

            Text(Fmt.size(model.totalSavedBytes))
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)

            Text("−\(model.overallPercent)%")
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.good)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(Theme.good.opacity(0.15)))
        }
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(progressLine)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.isPaused ? Theme.warn : Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.wash(0.08))
                    Capsule()
                        .fill(Theme.accentGradient)
                        .frame(
                            width: geo.size.width *
                                CGFloat(model.batchCount == 0 ? 0 :
                                            Double(model.finishedCount) / Double(model.batchCount))
                        )
                }
            }
            .frame(height: 4)
        }
        .frame(width: 300, alignment: .leading)
    }

    /// 进度那一行。
    ///
    /// 「第 3 / 20 批」必须和「120 / 874 张」一起出现：前者回答"还要等几轮"，
    /// 后者回答"还要等几张"—— 分批的意义就是让这两个数都能被算出来，
    /// 只给一个总数的进度条，正是用户说"体验不好"的那个东西。
    private var progressLine: String {
        if model.isPaused {
            return "已暂停 · 第 \(model.batchRound) 批完成，共 \(model.batchCount) 张"
        }

        var text = "正在压缩 \(model.finishedCount) / \(model.batchCount)"
        if model.runBatchSize > 0 {
            text += " · 第 \(model.batchRound) / \(model.runBatchRounds) 批"
        }
        if model.pauseRequested {
            text += " · 本批结束后暂停"
        }
        return text
    }

    /// 「暂停」这颗按钮此刻该叫什么。
    ///
    /// 三个名字对应三种真实状态，不能省：按了之后还没到批边界时，
    /// 按钮上写着「暂停」而图还在压，用户只会以为按坏了 ——
    /// 那时候它该变成「取消暂停」，承认他的那一按已经被记下了。
    private var pauseTitle: String {
        if model.isPaused { return "继续" }
        return model.pauseRequested ? "取消暂停" : "暂停"
    }
}

// MARK: - 文件行

struct ImageRow: View {
    @ObservedObject var item: ImageItem
    @ObservedObject var model: AppModel

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            thumbnail

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let quality = item.usedQuality {
                        // 改版前这个是品牌红小胶囊。它只是一条信息，不是主操作 ——
                        // 屏幕上每少一个红，「开始压缩」就多一分份量。
                        Text("自动 q\(Int((quality * 100).rounded()))%")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 5)
                            .frame(height: 15)
                            .background(Capsule().fill(Theme.wash(0.09)))
                    }
                }

                Text(item.folder)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 10)

            sizeColumn

            statusBadge
                .frame(width: 74, alignment: .trailing)

            actionButtons
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: Frost.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Frost.radiusCard, style: .continuous)
                .fill(hovering ? Theme.cardHover : Theme.card)
                // 柔影**只挂在行底那块圆角矩形上**，不挂整行 ——
                // 挂整行的话文件名、体积这些字也会跟着投一层影，字就糊了。
                // 分层靠"卡片自己浮起来"，不靠描边（描边会让边缘发毛，暗色下尤其）。
                .shadow(color: Theme.shadow,
                        radius: hovering ? 13 : 9,
                        y: hovering ? 5 : 3)
        )
        // 不描边。
        //
        // 白卡压在窗口底（#E9E9ED）上，背景差已经足够交代边界；再描一道
        // 0.09 的黑只会让边缘发毛 —— 暗色下尤其糟，那是一道白线压在深底上。
        // 暗色里改用上缘那道 1px 内高光：卡片读起来是"刻出来"的，而不是"贴上去"的。
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.cardHighlight)
                .frame(height: 1)
                .padding(.horizontal, 14)
        }
        .onHover { hovering = $0 }
        // 缩略图跟着"看得见"走：露出来才解码，滚走了就还给系统。
        // `LazyVStack` 会在行离开视口一段距离后才销毁它，所以这两个回调
        // 天然带一点滞回，小幅滚动不会来回重解。
        .onAppear { model.requestThumbnail(for: item) }
        .onDisappear { model.releaseThumbnail(for: item) }
        .animation(.easeOut(duration: 0.13), value: hovering)
    }

    // MARK: 缩略图

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Frost.radiusChip, style: .continuous)
                .fill(Theme.wash(0.05))

            if let image = item.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: Frost.thumb, height: Frost.thumb)
        // 裁剪必须加在 frame **外面**。
        //
        // `aspectRatio(.fill)` 的语义是"放大到填满"，所以 16:9 的图在 44×44 的框里
        // 会被算成 78 宽 —— 而 `frame` 只改布局尺寸、**不裁绘制**，多出来的那截
        // 就这么横着溢出去了（实测风景那张缩略图比别的宽了近一倍，
        // 左边甚至顶到了列表外沿）。加在里面的 clipShape 裁的是图片自己的 bounds，
        // 而 bounds 本来就那么大，等于没裁。
        .clipShape(RoundedRectangle(cornerRadius: Frost.radiusChip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Frost.radiusChip, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    // MARK: 大小

    private var sizeColumn: some View {
        HStack(spacing: 6) {
            Text(Fmt.size(item.originalBytes))
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textSecondary)

            if item.outputBytes > 0, !isUnchanged {
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                Text(Fmt.size(item.outputBytes))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .monospacedDigit()
        .frame(width: 150, alignment: .trailing)
    }

    private var isUnchanged: Bool {
        if case .noChange = item.state { return true }
        return false
    }

    // MARK: 状态

    @ViewBuilder
    private var statusBadge: some View {
        switch item.state {
        case .pending:
            Text("待压缩")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)

        case .processing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.62)
                    .frame(width: 12, height: 12)
                Text("压缩中")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }

        case .done(_, let percent):
            if item.targetMissed {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text("未达标")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.warn)
            } else {
                Text(percent <= 0 ? "<1%" : "−\(percent)%")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.good)
                    .padding(.horizontal, 8)
                    .frame(height: 21)
                    .background(Capsule().fill(Theme.good.opacity(0.15)))
            }

        case .noChange:
            Text("已最优")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)

        case .grew:
            Text("未缩小")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.warn)

        case .skipped(let reason):
            Text(reason)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)

        case .failed(let reason):
            Text(reason)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.bad)
                .lineLimit(1)
        }
    }

    // MARK: 悬停操作

    private var actionButtons: some View {
        HStack(spacing: 6) {
            if hovering {
                if item.outputURL != nil {
                    iconButton("rectangle.split.2x1", help: "对比画质") {
                        model.comparing = item
                    }
                }
                if let output = item.outputURL {
                    iconButton("folder", help: "在访达中显示") {
                        model.revealInFinder(output)
                    }
                }
                iconButton("xmark", help: "移除") { model.remove(item) }
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func iconButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: Frost.radiusChip, style: .continuous)
                        .fill(Theme.wash(0.07))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
