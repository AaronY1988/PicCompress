import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

// MARK: - 跨线程搬运 NSImage

struct SendableImage: @unchecked Sendable {
    let image: NSImage?
    init(_ image: NSImage?) { self.image = image }
}

// MARK: - 列表中的一张图片

@MainActor
final class ImageItem: ObservableObject, Identifiable {
    let id = UUID()
    let job: CompressJob

    @Published var thumbnail: NSImage?
    /// 已经排进缩略图队列（在途或待办）。**不是** `@Published` ——
    /// 它只用来防重复排队，变了不需要重画任何东西。
    var thumbnailPending = false
    @Published var originalBytes: Int
    @Published var state: ItemState = .pending
    @Published var outputBytes: Int = 0
    @Published var outputURL: URL?
    /// 按体积压缩时没能压到目标以下
    @Published var targetMissed = false
    /// 实际使用的质量（按体积压缩时由搜索决定）
    @Published var usedQuality: Double?
    /// 这一张是不是挂着调色压出来的（对比预览上要标出来）
    @Published var graded = false

    init(job: CompressJob) {
        self.job = job
        self.originalBytes = ImageCompressor.fileSize(job.url)
    }

    var url: URL { job.url }
    var name: String { job.url.lastPathComponent }

    var relativeDir: String { job.relativeDir }

