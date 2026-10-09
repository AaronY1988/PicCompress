import Foundation
import CoreGraphics

// MARK: - LUT 的工作色彩空间

/// .cube 文件里**不记录**自己是按哪个色彩空间做的，而下载来的 LUT 来源混杂。
/// 实测（见 Scripts/lut-spike）：这个参数必须显式指定，不指定时 Core Image 会按
/// 线性 RGB 处理；对平缓曲线只差一两级，但对 S 形对比曲线中间调能差 30 级以上，
/// 而创作型的 LUT 基本都是 S 形。
enum LUTWorkingSpace: String, CaseIterable, Identifiable, Sendable, Codable {
    case sRGB
    case linear
    case rec709

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sRGB: return "sRGB"
        case .linear: return "线性"
        case .rec709: return "Rec.709"
        }
    }

    var detail: String {
        switch self {
        case .sRGB: return "网上下载的绝大多数是这种"
        case .linear: return "给合成 / 线性工作流做的"
        case .rec709: return "影视显示用"
        }
    }

    var cgColorSpace: CGColorSpace? {
        switch self {
        case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)
        case .linear: return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        case .rec709: return CGColorSpace(name: CGColorSpace.itur_709)
        }
    }
}

// MARK: - 中性灰轴画像

/// 从 LUT 自己身上读出来的特征，用来回答"这个 LUT 是给什么素材做的"。
/// 下载来的 LUT 里混着「Log → 显示」的转换 LUT，套在普通照片上会错得离谱，
/// 而用户完全没有线索。这里靠中性灰轴的响应形状把它认出来。
struct LUTProfile: Sendable, Equatable {
    /// 输出离开黑点的输入位置（0…1）
    let inputFloor: Double
    /// 输出到达白点的输入位置（0…1）。常规 LUT 接近 1，转换 LUT 明显偏低
    let inputCeiling: Double
    /// 中性轴是否近似恒等映射
    let isNeutral: Bool
    /// 中灰处的亮度增益，>1 表示这条 LUT 会提亮
    let grayGain: Double
    /// 输入定义域是否不是 0…1
    let unusualDomain: [Double]?

    /// 输入范围被压在窄区间里 —— 典型的「Log → 显示」转换 LUT
    var looksLikeLog: Bool { inputCeiling < 0.82 }

    /// 给用户的一句提醒，没有问题时为 nil
    var hint: String? {
        if isNeutral {
            return "这条 LUT 几乎是恒等映射，套上去看不出变化，可能选错文件了。"
        }
        if looksLikeLog {
            return "输入范围到 \(pct(inputCeiling)) 就满了，像是给 Log 素材做的转换 LUT。"
                + "普通照片套上去会偏暗、反差过强，建议调低强度或加曝光补偿。"
        }
        // 门槛设得高一点：S 形对比曲线本来就会压暗部，阈值太低会变成天天报警的噪音。
        // 这里只在真的压得很狠（四分之一以下全黑）时才提醒。
        if inputFloor > 0.25 {
            return "暗部压得很狠（输入 \(pct(inputFloor)) 以下全是黑），原图有暗部细节的话要注意。"
        }
        if let d = unusualDomain {
            return "输入定义域是 \(d[0])–\(d[1])，已按此换算；如果颜色不对，可能作者的本意不是这样。"
        }
        return nil
    }

    /// 一行人话描述，放在 LUT 列表里用
    var summary: String {
        "输入满值 \(pct(inputCeiling)) · 中灰增益 \(String(format: "%.2f", grayGain))"
    }

    private func pct(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }
}

// MARK: - 解析错误

