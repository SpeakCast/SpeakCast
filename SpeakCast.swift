import SwiftUI
import CoreAudio
import AVFoundation
import AppKit

// =====================================================================
// MARK: - Core Audio helpers
// =====================================================================

struct AudioDev: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let isBuiltIn: Bool
}

private let systemObject = AudioObjectID(kAudioObjectSystemObject)
private let simpleUID = "com.matinalijani.speakcast.aggregate.simple"
// aggregate devices an older build (when the app was called MultiAudio) may have left behind
private let legacyUIDs = ["com.ardeshir.multiaudio.aggregate.simple", "com.ardeshir.multiaudio.aggregate"]

private func address(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func stringProp(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf)
    guard st == noErr, let s = cf else { return nil }
    return s.takeRetainedValue() as String
}

private func uint32Prop(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
    var addr = address(selector, scope: scope)
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)
    return v
}

private func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
    var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

private func streamCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
    var addr = address(kAudioDevicePropertyStreams, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return 0 }
    return Int(size) / MemoryLayout<AudioStreamID>.size
}

private func allDeviceIDs() -> [AudioDeviceID] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

private func findDevice(uid: String) -> AudioDeviceID? {
    allDeviceIDs().first { stringProp($0, kAudioDevicePropertyDeviceUID) == uid }
}

func listDevices(output: Bool) -> [AudioDev] {
    let scope = output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
    return allDeviceIDs().compactMap { id in
        guard channelCount(id, scope: scope) > 0,
              let uid = stringProp(id, kAudioDevicePropertyDeviceUID),
              let name = stringProp(id, kAudioObjectPropertyName) else { return nil }
        let t = uint32Prop(id, kAudioDevicePropertyTransportType)
        if t == kAudioDeviceTransportTypeAggregate || t == kAudioDeviceTransportTypeVirtual { return nil }
        return AudioDev(id: id, name: name, uid: uid, isBuiltIn: t == kAudioDeviceTransportTypeBuiltIn)
    }
}

private func defaultOutputDevice() -> AudioDeviceID {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id)
    return id
}

private func setDefaultOutputDevice(_ device: AudioDeviceID) {
    var dev = device
    for sel in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
        var addr = address(sel)
        AudioObjectSetPropertyData(systemObject, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
    }
}

private func supportsRate(_ id: AudioDeviceID, _ rate: Double) -> Bool {
    var addr = address(kAudioDevicePropertyAvailableNominalSampleRates)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
    var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ranges) == noErr else { return false }
    return ranges.contains { rate >= $0.mMinimum && rate <= $0.mMaximum }
}

/// Latency the device reports to macOS (device + safety offset + stream), in ms.
/// Hidden processing inside a monitor is NOT included here.
private func reportedLatencyMs(_ id: AudioDeviceID) -> Double {
    let scope = kAudioDevicePropertyScopeOutput
    var frames = Double(uint32Prop(id, kAudioDevicePropertyLatency, scope: scope))
    frames += Double(uint32Prop(id, kAudioDevicePropertySafetyOffset, scope: scope))
    var addr = address(kAudioDevicePropertyStreams, scope: scope)
    var size: UInt32 = 0
    if AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size >= 4 {
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &streams) == noErr, let s = streams.first {
            frames += Double(uint32Prop(s, kAudioStreamPropertyLatency))
        }
    }
    var raddr = address(kAudioDevicePropertyNominalSampleRate)
    var rate = Float64(0)
    var rsize = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(id, &raddr, 0, nil, &rsize, &rate)
    return rate > 0 ? frames / rate * 1000 : 0
}

