import Foundation
import AppKit
import Darwin

/// 开发期度量：量「一次导入 N 张，到底要付多少代价」。
///
/// **为什么不让外面用 `ps` 量**：这个沙箱里 `ps ax` 被挡掉
/// （`operation not permitted`），外部采样永远拿到空行 —— 白等一轮，
/// 还会把"进程根本没起来"和"进程起来了但量不到"混成同一个现象。
/// 让进程自己报，和 `DebugSnapshot` 自渲染出图是同一个思路：
/// 不依赖任何系统权限。
///
/// 用法（**必须给文件路径**）：
/// ```
///   PICCOMPRESS_METRICS=/tmp/m.txt       把度量追加写到这个文件
///   PICCOMPRESS_METRICS_SECS=20          采够这么多秒自己退出（默认 20）
/// ```
/// 为什么必须是文件：GUI 只能经 `open` 启动，stdout 带不回来。
///
/// 三个数各有各的答案：
///   rss   → 内存压力（缩略图是不是全留在内存里）
///   cpu   → 当时还在忙什么（0% 就是真闲下来了）
///   mark  → 钱花在哪一段（导入 / 列表构建 / 缩略图 / 分析 / 估算）
enum DevMetrics {

    private static let outPath = ProcessInfo.processInfo.environment["PICCOMPRESS_METRICS"]
    private static let t0 = Date()
    private static let interval: Double = 0.5
    private static let totalSeconds: Double = {
        let raw = ProcessInfo.processInfo.environment["PICCOMPRESS_METRICS_SECS"] ?? ""
        return Double(raw) ?? 20
    }()

    static let enabled = (outPath?.isEmpty == false)

    private static let lock = NSLock()
    private static var lastCPU: Double = 0
    private static var lastAt: Double = 0
    private static var peakRSS: Double = 0
    private static var thumbCount = 0
    private static var sink: FileHandle? = {
        guard let outPath, !outPath.isEmpty else { return nil }
        FileManager.default.createFile(atPath: outPath, contents: nil)
        return FileHandle(forWritingAtPath: outPath)
    }()

    // MARK: 出口

    private static func emit(_ text: String) {
        guard enabled, let sink else { return }
        lock.lock(); defer { lock.unlock() }
        sink.write(Data((text + "\n").utf8))
    }

    /// 打一个时间戳里程碑。全部走同一条出口，读的时候是一条时间线。
    static func mark(_ text: String) {
        guard enabled else { return }
        emit(String(format: "%6.2fs  %@", Date().timeIntervalSince(t0), text))
    }

    // MARK: 采样

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let u = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let s = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return u + s
    }

    private static func sample() {
        let now = Date().timeIntervalSince(t0)
        let cpu = cpuSeconds()
        let rss = residentMB()
        var pct = 0.0
        if lastAt > 0, now > lastAt {
            pct = (cpu - lastCPU) / (now - lastAt) * 100
        }
        lastCPU = cpu; lastAt = now
        if rss > peakRSS { peakRSS = rss }
        emit(String(format: "%6.2fs  rss=%4.0fMB  cpu=%3.0f%%", now, rss, pct))
    }

    /// 缩略图每好一张报一次数 —— 「导入 2000 张要等多久」这句话的答案就在这条线上。
    static func thumbnailDone(total: Int) {
        guard enabled else { return }
        lock.lock()
        thumbCount += 1
        let n = thumbCount
        lock.unlock()
        if n == 1 || n % 250 == 0 || n == total {
            mark("缩略图 \(n) / \(total)")
        }
    }

    // MARK: 启动

    @MainActor
    static func start() {
        guard enabled else { return }
        mark("== 开始度量（采 \(Int(totalSeconds)) 秒） ==")

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "devmetrics"))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { sample() }
        timer.resume()
        sampler = timer

        DispatchQueue.main.asyncAfter(deadline: .now() + totalSeconds) {
            sample()
            mark(String(format: "== 结束：峰值 RSS %.0f MB ==", peakRSS))
            // 用 exit 而不是 NSApp.terminate：terminate 在有模态窗口时会卡住
            // （这个坑上一轮在出图钩子里踩过）。度量跑没有模态，直接退最干净。
            exit(0)
        }
    }

    private static var sampler: DispatchSourceTimer?
}
