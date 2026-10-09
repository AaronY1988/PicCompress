import SwiftUI
import AppKit

// MARK: - 品牌色（恒定）
//
// 这几个值**不随外观变**。原因有两层：
//
// 1. 界面里的 Logo 必须和程序坞 / 访达里的图标逐像素一致。图标是烘焙好的
//    位图，改不了外观；如果界面里的标识跟着外观漂移，那就成了两个东西。
// 2. 压在**照片上**的角标同理 —— 照片内容不可预测，深浅未知，
//    所以底衬恒为深色，配浅字最稳，不该跟着界面外观翻。

enum Brand {
    static let red     = Color(hex: 0xE4002B)
    /// 只在**标识**（`AppLogo`）里用，和 `Scripts/make-icon.swift` 里的三档一一对应。
    /// 这三个值不能单独改 —— 改了界面里的 Logo 就和程序坞图标不是同一个东西了。
    static let redSoft = Color(hex: 0xFF5468)
    static let redDeep = Color(hex: 0x52000F)
    static let arrow   = Color(hex: 0xDB0F35)

    // MARK: 填充渐变
    //
    // 上一版主按钮用的是「`redSoft` → `red` 的**对角**渐变」（左上角走到底右下角）。
    // 截图里量出来是 `#EB5F6A` → `#D43B3C` —— 两个毛病叠在一起：
    //
    // 1. **左端是个粉**。`#FF5468` 已经是"玫红"而不是"正红"了，大面积铺在按钮上，
    //    读起来像糖果包装，而不是一个沉稳的主操作。
    // 2. **对角方向**。斜着打光是最典型的"网页 2.0"配方，在 macOS 的界面语言里
    //    显得轻浮；系统自带的强调色按钮要么平涂、要么纵向微渐变压一档。
    //
    // 现在两端都在正红区间里，颜色更实；方向改成纵向（上亮下暗），
    // 表达的是"这是一块有厚度、被照亮的实体"，而不是"这里有一道光扫过去"。
    // 两端的色相几乎相同（都是 ~350°），所以中间不会经过任何一格粉。

    /// 渐变上端
    static let fillTop    = Color(hex: 0xE9102F)
    /// 渐变下端
    static let fillBottom = Color(hex: 0xBC0020)

    /// 填充用的纵向渐变。只在**填充**场合用（按钮、开关），别拿去当前景色。
    static let gradient = LinearGradient(
        colors: [fillTop, fillBottom],
        startPoint: .top,
        endPoint: .bottom
    )

    /// 填充面上那条一像素的内高光。
    ///
    /// 这是把"平涂色块"和"有厚度的按钮"分开的那一像素：没有它，深红会像一块贴纸；
    /// 有了它，顶部有一条被光扫到的边，底下自然就被读成暗面。
    /// 恒为白色低透明 —— 它压在品牌红上，和界面外观无关。
    static let fillHighlight = Color.white.opacity(0.22)
}

/// 压在照片上的角标。底衬恒深、字恒浅，两种外观下完全一致。
enum Chip {
    static let fill       = Color.black.opacity(0.55)
    static let text       = Color(hex: 0xF2F2F5)
    static let muted      = Color(hex: 0x9A9AA6)
    static let good       = Color(hex: 0x3DDC97)

    // 这里原本还有一个 `accent = #FF5468`（玫红），用在"调色后"这类角标上。
    // 它现在是死代码，删掉了 —— 留着的话，下一个要加角标的人会顺手挑它，
    // 于是"屏幕上唯一的红是主操作"这条规则又被悄悄破坏一次。
    // 角标要区分状态就两条路：`text`（醒目）/ `muted`（压暗），语义靠文字交代。

    /// 分割线手柄：白线 + 白圆点 + 深色箭头，压在照片上，同样恒定。
    static let handleLine = Color.white.opacity(0.9)
    static let handle     = Color.white
    static let handleMark = Color(hex: 0x1A1A20)

