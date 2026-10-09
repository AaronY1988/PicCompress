import Foundation
import Combine

// MARK: - 库里的一条 LUT

struct LUTEntry: Identifiable, Hashable, Sendable {
    /// 库内文件名，同时充当 id（库内唯一）
    let fileName: String
    let url: URL
    /// .cube 头部 TITLE 里的名字
    let title: String?
    let dimension: Int?
    let fileBytes: Int
    /// 只读文件头就发现的问题。坏文件也照样列出来，好让用户能看到并删掉它
    let problem: String?

    var id: String { fileName }

    /// 用**文件名**作为显示名。
    ///
    /// .cube 头部还带一个 TITLE，通常名字更好看，但它是文件内部的内容、
    /// 用户在 App 里改不了。显示名跟着文件名走，改名才是有反馈的；
    /// TITLE 放在副标题里展示，信息一点不丢。
    var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }

    /// 文件里写的 TITLE，和文件名不一样时才值得单独露出来
    var subtitle: String? {
        guard let title, !title.isEmpty, title != displayName else { return nil }
        return title
    }

    var sizeLabel: String? { dimension.map { "\($0)³" } }
}

// MARK: - 导入结果

struct LUTImportIssue: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let reason: String
}

struct LUTImportReport: Sendable {
    var imported: [String] = []
    var skipped: [LUTImportIssue] = []

    var total: Int { imported.count + skipped.count }

    var summary: String {
        guard total > 0 else { return "没有可导入的文件" }
        var parts: [String] = []
        if !imported.isEmpty { parts.append("导入 \(imported.count) 条") }
        if !skipped.isEmpty { parts.append("跳过 \(skipped.count) 条") }
        return parts.joined(separator: "，")
    }
}

// MARK: - LUT 库

/// App 内建的 LUT 库：把 .cube 拷进 Application Support 下自己的目录里统一管理。
///
/// 为什么是拷进来而不是记录原路径：网上下载的 LUT 散落在下载文件夹里，
/// 清一次下载目录就全断了；拷进来之后删原文件也不影响，还能给每条 LUT
/// 挂上"工作色彩空间"这类标注。
///
/// 只依赖 Foundation，方便脱离 SwiftUI 单独测试。
///
/// 这里**故意不加 @MainActor**：它是一层文件系统 + 标注的读写，
/// 所有调用点（界面动作、开发期钩子）本来就都在主线程上，
/// 而加上 @MainActor 会让它没法在命令行类型的测试里同步调用。
/// 后台线程不碰它，所以不存在竞态。
final class LUTLibrary: ObservableObject {

    static let shared = LUTLibrary()

    /// 标注存在库目录里的这个小文件，跟着 LUT 一起复制走
    static let annotationFile = "_标注.json"

    @Published private(set) var entries: [LUTEntry] = []
    @Published private(set) var folder: URL

    private let fm = FileManager.default
    /// 每条 LUT 的工作色彩空间标注（文件名 → 色彩空间）
    private var spaces: [String: LUTWorkingSpace] = [:]

    // MARK: 位置

