import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 输出方式

enum OutputMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case siblingFolder
    case suffix
    case customFolder
    case overwrite

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .siblingFolder: return "同目录新文件夹"
        case .suffix: return "原目录加后缀"
        case .customFolder: return "指定文件夹"
        case .overwrite: return "替换原图"
        }
    }

    var icon: String {
        switch self {
        case .siblingFolder: return "folder.badge.plus"
        case .suffix: return "doc.on.doc"
        case .customFolder: return "folder"
        case .overwrite: return "arrow.triangle.2.circlepath"
        }
    }

    /// 卡片里用的一行短说明
    var cardDetail: String {
        switch self {
        case .siblingFolder: return "图片旁建子文件夹"
        case .suffix: return "生成副本，原图不动"
        case .customFolder: return "输出到你选的目录"
        case .overwrite: return "直接改动原文件"
        }
    }

    var isDestructive: Bool { self == .overwrite }

    /// 会不会动到原文件所在目录（决定时间戳保留是否有意义）
    var isInPlace: Bool { self == .overwrite || self == .suffix }
}

// MARK: - 输出格式

/// 输出格式的五档。
///
/// **每一档都必须真的产出那个格式** —— 摆一颗按下去和别的档位产出相同的芯片，
/// 等于在界面上摆一句假话。所以这里只收「系统真的写得出来」的格式：
///
///     格式     相对源图体积   单张编码耗时（4200x2800 实测）
///     AVIF       18%          350~530 ms
///     HEIC       33%           70 ms
///     JPEG       66%           95~135 ms
///     PNG       372%（无损）   520~890 ms
///
/// 上面那张表是**单张基准**（`/tmp` 里那个工具、质量 0.78）。下面是**走 App 真链路**
/// 的端到端实测（`--cli`、质量 85%、输出到临时目录、`sips -g format` 回读格式）：
///
///     源            jpeg      heic      avif      png
///     photo.jpg    2318KB    849KB     648KB    7138KB   （源 2576KB）
///     shot.png     1013KB    360KB     289KB    2297KB   （源 3402KB）
///     vista.heic   1988KB   1047KB    1143KB    9582KB   （源 5134KB）
///
/// ⚠️ 最后一行是个反例：**源图本来就是 HEIC 时，AVIF 反而比 HEIC 大 9%**。
/// 所以文案只能对 JPEG 下断言（AVIF / HEIC 都比它小四成以上），
/// 不能写"AVIF 一定比 HEIC 小" —— 那句话是假的。
///
/// **WebP 写不出来**（`org.webmproject.webp` 没有 encoder），
/// **TIFF 是 1340%**、JPEG 2000 是 122%、GIF 只有 256 色 —— 这三档放进一个
/// 「压缩」软件里是反着来的，所以都不收。要加之前先拿 `sips` 或 ImageIO 实写一遍：
/// 这条清单是量出来的，不是猜的。
///
/// `cacheKey` 那种"改一档就影响另一档"的坑这里没有：五档互相独立，
/// 但**改档位必须同时改 `ImageCompressor.resolveTargetType` 与 `CLIRunner.format(named:)`**，
/// 漏一处编译器不一定拦得住（`switch` 是穷举的，那边会拦）。
enum FormatChoice: String, CaseIterable, Identifiable, Sendable, Codable {
    case keep
    case jpeg
    case heic
    case avif
    case png

    var id: String { rawValue }

    /// 芯片上、抽屉摘要行里、窗口底部摘要里**共用同一个名字**。
    ///
    /// 三处必须是同一个来源：指路的文案和被指的那颗控件不同名，那条出路就等于没给。
    var shortTitle: String {
        switch self {
        case .keep: return "原格式"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .avif: return "AVIF"
        case .png:  return "PNG"
        }
    }

    /// 选中后芯片底下那句人话。**必须能兑现**：
    /// 会变大的要说会变大，会变慢的要说会变慢，会转成别的格式的要说出转成什么。
    ///
    /// 这一段走 `Text(变量)` ⇒ **verbatim、不解析 Markdown**，不许出现 `**`。
    /// `原格式` 那句和 `resolveTargetType` 是一张表的两面，改一边就得改另一边
    ///（引擎测试【26】把那张表并排钉住了）。
    var detail: String {
        switch self {
        case .keep:
            return "JPG、PNG、HEIC、AVIF、TIFF 原样不动；WebP 与 BMP 转成 PNG"
        case .jpeg:
            return "哪儿都打得开，体积中庸"
        case .heic:
            return "苹果设备天然支持；同画质下体积明显小于 JPEG"
        case .avif:
            return "这几档里体积最小；比同画质的 JPEG 小四成以上，编码慢一些"
        case .png:
            return "无损、能存透明；照片转过来体积会翻倍甚至更多，适合截图与插画"
        }
    }
}

