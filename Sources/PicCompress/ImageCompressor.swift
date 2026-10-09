import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import AppKit

// MARK: - 结果与错误

struct CompressOutcome: Sendable {
    let outputURL: URL
    let originalBytes: Int
    let outputBytes: Int
    let pixelWidth: Int
    let pixelHeight: Int
    /// 结果比原图还大（说明原图已经压得很狠了）
    let grew: Bool
    /// 是否发生了替换 / 转格式导致的原文件清理
    let replacedOriginal: Bool
    /// 没有产出文件（原图已是最优，保留原样）
    let noChange: Bool
    /// 实际使用的质量（按体积压缩时由搜索决定，和设置里的值可能不同）
    let usedQuality: Double
    /// 按体积压缩时是否达成了目标
    let targetMet: Bool

    var savedBytes: Int { max(0, originalBytes - outputBytes) }
    var savedPercent: Int { Fmt.savePercent(from: originalBytes, to: outputBytes) }
}

enum CompressError: LocalizedError, Equatable {
    case notFound
    case unreadable
    case empty
    case animated
    case cannotEncode
    case noDestination
    case targetUnreachable(Int)
    case gradingFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "文件不存在"
        case .unreadable: return "无法读取"
        case .empty: return "空文件"
        case .animated: return "动图不处理"
        case .cannotEncode: return "编码失败"
        case .noDestination: return "未选择输出文件夹"
        case .targetUnreachable(let bytes): return "压不到 \(TargetSize.label(bytes))"
        case .gradingFailed(let why): return "调色失败：\(why)"
        }
    }
}

extension CGImage {
    var hasAlphaChannel: Bool {
        switch alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            return true
        default:
            return false
        }
    }
}

// MARK: - 同一次运行内的输出路径登记

/// 防止"保留目录层级 + 输出到指定文件夹"时多张同名图片相互覆盖。
/// 同一批任务共用一个实例；单独调用压缩时可以不传。
final class PathReserver: @unchecked Sendable {
    private var used = Set<String>()
    private let lock = NSLock()

    func reserve(_ url: URL) -> URL {
        lock.lock()
        defer { lock.unlock() }

        var candidate = url
        var index = 2
        while used.contains(candidate.standardizedFileURL.path) {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var next = url.deletingLastPathComponent()
                .appendingPathComponent("\(base)-\(index)")
            if !ext.isEmpty { next.appendPathExtension(ext) }
            candidate = next
            index += 1
        }
        used.insert(candidate.standardizedFileURL.path)
        return candidate
    }
}

// MARK: - 压缩引擎

enum ImageCompressor {

    static let heicType = UTType.heic

    /// AVIF。**`UTType.avif` 不存在**（SDK 里没有这个静态成员），只能按标识符取。
    /// 兜底那一路是为了"系统没声明这个 UTI"的机器 —— 给 nil 的话下面
    /// `case .avif` 会直接崩在取 targetType 那一步。
    static let avifType = UTType("public.avif") ?? UTType(exportedAs: "public.avif")

    /// 能装下透明通道的格式，其余格式要先压白底
    static let alphaCapableTypeIDs: Set<String> = [
        UTType.png.identifier,
        UTType.tiff.identifier,
        UTType.heic.identifier,
        UTType.heif.identifier,
        UTType.webP.identifier,
        UTType.gif.identifier,
        avifType.identifier,
    ]

    /// 搜索目标体积时允许的最低质量
    static let floorQuality = 0.25
    /// 搜索目标体积时允许缩到的最小边长。
    /// 不设更小是因为：为了凑一个离谱的目标把图缩成 200px 的缩略图，
    /// 用户拿到的虽然"达标"，但已经不是他要的东西了——宁可如实说没做到。
    static let floorEdge = 640

