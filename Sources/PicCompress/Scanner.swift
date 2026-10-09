import Foundation

// MARK: - 扫描
//
// 「先看再决定」的那一半：把一个文件夹翻一遍，把找到的图片**带着体积**摆出来，
// 让用户按体积挑，确认之后才进列表。
//
// 这个文件刻意不依赖 SwiftUI —— 从外面喂进来的都是普通值，
// 于是它可以脱离 SPM 单独编译，断言也好写。

// MARK: 扫描来源

enum ScanSource: Sendable, Equatable {
    /// 磁盘上的一个文件夹（递归到底）
    case folder(URL)

    /// 报告里那句"从哪儿扫的"
    var caption: String {
        switch self {
        case .folder(let url): return url.path
        }
    }
}

// MARK: 候选

/// 扫描到的一张图 —— **还没进列表**，先拿给用户看。
///
/// 和 `CompressJob` 的分工：那个是"确定要压"的任务，这个是"可能压"的候选，
/// 多带了体积和来源。用户是拿这份候选做决定的，所以体积必须**在扫描时就有**，
/// 不能等加载图片时才知道 —— 那意味着要先解码几百张图。
struct ScanCandidate: Sendable, Hashable, Identifiable {
    let url: URL

    /// 导入根：它是从哪个目录扫出来的。保留目录层级时要用它算相对路径。
    let root: URL

    /// 文件体积。排序和过滤都靠它。
    let bytes: Int64

    var id: String { url.path }

    var name: String { url.lastPathComponent }

    var ext: String { url.pathExtension.lowercased() }

    init(url: URL, root: URL, bytes: Int64) {
        self.url = url
        self.root = root
        self.bytes = bytes
    }
}

// MARK: 报告

/// 一批扫描结果 + 按阈值算出来的账。
///
/// `threshold` 是 `var`：用户在报告界面上现场调，
/// 调一下重算一次。候选是几千条量级，重算就是一次 filter，不值得为它加缓存 ——
/// 缓存反而要处理"什么时候失效"，这里是纯粹的自找麻烦。
struct ScanReport: Sendable {

    struct Group: Sendable, Identifiable, Equatable {
        let ext: String
        let count: Int
        let bytes: Int64

        var id: String { ext }
        var title: String { ext.isEmpty ? "无扩展名" : ext.uppercased() }
    }

    let source: ScanSource
    let candidates: [ScanCandidate]

    /// 低于这个体积的一律不要。**0 表示不筛** —— `bytes >= 0` 恒真，
    /// 所以不需要另开一个"是否启用过滤"的开关：少一个能和阈值自相矛盾的状态。
    var threshold: Int64 = 0

    var total: Int { candidates.count }
    var totalBytes: Int64 { candidates.reduce(0) { $0 + $1.bytes } }

    /// 这些候选来自多少个不同的目录。
    ///
    /// 报告里要报它，因为用户的原话是"有些子文件夹里有文件，有些里面有图片" ——
    /// 他担心的正是递归有没有真的走到底。一个数字就能回答，
    /// 而让他去列表里逐条核对是把这个疑问原样还给他。
    ///
    /// 数的是**候选所在的目录**，不是"扫了几层"：空目录和只放文档的目录
    /// 一个计数都不占 —— 那正是他关心的另一半（哪些文件夹里没图）。
    var folderCount: Int {
        Set(candidates.map { $0.url.deletingLastPathComponent().standardizedFileURL.path }).count
    }

    /// 这次要留下的。
    var kept: [ScanCandidate] { candidates.filter { $0.bytes >= threshold } }

    /// 没留下的。
    ///
    /// 它是**账目的另一半**：`kept + skipped == total`，测试守着这一条，
    /// 有图不知去向是用户自己查不出来的那种错。
    ///
    /// 只有**一个**原因会把图筛掉（体积不够），所以这里不需要再分岔。
    /// 曾经按"体积不够 / 没勾 iCloud"拆成两笔 —— 那是图库那边才有的第二个原因，
    /// 两个数字混进一句话里，用户会拿它去对阈值，然后得出"阈值没生效"的结论。
    var skipped: [ScanCandidate] { candidates.filter { $0.bytes < threshold } }

