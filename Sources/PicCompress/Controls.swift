import SwiftUI

// MARK: - 改版后的通用控件
//
// 这一组是为了让「选中态不用品牌红」这条规则**只写一次**。
// 改版前同一个"选中"样式在设置面板里复制了六遍，全都是品牌红填充 ——
// 于是屏幕上同时出现六处红，「开始压缩」被自己人淹没。
// 现在所有选中态都走这里的组件，红色只剩主操作一处。

// MARK: 分组卡片
//
// 这里原来有一个 `SettingsCard`：一组设置一张卡。
//
// 它删掉了，原因是它服务的那套结构已经不在了 —— 右栏当时是三张独立的卡
// （实测 250 / 210 / 52pt），三张卡各画一圈边框、各留一圈内边距、
// 中间还隔着两道卡间距；高度差得远，右栏看上去是参差的，
// 而那些高度本来可以全给左栏的列表。
//
// 现在右栏是**一张卡、三段**（见 `SettingsPanel.mergedCard`），
// 段与段之间靠 `CardDivider` 交代 —— 不需要三个边框去重复说明同一件事。
//
// 组件本身删掉而不是留着，是因为：留着它，下次往右栏加一组设置时
// 最顺手的写法就是"再来一张卡"，而那恰恰是刚刚决定不要的东西。
//
// 调色室（`GradeStudioView`）那边是多张分组，用的是 `SettingsSection`
// （只给标题、不画边框），和这里不是同一个东西，没有受影响。

// MARK: 一排里选一个

/// 小胶囊：输出格式 / 最长边 / 界面外观 / 目标体积都用它。
///
/// 选中态是**中性浮起面 + 描边 + 字重加深**，不是品牌红。
struct ChoiceChip: View {
    let title: String
    var icon: String?
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 29)
            .background(
                RoundedRectangle(cornerRadius: Frost.radiusChip, style: .continuous)
                    .fill(fill)
                    .shadow(color: selected ? Theme.shadow : .clear, radius: 7, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Frost.radiusChip, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: selected)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// 选中 = **浮起面 + 柔影**，不是描边加粗。
    ///
    /// 霜白里"被选中"统一靠"浮起来"表达（`Theme.raised` + 柔影），
    /// 描边只留给没选中的那些片。一排里那颗没有边框的，
    /// 反而比"边框更粗"更容易一眼认出来 —— 这跟旧版是反过来的。
    private var fill: Color {
        if selected { return Theme.raised }
        return hovering ? Theme.wash(0.07) : .clear
    }

    private var stroke: Color {
        if selected { return .clear }
        return hovering ? Theme.borderStrong : Theme.border
    }
}

// MARK: 分段控件

/// 两三个互斥选项并排时用它（「按画质 / 按体积」）。
///
/// 和 `ChoiceChip` 的区别是**轨道**：分段控件外面有一层凹槽，
/// 让"这几个是一组、只能选一个"这件事一眼看得出来。
struct SegmentBar: View {
    struct Item: Identifiable {
        let id: String
        let icon: String?
        let title: String

        init(id: String, icon: String? = nil, title: String) {
            self.id = id
            self.icon = icon
            self.title = title
        }
    }

    let items: [Item]
    let selection: String
    let onSelect: (String) -> Void

    /// 直接绑一个值 —— 大多数地方用这个。
    init(items: [Item], selection: Binding<String>) {
        self.init(items: items,
                  selection: selection.wrappedValue,
                  onSelect: { selection.wrappedValue = $0 })
    }

