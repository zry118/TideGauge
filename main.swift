import SwiftUI
import AppKit
import Darwin
import Combine
import ServiceManagement

//
//  潮汐表 TideGauge —— 菜单栏系统监控
//
//  菜单栏常驻：CPU / 内存 / 网络流速一目了然；
//  点开是一块 60 秒滚动曲线 + 进程榜。
//
//  零权限：只读系统计数器（host_statistics / sysctl / getifaddrs / proc_pid_rusage），
//  不碰辅助功能、不碰屏幕录制，没有任何授权弹窗。
//
//  自检:   TideGauge --selftest
//  渲染:   TideGauge --render /tmp/panel.png
//

// MARK: - 运行模式

enum RunMode { case app, test, render }

enum RenderConfig {
    static var mode: RunMode = .app
    static var isRendering: Bool { mode == .render }
    /// 渲染设置页（--settings）时打开面板的设置分区
    static var showSettings = false
}

// MARK: - 配色（深海 + 潮汐青）

enum Theme {
    static let bg       = Color(red: 0.043, green: 0.063, blue: 0.090)
    static let cell     = Color(red: 0.078, green: 0.106, blue: 0.145)
    static let track    = Color(white: 1, opacity: 0.08)
    static let hairline = Color(red: 0.360, green: 0.560, blue: 0.700).opacity(0.22)
    static let paper    = Color(red: 0.878, green: 0.918, blue: 0.957)
    static let dim      = Color(red: 0.510, green: 0.596, blue: 0.700)
    static let cyan     = Color(red: 0.353, green: 0.780, blue: 0.980)
    static let jade     = Color(red: 0.361, green: 0.859, blue: 0.620)
    static let amber    = Color(red: 0.980, green: 0.725, blue: 0.380)
}

// MARK: - 格式化
//
// 注意：所有函数都返回 String。Text 直接插值 Int 会走 LocalizedStringKey，
// 1990 会被格式化成 "1,990"（ClipBox 踩过的坑），必须先转 String。

enum Fmt {
    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v) }

    static func gb(_ bytes: UInt64) -> String {
        String(format: "%.1fG", Double(bytes) / 1e9)
    }

    static func rate(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 { return String(format: "%.0fB/s", bytesPerSec) }
        if bytesPerSec < 1024 * 1024 { return String(format: "%.0fK/s", bytesPerSec / 1024) }
        return String(format: "%.1fM/s", bytesPerSec / 1048576)
    }

    /// 菜单栏用：去掉 /s 后缀，省宽度
    static func shortRate(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 { return String(format: "%.0fB", bytesPerSec) }
        if bytesPerSec < 1024 * 1024 { return String(format: "%.0fK", bytesPerSec / 1024) }
        return String(format: "%.1fM", bytesPerSec / 1048576)
    }

    static func uptime(_ t: TimeInterval) -> String {
        let s = Int(t)
        let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
        if d > 0 { return "\(d)天\(h)小时" }
        if h > 0 { return "\(h)小时\(m)分" }
        return "\(m)分钟"
    }
}

// MARK: - 数据模型

struct ProcSample {
    let pid: Int32
    let name: String
    let cpuTicks: Double   // 累计 CPU 时间（纳秒）
    let rss: UInt64
}

struct ProcRow: Identifiable {
    let pid: Int32
    let name: String
    let cpu: Double        // 采样间隔内的 CPU 百分比
    let rss: UInt64
    var id: Int32 { pid }
}

// MARK: - 菜单栏配置（UserDefaults 持久化）

final class Config: ObservableObject {
    enum NetMode: Int, CaseIterable, Identifiable {
        case both = 0, downOnly = 1, upOnly = 2
        var id: Int { rawValue }
    }

    @Published var showCPU = true    { didSet { save() } }
    @Published var showMem = true    { didSet { save() } }
    @Published var showNet = true    { didSet { save() } }
    @Published var showDisk = false  { didSet { save() } }
    @Published var showLoad = false  { didSet { save() } }
    /// 菜单栏图标开关：关掉后只显示文字，状态项窄约 19pt
    @Published var showIcon = true   { didSet { save() } }
    @Published var netMode: NetMode = .both { didSet { save() } }
    @Published var interval = 1.0    { didSet { save() } }

    init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "tg.showCPU": true, "tg.showMem": true, "tg.showNet": true,
            "tg.showDisk": false, "tg.showLoad": false,
            "tg.showIcon": true,
            "tg.netMode": 0, "tg.interval": 1.0
        ])
        showCPU = d.bool(forKey: "tg.showCPU")
        showMem = d.bool(forKey: "tg.showMem")
        showNet = d.bool(forKey: "tg.showNet")
        showDisk = d.bool(forKey: "tg.showDisk")
        showLoad = d.bool(forKey: "tg.showLoad")
        showIcon = d.bool(forKey: "tg.showIcon")
        netMode = NetMode(rawValue: d.integer(forKey: "tg.netMode")) ?? .both
        interval = d.double(forKey: "tg.interval")
        isLoading = false
    }

    /// init 里逐个属性赋值都会触发 didSet；没有这个护栏，
    /// save() 会把「还没加载完」的半初始化状态写回，冲掉已存的值
    private var isLoading = true

    private func save() {
        guard !isLoading else { return }
        let d = UserDefaults.standard
        d.set(showCPU, forKey: "tg.showCPU")
        d.set(showMem, forKey: "tg.showMem")
        d.set(showNet, forKey: "tg.showNet")
        d.set(showDisk, forKey: "tg.showDisk")
        d.set(showLoad, forKey: "tg.showLoad")
        d.set(showIcon, forKey: "tg.showIcon")
        d.set(netMode.rawValue, forKey: "tg.netMode")
        d.set(interval, forKey: "tg.interval")
    }

    /// 给 Picker/Segmented 用的 Binding
    func bind<T>(_ keyPath: ReferenceWritableKeyPath<Config, T>) -> Binding<T> {
        Binding(get: { self[keyPath: keyPath] },
                set: { self[keyPath: keyPath] = $0 })
    }
}

