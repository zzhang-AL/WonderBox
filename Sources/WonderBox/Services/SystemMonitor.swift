import Darwin
import Foundation
import IOKit
import IOKit.ps
import Metal

struct SystemInformation: Sendable {
    let computerName: String
    let modelIdentifier: String
    let processorName: String
    let graphicsName: String
    let operatingSystem: String
    let architecture: String
    let efficiencyCores: Int
    let performanceCores: Int

    static let current: SystemInformation = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return SystemInformation(
            computerName: Host.current().localizedName ?? "Mac",
            modelIdentifier: sysctlString("hw.model") ?? "Mac",
            processorName: sysctlString("machdep.cpu.brand_string") ?? sysctlString("hw.model") ?? "Apple Silicon",
            graphicsName: MTLCreateSystemDefaultDevice()?.name ?? "GPU",
            operatingSystem: os,
            architecture: sysctlString("hw.machine") ?? "arm64",
            // Apple Silicon: perflevel0 = performance, perflevel1 = efficiency. Intel reports neither.
            efficiencyCores: sysctlInt("hw.perflevel1.logicalcpu") ?? 0,
            performanceCores: sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        )
    }()

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

struct SystemCounters: Sendable {
    let cpuTotal: UInt64
    let cpuIdle: UInt64
    let receivedBytes: UInt64
    let sentBytes: UInt64
    let sampledAt: Date
    /// Per-core user/system/idle/nice ticks, as reported by `host_processor_info`.
    var coreTicks: [[UInt32]] = []
    var interfaces: [String: InterfaceCounter] = [:]
    var disk: DiskReading? = nil
}

/// Free space is answered by the CacheDelete service and is far costlier than every other metric;
/// it changes slowly, so readings are reused for a while.
struct DiskReading: Sendable {
    let used: UInt64
    let total: UInt64
    let readAt: Date
    static let lifetime: TimeInterval = 30
}

struct InterfaceCounter: Sendable {
    let received: UInt64
    let sent: UInt64
}

struct SystemSample: Sendable {
    let snapshot: MetricSnapshot
    let counters: SystemCounters
}

enum SystemMonitor {
    /// `refreshDisk` forces a fresh free-space reading, e.g. after a cleanup.
    static func sample(previous: SystemCounters?, refreshDisk: Bool = false) -> SystemSample {
        let cores = coreTicks()
        let cpu = totals(of: cores)
        let interfaces = interfaceCounters()
        let physical = interfaces.filter { NetworkInterfaceUsage.isPhysical($0.key) }.values
        let now = Date()
        let disk: DiskReading
        if !refreshDisk, let cached = previous?.disk, now.timeIntervalSince(cached.readAt) < DiskReading.lifetime {
            disk = cached
        } else {
            let reading = diskUsage()
            disk = DiskReading(used: reading.used, total: reading.total, readAt: now)
        }
        let counters = SystemCounters(
            cpuTotal: cpu.total,
            cpuIdle: cpu.idle,
            receivedBytes: physical.reduce(0) { $0 &+ $1.received },
            sentBytes: physical.reduce(0) { $0 &+ $1.sent },
            sampledAt: now,
            coreTicks: cores,
            interfaces: interfaces,
            disk: disk
        )

        let cpuUsage: Double
        if let previous,
           counters.cpuTotal >= previous.cpuTotal,
           counters.cpuIdle >= previous.cpuIdle {
            let totalDelta = counters.cpuTotal - previous.cpuTotal
            let idleDelta = counters.cpuIdle - previous.cpuIdle
            cpuUsage = totalDelta > 0 ? Double(totalDelta - min(totalDelta, idleDelta)) / Double(totalDelta) : 0
        } else {
            cpuUsage = 0
        }

        let elapsed = max(0.1, now.timeIntervalSince(previous?.sampledAt ?? now))
        let down = delta(current: counters.receivedBytes, previous: previous?.receivedBytes)
        let up = delta(current: counters.sentBytes, previous: previous?.sentBytes)
        let battery = batteryDetails()
        let gpu = gpuStatistics()
        let split = cpuSplit(current: cores, previous: previous?.coreTicks ?? [])

        var snapshot = MetricSnapshot(
            cpuUsage: min(1, max(0, cpuUsage)),
            gpuUsage: gpu?.utilization,
            memory: memoryBreakdown(),
            diskUsed: disk.used,
            diskTotal: disk.total,
            networkDownPerSecond: UInt64(Double(down) / elapsed),
            networkUpPerSecond: UInt64(Double(up) / elapsed),
            batteryLevel: battery?.level,
            isCharging: battery.map { $0.isCharging || $0.isPluggedIn } ?? false,
            thermalState: ProcessInfo.processInfo.thermalState,
            uptime: uptime(now: now),
            sampledAt: now
        )
        snapshot.cpuUser = split.user
        snapshot.cpuSystem = split.system
        snapshot.cpuCores = split.cores
        var load = [Double](repeating: 0, count: 3)
        snapshot.loadAverage = getloadavg(&load, 3) == 3 ? load : []
        snapshot.gpuStatistics = gpu?.statistics
        snapshot.networkInterfaces = interfaceUsage(current: interfaces, previous: previous?.interfaces, elapsed: elapsed)
        snapshot.networkReceivedTotal = counters.receivedBytes
        snapshot.networkSentTotal = counters.sentBytes
        snapshot.battery = battery
        return SystemSample(snapshot: snapshot, counters: counters)
    }

