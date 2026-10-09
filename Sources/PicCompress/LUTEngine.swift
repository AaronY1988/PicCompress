import Foundation
import CoreImage
import CoreGraphics

// MARK: - 调色参数

/// 一次调色的全部可调项。**LUT 本身没有参数**（.cube 是固定映射），
/// 这里的旋钮都是外挂在查表前后的，加上一个强度混合。
struct LUTGrade: Sendable, Equatable, Codable {
    static let intensityRange: ClosedRange<Double> = 0...1
    static let exposureRange: ClosedRange<Double> = -2...2
    static let contrastRange: ClosedRange<Double> = 0.5...1.5
    static let warmthRange: ClosedRange<Double> = -1...1
    static let saturationRange: ClosedRange<Double> = 0...2
    static let shadowsRange: ClosedRange<Double> = -1...1

    /// 选中的 .cube 文件；nil 表示不套 LUT，只用旋钮调
    var lutPath: String?
    /// 强度混合 0…1。0 = 完全不用这条 LUT，1 = 原样套用
    var intensity: Double = 1
    /// 这条 LUT 是按哪个色彩空间做的（下载来的文件里不记录这件事）
    var workingSpace: LUTWorkingSpace = .sRGB

    // 查表前
    var exposure: Double = 0
    var contrast: Double = 1
    var warmth: Double = 0

    // 查表后
    var saturation: Double = 1
    var shadows: Double = 0

    var lutURL: URL? { lutPath.map { URL(fileURLWithPath: $0) } }

    var knobsAreNeutral: Bool {
        abs(exposure) < 0.001 && abs(contrast - 1) < 0.001 && abs(warmth) < 0.001
            && abs(saturation - 1) < 0.001 && abs(shadows) < 0.001
    }

    /// 会不会真的改变像素。
    ///
    /// 没挂 LUT、旋钮也全在中性位时返回 false —— 引擎会整段跳过，
    /// 一行像素都不动。"压缩但不影响画质"的承诺就靠这条守住。
    var isActive: Bool {
        if !knobsAreNeutral { return true }
        guard lutPath != nil else { return false }
        return intensity > 0.001
    }

    /// 渲染缓存的键。
    ///
    /// 少了这个，换一条 LUT 会命中上一次的缓存，表现成"改了参数没反应"。
    var cacheKey: String {
        guard isActive else { return "off" }
        let p = lutPath ?? "-"
        return [p, String(Int(intensity * 1000)), workingSpace.rawValue,
                String(Int(exposure * 100)), String(Int(contrast * 1000)),
                String(Int(warmth * 100)), String(Int(saturation * 1000)),
                String(Int(shadows * 100))].joined(separator: "|")
    }

    func sanitized() -> LUTGrade {
        var g = self
        g.intensity = clamp(g.intensity, LUTGrade.intensityRange)
        g.exposure = clamp(g.exposure, LUTGrade.exposureRange)
        g.contrast = clamp(g.contrast, LUTGrade.contrastRange)
        g.warmth = clamp(g.warmth, LUTGrade.warmthRange)
        g.saturation = clamp(g.saturation, LUTGrade.saturationRange)
        g.shadows = clamp(g.shadows, LUTGrade.shadowsRange)
        if g.intensity < 0.001 { g.intensity = 0 }
        return g
    }

    /// 当前生效的旋钮有几项不在中性位（给界面显示"已调整 N 项"用）
    var adjustedKnobCount: Int {
        var c = 0
        if abs(exposure) > 0.001 { c += 1 }
        if abs(contrast - 1) > 0.001 { c += 1 }
        if abs(warmth) > 0.001 { c += 1 }
        if abs(saturation - 1) > 0.001 { c += 1 }
        if abs(shadows) > 0.001 { c += 1 }
        return c
    }

    mutating func resetKnobs() {
        exposure = 0; contrast = 1; warmth = 0; saturation = 1; shadows = 0
    }

    private func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double {
        v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : r.lowerBound
    }
}

// MARK: - 错误

enum LUTError: LocalizedError, Equatable {
    case missing(String)
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .missing(let p): return "找不到 LUT：\((p as NSString).lastPathComponent)"
        case .renderFailed: return "调色没渲染出来"
        }
    }
}

// MARK: - 已解析 LUT 的缓存

/// 一批几百张图会反复用到同一条 LUT，不能每张都重新解析一遍。
/// 键里带上文件修改时间和大小，用户换了同名文件会自动失效。
final class LUTCache: @unchecked Sendable {
    static let shared = LUTCache()

    private var storage: [String: LUTCube] = [:]
    private let lock = NSLock()

    func cube(forPath path: String) -> LUTCube? {
        let key = Self.stamp(path)

        lock.lock()
        let hit = storage[key]
        lock.unlock()
        if let hit { return hit }

        // 解析放在锁外面：一个 65³ 的 LUT 解析要几十毫秒，
        // 不该把别的线程堵在锁上（最坏情况就是两个线程各解析一遍，无害）
        guard let cube = try? LUTCube.load(url: URL(fileURLWithPath: path)) else { return nil }

        lock.lock()
        storage[key] = cube
        lock.unlock()
        return cube
    }