/// 菜单栏文本：按配置拼装，纯函数便于自检
enum MenuLabel {
    static func text(cpu: Double, memUsed: UInt64, netIn: Double, netOut: Double,
                     diskFree: UInt64, load: Double, _ c: Config) -> String {
        var parts: [String] = []
        if c.showCPU { parts.append(Fmt.pct(cpu)) }
        if c.showMem { parts.append(Fmt.gb(memUsed)) }
        if c.showNet {
            switch c.netMode {
            case .both:     parts.append("↑\(Fmt.shortRate(netOut))↓\(Fmt.shortRate(netIn))")
            case .downOnly: parts.append("↓\(Fmt.shortRate(netIn))")
            case .upOnly:   parts.append("↑\(Fmt.shortRate(netOut))")
            }
        }
        if c.showDisk { parts.append(Fmt.gb(diskFree)) }
        if c.showLoad { parts.append(String(format: "%.2f", load)) }
        return parts.isEmpty ? "—" : parts.joined(separator: "  ")
    }

    /// 当前配置下菜单栏文本的最宽可能值。NSStatusItem 按它设固定宽度，
    /// 数字涨落时按钮宽度不变，图标才不会晃。
    /// 取值贴现实：容量到 999.9G（1TB）、网速到 99.9M（≈100MB/s 的
    /// 光纤/SSD 读写量级）、负载到 99.99；再极端的值由 fixedLength
    /// 的余量兜 1 个字符，不至于抖动
    static func widestText(_ c: Config) -> String {
        var parts: [String] = []
        if c.showCPU { parts.append("100%") }
        if c.showMem { parts.append("999.9G") }
        if c.showNet {
            switch c.netMode {
            case .both:     parts.append("↑99.9M↓99.9M")
            case .downOnly: parts.append("↓99.9M")
            case .upOnly:   parts.append("↑99.9M")
            }
        }
        if c.showDisk { parts.append("999.9G") }
        if c.showLoad { parts.append("99.99") }
        return parts.isEmpty ? "—" : parts.joined(separator: "  ")
    }

    /// 状态项固定宽度。内边距是实测值（探针 app 量 variableLength 的
    /// 固有尺寸）：带图标 = 文字宽 + 38（20 按钮内边距 + 18 图标），
    /// 纯文字 = 文字宽 + 20。6% 余量兜住比最宽值多 1 个字符的极端值
    /// （单个方向；收发同时超 100M/s 会轻微截断）
    static func fixedLength(textW: CGFloat, showIcon: Bool) -> CGFloat {
        ceil((textW + (showIcon ? 38 : 20)) * 1.06)
    }
}

/// 面板的零碎 UI 状态（CLT 下没有 @State，统一用小 ObservableObject）
final class UIState: ObservableObject {
    @Published var settingsOpen = RenderConfig.showSettings
}

// MARK: - 采样器（依赖注入）
//
// 和 ClipBox 一样的思路：所有系统调用收进一组闭包。
// 真app接系统计数器，自检/渲染接确定性假数据 ——
// 核心逻辑（差值、排序、封顶、格式化）不碰真实系统也能测。

struct Sampler {
    var cpu: () -> (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)
    var memory: () -> (used: UInt64, total: UInt64, wired: UInt64, compressed: UInt64)
    var network: () -> (inBytes: UInt64, outBytes: UInt64)
    var disk: () -> UInt64
    var boot: () -> TimeInterval
    var load: () -> [Double]
    var processes: () -> [ProcSample]

    static let real = Sampler(
        cpu: { readCPUTicks() },
        memory: { readMemory() },
        network: { readNetwork() },
        disk: { readDiskFree() },
        boot: { readBootTime() },
        load: { readLoadAvg() },
        processes: { readProcesses() }
    )

    /// 每次访问都造一个新的假数据发生器，保证两次运行结果逐字节一致
    static var fake: Sampler {
        let g = FakeGen()
        return Sampler(cpu: { g.cpu() }, memory: { g.memory() },
                       network: { g.network() }, disk: { g.disk() },
                       boot: { g.boot() }, load: { g.load() },
                       processes: { g.processes() })
    }
}

// MARK: - 真实系统计数器

/// host_processor_info：分配内核缓冲区，用完必须 vm_deallocate
/// （host_statistics + HOST_CPU_LOAD_INFO 在新系统上只回一个核、且字段错位，不要用）
private func readCPUTicks() -> (UInt64, UInt64, UInt64, UInt64) {
    var procCount = mach_msg_type_number_t()
    var cpuInfo: UnsafeMutablePointer<integer_t>? = nil
    var infoCount = mach_msg_type_number_t()
    let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                 &procCount, &cpuInfo, &infoCount)
    guard kr == KERN_SUCCESS, let cpuInfo else { return (0, 0, 0, 0) }
    defer {
        // 第三个参数是「处理器数」，第五个才是 integer_t 元素数，别搞反
        let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)
    }
    let ptr = UnsafeRawPointer(cpuInfo)
        .assumingMemoryBound(to: processor_cpu_load_info.self)
    let buf = UnsafeBufferPointer(start: ptr, count: Int(procCount))
    // cpu_ticks 顺序：user / system / idle / nice（不是 user/nice/system/idle）
    var u: UInt64 = 0, s: UInt64 = 0, i: UInt64 = 0, ni: UInt64 = 0
    for k in 0..<buf.count {
        let t = buf[k].cpu_ticks
        u  += UInt64(t.0)
        s  += UInt64(t.1)
        i  += UInt64(t.2)
        ni += UInt64(t.3)
    }
    return (u, s, i, ni)
}

private func readMemory() -> (UInt64, UInt64, UInt64, UInt64) {
    var stats = vm_statistics64()
    var count = UInt32(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &stats) { p -> kern_return_t in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ip in
            host_statistics64(mach_host_self(), HOST_VM_INFO64, ip, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return (0, 0, 0, 0) }
    let page = UInt64(vm_kernel_page_size)
    let total = ProcessInfo.processInfo.physicalMemory
    // 和活动监视器口径一致：已用 = 应用内存 + 联动 + 压缩
    let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
                + UInt64(stats.compressor_page_count)) * page
    return (used, total, UInt64(stats.wire_count) * page,
            UInt64(stats.compressor_page_count) * page)
}

