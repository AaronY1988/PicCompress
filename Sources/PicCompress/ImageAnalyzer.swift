import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import AppKit

// MARK: - 图片类型

enum ImageKind: String, Sendable, CaseIterable {
    case photo
    case screenshot
    case graphic
    case tiny

    var title: String {
        switch self {
        case .photo: return "照片"
        case .screenshot: return "截图"
        case .graphic: return "插画 / 图标"
        case .tiny: return "小图"
        }
    }

    var icon: String {
        switch self {
        case .photo: return "camera.fill"
        case .screenshot: return "rectangle.on.rectangle"
        case .graphic: return "paintpalette.fill"
        case .tiny: return "circle.dashed"
        }
    }
}

// MARK: - 单张图的分析结果

struct ImageProfile: Sendable {
    let url: URL
    let kind: ImageKind
    let bytes: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let hasAlpha: Bool
    let hasCameraInfo: Bool
    let sourceType: UTType?
    /// 出现频率最高的几种颜色覆盖了多少像素（越高越"平"）
    let flatness: Double
    /// 相邻像素的平均差异，越高细节越多
    let detail: Double

    var longestEdge: Int { max(pixelWidth, pixelHeight) }
}

// MARK: - 推荐方案

struct Recommendation: Sendable {
    let kind: ImageKind
    let preset: StrengthPreset
    let format: FormatChoice
    /// 预估 / 实测还能省下的比例
    let estimatedSaving: Int
    /// 这个数字是拿其中一张真压了一遍量出来的，还是按经验估的
    let measured: Bool
    let reason: String
    let affectedCount: Int
    let totalCount: Int
    let originalBytes: Int

    var estimatedBytes: Int {
        Int(Double(originalBytes) * Double(100 - estimatedSaving) / 100)
    }

    var savingText: String {
        measured ? "实测可省约 \(estimatedSaving)%" : "预估可省约 \(estimatedSaving)%"
    }

    /// 和当前设置相比，是否真的值得改
    func differs(from settings: CompressSettings) -> Bool {
        settings.format != format || abs(settings.quality - preset.quality) > 0.001
    }
}

// MARK: - 分析器

/// 拖进图片后先"看一眼"：是相机拍的照片、屏幕截图，还是带透明的插画。
/// 三类图的最优解完全不同——截图转 HEIC 能省八九成，照片转 HEIC 收益很小还丢兼容性。
enum ImageAnalyzer {

    /// 判断类型时只看 64×64 的采样图，够用且几乎不耗时
    private static let sampleSize = 64

    // MARK: 单张分析

    /// `profile` 的记忆表。
    ///
    /// 一次导入会对**同一批图问两遍**：`AppModel.analyze()` 要算推荐方案，
    /// `AppModel.scheduleEstimate()` 要按源格式分组 —— 两边都从 `profile` 起步。
    /// 两千张就是四千次"开文件 + 读属性 + 解 64×64 + 逐像素走直方图"，
    /// 实测把 CPU 顶在 220% 上三十秒降不下来。而两遍问的是同一件事。
    ///
    /// 键里带体积和修改时间：图被覆盖写过就得重算（覆盖模式真的会改写原图）。
    /// 每个 `ImageProfile` 只有百来字节（直方图不留在里面），两千张约 400KB。
    /// 到上限就整个丢掉重来 —— 丢的只是缓存，**数字一个都不会错**。
    private static let cacheLock = NSLock()
    private static var cache: [String: (stamp: String, value: ImageProfile)] = [:]
    private static let cacheLimit = 4096

    static func profile(_ url: URL) -> ImageProfile? {
        let path = url.standardizedFileURL.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stamp = "\(size)|\(mtime)"

        cacheLock.lock()
        if let hit = cache[path], hit.stamp == stamp {
            cacheLock.unlock()
            return hit.value
        }
        cacheLock.unlock()

        guard let value = computeProfile(url) else { return nil }

        cacheLock.lock()
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[path] = (stamp, value)
        cacheLock.unlock()
        return value
    }