    func reset() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }

    private static func stamp(_ path: String) -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: path)
        let m = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let s = (a?[.size] as? NSNumber)?.intValue ?? 0
        return "\(path)|\(m)|\(s)"
    }
}

// MARK: - 调色引擎

enum LUTEngine {

    /// CIContext 创建成本很高（要建 GPU 管线），必须全局共用一个。
    /// 它是线程安全的，可以并发调用 —— 每张图新建一个会慢得离谱。
    static let context: CIContext = CIContext(options: [
        .cacheIntermediates: false,   // 批处理时不要缓存中间结果，省内存
    ])

    /// 按调色参数渲染一张图。grade.isActive 为 false 时原样返回。
    static func apply(_ image: CGImage, grade: LUTGrade) throws -> CGImage {
        guard grade.isActive else { return image }

        let deep = image.bitsPerComponent > 8
        guard let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw LUTError.renderFailed
        }
        let space = image.colorSpace ?? srgbSpace
        // 透明通道的有无必须原样带过去：凭空多出一个 alpha 通道会让下游
        // 编码出来的 PNG 悄悄变样。
        let info = image.hasAlphaChannel
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue

        func makeContext() -> CGContext? {
            CGContext(data: nil, width: image.width, height: image.height,
                      bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0,
                      space: space, bitmapInfo: info)
        }

        // ① 先把输入落地成一张由我们控制格式的普通位图。
        //
        // 这一步不改像素，目的是让 Core Image 看到"确定的像素"：
        // JPEG / HEIC 这类有损格式由 CGImageSource 交出来的是按需解码的图，
        // CI 读它时走的是另一条解码路径（色度上采样方式不同）。实测直接把这种图
        // 喂给 CI，**即便套的是恒等 LUT**，也会有 1.2% 的像素偏移、最大 88 级；
        // 先落地就完全精确。落地一次约 7ms，相对调色本身可以忽略。
        guard let inCtx = makeContext() else { throw LUTError.renderFailed }
        inCtx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let landed = inCtx.makeImage() else { throw LUTError.renderFailed }

        let extent = CGRect(x: 0, y: 0, width: landed.width, height: landed.height)
        let ci = pipeline(CIImage(cgImage: landed), grade: grade).cropped(to: extent)

