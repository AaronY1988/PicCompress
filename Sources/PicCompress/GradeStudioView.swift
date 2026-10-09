import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 调色室。
///
/// 为什么单独开一个窗口而不是塞进右侧设置栏：320px 的侧栏装不下
/// 「强度 + 五个旋钮 + 色彩空间 + 预览 + 两个导出」，会变成一根很长的滚动条。
/// 调色是"看一眼效果再定参数"的活儿，需要一块够大的预览。
struct GradeStudioView: View {

    @ObservedObject var model: AppModel
    @ObservedObject private var library = LUTLibrary.shared
    @ObservedObject private var studio = GradeStudio.shared
    @Environment(\.dismiss) private var dismiss

    enum PreviewMode: String, CaseIterable, Identifiable {
        case split, after, before
        var id: String { rawValue }
        var title: String {
            switch self {
            case .split: return "分屏"
            case .after: return "调色后"
            case .before: return "原图"
            }
        }
    }

    @State private var mode: PreviewMode = .split
    @State private var split: CGFloat = 0.5
    @State private var draggingDivider = false

    // MARK: 草稿
    //
    // 调色室编辑的是一份**草稿**，不是直接写设置。这是这一版最关键的一处改动：
    //
    // 1. **「应用到全部」才是一颗真按钮。** 上一版每动一下滑块就直接写
    //    `model.settings.grade`，也就是"早就生效了"—— 再放一颗"应用"按钮，
    //    按下去什么都不会发生，那是假的。有了草稿，提交和还原才是真动作。
    // 2. **拖动不再触发整个主窗口重算。** `AppModel.$settings` 的订阅会
    //    每次落盘一遍 UserDefaults、并把所有列表项的状态复位；
    //    拖动时每秒十几次，界面上就是"发涩"。草稿只活在调色室自己这里。
    // 3. **关窗不再有歧义。** 有没应用的改动时问一句（应用 / 放弃 / 取消），
    //    既不会悄悄丢掉你刚调的东西，也绝不会悄悄把调色写进批量里 ——
    //    覆盖模式下那是不可逆的。
    @State private var draft = LUTGrade()
    @State private var confirmingClose = false

    @State private var renaming = false
    @State private var renameTarget: LUTEntry?
    @State private var renameText = ""

    @State private var importReport: LUTImportReport?
    @State private var showingImportReport = false

    @State private var toast: String?
    @State private var toastBad = false
    @State private var dropTargeted = false

    /// 草稿和"已经提交的调色"不一样 → 有未应用的改动
    private var dirty: Bool { draft != model.settings.grade }

    /// 列表里有多少张会吃到这套调色
    private var batchCount: Int { model.items.count }

    /// 「无损保真」档下引擎会整段跳过调色。文案、按钮禁用、角标都看这个。
    private var blockedByPristine: Bool {
        model.settings.isPristinePreset && draft.isActive
    }

    /// 真正会生效的那份参数。不生效时给一个中性 `LUTGrade`，
    /// 预览渲染出来就是"没变化"，和引擎的行为严格一致。
    private var effective: LUTGrade {
        blockedByPristine ? LUTGrade() : draft
    }