// MARK: - 压缩目标

enum SizeGoal: String, CaseIterable, Identifiable, Sendable, Codable {
    case quality
    case targetBytes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quality: return "按画质"
        case .targetBytes: return "按体积"
        }
    }

    var icon: String {
        switch self {
        case .quality: return "slider.horizontal.3"
        case .targetBytes: return "arrow.down.to.line"
        }
    }
}

// MARK: - 压缩强度预设

enum StrengthPreset: String, CaseIterable, Identifiable, Sendable {
    case pristine
    case high
    case balanced
    case small
    case extreme

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pristine: return "无损保真"
        case .high: return "高质量"
        case .balanced: return "均衡"
        case .small: return "小巧"
        case .extreme: return "极致"
        }
    }

    var quality: Double {
        switch self {
        case .pristine: return 0.95
        case .high: return 0.85
        case .balanced: return 0.72
        case .small: return 0.55
        case .extreme: return 0.38
        }
    }

    var note: String {
        switch self {
        case .pristine: return "肉眼与原件无差别，压缩幅度温和"
        case .high: return "看不出损失，体积明显下降 · 推荐"
        case .balanced: return "细节仍清晰，适合网页/PPT/微信"
        case .small: return "有轻微损失，适合缩略图/邮件"
        case .extreme: return "损失可见，仅用于占位图"
        }
    }

    static func nearest(to quality: Double) -> StrengthPreset? {
        allCases.first { abs($0.quality - quality) < 0.001 }
    }
}

// MARK: - 常见目标体积

enum TargetSize {
    /// 报名字节限制、邮件附件限制这类真实场景里最常撞到的档位
    static let presets: [Int] = [
        100 * 1024,
        200 * 1024,
        500 * 1024,
        1 * 1024 * 1024,
        2 * 1024 * 1024,
        5 * 1024 * 1024,
    ]

    static func label(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1024 / 1024
        if mb >= 1, abs(mb - mb.rounded()) < 0.01 {
            return "\(Int(mb.rounded())) MB"
        }
        let kb = Double(bytes) / 1024
        if abs(kb - kb.rounded()) < 0.01 {
            return "\(Int(kb.rounded())) KB"
        }
        return Fmt.size(bytes)
    }

    /// 把 "800"、"800KB"、"1.5MB" 这类输入解析成字节数
    static func parse(_ text: String) -> Int? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }

        var multiplier: Double? = nil
        for (suffix, factor) in [("mb", 1 << 20), ("kb", 1 << 10), ("m", 1 << 20), ("k", 1 << 10), ("b", 1)] {
            if s.hasSuffix(suffix) {
                multiplier = Double(factor)
                s.removeLast(suffix.count)
                break
            }
        }

        guard let value = Double(s.trimmingCharacters(in: .whitespaces)), value > 0 else {
            return nil
        }

        // 没写单位时的直觉：500 是 500KB，1.5 是 1.5MB
        let factor = multiplier ?? (value >= 10 ? 1024 : 1024 * 1024)
        let bytes = Int(value * factor)
        return bytes >= 1024 ? bytes : nil
    }
}

// MARK: - 单张图片的状态

enum ItemState: Equatable {
    case pending
    case processing
    case done(saved: Int, percent: Int)
    case noChange
    case grew(percent: Int)
    case skipped(String)
    case failed(String)

    var isFinished: Bool {
        switch self {
        case .pending, .processing: return false
        default: return true
        }
    }

    var label: String {
        switch self {
        case .pending: return "待压缩"
        case .processing: return "压缩中"
        case .done(_, let percent): return "已压缩 −\(percent)%"
        case .noChange: return "原图已是最优"
        case .grew(let percent): return "未缩小 +\(percent)%"
        case .skipped(let r): return r
        case .failed(let r): return r
        }
    }

    var isGood: Bool {
        if case .done = self { return true }
        return false
    }

    var isProblem: Bool {
        switch self {
        case .failed, .grew: return true
        default: return false
        }
    }
}

// MARK: - 界面外观

/// 界面用哪套配色。
///
/// 默认跟着系统走 —— 用户大部分时间不会来改这里，但系统在傍晚自动切暗色时
/// 界面得跟上，不然整台机器都暗了就这一个窗口还亮着，很扎眼。
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "亮色"
        case .dark:   return "暗色"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    /// 交给 `NSWindow.appearance`。
    ///
    /// 这里 `nil` 是个**有意义的取值**，不是"没设置" —— 它的意思是
    /// "窗口不指定外观，跟着系统走"，这正是「跟随系统」。
    ///
    /// 这个功能最容易写错的地方就在这儿：把「跟随系统」实现成"什么都不做"
    /// （比如 `preferredColorScheme(nil)`），窗口会一直戴着上一次强制的外观不摘，
    /// 用户从暗色切回来时会发现毫无反应。**必须真的把 nil 写上去**才算切回去了。
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - 压缩设置