enum LUTParseError: LocalizedError, Equatable {
    case unreadable
    case tooLarge(Int)
    case notACube
    case missingSize
    case unsupportedSize(Int)
    case only1D
    case badData(line: Int)
    case wrongCount(expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "读不了这个文件"
        case .tooLarge(let b): return "文件太大（\(Fmt.compact(b))），不像正常的 LUT"
        case .notACube: return "不是文本格式的 .cube，可能该解压或换了扩展名"
        case .missingSize: return "文件里没有 LUT_3D_SIZE，不像是 .cube"
        case .unsupportedSize(let n): return "不支持 \(n)³ 的尺寸（本 App 支持 2–65）"
        case .only1D: return "这是 1D LUT，本 App 只支持 3D 的 .cube"
        case .badData(let line): return "第 \(line) 行不是合法的 RGB 数值"
        case .wrongCount(let e, let g): return "数据条数不对：应该有 \(e) 条，实际 \(g) 条"
        }
    }
}

// MARK: - 一条 3D LUT

struct LUTCube: Sendable, Equatable {
    /// 上限 65 是实测出来的可用范围（老文档说"必须是 2 的幂"，已过时）
    static let maxDimension = 65
    /// 65³ 的文本 .cube 约 7.4 MB，留一倍余量
    static let maxFileBytes = 24 * 1024 * 1024
    /// 65³ = 274,625 条数据行，加上头部留点余量
    static let maxLines = 300_000

    let title: String?
    let dimension: Int
    let domainMin: [Double]
    let domainMax: [Double]
    /// 已按 **R 最快** 展开、每条补好 alpha=1.0 的 float32 数据。
    /// 这个顺序与 CIColorCube 的要求一致，**不需要重排**（见 Scripts/lut-spike 实测）。
    let data: Data
    let profile: LUTProfile

    var displayName: String {
        if let t = title, !t.isEmpty { return t }
        return "未命名 LUT"
    }

    var sizeLabel: String { "\(dimension)³" }

    // MARK: 只读文件头
    //
    // 扫一个装满 LUT 的下载文件夹时不能把每个文件都整个解析一遍，
    // 列表只需要名字和尺寸。

