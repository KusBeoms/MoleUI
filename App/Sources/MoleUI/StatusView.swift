import SwiftUI
import Charts
import AppKit

struct StatusView: View {
    @EnvironmentObject var m: SystemMonitor

    private var health: (score: Int, label: String, note: String, color: Color) {
        var score = 100
        var notes: [String] = []
        if m.cpu > 85 { score -= 15; notes.append("CPU 부하 높음") }
        let memFrac = Double(m.memUsed) / Double(max(m.memTotal, 1))
        if memFrac > 0.9 { score -= 20; notes.append("메모리 부족") } else if memFrac > 0.8 { score -= 8; notes.append("메모리 사용량 높음") }
        let freeFrac = Double(m.diskFree) / Double(max(m.diskTotal, 1))
        if freeFrac < 0.08 { score -= 25; notes.append("저장 공간 부족") } else if freeFrac < 0.15 { score -= 10; notes.append("저장 공간 여유 적음") }
        if let b = m.battery, b.percent < 15, !b.charging { score -= 10; notes.append("배터리 부족") }
        let label = score >= 90 ? "우수" : score >= 70 ? "양호" : "주의"
        let color: Color = score >= 90 ? .green : score >= 70 ? .yellow : .orange
        return (score, label, notes.first ?? "모든 점검 통과", color)
    }

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 14) {
                VStack(spacing: 14) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                        healthCard
                        cpuCard
                        memoryCard
                        diskCard
                        networkCard
                        if m.battery != nil { batteryCard }
                    }
                    processTable
                }
                .padding(.horizontal, 28).padding(.bottom, 28)
            }
        }
        .scrollIndicators(.hidden)
    }

    private func cardShell<C: View>(_ title: String, icon: String, badge: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.65))
                Spacer()
                if let badge {
                    Text(badge).font(.caption2.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.white.opacity(0.1), in: .rect(cornerRadius: 6))
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func big(_ v: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(v).font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
            Text(unit).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.6))
        }
    }

    private var healthCard: some View {
        let h = health
        return cardShell("상태", icon: "sun.max", badge: "macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)") {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(h.score)").font(.system(size: 42, weight: .bold, design: .rounded)).contentTransition(.numericText())
                        Text(h.label).font(.title3).foregroundStyle(h.color)
                    }
                    Text(h.note).font(.callout).foregroundStyle(.white.opacity(0.6))
                    Spacer(minLength: 0)
                    Text("가동 \(uptime)").font(.caption).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                PlanetView(kind: .sun, size: 120, spin: 1)
                    .frame(width: 120, height: 120)
            }
        }
    }

    private var uptime: String {
        let s = Int(ProcessInfo.processInfo.systemUptime)
        let d = s / 86400, h = (s % 86400) / 3600, mnt = (s % 3600) / 60
        return d > 0 ? "\(d)일 \(h)시간" : h > 0 ? "\(h)시간 \(mnt)분" : "\(mnt)분"
    }

    private var cpuCard: some View {
        cardShell("CPU", icon: "cpu", badge: "\(ProcessInfo.processInfo.activeProcessorCount)코어") {
            big(String(format: "%.0f", m.cpu), unit: "%")
            Chart {
                ForEach(Array(m.cpuHistory.suffix(24).enumerated()), id: \.offset) { i, v in
                    BarMark(x: .value("t", i), y: .value("v", v), width: .fixed(7))
                        .foregroundStyle(.green.opacity(0.75)).cornerRadius(2)
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: 0...100).frame(height: 40)
        }
    }

    private var memoryCard: some View {
        let frac = Double(m.memUsed) / Double(max(m.memTotal, 1))
        return cardShell("메모리", icon: "memorychip", badge: frac > 0.8 ? "부하 높음" : "보통") {
            big(String(format: "%.0f", frac * 100), unit: "%")
            Sparkline(values: m.memHistory, color: .orange, maxValue: 100)
            Text("\(Fmt.bytes(m.memUsed)) / \(Fmt.bytes(m.memTotal)) · 압축 \(Fmt.bytes(m.memCompressed))")
                .font(.caption).foregroundStyle(.white.opacity(0.55))
        }
    }

    private var diskCard: some View {
        let used = m.diskTotal - m.diskFree
        let frac = Double(used) / Double(max(m.diskTotal, 1))
        return cardShell("저장 공간", icon: "internaldrive", badge: Fmt.bytes(m.diskTotal)) {
            big(String(format: "%.0f", Double(m.diskFree) / 1_073_741_824), unit: "GB 남음")
            UsageBar(fraction: frac, tint: frac > 0.9 ? .red : frac > 0.8 ? .orange : .green)
            Text("\(Fmt.bytes(used)) 사용 · \(Int(frac * 100))%").font(.caption).foregroundStyle(.white.opacity(0.55))
        }
    }

    private var networkCard: some View {
        cardShell("네트워크", icon: "network") {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(m.netDown.rate).font(.system(size: 26, weight: .bold, design: .rounded)).contentTransition(.numericText())
            }
            Sparkline(values: m.netHistory, color: .cyan)
            HStack {
                Label(m.netUp.rate, systemImage: "arrow.up"); Spacer(); Label(m.netDown.rate, systemImage: "arrow.down")
            }.font(.caption).foregroundStyle(.white.opacity(0.55))
        }
    }

    private var batteryCard: some View {
        let b = m.battery!
        return cardShell("배터리", icon: b.charging ? "battery.100.bolt" : "battery.75") {
            big("\(b.percent)", unit: "%")
            UsageBar(fraction: Double(b.percent) / 100, tint: b.percent < 20 ? .red : .green)
            Text(b.charging ? "충전 중" : "배터리 사용 중").font(.caption).foregroundStyle(.white.opacity(0.55))
        }
    }

    private var processTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("이름").frame(maxWidth: .infinity, alignment: .leading)
                Text("MEM").frame(width: 90, alignment: .trailing)
                Text("% CPU").frame(width: 150, alignment: .trailing)
                Text("PID").frame(width: 70, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 16).padding(.vertical, 10)
            ForEach(m.topProcesses) { p in
                HStack(spacing: 10) {
                    Rectangle().fill(p.cpu > 80 ? Color.red : p.cpu > 40 ? Color.orange : .clear).frame(width: 3, height: 22)
                    Image(nsImage: icon(for: p)).resizable().frame(width: 22, height: 22)
                    Text(p.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(Fmt.bytes(p.rssBytes)).monospacedDigit().foregroundStyle(.white.opacity(0.7)).frame(width: 90, alignment: .trailing)
                    HStack(spacing: 8) {
                        UsageBar(fraction: min(p.cpu / 100, 1), tint: p.cpu > 80 ? .red : p.cpu > 40 ? .orange : .gray).frame(width: 60)
                        Text(String(format: "%.1f", p.cpu)).monospacedDigit().frame(width: 50, alignment: .trailing)
                    }.frame(width: 150, alignment: .trailing)
                    Text("\(p.id)").monospacedDigit().foregroundStyle(.white.opacity(0.4)).frame(width: 70, alignment: .trailing)
                }
                .font(.callout)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .transition(.opacity)
            }
            .animation(.smooth, value: m.topProcesses.map(\.id))
            Spacer().frame(height: 6)
        }
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func icon(for p: ProcessRow) -> NSImage {
        if let app = NSRunningApplication(processIdentifier: pid_t(p.id)), let i = app.icon { return i }
        return NSWorkspace.shared.icon(for: .unixExecutable)
    }
}