    /// 缩略图上的「选中」环。
    ///
    /// 和 `Theme.raised` 那套中性浮起面**不是一回事**：那些画在面板上，底色可控；
    /// 这个画在照片上，而照片可能是雪景也可能是夜景 —— 任何一个单一颜色都会在某类
    /// 照片上消失。所以这里和角标同理走恒定色：一条白环，外面垫一圈深色。
    /// 深色照片上白环显，浅色照片上那圈深色垫底把白环托出来。
    static let ring       = Color.white
    static let ringShadow = Color.black.opacity(0.55)
}

// MARK: - 配色（随外观自适应）

enum Theme {

    // MARK: 外观判定

    /// 这个 provider 会被每个动态色调用，所以判定逻辑只留这一份。
    ///
    /// 这里**刻意不对外暴露**「当前是不是深色」这种查询：一旦能查，就会有人
    /// 在视图里写 `if Theme.isDark { ... } else { ... }` 去手动分叉，
    /// 而那种分叉在切换外观时不一定跟着刷新（`body` 未必重算）。
    /// 颜色令牌自己会在绘制那一刻解析，永远是对的 —— 需要新颜色就加新令牌。
    private static func isDarkAppearance(_ appearance: NSAppearance?) -> Bool {
        guard let appearance else { return true }
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: 造色工具

    /// 造一个随外观切换的颜色。
    ///
    /// 用 `NSColor(name:dynamicProvider:)` 而不是「算成一个普通 `Color`」，这一点是整个
    /// 自适应方案的关键：动态色是在**绘制那一刻**按当时的 appearance 解析的，
    /// 所以外观一切换，连那些"body 没有被重新求值"的视图也会跟着换色。
    ///
    /// 换个做法（把颜色算成 `Color` 直接返回）就得让每个用到颜色的视图都订阅
    /// `colorScheme` 才能刷新 —— 那意味着 180 多处调用点全要改，而且漏一个就是一个
    /// 永远不会变色的死角。现在这样调用点一个字都不用动。
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: isDarkAppearance(appearance) ? dark : light)
        })
    }

    // MARK: 底色
    //
    // 暗色下这三层是**逐层变亮**的（window → panel → card），越靠前越远。
    // 亮色下白色是天花板，没法再往上加，所以反过来逐层变暗：
    // window 浅灰当画布、panel 接近白当工具条、card 纯白当卡片。
    // 观感上都是"卡片浮在画布上"，只是换了个方向。

    /// 最外层画布
    static var window: Color { Color(nsColor: windowNSColor) }

    /// 同一块底色，但以 `NSColor` 形式给出。
    ///
    /// 给 `NSWindow.backgroundColor` 用：那里**必须传入真正的动态 NSColor**。
    /// 走 `NSColor(Theme.window)` 这种"从 Color 转回去"的路子会在转换那一刻就把
    /// 颜色解析死，外观再变它也不会跟。
    static var windowNSColor: NSColor {
        NSColor(name: nil) { appearance in
            NSColor(hex: isDarkAppearance(appearance) ? 0x0B0D13 : 0xEFF3FA)
        }
    }
    /// 侧栏 / 底栏 / 工具面板。这是**不透明**的那一档（右栏玻璃板走 `Theme.glass`）。
    static var panel: Color { adaptive(0xF2F5FB, 0x1A1E26) }
    /// 列表行、卡片
    static var card: Color { adaptive(0xFFFFFF, 0x1E222A) }
    static var cardHover: Color { adaptive(0xF5F8FD, 0x262B35) }

    // MARK: 描边
    //
    // 线的观感不对称：深色线压在浅底上比浅色线压在深底上更显眼，
    // 所以亮色下的 alpha 略高一点，两边看起来才是同一个粗细。

    static var border: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            isDarkAppearance(appearance)
                ? NSColor(white: 1, alpha: 0.075)
                : NSColor(white: 0, alpha: 0.07)
        })
    }

    static var borderStrong: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            isDarkAppearance(appearance)
                ? NSColor(white: 1, alpha: 0.14)
                : NSColor(white: 0, alpha: 0.13)
        })
    }

    /// 虚线框专用（空态引导、导入条、拖入提示）。
    ///
    /// 为什么不复用 `borderStrong`：虚线是一串**很短的线段**，每一段都太短，
    /// 感知上比同 alpha 的实线弱一档。暗色下尤其明显 ——
    /// 0.13 的白压在大片 `#121216` 上，实测截图里只能隐约看见几个角。
    ///
    /// 单独开一个令牌，是为了让虚线变清楚这件事**不牵连**到同样在用
    /// `borderStrong` 的选中态（选中芯片、单选行、主控卡）——
    /// 那些地方现在的分量是对的，跟着一起加重就糊了。
    static var dashed: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            isDarkAppearance(appearance)
                ? NSColor(white: 1, alpha: 0.20)
                : NSColor(white: 0, alpha: 0.20)
        })
    }

    // MARK: 文字

    static var textPrimary: Color { adaptive(0x171A21, 0xEEF1F6) }
    static var textSecondary: Color { adaptive(0x6E7681, 0x98A0AC) }
    static var textTertiary: Color { adaptive(0x9AA2AE, 0x5F6875) }

    // MARK: 强调色

    /// 品牌红，**两种外观下同一个值**。
    ///
    /// 试过在亮色下压深一点换对比度，但 #E4002B 在纯白上本身就有 4.85:1，
    /// 过得了 AA；而"品牌红就是这一个红"比那 0.2 的对比度提升重要得多。
    static let accent = Brand.red

    // 这里原本还有一个 `accentSoft`（暗色 #FF5468 / 亮色 #D01A3C），
    // 给"用红当前景色"的场合。上一版用它做了好几处告警与角标，
    // 现在那些语义各自有了更准确的令牌（`warn` 是提醒、`bad` 是失败），
    // 它就空出来了。删掉的理由和 `Chip.accent` 一样：屏幕上每多一条能随便取的
    // 红色通道，"红只给主操作"就多一条被绕过的路。

    /// 主按钮的渐变。恒定，跟着品牌走。
    static let accentGradient = Brand.gradient

    // MARK: 浮起面
    //
    // 改版前「选中」是用品牌红填充表达的，屏幕上同时有六处红
    // （按画质 / 高质量胶囊 / 保持原格式 / 保留原格式 / 暗色选中 / 调色室）。
    // 六个红等于没有红 —— 「开始压缩」被自己人淹没了。
    //
    // 现在所有选中态一律走下面这两块中性色 + 字重加深：
    // 一样清楚，而且不抢主操作的颜色。

    /// 「选中」用的浮起面（分段控件里被选中的那一格、选中的胶囊）。
    ///
    /// 暗色下比卡片再亮一档；亮色下白是天花板，只能靠描边和轻投影区分 ——
    /// 所以用到它的地方**必须**同时给描边或投影，否则亮色下会看不出选中。
    static var raised: Color { adaptive(0xFFFFFF, 0x2A303B) }

    /// 主控卡片（比普通卡片再浮起一档）。
    ///
    /// 亮色下和普通卡片同为白色，靠更强的描边 + 投影取胜 ——
    /// 这是刻意的：亮色里没法靠"更白"表达层级，硬提亮只会得到一块更亮的白。
    static var cardRaised: Color { adaptive(0xFFFFFF, 0x252B34) }

    // MARK: 状态色

    static var good: Color { adaptive(0x0E8A58, 0x3DDC97) }
    static var warn: Color { adaptive(0xB26A00, 0xFFB020) }
    static var bad:  Color { adaptive(0xD3262F, 0xFF5C5C) }

    // MARK: 叠加层

    /// 面板上的半透明叠加层：分组底、按下态、选中态。
    ///
    /// 暗色下是白色低透明；亮色下必须换成黑色低透明 —— 在浅底上叠白等于什么都没画，
    /// 控件会成片消失。亮色系数压到 0.75：同样的 alpha，深色压在浅底上看起来更重，
    /// 减一点才和暗色的观感对齐。
    static func wash(_ amount: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            isDarkAppearance(appearance)
                ? NSColor(white: 1, alpha: amount)
                : NSColor(white: 0, alpha: amount * 0.75)
        })
    }

    /// 输入框那种**凹陷**的底。
    ///
    /// 和 `wash` 不是一回事：wash 是"浮起一层"，well 是"挖进去一块"。
    /// 暗色下靠加深实现，亮色下靠一层浅灰实现 —— 亮色下再加深就成了两块黑斑。
    static var well: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            isDarkAppearance(appearance)
                ? NSColor(white: 0, alpha: 0.32)
                : NSColor(white: 0, alpha: 0.045)
        })
    }

    /// 预览 / 对比画布上，照片背后的衬底。
    ///
    /// 取中性灰，不参与对照片本身色彩的判断。亮色下**必须比窗口底色再深一档**：
    /// 和窗口同色的话照片就只是"浮在界面上"，少了那块该有的舞台感
    /// （暗色下本来就是这个关系：衬底比窗口更深）。
    /// 另外也不能沿用「透明黑」那个写法 —— 那在浅底上会得到一片脏灰。
    static var backdrop: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            isDarkAppearance(appearance)
                ? NSColor(white: 0, alpha: 0.34)
                : NSColor(hex: 0xDFDFE6)
        })
    }

    /// 卡片上缘那道一像素高光。
    ///
    /// 暗色下卡片比底色亮一点，加这道高光才有"刻出来"的实体感；
    /// 亮色下卡片本来就是纯白，再叠一道白什么都不是 —— 所以那边直接给透明，
    /// 而不是给一个"看不出来但确实存在"的颜色。
    static var cardHighlight: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            isDarkAppearance(appearance)
                ? NSColor(white: 1, alpha: 0.06)
                : NSColor.clear
        })
    }

    /// 浮起的卡片 / 按钮投的阴影。亮色下要轻一些，否则会显脏。
    static var shadow: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(white: 0, alpha: isDarkAppearance(appearance) ? 0.46 : 0.10)
        })
    }
}