private func readNetwork() -> (UInt64, UInt64) {
    var addrs: UnsafeMutablePointer<ifaddrs>? = nil
    guard getifaddrs(&addrs) == 0, let first = addrs else { return (0, 0) }
    defer { freeifaddrs(addrs) }
    var ib: UInt64 = 0, ob: UInt64 = 0
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let cur = p {
        let name = String(cString: cur.pointee.ifa_name)
        // 只统计物理网卡（en*），排除 lo0 / 桥接 / 隧道
        if cur.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK),
           name.hasPrefix("en"), let data = cur.pointee.ifa_data {
            let d = UnsafeRawPointer(data).assumingMemoryBound(to: if_data.self).pointee
            ib += UInt64(d.ifi_ibytes)
            ob += UInt64(d.ifi_obytes)
        }
        p = cur.pointee.ifa_next
    }
    return (ib, ob)
}

private func readDiskFree() -> UInt64 {
    var s = statfs()
    guard statfs("/", &s) == 0 else { return 0 }
    return UInt64(s.f_bavail) * UInt64(s.f_bsize)
}

private func readBootTime() -> TimeInterval {
    var size = MemoryLayout<timeval>.stride
    var tv = timeval()
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
    return Date().timeIntervalSince1970 - Double(tv.tv_sec) - Double(tv.tv_usec) / 1e6
}

private func readLoadAvg() -> [Double] {
    var l = [Double](repeating: 0, count: 3)
    getloadavg(&l, 3)
    return l
}

private func readProcesses() -> [ProcSample] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
    let buf = UnsafeMutableRawPointer.allocate(
        byteCount: size, alignment: MemoryLayout<kinfo_proc>.alignment)
    defer { buf.deallocate() }
    guard sysctl(&mib, 4, buf, &size, nil, 0) == 0 else { return [] }

    let stride = MemoryLayout<kinfo_proc>.stride
    let n = size / stride
    var out: [ProcSample] = []
    out.reserveCapacity(n)
    for i in 0..<n {
        let kp = buf.load(fromByteOffset: i * stride, as: kinfo_proc.self)
        let pid = kp.kp_proc.p_pid
        var nameBuf = [CChar](repeating: 0, count: 4096)
        proc_name(pid, &nameBuf, 4096)
        let nm = String(cString: nameBuf)
        var cpu = 0.0, rss: UInt64 = 0
        var ri = rusage_info_v4()
        // proc_pid_rusage 的第三个参数是 rusage_info_t*（即 void**），
        // Swift 导入成 UnsafeMutablePointer<UnsafeMutableRawPointer?>，
        // 直接 &ri 过不了编译 —— 把结构体内存重绑定成指针类型再传
        let ret = withUnsafeMutablePointer(to: &ri) { p -> Int32 in
            p.withMemoryRebound(to: Optional<UnsafeMutableRawPointer>.self, capacity: 1) { rp in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rp)
            }
        }
        if ret == 0 {
            // ri_user_time / ri_system_time 是 uint64_t，单位纳秒
            cpu = Double(ri.ri_user_time) + Double(ri.ri_system_time)
            rss = ri.ri_resident_size
        }
        out.append(ProcSample(pid: pid, name: nm.isEmpty ? "pid \(pid)" : nm,
                              cpuTicks: cpu, rss: rss))
    }
    return out
}

// MARK: - 假数据发生器（自检 / 离屏渲染用）

final class FakeGen {
    private var t = 0
    private var u: UInt64 = 12_000, s: UInt64 = 6_000, i: UInt64 = 90_000
    private var inB: UInt64 = 8_000_000, outB: UInt64 = 2_000_000
    private var seed: UInt64 = 20241025
    private let names = ["kernel_task", "Safari", "Xcode", "WeChat",
                         "Code Helper", "Music", "Mail", "WindowServer",
                         "Finder", "Terminal"]
    private let rss: [UInt64] = [420_000_000, 1_200_000_000, 2_800_000_000,
                                 680_000_000, 900_000_000, 210_000_000,
                                 180_000_000, 560_000_000, 96_000_000, 74_000_000]

    private func rnd() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double((seed >> 33) % 1000) / 1000.0
    }

    func cpu() -> (UInt64, UInt64, UInt64, UInt64) {
        t += 1
        u += UInt64(30 + rnd() * 90)
        s += UInt64(15 + rnd() * 45)
        i += UInt64(500 + rnd() * 260)
        return (u, s, i, 0)
    }

    func memory() -> (UInt64, UInt64, UInt64, UInt64) {
        let total: UInt64 = 16_000_000_000
        let used: UInt64 = 6_800_000_000
            + UInt64(900_000_000 * (0.5 + 0.5 * sin(Double(t) / 9)))
        return (used, total, 1_100_000_000, 640_000_000)
    }

    func network() -> (UInt64, UInt64) {
        inB += UInt64(200_000 + rnd() * 900_000)
        outB += UInt64(60_000 + rnd() * 240_000)
        return (inB, outB)
    }

    func disk() -> UInt64 { 128_000_000_000 }
    func boot() -> TimeInterval { 3 * 86400 + 4 * 3600 + 5 * 60 }
    func load() -> [Double] { [1.24, 1.31, 1.18] }

    func processes() -> [ProcSample] {
        (0..<names.count).map { k in
            ProcSample(pid: Int32(1000 + k), name: names[k],
                       // 每秒约 (80 + k*37) 毫秒 CPU，单位纳秒
                       cpuTicks: Double(t) * Double(80 + k * 37) * 1_000_000
                           + rnd() * 5e7,
                       rss: rss[k] + UInt64(rnd() * 4_000_000))
        }
    }
}

// MARK: - 监控核心
//
// 每秒采一次样，把累计计数器换成比率：
//   CPU% = Δbusy / Δtotal；网络速率 = Δbytes / Δt；进程 CPU% = ΔcpuTicks / Δt