private func fullSubDeviceUIDs(_ agg: AudioObjectID) -> [String] {
    var addr = address(kAudioAggregateDevicePropertyFullSubDeviceList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(agg, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var cf: Unmanaged<CFArray>?
    var sz = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
    guard AudioObjectGetPropertyData(agg, &addr, 0, nil, &sz, &cf) == noErr, let arr = cf else { return [] }
    return (arr.takeRetainedValue() as NSArray) as? [String] ?? []
}

private func processObject(pid: pid_t) -> AudioObjectID? {
    var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var p = pid
    var obj = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = AudioObjectGetPropertyData(systemObject, &addr, UInt32(MemoryLayout<pid_t>.size), &p, &size, &obj)
    return (st == noErr && obj != AudioObjectID(kAudioObjectUnknown)) ? obj : nil
}

@inline(__always)
private func clamp1(_ x: Float) -> Float { x > 1 ? 1 : (x < -1 ? -1 : x) }

// =====================================================================
// MARK: - Real-time router (Pro engine)
// =====================================================================

struct Route {
    var bufferIndex: Int32 = 0   // first output buffer of this device inside the aggregate
    var gain: Float = 1
    var delay: Int32 = 0         // samples
    var mode: Int32 = 0          // 0 stereo, 1 left, 2 right, 3 mono
}

/// Everything touched from the audio thread lives here as raw memory (no allocation, no locks).
final class RouterCore {
    static let ringSize = 1 << 18
    static let mask = (1 << 18) - 1
    static let maxRoutes = 16
    static let clickCap = 16384

    let ringL: UnsafeMutablePointer<Float>
    let ringR: UnsafeMutablePointer<Float>
    let routes: UnsafeMutablePointer<Route>
    let clickBuf: UnsafeMutablePointer<Float>

    var routeCount = 0
    var writePos = 0
    var masterGain: Float = 1
    var micGain: Float = 0
    var micIndex = -1
    var clickLen = 0
    var clickIdx = 0
    var sampleRate: Double = 48000

    init() {
        ringL = .allocate(capacity: Self.ringSize)
        ringR = .allocate(capacity: Self.ringSize)
        routes = .allocate(capacity: Self.maxRoutes)
        clickBuf = .allocate(capacity: Self.clickCap)
        ringL.initialize(repeating: 0, count: Self.ringSize)
        ringR.initialize(repeating: 0, count: Self.ringSize)
        routes.initialize(repeating: Route(), count: Self.maxRoutes)
        clickBuf.initialize(repeating: 0, count: Self.clickCap)
    }

    deinit {
        ringL.deallocate(); ringR.deallocate(); routes.deallocate(); clickBuf.deallocate()
    }

    func prepare(sampleRate sr: Double) {
        sampleRate = sr
        for i in 0..<Self.ringSize { ringL[i] = 0; ringR[i] = 0 }
        writePos = 0
        let n = min(Int(sr * 0.012), Self.clickCap)
        for i in 0..<n {
            let t = Double(i) / sr
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(max(n - 1, 1)))
            clickBuf[i] = Float(sin(2 * Double.pi * 1800 * t) * hann)
        }
        clickLen = n
        clickIdx = n
    }

    func triggerClick() { clickIdx = 0 }

    func makeBlock() -> AudioDeviceIOBlock {
        return { [unowned self] _, inData, _, outData, _ in
            self.process(inData, outData)
        }
    }

    func process(_ inData: UnsafePointer<AudioBufferList>, _ outData: UnsafeMutablePointer<AudioBufferList>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        let outs = UnsafeMutableAudioBufferListPointer(outData)
        guard outs.count > 0 else { return }

        // silence all outputs, find the frame count
        var frames = Int.max
        for b in outs {
            if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) }
            let ch = max(Int(b.mNumberChannels), 1)
            frames = min(frames, Int(b.mDataByteSize) / (MemoryLayout<Float>.size * ch))
        }
        if frames == Int.max || frames <= 0 { return }

        // system audio (tap) is the LAST input stream, microphone (if any) sits at micIndex
        var tapPtr: UnsafeMutablePointer<Float>? = nil
        var tapCh = 0
        var tapFrames = 0
        var micPtr: UnsafeMutablePointer<Float>? = nil
        var micCh = 0
        var micFrames = 0
        if ins.count >= 1 {
            let t = ins[ins.count - 1]
            tapPtr = t.mData?.assumingMemoryBound(to: Float.self)
            tapCh = Int(t.mNumberChannels)
            tapFrames = Int(t.mDataByteSize) / (MemoryLayout<Float>.size * max(tapCh, 1))
            if micIndex >= 0 && micIndex < ins.count - 1 {
                let m = ins[micIndex]
                micPtr = m.mData?.assumingMemoryBound(to: Float.self)
                micCh = max(Int(m.mNumberChannels), 1)
                micFrames = Int(m.mDataByteSize) / (MemoryLayout<Float>.size * micCh)
            }
        }

        let mask = Self.mask
        let w = writePos
        let g = masterGain
        let mg = micGain

        // 1) mix source (system audio + mic + test click) into the ring buffer
        for i in 0..<frames {
            var l: Float = 0
            var r: Float = 0
            if let tp = tapPtr, i < tapFrames {
                if tapCh >= 2 { l = tp[i * tapCh]; r = tp[i * tapCh + 1] }
                else if tapCh == 1 { l = tp[i]; r = l }
            }
            l *= g
            r *= g
            if let mp = micPtr, i < micFrames {
                let m = mp[i * micCh] * mg
                l += m
                r += m
            }
            if clickIdx < clickLen {
                let c = clickBuf[clickIdx] * 0.6
                l += c
                r += c
                clickIdx += 1
            }
            ringL[(w + i) & mask] = l
            ringR[(w + i) & mask] = r
        }

        // 2) render every device from the ring with its own delay / gain / channel mode
        for d in 0..<routeCount {
            let rt = routes[d]
            let bi = Int(rt.bufferIndex)
            guard bi >= 0, bi < outs.count else { continue }
            let ob = outs[bi]
            guard let op = ob.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let nch = max(Int(ob.mNumberChannels), 1)
            let delay = Int(rt.delay)
            let gain = rt.gain
            let mode = rt.mode
            for i in 0..<frames {
                let idx = (w + i - delay) & mask
                let l = ringL[idx]
                let r = ringR[idx]
                var a = l
                var b = r
                switch mode {
                case 1: b = l
                case 2: a = r
                case 3: let m = (l + r) * 0.5; a = m; b = m
                default: break
                }
                a = clamp1(a * gain)
                b = clamp1(b * gain)
                if nch == 1 {
                    op[i] = (a + b) * 0.5
                } else {
                    op[i * nch] = a
                    op[i * nch + 1] = b
                }
            }
        }
        writePos = (w + frames) & mask
    }
}