    static func peek(url: URL) -> (title: String?, dimension: Int?, error: LUTParseError?) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return (nil, nil, .unreadable) }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 8192) else { return (nil, nil, .unreadable) }
        // 截断可能切到多字节字符，utf8 解不出来就退到 latin1（头部关键字都是 ASCII）
        guard let text = String(data: head, encoding: .utf8)
                ?? String(data: head, encoding: .isoLatin1) else {
            return (nil, nil, .notACube)
        }

        var title: String?
        var dimension: Int?
        var saw1D = false
        var sawAnyKey = false

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let rest = keyword(line, "TITLE") {
                // 先去空白再去引号。反过来的话前导空格会把引号"挡"在修剪范围外，
                // 结果名字里带一个引号。
                title = rest.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                sawAnyKey = true
                continue
            }
            if let rest = keyword(line, "LUT_3D_SIZE") {
                dimension = Int(rest.trimmingCharacters(in: .whitespaces))
                sawAnyKey = true
                continue
            }
            if keyword(line, "LUT_1D_SIZE") != nil { saw1D = true; sawAnyKey = true; continue }
            if line.uppercased().hasPrefix("LUT_") { sawAnyKey = true; continue }
            break   // 碰到数据行就停
        }

        if dimension == nil, saw1D { return (title, nil, .only1D) }
        if dimension == nil, !sawAnyKey { return (title, nil, .notACube) }
        if let n = dimension, n < 2 || n > maxDimension { return (title, n, .unsupportedSize(n)) }
        return (title, dimension, nil)
    }

    // MARK: 完整解析

    static func load(url: URL) throws -> LUTCube {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteSize = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard byteSize > 0 else { throw LUTParseError.unreadable }
        guard byteSize <= maxFileBytes else { throw LUTParseError.tooLarge(byteSize) }

        guard let raw = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw LUTParseError.unreadable
        }
        guard let text = String(data: raw, encoding: .utf8)
                ?? String(data: raw, encoding: .isoLatin1) else {
            throw LUTParseError.notACube
        }

        var title: String?
        var dimension = 0
        var sawSize = false
        var saw1D = false
        var sawKey = false
        var domainMin: [Double] = [0, 0, 0]
        var domainMax: [Double] = [1, 1, 1]
        var values: [Float] = []
        var failure: LUTParseError?
        var lineNo = 0

        text.enumerateLines { rawLine, stop in
            lineNo += 1
            // 文件大小已经卡过了，这里是防"一行一个字符"这种畸形文件撑爆内存
            if lineNo > maxLines { failure = .tooLarge(byteSize); stop = true; return }

            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { return }

            if let rest = keyword(line, "TITLE") {
                // 顺序不能反：先修剪空白，否则前导空格会让引号逃过修剪
                title = rest.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                sawKey = true
                return
            }
            if let rest = keyword(line, "LUT_3D_SIZE") {
                guard let n = Int(rest.trimmingCharacters(in: .whitespaces)) else {
                    failure = .missingSize; stop = true; return
                }
                dimension = n
                sawSize = true
                sawKey = true
                return
            }
            if keyword(line, "LUT_1D_SIZE") != nil {
                saw1D = true
                sawKey = true
                return
            }
            if let rest = keyword(line, "DOMAIN_MIN") {
                if let v = triple(rest) { domainMin = v }
                sawKey = true
                return
            }
            if let rest = keyword(line, "DOMAIN_MAX") {
                if let v = triple(rest) { domainMax = v }
                sawKey = true
                return
            }
            // 其它以 LUT_ 开头的已知关键字（输入范围 / 视频范围之类）直接忽略
            if line.uppercased().hasPrefix("LUT_") { sawKey = true; return }

            // 数据行
            let parts = line.split { $0 == " " || $0 == "\t" || $0 == "," }
            guard parts.count >= 3,
                  let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2]) else {
                failure = .badData(line: lineNo); stop = true; return
            }
            values.append(Float(r))
            values.append(Float(g))
            values.append(Float(b))
        }

        if let failure { throw failure }
        if !sawSize, saw1D { throw LUTParseError.only1D }
        if !sawSize, !sawKey { throw LUTParseError.notACube }
        if !sawSize { throw LUTParseError.missingSize }
        guard dimension >= 2, dimension <= maxDimension else {
            throw LUTParseError.unsupportedSize(dimension)
        }

        let expected = dimension * dimension * dimension
        let got = values.count / 3
        guard got == expected else {
            throw LUTParseError.wrongCount(expected: expected, got: got)
        }

        // 补 alpha=1.0。顺序保持文件原样 —— .cube 与 CIColorCube 都是 R 最快，
        // 不要"顺手"统一成别的顺序，那会把红蓝颠倒。
        var out = [Float]()
        out.reserveCapacity(expected * 4)
        for i in stride(from: 0, to: values.count, by: 3) {
            out.append(values[i])
            out.append(values[i + 1])
            out.append(values[i + 2])
            out.append(1.0)
        }
        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }

        let profile = makeProfile(
            data: data,
            dimension: dimension,
            domainMin: domainMin,
            domainMax: domainMax
        )

        return LUTCube(
            title: title,
            dimension: dimension,
            domainMin: domainMin,
            domainMax: domainMax,
            data: data,
            profile: profile
        )
    }

    // MARK: 恒等 LUT
    //
    // 两处用到：测试里做不变式验证；烘焙导出时作为"空调色"的起点。

    static func identityData(dimension n: Int) -> Data {
        var out = [Float]()
        out.reserveCapacity(n * n * n * 4)
        let d = Float(n - 1)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    out.append(Float(r) / d)
                    out.append(Float(g) / d)
                    out.append(Float(b) / d)
                    out.append(1.0)
                }
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// 把强度直接混进立方体数据里。
    ///
    /// 为什么这么做而不是再加一个混合滤镜：CIColorCube 做的是三线性插值，
    /// 对立方体取值是线性的。把每条表项按 (1−i)·输入 + i·输出 改一遍，
    /// 等价于对渲染结果做同样的线性混合，**而且完全精确**——
    /// 恒等立方体的三线性插值结果恰好就是输入值本身。
    /// 顺带的好处是烘焙导出天然就带上了强度，不用另写一套逻辑。
    func blended(intensity: Double) -> Data {
        let t = Float(min(max(intensity, 0), 1))
        guard t < 0.999 else { return data }

        let n = dimension
        let d = Float(n - 1)
        var out = [Float]()
        out.reserveCapacity(n * n * n * 4)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            for b in 0..<n {
                for g in 0..<n {
                    for r in 0..<n {
                        let i = ((b * n + g) * n + r) * 4
                        let ir = Float(r) / d, ig = Float(g) / d, ib = Float(b) / d
                        out.append(ir + (p[i] - ir) * t)
                        out.append(ig + (p[i + 1] - ig) * t)
                        out.append(ib + (p[i + 2] - ib) * t)
                        out.append(1.0)
                    }
                }
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: 小工具

    /// 取出中性灰轴（r=g=b）上每个格点的输出亮度
    func neutralAxis() -> [Double] {
        let n = dimension
        var axis: [Double] = []
        axis.reserveCapacity(n)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            for i in 0..<n {
                let idx = (((i * n) + i) * n + i) * 4
                let r = Double(p[idx]), g = Double(p[idx + 1]), b = Double(p[idx + 2])
                axis.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
            }
        }
        return axis
    }

    // MARK: 私有

    /// 匹配行首关键字，返回其后的内容（关键字必须是独立的词）
    private static func keyword(_ line: String, _ key: String) -> String? {
        let upper = line.uppercased()
        let target = key.uppercased()
        guard upper.hasPrefix(target) else { return nil }
        let rest = line.dropFirst(target.count)
        guard let first = rest.first, first == " " || first == "\t" else { return nil }
        return String(rest)
    }

    private static func triple(_ s: String) -> [Double]? {
        let parts = s.split { $0 == " " || $0 == "\t" }
        guard parts.count >= 3,
              let a = Double(parts[0]), let b = Double(parts[1]), let c = Double(parts[2]) else {
            return nil
        }
        return [a, b, c]
    }

    private static func makeProfile(
        data: Data,
        dimension n: Int,
        domainMin: [Double],
        domainMax: [Double]
    ) -> LUTProfile {
        var axis: [Double] = []
        axis.reserveCapacity(n)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            for i in 0..<n {
                let idx = (((i * n) + i) * n + i) * 4
                let r = Double(p[idx]), g = Double(p[idx + 1]), b = Double(p[idx + 2])
                axis.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
            }
        }

        let d = Double(n - 1)
        var floorAt = 1.0
        var ceilingAt = 1.0

        for i in 0..<n {
            let y = axis[i]
            if y > 0.05, floorAt >= 1.0 { floorAt = Double(i) / d }
            if y >= 0.95 { ceilingAt = Double(i) / d; break }
        }
        // 黑点被抬高（胶片褪色感）说明起点不是 0，floor 就是 0
        if axis.first.map({ $0 > 0.05 }) == true { floorAt = 0 }

        var maxDeviation = 0.0
        for i in 0..<n {
            maxDeviation = max(maxDeviation, abs(axis[i] - Double(i) / d))
        }
        let isNeutral = maxDeviation < 0.012

        let mid = axis[n / 2]
        let grayGain = mid / max(0.001, Double(n / 2) / d)

        let domainUsual = abs(domainMin[0]) < 0.001 && abs(domainMin[1]) < 0.001
            && abs(domainMin[2]) < 0.001
            && abs(domainMax[0] - 1) < 0.001 && abs(domainMax[1] - 1) < 0.001
            && abs(domainMax[2] - 1) < 0.001

        return LUTProfile(
            inputFloor: floorAt,
            inputCeiling: ceilingAt,
            isNeutral: isNeutral,
            grayGain: grayGain,
            unusualDomain: domainUsual ? nil : [domainMin[0], domainMax[0]]
        )
    }
}
