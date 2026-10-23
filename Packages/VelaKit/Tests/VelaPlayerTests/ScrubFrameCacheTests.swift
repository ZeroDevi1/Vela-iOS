import Testing
@testable import VelaPlayer

struct ScrubFrameCacheTests {
    /// 同一帧时间被不同秒格请求时只存一份；失败表示缓存按请求位置重复存图。
    @Test func storesEachFrameTimeOnce() {
        var cache = ScrubFrameCache<String>(costLimit: 1000)
        #expect(cache.insert("a", time: 10.2, frameTime: 10, cost: 100, grid: false) == "a")
        // 第 12 秒落在同一张关键帧上：保留原帧，新帧丢弃。
        #expect(cache.insert("a2", time: 12.5, frameTime: 10, cost: 100, grid: false) == "a")
        #expect(cache.count == 1)
        #expect(cache.totalCost == 100)
        #expect(cache.exact(12.9) == "a")
        #expect(cache.exact(14) == nil)
        #expect(cache.hasExact(10.7))
    }

    /// 超出字节上限时先淘汰非网格帧；失败表示来回拖动会把预生成网格挤出缓存。
    @Test func keepsGridFramesWhenOverBudget() {
        var cache = ScrubFrameCache<String>(costLimit: 300)
        cache.insert("grid0", time: 0, frameTime: 0, cost: 100, grid: true)
        cache.insert("grid1", time: 60, frameTime: 60, cost: 100, grid: true)
        cache.insert("user0", time: 5, frameTime: 5, cost: 100, grid: false)
        cache.insert("user1", time: 7, frameTime: 7, cost: 100, grid: false)
        #expect(cache.count == 3)
        #expect(cache.exact(5) == nil)
        #expect(cache.exact(7) == "user1")
        #expect(cache.nearest(1, maxDistance: 8) == "grid0")
        #expect(cache.exact(60.5) == "grid1")
    }

    @Test func nearestRespectsMaxDistance() {
        var cache = ScrubFrameCache<String>(costLimit: 1000)
        cache.insert("a", time: 10, frameTime: 10, cost: 1, grid: false)
        cache.insert("b", time: 40, frameTime: 40, cost: 1, grid: false)
        #expect(cache.nearest(12.4, maxDistance: 8) == "a")
        #expect(cache.nearest(25, maxDistance: 8) == nil)
        cache.removeAll()
        #expect(cache.nearest(10, maxDistance: 8) == nil)
    }

    @Test func sweepGoesCoarseToFineWithoutDuplicateSeconds() {
        let duration: Double = 96 * 60
        let positions = ScrubSweep.positions(duration: duration)
        // 第一档 12 张均匀覆盖全片（每 8 分钟一张），后续档只补新位置。
        #expect(Set(positions.prefix(12).map { Int($0 / (8 * 60)) }).count == 12)
        #expect(positions.count == 96)
        #expect(Set(positions.map { Int($0) }).count == positions.count)
        #expect(ScrubSweep.positions(duration: 0).isEmpty)
        #expect(ScrubSweep.positions(duration: 20).count <= 20)
    }

    @Test func nearDistanceGrowsWithGridGap() {
        #expect(ScrubSweep.nearDistance(duration: 0) == 8)
        #expect(ScrubSweep.nearDistance(duration: 600) == 8)
        #expect(ScrubSweep.nearDistance(duration: 7200) == 75)
    }
}