    /// 切换的时候还要顺带做别的事，用这个。
    ///
    /// 调色室切预览模式时得把分割线复位 —— 用 `Binding` 表达不了这个"顺带"，
    /// 早先它就在本地又抄了一份分段控件。抄出来的那份慢慢就会和这份长得不一样，
    /// 所以宁可在这里多开一个入口。
    init(items: [Item], selection: String, onSelect: @escaping (String) -> Void) {
        self.items = items
        self.selection = selection
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(items) { item in
                let selected = item.id == selection
                Button {
                    onSelect(item.id)
                } label: {
                    HStack(spacing: 5) {
                        if let icon = item.icon {
                            Image(systemName: icon)
                                .font(.system(size: 10, weight: .medium))
                        }
                        Text(item.title)
                            .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    }
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(
                        // 选中那一格同样是"浮起面 + 柔影"，没有描边 ——
                        // 和 `ChoiceChip` 一套语言。凹槽（下面那层 `Theme.well`）
                        // 已经交代了"这是一组"，格子自己不需要再画边。
                        RoundedRectangle(cornerRadius: Frost.radiusButton - 3,
                                         style: .continuous)
                            .fill(selected ? Theme.raised : .clear)
                            .shadow(color: selected ? Theme.shadow : .clear,
                                    radius: 7, y: 3)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: Frost.radiusButton, style: .continuous)
                .fill(Theme.well)
        )
        .animation(.easeOut(duration: 0.14), value: selection)
    }
}

// MARK: 纵向单选

/// 输出方式那种"竖着排、选一个"的行。
///
/// 说明文字**只在选中的那一行展开**。四行都带小字的话会变成一堵墙，
/// 而这四句话里用户真正需要读的，永远只是当前那一条。
struct RadioOption: View {
    let title: String
    let detail: String
    let selected: Bool
    var destructive = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(selected ? Theme.textPrimary : Theme.textTertiary,
                                      lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                    if selected {
                        Circle()
                            .fill(Theme.textPrimary)
                            .frame(width: 6, height: 6)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .foregroundStyle(destructive && selected ? Theme.bad : Theme.textPrimary)
                        .lineLimit(1)

                    if selected, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(destructive ? Theme.bad.opacity(0.85) : Theme.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Frost.radiusCard, style: .continuous)
                    .fill(fill)
                    .shadow(color: selected ? Theme.shadow : .clear, radius: 8, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Frost.radiusCard, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: selected)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var fill: Color {
        // 选中 = 浮起面 + 柔影，和 `ChoiceChip` 同一套语言
        if selected { return Theme.raised }
        // 未选中的行**不给底色**。给了的话三行都是灰的，看着像"全选中了"。
        return hovering ? Theme.wash(0.05) : .clear
    }

    private var stroke: Color {
        // 破坏性的那一项选中时保留一道告警色描边 —— 这一条是**信息**，
        // 不是装饰，柔影替不了它。
        if selected {
            return destructive ? Theme.bad.opacity(0.5) : .clear
        }
        return hovering ? Theme.borderStrong : Theme.border
    }
}

// MARK: 卡片内部的分隔线

/// `soft` 给"同一段里的细分"用。
///
/// 段与段之间那条通边、颜色足；段内这几条浅一档（`opacity 0.6`）。
/// 霜白里这两种线的区别靠**深浅**表达，不靠左右缩进 ——
/// 缩进会让同一块板上出现两条不同的左边界，看着像对齐错了。
struct CardDivider: View {
    var soft = false

    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(height: 1)
            .opacity(soft ? 0.6 : 1)
    }
}

// MARK: 开关

/// 与整体风格一致的小开关。
///
/// 这是**极少数还保留品牌红的地方**：开关的"开"是一个布尔状态，
/// 不是"从一排里选中一个"，红在这里不会和别的红打架。
struct AccentSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn
                          ? AnyShapeStyle(Theme.accentGradient)
                          : AnyShapeStyle(Theme.wash(0.15)))
                    .frame(width: 38, height: 22)
                    // 「开」的时候给上缘一道内高光。这颗开关很小，没有这道光
                    // 那块红就是一枚扁平的色块，和旁边的滑块对不上重量。
                    .overlay(
                        Capsule()
                            .strokeBorder(Brand.fillHighlight, lineWidth: 1)
                            .mask(
                                LinearGradient(colors: [.black, .clear],
                                               startPoint: .top, endPoint: .center)
                            )
                            .opacity(isOn ? 1 : 0)
                    )