struct CompressSettings: Sendable, Equatable, Codable {
    static let qualityRange: ClosedRange<Double> = 0.3...1.0

    var sizeGoal: SizeGoal = .quality

    var quality: Double = StrengthPreset.high.quality
    /// 目标体积（字节），sizeGoal == .targetBytes 时生效
    var targetBytes: Int = 500 * 1024

    var maxDimension: Int = 0          // 0 = 不改变尺寸
    var outputMode: OutputMode = .siblingFolder
    var customFolderPath: String? = nil
    var format: FormatChoice = .keep
    var keepMetadata: Bool = true
    var keepTimestamps: Bool = true
    /// 按导入时的目录结构还原输出路径
    var preserveStructure: Bool = false

    /// 调色（LUT + 旋钮）。默认全在中性位，也就是不生效 —— 见 LUTGrade.isActive。
    /// 只要这项不激活，压缩管线上一个字节都不变，"无损保真"的承诺才守得住。
    var grade = LUTGrade()

    /// 界面外观。放这儿是为了跟着其它偏好一起记住；
    /// 它和压缩引擎完全无关，引擎不会读它。
    var appearance: AppearanceMode = .system

    /// 「扫描」时默认只收大于这个体积的图片。**0 表示不筛**。
    ///
    /// 用 0 表示"不筛"而不是另开一个布尔开关：`bytes >= 0` 恒真，
    /// 于是"开关 + 阈值"这两个状态里那个自相矛盾的组合
    /// （开关关着、阈值写着 5）根本不存在。少一个状态，少一类 bug。
    ///
    /// 它**只影响扫描报告里默认勾选谁**，不影响已经在列表里的图片 ——
    /// 用户手动加进来的图不该因为一个筛选值就消失。
    var scanMinBytes: Int64 = 0

    /// 一次压多少张。**0 表示不分批**（一口气跑完）。
    ///
    /// 它跟着"用户手里那批图的性质"走，不是每次都要重新回答的问题 ——
    /// 常压几百张的人设一次就够了，所以它进设置、被记住。
    /// 档位定义在 `BatchPlan`（那里也负责切段，界面上的"共 N 批"和
    /// 引擎真正走的批数必须来自同一个函数）。
    var batchSize: Int = 0

    var customFolder: URL? {
        get { customFolderPath.map { URL(fileURLWithPath: $0) } }
        set { customFolderPath = newValue?.path }
    }

    init() {}

