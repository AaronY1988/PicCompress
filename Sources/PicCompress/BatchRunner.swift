import Foundation

/// 把拖进来 / 传进来的路径展开成任务。
///
/// 遍历规则（认哪些扩展名、跳过隐藏文件、跳过 `Compressed/`、跳过自己的产物）
/// **全部在 `Scanner.swift` 的 `FolderScan` 里**，这里只把候选转成任务。
/// 规则只留一份是有意的：扫描报告和实际导入必须看到同一批文件 ——
/// 用户是拿报告做的决定，两边要是对不上，那个决定就落空了。
enum ImageScanner {

    static func jobs(from url: URL) -> [CompressJob] {
        FolderScan.candidates(from: url).map {
            CompressJob.make(url: $0.url, root: $0.root)
        }
    }
}

// MARK: - 分批

/// 「一次压多少张」。
///
/// 几百上千张的时候一口气跑完有两个毛病：进度条只有一个总数（用户换算不出
/// 还要等多久），以及跑到一半发现参数不合适时**没有干净的落脚点**——
/// 中途喊停会留下压了一半的一批，谁也说不清现在是什么状态。
///
/// 分批把两件事一起解决了：每批是一个可以安全停下的地方，进度也变成
/// 「第 3 / 20 批」这种一眼能换算成时间的说法。
///
/// **分批不改变压缩结果**：同一张图在批里还是批外，压出来逐位相同。
/// 它切的是"什么时候可以停下来"，不是像素 —— 所以这个开关无论怎么设，
/// 都不该影响用户拿到的画质，只是影响他能多细地看住这件事。
enum BatchPlan {

    /// 可选档位。**0 = 一次压完**。
    ///
    /// 用 0 表示"不分批"而不是另开一个开关：`chunks(total:size:)` 里
    /// `size <= 0` 天然就是"只有一批"，那个"开关关着但档位写着 100"
    /// 的自相矛盾状态根本构造不出来。和扫描阈值那里同一个思路。
    static let options: [Int] = [0, 50, 100, 200]

    static func label(_ size: Int) -> String {
        size <= 0 ? "一次压完" : "一次 \(size) 张"
    }

    /// 窄栏里用的短标签。
    ///
    /// 侧栏只有 272pt 宽，四颗「一次 200 张」并排放不下 —— 会挤成省略号，
    /// 而省略号在这里恰好把**区分它们的那几个数字**吃掉了。
    static func shortLabel(_ size: Int) -> String {
        size <= 0 ? "一次压完" : "\(size) 张"
    }

    static func isValid(_ size: Int) -> Bool { options.contains(size) }

    /// 值得把「分批」这个选项摆出来的最小张数。
    ///
    /// 最小的档位就是 50 —— 比它少的批次根本没有可选项（一批就装得下），
    /// 摆出来只是给一屏已经很满的报告再加一行噪声。
    static var smallestOption: Int { options.filter { $0 > 0 }.min() ?? 50 }

    /// 把 `total` 张切成若干段。
    ///
    /// 界面上显示「共 N 批」和引擎真正走的批数必须来自这一个函数 ——
    /// 各算各的话，"说好 18 批、实际跑了 19 批"是用户自己核不出来的错。
    static func chunks(total: Int, size: Int) -> [Range<Int>] {
        guard total > 0 else { return [] }
        guard size > 0 else { return [0..<total] }

        var result: [Range<Int>] = []
        var start = 0
        while start < total {
            let end = min(start + size, total)
            result.append(start..<end)
            start = end
        }
        return result
    }

    static func count(total: Int, size: Int) -> Int {
        chunks(total: total, size: size).count
    }
}

/// 批量压缩的执行器。界面和命令行都走这里，行为完全一致。
enum BatchRunner {