    /// 只要**源格式**，不把图解开。
    ///
    /// `AppModel.scheduleEstimate` 分组只问"这是 JPEG 还是 PNG"，一句话
    /// `CGImageSourceGetType` 就答了；走 `profile` 则会顺带解一张采样图、
    /// 逐像素走一遍直方图 —— 那是为了判"照片还是截图"，分组根本用不上。
    static func sourceType(_ url: URL) -> UTType? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
    }

    private static func computeProfile(_ url: URL) -> ImageProfile? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }

        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let bytes = ImageCompressor.fileSize(url)

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let hasCameraInfo = (tiff[kCGImagePropertyTIFFModel] as? String)?.isEmpty == false
            || (exif[kCGImagePropertyExifLensModel] as? String)?.isEmpty == false
            || (exif[kCGImagePropertyExifDateTimeOriginal] as? String)?.isEmpty == false

        let stats = sampleStats(source) ?? SampleStats(flatness: 0, detail: 0, hasAlpha: false)
        let kind = classify(
            bytes: bytes,
            longest: max(width, height),
            hasCameraInfo: hasCameraInfo,
            stats: stats
        )

        return ImageProfile(
            url: url,
            kind: kind,
            bytes: bytes,
            pixelWidth: width,
            pixelHeight: height,
            hasAlpha: stats.hasAlpha,
            hasCameraInfo: hasCameraInfo,
            sourceType: (CGImageSourceGetType(source) as String?).flatMap { UTType($0) },
            flatness: stats.flatness,
            detail: stats.detail
        )
    }

    // MARK: 分类

    private static func classify(
        bytes: Int,
        longest: Int,
        hasCameraInfo: Bool,
        stats: SampleStats
    ) -> ImageKind {
        if bytes < 60 * 1024, longest <= 1600 { return .tiny }

        // 带透明通道的基本都是设计稿 / 图标，转 JPEG 会把透明压成白底，先隔出来
        if stats.hasAlpha { return .graphic }

        if hasCameraInfo { return .photo }
        // 大片同色 + 颜色种类少 + 没有相机信息 → 屏幕截图
        if stats.flatness > 0.55, stats.detail < 0.055 { return .screenshot }
        if stats.flatness > 0.72, stats.detail < 0.03 { return .graphic }
        return .photo
    }

    // MARK: 给出建议

    /// 按类型给出"最划算"的一套参数。预估比例来自引擎实测（见 Scripts/engine-tests）。
    static func recommend(for profile: ImageProfile) -> Recommendation {
        let isPNG = profile.sourceType?.conforms(to: .png) ?? false
        let isHEIC = profile.sourceType?.conforms(to: .heic)
            ?? profile.sourceType?.conforms(to: .heif) ?? false

        switch profile.kind {
        case .photo:
            if isPNG {
                return Recommendation(
                    kind: .photo, preset: .high, format: .jpeg,
                    estimatedSaving: 78, measured: false, reason: "照片存成 PNG 体积虚高，转 JPEG 肉眼几乎无差",
                    affectedCount: 1, totalCount: 1, originalBytes: profile.bytes
                )
            }
            return Recommendation(
                kind: .photo, preset: .high, format: .keep,
                estimatedSaving: isHEIC ? 30 : 45, measured: false, reason: "相机照片保持原格式、高质量即可，转格式反而丢兼容性",
                affectedCount: 1, totalCount: 1, originalBytes: profile.bytes
            )

        case .screenshot:
            // 截图带透明通道时转 HEIC（HEIC 装得下 alpha），不带就照旧
            let keepAlphaSafe: FormatChoice = isPNG && !profile.hasAlpha ? .heic : .keep
            return Recommendation(
                kind: .screenshot, preset: .high, format: keepAlphaSafe,
                estimatedSaving: isPNG ? 85 : 45, measured: false, reason: isPNG
                    ? "截图存成 PNG 最吃亏，同样是无损观感，转 HEIC 能小八九成"
                    : "截图色块规整，高质量压缩就能明显变小",
                affectedCount: 1, totalCount: 1, originalBytes: profile.bytes
            )

        case .graphic:
            return Recommendation(
                kind: .graphic, preset: .pristine, format: .keep,
                estimatedSaving: 26, measured: false, reason: "带透明或线条的插画只能留在 PNG，靠无损重压省两三成",
                affectedCount: 1, totalCount: 1, originalBytes: profile.bytes
            )

        case .tiny:
            return Recommendation(
                kind: .tiny, preset: .pristine, format: .keep,
                estimatedSaving: 8, measured: false, reason: "这些图已经很小了，压不动多少，建议保留原样",
                affectedCount: 1, totalCount: 1, originalBytes: profile.bytes
            )
        }
    }

    // MARK: 批量汇总

    /// 真压一张的量尺：给（图片, 设置），返回（原大小, 压完大小）；不落位、不动原文件。
    typealias Probe = (URL, CompressSettings) -> (original: Int, output: Int)?

    /// 把一批图片的画像汇总成一条可执行建议；不值得改就返回 nil。
    ///
    /// 给了 `probe` 就会拿组里最大的一张真压一遍，用实测比例替换经验值——
    /// 省不动就干脆不打扰用户，省得为了弹个横幅编数字。
    static func summarize(
        _ profiles: [ImageProfile],
        current settings: CompressSettings,
        probe: Probe? = nil
    ) -> Recommendation? {
        let usable = profiles.filter { $0.bytes > 0 }
        guard !usable.isEmpty else { return nil }

        // 按类型分组，每组取"预计能省下的绝对字节数"最大的一条
        var grouped: [ImageKind: [ImageProfile]] = [:]
        for profile in usable { grouped[profile.kind, default: []].append(profile) }

        let candidates = grouped.map { kind, list -> Recommendation in
            let single = recommend(for: list[0])
            let bytes = list.reduce(0) { $0 + $1.bytes }
            return Recommendation(
                kind: kind,
                preset: single.preset,
                format: single.format,
                estimatedSaving: single.estimatedSaving,
                measured: false,
                reason: single.reason,
                affectedCount: list.count,
                totalCount: usable.count,
                originalBytes: bytes
            )
        }

        // 能省得多、又确实和当前设置不一样的，才值得拿出来说
        let worthSaying = candidates.filter { $0.differs(from: settings) }
        guard let best = worthSaying.max(by: { lhs, rhs in
            let left = Double(lhs.originalBytes) * Double(lhs.estimatedSaving)
            let right = Double(rhs.originalBytes) * Double(rhs.estimatedSaving)
            return left < right
        }), best.estimatedSaving >= 12 else { return nil }

        // 实测校准：拿组里最大的一张按建议参数真压一遍
        guard let probe,
              let sample = usable.filter({ $0.kind == best.kind }).max(by: { $0.bytes < $1.bytes })
        else { return best }

        var probeSettings = settings
        probeSettings.sizeGoal = .quality
        probeSettings.quality = best.preset.quality
        probeSettings.format = best.format
        probeSettings.maxDimension = 0

        guard let sampleResult = probe(sample.url, probeSettings), sampleResult.original > 0 else {
            return best
        }

        let measuredSaving = Fmt.savePercent(from: sampleResult.original, to: sampleResult.output)
        // 实测压不动就别建议了
        guard measuredSaving >= 12 else { return nil }

        return Recommendation(
            kind: best.kind,
            preset: best.preset,
            format: best.format,
            estimatedSaving: measuredSaving,
            measured: true,
            reason: best.reason,
            affectedCount: best.affectedCount,
            totalCount: best.totalCount,
            originalBytes: best.originalBytes
        )
    }

    // MARK: 采样统计

    private struct SampleStats {
        let flatness: Double
        let detail: Double
        let hasAlpha: Bool
    }

    private static func sampleStats(_ source: CGImageSource) -> SampleStats? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: sampleSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            return nil
        }

        let w = thumb.width, h = thumb.height
        guard w > 1, h > 1 else { return nil }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }

        // 颜色直方图（每通道量化到 5 bit，避免渐变噪声把"同色"拆散）
        var histogram: [UInt32: Int] = [:]
        histogram.reserveCapacity(2048)
        var detailSum = 0.0
        var detailCount = 0
        var lowestAlpha: UInt8 = 255

        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = pixels[i], g = pixels[i + 1], b = pixels[i + 2]
                let key = UInt32(r >> 3) << 10 | UInt32(g >> 3) << 5 | UInt32(b >> 3)
                histogram[key, default: 0] += 1

                if pixels[i + 3] < lowestAlpha { lowestAlpha = pixels[i + 3] }

                if x + 1 < w {
                    let j = i + 4
                    detailSum += abs(Double(r) - Double(pixels[j]))
                        + abs(Double(g) - Double(pixels[j + 1]))
                        + abs(Double(b) - Double(pixels[j + 2]))
                    detailCount += 3
                }
            }
        }

        let total = w * h
        let topCoverage = histogram.values.sorted(by: >).prefix(4).reduce(0, +)
        let flatness = Double(topCoverage) / Double(total)
        let detail = detailCount > 0 ? detailSum / Double(detailCount) / 255.0 : 0

        // 直接看像素里有没有真正的透明，别信 alphaInfo：
        // HEIC 解码出来的图经常带一个全不透明的 alpha 通道，按 alphaInfo 判断会误报成"有透明"
        return SampleStats(flatness: flatness, detail: detail, hasAlpha: lowestAlpha < 250)
    }
}
