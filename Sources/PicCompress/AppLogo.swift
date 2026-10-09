import SwiftUI

/// 品牌标识的**矢量版** —— 和程序坞 / 访达里那个 `.icns` 同源。
///
/// 构图逐项对齐 `Scripts/make-icon.swift` 的 e 系列：
/// **红色线条画框 + 框内一座双峰山 + 一枚太阳**，底板交给宿主
/// （窗口底色，或者图标那层中性底板）。
///
/// 上一版是"红底白图 + 压缩徽章"。换掉它不是配色问题 ——
/// 是它把四个元素塞进同一格：画框、山、太阳、压缩徽章。
/// 1024pt 上显得琐碎，缩到 22pt 又全糊成一团。现在只剩三笔，两端都成立。
/// （还有一层好处：底板撤掉之后，红的实色面积从 676pt² 降到约 150pt²，
/// 平级于标题，而不是压着标题。）
///
/// **界面里当前没有引用它。** 窗口里不放标识（Aaron 定的）—— 程序坞和 ⌘Tab
/// 已经在显示它了，窗口里再来一遍是冗余；顶栏自己后来也整条撤掉了。
/// 留着它的唯一理由是：品牌标识的矢量定义得有一处落点，
/// 而且要在这里写明它和 `.icns` 同源 —— 免得下次有人在视图里另画一个。
/// 界面里要放标识时（"关于"面板、欢迎页），用这个。
///
/// 比例：画框占画布 **62%**，和 `.icns` 一致。
/// **别拿旧顶栏那套比例来套** —— 那一版是给 22pt 用的，图符得占满 89%
/// 才立得住，两者不能互换。
struct AppLogo: View {
    var size: CGFloat = 64
    /// 线条色。默认品牌红，两种外观下同一个值。
    var color: Color = Brand.red

    var body: some View {
        Canvas { ctx, canvas in
            let s = min(canvas.width, canvas.height)

            // 画框
            let fSize = s * 0.620
            let lw = fSize * 0.070
            let ox = (s - fSize) / 2
            let frame = Path(
                roundedRect: CGRect(x: ox, y: ox, width: fSize, height: fSize),
                cornerRadius: fSize * 0.235,
                style: .continuous
            )
            ctx.stroke(frame, with: .color(color),
                       style: StrokeStyle(lineWidth: lw, lineJoin: .round))

            // 山和太阳排布在**框内有效区**（扣掉线宽和一圈呼吸），
            // 用的归一化坐标和 `.icns` 是同一组，y 向上 —— Canvas 是 y 向下，这里翻一次。
            let inset = lw / 2 + fSize * 0.034
            let inner = fSize - inset * 2
            let at = { (x: CGFloat, y: CGFloat) -> CGPoint in
                CGPoint(x: ox + inset + inner * x,
                        y: ox + inset + inner * (1 - y))
            }

            var mountain = Path()
            mountain.move(to: at(0.110, 0.200))   // 左脚
            mountain.addLine(to: at(0.395, 0.640))   // 左峰
            mountain.addLine(to: at(0.555, 0.435))   // 谷
            mountain.addLine(to: at(0.890, 0.700))   // 右峰（比左峰高一档，山才有前后）
            mountain.addLine(to: at(0.890, 0.200))   // 右脚
            mountain.closeSubpath()
            ctx.fill(mountain, with: .color(color))

            let sunR = inner * 0.070
            let sc = at(0.700, 0.760)
            ctx.fill(
                Path(ellipseIn: CGRect(x: sc.x - sunR, y: sc.y - sunR,
                                       width: sunR * 2, height: sunR * 2)),
                with: .color(color)
            )
        }
        .frame(width: size, height: size)
    }
}
