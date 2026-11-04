import Foundation
import IOKit.ps
import SwiftUI

struct ProcessRow: Identifiable {
    let id: Int
    let name: String
    let cpu: Double
    let rssBytes: Int64
}

/// Native live stats. Samples every two seconds while the dashboard is visible.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published var cpu: Double = 0
    @Published var cpuHistory: [Double] = Array(repeating: 0, count: 60)
    @Published var memUsed: Int64 = 0
    @Published var memTotal: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    @Published var memCompressed: Int64 = 0
    @Published var memHistory: [Double] = Array(repeating: 0, count: 60)
    @Published var diskFree: Int64 = 0
    @Published var diskTotal: Int64 = 0
    @Published var netDown: Double = 0
    @Published var netUp: Double = 0
    @Published var netHistory: [Double] = Array(repeating: 0, count: 60)
    @Published var battery: (percent: Int, charging: Bool)?
    @Published var topProcesses: [ProcessRow] = []

    private var timer: Timer?
    private var lastTicks: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?
    private var lastNet: (rx: UInt64, tx: UInt64, at: Date)?
    private var tick = 0

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastTicks = nil
        lastNet = nil
    }

    private func sample() {
        sampleCPU()
        sampleMemory()
        sampleNetwork()
        if tick % 15 == 0 { sampleDisk(); sampleBattery() }
        if tick % 3 == 0 { sampleProcesses() }
        tick += 1
    }

    private func sampleCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let t = info.cpu_ticks
        let now = (user: t.0, sys: t.1, idle: t.2, nice: t.3)
        defer { lastTicks = now }
        guard let prev = lastTicks else { return }
        let du = Double(now.user &- prev.user), ds = Double(now.sys &- prev.sys)
        let di = Double(now.idle &- prev.idle), dn = Double(now.nice &- prev.nice)
        let total = du + ds + di + dn
        guard total > 0 else { return }
        cpu = (du + ds + dn) / total * 100
        cpuHistory.append(cpu); cpuHistory.removeFirst()
    }

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let page = Int64(vm_kernel_page_size)
        memUsed = (Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
        memCompressed = Int64(stats.compressor_page_count) * page
        memHistory.append(Double(memUsed) / Double(max(memTotal, 1)) * 100); memHistory.removeFirst()
    }

    private func sampleDisk() {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        else { return }
        diskTotal = Int64(v.volumeTotalCapacity ?? 0)
        diskFree = v.volumeAvailableCapacityForImportantUsage ?? 0
    }

    private func sampleNetwork() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, let data = ifa.ifa_data
            else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            rx += UInt64(d.ifi_ibytes); tx += UInt64(d.ifi_obytes)
        }
        let now = Date()
        defer { lastNet = (rx, tx, now) }
        guard let prev = lastNet else { return }
        let dt = now.timeIntervalSince(prev.at)
        guard dt > 0, rx >= prev.rx, tx >= prev.tx else { return }
        netDown = Double(rx - prev.rx) / dt
        netUp = Double(tx - prev.tx) / dt
        netHistory.append(netDown + netUp); netHistory.removeFirst()
    }

    private func sampleBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let src = list.first,
              let d = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any],
              let cap = d[kIOPSCurrentCapacityKey] as? Int
        else { battery = nil; return }
        battery = (cap, (d[kIOPSIsChargingKey] as? Bool) ?? false)
    }

    private func sampleProcesses() {
        Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-Ao", "pid=,pcpu=,rss=,comm=", "-r"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let rows: [ProcessRow] = String(decoding: data, as: UTF8.self)
                .split(separator: "\n").prefix(10).compactMap { line in
                    let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                    guard f.count == 4, let pid = Int(f[0]), let cpu = Double(f[1]), let rss = Int64(f[2]) else { return nil }
                    let name = (String(f[3]) as NSString).lastPathComponent
                    return ProcessRow(id: pid, name: name, cpu: cpu, rssBytes: rss * 1024)
                }
            await MainActor.run { self.topProcesses = rows }
        }
    }
}

extension Double {
    var rate: String { ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .binary) + "/s" }
}