    // 手写解码。
    //
    // 合成出来的解码器遇到缺键会**整体失败**，于是新增一个字段就会把用户
    // 之前存的设置悄悄清空——"记住上次设置"这个功能最不能接受的失败方式。
    // 这里逐项 decodeIfPresent，缺哪项就用默认值补，老存档永远读得回来。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CompressSettings()
        sizeGoal = Self.enumValue(SizeGoal.self, from: c, forKey: .sizeGoal, fallback: d.sizeGoal)
        quality = try c.decodeIfPresent(Double.self, forKey: .quality) ?? d.quality
        targetBytes = try c.decodeIfPresent(Int.self, forKey: .targetBytes) ?? d.targetBytes
        maxDimension = try c.decodeIfPresent(Int.self, forKey: .maxDimension) ?? d.maxDimension
        outputMode = Self.enumValue(OutputMode.self, from: c, forKey: .outputMode, fallback: d.outputMode)
        customFolderPath = try c.decodeIfPresent(String.self, forKey: .customFolderPath)
        format = Self.enumValue(FormatChoice.self, from: c, forKey: .format, fallback: d.format)
        keepMetadata = try c.decodeIfPresent(Bool.self, forKey: .keepMetadata) ?? d.keepMetadata
        keepTimestamps = try c.decodeIfPresent(Bool.self, forKey: .keepTimestamps) ?? d.keepTimestamps
        preserveStructure = try c.decodeIfPresent(Bool.self, forKey: .preserveStructure) ?? d.preserveStructure
        grade = try c.decodeIfPresent(LUTGrade.self, forKey: .grade) ?? d.grade
        appearance = Self.enumValue(AppearanceMode.self, from: c, forKey: .appearance, fallback: d.appearance)
        scanMinBytes = try c.decodeIfPresent(Int64.self, forKey: .scanMinBytes) ?? d.scanMinBytes
        // `batchSize` 原来**只编码、不解码**（键在 `CodingKeys` 里，`encode` 会写它，
        // 但这里从来没读），于是每次启动都被静默重置成「一次压完」——
        // 用户看到的是"我明明设了每批 50 张，重开又变回去了"，
        // 而 `SettingsStore.sanitize()` 里那条档位校验也因此永远校验不到真值。
        batchSize = try c.decodeIfPresent(Int.self, forKey: .batchSize) ?? d.batchSize
    }

    /// 宽容地解一个字符串枚举。
    ///
    /// `decodeIfPresent` 只在**键缺失**时给 nil；值本身非法（手改过 UserDefaults、
    /// 或者存的是某个已经删掉的旧档位名）它照样**抛错**。而一抛出去整个设置就解不出来了，
    /// 用户的全部偏好会被一次清空 —— 这正是"记住上次设置"最不能接受的失败方式。
    /// 这里改成先取原始字符串再自己构造，认不出来就回退默认值。
    private static func enumValue<T: RawRepresentable>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        fallback: T
    ) -> T where T.RawValue == String {
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else {
            return fallback
        }
        return T(rawValue: raw) ?? fallback
    }

    private enum CodingKeys: String, CodingKey {
        case sizeGoal, quality, targetBytes, maxDimension, outputMode, customFolderPath
        case format, keepMetadata, keepTimestamps, preserveStructure, grade, appearance
        case scanMinBytes, batchSize
    }

    /// JPEG 源通常无需降采样即可大幅变小；PNG 源主要靠转格式或降采样。
    static let sizeOptions: [(Int, String)] = [
        (0, "不限制"),
        (4096, "4096"),
        (2560, "2560"),
        (1920, "1920"),
        (1440, "1440"),
        (1080, "1080"),
    ]
}

// MARK: - 调色与「无损保真」的互斥

extension CompressSettings {

    /// 当前是不是「无损保真」档（只有在按画质压、且质量正好落在该档时才算）
    var isPristinePreset: Bool {
        sizeGoal == .quality && StrengthPreset.nearest(to: quality) == .pristine
    }

    /// 「无损保真」的卖点是"像素肉眼无差别"，挂上 LUT 这个保证就作废了。
    /// 两者同时成立时这里为 true，界面负责说清楚，引擎负责不生效。
    var gradeBlockedByPristine: Bool {
        isPristinePreset && grade.isActive
    }

    /// 真正送进引擎的调色参数。
    ///
    /// 这一层是**兜底**：即使界面有漏网的路径让两者同时开着，
    /// 引擎这边也绝不会一边承诺"无损"一边把像素改掉。
    /// 界面会明确告诉用户"调色当前不生效"，不存在偷偷改掉的情况。
    var effectiveGrade: LUTGrade {
        gradeBlockedByPristine ? LUTGrade() : grade
    }
}

// MARK: - 一次压缩任务

/// 单张图片的压缩任务。除了文件本身，还要带上"它是从哪个目录被拖进来的"，
/// 这样勾选保留目录层级时才能把子目录结构还原出来。
struct CompressJob: Sendable, Hashable {
    let url: URL
    /// 导入根目录：拖进来的是文件夹就用它，拖进来的是文件就用文件所在目录
    let root: URL
    /// 相对 root 的子目录，空串表示就在根下
    let relativeDir: String

    init(url: URL, root: URL, relativeDir: String) {
        self.url = url
        self.root = root
        self.relativeDir = relativeDir
    }

    /// 独立文件的默认任务（等价于以前的 compress(url:settings:)）
    static func standalone(_ url: URL) -> CompressJob {
        CompressJob(url: url, root: url.deletingLastPathComponent(), relativeDir: "")
    }