    /// 留下的按格式分组，组内按体积从大到小。
    var keptGroups: [Group] { Self.groups(of: kept) }

    var keptBytes: Int64 { kept.reduce(0) { $0 + $1.bytes } }
    var skippedBytes: Int64 { skipped.reduce(0) { $0 + $1.bytes } }

    /// 按扩展名分组。
    ///
    /// 分组维度选的是**格式**而不是"照片/截图"那类猜测：这里只需要回答
    /// "这批都是些什么文件"，格式是唯一能**从文件名直接读出来**的东西，
    /// 不需要解码，也就不会猜错。
    static func groups(of list: [ScanCandidate]) -> [Group] {
        var counts: [String: (Int, Int64)] = [:]
        for c in list {
            let cur = counts[c.ext] ?? (0, 0)
            counts[c.ext] = (cur.0 + 1, cur.1 + c.bytes)
        }
        return counts
            .map { Group(ext: $0.key, count: $0.value.0, bytes: $0.value.1) }
            .sorted {
                // 体积降序；一样大就按格式名，保证顺序稳定可复现
                $0.bytes == $1.bytes ? $0.ext < $1.ext : $0.bytes > $1.bytes
            }
    }
}

// MARK: - 体积单位与文本

/// 扫描阈值输入框的单位。
///
/// 和设置面板里「目标体积」那套**没有共用**，因为约束正好相反：
/// 那边是"压到多少"，**必须大于 0**；这边是"小于多少的不要"，**0 是合法值**
/// （含义是"不筛"）。合成一个函数就得在里面为 0 分叉，两边的语义都会被搅浑。
enum SizeUnit: String, CaseIterable, Identifiable, Sendable {
    case kb, mb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kb: return "KB"
        case .mb: return "MB"
        }
    }

    var multiplier: Int64 {
        switch self {
        case .kb: return 1024
        case .mb: return 1024 * 1024
        }
    }
}

enum SizeText {

    /// "1.5" + MB → 1572864 字节。解不出来给 `nil`。
    ///
    /// **解不出来绝不回退成 0**：阈值那里 0 的意思是"一张都别筛掉"，
    /// 于是"多打了一个小数点"会变成"全都收进来"—— 正好是用户想要的反面。
    /// 输入框旁边那个"这行数字不算数"的提示，就是靠这个 nil。
    static func bytes(_ text: String, unit: SizeUnit) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let value = Double(trimmed),
              value.isFinite,
              value >= 0 else { return nil }
        let bytes = value * Double(unit.multiplier)
        guard bytes < Double(Int64.max) else { return nil }
        return Int64(bytes.rounded())
    }

    /// 反过来：把字节拆成"数值 + 单位"，给输入框回填。
    /// 整 MB 就不带小数（"2" 而不是 "2.0"）。
    static func field(_ bytes: Int64) -> (text: String, unit: SizeUnit) {
        guard bytes > 0 else { return ("0", .mb) }

        func plain(_ value: Double) -> String {
            value == value.rounded()
                ? "\(Int(value))"
                : String(format: "%.1f", value)
        }

        if bytes >= 1024 * 1024 {
            return (plain(Double(bytes) / Double(1024 * 1024)), .mb)
        }
        return (plain(Double(bytes) / 1024), .kb)
    }

    /// 报告里那行"≥ 1 MB"的文案
    static func thresholdLabel(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "不筛" }
        let f = field(bytes)
        return "≥ \(f.text) \(f.unit.title)"
    }
}

// MARK: - 文件夹扫描

enum FolderScan {