    private var effectiveActive: Bool { effective.isActive }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            HStack(spacing: 0) {
                previewPane.frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Theme.border).frame(width: 1)
                paramsPane.frame(width: 306)
            }
            hairline
            libraryPane
            hairline
            footer
        }
        .frame(width: 960, height: 790)
        // 同对比视图：浮层统一走玻璃板。板里那几个实心面板（`Theme.panel`）不变 ——
        // 调色室的正事是那张照片，编辑面板不该跟照片抢注意力。
        .background(Theme.glass)
        .onAppear {
            draft = model.settings.grade
            syncBase()
            studio.schedulePreview(grade: effective)

            // 出图钩子：截「有改动还没应用」那一屏。
            //
            // 必须**延迟**改、而不是把它当成 `draft` 的初值 —— 设成初值的话
            // `dirty` 一上来就是 true，走的是"打开就是这样"的路径，
            // 而真实路径是"打开是干净的、用户动了一下" —— 只有后者才会经过
            // 状态行的切换。这跟 `PICCOMPRESS_MORE` 当初踩的是同一个坑。
            if ProcessInfo.processInfo.environment["PICCOMPRESS_GRADE_DIRTY"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    draft.exposure = 0.65
                    draft.saturation = 1.35
                    draft.intensity = 0.72
                }
            }
        }
        .onDisappear { model.showingGradeStudio = false }
        .onChange(of: model.previewBaseURL) { _ in syncBase() }
        .onChange(of: studio.baseToken) { _ in studio.schedulePreview(grade: effective) }
        .onChange(of: effective) { newValue in studio.schedulePreview(grade: newValue) }
        .alert("重命名 LUT", isPresented: $renaming) {
            TextField("名字", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("改名") { commitRename() }
        } message: {
            Text("只改库里的文件名，.cube 的内容不动。")
        }
        .alert("导入完成", isPresented: $showingImportReport) {
            Button("好") { importReport = nil }
        } message: {
            Text(importMessage)
        }
        // 关窗时如果草稿还没提交，问一句。
        //
        // 不问的话只有两种做法，两种都不能接受：悄悄丢掉（用户刚调了五分钟）、
        // 或者悄悄应用（覆盖模式下这是把原图像素永久改掉，且用户不知道）。
        .confirmationDialog("有 \(changedKnobCount) 处改动还没应用", isPresented: $confirmingClose) {
            Button("应用并关闭") { applyToAll(); dismiss() }
            Button("放弃改动", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("应用到全部后会进入下一次压缩；放弃则只保留已经提交过的那套参数。")
        }
    }

    private var hairline: some View {
        Rectangle().fill(Theme.border).frame(height: 1)
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.wash(0.07))
                // 原本这块垫底是红的、图标也是红的。但调色室真正的主操作是下面那颗
                // 「应用到全部」—— 头部再放一个红，就又回到"一处红变两处红"的老路。
                // 这里只是个窗口标识，中性底 + 提亮图标足够。
                Image(systemName: "camera.filters")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("调色室")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(baseSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if studio.rendering || studio.preparing || !studio.previewIsCrisp {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    // 预览是两帧出的：先给快速档（跟手），停手后补高清档。
                    // 把"正在细化"说出来，用户才知道刚才那一下变糊不是画质问题。
                    Text(studio.preparing
                         ? "准备底图…"
                         : (studio.previewIsCrisp ? "正在算…" : "正在细化预览…"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            SegmentBar(
                items: PreviewMode.allCases.map {
                    SegmentBar.Item(id: $0.id, title: $0.title)
                },
                selection: mode.id
            ) { id in
                mode = PreviewMode(rawValue: id) ?? .split
                // 切回分屏时把分割线复位。这个"顺带"就是这里没法直接用
                // `Binding` 入口的原因，也正是 `SegmentBar` 开出第二个 init 的理由
                split = 0.5
            }
            // **必须给一个确定宽度。**
            //
            // `SegmentBar` 的每一格都是 `frame(maxWidth: .infinity)`，
            // 放在这里（外面还有个 Spacer 在抢宽度）会拿不到确定的提案，
            // 结果是三格宽度不均 —— 截图里「分屏」那一格比「调色后」宽了近一倍，
            // 看着像坏了。给死宽度，三格就一样宽。
            .frame(width: 234)

            // 头部只留一个收起：详细动作都在底栏。两个"完成"是上一版的冗余。
            Button {
                requestClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.wash(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("收起调色室")
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    /// 副标题要把**作用范围**说清楚。
    ///
    /// 上一版写的是「预览基于 X，调参与导出都跟着它走」—— 这句话字面上就是在说
    /// "这是针对那一张图的"，正好把用户引到"那我怎么给全部照片调"的疑问上。
    /// 实际上参数是全局的、会作用到整批，只是界面上从来没说过。
    private var baseSubtitle: String {
        guard let url = studio.baseURL else {
            return "还没有底图 —— 回到主窗口拖一张图片进来"
        }
        return "预览用列表里最大的「\(url.lastPathComponent)」，参数作用在全部 \(batchCount) 张上"
    }

    // MARK: 预览

    private var previewPane: some View {
        GeometryReader { geo in
            let box = geo.size
            ZStack {
                Theme.backdrop

                if studio.baseImage == nil {
                    emptyPreview
                } else {
                    previewLayers(box: box)
                    if mode == .split { divider(box: box) }
                }
            }
            .frame(width: box.width, height: box.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture(box: box))
        }
    }

    private var emptyPreview: some View {
        VStack(spacing: 9) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 28))
                .foregroundStyle(Theme.textTertiary)
                Text(studio.preparing ? "正在准备预览…" : "先在主窗口拖进一张图片")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("预览会拿列表里最大的一张图实时算，改一个参数马上就能看到")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    @ViewBuilder
    private func previewLayers(box: CGSize) -> some View {
        let after = studio.previewImage ?? studio.baseImage
        let before = studio.baseImage

        if mode == .before {
            if let before { layer(before, box: box) }
        } else if mode == .after {
            if let after { layer(after, box: box) }
        } else if let after, let before {
            layer(after, box: box)

            layer(before, box: box)
                .mask(alignment: .topLeading) {
                    Rectangle().frame(width: max(0, box.width * split))
                }

            previewTags(after, box: box)
        } else if let after {
            layer(after, box: box)
        }
    }

    /// 两侧的「原图 / 调色后」标签。
    ///
    /// 位置要贴着**图片**的边角，而不是整个面板的边角 —— 图片是等比 fit
    /// 居中显示的，面板边缘离图片往往还空着一截，标签挂在那儿会显得脱节。
    private func previewTags(_ image: CGImage, box: CGSize) -> some View {
        let fitted = fitSize(image, box: box)
        return HStack {
            // 角标压在照片上，底衬恒深 —— 所以这里用的是 Chip 里的恒定色，
            // 不能跟着界面外观翻，否则亮色下会变成深字压深底
            tag("原图", tint: Chip.text)
            Spacer()
            // 「调色后」以前是品牌红字。它只是一个**标签**，不是主操作，
            // 而品牌红在这个 App 里只留给"下一步该按的东西"。两边都用恒定的浅字，
            // 位置本身（左原图 / 右调色后）已经把意思说清楚了。
            //
            // 判断用 `effectiveActive` 而不是 `draft.isActive`：选了「无损保真」档时
            // 后者仍然是 true（用户确实挑了 LUT），但引擎收到的是中性参数、
            // 画面根本没变化。角标写「调色后」就成了假话 —— 得跟画面一致。
            tag(effectiveActive ? "调色后" : "调色后（当前未生效）",
                tint: effectiveActive ? Chip.text : Chip.muted)
        }
        .padding(.horizontal, max(10, (box.width - fitted.width) / 2))
        .padding(.top, max(10, (box.height - fitted.height) / 2))
        .frame(width: box.width, height: box.height, alignment: .top)
        .allowsHitTesting(false)
    }

    private func layer(_ image: CGImage, box: CGSize) -> some View {
        let size = fitSize(image, box: box)
        return Image(nsImage: NSImage(cgImage: image, size: .zero))
            .interpolation(.high)
            .resizable()
            .frame(width: size.width, height: size.height)
            .frame(width: box.width, height: box.height)
    }

    private func fitSize(_ image: CGImage, box: CGSize) -> CGSize {
        let w = max(1, CGFloat(image.width))
        let h = max(1, CGFloat(image.height))
        let scale = min(box.width / w, box.height / h)
        return CGSize(width: w * scale, height: h * scale)
    }

    private func tag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .frame(height: 21)
            .background(Capsule().fill(Chip.fill))
    }

    @ViewBuilder
    private func divider(box: CGSize) -> some View {
        if studio.baseImage != nil {
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

    private func dragGesture(box: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard mode == .split else { return }
                if !draggingDivider {
                    let dividerX = box.width * split
                    // 离分界线太远就不抢这一次拖动，避免误触
                    guard abs(value.startLocation.x - dividerX) < 30 else { return }
                    draggingDivider = true
                }
                split = min(1, max(0, value.location.x / max(1, box.width)))
            }
            .onEnded { _ in draggingDivider = false }
    }

    // MARK: 参数

    private var paramsPane: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 11) {
                // 只在"确实有一套调色被压住了"的时候才警告。
                // 上一版只看档位是不是「无损保真」，于是没挂任何 LUT 时也会弹一个
                // "调色当前不生效" —— 用户照着自己的屏幕读，只会一头雾水。
                if blockedByPristine { pristineWarning }

                currentLUTBlock
                intensityBlock
                spaceBlock
                knobGroup(title: "查表前", knobs: preKnobs)
                knobGroup(title: "查表后", knobs: postKnobs)
                resetRow
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .background(Theme.panel)
    }

    private var pristineWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                Text("调色当前不生效")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(Theme.warn)

            Text("「无损保真」这一档承诺像素不变，和调色互斥 —— 引擎会整段跳过调色，不是偷偷改掉你的图。")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // 这里原本是一颗红色实心按钮。它坐在琥珀色警告框里 —— 一个框两种告警色，
            // 而且调色室真正的主操作（底部的应用 / 导出）被它抢了。改中性。
            InlineActionButton(title: "改用「高质量」档") {
                model.settings.quality = StrengthPreset.high.quality
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.warn.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.warn.opacity(0.35), lineWidth: 1)
        )
    }

    private var currentLUTBlock: some View {
        SettingsSection(title: "当前 LUT") {
            if let path = draft.lutPath {
                HStack(spacing: 10) {
                    lutThumb(forPath: path)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(LUTLibrary.shared.displayName(forPath: path))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(lutStatusLine(path))
                            .font(.system(size: 9.5))
                            .foregroundStyle(LUTLibrary.shared.entry(forPath: path) == nil
                                             ? Theme.bad : Theme.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Button {
                        clearLUT()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Theme.wash(0.07))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("不用 LUT，只留旋钮")
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text("没有套用 LUT")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text("下面挑一条，或者只用旋钮调色")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private func lutThumb(forPath path: String) -> some View {
        let entry = LUTLibrary.shared.entry(forPath: path)
        let image = entry.flatMap { studio.thumbs["\($0.fileName)|\($0.fileBytes)"] }
        return ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.wash(0.05))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(systemName: "camera.filters")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: 52, height: 34)
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private func lutStatusLine(_ path: String) -> String {
        guard let entry = LUTLibrary.shared.entry(forPath: path) else {
            return "文件不在库里，可能是被移走了"
        }
        var parts: [String] = []
        if let size = entry.sizeLabel { parts.append(size) }
        if let subtitle = entry.subtitle { parts.append(subtitle) }
        return parts.isEmpty ? entry.fileName : parts.joined(separator: " · ")
    }

    private var intensityBlock: some View {
        SettingsSection(title: "强度") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(Int((draft.intensity * 100).rounded()))%")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(draft.lutPath == nil ? Theme.textTertiary : Theme.textPrimary)
                    Spacer()
                    Text("和原图的比例混合")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                FineSlider(
                    value: $draft.intensity,
                    range: LUTGrade.intensityRange,
                    neutral: 1
                )
                .disabled(draft.lutPath == nil)
                .opacity(draft.lutPath == nil ? 0.45 : 1)
            }
        }
    }

    private var spaceBlock: some View {
        SettingsSection(title: "工作色彩空间") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(LUTWorkingSpace.allCases) { space in
                        ChoiceChip(title: space.title,
                                   selected: draft.workingSpace == space) {
                            selectSpace(space)
                        }
                    }
                }

                Text(spaceNote)
                    .font(.system(size: 9.5))
                    .foregroundStyle(spaceIsWarned ? Theme.warn.opacity(0.95) : Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var profile: LUTProfile? {
        guard let path = draft.lutPath else { return nil }
        return LUTLibrary.shared.profile(forPath: path)
    }

    private var spaceNote: String {
        if let hint = profile?.hint { return hint }
        if draft.lutPath == nil { return "没套 LUT 时这项不影响结果" }
        // 只补 detail 里没有的那半句，别把同一件事说两遍
        return "\(draft.workingSpace.detail)。颜色明显不对时再改。"
    }

    private var spaceIsWarned: Bool {
        guard draft.lutPath != nil, let p = profile else { return false }
        return p.looksLikeLog || p.isNeutral || p.inputFloor > 0.25 || p.unusualDomain != nil
    }

    private struct Knob {
        let title: String
        let keyPath: WritableKeyPath<LUTGrade, Double>
        let range: ClosedRange<Double>
        let neutral: Double
        let format: (Double) -> String
    }

    private var preKnobs: [Knob] {
        [
            Knob(title: "曝光", keyPath: \.exposure, range: LUTGrade.exposureRange,
                 neutral: 0) { String(format: "%+.2f", $0) },
            Knob(title: "对比", keyPath: \.contrast, range: LUTGrade.contrastRange,
                 neutral: 1) { String(format: "%.2f", $0) },
            Knob(title: "色温", keyPath: \.warmth, range: LUTGrade.warmthRange,
                 neutral: 0) { String(format: "%+.2f", $0) },
        ]
    }

    private var postKnobs: [Knob] {
        [
            Knob(title: "饱和", keyPath: \.saturation, range: LUTGrade.saturationRange,
                 neutral: 1) { String(format: "%.2f", $0) },
            Knob(title: "暗部", keyPath: \.shadows, range: LUTGrade.shadowsRange,
                 neutral: 0) { String(format: "%+.2f", $0) },
        ]
    }

    private func knobGroup(title: String, knobs: [Knob]) -> some View {
        SettingsSection(title: title) {
            VStack(spacing: 5) {
                ForEach(knobs, id: \.title) { knob in
                    knobRow(knob)
                }
            }
        }
    }

    private func knobRow(_ knob: Knob) -> some View {
        let value = draft[keyPath: knob.keyPath]
        let moved = abs(value - knob.neutral) > 0.001
        return HStack(spacing: 8) {
            Text(knob.title)
                .font(.system(size: 10.5, weight: moved ? .semibold : .regular))
                .foregroundStyle(moved ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 28, alignment: .leading)

            // 用自绘的 `FineSlider`，不是系统 `Slider`。三点差别：
            // 填充从**中性位**出发（这几根参数的中性位没有一根在左端）、
            // 拖动中不做隐式动画（跟手）、双击归中位。
            // 详见 `Controls.swift` 里那一段说明。
            FineSlider(
                value: Binding(
                    get: { draft[keyPath: knob.keyPath] },
                    set: { draft[keyPath: knob.keyPath] = $0 }
                ),
                range: knob.range,
                neutral: knob.neutral
            )

            Text(knob.format(value))
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(moved ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 34, alignment: .trailing)
                .monospacedDigit()
        }
    }

    private var resetRow: some View {
        HStack(spacing: 8) {
            Button("把旋钮归位") {
                draft.resetKnobs()
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(draft.adjustedKnobCount == 0)

            Spacer(minLength: 0)

            Text(draft.adjustedKnobCount == 0
                 ? "旋钮都在中性位"
                 : "已调整 \(draft.adjustedKnobCount) 项")
                .font(.system(size: 9.5, weight: draft.adjustedKnobCount == 0 ? .regular : .semibold))
                .foregroundStyle(draft.adjustedKnobCount == 0 ? Theme.textTertiary : Theme.textPrimary)
        }
    }

    // MARK: LUT 库

    private var libraryPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("LUT 库")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                Text("\(library.entries.count) 条")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)

                if library.entries.isEmpty {
                    Text("· 把 .cube 拖到这里，或点右边「导入」")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Text("缩略图 = 你这张图套用该 LUT 100% 强度的效果")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)

                Button("导入 .cube…") { importLUTs() }
                    .buttonStyle(GhostButtonStyle())
                Button("打开库文件夹") { NSWorkspace.shared.open(library.folder) }
                    .buttonStyle(GhostButtonStyle())
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    noneCard
                    ForEach(library.entries) { entry in
                        card(entry)
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(height: 142)
        .background(Theme.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(Theme.accent, lineWidth: dropTargeted ? 2 : 0)
        )
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var noneCard: some View {
        let selected = draft.lutPath == nil
        return VStack(spacing: 4) {
            cardThumb(image: nsImage(studio.baseImage), selected: selected, warning: false)
            VStack(alignment: .leading, spacing: 1) {
                Text("不套用")
                    .font(.system(size: 9.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(effectiveActive ? "只用旋钮" : "原图直出")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 104, alignment: .leading)
        }
        .frame(width: 104)
        .contentShape(Rectangle())
        .onTapGesture { clearLUT() }
        .help("不套 LUT。旋钮仍然生效")
    }

    private func card(_ entry: LUTEntry) -> some View {
        let selected = draft.lutPath == entry.url.path
        let broken = entry.problem != nil
        let image = studio.thumbs["\(entry.fileName)|\(entry.fileBytes)"]

        return VStack(spacing: 4) {
            cardThumb(image: image, selected: selected, warning: broken)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName)
                    .font(.system(size: 9.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(broken ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(entry.problem != nil
                     ? "读不了"
                     : (entry.sizeLabel ?? "—"))
                    .font(.system(size: 8.5))
                    .foregroundStyle(broken ? Theme.bad : Theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(width: 104, alignment: .leading)
        }
        .frame(width: 104)
        .contentShape(Rectangle())
        .onTapGesture { if !broken { pick(entry) } }
        .help(entry.problem ?? entry.subtitle ?? entry.fileName)
        .task(id: "\(entry.id)#\(studio.baseToken)#\(library.workingSpace(for: entry).rawValue)") {
            guard !broken else { return }
            studio.requestThumbnail(for: entry, space: library.workingSpace(for: entry))
        }
        .contextMenu {
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
            Button("重命名…") {
                renameTarget = entry
                renameText = entry.displayName
                renaming = true
            }
            Divider()
            Button("从库里删除") { delete(entry) }
        }
    }

    /// CGImage → NSImage。必须带上真实像素尺寸：
    /// 传 .zero 的话 SwiftUI 那边量出来是零宽高，卡片就成空的了。
    private func nsImage(_ cg: CGImage?) -> NSImage? {
        guard let cg else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func cardThumb(image: NSImage?, selected: Bool, warning: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.wash(0.05))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.warn)
            } else {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }

            if selected {
                VStack {
                    HStack {
                        Spacer()
                        // 角标走 `Chip` 恒定色：底下是缩略图，深浅不可预知，
                        // 一只纯白的对勾压在雪景上就等于没有
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Chip.text)
                            .background(Circle().fill(Chip.fill).padding(-1.5))
                    }
                    Spacer()
                }
                .padding(5)
            }
        }
        .frame(width: 104, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // 选中不再用品牌红描边 —— 那是"一排里选中一个"，不是主操作。
        // 但也不能简单换成中性灰：底下是照片，中性灰在深色照片上会消失。
        // 所以是一圈白环垫一圈深色（`Chip.ring` 那两条），深浅底都能立住；
        // 认出"选了哪个"主要还是靠角上那个对勾，环只负责把卡片框出来。
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Chip.ringShadow : Theme.border,
                              lineWidth: selected ? 3.5 : 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Chip.ring : .clear, lineWidth: selected ? 2 : 0)
        )
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 12) {
            if let toast {
                HStack(spacing: 6) {
                    Image(systemName: toastBad ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11))
                    Text(toast)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(toastBad ? Theme.bad : Theme.good)
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusTint)
                        .frame(width: 6, height: 6)
                    Text(statusLine)
                        .font(.system(size: 10.5))
                        .foregroundStyle(statusTint)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // 「取消全部调色」放在最靠左的动作位，离右边那颗主操作最远。
            // 它不是"取消这次操作"，而是把这批图上的调色全部撤掉 ——
            // 一个会改掉整批结果的动作，不该挤在主操作旁边。
            Button("取消全部调色") { cancelAllGrading() }
                .buttonStyle(GhostButtonStyle(tint: hasAnyGrade ? Theme.textPrimary : Theme.textTertiary))
                .disabled(!hasAnyGrade)
                .help(hasAnyGrade
                      ? "把全部 \(batchCount) 张的调色撤掉，回到没调色的原图"
                      : "现在没有调色可取消")

            Button("导出这一张…") { exportImage() }
                .buttonStyle(GhostButtonStyle(tint: effectiveActive ? Theme.textPrimary : Theme.textTertiary))
                .disabled(!effectiveActive || studio.baseURL == nil)
                .help(effectiveActive
                      ? "只把这张预览底图按全尺寸导出，不缩尺寸 —— 想批量导出走右边那颗"
                      : exportBlockedReason)

            Button("导出 .cube…") { exportCube() }
                .buttonStyle(GhostButtonStyle(tint: effectiveActive ? Theme.textPrimary : Theme.textTertiary))
                .disabled(!effectiveActive)
                .help(effectiveActive
                      ? "把当前参数烘焙成 33³ 的 .cube，可给 Premiere / 达芬奇 / PS 用"
                      : exportBlockedReason)

            applyButton
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    /// 这颗是调色室的主操作，也是整个窗口唯一的品牌红。
    ///
    /// 它是**真按钮**：按下去才把草稿提交成批量参数。上一版没有草稿，
    /// 滑块一动就已经生效了 —— 那种设计里再放一颗"应用"只会是摆设。
    ///
    /// 红色跟着"下一步该做的事"走，共三态：
    /// - 有调色、没应用 → 「应用到全部 N 张」
    /// - 有调色、已应用 → 「回主窗口开始压缩」（把用户送去下一步，而不是
    ///   留一颗变淡的"已完成"按钮杵在那儿 —— 那看着像坏了）
    /// - 没调色 → 一颗中性「完成」，此时窗口里一个红都没有，是对的：
    ///   没东西可应用，就不该有一个主操作在喊
    @ViewBuilder
    private var applyButton: some View {
        if !effectiveActive {
            Button("完成") { requestClose() }
                .buttonStyle(GhostButtonStyle(tint: Theme.textPrimary))
                .help("参数都还在中性位，没有什么要应用的")
        } else if dirty || !model.settings.grade.isActive {
            Button {
                applyToAll()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("应用到全部 \(batchCount) 张")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .help("把这套参数写进这 \(batchCount) 张的压缩管线，之后回主窗口批量导出")
        } else {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                    Text("回主窗口开始压缩")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .help("已应用。回主窗口点「开始压缩」就是批量导出调色后的压缩图")
        }
    }

    // MARK: 状态

    /// 有任何一处挂着调色（草稿或已提交的）就算"有调色"
    private var hasAnyGrade: Bool {
        draft.isActive || model.settings.grade.isActive
    }

    private var statusTint: Color {
        if blockedByPristine { return Theme.warn }
        if dirty { return Theme.warn }
        if model.settings.grade.isActive { return Theme.good }
        return Theme.textTertiary
    }

    private var statusLine: String {
        if blockedByPristine {
            return "调色当前不生效：「无损保真」档承诺像素不变，先把档位换成「高质量」"
        }
        if dirty {
            return "有改动还没应用 —— 右边「应用到全部 \(batchCount) 张」之后才会写进批量"
        }
        if model.settings.grade.isActive {
            return "已应用到全部 \(batchCount) 张 · 回主窗口点「开始压缩」就是批量导出调色后的压缩图"
        }
        return "参数都还在中性位，先挑一条 LUT 或动一动旋钮"
    }

    private var exportBlockedReason: String {
        if blockedByPristine {
            return "「无损保真」档下调色不生效，先把档位换成「高质量」"
        }
        return "还没调任何参数"
    }

    private func syncBase() {        studio.setBase(model.previewBaseURL)
    }

    // MARK: 操作
    //
    // 这一组全都只改 `draft`，一个字节都不落到设置里 —— 提交统一走 `applyToAll()`。
    // 分界线画在这里，"哪一步会真的影响批量"就是一目了然的。

    /// 提交：把草稿写进设置，从此它参与这 \(batchCount) 张的压缩。
    private func applyToAll() {
        model.settings.grade = draft
        showToast("已应用到全部 \(batchCount) 张 · 回主窗口点「开始压缩」批量导出")
    }

    /// 撤销：把这批图上的调色整个撤掉。
    ///
    /// 草稿和已提交的两边都要清 —— 只清草稿的话，用户按完发现"已应用"那套还在
    ///（状态行的绿点还亮着），会以为按钮没生效。
    private func cancelAllGrading() {
        draft = LUTGrade()
        model.settings.grade = LUTGrade()
        studio.schedulePreview(grade: LUTGrade())
        showToast("已取消全部调色，\(batchCount) 张都回到没调色的原图")
    }

    /// 关窗。草稿没提交时先问一句 —— 见 `body` 上那段说明。
    private func requestClose() {
        if dirty {
            confirmingClose = true
        } else {
            dismiss()
        }
    }

    /// 供确认框文案用。数的是"和已提交那套不一样的参数项"，
    /// 比"动了几根滑块"更准：同一根来回拖回原位不算改动。
    private var changedKnobCount: Int {
        var count = 0
        if draft.lutPath != model.settings.grade.lutPath { count += 1 }
        if abs(draft.intensity - model.settings.grade.intensity) > 0.001 { count += 1 }
        if draft.workingSpace != model.settings.grade.workingSpace { count += 1 }
        if abs(draft.exposure - model.settings.grade.exposure) > 0.001 { count += 1 }
        if abs(draft.contrast - model.settings.grade.contrast) > 0.001 { count += 1 }
        if abs(draft.warmth - model.settings.grade.warmth) > 0.001 { count += 1 }
        if abs(draft.saturation - model.settings.grade.saturation) > 0.001 { count += 1 }
        if abs(draft.shadows - model.settings.grade.shadows) > 0.001 { count += 1 }
        return count
    }

    private func pick(_ entry: LUTEntry) {
        draft.lutPath = entry.url.path
        draft.workingSpace = library.workingSpace(for: entry)
        if draft.intensity <= 0.001 { draft.intensity = 1 }
    }

    private func clearLUT() {
        draft.lutPath = nil
    }

    private func selectSpace(_ space: LUTWorkingSpace) {
        draft.workingSpace = space
        // 顺手把这个判断记在库里：下次再选这条 LUT 还是同一个色彩空间。
        // 这是"库的元数据"，不是"这批图的参数"，所以直接落库，不走草稿。
        if let path = draft.lutPath, let entry = library.entry(forPath: path) {
            library.setWorkingSpace(space, for: entry)
        }
    }

    private func delete(_ entry: LUTEntry) {
        let wasSelected = draft.lutPath == entry.url.path
        guard library.remove(entry) else {
            showToast("删除失败，文件可能被占用了", bad: true)
            return
        }
        studio.forgetThumbnail(for: entry)
        if wasSelected { clearLUT() }
        showToast("已移到废纸篓：\(entry.displayName)")
    }

    private func commitRename() {
        guard let entry = renameTarget else { return }
        let wasSelected = draft.lutPath == entry.url.path
        if let problem = library.rename(entry, to: renameText) {
            showToast(problem, bad: true)
            return
        }
        if wasSelected {
            // 库里的文件名就是路径的一部分，改完得把草稿指向新路径
            draft.lutPath = library.entries.first {
                $0.displayName == renameText.trimmingCharacters(in: .whitespacesAndNewlines)
            }?.url.path
        }
        renameTarget = nil
        showToast("已改名")
    }

    private func importLUTs() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "导入"
        panel.message = "选择 .cube 文件（会拷进 App 的 LUT 库，原文件不动）"
        if let type = UTType(filenameExtension: "cube") {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK else { return }
        performImport(panel.urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var resolved: URL?
                if let url = item as? URL {
                    resolved = url
                } else if let data = item as? Data {
                    resolved = URL(dataRepresentation: data, relativeTo: nil)
                }
                if let resolved {
                    lock.lock(); found.append(resolved); lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [self] in
            performImport(found)
        }
        return true
    }

    private func performImport(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let report = library.importFiles(urls)
        importReport = report

        if report.imported.count == 1, report.skipped.isEmpty,
           let only = report.imported.first,
           let entry = library.entries.first(where: { $0.fileName == only }) {
            // 只导入一条就直接选上，省一步点击
            pick(entry)
            showToast("已导入并选中：\(entry.displayName)")
            return
        }
        if report.total <= 1 {
            showToast(report.skipped.first.map { "\($0.name)：\($0.reason)" } ?? "没有可导入的文件",
                      bad: !report.skipped.isEmpty)
            return
        }
        showingImportReport = true
    }

    private var importMessage: String {
        guard let report = importReport else { return "" }
        var lines: [String] = [report.summary]
        if !report.skipped.isEmpty {
            lines.append("")
            lines.append(contentsOf: report.skipped.prefix(6).map { "· \($0.name)：\($0.reason)" })
            if report.skipped.count > 6 {
                lines.append("· 还有 \(report.skipped.count - 6) 条，理由类似")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func exportImage() {
        guard let source = studio.baseURL else { return }
        let current = effective
        let panel = NSSavePanel()
        let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension.lowercased()
        panel.nameFieldStringValue =
            "\(source.deletingPathExtension().lastPathComponent)_调色.\(ext)"
        panel.prompt = "导出"
        panel.message = "导出全尺寸的调色结果，不缩尺寸、不做体积搜索"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            let bytes = try studio.exportGraded(source: source, grade: current, to: destination)
            showToast("已导出 \(Fmt.compact(bytes)) → \(destination.lastPathComponent)")
        } catch {
            showToast("导出失败：\(error.localizedDescription)", bad: true)
        }
    }

    private func exportCube() {
        let current = effective
        let panel = NSSavePanel()
        panel.nameFieldStringValue = bakeName()
        panel.prompt = "导出"
        panel.message = "把当前参数烘焙成 33³ 的 .cube。进度条上没有的强度也一起烘进去了"
        guard panel.runModal() == .OK, let picked = panel.url else { return }

        let destination = picked.pathExtension.lowercased() == "cube"
            ? picked
            : picked.appendingPathExtension("cube")

        do {
            let text = try studio.bakeCube(current)
            try Data(text.utf8).write(to: destination, options: .atomic)
            showToast("已导出 .cube → \(destination.lastPathComponent)")
        } catch {
            showToast("烘焙失败：\(error.localizedDescription)", bad: true)
        }
    }

    private func bakeName() -> String {
        var base = "调色"
        if let path = draft.lutPath {
            base = "\(LUTLibrary.shared.displayName(forPath: path))_调色"
        }
        let pct = Int((draft.intensity * 100).rounded())
        let name = (draft.lutPath != nil && pct < 100) ? "\(base)_强度\(pct)" : base
        return "\(name).cube"
    }

    private func showToast(_ text: String, bad: Bool = false) {
        toast = text
        toastBad = bad
    }
}
