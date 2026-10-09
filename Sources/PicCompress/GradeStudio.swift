import Foundation
import Combine
import CoreGraphics
import AppKit

/// 跨线程搬运 CGImage。CGImage 本身是不可变的，可以安全地在线程间传，
/// 但它没有标 Sendable，所以要包一层。
struct SendableCGImage: @unchecked Sendable {
    let image: CGImage?
    init(_ image: CGImage?) { self.image = image }
}

/// 调色室的状态与算力调度。
///
/// 三件事：
/// 1. 把用户的第一张图解码成一张小底图（预览和 LUT 缩略图都用它）
/// 2. 参数一变就重算预览（带防抖，拖动滑块时不会排队堆起来）
/// 3. 给 LUT 卡片出缩略图 —— 用**用户自己的图**渲染，
///    这样一眼就能看出这条 LUT 会对自己的照片做什么，比看通用色卡有用得多
@MainActor
final class GradeStudio: ObservableObject {

    static let shared = GradeStudio()

    // MARK: 分辨率
    //
    // 上一版这里只有一个 `baseEdge = 760`，底图解码到 760，预览也就按 760 渲染。
    // 但预览面板是 653×526pt —— 在 2x 屏上要 1306×1052 个像素才够。
    // 760 的图铺上去等于放大了 1.7 倍，所以看着"不是高清"。
    //
    // 现在分三档：
    // - 底图解码上限取够大的 2048，一次解码反复用；
    // - 拖动滑块时只按 820 渲染 —— 这一步的唯一任务是"立刻给个大概"，
    //   768 级的查表 + 编码在这个尺寸下是十几毫秒量级，跟手；
    // - 手停下来之后（静默 260ms）再按 1320 补一帧，
    //   这一帧正好覆盖面板在 2x 屏上的物理像素，落到屏幕上是 1:1，锐。
    //
    // 关键在于**顺序**：先缩到目标尺寸再查表，而不是查完表再缩。
    // 反过来的话每帧都要在全分辨率上跑一遍 Core Image 管线，白烧几倍算力 ——
    // 这正是"拖起来卡"的主要来源。

    /// 底图解码上限
    nonisolated static let baseEdge = 2048
    /// 拖动 / 连续调整时的快速档最长边
    nonisolated static let interactiveEdge = 820
    /// 手停下来之后补的那一帧。1320 是照 960 宽的窗口算出来的：
    /// 预览面板 653pt 宽，2x 屏 = 1306px，取整到 1320 刚好覆盖。
    nonisolated static let crispEdge = 1320
    /// 卡片缩略图的最长边。卡片是 104×60pt，竖图按 fill 铺满要 208×277px。
    nonisolated static let thumbEdge = 420

    /// 连续调整时的防抖。上一版是 120ms，是"跟手"和"别排一队"
    /// 之间取的折中；现在快速档只要十几毫秒，可以再激进一点。
    nonisolated static let fastDebounce: UInt64 = 55_000_000
    /// 判断"用户停手了"的静默期
    nonisolated static let settleDelay: UInt64 = 260_000_000

    @Published private(set) var baseURL: URL?
    @Published private(set) var baseImage: CGImage?
    @Published private(set) var previewImage: CGImage?
    /// 当前这一帧是快速档还是高清档。界面靠它决定要不要提示"正在细化…"
    @Published private(set) var previewIsCrisp = false
    @Published private(set) var preparing = false
    @Published private(set) var rendering = false
    @Published private(set) var thumbs: [String: NSImage] = [:]
    /// 底图每换一次就 +1。LUT 卡片靠它重新出缩略图 ——
    /// CGImage 没法比较，直接用计数当触发信号最省事
    @Published private(set) var baseToken = 0

    /// 每次请求自增。异步结果回来时对不上号就直接丢掉，
    /// 否则快速拖动滑块会出现"旧参数的结果盖住新参数"
    private var generation = 0
    private var prepareTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var pendingThumbs = Set<String>()

    private init() {}

    // MARK: 底图

    /// 换一张底图。传 nil 表示列表空了，预览跟着清掉。
    func setBase(_ url: URL?) {
        let normalized = url?.standardizedFileURL
        guard normalized != baseURL else { return }

        baseURL = normalized
        baseImage = nil
        previewImage = nil
        thumbs.removeAll()
        pendingThumbs.removeAll()
        generation += 1
        prepareTask?.cancel()
        renderTask?.cancel()

        guard let normalized else {
            preparing = false
            rendering = false
            return
        }

        preparing = true
        prepareTask = Task { [weak self] in
            let box = await Task.detached(priority: .userInitiated) {
                SendableCGImage(ImageCompressor.previewImage(
                    for: normalized, maxPixel: GradeStudio.baseEdge
                ))
            }.value
            guard let self, !Task.isCancelled, self.baseURL == normalized else { return }
            self.baseImage = box.image
            self.preparing = false
            self.baseToken += 1
            // 这里**不**渲染第一帧。
            //
            // 上一版在这调了一次 `renderNow(LUTGrade())`，而 `renderNow` 是同步的、
            // 又跑在主线程上 —— 底图只有 760 时看不出来，提到 2048 之后
            // 这一下会直接卡住界面。真正该出图的那一帧由界面上的
            // `onChange(of: baseToken)` 触发 `schedulePreview`，本来就会来。
            // 两处都发等于把同一张图算两遍，其中一遍还是同步的。
        }
    }

    /// 换图时把预览相关的状态一并复位
    func clearBase() {
        setBase(nil)
    }

    // MARK: 预览