                // 滑块恒为白色：亮色下轨道已被 wash 压成浅灰，白滑块压上去照样分得清；
                // 暗色下是白滑块压深轨道 —— 两边都成立，所以不跟外观走
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .padding(.horizontal, 2)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: isOn)
    }
}

/// 一行"标题 + 说明 + 开关"
struct SwitchRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            AccentSwitch(isOn: $isOn)
        }
    }
}

// MARK: 提示框里的行动按钮

/// 小尺寸的中性按钮：**是一个动作，不是一个选项**，但也不够格用品牌红。
///
/// 用在提示框里的"那就改一下"这类出路按钮上。之前它是一颗红色实心按钮，
/// 坐在一个琥珀色的警告框里 —— 一个框里两种告警色，读起来像两件事。
/// 而屏幕真正的主操作（开始压缩 / 应用调色）反而被压下去了。
///
/// 中性不等于弱：整块 `wash` 铺底 + 描边 + 字重 semibold，
/// 在一段说明文字底下依然一眼看得出"这块能点"。
struct InlineActionButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 27)
                .background(
                    RoundedRectangle(cornerRadius: Frost.radiusChip, style: .continuous)
                        .fill(Theme.wash(hovering ? 0.16 : 0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Frost.radiusChip, style: .continuous)
                        .strokeBorder(Theme.borderStrong, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: 精细滑杆

/// 调色室里的参数滑杆。**替掉系统的 `Slider`**。
///
/// 四个理由，每一条都在这个项目里真踩过：
///
/// 1. **丝滑。** 系统 `Slider` 的轨道由 AppKit 画，拖动时值已经变了、
///    画面还在按自己的节奏追。这里拖动过程中**完全不加隐式动画**，
///    手到哪儿游标到哪儿。
/// 2. **填充要从「中性位」出发，不是从左边。** 调色室的六根参数
///    （曝光 / 对比 / 色温 / 饱和 / 暗部 / 强度）**没有一根的中性位在左端**：
///    对比的中性位是 1.0（量程 0.5…1.5），饱和的中性位也是 1.0（量程 0…2），
///    曝光 / 色温 / 暗部的中性位是 0 而量程横跨负正。系统滑杆只会
///    "从最左填到当前位置"，那在这几根上表达的是**错的信息** ——
///    饱和拉到 1.0（也就是没动过）会显示成"填了一半"。
///    这里填充段画在「中性位 → 当前位置」之间，长度就是偏离量，
///    并在中性位立一道刻度。这是修图软件里的标准做法。
/// 3. **配色统一。** 调色室是照片编辑器，屏幕上唯一的颜色该是那张照片，
///    所以轨道一律中性。系统滑杆的轨道颜色两种外观各有一套，控制不了。
/// 4. **截图可信。** 系统 `Slider` 的填充段不经 `cacheDisplay`，
///    截出来永远是浅灰 —— 我照着一张假图误判过"亮色下配色错了"，
///    差点去改没问题的代码（见 `DebugSnapshot` 里的警告）。
///    自绘的每一笔都在自己的图层里，截什么就是什么。
///
/// 交互：按住拖动 / 点一下跳过去 / 双击回到中性位。
struct FineSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// 双击要回到哪个值
    let neutral: Double

    @State private var dragging = false
    @State private var hovering = false

    private let trackHeight: CGFloat = 4
    private let knobSize: CGFloat = 12
    private let knobSizeActive: CGFloat = 14
    /// 留出足够高度容纳放大后的游标 + 投影，否则放大时会被裁掉
    private let height: CGFloat = 18

    private var span: Double { max(0.0001, range.upperBound - range.lowerBound) }

    private var fraction: Double {
        min(1, max(0, (value - range.lowerBound) / span))
    }

    private var neutralFraction: Double {
        min(1, max(0, (neutral - range.lowerBound) / span))
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let center = height / 2
            // 游标的圆心只能在 [knob/2, width - knob/2] 之间走，
            // 否则贴到两端时会有半个圆探出控件外
            let usable = max(1, width - knobSize)
            let knobX = knobSize / 2 + CGFloat(fraction) * usable
            let neutralX = knobSize / 2 + CGFloat(neutralFraction) * usable
            // 填充段：中性位与当前位之间那一截
            let fillLeft = min(knobX, neutralX)
            let fillWidth = abs(knobX - neutralX)

            ZStack(alignment: .topLeading) {
                // 和 `GradeScale` 同一个理由：ZStack 的尺寸由最大子视图决定，
                // 垫一层贪心透明色让它老老实实等于整个宽度，否则下面的 offset 全偏。
                Color.clear

                Capsule()
                    .fill(Theme.wash(0.12))
                    .frame(width: usable, height: trackHeight)
                    .offset(x: knobSize / 2, y: center - trackHeight / 2)

                // 偏离量。不用品牌红 —— 这里表达的是"我动了多少"，
                // 是中性信息，不是主操作。
                if fillWidth > 0.5 {
                    Capsule()
                        .fill(Theme.textTertiary)
                        .frame(width: fillWidth, height: trackHeight)
                        .offset(x: fillLeft, y: center - trackHeight / 2)
                }

                // 中性位刻度：一眼看出"回哪儿是没动过"
                Rectangle()
                    .fill(Theme.textTertiary.opacity(0.7))
                    .frame(width: 1, height: 9)
                    .offset(x: neutralX - 0.5, y: center - 4.5)

                Circle()
                    .fill(.white)
                    .frame(width: active ? knobSizeActive : knobSize,
                           height: active ? knobSizeActive : knobSize)
                    .overlay(
                        Circle().strokeBorder(.black.opacity(0.14), lineWidth: 0.5)
                    )
                    .shadow(color: Theme.shadow, radius: active ? 3 : 1.5, y: 1)
                    .offset(x: knobX - (active ? knobSizeActive : knobSize) / 2,
                            y: center - (active ? knobSizeActive : knobSize) / 2)
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(
                // minimumDistance 0 ⇒ 点一下就直接跳过去，不用先按住再拖
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        dragging = true
                        let x = min(usable, max(0, v.location.x - knobSize / 2))
                        value = range.lowerBound + Double(x / usable) * span
                    }
                    .onEnded { _ in dragging = false }
            )
            // 双击归中位。用 simultaneousGesture 而不是 onTapGesture：
            // 拖动手势是 minimumDistance 0，单击本来就会落一次，
            // 双击时第一下落的位会被第二下紧接着覆盖成中性位，结果是我们要的。
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { value = neutral }
            )
        }
        .frame(height: height)
        .onHover { hovering = $0 }
        // 拖动和悬停时游标放大一档。**拖动中不做隐式动画** ——
        // 加了的话游标会黏在手指后面，这正是"不丝滑"的来源。
        .animation(dragging ? nil : .easeOut(duration: 0.12), value: active)
    }

    private var active: Bool { dragging || hovering }
}