    var folder: String {
        let parent = job.url.deletingLastPathComponent()
        let base = job.root.path
        if job.root != job.url.deletingLastPathComponent(),
           parent.path.hasPrefix(base) {
            let tail = String(parent.path.dropFirst(base.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !tail.isEmpty {
                return "\(job.root.lastPathComponent)/\(tail)"
            }
        }
        return parent.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var savedPercent: Int? {
        if case .done(_, let p) = state { return p }
        return nil
    }
}

// MARK: - 整批的预估

/// 「这批压完大概多大」。
///
/// 这个数字是**量出来的，不是估出来的**：按**源格式**分组，每组挑最大的那张，
/// 按当前设置真压一遍，再用各自的比例按体积加权外推到整批。
///
/// **为什么是按源格式，而不是按"照片 / 截图"这种图片类型**：
/// 实测这一批里 JPEG 压 10%、PNG 压 31%、HEIC 压 79% —— 拉开这么大差距的
/// 主要是源格式（HEIC 里已经压过一道，重编码的损失曲线完全是另一回事），
/// 而不是"它是照片还是截图"。先按图片类型分过，那三张会被归成同一类
/// （demo 里那张截图并不满足截图的判定），等于白分，报出来还是 79%。
///
/// 按源格式分之后：2.6×0.92 + 3.4×0.70 + 5.1×0.21 ≈ 5.8 MB —— 和真压完
/// 的 5.8 MB 对得上。而只抽最大那张会报 2.3 MB，差一倍还多。
///
/// 为什么不按经验乘个系数：那样更省事，写出来的数字也一样精确到整数，
/// 但它跟实际结果没关系。而这个数字是用户**决定要不要按下去**的依据 ——
/// 报一个比真实结果乐观的数，等于骗他按下按钮。
///
/// 外推仍然是近似的，所以样本是怎么来的必须带到界面上（`sampleText`）。
struct BatchEstimate: Equatable, Sendable {
    /// 被抽中实测的那几张（按源格式分组，每组一张）
    let sampleNames: [String]
    /// 抽样覆盖了几种源格式
    let groupCount: Int
    /// 外推到整批的预计输出体积
    let projectedBytes: Int
    /// 待压这批的原体积
    let originalBytes: Int

    var savingPercent: Int {
        Fmt.savePercent(from: originalBytes, to: projectedBytes)
    }

    /// 「抽样自 xx.jpg」/「3 种格式各抽一张」
    var sampleText: String {
        if groupCount <= 1 {
            return "抽样自 \(sampleNames.first ?? "其中一张")"
        }
        return "\(groupCount) 种格式各抽一张"
    }
}

/// 一种源格式的实测结果。
///
/// 单独开一个类型而不是用元组：`TaskGroup` 的元素必须满足 `Sendable`，
/// 而元组不 conform 这个协议 —— 用元组编译器会直接拒绝。
private struct FormatProbe: Sendable {
    let groupBytes: Int
    let sampleName: String
    let ratio: Double
}

// MARK: - 应用状态

/// 一次扫描会话。
///
/// 有它就是"报告界面开着"，没有就是关着 —— 拿可选值当开关，
/// 少一个能和它不同步的布尔量。
struct ScanState {
    enum Phase: Equatable {
        /// 还在翻。（done / total 文件夹那侧给不出 —— 要遍历完才知道总数）
        case scanning(done: Int, total: Int)
        /// 结果就绪，等用户挑
        case ready
        case failed(String)
    }

    let source: ScanSource
    var candidates: [ScanCandidate] = []
    var phase: Phase = .ready

    /// 这次扫描有哪些东西**没问出来**。非空就要在报告里照实说。
    ///
    /// 它是"诚实的缺口"：降级值本身是保守的（不会误伤任何一张图），
    /// 但用户在报告里看到的是数字，不主动说，他无从知道哪个数字是猜的。
    var notes: [String] = []
}

@MainActor
final class AppModel: ObservableObject {

    @Published var items: [ImageItem] = []
    @Published var settings: CompressSettings = SettingsStore.load()

    @Published var isRunning = false
    @Published var finishedCount = 0
    @Published var batchCount = 0

    // MARK: 分批与暂停
    //
    // 分批的意义是**给出可以停下来的地方**（见 `BatchPlan`）。所以下面这几个
    // 状态必须分开，不能让一个布尔量兼职：
    //
    // - `pauseRequested`：用户按了暂停，但**还没到批边界**
    // - `isPaused`：真的停在边界上了
    // - `stopRequested`：跑完当前这批就收工
    //
    // 把它们合成一个"暂停了没"，界面上就没法回答"我按的那一下到底生不生效" ——
    // 而这正是分批要解决的问题本身。

    /// 本次运行用的分批档位。跑起来之后就**不再读设置** ——
    /// 中途改档位去影响正在跑的这一轮，只会让进度数字前后对不上。
    @Published private(set) var runBatchSize = 0
    /// 本次计划的总批数
    @Published private(set) var runBatchRounds = 1
    /// 正在跑第几批（从 1 起）
    @Published private(set) var batchRound = 1

    @Published private(set) var pauseRequested = false
    @Published private(set) var isPaused = false
    @Published private(set) var stopRequested = false
    private var resumeGate: CheckedContinuation<Bool, Never>?

    /// 跑完摆出来的那份统计。它一非 nil 主窗口就弹报告。
    @Published var runReport: RunReport?

    @Published var recommendation: Recommendation?
    @Published var comparing: ImageItem?
    /// 调色室的开关。放在这里而不是设置面板里，是因为 sheet 要在最外层挂
    @Published var showingGradeStudio = false
    private var recommendationDismissed = false

    /// 「这批压完大概多大」。还没量出来时是 `nil` ——
    /// 界面上宁可显示"正在量"，也不要显示一个占着位的假数字。
    @Published private(set) var estimate: BatchEstimate?
    @Published private(set) var estimating = false
    private var estimateTask: Task<Void, Never>?
    private var analyzeTask: Task<Void, Never>?

    private var bag = Set<AnyCancellable>()

    init() {
        $settings
            .dropFirst()
            // 防抖 300ms 再落盘 + 复位结果。
            //
            // 之前是每改一个字段就立刻做这两件事。改开关时无所谓，但调色室那六根
            // 滑杆是**连续**在改的 —— 一次拖动会触发十几次：
            // `SettingsStore.save` 每次都把整份设置 JSON 编码写一遍 UserDefaults，
            // `resetResults` 每次都遍历所有列表项把状态复位一遍，
            // 后者会让主窗口每一行都重新求值。两个叠在一起就是"拖起来发涩"。
            //
            // 延迟落盘的代价是"改完立刻强杀进程会丢掉最后 300ms 的改动"，
            // 这个代价值得 —— 拖完手停下来的那一刻就会写下去。
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] newValue in
                SettingsStore.save(newValue)
                guard let self, !self.isRunning else { return }
                self.resetResults()
                // 参数一变，那个"预计压到多少"就不对了 —— 重新量。
                // 挂在同一道防抖上，所以拖滑杆不会每帧都去压一张图。
                self.scheduleEstimate()
            }
            .store(in: &bag)
    }

    /// 调色室用的底图：挑列表里**最大的一张**。
    ///
    /// 拿用户自己的图当预览底图，比通用色卡有用得多 —— 一眼就能看出
    /// 这条 LUT 会对自己的照片做什么。挑最大的是因为：它最可能是用户
    /// 真正在意的那张，也最不容易撞上图标 / 截图这类调色没意义的素材。
    var previewBaseURL: URL? {
        let pending = items.filter { $0.state == .pending }
        let pool = pending.isEmpty ? items : pending
        return pool.max { $0.originalBytes < $1.originalBytes }?.url
    }

    // MARK: 汇总

    var totalOriginalBytes: Int { items.reduce(0) { $0 + $1.originalBytes } }

    var totalSavedBytes: Int {
        items.reduce(0) { acc, item in
            if case .done = item.state {
                return acc + max(0, item.originalBytes - item.outputBytes)
            }
            return acc
        }
    }

    var overallPercent: Int {
        let doneItems = items.filter { $0.state.isGood }
        guard !doneItems.isEmpty else { return 0 }
        let orig = doneItems.reduce(0) { $0 + $1.originalBytes }
        let new = doneItems.reduce(0) { $0 + $1.outputBytes }
        return Fmt.savePercent(from: orig, to: new)
    }

    var remaining: Int { items.filter { $0.state == .pending }.count }

    var lastOutputFolder: URL? {
        items.compactMap { $0.outputURL }.last?.deletingLastPathComponent()
    }

    /// 已经按建议改了设置之后，横幅就没必要再挂着
    var visibleRecommendation: Recommendation? {
        guard !recommendationDismissed, let recommendation else { return nil }
        return recommendation.differs(from: settings) ? recommendation : nil
    }

    /// 有没有嵌套目录（决定"保留目录层级"这个开关值不值得提示）
    var hasNestedFolders: Bool {
        items.contains { !$0.relativeDir.isEmpty }
    }

    // MARK: 导入

    func handleDrop(providers: [NSItemProvider]) -> Bool {
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

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.add(urls: found)
        }
        return true
    }