// =====================================================================
// MARK: - Manager
// =====================================================================

enum EngineMode: String, CaseIterable {
    case pro, simple
}

struct DevSettings: Codable {
    var mode = 0            // 0 stereo, 1 left, 2 right, 3 mono
    var gain: Float = 1
    var delayMs: Double = 0
}

@MainActor
final class AudioManager: ObservableObject {
    @Published var devices: [AudioDev] = []
    @Published var inputs: [AudioDev] = []
    @Published var selected: Set<String> = []
    @Published var settings: [String: DevSettings] = [:]
    @Published var engineMode: EngineMode = .pro
    @Published var sampleRate: Double = 0          // 0 = auto
    @Published var bufferFrames: UInt32 = 256
    @Published var rateOptions: [Double] = []
    @Published var latencyMs: [String: Double] = [:]
    @Published var masterGain: Float = 1
    @Published var muted = false
    @Published var micOn = false
    @Published var micUID = ""
    @Published var micGain: Float = 0.7
    @Published var testClick = false
    @Published var active = false
    @Published var status = "Ready"

    private let core = RouterCore()
    private var aggregateID: AudioObjectID = 0
    private var tapID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private var routeIndex: [String: Int] = [:]
    private var activeRate: Double = 48000
    private var previousDefault: AudioDeviceID = 0
    private var simpleActive = false
    private var wantActive = false
    private var waitingForDevice = false   // paused because a selected output disappeared
    private var termSource: DispatchSourceSignal?
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var clickTimer: Timer?
    private var reconcileWork: DispatchWorkItem?