    static func make(url: URL, root: URL) -> CompressJob {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        let base = root.standardizedFileURL.path
        var relative = ""
        if parent.count > base.count, parent.hasPrefix(base) {
            relative = String(parent.dropFirst(base.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return CompressJob(url: url, root: root, relativeDir: relative)
    }

    /// 输出文件里要补上的子目录（未勾选保留层级时为空）
    func subdirectory(preserving: Bool) -> String {
        preserving ? relativeDir : ""
    }
}

// MARK: - 工具函数

enum Fmt {
    /// 张数。
    ///
    /// 存在的理由只有一条：**一屏之内必须同一种写法**。
    ///
    /// `Text("…\(n)…")` 是字面量插值，SwiftUI 按 `LocalizedStringKey` 处理，
    /// 会走本地化数字格式、带上千分位（`8,745`）；而 `Text(某个 String)` 走的是
    /// verbatim 那条路，同一个 `\(n)` 拼出来就是 `8745`。于是"找到 8,745 张"
    /// 和"只在 iCloud 上 8745 张"会**并排出现在同一屏上**（实测截图上就是）。
    ///
    /// 所以：凡是**先拼进 `String` 变量、再交给 `Text`** 的张数，都要过这里；
    /// 字面量里直接插值的交给 SwiftUI 自己格式化就对了。
    static func count(_ n: Int) -> String { n.formatted() }

    static func size(_ bytes: Int) -> String {
        bytes <= 0 ? "—" : bytes.formatted(.byteCount(style: .file))
    }

    /// `Int64` 的重载。
    ///
    /// 扫描那边的体积本来就是 `Int64` —— 图库里来自 `PHAssetResource` 的 KVC
    /// （是个 NSNumber），磁盘上是 `URLResourceValues.fileSize`。
    /// 一路窄化成 `Int` 再比大小，等于在最不该出错的一条路上多开几个出错的口子，
    /// 而"挑出大于 1 GB 的大图"正是这个功能存在的理由。
    /// `clamping` 只是让极端值不崩，不是用来修正数据的。
    static func size(_ bytes: Int64) -> String {
        size(Int(clamping: bytes))
    }

    static func compact(_ bytes: Int64) -> String {
        compact(Int(clamping: bytes))
    }

    static func savePercent(from: Int, to: Int) -> Int {
        guard from > 0 else { return 0 }
        return Int(round(Double(from - to) / Double(from) * 100))
    }

    /// 平均每张耗时。
    ///
    /// 和 `duration` **故意不是一个写法**：那一栏回答的是"刚才等了多久"，
    /// 秒以下写小数没有意义；这一栏是一个**速率**，用户拿它估
    /// "下次一千张大概要多久"。0.15 秒和"不到 1 秒"在估算上差着一个量级。
    static func perImage(_ seconds: Double) -> String {
        let value = max(0, seconds)
        if value < 0.01 { return "不到 0.01 秒" }
        if value < 1 { return String(format: "%.2f 秒", value) }
        // 十秒以内留一位小数：2.5 秒和 3 秒在"下一千张要多久"这件事上
        // 差了将近十分钟，不该被四舍五入掉。再往上就没这个必要了。
        if value < 10 { return String(format: "%.1f 秒", value) }
        return duration(value)
    }

    /// 耗时文案：`134` → 「2 分 14 秒」。
    ///
    /// 秒以下**不写小数**，直接说"不到 1 秒"。理由是这一栏要回答的是
    /// "刚才等了多久"，而 0.4 秒和 0.6 秒在体感上没有区别 ——
    /// 写出来只会让人以为这是一次性能测量。
    ///
    /// 分钟整数时不写"0 秒"（「2 分」而不是「2 分 0 秒」）：
    /// 补一个恒为零的量，读起来像少了点什么。
    static func duration(_ seconds: Double) -> String {
        let value = max(0, seconds)
        if value < 1 { return "不到 1 秒" }
        if value < 60 { return "\(Int(value.rounded())) 秒" }

        let total = Int(value.rounded())
        let minutes = total / 60
        let secs = total % 60
        if minutes < 60 {
            return secs == 0 ? "\(minutes) 分" : "\(minutes) 分 \(secs) 秒"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins == 0 ? "\(hours) 小时" : "\(hours) 小时 \(mins) 分"
    }

    /// 列表里更紧凑的体积写法：500 KB / 1.2 MB
    static func compact(_ bytes: Int) -> String {
        guard bytes > 0 else { return "—" }
        let kb = Double(bytes) / 1024
        if kb < 1000 { return "\(Int(kb.rounded())) KB" }
        let mb = kb / 1024
        if mb < 100 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f MB", mb)
    }
}

/// **能被读进来的**扩展名（文件夹扫描与导入共用这一份）。
///
/// ⚠️ 这张表必须和输出档位**闭环**：写得出来的格式，自己就得读得回来。
/// 2026-10-07 加 AVIF 输出时就漏了这里，症状很绕 ——
/// `--format avif` 能产出一张好好的 `photo.avif`，但把那张图再拖回 App，
/// 得到的回答是「这些路径里没有能处理的图片」：
/// 引擎、编码器、映射表全是对的，**只有入口这一行名单没有它**。
/// 引擎测试【26】⑩ 现在钉着这条闭环关系。
let supportExtensions: Set<String> = [
    "jpg", "jpeg", "jpe", "png", "heic", "heif", "tiff", "tif", "bmp", "webp", "gif",
    "avif",
]
