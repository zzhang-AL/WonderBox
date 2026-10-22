import Darwin
import Foundation

/// Graphics memory the kernel charges to a task: Metal buffers, textures and the IOSurfaces it owns.
/// On Apple Silicon the GPU shares system memory, so this is the process's "video memory". Pages
/// count once they are resident, so an allocation that was never written to does not show up yet.
public struct GraphicsMemory: Codable, Equatable, Sendable {
    /// Graphics pages charged to the process footprint and resident in RAM.
    public var resident: UInt64
    /// Graphics pages charged to the footprint but currently compressed.
    public var compressed: UInt64
    /// Purgeable (volatile) graphics pages; not charged, and reclaimable under memory pressure.
    public var purgeable: UInt64

    public init(resident: UInt64 = 0, compressed: UInt64 = 0, purgeable: UInt64 = 0) {
        self.resident = resident
        self.compressed = compressed
        self.purgeable = purgeable
    }

    public var total: UInt64 { resident &+ compressed }
    public var isEmpty: Bool { total == 0 && purgeable == 0 }

    public static func + (lhs: GraphicsMemory, rhs: GraphicsMemory) -> GraphicsMemory {
        GraphicsMemory(resident: lhs.resident &+ rhs.resident,
                       compressed: lhs.compressed &+ rhs.compressed,
                       purgeable: lhs.purgeable &+ rhs.purgeable)
    }
}

public enum GraphicsMemoryLedger {
    /// Reads the task's graphics ledgers through a task *name* port. That needs no entitlement for
    /// processes of the current user; other users' processes (WindowServer) need root.
    public static func read(pid: pid_t) -> GraphicsMemory? {
        var task: mach_port_name_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &task) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, task) }

        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        func bytes(_ value: Int64) -> UInt64 { UInt64(max(0, value)) }
        return GraphicsMemory(
            resident: bytes(info.ledger_tag_graphics_footprint),
            compressed: bytes(info.ledger_tag_graphics_footprint_compressed),
            purgeable: bytes(info.ledger_tag_graphics_nofootprint) &+ bytes(info.ledger_tag_graphics_nofootprint_compressed)
        )
    }

    /// Every readable process that holds graphics memory.
    public static func readAll() -> [pid_t: GraphicsMemory] {
        var result: [pid_t: GraphicsMemory] = [:]
        for pid in processIdentifiers() {
            if let memory = read(pid: pid), !memory.isEmpty { result[pid] = memory }
        }
        return result
    }

    /// One "pid resident compressed purgeable" line per process: the maintenance helper's wire format.
    public static func encode(_ entries: [pid_t: GraphicsMemory]) -> String {
        entries.keys.sorted().compactMap { pid in
            entries[pid].map { "\(pid) \($0.resident) \($0.compressed) \($0.purgeable)" }
        }.joined(separator: "\n")
    }

    public static func decode(_ text: String) -> [pid_t: GraphicsMemory] {
        var result: [pid_t: GraphicsMemory] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            guard fields.count == 4, let pid = pid_t(fields[0]), pid > 0,
                  let resident = UInt64(fields[1]), let compressed = UInt64(fields[2]), let purgeable = UInt64(fields[3])
            else { continue }
            result[pid] = GraphicsMemory(resident: resident, compressed: compressed, purgeable: purgeable)
        }
        return result
    }

    private static func processIdentifiers() -> [pid_t] {
        let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytesNeeded > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(bytesNeeded) / MemoryLayout<pid_t>.size + 32)
        let bytesWritten = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard bytesWritten > 0 else { return [] }
        return buffer.prefix(Int(bytesWritten) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }
}