    /// 「同目录新文件夹」模式下建的输出目录名。
    /// 扫描时也会跳过它，避免把自己的上一轮产物当成新素材再压一遍。
    static let outputFolderName = "Compressed"
    /// 「原目录加后缀」模式的后缀，同样在扫描时跳过
    static let suffixTag = "_compressed"

    /// 这个文件是不是我们自己生成的产物
    static func isOwnArtifact(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent.hasSuffix(suffixTag)
    }

    // MARK: 主入口

    static func compress(url: URL, settings: CompressSettings) throws -> CompressOutcome {
        try compress(job: .standalone(url), settings: settings, reserver: nil)
    }

    /// 压一张。
    ///
    /// 输出文件带一个方向标记、像素保持原始朝向 —— 这在 macOS 和「照片」里
    /// 显示都是对的，导出到别处也基本没问题，所以不需要先把方向烘焙进像素。
    /// （降采样那条路例外：`CreateThumbnailWithTransform` 顺手就摆正了，
    /// 于是标记写「向上」，那本来也是对的。）
    static func compress(
        job: CompressJob,
        settings: CompressSettings,
        reserver: PathReserver? = nil
    ) throws -> CompressOutcome {
        let url = job.url

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CompressError.notFound
        }
        let originalBytes = fileSize(url)
        guard originalBytes > 0 else { throw CompressError.empty }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw CompressError.unreadable
        }

        let sourceTypeID = CGImageSourceGetType(source) as String?
        let sourceType = sourceTypeID.flatMap { UTType($0) }

        // 动图默认不碰（重编码会丢帧）
        if settings.format == .keep, sourceType == .gif, CGImageSourceGetCount(source) > 1 {
            throw CompressError.animated
        }

        let targetType = resolveTargetType(sourceType: sourceType, choice: settings.format)
        let targetExt = preferredExtension(for: targetType)
        let sourceExt = url.pathExtension.lowercased()

        var destination = try destinationURL(job: job, targetExt: targetExt, settings: settings)
        // 覆盖模式写回原文件，不参与去重
        if settings.outputMode != .overwrite, let reserver {
            destination = reserver.reserve(destination)
        }

        // 输出目录必须存在
        let dir = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let context = RenderContext(
            source: source,
            props: props,
            orientation: (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1,
            srcW: (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0,
            srcH: (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0,
            targetType: targetType,
            targetExt: targetExt,
            dir: dir,
            keepMetadata: settings.keepMetadata,
            grade: settings.effectiveGrade
        )

        // MARK: 选出一份编码结果

        let render: RenderResult
        var targetMet = true

        switch settings.sizeGoal {
        case .quality:
            render = try renderOnce(
                context,
                quality: settings.quality,
                maxDimension: settings.maxDimension,
                cache: RenderCache()
            )
        case .targetBytes:
            let search = try searchForTarget(context, settings: settings, target: settings.targetBytes)
            render = search.result
            targetMet = search.met
        }

        defer { try? FileManager.default.removeItem(at: render.url) }

        let outputBytes = render.bytes
        let grew = outputBytes >= originalBytes

        // 覆盖模式 + 没变小 → 保持原图不动，什么都不做
        if grew, settings.outputMode == .overwrite {
            return CompressOutcome(
                outputURL: url,
                originalBytes: originalBytes,
                outputBytes: originalBytes,
                pixelWidth: render.width,
                pixelHeight: render.height,
                grew: true,
                replacedOriginal: false,
                noChange: true,
                usedQuality: render.quality,
                targetMet: targetMet
            )
        }

        // MARK: 落位

        let stamps = (settings.keepTimestamps && settings.outputMode.isInPlace)
            ? timestamps(of: url) : nil

        var replaced = false
        let extChanged = sourceExt != targetExt

        if settings.outputMode == .overwrite, extChanged {
            // 格式变了没法原地覆盖：新文件落位，原文件进废纸篓（可恢复）
            try place(render.url, at: destination)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                replaced = true
            }
        } else {
            try place(render.url, at: destination)
        }

        if let stamps { apply(stamps, to: destination) }

        return CompressOutcome(
            outputURL: destination,
            originalBytes: originalBytes,
            outputBytes: outputBytes,
            pixelWidth: render.width,
            pixelHeight: render.height,
            grew: grew,
            replacedOriginal: replaced,
            noChange: false,
            usedQuality: render.quality,
            targetMet: targetMet
        )
    }

    // MARK: - 按体积搜索

    private struct SearchResult {
        let result: RenderResult
        let met: Bool
    }

    /// 先试用户当前参数；不行就先在"可接受的最低质量"下缩尺寸，尺寸定了再把质量提回去。
    ///
    /// 为什么不直接把质量一降到底：一张 4200px 的大图，压到 500KB 用 q=32% 会明显发虚；
    /// 缩到 2000px 用 q=78% 一样是 500KB，但看起来干净得多。用户要的是"能传上去且不难看"，
    /// 不是"质量数字越大越好"。
    private static func searchForTarget(
        _ context: RenderContext,
        settings: CompressSettings,
        target: Int
    ) throws -> SearchResult {

        // PNG / TIFF / GIF 是无损的，质量参数对它没影响，只能靠缩尺寸
        let qualityMatters = qualityAffectsSize(context.targetType)
        let cache = RenderCache()

        func render(_ quality: Double, _ edge: Int) throws -> RenderResult {
            try renderOnce(
                context,
                quality: quality,
                maxDimension: edge,
                cache: cache,
                effectiveQuality: qualityMatters ? quality : 1.0
            )
        }

        func finish(_ winner: RenderResult, met: Bool) -> SearchResult {
            for result in cache.all where result.url != winner.url {
                try? FileManager.default.removeItem(at: result.url)
            }
            return SearchResult(result: winner, met: met)
        }

        let originalEdge = max(context.srcW, context.srcH)
        let startEdge = settings.maxDimension > 0
            ? min(settings.maxDimension, originalEdge)
            : originalEdge

        // 0. 用户当前参数就够小的话，直接交差（绝大多数情况到这就结束了）
        let asIs = try render(settings.quality, settings.maxDimension)
        if asIs.bytes <= target { return finish(asIs, met: true) }

        // 愿意为"不缩尺寸"付出的最低质量；再往下就不如缩尺寸了
        let qualityFloor = qualityMatters
            ? min(settings.quality, max(settings.quality - 0.12, 0.60))
            : settings.quality

        var smallest = asIs
        var winner: RenderResult?
        var winnerEdge = 0
        var failedEdge = startEdge
        var edge = startEdge
        // 允许缩到的最小边长（不超过用户自己设的上限）
        let minEdge = min(floorEdge, startEdge)

        // 1. 逐级缩尺寸，直到达标
        for _ in 0..<8 {
            let probe = try render(qualityFloor, edge)
            if probe.bytes < smallest.bytes { smallest = probe }

            if probe.bytes <= target {
                winner = probe
                winnerEdge = edge
                break
            }

            failedEdge = edge
            // 体积大致随像素数走，但缩图后每个像素更难压，系数收一点
            let ratio = min(0.92, max(0.55, sqrt(Double(target) / Double(max(1, probe.bytes))) * 0.97))
            let next = Int(Double(edge) * ratio)
            if next >= edge || edge <= minEdge { break }
            edge = max(minEdge, next)
        }

        // 2. 在"太大"和"够小"之间再夹两轮，尽量贴着目标线
        if let found = winner, failedEdge > winnerEdge {
            var low = winnerEdge
            var high = failedEdge
            var best = found
            for _ in 0..<2 {
                let mid = (low + high) / 2
                if mid <= low || mid >= high { break }
                let probe = try render(qualityFloor, mid)
                if probe.bytes <= target {
                    best = probe
                    low = mid
                } else {
                    high = mid
                }
            }
            winner = best
            winnerEdge = low
        }

        // 3. 缩到最小尺寸还是压不下去 → 最后一搏，把质量也放到底
        if winner == nil {
            let last = try render(floorQuality, edge)
            if last.bytes < smallest.bytes { smallest = last }
            if last.bytes <= target { winner = last }
        }

        guard let fitting = winner else {
            return finish(smallest, met: smallest.bytes <= target)
        }

        // 4. 尺寸定下来了，再尽量把质量提回去（但不超过用户设定的值）
        if qualityMatters, settings.quality > qualityFloor {
            var low = qualityFloor
            var high = settings.quality
            var best = fitting
            for _ in 0..<3 {
                if high - low < 0.03 { break }
                let mid = (low + high) / 2
                let probe = try render(mid, winnerEdge)
                if probe.bytes <= target {
                    best = probe
                    low = mid
                } else {
                    high = mid
                }
            }
            return finish(best, met: true)
        }

        return finish(fitting, met: true)
    }

    // MARK: - 只估不写

    /// 按给定参数压一遍量个大小，但不落位、不碰原文件（临时文件写在系统临时目录）。
    /// 给"智能推荐"用来把预估换成实测。
    static func probe(url: URL, settings: CompressSettings) -> (original: Int, output: Int)? {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }

        let original = fileSize(url)
        guard original > 0 else { return nil }

        let sourceType = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
        let targetType = resolveTargetType(sourceType: sourceType, choice: settings.format)
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]

        let context = RenderContext(
            source: source,
            props: props,
            orientation: (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1,
            srcW: (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0,
            srcH: (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0,
            targetType: targetType,
            targetExt: preferredExtension(for: targetType),
            dir: FileManager.default.temporaryDirectory,
            keepMetadata: settings.keepMetadata,
            grade: settings.effectiveGrade
        )

        let rendered: RenderResult?
        switch settings.sizeGoal {
        case .quality:
            rendered = try? renderOnce(
                context,
                quality: settings.quality,
                maxDimension: settings.maxDimension,
                cache: RenderCache()
            )
        case .targetBytes:
            rendered = try? searchForTarget(
                context, settings: settings, target: settings.targetBytes
            ).result
        }

        guard let result = rendered else { return nil }
        defer { try? FileManager.default.removeItem(at: result.url) }
        return (original, result.bytes)
    }

    // MARK: - 单次编码

    private struct RenderContext {
        let source: CGImageSource
        let props: [CFString: Any]
        let orientation: UInt32
        let srcW: Int
        let srcH: Int
        let targetType: UTType
        let targetExt: String
        /// 临时文件写在输出目录里，落位时才是同卷原子替换
        let dir: URL
        let keepMetadata: Bool
        /// 调色参数。全在中性位时不生效，管线上一个滤镜都不加。
        let grade: LUTGrade
    }

    private struct RenderResult {
        let url: URL
        let bytes: Int
        let width: Int
        let height: Int
        let quality: Double
    }

    /// 同一张图的多次试探编码不用重复做（比如 PNG 的尺寸试探和质量无关）
    private final class RenderCache {
        private var storage: [String: RenderResult] = [:]

        var all: [RenderResult] { Array(storage.values) }

        func get(_ key: String) -> RenderResult? { storage[key] }

        func set(_ key: String, _ value: RenderResult) { storage[key] = value }
    }

    private static func renderOnce(
        _ context: RenderContext,
        quality: Double,
        maxDimension: Int,
        cache: RenderCache,
        effectiveQuality: Double? = nil
    ) throws -> RenderResult {
        // 调色参数的哈希必须并进缓存键。少了它，换一条 LUT 会命中上一次的结果，
        // 表现成"改了参数没反应"。
        let key = "\(Int((effectiveQuality ?? quality) * 1000))|\(maxDimension)|\(context.grade.cacheKey)"
        if let hit = cache.get(key) { return hit }
        let result = try renderRaw(context, quality: quality, maxDimension: maxDimension)
        cache.set(key, result)
        return result
    }

    private static func renderRaw(
        _ context: RenderContext,
        quality: Double,
        maxDimension: Int
    ) throws -> RenderResult {

        var image: CGImage
        /// 像素是不是已经"摆正"了。只有摆正过，方向标记才允许写 1。
        var upright = false
        let longest = max(context.srcW, context.srcH)

        if maxDimension > 0, longest > maxDimension {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,   // 同时把方向摆正
                kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(
                context.source, 0, opts as CFDictionary
            ) else { throw CompressError.unreadable }
            image = thumb
            upright = true
        } else {
            guard let raw = CGImageSourceCreateImageAtIndex(
                context.source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            ) else { throw CompressError.unreadable }
            image = raw
        }

        // JPEG 不支持透明通道，带 alpha 的先压到白底
        if !alphaCapableTypeIDs.contains(context.targetType.identifier), image.hasAlphaChannel {
            image = flattenAlpha(image) ?? image
        }

        // 调色：查表 + 前后旋钮。
        // 放在压白底之后，查表看到的就是最终要编码的像素。
        // 实测 Core Image 会先反预乘再查表、查完重新预乘，透明区域不需要额外处理。
        if context.grade.isActive {
            do {
                image = try LUTEngine.apply(image, grade: context.grade)
            } catch {
                throw CompressError.gradingFailed(error.localizedDescription)
            }
        }

        let outProps = outputProperties(
            from: context.props,
            upright: upright,
            orientation: context.orientation,
            targetType: context.targetType,
            quality: quality,
            keepMetadata: context.keepMetadata
        )

        // 先写同目录下的隐藏临时文件，成功后再落位，避免写坏原图
        let tmpURL = context.dir.appendingPathComponent(
            ".piccompress-\(UUID().uuidString).\(context.targetExt)"
        )

        guard let dest = CGImageDestinationCreateWithURL(
            tmpURL as CFURL, context.targetType.identifier as CFString, 1, nil
        ) else { throw CompressError.cannotEncode }

        CGImageDestinationAddImage(dest, image, outProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw CompressError.cannotEncode
        }

        // PNG 走一道 zlib 最高等级重压：像素不变，但通常还能再小一两成
        if context.targetType.conforms(to: .png) {
            rewritePNGTighter(at: tmpURL)
        }

        let bytes = fileSize(tmpURL)
        guard bytes > 0 else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw CompressError.cannotEncode
        }

        return RenderResult(
            url: tmpURL,
            bytes: bytes,
            width: image.width,
            height: image.height,
            quality: quality
        )
    }

    /// 用 zlib 最高等级重压 PNG 的 IDAT，纯无损
    private static func rewritePNGTighter(at url: URL) {
        guard let data = try? Data(contentsOf: url),
              let optimized = PNGOptimizer.optimize(data),
              optimized.count < data.count else { return }
        try? optimized.write(to: url, options: .atomic)
    }

    // MARK: - 落位

    private static func place(_ tmp: URL, at destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: destination)
        }
    }

    // MARK: - 文件时间戳

    private struct FileStamps {
        let created: Date?
        let modified: Date?
    }

    private static func timestamps(of url: URL) -> FileStamps {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return FileStamps(created: values?.creationDate, modified: values?.contentModificationDate)
    }

    private static func apply(_ stamps: FileStamps, to url: URL) {
        var attributes: [FileAttributeKey: Any] = [:]
        if let created = stamps.created { attributes[.creationDate] = created }
        if let modified = stamps.modified { attributes[.modificationDate] = modified }
        guard !attributes.isEmpty else { return }
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }

    // MARK: - 目标路径

    private static func destinationURL(
        job: CompressJob,
        targetExt: String,
        settings: CompressSettings
    ) throws -> URL {
        let url = job.url
        let base = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent()
        let sub = job.subdirectory(preserving: settings.preserveStructure)

        switch settings.outputMode {
        case .overwrite:
            // 扩展名没变就是原路径；变了则同目录换个扩展名
            if url.pathExtension.lowercased() == targetExt { return url }
            return parent.appendingPathComponent(base).appendingPathExtension(targetExt)

        case .suffix:
            // 原地生成副本，目录层级天然保留，不需要额外处理
            return parent.appendingPathComponent("\(base)\(suffixTag)").appendingPathExtension(targetExt)

        case .siblingFolder:
            // 在"导入根目录"下建一个 Compressed，勾选保留层级时再往下还原子目录
            var folder = job.root.appendingPathComponent(outputFolderName, isDirectory: true)
            if !sub.isEmpty { folder.appendPathComponent(sub, isDirectory: true) }
            return folder.appendingPathComponent(base).appendingPathExtension(targetExt)

        case .customFolder:
            guard let root = settings.customFolder else { throw CompressError.noDestination }
            var folder = root
            if !sub.isEmpty { folder.appendPathComponent(sub, isDirectory: true) }
            return folder.appendingPathComponent(base).appendingPathExtension(targetExt)
        }
    }

    // MARK: - 格式判定

    /// 选了哪一档、源图是什么格式 ⇒ 真正编码成什么。
    ///
    /// **这张表就是 `FormatChoice.detail` 里那些话的依据**，改一边必须改另一边。
    ///
    /// `原格式` 那条链的顺序有讲究：
    ///   - PNG 排在 HEIC 前面是**必须**的 —— HEIF 家族包含若干"动图/序列"子类型，
    ///     HEIC 提到 PNG 前会把某些 PNG 认成 HEIC，那是另一类 bug；
    ///   - **AVIF 必须单列**。它是"原格式"这一档的**成员**：我们既然把 AVIF 摆上了台面，
    ///     就不能让选了"原格式"的 AVIF 图被悄悄转成 JPEG（那会同时丢掉体积优势和文件名后缀）。
    ///   - BMP 与 WebP 落到 PNG：WebP 是**没有 encoder** 被迫转，
    ///     BMP 是同一个决定（无损画布），两件事的注释分开写，别合成一句。
    static func resolveTargetType(sourceType: UTType?, choice: FormatChoice) -> UTType {
        switch choice {
        case .jpeg:
            return .jpeg
        case .heic:
            return heicType
        case .avif:
            return avifType
        case .png:
            return .png
        case .keep:
            guard let sourceType else { return .jpeg }
            if sourceType.conforms(to: .jpeg) { return .jpeg }
            if sourceType.conforms(to: .png) { return .png }
            if sourceType.conforms(to: .heic) { return heicType }
            if sourceType.conforms(to: .heif) { return heicType }
            if sourceType.conforms(to: avifType) { return avifType }
            if sourceType.conforms(to: .tiff) { return .tiff }
            if sourceType.conforms(to: .bmp) { return .png }
            if sourceType.conforms(to: .webP) { return .png }
            return .jpeg
        }
    }

    static func preferredExtension(for type: UTType) -> String {
        // AVIF 走一条显式的路：`preferredFilenameExtension` 在
        // 系统没声明这个 UTI 的机器上会给 nil，兜底成 "jpg" —— 那会把
        // AVIF 的数据装进一个 .jpg 的文件里，双击打不开还找不到原因。
        if type == avifType { return "avif" }
        switch type {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tiff"
        default: return type.preferredFilenameExtension ?? "jpg"
        }
    }

    /// 该格式下质量参数是否真的影响体积。
    ///
    /// **只有无损格式才返回 false**（PNG / TIFF / GIF）。这条判据在
    /// `searchForTarget` 里决定"够不够得着目标体积"能不能靠质量去凑 ——
    /// 把一个有损格式误判成无损，就只剩缩尺寸一条路了。
    static func qualityAffectsSize(_ type: UTType) -> Bool {
        type.conforms(to: .jpeg)
            || type.conforms(to: .heic)
            || type.conforms(to: avifType)
    }

    // MARK: 元数据

    private static func outputProperties(
        from srcProps: [CFString: Any],
        upright: Bool,
        orientation: UInt32,
        targetType: UTType,
        quality: Double,
        keepMetadata: Bool
    ) -> [CFString: Any] {
        var out: [CFString: Any] = [:]

        if keepMetadata {
            let inherit: [CFString] = [
                kCGImagePropertyExifDictionary,
                kCGImagePropertyExifAuxDictionary,
                kCGImagePropertyTIFFDictionary,
                kCGImagePropertyGPSDictionary,
                kCGImagePropertyIPTCDictionary,
            ]
            for key in inherit {
                guard var dict = srcProps[key] as? [CFString: Any] else { continue }
                // 像素摆正过之后，这几条"关于原图尺寸/朝向"的元数据就过期了：
                // 尺寸可能已经缩过或转过后交换，方向已经不是原来那个。
                // 留着它们等于给下游一个错的说法。
                if upright {
                    dict.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
                    dict.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
                    dict.removeValue(forKey: kCGImagePropertyTIFFOrientation)
                }
                out[key] = dict
            }
            if let dpiW = srcProps[kCGImagePropertyDPIWidth] { out[kCGImagePropertyDPIWidth] = dpiW }
            if let dpiH = srcProps[kCGImagePropertyDPIHeight] { out[kCGImagePropertyDPIHeight] = dpiH }
        }

        // 摆正过（降采样用了 transform，或写回时专门转过）→ 标记回归 1；
        // 否则像素还是原始朝向，标记必须原样带过去，不然图会歪。
        out[kCGImagePropertyOrientation] = upright ? 1 : Int(orientation)

        if qualityAffectsSize(targetType) {
            out[kCGImageDestinationLossyCompressionQuality] = quality
        }
        return out
    }

    // MARK: 透明通道压到白底

    private static func flattenAlpha(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - 调色导出

    /// 导出调色后的图片。
    ///
    /// 和批量压缩分开走：这里**不缩尺寸、不做体积搜索**，就是把当前参数应用到
    /// 原图全尺寸上，写到你选的位置。用途是"这一张我调好了，想单独存一份"，
    /// 所以优先保证画质（q=0.95）而不是体积。
    static func exportGraded(source: URL, grade: LUTGrade, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path),
              let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(src) > 0 else {
            throw CompressError.unreadable
        }
        guard let raw = CGImageSourceCreateImageAtIndex(
            src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) else { throw CompressError.unreadable }

        let type = exportType(for: destination)
        var image = raw
        // 目标格式装不下透明通道就压白底（和批量压缩里同一条规则）
        if !alphaCapableTypeIDs.contains(type.identifier), image.hasAlphaChannel {
            image = flattenAlpha(image) ?? image
        }
        if grade.isActive {
            do {
                image = try LUTEngine.apply(image, grade: grade)
            } catch {
                throw CompressError.gradingFailed(error.localizedDescription)
            }
        }

        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        // 这里没有走"摆正"那条路，像素还是原始朝向，所以方向标记要原样带过去。
        // 调色导出是给用户在访达里拿走的文件，不需要把方向烘焙进像素。
        let outProps = outputProperties(
            from: props,
            upright: false,
            orientation: (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1,
            targetType: type,
            quality: 0.95,
            keepMetadata: true
        )

        let dir = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // 先写隐藏临时文件再落位，中途失败也不会留下一个半截的成品
        let tmp = dir.appendingPathComponent(".piccompress-export-\(UUID().uuidString)")
            .appendingPathExtension(destination.pathExtension)
        guard let dest = CGImageDestinationCreateWithURL(
            tmp as CFURL, type.identifier as CFString, 1, nil
        ) else { throw CompressError.cannotEncode }

        CGImageDestinationAddImage(dest, image, outProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: tmp)
            throw CompressError.cannotEncode
        }

        if type.conforms(to: .png) { rewritePNGTighter(at: tmp) }
        try place(tmp, at: destination)
    }

    /// 按扩展名决定导出成什么格式。认不出来就按 JPEG 走
    static func exportType(for destination: URL) -> UTType {
        switch destination.pathExtension.lowercased() {
        case "png": return .png
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        default: return .jpeg
        }
    }

    // MARK: 辅助

    /// 把一张**已经解码好的**图缩到指定最长边（只缩不放，够小就原样返回）。
    ///
    /// 和 `previewImage(for:maxPixel:)` 的分工：那个是"从文件解码并顺便缩"，
    /// 走 ImageIO 的缩略图路径，每次都要重新解码；这个是"手上已经有一张图了，
    /// 再要一个小号"。调色预览就属于后者 —— 底图只解码一次（2048），
    /// 拖动时反复要 820、停下来要 1320，靠的就是它。
    ///
    /// 用 `CGContext` + `.high` 插值：Core Image 的 `lanczosScaleTransform` 更漂亮，
    /// 但这里每拖一下都要跑一次，插值质量到 `.high` 就够，肉眼分辨不出。
    /// 位深和透明通道都按原图带过去 —— 凭空多一个 alpha 通道会让下游编码结果变样。
    static func downscale(_ image: CGImage, maxPixel: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard maxPixel > 0, longest > maxPixel else { return image }

        let scale = Double(maxPixel) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))

        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        let space = image.colorSpace ?? srgb
        let info = image.hasAlphaChannel
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue

        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: info
        ) else { return image }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }

    /// 解码成缩小版的 CGImage（调色预览、LUT 卡片缩略图用）。
    /// 必须带 ShouldCacheImmediately —— 否则交出来的是按需解码的图，
    /// Core Image 读它时会走另一条色度上采样路径（见 LUTEngine.apply 的说明）。
    static func previewImage(for url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }

    /// 文件大小。
    ///
    /// 这里**不能用 `URL.resourceValues`** —— 它把结果挂在 URL 对象自身上缓存，
    /// 同一个 URL 第二次问会拿到旧值。覆盖模式下同一个 job 会跑第二遍，
    /// 那时文件已经变小了，拿旧值会把节省比例算错（测试里就是这么暴露出来的：
    /// 文件重写成 128KB，同一个 URL 量出来还是 970KB）。
    /// `attributesOfItem` 每次都真去问文件系统。
    static func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// 生成列表用的小缩略图
    static func thumbnail(for url: URL, maxPixel: Int = 160) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// 解码成 CGImage（对比预览用）。
    ///
    /// 给的是**看起来的样子**，不是**存储的样子**：带 `WithTransform` 读，
    /// 方向标记落在像素里。
    ///
    /// 直接用 `CreateImageAtIndex` 的话，方向只存在于 EXIF 标记里、像素不转。
    /// 于是同一张方向 ≠ 1 的图，会得到两个朝向不同的解码结果：
    /// 原图是"没转的"，而压缩结果是"转过的"（降采样那条路本来就会把方向
    /// 烘焙进像素）。逐像素比对出来的差异就成了**假的** ——
    /// 一个以诚实为底线的工具，最不该出现的就是这种"把旋转报成画质损失"。
    ///
    /// 这个 bug 在"缩过尺寸"的图上一直存在，只是默认不缩尺寸（`maxDimension`
    /// 默认 0）所以没人撞见；一旦用户把尺寸限制打开，它就会变成常见现象。
    static func fullImage(for url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let edge = max(
            (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0,
            (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        )
        if edge > 0 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let upright = CGImageSourceCreateThumbnailAtIndex(
                source, 0, opts as CFDictionary
            ) { return upright }
        }

        return CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        )
    }
}
