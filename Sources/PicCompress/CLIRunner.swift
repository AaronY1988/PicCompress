import Foundation

/// 无界面的命令行模式。
///
/// 访达的右键快速操作、以及你想写脚本批处理时，都是跑这个入口：
///     PicCompress --cli ~/Pictures/DSC_0001.jpg
///     PicCompress --cli --remembered ~/Pictures/旅行
/// 它和界面走的是同一套压缩引擎，参数含义也一一对应。
enum CLIRunner {

    static var isCLI: Bool {
        CommandLine.arguments.dropFirst().contains("--cli")
    }

    // MARK: 入口

    static func run() -> Int32 {
        let raw = Array(CommandLine.arguments.dropFirst())

        // --remembered：沿用界面上最后一次用的设置
        var settings = raw.contains("--remembered") ? SettingsStore.load() : CompressSettings()
        if !raw.contains("--remembered") { settings.outputMode = .siblingFolder }

        var paths: [String] = []
        var quiet = false
        var index = 0
        /// 只烘焙 .cube 不压缩
        var bakePath: String?
        /// 只导出调色后的图片不压缩
        var exportPath: String?

        func next() -> String? {
            index += 1
            return index < raw.count ? raw[index] : nil
        }

        while index < raw.count {
            let argument = raw[index]
            switch argument {
            case "--cli", "--remembered":
                break

            case "--help", "-h":
                printUsage()
                return 0

            case "--quiet", "-q":
                quiet = true

            case "--level":
                guard let value = next(), let preset = preset(named: value) else {
                    return fail("--level 需要一个档位：pristine / high / balanced / small / extreme")
                }
                settings.sizeGoal = .quality
                settings.quality = preset.quality

            case "--quality":
                guard let value = next(), let quality = Double(value),
                      quality >= 0.3, quality <= 1 else {
                    return fail("--quality 需要 0.3 ~ 1.0 之间的数值")
                }
                settings.sizeGoal = .quality
                settings.quality = quality

            case "--target":
                guard let value = next(), let bytes = TargetSize.parse(value) else {
                    return fail("--target 需要形如 500KB / 1.5MB 的数值")
                }
                settings.sizeGoal = .targetBytes
                settings.targetBytes = bytes

            case "--format":
                guard let value = next(), let choice = format(named: value) else {
                    return fail("--format 只支持 keep / jpeg / heic / avif / png")
                }
                settings.format = choice

            case "--max":
                guard let value = next(), let pixels = Int(value), pixels >= 0 else {
                    return fail("--max 需要像素数，0 表示不限制")
                }
                settings.maxDimension = pixels

            case "--dest":
                guard let value = next() else { return fail("--dest 需要一个目录") }
                settings.outputMode = .customFolder
                settings.customFolder = URL(
                    fileURLWithPath: (value as NSString).expandingTildeInPath
                )

            case "--suffix":
                settings.outputMode = .suffix

            case "--in-place", "--overwrite":
                settings.outputMode = .overwrite

            case "--structure":
                settings.preserveStructure = true

            case "--flat":
                settings.preserveStructure = false

            case "--keep-originals":
                // 访达右键用：万一"上次设置"是替换原图，也降级成另存，
                // 右键就把原图改了太容易出事
                if settings.outputMode == .overwrite {
                    settings.outputMode = .siblingFolder
                }

            case "--no-metadata":
                settings.keepMetadata = false

            case "--fresh-timestamps":
                settings.keepTimestamps = false

            // MARK: 调色
            //
            // 命令行这一侧和界面用的是同一个 effectiveGrade，语义完全一致。

            case "--lut":
                guard let value = next() else { return fail("--lut 需要一个 .cube 路径") }
                let url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return fail("找不到 LUT：\(url.path)")
                }
                do {
                    _ = try LUTCube.load(url: url)
                } catch {
                    let why = (error as? LUTParseError)?.errorDescription
                        ?? error.localizedDescription
                    return fail("这份 .cube 用不了：\(why)")
                }
                settings.grade.lutPath = url.path

            case "--lut-intensity":
                guard let value = next(), let raw = Double(value), raw >= 0 else {
                    return fail("--lut-intensity 需要 0 ~ 1（或 0 ~ 100 当百分比）")
                }
                // 80 和 0.8 都认：写脚本的人两种都会顺手打出来
                let normalized = raw > 1 ? raw / 100 : raw
                guard normalized <= 1 else { return fail("--lut-intensity 不能超过 100%") }
                settings.grade.intensity = normalized

            case "--lut-space":
                guard let value = next(), let space = workingSpace(named: value) else {
                    return fail("--lut-space 只支持 srgb / linear / rec709")
                }
                settings.grade.workingSpace = space

            case "--exposure":
                guard let value = next(), let v = Double(value) else {
                    return fail("--exposure 需要一个数值（EV，建议 -2 ~ 2）")
                }
                settings.grade.exposure = v

            case "--contrast":
                guard let value = next(), let v = Double(value) else {
                    return fail("--contrast 需要一个数值（1 为不变）")
                }
                settings.grade.contrast = v

            case "--warmth":
                guard let value = next(), let v = Double(value) else {
                    return fail("--warmth 需要一个数值（-1 冷 ~ 1 暖）")
                }
                settings.grade.warmth = v

            case "--saturation":
                guard let value = next(), let v = Double(value) else {
                    return fail("--saturation 需要一个数值（1 为不变，0 为去色）")
                }
                settings.grade.saturation = v

            case "--shadows":
                guard let value = next(), let v = Double(value) else {
                    return fail("--shadows 需要一个数值（-1 ~ 1）")
                }
                settings.grade.shadows = v

            case "--reset-grade":
                settings.grade = LUTGrade()

            case "--bake-cube":
                guard let value = next() else { return fail("--bake-cube 需要一个输出路径") }
                bakePath = value

            case "--export-graded":
                guard let value = next() else { return fail("--export-graded 需要一个输出路径") }
                exportPath = value

            default:
                if argument.hasPrefix("-") {
                    return fail("不认识的参数：\(argument)（--help 看用法）")
                }
                paths.append(argument)
            }
            index += 1
        }