// MARK: - 霜白几何
//
// 这一版的视觉语言只有三条，改别处时要守住：
//
// 1. **冷调渐变画布是前提，不是装饰。** 蓝紫两处光斑是给玻璃板"可透的东西" ——
//    面板背后若是空的，玻璃就只是一块灰板子，浮不起来。
// 2. **所有浮层是同一块玻璃板**（右栏、sheet）：半透明冷调底 + 1px 白环 + 大柔影。
//    一张 sheet 就是一块浮起的板子 —— 这是"浮层"在这套语言里唯一的长相。
// 3. **行是独立卡片**，靠柔影和底色差分分层，**不靠描边**。
//
// 尺寸也收进下面这一个枚举：圆角只留三档，不再 6/8/11/14 混着用。

enum Frost {
    /// 列表行、卡片、分组卡
    static let radiusCard: CGFloat = 16
    /// 小控件：胶囊、档位片、输入框、缩略图
    static let radiusChip: CGFloat = 10
    /// 按钮、分段控件、提示框
    static let radiusButton: CGFloat = 13
    /// 右栏玻璃板
    static let radiusPanel: CGFloat = 20

    // sheet 的圆角（22）**不在这里**：五张 sheet 的圆角由系统给，
    // 代码里没有一处能设它。留一个用不上的令牌在这里，下一个人就会
    // 试着拿它去 clip 一张 sheet —— 那只会和系统的圆角打架。

