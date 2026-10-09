import Foundation

// MARK: - 档位尺的换算
//
// 这把尺子存在的唯一理由是**方向不能有歧义**。
//
// 改版前是一个普通滑杆：填充表示"质量数值 85%"，从左填了六成多；
// 而它下面那排档位是从左到右越来越压得狠。两句话说的是反的 ——
// 于是滑块越往右拖、画质反而越保真，手感完全是拧的。
//
// 现在两端表示同一个量：**左 = 更保真，右 = 更小**；
// 填充去掉，只留一条轨道、五个刻度和一个游标，刻度正对着档位标签。
//
// 换算**不是线性的**：按数值线性地画，档位标签就对不上刻度
// （0.72 这个"均衡"档在线性尺上会落到 40% 而不是正中间）。
// 所以这里按档位锚点做分段线性插值。

/// 画质数值 ↔ 尺子位置的双向换算。
///
/// 位置用 0…1 表示，**直接就是尺子宽度的比例** —— 不引入额外的内缩系数，
/// 免得"刻度画在 10%、标签中心在 10%、游标算出来在 11.6%" 这种对不齐。
enum StrengthScale {

    /// 第一个刻度的位置（尺子宽度的比例）
    static let firstTick: Double = 0.10

    /// 相邻两个刻度的间距
    static let tickStep: Double = 0.20

    /// 档位总数
    static var tickCount: Int { StrengthPreset.allCases.count }

    /// 第 `index` 个刻度在尺子上的位置（0 = 最左，1 = 最右）
    static func tickPosition(_ index: Int) -> Double {
        firstTick + Double(index) * tickStep
    }

    /// 锚点：把画质数值钉到尺子位置上。
    ///
    /// 五个档位各自钉在自己的刻度上；**两端再各留 8% 的行程**给范围外的取值
    /// （1.0 比"无损保真"还高，0.3 比"极致"还低）。
    /// 不留这段的话，游标拖到底只能到 0.95 / 0.38 ——
    /// 等于悄悄砍掉了两截可选范围，而用户看不出来。
    static let anchors: [(quality: Double, position: Double)] = {
        var list: [(quality: Double, position: Double)] = [
            (CompressSettings.qualityRange.upperBound, 0.02),
        ]
        for (index, preset) in StrengthPreset.allCases.enumerated() {
            list.append((preset.quality, tickPosition(index)))
        }
        list.append((CompressSettings.qualityRange.lowerBound, 0.98))
        // 按画质从高到低排 —— 位置随之从低到高，两列都单调
        return list.sorted { $0.quality > $1.quality }
    }()

    /// 画质 → 尺子位置
    static func position(for quality: Double) -> Double {
        let list = anchors
        guard let first = list.first, let last = list.last else { return 0 }
        if quality >= first.quality { return first.position }
        if quality <= last.quality { return last.position }

        for (a, b) in zip(list, list.dropFirst()) {
            guard quality <= a.quality, quality >= b.quality else { continue }
            let span = a.quality - b.quality
            guard span > 0 else { return a.position }
            let t = (a.quality - quality) / span
            return a.position + (b.position - a.position) * t
        }
        return last.position
    }

    /// 尺子位置 → 画质（拖动时用）
    static func quality(at position: Double) -> Double {
        let list = anchors
        guard let first = list.first, let last = list.last else {
            return StrengthPreset.high.quality
        }
        if position <= first.position { return first.quality }
        if position >= last.position { return last.quality }

        for (a, b) in zip(list, list.dropFirst()) {
            guard position >= a.position, position <= b.position else { continue }
            let span = b.position - a.position
            guard span > 0 else { return a.quality }
            let t = (position - a.position) / span
            return a.quality + (b.quality - a.quality) * t
        }
        return last.quality
    }

    /// 当前画质落在哪个刻度上（不在刻度上时给 nil）
    static func tickIndex(for quality: Double) -> Int? {
        StrengthPreset.allCases.firstIndex { abs($0.quality - quality) < 0.001 }
    }
}
