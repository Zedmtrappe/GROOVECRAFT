import Foundation
import CoreMIDI
import Darwin
import GrooveCore

/// Host-time helpers (mach absolute time, the clock CoreMIDI timestamps use).
enum HostClock {
    static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static var now: UInt64 { mach_absolute_time() }

    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    static func ticks(_ seconds: Double) -> UInt64 {
        guard seconds > 0 else { return 0 }
        return UInt64(seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }

    /// Seconds from `anchor` to `host` (negative before the anchor).
    static func interval(from anchor: UInt64, to host: UInt64) -> Double {
        host >= anchor ? seconds(host - anchor) : -seconds(anchor - host)
    }
}

/// A MIDI destination the user can choose.
struct MIDIDestinationInfo: Identifiable, Hashable {
    let id: Int32            // CoreMIDI unique ID (stable across launches)
    let name: String
    let isIAC: Bool
    let isOffline: Bool
}

enum MIDIRoute: Hashable, Codable {
    /// Groovecraft's own virtual source: DAWs list it as an input called "Groovecraft".
    case virtualSource
    /// A specific destination, e.g. the IAC Driver bus or a hardware port.
    case destination(uniqueID: Int32)
}

/// CoreMIDI client: publishes the "Groovecraft" virtual source, lists destinations and sends
/// timestamped messages. Message bytes and timing come from `MIDIScheduler` (GrooveCore).
final class MIDIOutput {
    static let sourceName = "Groovecraft"

    private var client = MIDIClientRef()
    private var outPort = MIDIPortRef()
    private var virtualSource = MIDIEndpointRef()
    private(set) var isReady = false
    private(set) var setupError: String?
    var onSetupChanged: (() -> Void)?

    /// Packet buffer reused for sending (guarded by `sendLock`).
    private let bufferSize = 4096
    private let buffer: UnsafeMutableRawPointer
    private let sendLock = NSLock()

    var route: MIDIRoute = .virtualSource
    private var destination = MIDIEndpointRef()

    init() {
        buffer = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
        setUp()
    }

    deinit {
        buffer.deallocate()
        if virtualSource != 0 { MIDIEndpointDispose(virtualSource) }
        if outPort != 0 { MIDIPortDispose(outPort) }
        if client != 0 { MIDIClientDispose(client) }
    }

    private func setUp() {
        var status = MIDIClientCreateWithBlock(MIDIOutput.sourceName as CFString, &client) { [weak self] notification in
            let id = notification.pointee.messageID
            if id == .msgSetupChanged || id == .msgObjectAdded || id == .msgObjectRemoved {
                DispatchQueue.main.async { self?.refreshDestination(); self?.onSetupChanged?() }
            }
        }
        guard status == noErr else { setupError = "Couldn't start CoreMIDI (error \(status))."; return }
        status = MIDIOutputPortCreate(client, "Groovecraft Out" as CFString, &outPort)
        guard status == noErr else { setupError = "Couldn't create a MIDI output port (error \(status))."; return }
        status = MIDISourceCreate(client, MIDIOutput.sourceName as CFString, &virtualSource)
        if status != noErr {
            // Virtual sources can fail in restricted environments; destinations (IAC) still work.
            setupError = "The Groovecraft virtual MIDI port couldn't be created (error \(status)). Use the IAC Driver instead."
            virtualSource = 0
        } else {
            // Keep the same identity between launches so DAWs remember the routing.
            let key = "virtualSourceUniqueID"
            let saved = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: key))
            if saved != 0 {
                MIDIObjectSetIntegerProperty(virtualSource, kMIDIPropertyUniqueID, saved)
            }
            var current: Int32 = 0
            MIDIObjectGetIntegerProperty(virtualSource, kMIDIPropertyUniqueID, &current)
            UserDefaults.standard.set(Int(current), forKey: key)
            MIDIObjectSetStringProperty(virtualSource, kMIDIPropertyManufacturer, "Groovecraft" as CFString)
        }
        isReady = true
    }

    var hasVirtualSource: Bool { virtualSource != 0 }

    // MARK: Destinations

    func destinations() -> [MIDIDestinationInfo] {
        var list: [MIDIDestinationInfo] = []
        let count = MIDIGetNumberOfDestinations()
        for i in 0 ..< count {
            let endpoint = MIDIGetDestination(i)
            guard endpoint != 0 else { continue }
            let name = MIDIOutput.string(endpoint, kMIDIPropertyDisplayName) ?? MIDIOutput.string(endpoint, kMIDIPropertyName) ?? "MIDI Destination"
            var uid: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid)
            var offline: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline)
            let iac = name.localizedCaseInsensitiveContains("IAC") || (MIDIOutput.string(endpoint, kMIDIPropertyDriverOwner) ?? "").contains("IAC")
            list.append(MIDIDestinationInfo(id: uid, name: name, isIAC: iac, isOffline: offline != 0))
        }
        return list
    }

    static func string(_ object: MIDIObjectRef, _ property: CFString) -> String? {
        var value: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(object, property, &value)
        guard status == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    func setRoute(_ newRoute: MIDIRoute) {
        sendLock.lock()
        route = newRoute
        sendLock.unlock()
        refreshDestination()
    }

    /// Looks the chosen destination up again (devices come and go).
    func refreshDestination() {
        sendLock.lock()
        defer { sendLock.unlock() }
        destination = 0
        guard case .destination(let uid) = route else { return }
        var object = MIDIObjectRef()
        var type = MIDIObjectType.destination
        if MIDIObjectFindByUniqueID(uid, &object, &type) == noErr, type == .destination {
            destination = object
        }
    }

    /// True when messages actually have somewhere to go.
    var isConnected: Bool {
        switch route {
        case .virtualSource: return virtualSource != 0
        case .destination: return destination != 0
        }
    }

    // MARK: Sending

    /// Sends messages, each at its own host timestamp (0 = now). Called from the scheduling
    /// thread and the main thread (test note, panic).
    func send(_ messages: [(bytes: [UInt8], host: UInt64)]) {
        guard !messages.isEmpty else { return }
        sendLock.lock()
        defer { sendLock.unlock() }
        let list = buffer.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var packet = MIDIPacketListInit(list)
        var count = 0
        for m in messages {
            m.bytes.withUnsafeBufferPointer { b in
                guard let base = b.baseAddress else { return }
                packet = MIDIPacketListAdd(list, bufferSize, packet, m.host, b.count, base)
            }
            count += 1
            // Flush well before the buffer could fill.
            if count >= 64 {
                deliver(list)
                packet = MIDIPacketListInit(list)
                count = 0
            }
        }
        if count > 0 { deliver(list) }
    }

    private func deliver(_ list: UnsafeMutablePointer<MIDIPacketList>) {
        switch route {
        case .virtualSource:
            if virtualSource != 0 { MIDIReceived(virtualSource, list) }
        case .destination:
            if destination != 0 { MIDISend(outPort, destination, list) }
        }
    }

    /// Sends one short drum hit right now (the "Test" button).
    func sendTestNote(channel: Int, note: Int, velocity: Int) {
        let now = HostClock.now
        send([(MIDIBytes.noteOn(channel, note, velocity), now),
              (MIDIBytes.noteOff(channel, note), now + HostClock.ticks(0.15))])
    }

    /// All notes off on every channel, immediately.
    func panic() {
        let now = HostClock.now
        var messages: [(bytes: [UInt8], host: UInt64)] = []
        for bytes in MIDIScheduler.panicMessages() { messages.append((bytes, now)) }
        send(messages)
        if case .destination = route, destination != 0 { MIDIFlushOutput(destination) }
    }
}