// MARK: 档位尺

/// 压缩强度：一条轨道 + 五个刻度 + 一个游标 + 五个档位标签。
///
/// 四点刻意的设计，都是从上一次的方向矛盾里改出来的：
///
/// 1. **没有填充**。填充会让它看起来像进度条，而进度条天然带方向暗示 ——
///    之前那个"越往右拖画质越保真"的拧劲就是从填充来的。
/// 2. **两端表示同一个量**：左 = 更保真，右 = 更小。轨道恰好只跨在
///    首尾刻度之间，游标能走到轨道之外的那一小段，表示"超出了档位范围"。
/// 3. **刻度与标签同源**。两者都在下面这一个 `GeometryReader` 里、都用
///    `StrengthScale.tickPosition` 算位置 —— 放进同一个坐标系，就不存在
///    "调了标签的 padding、忘了调刻度"这种错位。
/// 4. 标签**可以点**：点哪一档就跳到哪一档，同时也是刻度的文字说明。
struct GradeScale: View {
    @Binding var quality: Double

    @State private var dragging = false

    private let rulerHeight: CGFloat = 22
    private let labelHeight: CGFloat = 15
    private let gap: CGFloat = 5
    private var totalHeight: CGFloat { rulerHeight + gap + labelHeight }

    private let trackHeight: CGFloat = 3
    private let tickSize: CGFloat = 5
    private let knobSize: CGFloat = 15

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let center = rulerHeight / 2