    /// 按钮高度。比上一版（34）高一档 —— 和行高、留白一起构成"整体松一档"。
    static let buttonHeight: CGFloat = 38
    /// 卡片左右内边距
    static let padX: CGFloat = 18
    /// 行与行之间的间隙
    static let rowGap: CGFloat = 10
    /// 列表行高
    static let rowHeight: CGFloat = 72
    /// 缩略图边长
    static let thumb: CGFloat = 44
    /// 右栏总宽（含玻璃板外侧那圈边距）
    static let railWidth: CGFloat = 320
    /// 玻璃板离窗口边缘让出的边距
    static let railInset: CGFloat = 10
}

// MARK: - 霜白：画布与玻璃板
//
// 放在 `Theme` 的扩展里，是因为两个造色工具（`adaptive` / `isDarkAppearance`）是
// `private` 的 —— 同文件里的扩展照样能用，而且**不必把它们公开出去**。
// 公开了，就会有人在视图里查"当前是不是深色"再手动分叉（`Theme` 顶部那段注释
// 说的就是这个），颜色令牌自己会在绘制那一刻解析，永远是对的。

extension Theme {

    // MARK: 画布

    /// 画布底：一条纵向微渐变。方向不是正上正下（生成器里是 CSS 168°），
    /// 带一点点倾角 —— 完全垂直会显得板正得像张纸。
    static var canvasTop: Color { adaptive(0xFBFCFE, 0x0F1218) }
    static var canvasBottom: Color { adaptive(0xE3EBF8, 0x06070E) }

