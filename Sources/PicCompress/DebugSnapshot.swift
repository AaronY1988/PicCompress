import SwiftUI
import AppKit

/// 仅用于开发期验证界面：通过环境变量触发，正常启动完全不受影响。
///
///   PICCOMPRESS_SNAPSHOT=/path/out.png   渲染窗口内容并退出
///   PICCOMPRESS_DEMO=/path/to/images     启动时先导入这些图片
///   PICCOMPRESS_RUN=1                    导入后自动跑一次压缩
///   PICCOMPRESS_DELAY=3                  截图前等待秒数
///   PICCOMPRESS_VIEW=compare             压完之后打开画质对比再截图
///   PICCOMPRESS_VIEW=grade               打开调色室再截图
///   PICCOMPRESS_LUT=/path/x.cube         截图前先挂上这条 LUT
///   PICCOMPRESS_LUT_INTENSITY=0.8        强度
///   PICCOMPRESS_LUT_SPACE=linear         工作色彩空间
///   PICCOMPRESS_EXPOSURE / _CONTRAST / _WARMTH / _SATURATION / _SHADOWS
///   PICCOMPRESS_GOAL=size|structure      截图前先把某组设置打开
///   PICCOMPRESS_FORMAT=avif              输出格式（keep/jpeg/heic/avif/png）
///   PICCOMPRESS_BATCH=50                 分批档位（配 PICCOMPRESS_RUN=1 真跑一遍，
///                                        验"报告里的批数 = 引擎真正走的段数"）
///   PICCOMPRESS_APPEARANCE=light|dark|system  指定界面外观（默认 dark，和以前一致）
///   PICCOMPRESS_APPEARANCE_SWITCH=system@1.5  窗口起来后再切一次外观（可带 @秒）
///   PICCOMPRESS_VIEW=scan                打开扫描报告再截图
///   PICCOMPRESS_DEMO=demo-scan           扫描报告要扫哪个目录（默认 demo-images）
///   PICCOMPRESS_SCAN_MB=1                扫描报告的体积阈值
///   PICCOMPRESS_SCAN_SOURCE=failed       摆"扫描失败"那一屏
///   PICCOMPRESS_VIEW=stats               摆"压缩完成"报告
///   PICCOMPRESS_STATS=full|stopped|failed|nothing|partial  报告的哪一种口径
///   PICCOMPRESS_REOPEN_TEST=1            自检"关窗后点程序坞图标能否恢复窗口"
// MARK: - 开发钩子的入口翻译

/// 给开发钩子喂 `PICCOMPRESS_*` 的两个入口。
///
/// **为什么需要这一层**：GUI 只能经 `open` 启动（直接跑二进制拿不到 GUI 会话 ——
/// 进程静默退出、日志为空、连崩溃报告都不留，看着像"启动就崩"，其实什么都没发生），
/// 而这条路上**三种传参方式实测全部失效**：
///   · `open --env KEY=V`   静默失效，应用一个都收不到（虽然 `open` 的帮助里写着支持）
///   · `launchctl setenv`   `Not privileged to set domain environment`
///   · `open APP --args …`  argv 也进不到 `main()`（连 `--cli` 都分流不过去）
/// 所以加一条不依赖任何传参通道的路：**读固定路径的配置文件**。
/// 底下所有钩子照旧读 `ProcessInfo.environment`，一行都不用改。
///
///   open -n dist/PicCompress.app        # 配合 /tmp/piccompress-dev.env
///
/// 文件里每行一个 `KEY=VALUE`，`#` 开头是注释。**只认 `PICCOMPRESS_` 前缀**，
/// 而且要求文件属于当前用户、且不是同组/其他人可写 —— 它在 /tmp 下，
/// 不加这道检查就等于让本机任何进程都能改这台机器的出图行为。
///
/// ## 这份文件是**一次性的**，用完即焚
///
/// 它是个固定路径，而 app 无法区分"谁启动的我" —— 出图脚本留下的文件，
/// 用户下一次**双击**打开时会照样生效。这条真的发生过：上一轮出完
/// `list-2000-dark`（带着 `PICCOMPRESS_DEMO=/tmp/pc-2000` 与
/// `PICCOMPRESS_SNAPSHOT=…`）之后文件留在原处，用户再打开软件看到的是
/// 2000 张测试数据，而且截完图就**自己退出**了，看着像"软件坏了"。
///
/// 所以两道闸：
///   1. **读完立刻删**（`consume`）—— 一次启动只吃一次，正常双击时文件根本不在。
///   2. **时效窗口** —— mtime 超过 `maxAge` 的不认，并顺手清掉。
///      兜住"写完文件但 app 没起来/起在半路被杀"那种残留。
enum DevEnvBridge {

