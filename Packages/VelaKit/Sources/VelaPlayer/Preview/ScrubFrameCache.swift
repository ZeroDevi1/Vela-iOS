import Foundation

/// 拖动预览的帧缓存与预生成取点规则（纯逻辑，与 Android 版 `ScrubFrameSchedule` 一致）。
///
/// - 帧按实际解出的帧时间存放，请求位置所在的秒格只记一个指向它的别名：关键帧间隔通常 2～10 秒，
///   按请求秒格直接存图时同一张关键帧会被存多份，既浪费内存又把网格帧挤出缓存。
/// - 后台预生成的网格帧固定保留，超出字节上限时先淘汰最久未用的现场抽帧，
///   保证来回拖动之后全片仍有均匀的邻近帧可用。
///
/// 值类型，由 `ScrubPreviewer` 在主 actor 上持有与修改。
struct ScrubFrameCache<Frame> {
    private struct Entry {
        var frame: Frame
        var cost: Int
    }

    /// 缓存总字节上限；网格帧也计入，但只在没有非网格帧可淘汰时才被淘汰。
    let costLimit: Int
    /// 帧时间（毫秒）→ 帧。
    private var entries: [Int: Entry] = [:]
    /// 最近使用顺序，最久未用的在前；与 `entries` 的键集合始终相同。
    private var order: [Int] = []
    /// 请求秒格 → 帧时间（毫秒）。只指向仍在 `entries` 里的帧。
    private var aliases: [Int: Int] = [:]
    private var gridKeys: Set<Int> = []
    private(set) var totalCost = 0

    init(costLimit: Int) {
        self.costLimit = costLimit
    }

    var count: Int { entries.count }

    static func bucket(for time: TimeInterval) -> Int { Int(max(0, time)) }

    /// 同一请求秒格可复用，但仍按当前目标和实际帧时间校验误差。
    mutating func exact(_ time: TimeInterval, maxDistance: TimeInterval = .infinity) -> Frame? {
        guard let key = aliases[Self.bucket(for: time)], let entry = entries[key],
              abs(Double(key) / 1000 - time) <= maxDistance else { return nil }
        touch(key)
        return entry.frame
    }

    mutating func nearest(_ time: TimeInterval, maxDistance: TimeInterval) -> Frame? {
        let target = time * 1000
        guard let key = entries.keys.min(by: { abs(Double($0) - target) < abs(Double($1) - target) }),
              abs(Double(key) - target) <= maxDistance * 1000 else { return nil }
        touch(key)
        return entries[key]?.frame
    }

    /// 记下请求位置对应的帧。该帧时间已缓存时保留原帧、丢弃新帧。
    /// - Parameters:
    ///   - time: 请求位置（秒）。
    ///   - frameTime: 实际解出的帧时间（秒）。
    ///   - cost: 帧占用的字节数。
    ///   - grid: 是否为后台预生成的网格帧。
    /// - Returns: 该帧时间当前对应的帧。
    @discardableResult
    mutating func insert(_ frame: Frame, time: TimeInterval, frameTime: TimeInterval, cost: Int, grid: Bool) -> Frame {
        let key = Int((max(0, frameTime) * 1000).rounded())
        if entries[key] == nil {
            entries[key] = Entry(frame: frame, cost: cost)
            order.append(key)
            totalCost += cost
        } else {
            touch(key)
        }
        aliases[Self.bucket(for: time)] = key
        if grid { gridKeys.insert(key) }
        trim(keeping: key)
        return entries[key]?.frame ?? frame
    }

    /// 该请求秒格是否已有确定的帧（预生成据此跳过）。
    func hasExact(_ time: TimeInterval) -> Bool {
        aliases[Self.bucket(for: time)].map { entries[$0] != nil } ?? false
    }

    mutating func removeAll() {
        entries = [:]
        order = []
        aliases = [:]
        gridKeys = []
        totalCost = 0
    }

    private mutating func touch(_ key: Int) {
        guard let index = order.firstIndex(of: key) else { return }
        order.remove(at: index)
        order.append(key)
    }

    /// 超出上限时先淘汰最久未用的非网格帧；只剩网格帧时淘汰最久未用的网格帧。刚写入的帧不淘汰。
    private mutating func trim(keeping latest: Int) {
        while totalCost > costLimit, order.count > 1 {
            guard let index = order.firstIndex(where: { $0 != latest && !gridKeys.contains($0) })
                ?? order.firstIndex(where: { $0 != latest }) else { return }
            let victim = order.remove(at: index)
            totalCost -= entries.removeValue(forKey: victim)?.cost ?? 0
            gridKeys.remove(victim)
            aliases = aliases.filter { $0.value != victim }
        }
    }
}

/// 后台预生成的取点规则。
enum ScrubSweep {
    /// 网格分档：先全片均分 12 张，再逐档加密到 96 张。由粗到细保证刚开始不久，任意位置就有一张不太远的预览。
    static let levels = [12, 24, 48, 96]

    /// 预生成的取帧位置（秒），按分档由粗到细排列，同一秒格只出现一次；片长未知时为空。
    static func positions(duration: TimeInterval) -> [TimeInterval] {
        guard duration > 0 else { return [] }
        // 各档共用最细一档的格子：粗档按步长从中抽取，总帧数不超过最细档，不会重复取帧。
        let finest = levels.last!
        var picked: [Int] = []
        var pickedSet: Set<Int> = []
        for count in levels {
            let stride = finest / count
            for index in 0..<count {
                let cell = index * stride + stride / 2
                if pickedSet.insert(cell).inserted { picked.append(cell) }
            }
        }
        var seenBuckets: Set<Int> = []
        return picked.compactMap { cell in
            // 取格子中点，避开片头黑场和片尾字幕的边界。
            let time = duration * Double(2 * cell + 1) / Double(2 * finest)
            return seenBuckets.insert(ScrubFrameCache<Never>.bucket(for: time)).inserted ? time : nil
        }
    }
}