final class Monitor: ObservableObject {
    @Published var cpuPct: Double = 0
    @Published var memUsed: UInt64 = 0
    @Published var memTotal: UInt64 = 0
    @Published var memWired: UInt64 = 0
    @Published var memCompressed: UInt64 = 0
    @Published var netIn: Double = 0
    @Published var netOut: Double = 0
    @Published var diskFree: UInt64 = 0
    @Published var uptime: TimeInterval = 0
    @Published var load: [Double] = [0, 0, 0]
    @Published var procs: [ProcRow] = []

    // 60 秒滚动窗口
    @Published var cpuHist: [Double] = []
    @Published var memHist: [Double] = []
    @Published var netInHist: [Double] = []
    @Published var netOutHist: [Double] = []

    private let sampler: Sampler
    private let config: Config
    private let selfPID = getpid()
    private var lastCPU: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var lastNet: (inBytes: UInt64, outBytes: UInt64)?
    private var lastProcCPU: [Int32: Double] = [:]
    private var lastTick = Date()
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(sampler: Sampler, config: Config = Config()) {
        self.sampler = sampler
        self.config = config
        // 间隔改动时重建定时器（@Published 订阅即刻推当前值，dropFirst 掉）
        config.$interval
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.restartTimer() }
            .store(in: &cancellables)
    }

    func start() { restartTimer() }

    private func restartTimer() {
        timer?.invalidate()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: max(config.interval, 0.5),
                                     repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func tick() { tick(at: Date()) }

    /// at 参数是为了让自检能在「1 秒间隔」下跑：
    /// 紧密循环调用会把 dt 钳到 1ms，速率类断言全部失真
    func tick(at now: Date) {
        let dt = max(now.timeIntervalSince(lastTick), 0.001)
        lastTick = now

        // CPU
        let c = sampler.cpu()
        if let prev = lastCPU {
            // &- 防计数器回绕
            let busy = Double(c.user &- prev.user) + Double(c.system &- prev.system)
            let total = busy + Double(c.idle &- prev.idle) + Double(c.nice &- prev.nice)
            cpuPct = total > 0 ? min(max(busy / total * 100, 0), 100) : 0
        }
        lastCPU = c
        push(&cpuHist, cpuPct)

        // 内存
        let m = sampler.memory()
        memUsed = m.used; memTotal = m.total
        memWired = m.wired; memCompressed = m.compressed
        push(&memHist, Double(m.used) / 1e9)

        // 网络
        let net = sampler.network()
        if let prev = lastNet {
            netIn = Double(net.inBytes &- prev.inBytes) / dt
            netOut = Double(net.outBytes &- prev.outBytes) / dt
        }
        lastNet = net
        push(&netInHist, netIn)
        push(&netOutHist, netOut)

        diskFree = sampler.disk()
        uptime = sampler.boot()
        load = sampler.load()

        // 进程榜：算增量 CPU%，按 CPU 降序取前 8，排除自己
        var rows: [ProcRow] = []
        var curCPU: [Int32: Double] = [:]
        for p in sampler.processes() where p.pid != selfPID {
            curCPU[p.pid] = p.cpuTicks
            let prevT = lastProcCPU[p.pid] ?? p.cpuTicks
            // cpuTicks 单位纳秒 → 百分比
            let pct = max((p.cpuTicks - prevT) / 1e9 / dt * 100, 0)
            rows.append(ProcRow(pid: p.pid, name: p.name, cpu: pct, rss: p.rss))
        }
        lastProcCPU = curCPU
        rows.sort { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.rss > $1.rss }
        procs = Array(rows.prefix(8))
    }

    private func push(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > 60 { arr.removeFirst(arr.count - 60) }
    }
}

// MARK: - 开机启动状态

final class LaunchState: ObservableObject {
    @Published var on: Bool
    init() { on = (SMAppService.mainApp.status == .enabled) }
    func toggle() {
        do {
            if on { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { }
        on = (SMAppService.mainApp.status == .enabled)
    }
}

// MARK: - 曲线（Canvas，离屏渲染可画）

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var second: [Double]? = nil
    var secondColor: Color = Theme.amber

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            // 纵轴固定从 0 起：速率图不会因为一次尖峰把其余压平
            let maxV = max((values.max() ?? 1), (second?.max() ?? 0), 1e-6)
            let range = maxV

            func pt(_ v: Double, _ i: Int, _ n: Int) -> CGPoint {
                CGPoint(x: size.width * CGFloat(i) / CGFloat(n - 1),
                        y: size.height * CGFloat(1 - v / range))
            }

            // 底纹网格
            var grid = Path()
            for k in 1..<3 {
                let y = size.height * CGFloat(k) / 3
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(grid, with: .color(Theme.track), lineWidth: 0.5)

            func line(_ arr: [Double], _ c: Color, area: Bool) {
                guard arr.count > 1 else { return }
                var p = Path()
                for (i, v) in arr.enumerated() {
                    let q = pt(v, i, arr.count)
                    if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
                }
                if area {
                    var fill = p
                    fill.addLine(to: CGPoint(x: size.width, y: size.height))
                    fill.addLine(to: CGPoint(x: 0, y: size.height))
                    fill.closeSubpath()
                    ctx.fill(fill, with: .linearGradient(
                        Gradient(colors: [c.opacity(0.30), c.opacity(0)]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: size.height)))
                }
                ctx.stroke(p, with: .color(c), lineWidth: 1.3)
            }

            if let second { line(second, secondColor, area: false) }
            line(values, color, area: true)
        }
    }
}

// MARK: - 面板

