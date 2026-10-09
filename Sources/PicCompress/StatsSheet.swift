import SwiftUI
import AppKit

// MARK: - 压缩完成报告
//
// 这一屏回答三个问题，顺序就是它们的重要程度：
//
//   1. **省了多少**（这是用户按下去的理由）
//   2. **花了多久**（这是他下次要不要这么干的依据）
//   3. **有没有出岔子**（有多少张没成、为什么）
//
// 三条都必须是**实测值**。这里最容易走偏的是第 1 条：把失败、跳过、
// 已是最优的那些也算进"原始体积"，省下的百分比立刻好看一大截 ——
// 而那些图一个字节都没动过。所以尺寸那笔账只算真的变小了的那些，
// 没参与的张数在下面用一句话交代清楚（`isPartialMeasurement`），
// 不让"874 张"和那个百分比互相打架。

struct StatsSheet: View {

    @ObservedObject var model: AppModel
    /// 一份**快照**。跑完那一刻定下来，之后删几行列表也不影响它。
    let report: RunReport

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline

            VStack(alignment: .leading, spacing: 18) {
                if report.shrunkCount > 0 {
                    savedBlock
                } else {
                    nothingSaved
                }

                if !tiles.isEmpty {
                    tileGrid
                }

                if let note = caveat {
                    caveatRow(note)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)

            hairline
            footer
        }
        .frame(width: 480)
        // 和扫描报告一样：一张 sheet 就是一块浮起的玻璃板。
        .background(Theme.glass)
    }

    private var hairline: some View {
        Rectangle().fill(Theme.border).frame(height: 1)
    }

    // MARK: 标题

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(report.stoppedEarly ? "已停止" : "压缩完成")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 15)
    }

    /// 标题下面那行：这一批**是多大范围**的活儿。
    ///
    /// 只写张数，**不写用时、不写批数** —— 那两个数在下面第二排格子里
    /// 各有一个自己的卡片（「用时 2 分 14 秒」「分批 18 批」），
    /// 同一屏里出现两遍，用户会开始琢磨它们是不是同一个数。
    ///（"原始体积"从这一行挪走，也是同一个理由。）
    ///
    /// 计时和分批留在格子里而不是搬上来，是因为卡片里那行是 13pt 半粗、
    /// 还带一块底 —— 比 11pt 的 tertiary 小字**更显眼**，而不是更弱。
    private var subtitle: String {
        if report.stoppedEarly {
            return "处理了 \(Fmt.count(report.processed)) / \(Fmt.count(report.planned)) 张"
        }
        return "处理了 \(Fmt.count(report.processed)) 张"
    }

    // MARK: 省了多少

    private var savedBlock: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("共省下")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)

                Text(Fmt.size(report.savedBytes))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)

                Text("−\(report.savedPercent)%")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.good)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Capsule().fill(Theme.good.opacity(0.15)))

                Spacer(minLength: 0)
            }

            proportionBar

            // 两段各自标名字。上面那条 bar 是**按比例**画的，
            // 光看长度猜不出哪一段是哪一段 —— 把两个数字摆在同一行，
            // "留下 / 省掉"就没有第二种读法。
            HStack(spacing: 14) {
                legend(color: Theme.textSecondary, title: "留下 \(Fmt.size(report.outputBytes))")
                legend(color: Theme.good, title: "省掉 \(Fmt.size(report.savedBytes))")
                Spacer(minLength: 0)
                Text("原始 \(Fmt.size(report.originalBytes))")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }
        }
    }

    /// 一条按体积比例切开的 bar：左边是留下来的，右边是省掉的。
    private var proportionBar: some View {
        GeometryReader { geo in
            let kept = report.originalBytes > 0
                ? Double(report.outputBytes) / Double(report.originalBytes)
                : 1

            ZStack(alignment: .leading) {
                // 底：省掉的那一截
                Capsule().fill(Theme.good.opacity(0.30))
                // 上：留下来的那一截。用中性色而不是彩色 ——
                // 两段都上色的话，这条 bar 就成了"两个颜色哪个更重要"的问题。
                // 0.30 而不是 0.16：它要和图例里那颗同名的点看起来是**同一个颜色**，
                // 而 7pt 的小圆点在浅底上太浅就看不出是个点了。
                Capsule()
                    .fill(Theme.wash(0.30))
                    .frame(width: geo.size.width * CGFloat(min(max(kept, 0), 1)))
            }
        }
        .frame(height: 9)
    }

    private func legend(color: Color, title: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
        }
    }

    /// 一张都没压小的时候，不能摆一个「共省下 0 B」——
    /// 那读起来像失败，而实际情况多半是"这批图本来就已经是最优的"。
    private var nothingSaved: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("这批没有再压小的余地")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text(report.unchanged + report.grew >= report.processed
                 ? "它们本来就已经压得很到位了，原文件一个字节都没动。"
                 : "处理过的这些里没有一张能压得更小，原文件一个字节都没动。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 统计格

    /// 只摆**非零**的那些 —— 一排「失败 0 张」既占地方又让人紧张。
    ///
    /// 张数一律过 `Fmt.count`：这些值先拼成 `String` 再交给 `Text`，
    /// 走的是 verbatim 那条路，不会像字面量插值那样自动带千分位。
    private var tiles: [(title: String, value: String, tint: Color)] {
        var out: [(String, String, Color)] = []
        if report.compressed > 0 {
            out.append(("压缩", "\(Fmt.count(report.compressed)) 张", Theme.textPrimary))
        }
        if report.unchanged > 0 {
            out.append(("已是最优", "\(Fmt.count(report.unchanged)) 张", Theme.textSecondary))
        }
        if report.grew > 0 {
            out.append(("未缩小", "\(Fmt.count(report.grew)) 张", Theme.warn))
        }
        if report.skipped > 0 {
            out.append(("跳过", "\(Fmt.count(report.skipped)) 张", Theme.textSecondary))
        }
        if report.failed > 0 {
            out.append(("失败", "\(Fmt.count(report.failed)) 张", Theme.bad))
        }
        return out
    }

    private var tileGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                spacing: 8
            ) {
                ForEach(tiles, id: \.title) { tile in
                    tileView(tile.title, tile.value, tile.tint)
                }
            }

            // 用时那一行不给 it 自己的小节标题：它和上面那些格子说的是同一件事
            //（"这次干了什么"），多一个标题只是多一道需要读的横线。
            HStack(spacing: 8) {
                tileView("用时", Fmt.duration(report.duration), Theme.textPrimary)
                tileView("平均每张", Fmt.perImage(report.secondsPerImage), Theme.textPrimary)
                tileView("分批", report.batchSize > 0 ? "\(report.batchCount) 批" : "一次跑完",
                         Theme.textPrimary)
            }
        }
    }

    private func tileView(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Frost.radiusCard, style: .continuous)
                .fill(Theme.card)
                .shadow(color: Theme.shadow, radius: 9, y: 3)
        )
    }

    // MARK: 一句实话

    /// 这一屏唯一允许说"但是"的地方。
    ///
    /// 只写一条 —— 把四条注意事项堆在一起，用户一条都不会读，
    /// 而这里每一条都是他不该漏掉的。按严重程度排优先级。
    private var caveat: String? {
        if report.failed > 0 {
            return "有 \(Fmt.count(report.failed)) 张没能压成功，原因在列表里那一行上写着。"
        }
        if report.missedTarget > 0 {
            return "有 \(Fmt.count(report.missedTarget)) 张没能压到目标体积以内 —— 这几张本身能压的余地可能就这么大。"
        }
        if report.stoppedEarly {
            let left = max(0, report.planned - report.processed)
            return "你中途按了停止，还有 \(Fmt.count(left)) 张没处理。"
        }
        if report.isPartialMeasurement, report.shrunkCount > 0 {
            return "上面的百分比只算真的变小的那 \(Fmt.count(report.shrunkCount)) 张。"
        }
        return nil
    }

    private func caveatRow(_ text: String) -> some View {
        let severe = report.failed > 0
        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: severe ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(severe ? Theme.bad : Theme.warn)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Frost.radiusChip, style: .continuous)
                .fill(Theme.wash(0.05))
        )
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 11) {
            Spacer(minLength: 8)

            Button("好") { dismiss() }
                .buttonStyle(GhostButtonStyle())

            if let folder = outputFolder {
                Button {
                    NSWorkspace.shared.open(folder)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .bold))
                        Text("打开输出文件夹")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .help(folder.path)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 62)
    }

    /// 报告里"去哪儿看结果"。用的是跑完那一刻记下的那一格。
    private var outputFolder: URL? { report.outputFolder }
}