    /// 默认放在 Application Support 下：跟着用户账户走，重装 App 也不丢
    static func defaultFolder() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("PicCompress", isDirectory: true)
            .appendingPathComponent("LUTs", isDirectory: true)
    }

    init(folder: URL? = nil) {
        // 开发期钩子：和项目里其它 PICCOMPRESS_* 环境变量一个路子，
        // 出截图时可以把库指向一个现成的目录，不动用户真实的那一份
        let override = folder
            ?? ProcessInfo.processInfo.environment["PICCOMPRESS_LUT_FOLDER"]
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        self.folder = override ?? Self.defaultFolder()
        ensureFolder()
        loadAnnotations()
        refresh()
    }

    @discardableResult
    func ensureFolder() -> Bool {
        if fm.fileExists(atPath: folder.path) { return true }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    // MARK: 扫描

    func refresh() {
        guard ensureFolder() else {
            entries = []
            return
        }
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let contents = (try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []

        var found: [LUTEntry] = []
        for url in contents {
            guard url.pathExtension.lowercased() == "cube" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile ?? false else { continue }

            // 只读前 8KB：一个装满 LUT 的库不能每次刷新都整份解析
            let peeked = LUTCube.peek(url: url)
            found.append(LUTEntry(
                fileName: url.lastPathComponent,
                url: url,
                title: peeked.title,
                dimension: peeked.dimension,
                fileBytes: values?.fileSize ?? 0,
                problem: peeked.error?.errorDescription
            ))
        }

        entries = found.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: 导入

    /// 把外部的 .cube 拷进库里。
    ///
    /// 导入前**完整解析一遍**再决定收不收：宁可导入时慢半拍，
    /// 也不能让一个坏文件进了库，等到压几百张图的时候才炸。
    func importFiles(_ urls: [URL]) -> LUTImportReport {
        var report = LUTImportReport()

        guard ensureFolder() else {
            report.skipped = urls.map {
                LUTImportIssue(name: $0.lastPathComponent, reason: "建不了库目录 \(folder.path)")
            }
            return report
        }

        var taken = Set(entries.map { $0.fileName.lowercased() })

        for raw in urls {
            let name = raw.lastPathComponent

            guard raw.pathExtension.lowercased() == "cube" else {
                report.skipped.append(LUTImportIssue(name: name, reason: "不是 .cube 文件"))
                continue
            }
            let isDir = (try? raw.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDir else {
                report.skipped.append(LUTImportIssue(name: name, reason: "这是个文件夹"))
                continue
            }

            do {
                _ = try LUTCube.load(url: raw)
            } catch {
                let reason = (error as? LUTParseError)?.errorDescription
                    ?? error.localizedDescription
                report.skipped.append(LUTImportIssue(name: name, reason: reason))
                continue
            }

            // 内容一样就不重复入库。
            //
            // 判断分两级：先比大小（读目录时就拿到了，免费），
            // 大小撞上了再逐块比字节。为什么不能只看文件名：
            // 用户从两个地方下载同一条 LUT，文件名往往不一样；
            // 反过来，同名但作者改过内容的两条也必须都能留下。
            let size = ImageCompressor.fileSize(raw)
            if let twin = entries.first(where: {
                $0.fileBytes == size && sameContent($0.url, raw)
            }) {
                report.skipped.append(LUTImportIssue(
                    name: name, reason: "库里已经有同一个文件了（\(twin.displayName)）"
                ))
                continue
            }

            let target = uniqueURL(for: name, taken: &taken)
            do {
                try fm.copyItem(at: raw, to: target)
            } catch {
                report.skipped.append(LUTImportIssue(
                    name: name, reason: "拷进库里失败：\(error.localizedDescription)"
                ))
                continue
            }

            // 名字撞了会带 -2 后缀，顺带把原文件名记下来
            report.imported.append(
                target.lastPathComponent == name
                    ? name
                    : "\(name) → \(target.lastPathComponent)"
            )
        }

        refresh()
        return report
    }

    /// 逐块比对两个文件内容是否完全一样。
    /// 只在**文件大小已经相同**时才被调用，所以平时根本不走这条路径，
    /// 一次性读进内存也不划算（65³ 的 .cube 有 7MB）。
    private func sameContent(_ a: URL, _ b: URL) -> Bool {
        guard let fa = try? FileHandle(forReadingFrom: a),
              let fb = try? FileHandle(forReadingFrom: b) else { return false }
        defer {
            try? fa.close()
            try? fb.close()
        }

        let chunk = 1 << 20
        while true {
            // 注意 read(upToCount:) 到 EOF 时返回的是 nil 而不是空 Data，
            // 所以"两边同时 nil"必须当成相等处理 —— 当成失败会把所有文件都判成不同
            let da = try? fa.read(upToCount: chunk)
            let db = try? fb.read(upToCount: chunk)
            switch (da, db) {
            case (nil, nil):
                return true
            case let (a?, b?):
                if a != b { return false }
                if a.isEmpty { return true }
            default:
                return false          // 一边读到东西另一边没了 = 长度不同
            }
        }
    }

    /// 库里没有就挑一个不撞的名字（`名字-2.cube`、`名字-3.cube`…）
    private func uniqueURL(for fileName: String, taken: inout Set<String>) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = fileName
        var index = 2
        while taken.contains(candidate.lowercased())
            || fm.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(index).\(ext)"
            index += 1
        }
        taken.insert(candidate.lowercased())
        return folder.appendingPathComponent(candidate)
    }

    // MARK: 维护

    /// 删掉一条。走系统废纸篓，删错了还能捞回来
    @discardableResult
    func remove(_ entry: LUTEntry) -> Bool {
        do {
            try fm.trashItem(at: entry.url, resultingItemURL: nil)
        } catch {
            // 有些卷（网络盘、外置 FAT）不支持废纸篓，退一步直接删
            do { try fm.removeItem(at: entry.url) } catch { return false }
        }
        spaces.removeValue(forKey: entry.fileName)
        saveAnnotations()
        refresh()
        return true
    }

    /// 改名。返回 nil 表示成功，否则是给用户看的原因
    func rename(_ entry: LUTEntry, to newBase: String) -> String? {
        let clean = newBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "名字不能是空的" }
        guard clean.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\\\\")) == nil else {
            return "名字里不能有 / 或 :"
        }

        let targetName = clean.lowercased().hasSuffix(".cube") ? clean : clean + ".cube"
        guard targetName != entry.fileName else { return nil }

        var taken = Set(entries.map { $0.fileName.lowercased() })
        taken.remove(entry.fileName.lowercased())
        let target = uniqueURL(for: targetName, taken: &taken)

        do {
            try fm.moveItem(at: entry.url, to: target)
        } catch {
            return "改名失败：\(error.localizedDescription)"
        }

        if let space = spaces.removeValue(forKey: entry.fileName) {
            spaces[target.lastPathComponent] = space
            saveAnnotations()
        }
        refresh()
        return nil
    }

    /// 导入时把同名的标注一起带过来（从别处整库拷过来时用得上）
    func adoptAnnotation(from oldName: String, to newName: String) {
        guard let space = spaces[oldName] else { return }
        spaces[newName] = space
        saveAnnotations()
    }

    // MARK: 走文件头 / 画像

    func entry(forPath path: String) -> LUTEntry? {
        entries.first { $0.url.path == path }
    }

    /// 列表和导出上用的人话名字，库外路径也能给一个
    func displayName(forPath path: String) -> String {
        if let e = entry(forPath: path) { return e.displayName }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    /// 完整解析一次拿画像。`LUTCache` 会兜住重复调用，所以这里不用自己缓存
    func profile(for entry: LUTEntry) -> LUTProfile? {
        LUTCache.shared.cube(forPath: entry.url.path)?.profile
    }

    func profile(forPath path: String) -> LUTProfile? {
        LUTCache.shared.cube(forPath: path)?.profile
    }

    // MARK: 工作色彩空间标注

    /// .cube 文件里**不记录**自己的工作色彩空间，而下载来的 LUT 来源混杂。
    /// 这里给每条 LUT 挂一个标注：默认按最常见的 sRGB，用户可以逐条改，改完记住。
    func workingSpace(for entry: LUTEntry) -> LUTWorkingSpace {
        spaces[entry.fileName] ?? .sRGB
    }

    func workingSpace(forPath path: String) -> LUTWorkingSpace? {
        guard let entry = entry(forPath: path) else { return nil }
        return workingSpace(for: entry)
    }

    func setWorkingSpace(_ space: LUTWorkingSpace, for entry: LUTEntry) {
        spaces[entry.fileName] = space
        saveAnnotations()
        objectWillChange.send()
    }

    /// 有没有为某条 LUT 特意标过（界面据此显示"自动"还是"已指定"）
    func hasAnnotation(for entry: LUTEntry) -> Bool {
        spaces[entry.fileName] != nil
    }

    private func loadAnnotations() {
        let url = folder.appendingPathComponent(Self.annotationFile)
        guard let data = try? Data(contentsOf: url) else { return }
        // 标注文件是不可信输入（用户可能手改过），坏了就当没有，不要影响主流程
        guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        spaces = decoded.compactMapValues { LUTWorkingSpace(rawValue: $0) }
    }

    private func saveAnnotations() {
        let url = folder.appendingPathComponent(Self.annotationFile)
        let plain = spaces.mapValues { $0.rawValue }
        guard let data = try? JSONEncoder().encode(plain) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