struct PanelView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var config: Config
    @StateObject private var launch = LaunchState()
    @StateObject private var ui = UIState()

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if ui.settingsOpen {
                settingsBody
            } else {
                cards
                graphBlock("CPU 使用率", monitor.cpuHist, Theme.cyan)
                graphBlock("网络流速", monitor.netInHist, Theme.jade,
                           second: monitor.netOutHist, secondColor: Theme.amber)
                procBlock
            }
            footer
        }
        .frame(width: 320, height: 580)
        .background(Theme.bg)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 12))
                .foregroundStyle(Theme.cyan)
            Text("潮汐表")
                .font(.system(size: 13, weight: .medium, design: .serif))
                .foregroundStyle(Theme.paper)
            Spacer()
            Text("运行 " + Fmt.uptime(monitor.uptime))
                .font(.system(size: 10, design: .serif))
                .foregroundStyle(Theme.dim)
            Text(String(format: "负载 %.2f", monitor.load.first ?? 0))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.dim)
            Button {
                ui.settingsOpen.toggle()
            } label: {
                Image(systemName: ui.settingsOpen ? "chevron.left" : "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(ui.settingsOpen ? Theme.cyan : Theme.dim)
            }
            .buttonStyle(.plain)
            .frame(width: 18)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: 设置分区
    //
    // 注意：这里不能用 ScrollView —— ImageRenderer 画不出 ScrollView 里的内容
    // （离屏渲染整段空白）。内容控制在 580pt 内即可。

    private var settingsBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("菜单栏显示")

            toggleRow("CPU 使用率", Theme.cyan, config.showCPU) { config.showCPU = $0 }
            toggleRow("内存占用", Theme.cyan.opacity(0.85), config.showMem) { config.showMem = $0 }
            toggleRow("网络流速", Theme.jade, config.showNet) { config.showNet = $0 }
            toggleRow("磁盘可用", Theme.amber, config.showDisk) { config.showDisk = $0 }
            toggleRow("系统负载", Theme.cyan, config.showLoad) { config.showLoad = $0 }
            toggleRow("状态栏图标", Theme.jade, config.showIcon) { config.showIcon = $0 }

            sectionTitle("网速样式")
            segmented([("双向", Config.NetMode.both),
                       ("仅下载", Config.NetMode.downOnly),
                       ("仅上传", Config.NetMode.upOnly)],
                      config.bind(\.netMode))
            .padding(.horizontal, 12)

            sectionTitle("刷新间隔")
            segmented([("1秒", 1.0), ("2秒", 2.0), ("3秒", 3.0), ("5秒", 5.0)],
                      config.bind(\.interval))
            .padding(.horizontal, 12)

            // 实时预览菜单栏文本（含图标开关效果）
            VStack(alignment: .leading, spacing: 6) {
                Text("菜单栏预览")
                    .font(.system(size: 10, design: .serif))
                    .foregroundStyle(Theme.dim.opacity(0.8))
                HStack(spacing: 5) {
                    if config.showIcon {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.cyan)
                    }
                    Text(MenuLabel.text(cpu: monitor.cpuPct, memUsed: monitor.memUsed,
                                        netIn: monitor.netIn, netOut: monitor.netOut,
                                        diskFree: monitor.diskFree,
                                        load: monitor.load.first ?? 0, config))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.paper)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(Theme.cell)
                .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 8)
    }

    /// 自制分段控件：Picker(.segmented) 在离屏渲染里会变成禁止符号
    /// （ImageRenderer 画不了 AppKit-backed 控件），按钮式实现两边一致
    private func segmented<T: Equatable>(_ options: [(String, T)],
                                          _ selection: Binding<T>) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, opt in
                Button {
                    selection.wrappedValue = opt.1
                } label: {
                    Text(opt.0)
                        .font(.system(size: 11, design: .serif))
                        .foregroundStyle(selection.wrappedValue == opt.1 ? Theme.bg : Theme.dim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(selection.wrappedValue == opt.1
                                    ? Theme.cyan.opacity(0.85) : Theme.cell)
                }
                .buttonStyle(.plain)
                if i < options.count - 1 {
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                }
            }
        }
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, design: .serif))
            .foregroundStyle(Theme.dim.opacity(0.8))
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private func toggleRow(_ title: String, _ tint: Color, _ on: Bool,
                           _ set: @escaping (Bool) -> Void) -> some View {
        Button {
            set(!on)
        } label: {
            HStack(spacing: 7) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 12, design: .serif))
                    .foregroundStyle(Theme.paper.opacity(0.9))
                Spacer()
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule()
                        .fill(on ? tint.opacity(0.32) : Theme.track)
                        .frame(width: 34, height: 18)
                    Circle()
                        .fill(on ? tint : Theme.dim.opacity(0.55))
                        .frame(width: 14, height: 14)
                        .padding(.horizontal, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var cards: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                card("CPU", Fmt.pct(monitor.cpuPct),
                     "\(ProcessInfo.processInfo.activeProcessorCount) 核",
                     Theme.cyan, bar: monitor.cpuPct / 100)
                card("内存", Fmt.gb(monitor.memUsed),
                     "共 " + Fmt.gb(monitor.memTotal),
                     Theme.cyan.opacity(0.85),
                     bar: monitor.memTotal > 0
                         ? Double(monitor.memUsed) / Double(monitor.memTotal) : 0)
            }
            HStack(spacing: 8) {
                card("下载", Fmt.rate(monitor.netIn),
                     "↑ " + Fmt.rate(monitor.netOut), Theme.jade)
                card("磁盘可用", Fmt.gb(monitor.diskFree), "根卷", Theme.amber)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private func card(_ title: String, _ value: String, _ sub: String,
                      _ tint: Color, bar: Double = -1) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 10, design: .serif))
                    .foregroundStyle(Theme.dim)
                Spacer()
                if bar >= 0 {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.track)
                        Rectangle().fill(tint.opacity(0.85))
                            .frame(width: 44 * min(max(bar, 0), 1))
                    }
                    .frame(width: 44, height: 3)
                }
            }
            Text(value)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.paper)
            Text(sub)
                .font(.system(size: 9.5, design: .serif))
                .foregroundStyle(Theme.dim.opacity(0.7))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cell)
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    private func graphBlock(_ title: String, _ values: [Double], _ color: Color,
                            second: [Double]? = nil,
                            secondColor: Color = Theme.amber) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 10, design: .serif))
                    .foregroundStyle(Theme.dim)
                Spacer()
                if let second {
                    Text("↑ " + Fmt.rate(second.last ?? 0))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(secondColor)
                    Text("↓ " + Fmt.rate(values.last ?? 0))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(color)
                } else {
                    Text(Fmt.pct(values.last ?? 0))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(color)
                }
            }
            Sparkline(values: values, color: color,
                      second: second, secondColor: secondColor)
                .frame(height: 46)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var procBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("进程榜 · 按 CPU")
                    .font(.system(size: 10, design: .serif))
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text("CPU")
                    .frame(width: 38, alignment: .trailing)
                Text("内存")
                    .frame(width: 52, alignment: .trailing)
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(Theme.dim.opacity(0.55))
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ForEach(monitor.procs) { p in
                HStack(spacing: 6) {
                    Circle()
                        .fill(p.cpu > 20 ? Theme.amber : Theme.cyan.opacity(0.7))
                        .frame(width: 4, height: 4)
                    Text(p.name)
                        .font(.system(size: 11, design: .serif))
                        .foregroundStyle(Theme.paper.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 118, alignment: .leading)
                    Spacer(minLength: 4)
                    Text(Fmt.pct(p.cpu))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(p.cpu > 20 ? Theme.amber : Theme.dim)
                        .frame(width: 38, alignment: .trailing)
                    Text(String(format: "%.0fM", Double(p.rss) / 1048576))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.dim.opacity(0.8))
                        .frame(width: 52, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2.5)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("每秒采样 · 全部本地计算")
                .font(.system(size: 9, design: .serif))
                .foregroundStyle(Theme.dim.opacity(0.55))
            Spacer()
            if RenderConfig.isRendering {
                // ImageRenderer 画不了会碰系统服务的控件，渲染时退化为文本
                Text("开机启动")
                    .font(.system(size: 10, design: .serif))
                    .foregroundStyle(Theme.dim.opacity(0.4))
            } else {
                Button {
                    launch.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(launch.on ? Theme.jade : Theme.track)
                            .frame(width: 5, height: 5)
                        Text(launch.on ? "已开机启动" : "开机启动")
                            .font(.system(size: 10, design: .serif))
                    }
                    .foregroundStyle(Theme.dim)
                }
                .buttonStyle(.plain)

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("退出")
                        .font(.system(size: 10, design: .serif))
                        .foregroundStyle(Theme.amber.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

// MARK: - App 委托（菜单栏状态项）
//
// 为什么不用 MenuBarExtra：实测在这个 macOS 版本上，MenuBarExtra 的
// Label(title, systemImage:) 只渲染图标、不渲染文字（最小复现验证过），
// 菜单栏状态根本显示不出来。NSStatusItem 的 button.title 是可靠的。

final class AppDelegate: NSObject, NSApplicationDelegate {
    let config = Config()
    private var monitor: Monitor?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let m = Monitor(sampler: .real, config: config)
        monitor = m
        m.start()

        buildStatusItem()
        buildPopover(m)

        // 指标每秒变，菜单栏文字跟着变。
        // objectWillChange 在 willSet 时触发，sink 里读到的是旧值，
        // 异步到下一个主循环周期再读，拿到的就是新值
        m.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusTitle() }
            }
            .store(in: &cancellables)

        // 显示项 / 图标开关变化时：换图标 + 重算固定宽度
        // （也是异步，避开 willSet 旧值）
        config.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, let btn = self.statusItem?.button else { return }
                    if self.config.showIcon {
                        let img = NSImage(
                            systemSymbolName: "waveform.path.ecg",
                            accessibilityDescription: "潮汐表")
                        img?.isTemplate = true
                        btn.image = img
                    } else {
                        btn.image = nil
                    }
                    self.statusItem?.length = self.fixedLength()
                }
            }
            .store(in: &cancellables)
    }

    /// 固定宽度：按当前配置的最宽可能文本测量。
    /// variableLength 会让按钮宽度跟着数字涨落抖动，图标被推着晃；
    /// 锁死宽度后只有框内数字在变。
    /// 内边距 38/20 是探针实测值（见 MenuLabel.fixedLength）
    private func fixedLength() -> CGFloat {
        let font = NSFont.menuBarFont(ofSize: 0)
        let textW = (MenuLabel.widestText(config) as NSString)
            .size(withAttributes: [.font: font]).width
        return MenuLabel.fixedLength(textW: textW, showIcon: config.showIcon)
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: fixedLength())
        if let btn = item.button {
            if config.showIcon {
                btn.image = NSImage(systemSymbolName: "waveform.path.ecg",
                                    accessibilityDescription: "潮汐表")
                btn.image?.isTemplate = true
            }
            btn.action = #selector(togglePopover)
            btn.target = self
        }
        statusItem = item
        updateStatusTitle()
    }

    private func buildPopover(_ m: Monitor) {
        let p = NSPopover()
        p.behavior = .transient          // 点外面自动收起
        p.contentSize = NSSize(width: 320, height: 580)
        p.contentViewController = NSHostingController(
            rootView: PanelView(monitor: m, config: config)
                .frame(width: 320, height: 580)
        )
        popover = p
    }

    private func updateStatusTitle() {
        guard let m = monitor, let btn = statusItem?.button else { return }
        btn.title = MenuLabel.text(cpu: m.cpuPct, memUsed: m.memUsed,
                                   netIn: m.netIn, netOut: m.netOut,
                                   diskFree: m.diskFree,
                                   load: m.load.first ?? 0, config)
    }

    @objc func togglePopover() {
        guard let p = popover, let btn = statusItem?.button else { return }
        if p.isShown {
            p.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            p.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            p.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - 入口（菜单栏 + CLI）

@main
struct TideGaugeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        let mode = Entry.resolveMode()
        RenderConfig.mode = mode
        RenderConfig.showSettings = CommandLine.arguments.contains("--settings")
        switch mode {
        case .app:
            break   // 菜单栏状态项由 AppDelegate 搭建
        case .test:
            Entry.runTests()
        case .render:
            let a = CommandLine.arguments
            guard let i = a.firstIndex(of: "--render"), a.count > i + 1 else { exit(2) }
            Entry.render(Monitor(sampler: Sampler.fake), Config(), a[i + 1])
        }
    }

    var body: some Scene {
        // 纯菜单栏应用：不放任何可见场景（Settings 不会自动开）
        Settings { EmptyView() }
    }
}