    static var defaultConcurrency: Int {
        max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 1))
    }

    /// 跑完一批就回调一次，(已完成批数, 总批数) → **还要不要接着跑**。
    ///
    /// 用"回调返回布尔"而不是"让调用方自己循环"：批边界是唯一能安全停下的
    /// 地方（此刻没有在跑的压缩、结果已经落盘），这个约束只有执行器知道。
    /// 把它留在外面，调用方迟早会在别的时刻去停它。
    ///
    /// 返回 `false` 就停下 —— 已经压好的结果全部保留，不做回滚。
    typealias BatchGate = @Sendable (_ finished: Int, _ total: Int) async -> Bool

    /// 没选分批时，执行器自己回来问一次的间隔。
    ///
    /// 和用户选的档位是**两件事**：档位是"他要不要一批一批地看"，
    /// 这个是"多久给他一次叫停的机会"。哪怕选了「一次压完」，
    /// 隔一段问一次也是必要的 —— 否则两千张跑起来，那颗「停止」
    /// 要等到全部结束才生效，和一颗粒子灰按钮没有区别。
    static let stopGranularity = 64

    static func run(
        jobs: [CompressJob],
        settings: CompressSettings,
        reserver: PathReserver? = nil,
        concurrency: Int = BatchRunner.defaultConcurrency,
        onStart: (@Sendable (Int) async -> Void)? = nil,
        onFinish: (@Sendable (Int, Result<CompressOutcome, Error>) async -> Void)? = nil,
        onBatchFinished: BatchGate? = nil
    ) async {
        guard !jobs.isEmpty else { return }

        let limit = max(1, concurrency)
        let granularity = settings.batchSize > 0 ? settings.batchSize : stopGranularity
        let chunks = BatchPlan.chunks(total: jobs.count, size: granularity)

        for (round, range) in chunks.enumerated() {
            await runChunk(
                indices: Array(range),
                jobs: jobs,
                settings: settings,
                reserver: reserver,
                limit: limit,
                onStart: onStart,
                onFinish: onFinish
            )

            // 最后一批跑完就没有"下一批要不要跑"这个问题了，
            // 不再回调 —— 否则界面会在结束前闪一下"继续？"
            guard round < chunks.count - 1, let gate = onBatchFinished else { continue }
            if await gate(round + 1, chunks.count) == false { break }
        }
    }

    /// 一批。就是一个上限为 `limit` 的并发队列。
    private static func runChunk(
        indices: [Int],
        jobs: [CompressJob],
        settings: CompressSettings,
        reserver: PathReserver?,
        limit: Int,
        onStart: (@Sendable (Int) async -> Void)?,
        onFinish: (@Sendable (Int, Result<CompressOutcome, Error>) async -> Void)?
    ) async {
        await withTaskGroup(of: (Int, Result<CompressOutcome, Error>).self) { group in
            var queue = indices
            var inFlight = 0

            while !queue.isEmpty || inFlight > 0 {
                while inFlight < limit, !queue.isEmpty {
                    let index = queue.removeFirst()
                    let job = jobs[index]
                    await onStart?(index)
                    group.addTask {
                        let result = await Task.detached(priority: .userInitiated) {
                            Result {
                                try ImageCompressor.compress(
                                    job: job,
                                    settings: settings,
                                    reserver: reserver
                                )
                            }
                        }.value
                        return (index, result)
                    }
                    inFlight += 1
                }

                if let (index, result) = await group.next() {
                    inFlight -= 1
                    await onFinish?(index, result)
                }
            }
        }
    }
}

// MARK: - 一次运行的统计报告

/// 一次压缩跑完之后摆给用户的那份账。
///
/// 它**在跑完的那一刻定下来**（一个值类型），不是每次去列表里现算：
/// 用户完全可能在看完报告之后删掉几行，而"刚才那次到底省了多少"
/// 不该跟着变。跑完时是什么样，报告里就永远是什么样。
struct RunReport: Identifiable, Sendable {

    let id = UUID()

    let startedAt: Date
    let finishedAt: Date

    /// 这次**打算**压多少张（中途停下时它大于 `processed`）
    let planned: Int
    /// 实际处理完的（含失败与跳过）
    let processed: Int