/// The real-time MIDI playback thread. It asks the scheduler for everything due within a few
/// milliseconds and hands CoreMIDI the exact host timestamps, so timing doesn't depend on
/// the UI or on timer accuracy.
final class MIDIPlaybackThread {
    private let output: MIDIOutput
    private let lock = NSLock()
    private var scheduler: MIDIScheduler?
    private var anchor: UInt64 = 0
    private var thread: Thread?
    private var running = false
    /// How far ahead messages are timestamped (seconds).
    var lookahead: Double = 0.004
    /// Called (on the scheduling thread) when note-ons are sent, for the activity light.
    var onActivity: (() -> Void)?

    init(output: MIDIOutput) { self.output = output }

    /// Starts sending. `anchor` is the host time of transport time 0.
    func start(scheduler newScheduler: MIDIScheduler, anchor hostAnchor: UInt64, initial: [ScheduledMIDI]) {
        stop(sendRelease: true)
        lock.lock()
        scheduler = newScheduler
        anchor = hostAnchor
        running = true
        lock.unlock()
        send(initial)
        let t = Thread { [weak self] in self?.loop() }
        t.name = "Groovecraft MIDI"
        t.qualityOfService = .userInteractive
        t.threadPriority = 1.0
        thread = t
        t.start()
    }

    private func loop() {
        let period = HostClock.ticks(0.001)
        var next = HostClock.now
        while true {
            lock.lock()
            guard running, let s = scheduler else { lock.unlock(); break }
            let t = HostClock.interval(from: anchor, to: HostClock.now)
            let due = s.process(until: t + lookahead)
            lock.unlock()
            if !due.isEmpty { send(due) }
            next += period
            let now = HostClock.now
            if next < now { next = now + period }
            mach_wait_until(next)
        }
    }

    private func send(_ events: [ScheduledMIDI]) {
        guard !events.isEmpty else { return }
        let now = HostClock.now
        var messages: [(bytes: [UInt8], host: UInt64)] = []
        var noteOn = false
        for e in events {
            let host: UInt64
            if e.time <= 0 {
                let early = anchor >= HostClock.ticks(-e.time) ? anchor - HostClock.ticks(-e.time) : 0
                host = max(now, early)
            } else {
                host = max(now, anchor + HostClock.ticks(e.time))
            }
            messages.append((e.bytes, host))
            if e.bytes.first.map({ $0 & 0xF0 == 0x90 }) ?? false { noteOn = true }
        }
        output.send(messages)
        if noteOn { onActivity?() }
    }

    /// Switches performance without stopping (A/B).
    func swap(plan: PlaybackPlan) {
        lock.lock()
        guard let s = scheduler, running else { lock.unlock(); return }
        let t = HostClock.interval(from: anchor, to: HostClock.now)
        let releases = s.swap(plan: plan, at: t)
        lock.unlock()
        send(releases)
    }

    func update(settings: MIDIOutputSettings) {
        lock.lock()
        scheduler?.update(settings: settings)
        lock.unlock()
    }

    /// Stops and releases every note (plus panic) so nothing hangs.
    func stop(sendRelease: Bool = true) {
        lock.lock()
        let wasRunning = running
        running = false
        let s = scheduler
        scheduler = nil
        let t = HostClock.interval(from: anchor, to: HostClock.now)
        lock.unlock()
        if wasRunning, sendRelease, let s {
            let messages = s.stop(at: t)
            let now = HostClock.now
            output.send(messages.map { ($0.bytes, now) })
        }
        thread = nil
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }
}