        // 每个旋钮都夹回合法区间，别让脚本传进来的离谱数字漏到引擎里
        settings.grade = settings.grade.sanitized()

        // 「无损保真」承诺像素不变，和调色天然互斥。
        // 命令行这边不能像界面那样"灰掉并说明"，只能明确报错 ——
        // 悄悄不生效会让脚本作者以为调色成功了，那是最糟的失败方式。
        if settings.gradeBlockedByPristine {
            return fail("--level pristine 和调色互斥：无损保真档承诺像素不变。"
                        + "要调色请换成 --level high（或更低）。")
        }

        // 只烘焙：不需要输入图片，直接出 .cube
        if let bakePath {
            let destination = URL(
                fileURLWithPath: (bakePath as NSString).expandingTildeInPath
            )
            do {
                let text = try LUTEngine.bake(grade: settings.effectiveGrade)
                try Data(text.utf8).write(to: destination, options: .atomic)
                print("已导出 .cube（33³）→ \(destination.path)")
                return 0
            } catch {
                return fail("烘焙失败：\(error.localizedDescription)")
            }
        }

        guard !paths.isEmpty else {
            printUsage()
            return 1
        }

        // 只导出调色后的图片：拿第一个路径当源图，不跑批量压缩
        if let exportPath {
            let source = URL(
                fileURLWithPath: (paths[0] as NSString).expandingTildeInPath
            )
            let destination = URL(
                fileURLWithPath: (exportPath as NSString).expandingTildeInPath
            )
            do {
                try ImageCompressor.exportGraded(
                    source: source, grade: settings.effectiveGrade, to: destination
                )
                print("已导出调色后的图片 → \(destination.path)")
                return 0
            } catch {
                return fail("导出失败：\(error.localizedDescription)")
            }
        }