        // ② 渲染进另一张我们自己控参数的位图。
        //
        // 这里不用 createCGImage：它只能给固定格式，要么把不透明图变成带 alpha 的、
        // 要么把色彩空间换成上下文默认值（实测默认是 DeviceRGB）。两者都会让
        // 下游的编码结果悄悄变化，而 outputProperties 并不写 ICC，
        // 成品的色彩描述完全取决于这张图自己的 colorSpace。
        guard let outCtx = makeContext(), let base = outCtx.data else {
            throw LUTError.renderFailed
        }
        context.render(ci, toBitmap: base, rowBytes: outCtx.bytesPerRow, bounds: extent,
                       format: deep ? .RGBA16 : .RGBA8, colorSpace: space)
        guard let out = outCtx.makeImage() else { throw LUTError.renderFailed }
        return out
    }

    /// 把当前的调色参数反向烘焙成一份 .cube 文本。
    ///
    /// 做法：造一张 n²×n 的图，每个像素正好对应一个格点，走**同一条管线**渲染，
    /// 再把浮点结果按行读回来。好处是烘焙出来的东西严格等于你在预览里看到的，
    /// 不存在"烘焙逻辑和渲染逻辑各写一套、慢慢跑偏"的问题。
    static func bake(grade: LUTGrade, dimension: Int = 33) throws -> String {
        let n = max(2, min(dimension, LUTCube.maxDimension))
        let w = n * n, h = n
        let count = w * h * 4
        // sRGB 在 macOS 上必然存在；万一拿不到就没法保证色彩正确，直接失败而不是猜
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw LUTError.renderFailed
        }

        // 格点布局：横坐标 x = r + g·n（r 最快），纵坐标 y = b。
        // 按行读回来就是 b·n² + g·n + r —— 正好是 .cube 要求的 R 最快顺序。
        //
        // 这里用**浮点缓冲直接构造 CIImage**，不走 CGImage。原因是实测发现：
        // 16 位整数的 CGImage 在 1089×33 这种尺寸下会被 Core Image 读错
        // （见 Scripts/lut-spike），而 8 位又会把格点坐标量化掉，
        // 两者都会让烘焙结果和预览对不上。浮点路径既没有位深问题也没有量化。
        let d = Float(n - 1)
        var lattice = [Float](repeating: 0, count: count)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let i = ((b * n + g) * n + r) * 4
                    lattice[i] = Float(r) / d
                    lattice[i + 1] = Float(g) / d
                    lattice[i + 2] = Float(b) / d
                    lattice[i + 3] = 1
                }
            }
        }

        let rowBytes = w * 4 * MemoryLayout<Float>.size
        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        // latticeData 必须活到渲染结束：CIImage 引用的是这块内存
        let latticeData = lattice.withUnsafeBufferPointer { Data(buffer: $0) }
        let source = CIImage(
            bitmapData: latticeData, bytesPerRow: rowBytes,
            size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: srgb
        )

        let ci = pipeline(source, grade: grade).cropped(to: extent)

        var floats = [Float](repeating: 0, count: count)
        floats.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(ci, toBitmap: base, rowBytes: rowBytes, bounds: extent,
                           format: .RGBAf, colorSpace: srgb)
        }

        var lines: [String] = []
        lines.reserveCapacity(h * w + 6)
        lines.append("# 由 图片压缩 导出")
        lines.append("# 按 \(grade.workingSpace.title) 生成，导入别的软件时也要选同一个色彩空间")
        if grade.intensity < 0.999 {
            lines.append(String(format: "# 已含 LUT 强度 %.0f%%", grade.intensity * 100))
        }
        lines.append("TITLE \"\(bakedTitle(grade))\"")
        lines.append("LUT_3D_SIZE \(n)")
        lines.append("DOMAIN_MIN 0.0 0.0 0.0")
        lines.append("DOMAIN_MAX 1.0 1.0 1.0")

        for i in stride(from: 0, to: floats.count, by: 4) {
            lines.append(String(format: "%.6f %.6f %.6f", floats[i], floats[i + 1], floats[i + 2]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: 管线
    //
    // 顺序：查表前的旋钮 → 定义域换算 → LUT → 查表后的旋钮
    // 烘焙和正常渲染都走这里，保证两边严格一致。

    private static func pipeline(_ input: CIImage, grade: LUTGrade) -> CIImage {
        var ci = input

        // ---- 查表前 ----
        if abs(grade.exposure) > 0.001 {
            ci = ci.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: grade.exposure])
        }
        if abs(grade.contrast - 1) > 0.001 {
            ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: grade.contrast])
        }
        if abs(grade.warmth) > 0.001 {
            // 不做真正的色温换算，就是一个 R/B 增益。慢一点的好处是行为可预期、可测试：
            // 拉到 +1 就是红 ×1.15、蓝 ×0.85，肉眼即"变暖"。
            let w = grade.warmth
            ci = ci.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 + w * 0.15, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - w * 0.15, w: 0),
            ])
        }

        // ---- LUT ----
        if let path = grade.lutPath, grade.intensity > 0.001,
           let cube = LUTCache.shared.cube(forPath: path) {
            ci = domainAdjust(ci, cube)
            ci = applyCube(ci, cube: cube, intensity: grade.intensity, space: grade.workingSpace)
        }

        // ---- 查表后 ----
        if abs(grade.saturation - 1) > 0.001 {
            ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: grade.saturation])
        }
        if abs(grade.shadows) > 0.001 {
            ci = ci.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": grade.shadows,
                "inputHighlightAmount": 1.0,   // 不动高光
            ])
        }

        return ci
    }

    private static func applyCube(
        _ image: CIImage, cube: LUTCube, intensity: Double, space: LUTWorkingSpace
    ) -> CIImage {
        // 强度直接混进立方体数据（见 LUTCube.blended 的说明），不额外加混合滤镜
        let data = cube.blended(intensity: intensity)
        var params: [String: Any] = [
            "inputCubeDimension": Float(cube.dimension),
            "inputCubeData": data,
        ]
        // 色彩空间必须显式给。不指定时 Core Image 按线性 RGB 处理，
        // 而对 S 形对比曲线这会差出 30 级以上（见 Scripts/lut-spike 实测）
        if let cs = space.cgColorSpace {
            params["inputColorSpace"] = cs
        }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: params)
    }

    /// DOMAIN_MIN / DOMAIN_MAX 不是 0…1 时，先把输入映射到 0…1。
    /// 绝大多数 .cube 是 0…1，这种就直接返回，一个滤镜都不加。
    private static func domainAdjust(_ image: CIImage, _ cube: LUTCube) -> CIImage {
        let mn = cube.domainMin, mx = cube.domainMax
        let span = [mx[0] - mn[0], mx[1] - mn[1], mx[2] - mn[2]]
        let usual = mn.allSatisfy { abs($0) < 1e-6 } && span.allSatisfy { abs($0 - 1) < 1e-6 }
        guard !usual else { return image }

        let sx = 1 / max(span[0], 1e-6)
        let sy = 1 / max(span[1], 1e-6)
        let sz = 1 / max(span[2], 1e-6)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: sx, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: sy, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: sz, w: 0),
            "inputBiasVector": CIVector(x: -mn[0] * sx, y: -mn[1] * sy, z: -mn[2] * sz, w: 0),
        ])
    }

    private static func bakedTitle(_ grade: LUTGrade) -> String {
        guard let path = grade.lutPath else { return "图片压缩 · 调色" }
        let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return "\(base) · 图片压缩调色"
    }
}