// MARK: - 自检 / 离屏渲染

enum Entry {
    static func resolveMode() -> RunMode {
        let a = CommandLine.arguments
        if a.contains("--selftest") { return .test }
        if a.contains("--render") { return .render }
        return .app
    }

    static func runTests() {
        let m = Monitor(sampler: Sampler.fake)
        var pass = 0
        var fail: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if ok { pass += 1; print("PASS  \(name)") }
            else { fail.append(name); print("FAIL  \(name)") }
        }
        // 按 1 秒间隔灌 80 拍，和真实定时器节奏一致
        var clock = Date()
        for _ in 0..<80 { clock.addTimeInterval(1); m.tick(at: clock) }

        // —— 假数据链 ——
        check("CPU 历史封顶 60 点", m.cpuHist.count == 60)
        check("CPU 百分比在 0…100", m.cpuHist.allSatisfy { $0 >= 0 && $0 <= 100 })
        check("CPU 有负载", m.cpuPct > 0)
        check("内存曲线 60 点且为正",
              m.memHist.count == 60 && m.memHist.allSatisfy { $0 > 0 })
        check("下行速率合理", m.netIn > 100_000 && m.netIn < 2_000_000)
        check("上行速率合理", m.netOut > 10_000 && m.netOut < 500_000)
        check("进程榜取前 8", m.procs.count == 8)
        check("进程按 CPU 降序",
              zip(m.procs, m.procs.dropFirst()).allSatisfy { $0.cpu >= $1.cpu })
        check("排除自身进程", m.procs.allSatisfy { $0.pid != getpid() })
        check("进程 CPU 非零", m.procs[0].cpu > 0)