        var jobs: [CompressJob] = []
        for path in paths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            jobs.append(contentsOf: ImageScanner.jobs(from: url))
        }
        guard !jobs.isEmpty else {
            return fail("这些路径里没有能处理的图片")
        }

        return execute(jobs: jobs, settings: settings, quiet: quiet)
    }

    // MARK: 执行

    private static func execute(
        jobs: [CompressJob],
        settings: CompressSettings,
        quiet: Bool
    ) -> Int32 {
        let box = SummaryBox()
        let reserver = PathReserver()
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            await BatchRunner.run(
                jobs: jobs,
                settings: settings,
                reserver: reserver,
                onFinish: { index, result in
                    box.record(jobs[index], result)
                    guard !quiet else { return }
                    if case .success(let outcome) = result, !outcome.noChange {
                        print("   \(jobs[index].url.lastPathComponent)  "
                              + "\(Fmt.compact(outcome.originalBytes)) → \(Fmt.compact(outcome.outputBytes))  "
                              + "−\(outcome.savedPercent)%")
                    }
                }
            )
            semaphore.signal()
        }

        semaphore.wait()

        let summary = box.value
        if !quiet { print("") }
        print(summary.text())

        if !quiet, let folder = summary.firstOutputFolder {
            print("输出目录：\(folder.path)")
        }
        return summary.failed > 0 ? 1 : 0
    }

    // MARK: 参数解析辅助

    private static func preset(named name: String) -> StrengthPreset? {
        switch name.lowercased() {
        case "pristine", "lossless": return .pristine
        case "high": return .high
        case "balanced": return .balanced
        case "small": return .small
        case "extreme": return .extreme
        default: return nil
        }
    }

    private static func format(named name: String) -> FormatChoice? {
        switch name.lowercased() {
        case "keep", "same": return .keep
        case "jpeg", "jpg": return .jpeg
        case "heic", "heif": return .heic
        case "avif": return .avif
        case "png": return .png
        default: return nil
        }
    }

    private static func workingSpace(named name: String) -> LUTWorkingSpace? {
        switch name.lowercased().replacingOccurrences(of: ".", with: "") {
        case "srgb", "rec709srgb": return .sRGB
        case "linear", "linearsrgb", "lin": return .linear
        case "rec709", "bt709", "709": return .rec709
        default: return nil
        }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        return 1
    }

    private static func printUsage() {
        print("""
        图片压缩 · 命令行模式

        用法：PicCompress --cli [选项] <图片或文件夹> ...

        压缩目标
          --level <档位>       pristine / high / balanced / small / extreme
          --quality <0.3-1.0>  直接指定质量
          --target <体积>      压到指定体积以内，如 500KB、1.2MB

        输出
          --dest <目录>        输出到指定文件夹（默认：图片旁的 Compressed）
          --suffix             原目录生成 xxx_compressed 副本
          --in-place           直接替换原图（只有确实变小才替换）
          --structure          保留原始子目录结构
          --flat               打平到一层（默认）
          --keep-originals     绝不替换原图（右键快速操作用）
          --format <格式>      keep / jpeg / heic / avif / png
          --max <像素>         限制最长边，0 表示不限制

        其它
          --no-metadata        不保留相机/GPS 等拍摄信息
          --fresh-timestamps   覆盖后不沿用原文件时间
          --remembered         沿用 App 里最后一次用的设置
          -q, --quiet          只输出汇总
          -h, --help           显示这份说明

        调色（默认关闭；挂上之后压缩结果会一并调色）
          --lut <文件>         用哪条 .cube
          --lut-intensity <值> 强度 0~1，或直接写 0~100 当百分比
          --lut-space <空间>   srgb / linear / rec709（网上下载的基本都是 srgb）
          --exposure <EV>      曝光，-2 ~ 2
          --contrast <值>      对比，1 为不变
          --warmth <值>        色温，-1 冷 ~ 1 暖
          --saturation <值>    饱和，1 为不变，0 为去色
          --shadows <值>       暗部，-1 ~ 1
          --reset-grade        清掉所有调色参数

        只做一件事（不跑批量压缩）
          --export-graded <文件>  把第一张输入图的调色结果全尺寸导出
          --bake-cube <文件>      把当前调色参数烘焙成 33³ 的 .cube
        """)
    }
}

/// 命令行模式下汇总多个线程回传的结果
private final class SummaryBox: @unchecked Sendable {
    private var storage = BatchSummary()
    private let lock = NSLock()

    var value: BatchSummary {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ job: CompressJob, _ result: Result<CompressOutcome, Error>) {
        lock.lock()
        defer { lock.unlock() }
        storage.record(job, result)
    }
}