    /// 右上角那团蓝光。
    ///
    /// 亮暗两套**不是同一个值**：暗色下同样的浓度会显得脏，所以暗色调得更高更快
    /// （0.32 但收得更紧），紫光则降到 0.15 —— 0.22 在近黑底上是一片发灰的雾。
    static var canvasBlue: Color { spot(0x6894FF, 0.36, 0x466CFF, 0.32) }
    /// 左下角那团紫光
    static var canvasViolet: Color { spot(0xAA7CFF, 0.26, 0x844AFA, 0.15) }

    /// 带透明度的自适应色。`adaptive` 只吃不透明的十六进制，光斑和玻璃都要 alpha。
    private static func spot(_ light: UInt32, _ lightAlpha: Double,
                             _ dark: UInt32, _ darkAlpha: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            isDarkAppearance(appearance)
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        })
    }

    // MARK: 玻璃板

    /// 玻璃板的底。
    ///
    /// **必须带冷调 tint，不能是纯白** —— 板内的行卡片是纯白（`Theme.card`），
    /// 板要是也纯白，卡片就彻底不分层（实测第一版就是这样，扫描报告里那张
    /// 「按格式」卡贴在板上分不清）。分层靠的是"板比卡暗一点"，不是给卡加描边。
    /// 0.64 / 0.74 是**量出来的**：第一版写 0.70 / 0.78，出图一看右栏是一块
    /// 实心白板 —— 背后的蓝紫光斑一点没透上来，"浮起"就只剩一道边。
    /// 再透又会把板里的白卡片淹掉（板卡不分层），所以停在这里。
    static var glass: Color { spot(0xFCFDFF, 0.64, 0x1E232D, 0.74) }
    /// 玻璃板那一圈 1px 白环。亮色下是"玻璃的边缘"；暗色下压到 0.10，
    /// 再亮就成了一道描边，和"玻璃"这件事说不到一块去。
    static var glassRing: Color { spot(0xFFFFFF, 0.72, 0xFFFFFF, 0.10) }
    /// 玻璃板投下的大柔影 —— "浮起"这件事至少有八成靠它。
    static var glassShadow: Color { spot(0x1C2840, 0.22, 0x000000, 0.68) }
    /// 上缘那道内高光
    static var glassHighlight: Color { spot(0xFFFFFF, 0.95, 0xFFFFFF, 0.10) }
}

/// 霜白画布：整窗铺底。
///
/// 三层叠出来 —— 纵向微渐变打底，右上角一团蓝光、左下角一团紫光。
/// **这两团光是玻璃板能"浮起来"的前提**：面板背后若是空的，
/// 半透明底就只是块灰板子，模糊也没东西可透。
struct FrostCanvas: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.canvasTop, Theme.canvasBottom],
                startPoint: UnitPoint(x: 0.44, y: 0),
                endPoint: UnitPoint(x: 0.56, y: 1)
            )
            spot(Theme.canvasBlue, center: UnitPoint(x: 0.94, y: -0.08), radius: 780)
            spot(Theme.canvasViolet, center: UnitPoint(x: -0.10, y: 1.08), radius: 720)
        }
    }

    /// 光斑的衰减按生成器那边的口径：颜色在中心最浓，走到半径的 62% 就没了。
    /// 用 `stops` 而不是两个颜色 —— 后者会在整个半径上线性衰减，
    /// 光会散得比设计里大一圈，近黑底上就是一片看不见边的灰。
    private func spot(_ color: Color, center: UnitPoint, radius: CGFloat) -> some View {
        RadialGradient(
            stops: [
                .init(color: color, location: 0),
                .init(color: color.opacity(0), location: 0.62),
            ],
            center: center, startRadius: 0, endRadius: radius
        )
    }
}

