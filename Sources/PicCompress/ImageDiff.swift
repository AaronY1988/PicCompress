import Foundation
import CoreGraphics
import AppKit

// MARK: - 色差统计

struct DiffStats: Sendable {
    /// 每通道平均色差，0…255
    let meanDiff: Double
    /// 最大单通道色差，0…255
    let maxDiff: Int
    /// 单通道色差超过 3 的像素占比
    let changedRatio: Double
    /// 比对用的尺寸
    let width: Int
    let height: Int
    /// 原图和结果本身的像素尺寸就不一样（压缩时缩过尺寸）
    let dimensionChanged: Bool
    /// 因为原图太大，比对前统一缩过（细节会被平均掉，差异看起来会比实际小一点）
    let downscaledForCompare: Bool
    /// 放大后的差异图
    let diffImage: CGImage?

    var meanText: String { String(format: "%.2f", meanDiff) }
    var changedText: String { String(format: "%.1f%%", changedRatio * 100) }

    /// 给非技术用户看的一句结论
    var verdict: String {
        if maxDiff == 0 { return "像素完全一致，是真无损" }
        if !dimensionChanged, !downscaledForCompare, meanDiff < 0.6, maxDiff <= 6 {
            return "像素级几乎完全一致"
        }
        switch meanDiff {
        case ..<1.5: return "肉眼分辨不出差别"
        case ..<4: return "几乎无差别，放大到 200% 才看得出"
        case ..<9: return "细节有轻微损失，正常观看察觉不到"
        case ..<18: return "损失已经能看出来，建议提高质量档"
        default: return "损失明显，建议用更高质量的档位"
        }
    }

    var verdictLevel: Int {
        switch meanDiff {
        case ..<1.5: return 0
        case ..<4: return 1
        case ..<9: return 2
        default: return 3
        }
    }

    /// 这次比对有多少"水分"，界面要如实标出来
    var note: String {
        if dimensionChanged {
            return "两张图尺寸不同（压缩时缩过），按 \(width)×\(height) 对齐后比对"
        }
        if downscaledForCompare {
            return "原图较大，比对前缩到 \(width)×\(height)（细节会被平均掉）"
        }
        return "逐像素比对 \(width)×\(height)"
    }
}

// MARK: - 逐像素比对

enum ImageDiff {

    /// 超过这个边长就先缩下来再比，避免为了一张图吃几百 MB 内存
    static let pixelCap = 2048
    /// 差异图的放大倍数
    static let amplify: Double = 14

    static func compare(original: URL, compressed: URL) -> DiffStats? {
        guard let sourceImage = ImageCompressor.fullImage(for: original),
              let resultImage = ImageCompressor.fullImage(for: compressed) else { return nil }
        return compare(sourceImage, resultImage)
    }

    static func compare(_ source: CGImage, _ result: CGImage) -> DiffStats? {
        var width = result.width
        var height = result.height

        let dimensionChanged = source.width != result.width || source.height != result.height
        var downscaled = false

        if max(width, height) > pixelCap {
            let scale = Double(pixelCap) / Double(max(width, height))
            width = max(1, Int((Double(width) * scale).rounded()))
            height = max(1, Int((Double(height) * scale).rounded()))
            downscaled = true
        }

        guard width > 0, height > 0,
              let sourcePixels = rgba(source, width: width, height: height),
              let resultPixels = rgba(result, width: width, height: height) else { return nil }

        var diffPixels = [UInt8](repeating: 0, count: width * height * 4)
        var sum = 0.0
        var maxDiff = 0
        var changed = 0

        for index in stride(from: 0, to: width * height * 4, by: 4) {
            let dr = abs(Int(sourcePixels[index]) - Int(resultPixels[index]))
            let dg = abs(Int(sourcePixels[index + 1]) - Int(resultPixels[index + 1]))
            let db = abs(Int(sourcePixels[index + 2]) - Int(resultPixels[index + 2]))

            sum += Double(dr + dg + db) / 3.0
            let worst = max(dr, max(dg, db))
            if worst > maxDiff { maxDiff = worst }
            if worst > 3 { changed += 1 }

            // 差异图上把差别放大成暖色，背景保持近黑，一眼能看出哪里变了
            let intensity = min(255.0, Double(worst) * amplify)
            diffPixels[index] = UInt8(intensity)
            diffPixels[index + 1] = UInt8(intensity * 0.30)
            diffPixels[index + 2] = UInt8(intensity * 0.36)
            diffPixels[index + 3] = 255
        }

        let total = width * height
        let stats = DiffStats(
            meanDiff: sum / Double(total),
            maxDiff: maxDiff,
            changedRatio: Double(changed) / Double(total),
            width: width,
            height: height,
            dimensionChanged: dimensionChanged,
            downscaledForCompare: downscaled,
            diffImage: makeImage(diffPixels, width: width, height: height)
        )
        return stats
    }

    // MARK: 辅助

    private static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buffer : nil
    }

    private static func makeImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