    init() {
        let ud = UserDefaults.standard
        selected = Set(ud.stringArray(forKey: "selected") ?? [])
        if let d = ud.data(forKey: "settings"),
           let s = try? JSONDecoder().decode([String: DevSettings].self, from: d) { settings = s }
        engineMode = EngineMode(rawValue: ud.string(forKey: "engine") ?? "") ?? .pro
        sampleRate = ud.double(forKey: "rate")
        let b = ud.integer(forKey: "buf")
        bufferFrames = b > 0 ? UInt32(b) : 256
        masterGain = (ud.object(forKey: "master") as? Float) ?? 1
        micGain = (ud.object(forKey: "micGain") as? Float) ?? 0.7
        micOn = ud.bool(forKey: "micOn")
        micUID = ud.string(forKey: "micUID") ?? ""

        // remove aggregates a previous run might have left behind
        for uid in [simpleUID] + legacyUIDs {
            if let old = findDevice(uid: uid) { AudioHardwareDestroyAggregateDevice(old) }
        }
        refresh()

        var addr = address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(systemObject, &addr, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.deviceListChanged() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }

        // quit cleanly on SIGTERM (e.g. when build.sh replaces a running copy)
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.stopAll() }
            exit(0)
        }
        src.resume()
        termSource = src
    }

    // MARK: persistence / refresh

    func save() {
        let ud = UserDefaults.standard
        ud.set(Array(selected), forKey: "selected")
        if let d = try? JSONEncoder().encode(settings) { ud.set(d, forKey: "settings") }
        ud.set(engineMode.rawValue, forKey: "engine")
        ud.set(sampleRate, forKey: "rate")
        ud.set(Int(bufferFrames), forKey: "buf")
        ud.set(masterGain, forKey: "master")
        ud.set(micGain, forKey: "micGain")
        ud.set(micOn, forKey: "micOn")
        ud.set(micUID, forKey: "micUID")
    }

    func refresh() {
        devices = listDevices(output: true)
        inputs = listDevices(output: false)
        var lat: [String: Double] = [:]
        for d in devices { lat[d.uid] = reportedLatencyMs(d.id) }
        latencyMs = lat
        if micUID.isEmpty || !inputs.contains(where: { $0.uid == micUID }) {
            if micUID.isEmpty { micUID = inputs.first(where: { $0.isBuiltIn })?.uid ?? inputs.first?.uid ?? "" }
        }
        computeRates()
    }

    private func computeRates() {
        let devs = devices.filter { selected.contains($0.uid) }
        guard !devs.isEmpty else { rateOptions = []; return }
        let candidates: [Double] = [44100, 48000, 88200, 96000, 176400, 192000]
        rateOptions = candidates.filter { r in devs.allSatisfy { supportsRate($0.id, r) } }
    }

    private func chosenRate() -> Double {
        if sampleRate > 0, rateOptions.contains(sampleRate) { return sampleRate }
        if let best = rateOptions.filter({ $0 <= 96000 }).max() { return best }
        return rateOptions.first ?? 48000
    }

    private func deviceListChanged() {
        reconcileWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        reconcileWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    private func reconcile() {
        refresh()
        guard wantActive else { return }
        let missing = selected.subtracting(Set(devices.map(\.uid)))
        if active && !missing.isEmpty {
            teardown()
            waitingForDevice = true
            status = "An output was disconnected. Waiting for it to reconnect…"
        } else if waitingForDevice && !active && missing.isEmpty
                    && selected.count >= (engineMode == .simple ? 2 : 1) {
            waitingForDevice = false
            start()
        }
    }

    // MARK: user actions

    func toggle(_ dev: AudioDev) {
        if selected.contains(dev.uid) { selected.remove(dev.uid) } else { selected.insert(dev.uid) }
        save()
        computeRates()
        if active { start() }
    }

    func update(_ uid: String, _ f: (inout DevSettings) -> Void) {
        var s = settings[uid] ?? DevSettings()
        f(&s)
        settings[uid] = s
        save()
        pushRoute(uid)
    }

    private func pushRoute(_ uid: String) {
        guard let i = routeIndex[uid] else { return }
        let s = settings[uid] ?? DevSettings()
        core.routes[i].gain = s.gain
        core.routes[i].mode = Int32(s.mode)
        let ms = min(max(s.delayMs, 0), 500)
        core.routes[i].delay = Int32(ms * activeRate / 1000)
    }

    func pushMaster() {
        core.masterGain = muted ? 0 : masterGain
        core.micGain = micOn ? micGain : 0
        save()
    }

    func engineChanged() { save(); if active { start() } }
    func formatChanged() { save(); if active { start() } }

    func setMic(_ on: Bool) {
        micOn = on
        save()
        if active { start() }
    }

    func setTestClick(_ on: Bool) {
        testClick = on
        clickTimer?.invalidate()
        clickTimer = nil
        guard on, active, engineMode == .pro else { return }
        core.triggerClick()
        clickTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.core.triggerClick() }
        }
    }

    // MARK: start / stop

    func start() {
        wantActive = true
        waitingForDevice = false
        if micOn {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if !granted {
                        self.micOn = false
                        self.status = "Microphone access denied (System Settings > Privacy & Security > Microphone)"
                    }
                    self.launch()
                }
            }
        } else {
            launch()
        }
    }

    private func launch() {
        if engineMode == .pro { startPro() } else { startSimple() }
    }

    func stopAll() {
        wantActive = false
        waitingForDevice = false
        teardown()
        status = "Stopped"
    }

    private func teardown() {
        clickTimer?.invalidate()
        clickTimer = nil
        stopSimpleMic()
        if let p = procID {
            AudioDeviceStop(aggregateID, p)
            AudioDeviceDestroyIOProcID(aggregateID, p)
            procID = nil
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        if simpleActive {
            if previousDefault != 0 { setDefaultOutputDevice(previousDefault) }
            simpleActive = false
        }
        if let old = findDevice(uid: simpleUID) { AudioHardwareDestroyAggregateDevice(old) }
        routeIndex = [:]
        core.routeCount = 0
        active = false
    }

    private func configureAggregate(_ agg: AudioObjectID) -> Double {
        var rate = Float64(chosenRate())
        var a = address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectSetPropertyData(agg, &a, 0, nil, UInt32(MemoryLayout<Float64>.size), &rate)
        var frames = bufferFrames
        var b = address(kAudioDevicePropertyBufferFrameSize)
        AudioObjectSetPropertyData(agg, &b, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        var actual = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(agg, &a, 0, nil, &size, &actual)
        return actual > 0 ? actual : rate
    }

    // MARK: Pro engine (system-audio tap + one clock + per-device delay)

    private func startPro() {
        teardown()
        let outs = devices.filter { selected.contains($0.uid) }
        guard !outs.isEmpty else { status = "Select at least one output"; return }

        // we must exclude ourselves from the tap, otherwise our own output would feed back
        guard let me = processObject(pid: getpid()) else {
            status = "Couldn't exclude this app from the system-audio tap (feedback risk). Use Simple mode instead."
            return
        }
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [me])
        tap.name = "SpeakCast Tap"
        tap.uuid = UUID()
        tap.muteBehavior = CATapMuteBehavior.mutedWhenTapped
        tap.isPrivate = true
        var newTap = AudioObjectID(kAudioObjectUnknown)
        var st = AudioHardwareCreateProcessTap(tap, &newTap)
        guard st == noErr else {
            status = "Failed to create the system-audio tap (\(st)). Check the System Audio Recording permission."
            return
        }
        tapID = newTap

        let ordered = outs.sorted { $0.isBuiltIn && !$1.isBuiltIn }
        var uids = ordered.map(\.uid)
        var micDev: AudioDev? = nil
        if micOn, let m = inputs.first(where: { $0.uid == micUID }) {
            micDev = m
            if !uids.contains(m.uid) { uids.append(m.uid) }
        }

        let subs: [[String: Any]] = uids.enumerated().map { pair -> [String: Any] in
            [kAudioSubDeviceUIDKey: pair.element,
             kAudioSubDeviceDriftCompensationKey: pair.offset == 0 ? 0 : 1,
             "drift quality": 0x7F]
        }
        let tapList: [[String: Any]] = [[kAudioSubTapUIDKey: tap.uuid.uuidString,
                                         kAudioSubTapDriftCompensationKey: true]]
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SpeakCast Router",
            kAudioAggregateDeviceUIDKey: "com.matinalijani.speakcast.router.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: uids[0],
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subs,
            kAudioAggregateDeviceTapListKey: tapList
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg)
        guard st == noErr else {
            status = "Failed to create the aggregate device (\(st))"
            teardown()
            return
        }
        aggregateID = agg

        let rate = configureAggregate(agg)
        activeRate = rate
        core.prepare(sampleRate: rate)

        // map every selected device to its output buffer inside the aggregate
        let order = fullSubDeviceUIDs(agg)
        let layout = order.isEmpty ? uids : order
        var outBase = 0
        var inBase = 0
        var micIndex = -1
        var count = 0
        routeIndex = [:]
        for uid in layout {
            guard let did = findDevice(uid: uid) else { continue }
            if outs.contains(where: { $0.uid == uid }), count < RouterCore.maxRoutes {
                routeIndex[uid] = count
                core.routes[count].bufferIndex = Int32(outBase)
                count += 1
            }
            if let m = micDev, m.uid == uid { micIndex = inBase }
            outBase += streamCount(did, scope: kAudioDevicePropertyScopeOutput)
            inBase += streamCount(did, scope: kAudioDevicePropertyScopeInput)
        }
        core.routeCount = count
        core.micIndex = micIndex
        for uid in routeIndex.keys { pushRoute(uid) }
        pushMaster()
        let aggOut = streamCount(agg, scope: kAudioDevicePropertyScopeOutput)

        var pid: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&pid, agg, nil, core.makeBlock())
        guard st == noErr, let p = pid else {
            status = "Failed to create the IOProc (\(st))"
            teardown()
            return
        }
        procID = p
        st = AudioDeviceStart(agg, p)
        guard st == noErr else {
            status = "Failed to start playback (\(st))"
            teardown()
            return
        }
        active = true
        let plural = count == 1 ? "" : "s"
        var msg = "Active (Pro): \(count) output\(plural), \(rateLabel(rate)), buffer \(bufferFrames) frames"
        if aggOut != outBase { msg += " — warning: stream layout mismatch (\(aggOut) vs \(outBase))" }
        status = msg
        if testClick { setTestClick(true) }
    }

    // MARK: Simple engine (stacked Multi-Output device)

    private func startSimple() {
        teardown()
        let chosen = devices.filter { selected.contains($0.uid) }
        guard chosen.count >= 2 else { status = "Select at least two outputs"; return }
        previousDefault = defaultOutputDevice()

        let ordered = chosen.sorted { $0.isBuiltIn && !$1.isBuiltIn }
        let subs: [[String: Any]] = ordered.enumerated().map { pair -> [String: Any] in
            [kAudioSubDeviceUIDKey: pair.element.uid,
             kAudioSubDeviceDriftCompensationKey: pair.offset == 0 ? 0 : 1,
             "drift quality": 0x7F]
        }
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SpeakCast (Auto)",
            kAudioAggregateDeviceUIDKey: simpleUID,
            kAudioAggregateDeviceSubDeviceListKey: subs,
            kAudioAggregateDeviceMainSubDeviceKey: ordered[0].uid,
            kAudioAggregateDeviceIsStackedKey: 1,
            kAudioAggregateDeviceIsPrivateKey: 0
        ]
        var newID = AudioDeviceID(0)
        let st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newID)
        guard st == noErr else { status = "Failed to create the device (\(st))"; return }
        let rate = configureAggregate(newID)
        simpleActive = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.simpleActive else { return }
                setDefaultOutputDevice(newID)
                self.active = true
                self.status = "Active (Simple): \(ordered.count) outputs, \(rateLabel(rate))"
                if self.micOn { self.startSimpleMic() }
            }
        }
    }

    private func startSimpleMic() {
        stopSimpleMic()
        let eng = AVAudioEngine()
        let input = eng.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { status = "No microphone found"; return }
        eng.connect(input, to: eng.mainMixerNode, format: fmt)
        eng.mainMixerNode.outputVolume = micGain
        do {
            try eng.start()
            engine = eng
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: eng, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if self?.micOn == true && self?.simpleActive == true { self?.startSimpleMic() }
                }
            }
        } catch {
            status = "Microphone error: \(error.localizedDescription)"
        }
    }

    private func stopSimpleMic() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine?.stop()
        engine = nil
    }
}