    static let configPath = "/tmp/piccompress-dev.env"

    /// 这次启动是不是**开发钩子会话**。
    ///
    /// `install(from:)` 在两个入口任一命中时置上，之后全进程只读。
    /// 它是两处闸门的共同判据：
    ///   · `DebugSnapshot.schedule` —— 没钩子就一个字节都不动
    ///   · `SettingsStore` —— 设置只活在内存里，不落盘
    ///
    /// 用计算属性而不是 `static let`：`static let` 是首次访问时才求值，
    /// 而"首次访问"发生在哪个线程、在 `install` 之前还是之后都不确定。
    /// 这里每次读一次环境，一次字典查找，换掉一整类时序问题。
    static var isActive: Bool {
        ProcessInfo.processInfo.environment["PICCOMPRESS_DEV_SESSION"] == "1"
    }

    /// 过了这个岁数的配置一律不认。
    ///
    /// `devlaunch.sh` 是**写完立刻 `open`**，中间只有几百毫秒，
    /// 120 秒对正常出图宽松得不可能误伤；而它要拦的是"上次跑崩留下的残骸"
    /// —— 那种情况动辄几分钟几小时起步，隔着一条清晰的界线。
    static let maxAge: TimeInterval = 120

    /// 这次启动有没有任何钩子真的生效。
    ///
    /// 用来给整个会话打标（`PICCOMPRESS_DEV_SESSION`）—— 后续 `SettingsStore`
    /// 靠它决定"设置要不要落盘"。**必须等两个入口都试完再判定**：
    /// 只看配置文件会漏掉 argv 那条路，只看 argv 又漏掉本机唯一能用的那条。
    @discardableResult
    static func install(from args: [String]) -> Bool {
        let fromFile = applyConfigFile()
        let fromArgv = applyArgv(args)
        let active = fromFile || fromArgv
        if active { setenv("PICCOMPRESS_DEV_SESSION", "1", 1) }
        return active
    }

    @discardableResult
    private static func put(_ key: String, _ value: String) -> Bool {
        guard key.hasPrefix("PICCOMPRESS_") else { return false }
        setenv(key, value, 1)
        return true
    }

    /// `open APP --args --dev KEY=VALUE`。这条在本机不通，但别的机器上通，
    /// 留着不吃亏 —— 两个入口写的是同一个环境。
    @discardableResult
    private static func applyArgv(_ args: [String]) -> Bool {
        var applied = false
        var i = 0
        while i < args.count {
            guard args[i] == "--dev", i + 1 < args.count else { i += 1; continue }
            let pair = args[i + 1]
            if let eq = pair.firstIndex(of: "="), eq != pair.startIndex {
                applied = put(String(pair[..<eq]), String(pair[pair.index(after: eq)...])) || applied
            }
            i += 2
        }
        return applied
    }