        let m2 = Monitor(sampler: Sampler.fake)
        var clock2 = Date()
        for _ in 0..<80 { clock2.addTimeInterval(1); m2.tick(at: clock2) }
        check("确定性输出",
              m.cpuHist == m2.cpuHist && m.procs.map(\.cpu) == m2.procs.map(\.cpu))

        // —— 格式化 ——
        check("uptime 3天4小时", Fmt.uptime(3 * 86400 + 4 * 3600 + 5 * 60) == "3天4小时")
        check("uptime 5小时12分", Fmt.uptime(5 * 3600 + 12 * 60) == "5小时12分")
        check("rate 500B/s", Fmt.rate(500) == "500B/s")
        check("rate 1.5K → 1K/s", Fmt.rate(1500) == "1K/s")
        check("rate 2M → 1.9M/s", Fmt.rate(2_000_000) == "1.9M/s")
        check("gb 3.4G", Fmt.gb(3_400_000_000) == "3.4G")
        check("pct 12.4 → 12%", Fmt.pct(12.4) == "12%")

        // —— 真实采样器冒烟：自检同时验证系统 API 通路 ——
        let rc = Sampler.real.cpu()
        check("真实 CPU 计数器", rc.idle > 0 && rc.user > 0)
        let rm = Sampler.real.memory()
        check("真实内存总量 > 1GB", rm.total > 1_000_000_000)
        check("真实内存已用 > 0", rm.used > 0)
        check("真实网络计数器", Sampler.real.network().inBytes > 0)
        let rp = Sampler.real.processes()
        check("真实进程列表 > 5", rp.count > 5)
        check("真实进程有内存值", rp.contains { $0.rss > 0 })
        check("真实磁盘", Sampler.real.disk() > 0)
        check("真实运行时间", Sampler.real.boot() > 60)
        check("真实负载 3 项", Sampler.real.load().count == 3)

        // —— 配置与菜单栏文本 ——
        // 上一次自检若中途失败，可能把 defaults 污染成非默认值，先重置
        let reset = Config()
        reset.showCPU = true; reset.showMem = true; reset.showNet = true
        reset.showDisk = false; reset.showLoad = false; reset.showIcon = true
        reset.netMode = .both; reset.interval = 1.0
        let c = Config()
        check("默认显示 CPU/内存/网速", c.showCPU && c.showMem && c.showNet)
        check("默认不显示磁盘/负载", !c.showDisk && !c.showLoad)
        check("默认显示图标", c.showIcon)
        check("默认间隔 1 秒", c.interval == 1.0)
        check("默认网速双向", c.netMode == .both)

        let sample = (cpu: 20.0, mem: 7_500_000_000 as UInt64,
                      inB: 510_000.0, outB: 198_000.0, disk: 128_000_000_000 as UInt64)
        let all = MenuLabel.text(cpu: sample.cpu, memUsed: sample.mem,
                                 netIn: sample.inB, netOut: sample.outB,
                                 diskFree: sample.disk, load: 1.24, c)
        check("全开：CPU+内存+双向网速",
              all.contains("20%") && all.contains("7.5G")
              && all.contains("↑193K↓498K"))

        c.netMode = .upOnly
        let up = MenuLabel.text(cpu: sample.cpu, memUsed: sample.mem,
                                netIn: sample.inB, netOut: sample.outB,
                                diskFree: sample.disk, load: 1.24, c)
        check("仅上传：有 ↑ 无 ↓", up.contains("↑193K") && !up.contains("↓"))
        c.netMode = .downOnly
        let down = MenuLabel.text(cpu: sample.cpu, memUsed: sample.mem,
                                  netIn: sample.inB, netOut: sample.outB,
                                  diskFree: sample.disk, load: 1.24, c)
        check("仅下载：有 ↓ 无 ↑", down.contains("↓498K") && !down.contains("↑"))
        c.netMode = .both

        c.showNet = false; c.showCPU = false
        let memOnly = MenuLabel.text(cpu: sample.cpu, memUsed: sample.mem,
                                     netIn: sample.inB, netOut: sample.outB,
                                     diskFree: sample.disk, load: 1.24, c)
        check("只开内存时只有一项", memOnly == "7.5G")
        c.showDisk = true
        let withDisk = MenuLabel.text(cpu: sample.cpu, memUsed: sample.mem,
                                      netIn: sample.inB, netOut: sample.outB,
                                      diskFree: sample.disk, load: 1.24, c)
        check("开磁盘后追加容量", withDisk == "7.5G  128.0G")
        c.showDisk = false; c.showNet = true; c.showCPU = true