    let compressed: Int
    let unchanged: Int
    /// 压出来反而更大 —— 原图已经压得很狠了，这种原文件不动
    let grew: Int
    let skipped: Int
    let failed: Int
    /// 压下去了但没达到目标体积的
    let missedTarget: Int

    /// **真的变小了**的那些的原始体积合计
    let originalBytes: Int
    /// 同上那些的输出体积合计
    let outputBytes: Int
    /// 真的变小了的张数。"省下"这个数就是拿这 N 张算的
    let shrunkCount: Int

    let batchSize: Int
    let batchCount: Int
    /// 中途停下（用户按了停止）
    let stoppedEarly: Bool

    /// 结果落在哪个目录。**在这一刻定下来**，不再去列表里现找 ——
    /// 用户完全可能看完报告顺手删掉几行，而"结果在哪儿"不该跟着变。
    let outputFolderPath: String?

    var duration: TimeInterval { max(0, finishedAt.timeIntervalSince(startedAt)) }

    var savedBytes: Int { max(0, originalBytes - outputBytes) }
    var savedPercent: Int { Fmt.savePercent(from: originalBytes, to: outputBytes) }
    var outputFolder: URL? { outputFolderPath.map { URL(fileURLWithPath: $0) } }

    /// 平均每张用时。算的是**已处理**的那些，不是计划的那些 ——
    /// 用计划数去除会得到一个偏快的数，那是在替用户美化这次的速度。
    var secondsPerImage: Double {
        processed > 0 ? duration / Double(processed) : 0
    }

    var batchLabel: String {
        batchSize > 0 ? "分 \(batchCount) 批，每批 \(batchSize) 张" : "一次跑完"
    }

    /// 尺寸账是不是只有一部分图参与。
    ///
    /// 报告里那个「省下 X%」必须说清是**谁**省下来的：只有变小的那些才算得进来，
    /// 而如果这批图里有"已是最优""未缩小"的，不写这句话用户会发现
    /// "总共 874 张，怎么这个百分比像是按 500 张算的"。
    var isPartialMeasurement: Bool { shrunkCount < processed }
}

// MARK: - 批量结果汇总

struct BatchSummary {
    var total = 0
    var compressed = 0
    var unchanged = 0
    var skipped = 0
    var failed = 0
    var originalBytes = 0
    var outputBytes = 0
    var missedTargets = 0
    var firstOutputFolder: URL?
    var failures: [String] = []

    var savedBytes: Int { max(0, originalBytes - outputBytes) }
    var savedPercent: Int { Fmt.savePercent(from: originalBytes, to: outputBytes) }

    mutating func record(_ job: CompressJob, _ result: Result<CompressOutcome, Error>) {
        total += 1
        switch result {
        case .success(let outcome):
            if outcome.noChange {
                unchanged += 1
                originalBytes += outcome.originalBytes
                outputBytes += outcome.originalBytes
            } else {
                compressed += 1
                originalBytes += outcome.originalBytes
                outputBytes += outcome.outputBytes
                if !outcome.targetMet { missedTargets += 1 }
                if firstOutputFolder == nil {
                    firstOutputFolder = outcome.outputURL.deletingLastPathComponent()
                }
            }

        case .failure(let error):
            if let compressError = error as? CompressError, compressError == .animated {
                skipped += 1
            } else {
                failed += 1
                if failures.count < 5 {
                    failures.append("\(job.url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
        }
    }

    func text() -> String {
        var lines: [String] = []
        lines.append("已处理 \(total) 张：压缩 \(compressed)，已是最优 \(unchanged)，跳过 \(skipped)，失败 \(failed)")
        lines.append("合计 \(Fmt.compact(originalBytes)) → \(Fmt.compact(outputBytes))，省下 \(Fmt.compact(savedBytes))（−\(savedPercent)%）")
        if missedTargets > 0 {
            lines.append("有 \(missedTargets) 张没能压到目标体积以内")
        }
        for failure in failures { lines.append("失败：\(failure)") }
        return lines.joined(separator: "\n")
    }
}