/// 霜白里**所有浮层共用的这一块板**：右栏、sheet 都是它。
///
/// 三个部件缺一不可：半透明冷调底（可透）、1px 白环（边缘）、大柔影（浮起）。
/// 投影**只挂在底那块圆角矩形上**，不能挂在整块内容上 ——
/// 挂在内容上会把板里的每一个字也一起投影，字会糊成一团。
struct FrostPanel: ViewModifier {
    var radius: CGFloat = Frost.radiusPanel

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.glass)
                    // 柔影要够大够散。"浮起"这件事至少有八成靠它 ——
                    // 半径小了就只是卡片自己的边影，读不出"离画布有多高"。
                    .shadow(color: Theme.glassShadow, radius: 26, y: 16)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.glassRing, lineWidth: 1)
            }
            .overlay(alignment: .top) {
                // 只留顶上那一条。整圈内高光会让板子看着像被包了框。
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.glassHighlight, lineWidth: 1)
                    .mask(
                        LinearGradient(colors: [.black, .clear],
                                       startPoint: .top, endPoint: .center)
                    )
            }
    }
}

extension View {
    /// 把一块内容变成霜白的玻璃板。
    func frostPanel(_ radius: CGFloat = Frost.radiusPanel) -> some View {
        modifier(FrostPanel(radius: radius))
    }
}

// MARK: - 颜色构造

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension NSColor {
    /// 给动态色的 provider 用。
    ///
    /// 必须走 sRGB 显式转换，不能直接 `NSColor(red:green:blue:alpha:)` ——
    /// 那个初始化器读的是**设备**色域，在 P3 屏上会偏色。
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}

// MARK: - 按钮样式

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            // 主按钮**永远只占一行**。
            //
            // 它固定 34pt 高，而文案长起来（"连 iCloud 上的 8,745 张一起取"）
            // 会自己折成两行 —— 折出来的那两行塞在 34pt 里，按钮看着像被压扁了。
            // 实测截图里就出过这一下。宁可让它缩一点，也不要变形。
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(isEnabled ? Color.white : Theme.textTertiary)
            .padding(.horizontal, 18)
            .frame(height: Frost.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: Frost.radiusButton, style: .continuous)
                    // 不可用时**不是"淡一点的红"，而是根本不是红的**。
                    //
                    // 原来是 `accentGradient.opacity(0.35)`：亮色下白底透出粉红，
                    // 一眼看得出按不动；暗色下同样的 0.35 压出来的是一片**深红**，
                    // 和正常状态的深红几乎分不开 —— 一颗按下去没反应的按钮
                    // 在暗色下装得跟能用一样。这是实测截图里发现的。
                    //
                    // 而且"红 = 此刻该做的那件事"这条规矩本身也不该有例外：
                    // 一个做不了的动作不该占着这个颜色。
                    .fill(isEnabled ? AnyShapeStyle(Theme.accentGradient)
                                    : AnyShapeStyle(Theme.wash(0.07)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Frost.radiusButton, style: .continuous)
                    .strokeBorder(isEnabled ? Brand.fillHighlight : Theme.border, lineWidth: 1)
                    .mask(
                        // 只留上缘那一条 —— 整圈描边会让按钮看着像被包了框
                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
            )
            // 投影换成**中性**的。
            //
            // 上一版这里是 `Theme.accent.opacity(0.35), radius 12` —— 一圈红晕。
            // 放大看就是按钮周围糊着一层粉色雾，在浅色底上尤其脏（实测亮色截图里
            // 按钮下方那圈影子是 `#E7DCE0`，已经是灰粉色了）。
            // 而且"发光"这个手法本身在表达"这里是主操作"之外还多喊了一句，
            // 深红按钮自身的重量已经够了。
            // 投影仍然是**中性**的，不用红晕。
            //
            // 生成器里那颗按钮带的是一圈暗红投影（`rgba(150,0,26,0.28)`），
            // 但那是浏览器里的写法：实测在浅底上，同样的配方会糊出一圈
            // **灰粉色**的脏边（见 Theme 顶部 `Brand` 那段注释里记的那次）。
            // 深红按钮自身的重量已经够了，不需要靠发光再喊一句。
            .shadow(
                color: Theme.shadow.opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0),
                radius: configuration.isPressed ? 3 : 8,
                y: configuration.isPressed ? 1 : 4
            )
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14), value: isEnabled)
    }
}