    /// 面板上每动一下滑块都会调这里。
    ///
    /// 两帧走法：
    /// 1. **快速档**（820）。短防抖之后立刻出 —— 拖动时眼睛要的是"颜色往哪边走了"，
    ///    这个尺寸完全够看，而且只要十几毫秒，跟得上手。
    /// 2. **高清档**（1320）。手停下来静默 260ms 之后再补一帧，
    ///    这一帧正好是面板在 2x 屏上的物理像素数，落到屏幕上是 1:1。
    ///
    /// 两帧之间**不换尺寸、不换位置**，所以肉眼看到的只是"变清楚了"，
    /// 不会有画面跳动。这就是"丝滑"和"高清"能同时成立的原因 ——
    /// 不是靠把单帧做得又大又快，而是把"跟手"和"精细"拆成两件事。
    func schedulePreview(grade: LUTGrade) {
        generation += 1
        let token = generation
        renderTask?.cancel()

        guard let base = baseImage else {
            previewImage = nil
            previewIsCrisp = false
            rendering = false
            return
        }
        let box = SendableCGImage(base)
        let fast = GradeStudio.interactiveEdge
        let crisp = max(fast, GradeStudio.crispEdge)

        renderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: GradeStudio.fastDebounce)
            guard let self, !Task.isCancelled else { return }

            self.rendering = true
            self.previewIsCrisp = false
            // 必须走 `Task.detached` 显式切走。
            //
            // `Self.render` 是 `nonisolated` 而且是同步的 —— 直接调用（哪怕写个
            // `await`）它会**在当前线程上跑完**，而这里的当前线程就是主线程。
            // 编译器那句 "no 'async' operations occur within 'await' expression"
            // 说的正是这件事：那个 `await` 没换来任何东西。2048 的降采样 + 查表
            // 放主线程上，界面就是一顿一顿的。
            let source = box.image ?? base
            let quick = await Task.detached(priority: .userInitiated) {
                Self.render(source, grade: grade, maxPixel: fast)
            }.value
            guard !Task.isCancelled, token == self.generation else { return }
            self.previewImage = quick
            self.rendering = false

            // 这次调整如果本来就只到快速档的分辨率，就没什么可补的了
            guard crisp > fast, token == self.generation else { return }

            try? await Task.sleep(nanoseconds: GradeStudio.settleDelay)
            guard !Task.isCancelled, token == self.generation else { return }

            let sharp = await Task.detached(priority: .userInitiated) {
                Self.render(source, grade: grade, maxPixel: crisp)
            }.value
            guard !Task.isCancelled, token == self.generation else { return }
            self.previewImage = sharp
            self.previewIsCrisp = true
        }
    }

    /// 降采样 → 查表。**顺序不能反**：先缩再查，每帧的开销只跟显示尺寸有关；
    /// 反过来就是每帧都在原分辨率上跑一遍 Core Image 管线。
    nonisolated private static func render(
        _ base: CGImage,
        grade: LUTGrade,
        maxPixel: Int
    ) -> CGImage {
        let scaled = ImageCompressor.downscale(base, maxPixel: maxPixel)
        guard grade.isActive else { return scaled }
        return (try? LUTEngine.apply(scaled, grade: grade)) ?? scaled
    }

    // MARK: LUT 卡片缩略图

    /// 卡片上要展示的是**这条 LUT 本来的样子**，所以固定 100% 强度、不加任何旋钮。
    /// 用户想看叠加了旋钮的效果，看上面的大预览就够了。
    ///
    /// 色彩空间用这条 LUT 在库里的标注值 —— 缩略图应该反映它真实的效果，
    /// 而不是某个"通用"假设。
    func requestThumbnail(for entry: LUTEntry, space: LUTWorkingSpace) {
        let key = Self.thumbKey(entry)
        guard thumbs[key] == nil, !pendingThumbs.contains(key) else { return }
        guard let base = baseImage else { return }

        pendingThumbs.insert(key)
        let box = SendableCGImage(base)

        Task.detached(priority: .utility) { [weak self] in
            var grade = LUTGrade()
            grade.lutPath = entry.url.path
            grade.intensity = 1
            grade.workingSpace = space

            // 走和预览同一条路：先把 2048 的底图缩到缩略图尺寸再查表。
            // 上一版是直接在全尺寸上查完表再交给 SwiftUI 缩 —— 缩略图那一栏
            // 一次要出十几张，每张都在 760 上跑一遍管线的开销是白花的。
            let out = Self.render(
                box.image ?? base, grade: grade, maxPixel: GradeStudio.thumbEdge
            )
            await self?.finishThumbnail(key: key, box: SendableCGImage(out))
        }
    }

    private func finishThumbnail(key: String, box: SendableCGImage) {
        pendingThumbs.remove(key)
        guard let image = box.image else { return }
        thumbs[key] = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    /// 底图还没解码完时，卡片先空着；这个键带上文件大小，
    /// 用户换掉了同名文件会自动重新出图
    private static func thumbKey(_ entry: LUTEntry) -> String {
        "\(entry.fileName)|\(entry.fileBytes)"
    }

    /// 从库里删掉一条 LUT 之后，把它的缩略图也扔掉，别让缓存一直占着
    func forgetThumbnail(for entry: LUTEntry) {
        thumbs.removeValue(forKey: Self.thumbKey(entry))
    }

    // MARK: 导出

    /// 把当前参数烘焙成 .cube 文本
    func bakeCube(_ grade: LUTGrade, dimension: Int = 33) throws -> String {
        try LUTEngine.bake(grade: grade, dimension: dimension)
    }

    /// 把某张图的调色结果写到目标路径。返回写出的字节数。
    @discardableResult
    func exportGraded(source: URL, grade: LUTGrade, to destination: URL) throws -> Int {
        try ImageCompressor.exportGraded(source: source, grade: grade, to: destination)
        return ImageCompressor.fileSize(destination)
    }
}