            let first = StrengthScale.tickPosition(0)
            let last = StrengthScale.tickPosition(StrengthScale.tickCount - 1)
            let knobX = CGFloat(StrengthScale.position(for: quality)) * width

            VStack(spacing: gap) {
                ZStack(alignment: .topLeading) {
                    // 这一层是必须的，不是装饰。
                    //
                    // ZStack 的尺寸由**最大的子视图**决定：这里的轨道只有 0.8 宽，
                    // 于是 ZStack 自己也变成 0.8 宽，外层 `frame(width:)` 再把它居中 ——
                    // 等于给里面的每个 offset 白白加了 0.1 宽的位移。
                    // 表现就是刻度、游标整体右移半格，跟下面那排标签对不上
                    // （实测游标落在 40% 而标签在 30%）。
                    // 垫一层贪心的透明色，让 ZStack 老老实实等于整个宽度。
                    Color.clear

                    Capsule()
                        .fill(Theme.wash(0.13))
                        .frame(width: width * (last - first), height: trackHeight)
                        .offset(x: width * first, y: center - trackHeight / 2)

                    ForEach(0..<StrengthScale.tickCount, id: \.self) { index in
                        Circle()
                            .fill(Theme.textTertiary.opacity(0.55))
                            .frame(width: tickSize, height: tickSize)
                            .offset(
                                x: width * StrengthScale.tickPosition(index) - tickSize / 2,
                                y: center - tickSize / 2
                            )
                    }

                    // 游标恒为白色：暗色下压在深轨道上、亮色下压在浅灰轨道上，
                    // 两种外观都分得清，所以不跟外观走（和开关的滑块同一个理由）。
                    // 投影用自适应令牌 —— 写死 0.42 的话亮色下会在白卡片上糊出一圈灰晕。
                    Circle()
                        .fill(.white)
                        .frame(width: knobSize, height: knobSize)
                        .overlay(
                            Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5)
                        )
                        .shadow(color: Theme.shadow, radius: 2, y: 1)
                        .offset(x: knobX - knobSize / 2, y: center - knobSize / 2)
                }
                .frame(width: width, height: rulerHeight)
                .contentShape(Rectangle())
                .gesture(
                    // minimumDistance 0 ⇒ 点一下也能直接跳过去，不用先按住再拖
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragging = true
                            let fraction = min(1, max(0, value.location.x / width))
                            quality = StrengthScale.quality(at: Double(fraction))
                        }
                        .onEnded { _ in dragging = false }
                )

                // 五个标签是等宽单元、各自居中，所以中心落在
                // width/10、3·width/10 … 正好是刻度的位置
                HStack(spacing: 0) {
                    ForEach(Array(StrengthPreset.allCases.enumerated()), id: \.element.id) { index, preset in
                        let on = StrengthScale.tickIndex(for: quality) == index
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) {
                                quality = preset.quality
                            }
                        } label: {
                            Text(preset.title)
                                .font(.system(size: 10, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? Theme.textPrimary : Theme.textTertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .frame(maxWidth: .infinity)
                                .frame(height: labelHeight)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: width)
            }
        }
        .frame(height: totalHeight)
        // 拖动过程中**不能有隐式动画** —— 那会让游标黏在手指后面。
        // 点档位标签跳过去时才要动画，所以按 dragging 分开。
        .animation(dragging ? nil : .easeOut(duration: 0.18), value: quality)
    }
}