    func add(urls: [URL]) {
        var jobs: [CompressJob] = []
        for url in urls {
            jobs.append(contentsOf: collectJobs(from: url))
        }
        add(jobs: jobs)
    }

    /// 加一批任务。
    func add(jobs rawJobs: [CompressJob]) {
        DevMetrics.mark("add() 收到 \(rawJobs.count) 个文件，现列表 \(items.count) 行")
        var seen = Set(items.map { $0.url.standardizedFileURL.path })
        var added = 0

        for job in rawJobs {
            let key = job.url.standardizedFileURL.path
            if seen.contains(key) { continue }
            seen.insert(key)

            let item = ImageItem(job: job)
            items.append(item)
            added += 1
            // 这里**故意不加载缩略图**。导入两千张时每张都派一个解码任务的话：
            //   · 第一张要排在两千张后面 —— 实测 4.06 秒才出第一张图
            //   · 两千个 `NSImage` 从此常驻内存 —— 实测峰值 1127MB
            // 改成"哪一行真露出来才解码"（见 `requestThumbnail`）。
        }

        if added > 0 {
            finishedCount = 0
            batchCount = 0
            recommendationDismissed = false
            NSSound(named: "Tink")?.play()
            DevMetrics.mark("列表建好 \(items.count) 行，缩略图任务已派发")
            scheduleEstimate()
            scheduleAnalyze()
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "添加"
        panel.message = "选择图片或文件夹（文件夹会递归读取）"
        if panel.runModal() == .OK {
            add(urls: panel.urls)
        }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择压缩结果的存放位置"
        if panel.runModal() == .OK {
            settings.customFolder = panel.urls.first
        }
    }

    // MARK: 扫描
    //
    // 扫文件夹走的是**先看再决定**那条流程：先把结果收齐、带着体积摆出来，
    // 用户挑完再进列表。中间那一步不能省 —— 用户要的正是"先看看有多少大图"。

    @Published var scan: ScanState?

    /// 扫一个文件夹（连同子文件夹一起扫到底）。
    func beginFolderScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "扫描"
        panel.message = "选择一个文件夹，会连同它的子文件夹一起扫"
        guard panel.runModal() == .OK, let folder = panel.urls.first else { return }
        beginFolderScan(at: folder)
    }

