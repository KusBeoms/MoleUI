import SwiftUI
import AppKit

enum Tab: String, CaseIterable, Identifiable {
    case clean, apps, optimize, analyze, status
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clean: "정리"
        case .apps: "앱"
        case .optimize: "최적화"
        case .analyze: "분석"
        case .status: "상태"
        }
    }
    /// Top and bottom colors of the tab's backdrop.
    var gradient: [Color] {
        switch self {
        case .clean: [Color(red: 0.17, green: 0.21, blue: 0.38), Color(red: 0.10, green: 0.11, blue: 0.20)]
        case .apps: [Color(red: 0.27, green: 0.12, blue: 0.12), Color(red: 0.15, green: 0.08, blue: 0.09)]
        case .optimize: [Color(red: 0.23, green: 0.22, blue: 0.22), Color(red: 0.11, green: 0.11, blue: 0.12)]
        case .analyze: [Color(red: 0.31, green: 0.17, blue: 0.09), Color(red: 0.17, green: 0.12, blue: 0.09)]
        case .status: [Color(red: 0.28, green: 0.23, blue: 0.08), Color(red: 0.15, green: 0.13, blue: 0.08)]
        }
    }
}

@main
struct MoleUIApp: App {
    @StateObject private var monitor = SystemMonitor()
    @StateObject private var clean = TaskModel(command: "clean")
    @StateObject private var optimize = TaskModel(command: "optimize")
    @StateObject private var analyze = AnalyzeModel()
    @StateObject private var uninstall = UninstallModel()

    var body: some Scene {
        WindowGroup("MoleUI") {
            RootView()
                .environmentObject(monitor)
                .environmentObject(clean)
                .environmentObject(optimize)
                .environmentObject(analyze)
                .environmentObject(uninstall)
                .frame(minWidth: 960, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 780)
        Settings { SettingsView().preferredColorScheme(.dark) }
    }
}

struct RootView: View {
    @State private var selection: Tab = .clean
    @Namespace private var tabSpace
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var clean: TaskModel
    @EnvironmentObject var optimize: TaskModel

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: selection.gradient, startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .animation(.smooth(duration: 0.7), value: selection)

            Group {
                switch selection {
                case .clean:
                    TaskHeroView(model: clean, kind: .earth, moon: true, verb: "정리", startLabel: "Mac 스캔",
                                 tagline: "쌓인 먼지를 걷어내면\n공간이 다시 숨을 쉽니다", terminalArgs: nil)
                case .apps: UninstallView()
                case .optimize:
                    TaskHeroView(model: optimize, kind: .mercury, moon: false, verb: "최적화", startLabel: "최적화 확인",
                                 tagline: "작은 손질 하나가\n하루의 속도를 바꿉니다", terminalArgs: "optimize")
                case .analyze: AnalyzeView()
                case .status: StatusView()
                }
            }
            .padding(.top, 78)
            .id(selection)
            .transition(.opacity.animation(.easeInOut(duration: 0.25)))

            TabBar(selection: $selection, space: tabSpace)
                .padding(.top, 14)
        }
        .onAppear { monitor.start() }
        .overlay(alignment: .topTrailing) { CLIStatus().padding(.top, 20).padding(.trailing, 20) }
    }
}

private struct TabBar: View {
    @Binding var selection: Tab
    let space: Namespace.ID

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().fill(.white)
                Image(systemName: "sparkle").font(.system(size: 17, weight: .bold)).foregroundStyle(.black)
            }
            .frame(width: 38, height: 38)
            ForEach(Tab.allCases) { tab in
                Button { selection = tab } label: {
                    Text(tab.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selection == tab ? .black : .white.opacity(0.75))
                        .padding(.horizontal, 20).padding(.vertical, 9)
                        .background {
                            if selection == tab {
                                Capsule().fill(.white).matchedGeometryEffect(id: "tab", in: space)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .glassEffect(.regular, in: .capsule)
    }
}

enum Permissions {
    /// Full Disk Access probe: the TCC database is only readable when it is granted.
    static var hasFullDiskAccess: Bool {
        FileManager.default.isReadableFile(atPath: "/Library/Application Support/com.apple.TCC/TCC.db")
    }
    static func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}

struct CLIStatus: View {
    @State private var fda = Permissions.hasFullDiskAccess
    var body: some View {
        let ok = MoleLocator.find() != nil
        HStack(spacing: 8) {
            if !fda {
                Button { Permissions.openFullDiskAccess() } label: {
                    Label("권한 한 번에 허용", systemImage: "lock.open.fill").font(.caption.weight(.semibold))
                }
                .buttonStyle(.glassProminent)
                .help("전체 디스크 접근 권한을 주면 폴더별 허용 팝업이 더 이상 뜨지 않습니다.")
            }
            HStack(spacing: 6) {
                Circle().fill(ok ? Color.green : Color.red).frame(width: 7, height: 7)
                Text(ok ? "mo 연결됨" : "mo 없음").font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fda = Permissions.hasFullDiskAccess
        }
    }
}

struct SettingsView: View {
    @AppStorage(MoleLocator.overrideKey) private var path = ""
    var body: some View {
        Form {
            TextField("mo 실행 파일 경로", text: $path, prompt: Text("비워두면 자동 탐색"))
            LabeledContent("전체 디스크 접근") {
                Button(Permissions.hasFullDiskAccess ? "허용됨" : "시스템 설정 열기") { Permissions.openFullDiskAccess() }
                    .disabled(Permissions.hasFullDiskAccess)
            }
            Text("현재 사용: \(MoleLocator.find()?.path ?? "찾을 수 없음")")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("MoleUI는 Mole CLI의 비공식 인터페이스입니다. Mole 프로젝트와 제휴 관계가 아닙니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 280)
    }
}