    @discardableResult
    private static func applyConfigFile() -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: configPath) else { return false }

        // 属主必须是当前用户，且不能是同组/其他人可写。
        let owner = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777
        guard owner == getuid(), perms & 0o022 == 0 else { return false }

        // 不只是读，是**取走**：读得到内容之后立刻删。
        //
        // 顺序很重要 —— 先把内容拿到手，再删文件，最后才 setenv。
        // 反过来（先删再读）会有一个极窄的窗口让 `devlaunch.sh` 写完的
        // 新配置被这次启动吃掉又删掉，下一次启动就空手而归。
        let text = consume(fm, attrs: attrs)
        guard let text else { return false }

        var applied = false
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
            applied = put(String(line[..<eq]), String(line[line.index(after: eq)...])) || applied
        }
        return applied
    }

    /// 取出配置内容并删除文件。过期、读不出来都返回 nil，**但文件一律清掉** ——
    /// 留着它只会让下一次启动再判一次，迟早还会咬人。
    private static func consume(_ fm: FileManager, attrs: [FileAttributeKey: Any]) -> String? {
        let modified = attrs[.modificationDate] as? Date
        let expired = modified.map { Date().timeIntervalSince($0) > maxAge } ?? false

        defer { try? fm.removeItem(atPath: configPath) }

        guard !expired else {
            // 只留一行到 stderr。出图脚本靠 stdout 判读，不干扰。
            FileHandle.standardError.write(
                Data("[dev] 忽略过期的钩子配置（超过 \(Int(maxAge)) 秒），已清除\n".utf8))
            return nil
        }
        return try? String(contentsOfFile: configPath, encoding: .utf8)
    }
}

enum DebugSnapshot {