    /// 同上，但目录是外面给的。
    ///
    /// 拆出来是为了让出图钩子能不弹面板直接扫一个已知目录 ——
    /// 和"目录从哪儿来"有关的部分只有上面那 8 行，剩下的应该是同一份代码。
    func beginFolderScan(at folder: URL) {
        scan = ScanState(source: .folder(folder), phase: .scanning(done: 0, total: 0))

        // 几千张图的目录要跑好几秒，扔后台。这是彩球和"卡了一下"的区别。
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                FolderScan.candidates(from: folder)
            }.value
            guard let self, case .folder(let current) = self.scan?.source,
                  current == folder else { return }
            self.scan?.candidates = found
            self.scan?.phase = .ready
        }
    }

    /// 报告里点了「导入」。
    func confirmScan(_ selected: [ScanCandidate]) {
        scan = nil
        guard !selected.isEmpty else { return }
        // 选中的本来就是磁盘上现成的文件，没有"取图"这一步
        add(jobs: selected.map { CompressJob.make(url: $0.url, root: $0.root) })
    }

    func cancelScan() {
        scan = nil
    }

    func remove(_ item: ImageItem) {
        items.removeAll { $0.id == item.id }
        if items.isEmpty { recommendation = nil }
        // 抽样的那张可能刚被删掉，比例就作废了
        scheduleEstimate()
    }

    func clear() {
        items.removeAll()
        finishedCount = 0
        batchCount = 0
        recommendation = nil
        recommendationDismissed = false
        estimateTask?.cancel()
        estimate = nil
        estimating = false
        // 列表都清空了，那份"刚才省了多少"的报告就无从对照了 ——
        // 一起收走，别让一屏统计悬在空的窗口上
        runReport = nil
    }

    // MARK: 智能推荐

    /// 和 `scheduleEstimate` 一样，防抖之后才真的分析。
    ///
    /// 它原来在每次 `add()` 里立刻跑一遍全量，分批导入时是**平方级**的：
    /// 分十批各 200 张加进来，每批都要重扫"当时列表里的全部" ——
    /// 合计一万一千张，而产出的只是一个推荐方案，早 300ms 晚 300ms 没有区别。
    private func scheduleAnalyze() {
        analyzeTask?.cancel()
        analyzeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.analyze()
        }
    }

    private func analyze() async {
        let urls = items.filter { $0.state == .pending }.map { $0.url }
        guard !urls.isEmpty else { return }

        let settingsSnapshot = settings

        let advice = await Task.detached(priority: .utility) { () -> Recommendation? in
            let profiles = urls.compactMap { ImageAnalyzer.profile($0) }
            // 带上量尺：拿组里最大的一张真压一遍，把"预估"换成实测
            return ImageAnalyzer.summarize(profiles, current: settingsSnapshot) { url, probeSettings in
                ImageCompressor.probe(url: url, settings: probeSettings)
            }
        }.value

        guard !Task.isCancelled else { return }
        recommendation = advice
        DevMetrics.mark("分析（analyze）完成")
    }

    func applyRecommendation() {
        guard let recommendation else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            settings.sizeGoal = .quality
            settings.quality = recommendation.preset.quality
            settings.format = recommendation.format
        }
        recommendationDismissed = true
    }

    func dismissRecommendation() {
        recommendationDismissed = true
    }

    // MARK: 批次估算

    /// 重新量一遍"这批压完大概多大"。
    ///
    /// 挂在设置落盘那道 300ms 防抖后面（见 `init`），所以连续拖动时不会
    /// 每帧都去压图 —— 手停下来量一次就够。
    private func scheduleEstimate() {
        estimateTask?.cancel()

        let pending = items.filter { $0.state == .pending }
        guard !pending.isEmpty else {
            // 没有待压的了 —— 这时候界面用的是真实汇总，不需要预估
            estimate = nil
            estimating = false
            return
        }

        let settingsSnapshot = settings
        let entries = pending.map { (name: $0.name, url: $0.url, bytes: $0.originalBytes) }
        let originalBytes = pending.reduce(0) { $0 + $1.originalBytes }

        estimating = true
        estimateTask = Task { [weak self] in
            // 整段（分组 + 压缩）都必须显式切到别的线程。
            //
            // `profile` 和 `probe` 都是同步函数：直接在这里调用（哪怕前面写个
            // `await`）都会在**当前线程**上跑完，而这里的当前线程就是主线程 ——
            // 分组要解 N 张缩略图、probe 要跑满一次全尺寸压缩，
            // 留在主线程上就是拖动时的"顿一下"（和调色室预览那次是同一个坑）。
            let value = await Task.detached(priority: .utility) { () -> BatchEstimate? in
                // 按**源格式**分组（JPEG / PNG / HEIC / …）。
                // `identifier` 而不是 UTType 本身当键，是因为字典键必须能被
                // 老实比较 —— UTType 的相等性依赖它内部注册的声明，
                // 两个"都表示 JPEG"的类型未必要能判等（见 `BatchEstimate` 上方的说明）。
                var groups: [String: [(name: String, url: URL, bytes: Int)]] = [:]
                for entry in entries {
                    // `sourceType` 而不是 `profile().sourceType`：分组只要格式名，
                    // 而 `profile` 会顺带解一张采样图走直方图（那是为了判
                    // "照片还是截图"）。两千张上这个差别就是几秒钟。
                    let key = ImageAnalyzer.sourceType(entry.url)?.identifier ?? "unknown"
                    groups[key, default: []].append(entry)
                }

                var projected = 0
                var covered = 0
                var sampleNames: [String] = []

                // 各组**并行**测量。
                //
                // 串行的话等待时间就是"组数 × 一次全量压缩" —— 三张不同格式
                // 的图要等三次，而这段等待里界面上只能写着"正在量…"（见下）。
                // 并行之后总耗时约等于最慢的那一组。
                //
                // 用 `withTaskGroup` 而不是 `DispatchQueue.concurrentPerform`：
                // 后者要手写加锁去汇总结果，而这里天然就是"每个任务产出一个值"。
                let probes = await withTaskGroup(of: FormatProbe?.self) { taskGroup in
                    for (_, group) in groups {
                        guard let biggest = group.max(by: { $0.bytes < $1.bytes }) else { continue }
                        let groupBytes = group.reduce(0) { $0 + $1.bytes }
                        let url = biggest.url
                        let name = biggest.name
                        let settings = settingsSnapshot

                        taskGroup.addTask {
                            guard let probe = ImageCompressor.probe(url: url, settings: settings),
                                  probe.original > 0 else { return nil }
                            return FormatProbe(
                                groupBytes: groupBytes,
                                sampleName: name,
                                ratio: Double(probe.output) / Double(probe.original)
                            )
                        }
                    }

                    var collected: [FormatProbe] = []
                    for await result in taskGroup {
                        if let result { collected.append(result) }
                    }
                    return collected
                }

                for probe in probes {
                    projected += Int((Double(probe.groupBytes) * probe.ratio).rounded())
                    covered += probe.groupBytes
                    sampleNames.append(probe.sampleName)
                }

                guard covered > 0 else { return nil }

                // 有量不成的（坏文件、读不了）就按已经量出来的平均比例补齐。
                // 不补的话整批预估会凭空少一截，看着像"省得更多"——
                // 那等于把"测不到"悄悄算成了"压得动"。
                if covered < originalBytes {
                    let average = Double(projected) / Double(covered)
                    projected += Int((Double(originalBytes - covered) * average).rounded())
                }

                return BatchEstimate(
                    sampleNames: sampleNames,
                    groupCount: groups.count,
                    projectedBytes: projected,
                    originalBytes: originalBytes
                )
            }.value

            guard let self, !Task.isCancelled else { return }
            self.estimating = false
            self.estimate = value
            DevMetrics.mark("估算（scheduleEstimate）完成")
        }
    }

    /// **整批**压完大概多重：已经压过的用真实值，还没压的用抽样外推。
    ///
    /// 为什么要把两半合起来，而不是只显示"待压这部分的预计"：
    /// 批次条两端必须指**同一个范围**（和顶栏那句"3 张 · 11.2 MB"一致），
    /// 否则左边是整批、右边是其中两张，读起来就是一个错的比值。
    ///
    /// 合起来仍然诚实 —— 两半的来源都标在界面上（「本次实测」/「抽样自 xx.jpg」），
    /// 它表达的是"按目前掌握的信息，整批大概多重"，没有多说的部分。
    var projectedBatchBytes: Int? {
        let doneBytes = items
            .filter { $0.state.isGood }
            .reduce(0) { $0 + $1.outputBytes }

        if remaining == 0 {
            // 全压完了：这时候只有实测，没有推测
            return items.contains { $0.state.isGood } ? doneBytes : nil
        }
        guard let estimate else { return nil }
        return doneBytes + estimate.projectedBytes
    }

    // MARK: 压缩

    func requestStart() {
        guard !items.filter({ $0.state == .pending }).isEmpty, !isRunning else { return }
        start()
    }

    /// 全部压完之后"用当前参数再跑一遍"。
    ///
    /// 复位这一步不能省：压缩只处理 `pending` 的那些，而全压完时 pending
    /// 已经是空的 —— 直接 `start()` 会静静地什么都不做。按钮按下去没反应，
    /// 是最难排查的一种"坏掉"。
    func restart() {
        guard !isRunning, !items.isEmpty else { return }
        resetResults()
        start()
    }

    private func start() {
        let targets = items.filter { $0.state == .pending }
        guard !targets.isEmpty else { return }

        let ids = targets.map { $0.id }
        let jobs = targets.map { $0.job }

        let config = settings
        let startedAt = Date()
        let planned = jobs.count

        isRunning = true
        finishedCount = 0
        batchCount = planned
        runReport = nil
        pauseRequested = false
        stopRequested = false
        isPaused = false
        runBatchSize = config.batchSize
        runBatchRounds = max(1, BatchPlan.count(total: planned, size: config.batchSize))
        batchRound = 1

        let reserver = PathReserver()
        // 用的是 effectiveGrade，和引擎真正吃到的那份参数严格一致
        let gradeActive = config.effectiveGrade.isActive

        Task {
            await BatchRunner.run(
                jobs: jobs,
                settings: config,
                reserver: reserver,
                onStart: { index in
                    await MainActor.run {
                        guard index < ids.count else { return }
                        self.item(ids[index])?.state = .processing
                    }
                },
                onFinish: { index, result in
                    await MainActor.run {
                        guard index < ids.count else { return }
                        if let item = self.item(ids[index]) {
                            item.graded = gradeActive
                            self.apply(result, to: item)
                        }
                        self.finishedCount += 1
                    }
                },
                // 批与批之间是**唯一**能安全停下的地方。要不要接着跑由这里说了算 ——
                // 引擎只负责在边界上问一句，不负责替用户做决定。
                //
                // 这里不用 `[weak self]`：外面那个 `Task` 已经强引用了 self，
                // 里面再写一遍弱引用只是让编译器报警的假动作，拦不住任何东西。
                onBatchFinished: { finished, _ in
                    await self.batchBoundary(finished: finished)
                }
            )

            self.isRunning = false
            self.isPaused = false
            self.pauseRequested = false
            if let gate = self.resumeGate {
                self.resumeGate = nil
                gate.resume(returning: false)
            }
            NSSound(named: "Glass")?.play()

            self.runReport = self.makeReport(ids: ids, startedAt: startedAt, planned: planned)
        }
    }

    /// 报告关掉之后的收尾。
    func reportDismissed() {
        runReport = nil
    }

    /// 到了批边界：要不要接着跑。
    ///
    /// 这里刻意只在**边界**上停 —— 此刻没有在跑的压缩、结果都已经落盘，
    /// 停下来不会留下压了一半的图。让"停止"在任意时刻生效看着更跟手，
    /// 代价是用户可能拿到几张处于中间态的图，而那种状态谁也说不清。
    private func batchBoundary(finished: Int) async -> Bool {
        if stopRequested { return false }

        // 只有用户真的选了分批，才会在批边界上摆出"第 N 批完成"
        if runBatchSize > 0 {
            batchRound = min(runBatchRounds, finished + 1)
        }

        guard pauseRequested, runBatchSize > 0 else { return true }

        pauseRequested = false
        isPaused = true
        let go = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            resumeGate = cont
        }
        isPaused = false
        return go
    }

    /// 「暂停」。**在批边界生效**，不是立刻 —— 界面上要说清楚这一点，
    /// 否则用户按完发现还在跑，会以为按钮坏了。
    func requestPause() {
        guard isRunning, runBatchSize > 0 else { return }
        if isPaused { resumeRun(); return }
        pauseRequested = true
    }

    func resumeRun() {
        guard isPaused else { return }
        isPaused = false
        let gate = resumeGate
        resumeGate = nil
        gate?.resume(returning: true)
    }

    /// 「停止」。已经压好的结果全部保留，不做回滚 —— 那些是用户的劳动成果。
    func stopRun() {
        guard isRunning else { return }
        stopRequested = true
        pauseRequested = false
        if let gate = resumeGate {
            resumeGate = nil
            isPaused = false
            gate.resume(returning: false)
        }
    }

    /// 把这一轮的结果算成一份账。
    ///
    /// **尺寸那笔账只算真的变小了的那些**：失败、跳过、已是最优、
    /// 越压越大的原图一寸都没动，把它们算进"原始体积"再算进"省下"，
    /// 等于凭空空出一块。报告里另外用一句话交代有几百张没参与这个百分比
    /// （`isPartialMeasurement`），不让"874 张"和那个百分比互相打架。
    private func makeReport(ids: [UUID], startedAt: Date, planned: Int) -> RunReport? {
        let targets = ids.compactMap { item($0) }
        guard !targets.isEmpty else { return nil }

        var compressed = 0, unchanged = 0, grew = 0, skipped = 0, failed = 0, missed = 0
        var processed = 0
        var original = 0, output = 0, shrunk = 0

        for item in targets {
            switch item.state {
            case .pending, .processing:
                continue                        // 中途停下时还没轮到的那些
            case .done:
                compressed += 1
                if item.targetMissed { missed += 1 }
            case .noChange:  unchanged += 1
            case .grew:      grew += 1
            case .skipped:   skipped += 1
            case .failed:    failed += 1
            }
            processed += 1

            if item.outputBytes > 0, item.outputBytes < item.originalBytes {
                original += item.originalBytes
                output += item.outputBytes
                shrunk += 1
            }
        }

        return RunReport(
            startedAt: startedAt,
            finishedAt: Date(),
            planned: planned,
            processed: processed,
            compressed: compressed,
            unchanged: unchanged,
            grew: grew,
            skipped: skipped,
            failed: failed,
            missedTarget: missed,
            originalBytes: original,
            outputBytes: output,
            shrunkCount: shrunk,
            batchSize: runBatchSize,
            batchCount: runBatchSize > 0 ? runBatchRounds : 1,
            stoppedEarly: stopRequested,
            // 报告的"去结果在哪儿"在这一刻定下来，之后不去列表里现找
            outputFolderPath: targets.compactMap { $0.outputURL }
                .last?.deletingLastPathComponent().path
        )
    }

    private func item(_ id: UUID) -> ImageItem? {
        items.first { $0.id == id }
    }

    private func apply(_ result: Result<CompressOutcome, Error>, to item: ImageItem) {
        switch result {
        case .success(let outcome):
            item.outputBytes = outcome.outputBytes
            item.outputURL = outcome.outputURL
            item.usedQuality = outcome.usedQuality
            item.targetMissed = !outcome.targetMet

            if outcome.noChange {
                item.state = .noChange
            } else if outcome.grew {
                item.state = .grew(percent: Fmt.savePercent(from: outcome.originalBytes, to: outcome.outputBytes))
            } else {
                item.state = .done(
                    saved: outcome.savedBytes,
                    percent: outcome.savedPercent
                )
            }

            // 覆盖模式下如果格式变了，原文件会进废纸篓、结果换个扩展名留下来，
            // 这里不做移除，让用户还能看到"省了多少"和结果入口。

        case .failure(let error):
            // 动图是主动跳过的，不算失败
            if let compressError = error as? CompressError {
                switch compressError {
                case .animated:
                    item.state = .skipped("动图不处理")
                    return
                default:
                    break
                }
            }
            item.state = .failed(error.localizedDescription)
        }
    }

    private func resetResults() {
        for item in items {
            item.state = .pending
            item.outputBytes = 0
            item.outputURL = nil
            item.targetMissed = false
            item.usedQuality = nil
            item.graded = false
        }
        finishedCount = 0
        batchCount = 0
    }

    // MARK: 辅助

    // MARK: 缩略图（按需）

    /// 同时在解的张数。
    ///
    /// 卡住它是因为解码是 CPU 活：两千张一起放出去会把所有核占满二十多秒
    /// （实测 550~600% 持续 24 秒），而屏幕上其实只有十来行。
    private let thumbParallel = 4
    private var thumbRunning = 0

    /// 待办队列。**当栈用**（后进先出）——
    /// 用户看的是眼前这几行，它们该先拿到图，而不是排在两千张的队尾：
    /// 全量派发时第一张缩略图等了 **4.06 秒** 才出现，就是这个原因。
    private var thumbQueue: [ImageItem] = []

    /// 行进入视口时来要图。由 `ImageRow.onAppear` 调。
    func requestThumbnail(for item: ImageItem) {
        guard item.thumbnail == nil, !item.thumbnailPending else { return }
        item.thumbnailPending = true
        thumbQueue.append(item)
        pumpThumbnails()
    }

    /// 行离开视口时把图还回去。由 `ImageRow.onDisappear` 调。
    ///
    /// 不还的话缩略图会一直挂在 `item` 上：两千张合计 900MB+ 常驻，
    /// 而其中绝大多数用户整个会话都不会再看一眼。
    func releaseThumbnail(for item: ImageItem) {
        guard item.thumbnailPending || item.thumbnail != nil else { return }
        item.thumbnailPending = false
        thumbQueue.removeAll { $0 === item }
        item.thumbnail = nil
    }

    private func pumpThumbnails() {
        while thumbRunning < thumbParallel, let item = thumbQueue.popLast() {
            thumbRunning += 1
            let url = item.url
            Task {
                let boxed = await Task.detached(priority: .utility) {
                    SendableImage(ImageCompressor.thumbnail(for: url, maxPixel: 200))
                }.value
                item.thumbnailPending = false
                item.thumbnail = boxed.image
                thumbRunning -= 1
                DevMetrics.thumbnailDone(total: items.count)
                pumpThumbnails()
            }
        }
    }

    private func collectJobs(from url: URL) -> [CompressJob] {
        ImageScanner.jobs(from: url)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