        // 持久化：改一项 → 新实例应读回
        c.interval = 2.0
        c.showCPU = false
        c.showIcon = false
        let c2 = Config()
        check("配置持久化（间隔/开关/图标）",
              c2.interval == 2.0 && !c2.showCPU && !c2.showIcon)
        c.interval = 1.0
        c.showCPU = true
        c.showIcon = true
        check("还原后读回默认", Config().interval == 1.0 && Config().showCPU && Config().showIcon)

        // —— 固定宽度（防菜单栏图标抖动）——
        // 注意：用例里每个 Config 都要显式设全部开关——Config 的 didSet 会写
        // UserDefaults，上一个用例的状态会污染下一个用例的默认值
        // 极端值贴现实：容量到 999G、网速到 95M（≈100M/s 以内）、负载到
        // 99.99——都落在最宽文本内。超过 99.9M 会多 1 个字符，fixedLength
        // 的 6% 余量能兜一个方向，收发同时爆会轻微截断
        let extremes: [(Double, UInt64, Double, Double, UInt64, Double)] = [
            (100, 999_000_000_000, 99_999_999, 99_999_999, 999_000_000_000, 99.99),
            (0, 0, 0, 0, 0, 0),
            (99.9, 16_000_000_000, 9_999_999, 9_999_999, 128_000_000_000, 1.24)
        ]
        func fresh(_ setup: (Config) -> Void) -> Config {
            let c = Config()
            c.showCPU = false; c.showMem = false; c.showNet = false
            c.showDisk = false; c.showLoad = false; c.showIcon = true
            c.netMode = .both
            setup(c)
            return c
        }
        let cfgs: [Config] = [
            fresh { $0.showCPU = true; $0.showMem = true; $0.showNet = true },
            fresh { $0.showMem = true },
            fresh { $0.showCPU = true; $0.showMem = true; $0.showNet = true
                    $0.showDisk = true; $0.showLoad = true },
            fresh { $0.showCPU = true }
        ]
        var widestOK = true
        for cfg in cfgs {
            for ex in extremes {
                let t = MenuLabel.text(cpu: ex.0, memUsed: ex.1, netIn: ex.2,
                                       netOut: ex.3, diskFree: ex.4, load: ex.5, cfg)
                if t.count > MenuLabel.widestText(cfg).count { widestOK = false }
            }
        }
        check("极端值也不超过最宽文本", widestOK)
        check("只开 CPU 时最宽即 100%",
              MenuLabel.widestText(fresh { $0.showCPU = true }) == "100%")
        check("全开时最宽含全部段", {
            let w = MenuLabel.widestText(fresh {
                $0.showCPU = true; $0.showMem = true; $0.showNet = true
                $0.showDisk = true; $0.showLoad = true })
            return w.contains("100%") && w.contains("999.9G")
                && w.contains("↑99.9M↓99.9M") && w.contains("99.99")
        }())
        check("仅下载时最宽只有下行", {
            let c = fresh { $0.showCPU = true; $0.showMem = true; $0.showNet = true
                            $0.netMode = .downOnly }
            return MenuLabel.widestText(c) == "100%  999.9G  ↓99.9M"
        }())

        // —— 固定宽度公式（内边距为探针实测值）——
        // 带图标 = 文字宽 + 38，纯文字 = 文字宽 + 20，各自 ×1.06 余量
        check("无图标比带图标窄（同一文本）", {
            let w: CGFloat = 97      // "↑99.9M↓99.9M" 实测文字宽
            return MenuLabel.fixedLength(textW: w, showIcon: false)
                 < MenuLabel.fixedLength(textW: w, showIcon: true)
        }())
        check("固定宽度数值符合实测内边距", {
            let w: CGFloat = 97
            return MenuLabel.fixedLength(textW: w, showIcon: true) == 144   // (97+38)*1.06
                && MenuLabel.fixedLength(textW: w, showIcon: false) == 125  // (97+20)*1.06
        }())
        check("固定宽度覆盖最宽文本的内边距", {
            // 最宽文本按各自模式都要放得下：fixed ≥ 文字宽 + 内边距
            let font = NSFont.menuBarFont(ofSize: 0)
            for icon in [true, false] {
                let c = fresh {
                    $0.showCPU = true; $0.showMem = true; $0.showNet = true
                    $0.showDisk = true; $0.showLoad = true
                    $0.showIcon = icon
                }
                let tw = (MenuLabel.widestText(c) as NSString)
                    .size(withAttributes: [.font: font]).width
                if MenuLabel.fixedLength(textW: tw, showIcon: icon) < tw + (icon ? 38 : 20) {
                    return false
                }
            }
            return true
        }())

        // 还原默认配置，别让自检污染 app 下次启动的显示
        let restore = fresh {
            $0.showCPU = true; $0.showMem = true; $0.showNet = true
            $0.showDisk = false; $0.showLoad = false
            $0.showIcon = true
            $0.netMode = .both; $0.interval = 1.0
        }
        check("自检后配置恢复默认",
              restore.showCPU && restore.showMem && restore.showNet
              && !restore.showDisk && !restore.showLoad && restore.showIcon
              && restore.interval == 1.0)

        print(fail.isEmpty
              ? "自检通过 \(pass)/\(pass)"
              : "自检失败 \(fail.count) 项: \(fail.joined(separator: ", "))")
        exit(fail.isEmpty ? 0 : 1)
    }

    static func render(_ m: Monitor, _ cfg: Config, _ path: String) {
        // 必须按 1 秒间隔灌历史：紧密循环会把 dt 钳到 1ms，速率全部爆表
        var clock = Date()
        for _ in 0..<80 { clock.addTimeInterval(1); m.tick(at: clock) }
        MainActor.assumeIsolated {
            let view = PanelView(monitor: m, config: cfg)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                print("已渲染 \(path)")
            }
        }
        exit(0)
    }
}