    @MainActor
    static func schedule(model: AppModel) {
        // ⚠️ 总闸：**没有开发钩子的正常启动，一个字节都不许动。**
        //
        // 这下面是"摆设置 / 导入测试数据 / 出图 / 真跑"，全部只为开发期服务。
        // 少了这道闸，它们会在**用户双击打开**时照样执行 —— 而其中几条
        // 用户的感受极其直接：
        //   · `model.settings.appearance = … ?? .dark`（无条件）→ 每次打开都是深色
        //   · `PICCOMPRESS_SNAPSHOT` 截完图 `NSApp.terminate` → 打开就自己退
        //   · `PICCOMPRESS_DEMO` → 界面里冒出几千张测试图
        // 三条都真的发生过。闸门的判据由 `DevEnvBridge` 在入口定，见 `isActive`。
        guard DevEnvBridge.isActive else { return }

        let env = ProcessInfo.processInfo.environment

        // 导入压力的度量。**放在 snapshot 那道 guard 前面** ——
        // 它要量的是"导入本身"，不出图，也不需要窗口稳定。
        if env["PICCOMPRESS_METRICS"]?.isEmpty == false {
            DevMetrics.start()
        }

        // ⚠️ 从这里往下一直到 DEMO 那一段是**摆设置 / 导入**，与出图无关。
        //
        // 它必须跑在 SNAPSHOT 那道 guard **之前**：度量钩子（`PICCOMPRESS_METRICS`）
        // 要量的正是"一次导入付多少代价"，它不出图，但同样依赖这些设置真的生效
        // （比如分批档位）。原来整段关在 guard 后面，于是度量跑出来是一条平线 ——
        // RSS 106MB、CPU 0%、一个里程碑都没有，看着像"几千张毫无压力"，
        // 真相是一张图都没进来。**量不出来和量出来是零，在图上长得一模一样。**
        //
        // 快照要可复现：默认先把上次记住的设置清掉
        if env["PICCOMPRESS_FRESH"] == "1" {
            SettingsStore.reset()
            model.settings = CompressSettings()
        }

        if let goal = env["PICCOMPRESS_GOAL"] {
            switch goal {
            case "size": model.settings.sizeGoal = .targetBytes
            case "structure": model.settings.preserveStructure = true
            case "quality": model.settings.sizeGoal = .quality
            default: break
            }
        }

        // 分批档位。这条走的是**真链路**：分批是"跑到批边界回来问一次"，
        // 而报告里那个「分批 N 批」是引擎自己数出来的段数 ——
        // 摆一份假报告验不到"两者是不是同一批人"，只有真跑一遍才知道。
        if let text = env["PICCOMPRESS_BATCH"], let value = Int(text) {
            model.settings.batchSize = value
        }

        // 输出格式。五档各有一句不同的说明（`FormatChoice.detail`），
        // 而那句说明是**按当前档位**渲染的 —— 不设它就只能看到默认那一句，
        // 另外四句在图上永远不出现。取值用 `rawValue`，和存档里那个值同一套词。
        if let name = env["PICCOMPRESS_FORMAT"] {
            if let choice = FormatChoice(rawValue: name) {
                model.settings.format = choice
            } else {
                print("   ! PICCOMPRESS_FORMAT=\(name) 不是合法档位，忽略了")
            }
        }

        // 想复现「无损保真档与调色互斥」那一屏时需要它
        if let text = env["PICCOMPRESS_QUALITY"], let value = Double(text) {
            model.settings.sizeGoal = .quality
            model.settings.quality = min(1, max(0.3, value))
        }

        // 指定外观。要放在 PICCOMPRESS_FRESH 之后 ——
        // FRESH 会把设置整个重置，先设了会被冲掉。
        //
        // 不指定时**显式取暗色**，而不是留着"跟随系统"：出图脚本不该因为
        // 当时系统是白天还是晚上而改变结果，那样两张截图就没法比了。
        model.settings.appearance = AppearanceMode(rawValue: env["PICCOMPRESS_APPEARANCE"] ?? "") ?? .dark

        // 再切一次外观，模拟"用户先选暗色、后来又点回跟随系统"。
        //
        // 只测首屏是不够的 —— 窗口建好时设一次外观谁都能对，
        // 真正会出问题的是**过渡**：从固定外观回到"跟随系统"时，
        // 那个"不干预"的语义能不能把窗口已经戴上的外观摘掉。
        // 这类 bug 只有真的切一次才看得见，所以单独留一个钩子。
        if let spec = env["PICCOMPRESS_APPEARANCE_SWITCH"] {
            let parts = spec.split(separator: "@")
            let mode = AppearanceMode(rawValue: String(parts[0]))
            let at = parts.count > 1 ? (Double(parts[1]) ?? 1.5) : 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                guard let mode else { return }
                print("[appearance] 切换到 \(mode.rawValue)")
                // 切完之后把外观实际落在哪打出来。
                //
                // 像素颜色只能说明"看起来变了"，这里能说明"机制上是谁在管" ——
                // 排查这类问题时两者都要。要看的是 **NSApp.effectiveAppearance**：
                // 窗口那一层是"继承"，本身不说明任何问题，而它继承的正是 App 这一层。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    let w = NSApp.windows.first { $0.isVisible && $0.contentView != nil }
                    print("[appearance] App 生效=\(NSApp.effectiveAppearance.name.rawValue) "
                          + "窗口=\(w?.appearance?.name.rawValue ?? "继承") "
                          + "窗口生效=\(w?.effectiveAppearance.name.rawValue ?? "?")")
                    fflush(stdout)
                }
                model.settings.appearance = mode
            }
        }

        applyGrade(from: env, to: model)

        if let demo = env["PICCOMPRESS_DEMO"] {
            model.add(urls: [URL(fileURLWithPath: demo)])
            // 让列表稳定下来，缩略图也加载完
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if env["PICCOMPRESS_RUN"] == "1" {
                    model.requestStart()
                }
            }
        }

        // ——— 到这里为止是"摆设置 / 导入"。再往下才是出图，需要 SNAPSHOT。 ———
        guard let snapshotPath = env["PICCOMPRESS_SNAPSHOT"] else { return }

        // 调色室：底图和每张 LUT 的缩略图都要现算，多等一下
        if env["PICCOMPRESS_VIEW"] == "grade" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                model.showingGradeStudio = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                capture(to: snapshotPath)
                model.showingGradeStudio = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    NSApp.terminate(nil)
                    exit(0)
                }
            }
            return
        }

        // 扫描报告：它装在 sheet 里，而 `capture` 会**优先抓 sheet**，弹出来就截得到。
        //
        // 阈值要在开扫**之前**设好：sheet 的 `onAppear` 会拿 `settings.scanMinBytes`
        // 去填输入框，设晚了就填成旧值，截出来的还是上一轮的图。
        if env["PICCOMPRESS_VIEW"] == "scan" {
            let demo = env["PICCOMPRESS_DEMO"] ?? "demo-images"
            let target = URL(
                fileURLWithPath: demo,
                relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            ).absoluteURL

            if let raw = env["PICCOMPRESS_SCAN_MB"], let mb = Double(raw) {
                model.settings.scanMinBytes = Int64(mb * 1024 * 1024)
            }

            // "扫描失败"那一屏直接**摆一个状态**上去，不去真造一个读不了的目录。
            //
            // 摆出来的好处是它验的正是要看的东西：字有没有写全、按钮在不在、
            // 亮暗两套下看不看得清 —— 而这些跟失败是真是假毫无关系。
            if env["PICCOMPRESS_SCAN_SOURCE"] == "failed" {
                model.scan = ScanState(
                    source: .folder(target),
                    phase: .failed("读不了这个文件夹：App 没有访问它的权限。"
                                   + "在「系统设置 → 隐私与安全性 → 文件与文件夹」里放开就行。")
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    capture(to: snapshotPath)
                    model.cancelScan()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        NSApp.terminate(nil)
                        exit(0)
                    }
                }
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                model.beginFolderScan(at: target)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                capture(to: snapshotPath)
                // 先收起 sheet 再退出，否则 modal 会把 terminate 卡住
                model.cancelScan()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    NSApp.terminate(nil)
                    exit(0)
                }
            }
            return
        }

        // 压缩完成报告。
        //
        // 报告的内容全是数字和文案，摆一份进去就够 —— 它要验的是**几种口径**
        //（全成功 / 中途停 / 有失败 / 一张都没压小 / 只有一部分图参与百分比）
        // 下说得对不对、排版挤不挤。这几条恰恰是"实话最容易写歪"的地方：
        // 数字凑得上、但话说得让人误解，只有把每一屏都摆出来看才发现得了。
        if env["PICCOMPRESS_VIEW"] == "stats" {
            // 主按钮得有个地方可去，否则那一屏会少一颗按钮、看不出真实版式
            model.settings.customFolderPath = "/tmp/pc-stats-out"
            model.runReport = Self.fakeReport(variant: env["PICCOMPRESS_STATS"] ?? "full")

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                capture(to: snapshotPath)
                model.runReport = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    NSApp.terminate(nil)
                    exit(0)
                }
            }
            return
        }

        let delay = Double(env["PICCOMPRESS_DELAY"] ?? "") ?? 3.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // 系统会记住上次的窗口大小，截图前统一成一个固定尺寸，保证可比
            if let size = env["PICCOMPRESS_WINDOW"] {
                let parts = size.split(separator: "x").compactMap { Double($0) }
                if parts.count == 2,
                   let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
                    window.setContentSize(NSSize(width: parts[0], height: parts[1]))
                }
            }

            if env["PICCOMPRESS_VIEW"] == "compare",
               // 挑最大的一张来对比，细节多的图才看得出分屏效果
               let item = model.items
                   .filter({ $0.outputURL != nil })
                   .max(by: { $0.originalBytes < $1.originalBytes }) {
                model.comparing = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    capture(to: snapshotPath)
                    // 先收起 sheet 再退出，否则 modal 会把 terminate 卡住
                    model.comparing = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        NSApp.terminate(nil)
                        exit(0)
                    }
                }
                return
            }
            capture(to: snapshotPath)
            // 压完报告是**弹着的 sheet**（这正是要验的东西），收走再退。
            // 直接 terminate 会让进程挂住 —— modal 会话没结束，terminate 排不上队，
            // 实测跑完图已经写出来了、进程却一直不退，只能靠外部 kill。
            model.runReport = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - 自检：关窗后点程序坞图标能否恢复

    @MainActor private static var reopenTestScheduled = false

    @MainActor
    static func scheduleReopenTest() {
        guard !reopenTestScheduled,
              let mode = ProcessInfo.processInfo.environment["PICCOMPRESS_REOPEN_TEST"]
        else { return }
        reopenTestScheduled = true

        func log(_ s: String) {
            print(s)
            fflush(stdout)
        }

        func visibleCount() -> Int {
            NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && $0.contentView != nil }.count
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            log("[reopen] step1 关闭前可见窗口 = \(visibleCount())")
            NSApp.windows
                .filter { $0.isVisible && $0.canBecomeMain && $0.contentView != nil }
                .forEach { $0.close() }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let afterClose = visibleCount()
                log("[reopen] step2 关闭后可见窗口 = \(afterClose)（现存窗口对象 \(NSApp.windows.count) 个）")

                // wait 模式：不自己触发，等外部 `open` 送进来真实的 reopen 事件
                if mode == "wait" {
                    log("[reopen] 已关窗，等待系统 reopen 事件（等同于点程序坞图标）…")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        let n = visibleCount()
                        log("[reopen] step3 事件触发后可见窗口 = \(n)")
                        log("[reopen] \(n > 0 ? "PASS ✓" : "FAIL ✗")")
                        NSApp.terminate(nil)
                    }
                    return
                }

                // 模拟用户点程序坞图标：系统会调这个方法
                let handled = NSApp.delegate?.applicationShouldHandleReopen?(
                    NSApp, hasVisibleWindows: afterClose > 0
                )

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let afterReopen = visibleCount()
                    log("[reopen] step3 触发 reopen 后可见窗口 = \(afterReopen)")
                    log("[reopen] handled=\(handled.map { String($0) } ?? "nil")")
                    log("[reopen] \(afterReopen > 0 ? "PASS ✓" : "FAIL ✗")")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// 出图用的假报告。数字都挑成"像真的"，因为要验的正是数字挨在一起时
    /// 那一屏读起来对不对 —— 摆一堆 1 和 0 是验不出这件事的。
    private static func fakeReport(variant: String) -> RunReport {
        let finished = Date()
        // 2 分 14 秒，正好跨过"分"这道坎
        let started = finished.addingTimeInterval(-134)

        func make(
            planned: Int, processed: Int,
            compressed: Int, unchanged: Int, grew: Int, skipped: Int, failed: Int, missed: Int,
            original: Int, output: Int, shrunk: Int,
            batchSize: Int, batches: Int, stopped: Bool
        ) -> RunReport {
            RunReport(
                startedAt: started, finishedAt: finished,
                planned: planned, processed: processed,
                compressed: compressed, unchanged: unchanged, grew: grew,
                skipped: skipped, failed: failed, missedTarget: missed,
                originalBytes: original, outputBytes: output, shrunkCount: shrunk,
                batchSize: batchSize, batchCount: batches, stoppedEarly: stopped,
                outputFolderPath: "/tmp/pc-stats-out"
            )
        }

        switch variant {
        case "stopped":
            return make(planned: 874, processed: 350,
                        compressed: 342, unchanged: 6, grew: 0, skipped: 2, failed: 0, missed: 0,
                        original: 18_240_000_000, output: 6_880_000_000, shrunk: 342,
                        batchSize: 50, batches: 18, stopped: true)

        case "failed":
            return make(planned: 874, processed: 874,
                        compressed: 870, unchanged: 2, grew: 0, skipped: 0, failed: 2, missed: 0,
                        original: 44_700_000_000, output: 16_500_000_000, shrunk: 870,
                        batchSize: 0, batches: 1, stopped: false)

        case "nothing":
            return make(planned: 260, processed: 260,
                        compressed: 0, unchanged: 254, grew: 6, skipped: 0, failed: 0, missed: 0,
                        original: 0, output: 0, shrunk: 0,
                        batchSize: 0, batches: 1, stopped: false)

        case "partial":
            return make(planned: 874, processed: 874,
                        compressed: 500, unchanged: 300, grew: 0, skipped: 74, failed: 0, missed: 0,
                        original: 30_100_000_000, output: 12_040_000_000, shrunk: 500,
                        batchSize: 100, batches: 9, stopped: false)

        default:   // full
            return make(planned: 874, processed: 874,
                        compressed: 862, unchanged: 8, grew: 0, skipped: 4, failed: 0, missed: 3,
                        original: 44_700_000_000, output: 16_540_000_000, shrunk: 862,
                        batchSize: 50, batches: 18, stopped: false)
        }
    }

    /// 出调色室截图前把参数摆好。和项目里别的开发期钩子一样，只走环境变量
    @MainActor
    private static func applyGrade(from env: [String: String], to model: AppModel) {
        if let lut = env["PICCOMPRESS_LUT"] {
            model.settings.grade.lutPath = (lut as NSString).expandingTildeInPath
        }
        if let text = env["PICCOMPRESS_LUT_INTENSITY"], let value = Double(text) {
            model.settings.grade.intensity = value > 1 ? value / 100 : value
        }
        if let text = env["PICCOMPRESS_LUT_SPACE"],
           let space = LUTWorkingSpace(rawValue: text) {
            model.settings.grade.workingSpace = space
        }
        let knobs: [(String, WritableKeyPath<LUTGrade, Double>)] = [
            ("PICCOMPRESS_EXPOSURE", \.exposure),
            ("PICCOMPRESS_CONTRAST", \.contrast),
            ("PICCOMPRESS_WARMTH", \.warmth),
            ("PICCOMPRESS_SATURATION", \.saturation),
            ("PICCOMPRESS_SHADOWS", \.shadows),
        ]
        for (key, path) in knobs {
            if let text = env[key], let value = Double(text) {
                model.settings.grade[keyPath: path] = value
            }
        }
        model.settings.grade = model.settings.grade.sanitized()
    }

    private static func capture(to path: String) {
        // 弹出 sheet 时要截 sheet，它才是当前视觉重点
        guard let window = NSApp.windows.first(where: { $0.isSheet && $0.isVisible })
                ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView
        else {
            FileHandle.standardError.write(Data("snapshot: no window\n".utf8))
            return
        }

        // 先把窗口立成 key、把应用提到前台，再渲染。
        //
        // 这一步不是"为了好看"：窗口不 key 的时候，**AppKit 画的控件会走非激活外观** ——
        // 滑杆、开关、滚动条都会换成一套更暗更灰的画法，而那套画法真实用户几乎看不到
        //（他一点窗口就激活了）。之前有一版亮色截图里滑杆的填充段是近黑的 #2B2B34，
        // 我照着它去找配色的问题，其实压根不是配色 —— 是没把窗口立起来。
        //
        // 换句话说：不修这里，截出来的图就**不是用户看到的样子**，
        // 后面每一轮"看图验收"都在验错的东西。
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 但 `activate` 是**异步**的：调完就立刻 cacheDisplay，应用还没有真正 active，
        // 控件依旧按"非激活"画。所以还要在这里等它落地 ——
        // 实测差别很大：亮色下滑杆填充段在"未激活"下是 #DCDCDE，跟轨道 #E8E8E9
        // 只差 12 级，等于看不见；真正激活之后才是该有的那道实心灰。
        //
        // 只等这一个条件，且有上限（1.5s）。正常情况下不到 0.3s 就满足了。
        let deadline = Date().addingTimeInterval(1.5)
        while !NSApp.isActive, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        window.displayIfNeeded()

        // ⚠️ 已知失真：**滑杆（`Slider`）的填充段在截图里不可信。**
        //
        // 实测：把 `.tint` 设成纯静态的 `Brand.red`，抓出来仍然是 #DCDCDE 的浅灰 ——
        // 也就是说那一截根本不经 `cacheDisplay`，tint 是什么颜色都抓不到。
        // 非激活状态下它倒是会变（一版截出过 #2B2B34 近黑），于是很容易
        // 误判成"亮色下滑杆配色错了"，然后照着一张假的图去调真代码。
        //
        // 这里踩过一次，所以写下来：**验滑杆颜色不要看这张图**，
        // 要么在真机上肉眼确认，要么换一条截图路径（`screencapture` 走的是
        // 合成后的窗口，能拿到真实内容）。其它 SwiftUI 画出来的东西
        //（卡片、文字、描边、圆角）都准 —— 实测底色和令牌逐位相同。
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        // 必须在视图**自己的**外观下渲染。
        //
        // 动态色是在绘制那一刻按 `NSAppearance.currentDrawingAppearance` 解析的，
        // 而 `cacheDisplay` 不保证会把它设成这个视图的 effectiveAppearance ——
        // 不显式指定的话，切到亮色也会渲出一张暗色图，而且看起来"像那么回事"，
        // 非常容易把自适应这件事误判成没生效。
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: bounds, to: rep)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
