import Darwin
import SwiftUI
import VelaPlayer
#if os(iOS)
import UIKit
#endif

/// 「OSD 信息显示」：屏幕左上角的系统时间、帧率、网速、倍速、播放时间、CPU 与电量。
/// 每秒采样一次（`TimelineView`），只有本视图刷新，不牵动播放界面其他部分。
struct PlayerOSD: View {
    let controller: PlayerController
    @State private var sampler = DeviceMetricsSampler()

    var body: some View {
        let options = controller.preferences.osd
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height
            if options.hasContent, !options.landscapeOnly || isLandscape {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let lines = lines(options: options, date: context.date)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(lines, id: \.self) { Text($0) }
                    }
                    .font(font(options.textSize).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(options.textBackground ? 0 : 0.9), radius: 2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background {
                        if options.textBackground {
                            RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.45))
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.leading, options.hugEdges ? 4 : 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .ignoresSafeArea(edges: options.hugEdges ? .horizontal : [])
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func lines(options: OSDOptions, date: Date) -> [String] {
        let engine = controller.engine
        var lines: [String] = []
        if options.clock { lines.append(date.formatted(date: .omitted, time: .shortened)) }
        if options.frameRate { lines.append(engine.currentFrameRate().map { String(format: "%.2f fps", $0) } ?? "-- fps") }
        if options.networkSpeed { lines.append("网速 " + (sampler.networkBytesPerSecond(at: date).map(Self.byteRate) ?? "--")) }
        if options.playbackSpeed { lines.append("倍速 \(engine.rate.formatted())×") }
        if options.playbackTime { lines.append("\(PlayerTime.format(engine.currentTime)) / \(PlayerTime.format(engine.duration))") }
        if options.cpuUsage { lines.append("CPU " + (DeviceMetrics.cpuUsage().map { "\(Int($0))%" } ?? "--")) }
        if options.battery { lines.append("电量 " + (DeviceMetrics.batteryLevel().map { "\(Int($0 * 100))%" } ?? "--")) }
        return lines
    }

    private func font(_ size: OSDTextSize) -> Font {
        switch size {
        case .small: .caption2
        case .standard: .caption
        case .large: .footnote
        }
    }

    private static func byteRate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond >= 1_000_000
            ? String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
            : String(format: "%.0f KB/s", bytesPerSecond / 1000)
    }
}

/// 设备网速采样：两次读取网卡累计接收字节数之差除以时间间隔。
@MainActor
final class DeviceMetricsSampler {
    private var last: (bytes: UInt64, date: Date)?

    func networkBytesPerSecond(at date: Date) -> Double? {
        guard let bytes = DeviceMetrics.receivedBytes() else { return nil }
        defer { last = (bytes, date) }
        guard let last, date > last.date, bytes >= last.bytes else { return nil }
        return Double(bytes - last.bytes) / date.timeIntervalSince(last.date)
    }
}

enum DeviceMetrics {
    /// 本进程 CPU 占用（所有线程之和，可超过 100%）。
    static func cpuUsage() -> Double? {
        let task = task_self_trap()
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(task, &threads, &count) == KERN_SUCCESS, let threads else { return nil }
        defer {
            vm_deallocate(task, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for index in 0..<Int(count) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
        }
        return total
    }

    /// 所有 Wi-Fi / 蜂窝 / 有线网卡的累计接收字节数（设备级，不只本应用）。
    static func receivedBytes() -> UInt64? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }
        var total: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            total += UInt64(data.pointee.ifi_ibytes)
        }
        return total
    }

    /// 电量 0...1；未知（模拟器、Mac）时为 nil。
    @MainActor
    static func batteryLevel() -> Double? {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? Double(level) : nil
        #else
        return nil
        #endif
    }
}
