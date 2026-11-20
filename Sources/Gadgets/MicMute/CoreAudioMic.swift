import CoreAudio
import Foundation
import MicMuteCore

/// The default input device, via Core Audio. Changing mute/volume needs no permission.
final class CoreAudioMic: MicDevice {
    let id: AudioObjectID

    init(id: AudioObjectID) {
        self.id = id
    }

    static func defaultInput() -> CoreAudioMic? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return CoreAudioMic(id: device)
    }

    var uid: String { string(kAudioDevicePropertyDeviceUID) ?? "\(id)" }
    var name: String { string(kAudioObjectPropertyName) ?? "Microphone" }

    var canMute: Bool { settable(kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain) }

    var isMuted: Bool {
        get { (uint32(kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain) ?? 0) != 0 }
        set { setUInt32(kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain, newValue ? 1 : 0) }
    }

    /// Some devices only have per-channel volume (elements 1, 2…), not a main one.
    private var volumeElements: [AudioObjectPropertyElement] {
        if settable(kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain) {
            return [kAudioObjectPropertyElementMain]
        }
        return (1...8).map { AudioObjectPropertyElement($0) }
            .filter { settable(kAudioDevicePropertyVolumeScalar, element: $0) }
    }

    var canSetVolume: Bool { !volumeElements.isEmpty }

    var volume: Float {
        get {
            guard let e = volumeElements.first else { return 1 }
            return float(kAudioDevicePropertyVolumeScalar, element: e) ?? 1
        }
        set {
            for e in volumeElements { setFloat(kAudioDevicePropertyVolumeScalar, element: e, newValue) }
        }
    }

    // MARK: - Core Audio plumbing

    private func address(_ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeInput,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private func settable(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Bool {
        var addr = address(selector, element: element)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var isSettable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &addr, &isSettable) == noErr && isSettable.boolValue
    }

    private func string(_ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector, scope: kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func uint32(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> UInt32? {
        var addr = address(selector, element: element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func setUInt32(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement, _ v: UInt32) {
        var addr = address(selector, element: element)
        var value = v
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private func float(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Float? {
        var addr = address(selector, element: element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func setFloat(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement, _ v: Float) {
        var addr = address(selector, element: element)
        var value = Float32(min(max(v, 0), 1))
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }
}

/// Calls back (on the main queue) when the default input device changes, or when the
/// current device's mute/volume changes outside Mac Belt.
final class MicWatcher {
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var watchedDevice: AudioObjectID?
    private let onDeviceChange: () -> Void
    private let onStateChange: () -> Void

    private var defaultInputAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                              mScope: kAudioObjectPropertyScopeGlobal,
                                                              mElement: kAudioObjectPropertyElementMain)
    private var deviceAddrs: [AudioObjectPropertyAddress] = [
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput,
                                   mElement: kAudioObjectPropertyElementMain),
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeInput,
                                   mElement: kAudioObjectPropertyElementMain),
    ]

    init(onDeviceChange: @escaping () -> Void, onStateChange: @escaping () -> Void) {
        self.onDeviceChange = onDeviceChange
        self.onStateChange = onStateChange
    }

    func start() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onDeviceChange() }
        systemListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInputAddr, .main, block)
    }

    func watch(device: AudioObjectID?) {
        unwatchDevice()
        guard let device else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onStateChange() }
        deviceListener = block
        watchedDevice = device
        for i in deviceAddrs.indices {
            var addr = deviceAddrs[i]
            if AudioObjectHasProperty(device, &addr) {
                AudioObjectAddPropertyListenerBlock(device, &addr, .main, block)
            }
        }
    }

    func stop() {
        unwatchDevice()
        if let block = systemListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInputAddr, .main, block)
        }
        systemListener = nil
    }

    private func unwatchDevice() {
        if let device = watchedDevice, let block = deviceListener {
            for i in deviceAddrs.indices {
                var addr = deviceAddrs[i]
                if AudioObjectHasProperty(device, &addr) {
                    AudioObjectRemovePropertyListenerBlock(device, &addr, .main, block)
                }
            }
        }
        watchedDevice = nil
        deviceListener = nil
    }
}