    /// 递归扫一个文件夹，把认得出的图片**带着体积**收上来。
    ///
    /// 排除规则和"直接导入"是**同一套**（隐藏文件、自己的产物、上一轮的
    /// `Compressed/` 目录）。规则只能有一份 —— 否则"扫描时看到的"和
    /// "导入之后得到的"会对不上，而用户正是拿扫描报告做决定的人。
    ///
    /// 这是个同步函数，调用方负责放到后台线程（`Task.detached`）。
    /// 几千张图的目录要跑几秒，放主线程就是一个彩球。
    static func candidates(from url: URL) -> [ScanCandidate] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }

        guard isDirectory.boolValue else {
            // 明确点名的单个文件不挑，即便它看着像上一次的产物
            guard supportExtensions.contains(url.pathExtension.lowercased()) else { return [] }
            return [ScanCandidate(url: url,
                                  root: url.deletingLastPathComponent(),
                                  bytes: fileSize(url))]
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [ScanCandidate] = []
        for case let entry as URL in enumerator {
            let values = try? entry.resourceValues(forKeys: Set(keys))

            if values?.isDirectory == true {
                // 别把我们自己上一轮的输出当成新素材，否则会 Compressed/Compressed 套下去
                if entry.lastPathComponent == ImageCompressor.outputFolderName {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard supportExtensions.contains(entry.pathExtension.lowercased()) else { continue }
            if ImageCompressor.isOwnArtifact(entry) { continue }

            found.append(ScanCandidate(
                url: entry,
                root: url,
                bytes: Int64(values?.fileSize ?? 0)
            ))
        }

        // 路径排序：同样的目录扫两次结果顺序一致，出图对比时才有可比性
        return found.sorted { $0.url.path < $1.url.path }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// 扫完之后有多少张 ≥ 阈值 —— 给"选完文件夹立刻给个反馈"用，
    /// 需要的是它而不是完整报告的时候不必构造整个 `ScanReport`。
    static func count(in candidates: [ScanCandidate], atLeast threshold: Int64) -> Int {
        candidates.filter { $0.bytes >= threshold }.count
    }
}

// MARK: - 安全探测（KVC）
//
// 一段**通用的安全探测原语**，和照片图库没有绑定关系 —— 图库在 2026-09-19
// 整块删掉了，这套规矩照样要守。
//
// **关键在这里：`value(forKey:)` 遇到不认识的 key 是"抛异常"，不是"返回 nil"。**
// 抛的是 `NSUnknownKeyException`，而 Objective-C 异常在 Swift 里**接不住**
// （没有 do/catch 能拦它），一路冒到顶层就是 SIGABRT —— 用户看到的是
// "PicCompress 意外退出"。2026-09-18 那次崩溃就是它：当时读图库私有属性
// （文件的体积、在不在 iCloud 上），`isCloudOnly` 里明明写着 `as? Bool` 兜底，
// 那一行却根本没机会执行。
//
// 所以先问 `responds(to:)`：那是纯粹的查询，永远不会抛；
// key 不在时它老实返回 false，我们就能**体面地说"这台机器上读不到"**，
// 而不是把一份猜出来的数字当真的交出去。
//
// `Scripts/engine-tests/main.swift` 第 21 组守着它 —— 那组断言一个都没动，
// 因为要守的东西和"谁在用"无关。
enum ObjCProbe {

    /// 按 key 取值。这个对象上没有这个 key 时给 `nil` —— **不抛异常**。
    static func value(_ object: NSObject, key: String) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }

    /// 依次试几个候选 key，给第一个取得到的值。
    ///
    /// 私有属性在不同系统版本上会换名字（`fileSize` / `_fileSize`），
    /// 甚至同一族里只留一个。认一串候选比死认一个稳。
    static func value(_ object: NSObject, keys: [String]) -> Any? {
        for key in keys {
            if let found = value(object, key: key) { return found }
        }
        return nil
    }

    /// 候选 key 里**能用的那一个**。拿它去写诊断信息：出问题时
    /// 用户日志里有"这台机器认哪个名字"，比"读不到"三个字有用得多。
    static func firstAvailableKey(_ object: NSObject, keys: [String]) -> String? {
        keys.first { object.responds(to: NSSelectorFromString($0)) }
    }

    static func number(_ object: NSObject, keys: [String]) -> NSNumber? {
        value(object, keys: keys) as? NSNumber
    }

    /// 布尔。**读不到给 `nil`，不要给 `false`** —— "问不出来"和"答案是假"
    /// 是两件事，混成一个就会在界面上说出没根据的话。
    static func flag(_ object: NSObject, keys: [String]) -> Bool? {
        guard let raw = value(object, keys: keys) else { return nil }
        // 私有属性有时候是 NSNumber，有时候直接是 Bool
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        return nil
    }
}