struct GhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color = Theme.textSecondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(isEnabled ? tint : Theme.textTertiary.opacity(0.5))
            .padding(.horizontal, 15)
            .frame(height: Frost.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: Frost.radiusButton, style: .continuous)
                    .fill(Theme.wash(configuration.isPressed ? 0.12 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Frost.radiusButton, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - 设置分组卡片

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)

            content
        }
    }
}

// MARK: - 让窗口可以用背景拖动，并给 App 上外观

/// 界面外观必须**写到 `NSApp` 上**，不能只靠 `preferredColorScheme`，
/// 也不能写到窗口上。这两条都是实测出来的：
///
/// 1. `preferredColorScheme` 的 `nil` 语义是"这个视图没有偏好"，
///    SwiftUI 对它的实现是**不做任何事**。于是从暗色切回「跟随系统」时，
///    窗口会一直戴着上一次强制的暗色不摘 —— 用户看到的就是"点了没反应"。
/// 2. 那自己往 `NSWindow.appearance` 写行不行？也不行：SwiftUI 自己管着这个属性，
///    没有 `preferredColorScheme` 时它会**主动写 nil**。实测写进去的 `darkAqua`
///    立刻读回还是 `darkAqua`，但 50 毫秒后就变回"继承"了。跟框架抢同一个属性
///    是抢不赢的。
///
/// 而窗口外观为 nil 时的语义恰恰是"继承自 App"—— 所以把外观写在 `NSApp` 上，
/// 正好落在这条继承链的下游，SwiftUI 不会碰它，两个 sheet 作为子窗口也一并跟着。
///
/// 根子还在于这个设置是**应用级**的、还会被持久化：它本来就该由 App 拥有，
/// 借用视图层的"偏好"机制只是在将就。
struct WindowConfigurator: NSViewRepresentable {
    /// 当前设置。**作为属性传进来**（而不是让配置器自己去读单例）是关键：
    /// 值一变 SwiftUI 就会调 `updateNSView`，通路才能生效。
    var mode: AppearanceMode

    func makeNSView(context: Context) -> NSView {
        let view = AppearanceAwareView()
        view.mode = mode
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? AppearanceAwareView else { return }
        view.mode = mode
        view.apply()
    }
}

private final class AppearanceAwareView: NSView {
    var mode: AppearanceMode = .system

    /// 窗口的背景与标题栏属性只能在**已经进到窗口里**之后设，
    /// 所以放在这里而不是 `makeNSView` —— 那边返回时还没挂上去。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.isMovableByWindowBackground = true
        window.titlebarAppearsTransparent = true
        apply()
    }

    /// 系统外观变化时（比如傍晚自动转暗）要重新上一遍底色 ——
    /// 窗口底色是动态色，不主动重设的话那块区域会留着上一套配色。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    func apply() {
        // 只在真的变了才写：写 `appearance` 会触发 `viewDidChangeEffectiveAppearance`，
        // 无条件写就是自己触发自己。比较用名字而不是实例 ——
        // 每次 `NSAppearance(named:)` 未必返回同一个对象，用身份比较会误判成"变了"。
        let target = mode.nsAppearance
        if NSApp?.appearance?.name != target?.name {
            NSApp?.appearance = target
        }

        window?.backgroundColor = Theme.windowNSColor
    }
}