// =====================================================================
// MARK: - UI
// =====================================================================

private func rateLabel(_ r: Double) -> String { String(format: "%g kHz", r / 1000) }

struct DeviceRow: View {
    @EnvironmentObject var m: AudioManager
    let dev: AudioDev

    var body: some View {
        let isOn = m.selected.contains(dev.uid)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: Binding(get: { isOn }, set: { _ in m.toggle(dev) })) {
                    Text(dev.name).lineLimit(1)
                }
                .toggleStyle(.checkbox)
                Spacer()
                if let l = m.latencyMs[dev.uid] {
                    Text(String(format: "Reported %.1f ms", l))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if isOn && m.engineMode == .pro {
                let s = m.settings[dev.uid] ?? DevSettings()
                Picker("", selection: Binding(get: { s.mode },
                                              set: { v in m.update(dev.uid) { $0.mode = v } })) {
                    Text("Stereo").tag(0)
                    Text("Left").tag(1)
                    Text("Right").tag(2)
                    Text("Mono").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack {
                    Image(systemName: "speaker.wave.2")
                    Slider(value: Binding(get: { Double(s.gain) },
                                          set: { v in m.update(dev.uid) { $0.gain = Float(v) } }),
                           in: 0...1.5)
                    Text("\(Int(s.gain * 100))%").font(.caption).frame(width: 44)
                }
                HStack {
                    Image(systemName: "clock")
                    Slider(value: Binding(get: { s.delayMs },
                                          set: { v in m.update(dev.uid) { $0.delayMs = v } }),
                           in: 0...300, step: 0.5)
                    Stepper("", value: Binding(get: { s.delayMs },
                                               set: { v in m.update(dev.uid) { $0.delayMs = v } }),
                            in: 0...300, step: 0.5)
                        .labelsHidden()
                    Text(String(format: "%.1f ms", s.delayMs)).font(.caption).frame(width: 58)
                }
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var m: AudioManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $m.engineMode) {
                    Text("Pro").tag(EngineMode.pro)
                    Text("Simple").tag(EngineMode.simple)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: m.engineMode) { m.engineChanged() }

                Text(m.engineMode == .pro
                     ? "Pro: all outputs share one clock, with per-output delay, volume and channel mode. Needs the System Audio Recording permission."
                     : "Simple: uses a macOS Multi-Output device. Lightweight, but no per-output delay or channel controls.")
                    .font(.caption).foregroundStyle(.secondary)

                GroupBox(label: Text("Outputs")) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(m.devices) { d in DeviceRow(dev: d) }
                        if m.devices.isEmpty { Text("No outputs found").foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox(label: Text("Quality")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Sample rate", selection: $m.sampleRate) {
                            Text("Auto (highest common rate up to 96 kHz)").tag(0.0)
                            ForEach(m.rateOptions, id: \.self) { Text(rateLabel($0)).tag($0) }
                        }
                        .onChange(of: m.sampleRate) { m.formatChanged() }
                        Picker("Buffer (smaller = lower latency)", selection: $m.bufferFrames) {
                            ForEach([UInt32(64), 128, 256, 512, 1024], id: \.self) { Text("\($0) frames").tag($0) }
                        }
                        .onChange(of: m.bufferFrames) { m.formatChanged() }
                        Text("Internal processing is 32-bit float with no quality loss; drift compensation uses the highest quality setting.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                if m.engineMode == .pro {
                    GroupBox(label: Text("Master volume")) {
                        HStack {
                            Button { m.muted.toggle(); m.pushMaster() } label: {
                                Image(systemName: m.muted ? "speaker.slash.fill" : "speaker.wave.3.fill")
                            }
                            Slider(value: Binding(get: { Double(m.masterGain) },
                                                  set: { m.masterGain = Float($0); m.pushMaster() }),
                                   in: 0...1)
                            Text("\(Int(m.masterGain * 100))%").font(.caption).frame(width: 44)
                        }
                        .padding(6)
                    }
                }

                GroupBox(label: Text("Microphone")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Play microphone through the outputs", isOn: Binding(get: { m.micOn },
                                                                              set: { m.setMic($0) }))
                        if m.micOn {
                            if m.engineMode == .pro {
                                Picker("Input", selection: $m.micUID) {
                                    ForEach(m.inputs) { Text($0.name).tag($0.uid) }
                                }
                                .onChange(of: m.micUID) { m.save(); if m.active { m.start() } }
                            }
                            HStack {
                                Image(systemName: "mic.fill")
                                Slider(value: Binding(get: { Double(m.micGain) },
                                                      set: { m.micGain = Float($0); m.pushMaster() }),
                                       in: 0...2)
                            }
                            Text("Open speakers can cause feedback (howling). Use headphones or keep the volume low.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                }

                if m.engineMode == .pro {
                    Toggle("Sync test (repeating click)", isOn: Binding(get: { m.testClick },
                                                                    set: { m.setTestClick($0) }))
                    Text("You'll hear the click from every output. If one output plays it earlier, increase that output's delay until you hear a single click.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                HStack {
                    Button(m.active ? "Reapply" : "Activate") { m.start() }
                        .keyboardShortcut(.defaultAction)
                    Button("Stop") { m.stopAll() }.disabled(!m.active)
                    Button("Refresh") { m.refresh() }
                }

                Divider()
                Text(m.status).font(.caption).foregroundStyle(.secondary)
                Button("Quit") {
                    m.stopAll()
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(14)
        }
        .frame(width: 400, height: 640)
        .onAppear { m.refresh() }
    }
}

@main
struct SpeakCastApp: App {
    @StateObject private var manager = AudioManager()

    var body: some Scene {
        MenuBarExtra("SpeakCast", systemImage: manager.active ? "speaker.wave.3.fill" : "speaker.wave.2") {
            ContentView().environmentObject(manager)
        }
        .menuBarExtraStyle(.window)
    }
}
