import SwiftUI

// MARK: - 设置面板（右栏）
//
// 改版前的三条问题，这里逐条对应：
//
// 1. **容器比内容大**。窗口被右侧七组表单撑到 940 高，左边三张图只占顶部三分之一，
//    下面 600 多像素全是空的。根因是把"长表单"和"短列表"绑在同一个高度上。
//    现在只有三张卡：压缩目标（主控）、输出方式、更多设置（默认收起）——
//    高度降到 700，列表底下那片空白改成了可拖入区。
//
// 2. **每组只是一条线**。七组、二十多个控件平铺在 320 宽的窄栏里，
//    组与组之间只有一条 1px 分隔线。现在每组是一张卡片，边界自己交代。
//
// 3. **红色被当成选中态用了六次**。六个红等于没有红。所有选中态改走
//    `ChoiceChip` / `SegmentBar` / `RadioOption`（中性浮起面 + 字重加深），
//    品牌红只剩「开始压缩」一处。

struct SettingsPanel: View {
    @ObservedObject var model: AppModel

    private static let drawerID = "more-settings"

    @State private var targetValue = "500"
    @State private var targetUnit = 0          // 0 = KB，1 = MB
    @State private var moreExpanded = false
    @State private var drawerHovering = false

    /// 目标体积那一栏正在被输入。
    ///
    /// 这个标记是必须的：输入时每敲一个字都会提交一次设置，设置一变就会触发
    /// 下面的 `syncTargetField()` 把输入框规范化 —— 用户打到一半的
    /// "1"、"1."、"1.5" 会被改写成 "512" 之类，等于把人的输入吞掉了。
    @FocusState private var targetFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: true) {
                mergedCard
                    .padding(.horizontal, Frost.padX)
                    // 顶部这一条是交通灯的让位区（`titleBarInset`）。
                    //
                    // 右栏的底色铺到窗口最上沿之后，这一条就**不能**用 padding 之外
                    // 的办法让 —— 试过 `safeAreaInset`，它只是个不遮挡的占位，
                    // 内容上滚时会从交通灯底下穿过去。
                    // 玻璃板自己已经从窗口顶端让开 10pt，交通灯又在**左栏**那边，
                    // 所以这里不用再让一整条 28pt 的净空 —— 让了的话
                    // 右栏第一组设置会比左栏的列表低一大截，两栏从顶上就错开了。
                    .padding(.top, 16)
                    .padding(.bottom, 16)
            }
            .onChange(of: moreExpanded) { expanded in
                guard expanded else { return }
                // 展开后有近 400pt 内容落在视口外。不滚一下的话，
                // 点了之后屏幕上只多出一行"输出格式"，用户会以为没反应。
                //
                // 对齐**底部**而不是顶部：抽屉现在是合并卡的最后一段，
                // 对齐顶部会让「压缩目标」和「输出方式」整个移出视口，
                // 屏幕上只剩展开的五组 —— 看着像换了个界面。
                // 对齐底部刚好让新展开的内容进来，上面还留着上一段的尾巴，
                // 卡片没被"切断"。
                withAnimation(.easeOut(duration: 0.26)) {
                    proxy.scrollTo(Self.drawerID, anchor: .bottom)
                }
            }
        }
        // 底色由外面那层玻璃板给（`ContentView` 上的 `.frostPanel`）。
        //
        // 这里**绝不能**再铺一层不透明的 `Theme.panel` —— 铺了就把玻璃盖死，
        // 右栏看着和左栏一样是块实心板，"浮起来"这件事整个没了。
        //
        // 顺带，原来那条盖住交通灯让位区的遮罩也撤了：让位区在**左栏**顶上，
        // 右栏离那三颗灯还有 700pt 远，不存在"卡片从灯底下钻过去"这回事。
        .opacity(model.isRunning ? 0.5 : 1)
        .disabled(model.isRunning)
        .animation(.easeOut(duration: 0.2), value: model.isRunning)
        .onAppear {
            syncTargetField()
            // 出图钩子：`PICCOMPRESS_MORE=1` 时**延迟**展开，而不是把它设成初值。
            //
            // 设成初值的话 `onChange` 不会触发，等于绕过了"展开 → 自动滚过去"
            // 这条真实路径 —— 那样截出来的图是好看，但测的是另一段代码。
            if ProcessInfo.processInfo.environment["PICCOMPRESS_MORE"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    moreExpanded = true
                }
            }
        }
        .onChange(of: model.settings.targetBytes) { newValue in
            if parsedTarget != newValue { syncTargetField() }
        }
        .onChange(of: targetFocused) { focused in
            // 失焦时落地 —— 和回车一个效果
            if !focused { commitTarget() }
        }
    }

    // MARK: 合并卡

    /// 右栏现在只有**一张卡**，三段：压缩目标 / 输出方式 / 更多设置。
    ///
    /// 改版前是三张独立的卡（实测 250 / 210 / 52pt）。三张卡各画一圈边框、
    /// 各留一圈内边距，中间还隔着两道 12pt 的卡间距 —— 那些高度本来可以
    /// 全给左栏的列表。更要命的是三张卡的高度差得远，右栏看上去是"参差的"。
    ///
    /// 合成一张之后，"这几组属于同一批设置"由**分段线**交代，
    /// 不再需要三个边框去重复说明同一件事。
    private var mergedCard: some View {
        VStack(spacing: 0) {
            segment("压缩目标") {
                VStack(alignment: .leading, spacing: 11) {
                    SegmentBar(items: goalItems, selection: goalBinding)

                    if model.settings.sizeGoal == .quality {
                        qualityBody
                    } else {
                        targetBody
                    }
                }
            }

            CardDivider()

            segment("输出方式") {
                outputBody
            }

            CardDivider()

            drawer
        }
        // 这张卡**不再自己画边框、投影和高光**。
        //
        // 霜白里右栏整体就是那一块玻璃板（见 `ContentView` 的 `.frostPanel`），
        // 板上再套一张有边有影的卡，等于同一件事说了两遍 ——
        // 两层边界还会把"这三段是同一批设置"拆散。
        // 段与段之间靠 `CardDivider` 交代，就够了。
    }

    /// 合并卡里的一段。段与段之间靠 `CardDivider` 分，不靠外框。
    private func segment<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.textTertiary)

            content()
        }
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var goalItems: [SegmentBar.Item] {
        SizeGoal.allCases.map {
            SegmentBar.Item(id: $0.rawValue, icon: $0.icon, title: $0.title)
        }
    }

    private var goalBinding: Binding<String> {
        Binding(
            get: { model.settings.sizeGoal.rawValue },
            set: { model.settings.sizeGoal = SizeGoal(rawValue: $0) ?? .quality }
        )
    }

    private var currentPreset: StrengthPreset? {
        StrengthPreset.nearest(to: model.settings.quality)
    }

    // MARK: 按画质

    private var qualityBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            bigReadout(
                number: "\(Int((model.settings.quality * 100).rounded()))",
                unit: "%",
                tagline: currentPreset?.title ?? "自定义"
            )

            // 尺子和档位标签是**同一个控件**：标签就在 GradeScale 里面，
            // 和刻度共用一套坐标 —— 分开写的话两边迟早会对不齐
            GradeScale(quality: $model.settings.quality)

            hint(currentPreset?.note ?? "数值越低体积越小，也越容易看出画质损失")
        }
    }

    // MARK: 按体积

    private var targetBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 大数字本身就是输入框 —— 不再下面再放一个一样的输入框，
            // 同一个数在同一张卡里出现两次只会让人怀疑哪个才是真的
            HStack(alignment: .bottom, spacing: 3) {
                TextField("", text: $targetValue)
                    .textFieldStyle(.plain)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 88)
                    .focused($targetFocused)
                    .onSubmit { commitTarget() }

                Text(targetUnit == 1 ? "MB" : "KB")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 5)

                Spacer(minLength: 6)

                Text("目标体积")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule().fill(Theme.wash(0.09)))
                    .padding(.bottom, 4)
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3),
                spacing: 5
            ) {
                ForEach(TargetSize.presets, id: \.self) { bytes in
                    ChoiceChip(
                        title: TargetSize.label(bytes),
                        selected: model.settings.targetBytes == bytes
                    ) {
                        model.settings.targetBytes = bytes
                        syncTargetField()
                    }
                }
            }

            HStack(spacing: 6) {
                ForEach([("KB", 0), ("MB", 1)], id: \.1) { label, unit in
                    ChoiceChip(title: label, selected: targetUnit == unit) {
                        targetUnit = unit
                        commitTarget()
                    }
                    .frame(width: 44)
                }

                Spacer(minLength: 4)

                if let parsed = parsedTarget {
                    Text("= \(Fmt.compact(parsed))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    Text("数值不对")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.bad)
                }
            }

            hint("先压质量、再缩尺寸，两头找平衡，尽量保住观感")
        }
    }

    /// 主控卡里那个放大到 32px 的读数
    private func bigReadout(number: String, unit: String, tagline: String) -> some View {
        HStack(alignment: .bottom, spacing: 3) {
            Text(number)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Text(unit)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 5)

            Spacer(minLength: 6)

            Text(tagline)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(Theme.wash(0.09)))
                .padding(.bottom, 4)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var parsedTarget: Int? {
        guard let value = Double(targetValue.trimmingCharacters(in: .whitespaces)), value > 0 else {
            return nil
        }
        return Int(value * (targetUnit == 0 ? 1024 : 1024 * 1024))
    }

    private func commitTarget() {
        if let bytes = parsedTarget { model.settings.targetBytes = bytes }
    }

    private func syncTargetField() {
        // 正在输入时绝不回写 —— 见 `targetFocused` 的说明
        guard !targetFocused else { return }
        let bytes = model.settings.targetBytes
        if bytes >= 1024 * 1024, bytes % (1024 * 1024) == 0 {
            targetUnit = 1
            targetValue = "\(bytes / (1024 * 1024))"
        } else {
            targetUnit = 0
            targetValue = "\(max(1, bytes / 1024))"
        }
    }

    // MARK: 输出方式

    /// 输出方式那一段的内容。外壳（标题、内边距、分段线）由 `mergedCard` 的
    /// `segment` 提供 —— 这里只写内容，不再自己套一层卡片。
    private var outputBody: some View {
        VStack(spacing: 5) {
            ForEach(OutputMode.allCases) { mode in
                RadioOption(
                    title: mode.shortTitle,
                    detail: mode.cardDetail,
                    selected: model.settings.outputMode == mode,
                    destructive: mode.isDestructive
                ) {
                    model.settings.outputMode = mode
                }
            }

            if model.settings.outputMode == .customFolder {
                Button {
                    model.chooseOutputFolder()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "hand.point.up.left")
                            .font(.system(size: 10.5))
                        Text(model.settings.customFolder?.path ?? "点击选择输出文件夹…")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(
                        model.settings.customFolder == nil
                            ? Theme.textSecondary
                            : Theme.textTertiary
                    )
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: Frost.radiusChip, style: .continuous)
                            .fill(Theme.wash(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Frost.radiusChip, style: .continuous)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            if model.settings.outputMode == .overwrite {
                Text("只有确实变小的图片才会被替换")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warn.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 1)
            }

            if model.hasNestedFolders, model.settings.outputMode != .suffix {
                Text("这批图片里有子文件夹，到「更多设置」里勾上「目录层级」才能还原结构")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }
        }
    }

    // MARK: 更多设置（抽屉）

    /// 其余五组收进一个抽屉，默认收起。
    ///
    /// 这是「窗口高度由内容决定」那条约定的落地：设置多了就收起来，
    /// **不要靠拉高窗口解决** —— 那会让左边列表出现一大片死空白。
    /// 收起时那行摘要会显示每组的当前取值，所以"收起"不等于"藏起状态"。
    /// 抽屉 —— 合并卡的最后一段。
    ///
    /// 收起时它就是这张卡的"下缘"：一行摘要加一个把手，底色浅一档。
    /// 展开后其余五组**直接长在卡里**（不再套一层内嵌卡）——
    /// 嵌一层卡等于在卡片内部又画一圈边界，而里面装的东西
    /// 明明和上面两段是同一批设置。
    private var drawer: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { moreExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("更多设置")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(drawerSummary)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                            // 允许折到第二行。
                            //
                            // 原来写的是 `lineLimit(1)`：这一行要报五段的取值，
                            // 而右栏只有 300pt —— 实测最宽的组合
                            //（「原格式 · 不限尺寸 · 每批 200 · 未调色 · 跟随系统」）
                            // 会把它截成「跟随…」，正好截掉最后一段。
                            //
                            // 而这一行存在的理由就是**收起不等于藏起状态**：
                            // 靠它才知道抽屉里有几段不是默认值。一个会悄悄吃掉
                            // 最后一项的摘要，恰好是在最需要它的时候失效 ——
                            // 越多人去改了非默认值，它越不可信。
                            //
                            // 折行只在真的放不下时发生，常规情况仍是一行。
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 6)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(moreExpanded ? 90 : 0))
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 收起时那一行**不铺灰底** —— 生成器里它就是平的，铺了会在
            // 玻璃板底部凭空多出一块"页脚"，把板子切成两截。
            // 悬停时才浮起一点，让"这行能点"有个落点。
            .onHover { drawerHovering = $0 }

            if moreExpanded {
                VStack(spacing: 14) {
                    CardDivider(soft: true)
                    formatGroup
                    CardDivider(soft: true)
                    sizeGroup
                    CardDivider(soft: true)
                    batchGroup
                    CardDivider(soft: true)
                    gradeGroup
                    CardDivider(soft: true)
                    keepGroup
                    CardDivider(soft: true)
                    appearanceGroup
                }
                // 段内这几条线比段与段之间那条**浅一档**（`CardDivider(soft:)`）——
                // 一个是"同一段里的细分"，一个是"新的段开始了"。
                // 霜白里这个区别靠深浅，不靠左右缩进。
                .padding(.top, 14)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
        // id 挂在**整段**上（含展开出来的内容），不是挂在那个把手上：
        // 滚动的目标是"让这一段整个看得见"。挂在把手上的话，对齐底部
        // 只会把把手送到视口底边，展开的五组照样在下面看不见。
        .id(Self.drawerID)
        .background(drawerHovering && !moreExpanded ? Theme.wash(0.05) : .clear)
    }

    /// 抽屉收起时那行摘要。每段都带当前取值 —— 这是"收起不等于藏起状态"的落地。
    ///
    /// 这一行**从来没写满过余量**：五段全取非默认值时放不下一行，所以视图那边
    /// 允许折到两行（见 `drawer`）。加新的一段之前先按最宽组合估一下宽度。
    private var drawerSummary: String {
        var parts: [String] = []

        // 这一格和芯片上那个名字**同源**（`FormatChoice.shortTitle`）。
        // 原来在这里手抄了一份 `case` 列表：加档位时很容易只改芯片、漏掉这里，
        // 而摘要行少一格是看得见的 —— 抽屉一收起，用户就再也没有第二处
        // 能确认自己选的是哪一档了。
        parts.append(model.settings.format.shortTitle)

        parts.append(model.settings.maxDimension == 0
                     ? "不限尺寸"
                     : "≤\(model.settings.maxDimension)")

        // 分批只在**非默认**时才写。
        //
        // 默认是「一次压完」，写出来等于把一件没发生的事也报一遍；
        // 而用户真选了分批，收起抽屉后就没有第二处能看见它了 ——
        // 跑起来每 50 张停一次，他会先怀疑是不是卡住了。
        //
        // 写法特意**不是**档位芯片上那句「一次 50 张」：这一行是
        // `lineLimit(1)` 尾部截断、宽度按最宽的组合算只剩几个字的余量
        //（实测「原格式 · 不限尺寸 · 未调色 · 亮色」已经吃掉一半），
        // 多一个字就在最长的那个组合上把「跟随系统」截掉半截。
        // 「每批 50」短一位，意思一样。
        if model.settings.batchSize > 0 {
            parts.append("每批 \(model.settings.batchSize)")
        }

        if gradeBlocked {
            parts.append("调色停用")
        } else if gradeActive {
            parts.append(model.settings.grade.lutPath == nil ? "旋钮调色" : "已调色")
        } else {
            parts.append("未调色")
        }

        // 「已编辑的图」那一档的摘要曾经挂在这里 —— 随图库功能一起删了。

        parts.append(model.settings.appearance.title)

        return parts.joined(separator: " · ")
    }

    private func drawerGroup(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 抽屉 · 输出格式

    private var formatGroup: some View {
        drawerGroup("输出格式") {
            VStack(alignment: .leading, spacing: 8) {
                // 五档等宽铺满一行。芯片上**只放格式名**，不写「统一转」：
                // 段标题已经是「输出格式」、每一档也都只有一个意思，
                // 再重复一遍只是把本来就紧的宽度花掉 —— 五档等分之后每颗只剩 55pt，
                // 多那三个字就得靠缩字号去挤，一排字会忽大忽小。
                HStack(spacing: 5) {
                    ForEach(FormatChoice.allCases) { choice in
                        ChoiceChip(
                            title: choice.shortTitle,
                            selected: model.settings.format == choice
                        ) {
                            model.settings.format = choice
                        }
                    }
                }

                // 选中那一档的一句人话。
                //
                // 在此之前 `FormatChoice.detail` **定义了却一处都没被渲染**，是死代码；
                // 更要紧的是，用户因此看不到「PNG 会把照片涨好几倍」
                // 「AVIF 编码慢一些」这类必须先说清、否则只能自己踩一次的后果。
                //
                // 两行封顶：`原格式` 那一档要说清"哪些不动、哪些转成什么"，一行放不下；
                // 但也不许无限长 —— 抽屉是滚动区，多一行就把下面几组顶出视口。
                Text(model.settings.format.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 抽屉 · 最长边

    private var sizeGroup: some View {
        drawerGroup(model.settings.sizeGoal == .targetBytes
                    ? "最长边上限（按体积压缩时会自动再缩）"
                    : "最长边限制（像素）") {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3),
                spacing: 5
            ) {
                ForEach(CompressSettings.sizeOptions, id: \.0) { option in
                    ChoiceChip(
                        title: option.1,
                        selected: model.settings.maxDimension == option.0
                    ) {
                        model.settings.maxDimension = option.0
                    }
                }
            }
        }
    }

    // MARK: 抽屉 · 分批

    /// 分批压缩。
    ///
    /// 收在抽屉里而不是摆到主控卡上：它是**一批图特别多**时才需要回答的问题，
    /// 三五张的时候这一行只是噪音。默认是「一次压完」，所以不展开抽屉的人
    /// 行为一个字节都不变。
    ///
    /// 扫描报告里也有一处（那边张数够多才出现）。两处改的是同一个设置项，
    /// 所以不会出现"报告里选了 50、这里显示别的"这种事。
    private var batchGroup: some View {
        drawerGroup("分批压缩") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    ForEach(BatchPlan.options, id: \.self) { size in
                        ChoiceChip(
                            title: BatchPlan.shortLabel(size),
                            selected: model.settings.batchSize == size
                        ) {
                            model.settings.batchSize = size
                        }
                    }
                }

                hint("每批之间可以停下来看结果，也可以随时叫停。"
                     + "不改画质 —— 同一张图分不分批压出来完全一样。")
            }
        }
    }

    // MARK: 抽屉 · 调色

    /// 这里只放一行入口。
    ///
    /// 300px 的侧栏塞不下「强度 + 五个旋钮 + 色彩空间 + 预览 + 两个导出」，
    /// 硬塞会变成一根很长的滚动条、还会把上面几组设置顶出视野。
    /// 真正的调色操作全在「调色室」那个独立窗口里。
    private var gradeGroup: some View {
        drawerGroup("调色 / LUT") {
            Button {
                model.showingGradeStudio = true
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: Frost.radiusChip, style: .continuous)
                            .fill(gradeActive ? Theme.wash(0.09) : Theme.wash(0.05))
                        Image(systemName: "camera.filters")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(gradeActive ? Theme.textPrimary : Theme.textTertiary)
                    }
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(gradeTitle)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(gradeDetail)
                            .font(.system(size: 9.5))
                            .foregroundStyle(gradeBlocked ? Theme.warn : Theme.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: Frost.radiusChip, style: .continuous)
                        .fill(gradeActive ? Theme.wash(0.09) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Frost.radiusChip, style: .continuous)
                        .strokeBorder(gradeActive ? Theme.borderStrong : Theme.border,
                                      lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var gradeActive: Bool { model.settings.effectiveGrade.isActive }
    private var gradeBlocked: Bool { model.settings.gradeBlockedByPristine }

    private var gradeTitle: String {
        let grade = model.settings.grade
        if let path = grade.lutPath {
            return LUTLibrary.shared.displayName(forPath: path)
        }
        if grade.adjustedKnobCount > 0 {
            return "只用旋钮调色"
        }
        return "未启用"
    }

    private var gradeDetail: String {
        let grade = model.settings.grade
        if gradeBlocked { return "与「无损保真」档互斥" }
        if grade.lutPath != nil {
            return "强度 \(Int((grade.intensity * 100).rounded()))% · 会一并应用"
        }
        if grade.adjustedKnobCount > 0 {
            return "已调整 \(grade.adjustedKnobCount) 项 · 会一并应用"
        }
        return "默认关闭，不影响画质"
    }

    // MARK: 抽屉 · 保留

    private var keepGroup: some View {
        drawerGroup("保留") {
            VStack(spacing: 8) {
                SwitchRow(
                    title: "目录层级",
                    detail: "拖文件夹进来时按原来的子目录结构输出",
                    isOn: $model.settings.preserveStructure
                )
                SwitchRow(
                    title: "拍摄信息",
                    detail: "相机 / 镜头 / GPS / 拍摄时间",
                    isOn: $model.settings.keepMetadata
                )
                SwitchRow(
                    title: "文件时间",
                    detail: "覆盖或副本沿用原文件的创建与修改时间",
                    isOn: $model.settings.keepTimestamps
                )
            }
        }
    }

    // MARK: 抽屉 · 外观

    private var appearanceGroup: some View {
        drawerGroup("界面外观") {
            HStack(spacing: 5) {
                ForEach(AppearanceMode.allCases) { mode in
                    ChoiceChip(
                        title: mode.title,
                        icon: mode.icon,
                        selected: model.settings.appearance == mode
                    ) {
                        model.settings.appearance = mode
                    }
                }
            }
        }
    }
}