    private static func interfaceUsage(current: [String: InterfaceCounter], previous: [String: InterfaceCounter]?,
                                       elapsed: TimeInterval) -> [NetworkInterfaceUsage] {
        current.compactMap { name, counter -> NetworkInterfaceUsage? in
            guard NetworkInterfaceUsage.isRelevant(name), counter.received > 0 || counter.sent > 0 else { return nil }
            let before = previous?[name]
            return NetworkInterfaceUsage(
                name: name,
                downPerSecond: UInt64(Double(delta(current: counter.received, previous: before?.received)) / elapsed),
                upPerSecond: UInt64(Double(delta(current: counter.sent, previous: before?.sent)) / elapsed),
                received: counter.received,
                sent: counter.sent
            )
        }
        .sorted { ($0.downPerSecond + $0.upPerSecond, $0.received) > ($1.downPerSecond + $1.upPerSecond, $1.received) }
    }

    /// Like System Information's “Time since boot”, includes time spent asleep.
    static func uptime(now: Date = Date()) -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else {
            return ProcessInfo.processInfo.systemUptime
        }
        return uptime(bootTime: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000, now: now)
    }

    static func uptime(bootTime: TimeInterval, now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince1970 - bootTime)
    }

    private static func delta(current: UInt64, previous: UInt64?) -> UInt64 {
        guard let previous, current >= previous else { return 0 }
        return current - previous
    }

    /// Per-core ticks in CPU_STATE_USER, SYSTEM, IDLE, NICE order.
    private static func coreTicks() -> [[UInt32]] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { cpu in
            (0..<states).map { UInt32(bitPattern: info[cpu * states + $0]) }
        }
    }

    private static func totals(of cores: [[UInt32]]) -> (total: UInt64, idle: UInt64) {
        cores.reduce((UInt64(0), UInt64(0))) { sum, core in
            (sum.0 + core.reduce(UInt64(0)) { $0 + UInt64($1) }, sum.1 + UInt64(core[Int(CPU_STATE_IDLE)]))
        }
    }

    /// Per-core busy fractions plus the user/system split of the whole machine.
    static func cpuSplit(current: [[UInt32]], previous: [[UInt32]]) -> (user: Double, system: Double, cores: [Double]) {
        guard current.count == previous.count, !current.isEmpty else { return (0, 0, []) }
        var user: UInt64 = 0, system: UInt64 = 0, all: UInt64 = 0
        var cores: [Double] = []
        for (now, before) in zip(current, previous) {
            // 32-bit tick counters wrap; wrapping subtraction still yields the elapsed ticks.
            let d = zip(now, before).map { UInt64($0 &- $1) }
            let coreUser = d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_NICE)]
            let coreSystem = d[Int(CPU_STATE_SYSTEM)]
            let total = coreUser + coreSystem + d[Int(CPU_STATE_IDLE)]
            cores.append(total > 0 ? Double(coreUser + coreSystem) / Double(total) : 0)
            user += coreUser
            system += coreSystem
            all += total
        }
        guard all > 0 else { return (0, 0, cores) }
        return (Double(user) / Double(all), Double(system) / Double(all), cores)
    }

    /// Busiest GPU's driver statistics (the utilization Activity Monitor charts), or nil when no
    /// accelerator is registered, e.g. inside a virtual machine.
    private static func gpuStatistics() -> (utilization: Double, statistics: GPUStatistics)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var busiest: (utilization: Double, statistics: GPUStatistics)?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let statistics = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            if let percent = statistics?["Device Utilization %"] as? NSNumber {
                let utilization = min(1, max(0, percent.doubleValue / 100))
                if utilization >= busiest?.utilization ?? 0 {
                    func fraction(_ key: String) -> Double { min(1, max(0, ((statistics?[key] as? NSNumber)?.doubleValue ?? 0) / 100)) }
                    func bytes(_ key: String) -> UInt64 { (statistics?[key] as? NSNumber)?.uint64Value ?? 0 }
                    busiest = (utilization, GPUStatistics(
                        renderer: fraction("Renderer Utilization %"),
                        tiler: fraction("Tiler Utilization %"),
                        memoryInUse: bytes("In use system memory"),
                        memoryAllocated: bytes("Alloc system memory")
                    ))
                }
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return busiest
    }

    static func memoryBreakdown() -> MemoryBreakdown {
        let swap = swapUsage()
        var breakdown = MemoryBreakdown(swapUsed: swap.used, pressure: pressureLevel(), swapTotal: swap.total)
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return breakdown }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)
        // Match Activity Monitor: App Memory = anonymous pages minus purgeable pages.
        let internalPages = UInt64(info.internal_page_count)
        let purgeablePages = UInt64(info.purgeable_count)
        breakdown.app = (internalPages - min(internalPages, purgeablePages)) * page
        breakdown.wired = UInt64(info.wire_count) * page
        breakdown.compressed = UInt64(info.compressor_page_count) * page
        breakdown.cached = UInt64(info.external_page_count) * page
        return breakdown
    }

    private static func swapUsage() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    private static func pressureLevel() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return MemoryPressure(rawValue: Int(level)) ?? .normal
    }

    private static func diskUsage() -> (used: UInt64, total: UInt64) {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        let total = UInt64(max(0, values?.volumeTotalCapacity ?? 0))
        let available = UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))
        return (total > available ? total - available : 0, total)
    }

    /// 64-bit byte counters per interface. `getifaddrs`' `if_data` counters are 32-bit and wrap every 4 GB.
    private static func interfaceCounters() -> [String: InterfaceCounter] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: InterfaceCounter] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if message.ifm_flags & IFF_UP != 0, message.ifm_flags & IFF_LOOPBACK == 0,
                       if_indextoname(UInt32(message.ifm_index), &name) != nil {
                        result[String(cString: name)] = InterfaceCounter(
                            received: message.ifm_data.ifi_ibytes,
                            sent: message.ifm_data.ifi_obytes
                        )
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return result
    }

    private static func batteryDetails() -> BatteryDetails? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Double,
                  let maximum = description[kIOPSMaxCapacityKey] as? Double,
                  maximum > 0
            else { continue }
            let charging = (description[kIOPSIsChargingKey] as? Bool) == true
            let minutes = (charging ? description[kIOPSTimeToFullChargeKey] : description[kIOPSTimeToEmptyKey]) as? Int
            var details = BatteryDetails(
                level: current / maximum,
                isCharging: charging,
                isPluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                isFullyCharged: (description[kIOPSIsChargedKey] as? Bool) == true,
                minutesRemaining: (minutes ?? 0) > 0 ? minutes : nil
            )
            addSmartBatteryReadings(to: &details)
            return details
        }
        return nil
    }

    /// Health, cycle count and power figures from the battery controller. Only the needed keys are
    /// read; copying the whole property table costs several times more.
    private static func addSmartBatteryReadings(to details: inout BatteryDetails) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        func value(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        func number(_ key: String) -> Int64? { (value(key) as? NSNumber)?.int64Value }
        let telemetry = value("PowerTelemetryData") as? [String: Any]
        let battery = value("BatteryData") as? [String: Any]

        details.cycleCount = number("CycleCount").map(Int.init)
        details.designCapacity = (number("DesignCapacity") ?? (battery?["DesignCapacity"] as? NSNumber)?.int64Value).map(Int.init)
        details.fullChargeCapacity = (number("AppleRawMaxCapacity") ?? (battery?["FullChargeCapacity"] as? NSNumber)?.int64Value).map(Int.init)
        if let millivolts = number("Voltage") {
            details.voltage = Double(millivolts) / 1_000
            // Amperage is a signed mA reading that IOKit may hand over as a wrapped unsigned value.
            if let milliamps = number("Amperage") {
                details.batteryPower = Double(millivolts) * Double(Int32(truncatingIfNeeded: milliamps)) / 1_000_000
            }
        }
        if let milliwatts = (telemetry?["SystemLoad"] as? NSNumber)?.int64Value, milliwatts > 0 {
            details.systemPower = Double(milliwatts) / 1_000
        }
        if details.isPluggedIn, let adapter = value("AdapterDetails") as? [String: Any] {
            details.adapterWatts = (adapter["Watts"] as? NSNumber)?.intValue
        }
        if let centidegrees = number("Temperature") ?? number("VirtualTemperature"), centidegrees > 0 {
            details.temperature = Double(centidegrees) / 100
        }
    }
}
