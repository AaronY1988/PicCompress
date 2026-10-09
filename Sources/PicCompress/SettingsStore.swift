import Foundation

/// 记住上次用的设置。
///
/// 存在 UserDefaults 里，键名带命名空间，避免和别的 App 撞。
/// 读不出来（首次启动 / 版本升级结构变了）就回落到默认值，不抛错。
enum SettingsStore {

    private static let key = "piccompress.settings.v1"

    /// 这次启动是**开发钩子会话**（由 `DevEnvBridge` 置上），设置只活在内存里。
    ///
    /// 为什么必须有这道闸：出图脚本会摆一堆状态（`PICCOMPRESS_FRESH=1` 清设置、
    /// `PICCOMPRESS_APPEARANCE=dark` 定外观、`PICCOMPRESS_BATCH=200` 定分批），
    /// 而这些改动会经 `$settings` 那道 300ms 防抖**写回磁盘**。
    /// 于是用户下次正常打开软件，看到的是上一次出图摆过的状态 ——
    /// 外观变成深色、分批变成每批 200 张，而他从没改过这些。
    ///
    /// 更糟的是 `reset()`：`FRESH` 会真的把磁盘上那个键删掉，
    /// 用户攒下来的偏好就此蒸发。
    ///
    /// 所以 dev 会话下：**读走默认值、写不落盘、重置不删**。
    /// 三个一起才叫"只活在内存里"，漏一个都会漏到用户那边去。
    private static let isDevSession =
        ProcessInfo.processInfo.environment["PICCOMPRESS_DEV_SESSION"] == "1"

    static func load(defaults: UserDefaults = .standard) -> CompressSettings {
        if isDevSession { return CompressSettings() }
        guard let data = defaults.data(forKey: key) else { return CompressSettings() }
        guard let decoded = try? JSONDecoder().decode(CompressSettings.self, from: data) else {
            return CompressSettings()
        }
        return sanitize(decoded)
    }

    static func save(_ settings: CompressSettings, defaults: UserDefaults = .standard) {
        guard !isDevSession else { return }
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    static func reset(defaults: UserDefaults = .standard) {
        guard !isDevSession else { return }
        defaults.removeObject(forKey: key)
    }

    /// 兜一层：手改过 UserDefaults、或者旧数据混进来时，别让非法值把界面搞坏
    private static func sanitize(_ s: CompressSettings) -> CompressSettings {
        var out = s
        out.quality = min(max(out.quality, CompressSettings.qualityRange.lowerBound),
                          CompressSettings.qualityRange.upperBound)
        out.targetBytes = min(max(out.targetBytes, 8 * 1024), 200 * 1024 * 1024)

        if !CompressSettings.sizeOptions.contains(where: { $0.0 == out.maxDimension }) {
            out.maxDimension = 0
        }
        if out.outputMode == .customFolder, out.customFolderPath == nil {
            out.outputMode = .siblingFolder
        }
        // 调色参数：把旋钮夹回各自区间。
        // 这里**不检查 LUT 文件是否存在**——文件可能在外置盘上暂时没挂载，
        // 直接清掉用户的选择比留着更糟。真用的时候找不到会明确报错。
        out.grade = out.grade.sanitized()

        // 扫描阈值：负数没意义；上限给 10 GB —— 再往上就不是"筛图"，
        // 是输入的时候多按了一位，而那种值会让扫描报告看起来"一张都没扫到"。
        out.scanMinBytes = min(max(out.scanMinBytes, 0), 10 * 1024 * 1024 * 1024)

        // 分批档位：不认识的数一律回落到"一次压完"。
        // 这一条不只是防手改 —— 档位表以后可能会换（比如去掉 200 那档），
        // 那时老存档里的 200 必须有个去处，而不是变成"每批 200 张"的幽灵值。
        if !BatchPlan.isValid(out.batchSize) { out.batchSize = 0 }
        return out
    }
}
