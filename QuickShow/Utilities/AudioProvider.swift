import Foundation
import CoreAudio
import Combine

// MARK: - 音频输出设备与音量 (CoreAudio HAL) + 音频变化实时监听
//
// C 回调指针生命周期链：
//   audioListenerContext 每次读取都以 Unmanaged.passUnretained(self).toOpaque() 生成裸指针，
//   作为 userData 传给 AudioObjectAdd/RemovePropertyListener（系统仅借用，不持有引用）；
//   回调音频监听线程经 Unmanaged<AudioProvider>.fromOpaque(userData).takeUnretainedValue()
//   还原实例（同样非持有）。裸指针不落任何存储，仅在调用配对的生命周期内有效；
//   实例由门面 SystemStatusProvider.shared 终身持有，故 passUnretained 安全。
final class AudioProvider {
    /// 音频属性变化事件：音量/静音被外部（键盘、控制中心）调节，或默认输出设备切换时实时推送
    let audioChangeSubject = PassthroughSubject<Void, Never>()

    private var audioMonitoringStarted = false
    private var monitoredVolumeDeviceID: AudioDeviceID = 0

    /// C 函数指针不能捕获上下文，经 userData 携带实例引用回调
    private static let audioListenerProc: AudioObjectPropertyListenerProc = { objectID, numberOfAddresses, addresses, userData in
        guard let userData = userData else { return noErr }
        let provider = Unmanaged<AudioProvider>.fromOpaque(userData).takeUnretainedValue()
        provider.handleAudioPropertyChanged(objectID: objectID,
                                            addresses: addresses,
                                            count: Int(numberOfAddresses))
        return noErr
    }

    private var audioListenerContext: UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    }

    /// 门面在 init 中调用：注册默认设备切换与音量/静音监听
    func start() {
        startAudioChangeMonitoring()
    }

    /// 当前默认输出设备 ID（0 表示获取失败）
    private func currentDefaultOutputDevice() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        return (status == noErr) ? deviceID : 0
    }

    /// 输出 scope 全部声道 element（Main(0) + 声道 1...N）。
    /// 蓝牙耳机（AirPods 等）的音量在 HAL 层按左右声道独立暴露，只写 Main 或单个
    /// element 只会改到一只耳机、打破系统左右平衡，因此读写必须统一覆盖全部声道。
    private func outputVolumeElements(_ deviceID: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var configSize = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &configSize) == noErr,
              configSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return [kAudioObjectPropertyElementMain, 1]
        }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(configSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &configSize, buffer) == noErr else {
            return [kAudioObjectPropertyElementMain, 1]
        }
        let bufferList = buffer.assumingMemoryBound(to: AudioBufferList.self)
        // mBuffers 是变长数组头部，Swift 里表现为 tuple，需按指针遍历实际 buffer 数
        let buffers = UnsafeMutableBufferPointer<AudioBuffer>(
            start: &bufferList.pointee.mBuffers,
            count: Int(bufferList.pointee.mNumberBuffers)
        )
        var channelCount = 0
        for audioBuffer in buffers {
            channelCount += Int(audioBuffer.mNumberChannels)
        }
        // Main(0) 优先（内置扬声器等单卷设备），其后跟上各声道；声道数未知时兜底 element 1
        var elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain]
        for element in 1...max(channelCount, 1) {
            elements.append(AudioObjectPropertyElement(element))
        }
        return elements
    }

    /// 读取音量：取所有可读声道中的最大值（左右一致时即统一值；有偏差时按较大方展示）
    private func readVolume(deviceID: AudioDeviceID, elements: [AudioObjectPropertyElement]) -> Float32 {
        var volume: Float32 = 0
        var didRead = false
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr {
                if didRead {
                    volume = max(volume, value)
                } else {
                    volume = value
                    didRead = true
                }
            }
        }
        return didRead ? volume : 0
    }

    /// 写入音量到全部声道（任一声道失败不影响其余声道，保证左右一致）
    private func writeVolume(_ value: Float32, deviceID: AudioDeviceID, elements: [AudioObjectPropertyElement]) {
        let size = UInt32(MemoryLayout<Float32>.size)
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var volume = value
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volume)
        }
    }

    /// 读取静音：任一可读声道处于静音即视为静音
    private func readMuted(deviceID: AudioDeviceID, elements: [AudioObjectPropertyElement]) -> Bool {
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr, value != 0 {
                return true
            }
        }
        return false
    }

    /// 写入静音到全部声道
    private func writeMuted(_ muted: Bool, deviceID: AudioDeviceID, elements: [AudioObjectPropertyElement]) {
        let size = UInt32(MemoryLayout<UInt32>.size)
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var flag: UInt32 = muted ? 1 : 0
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &flag)
        }
    }

    /// 按输出传输类型判定蓝牙音频设备（比设备名匹配更稳，覆盖非典型命名的耳机）
    private func isBluetoothAudioDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    func getAudioInfo() -> AudioInfo {
        let deviceID = currentDefaultOutputDevice()
        guard deviceID != 0 else {
            return AudioInfo(deviceName: "系统音频", volume: 50, isMuted: false, isHeadphones: false)
        }

        let elements = outputVolumeElements(deviceID)
        let volumePercent = Int(round(readVolume(deviceID: deviceID, elements: elements) * 100))
        let isMuted = readMuted(deviceID: deviceID, elements: elements)

        // 设备名称
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devName = "音频输出"
        var nameCF: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        if AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameCF) == noErr,
           let cf = nameCF?.takeRetainedValue() {
            devName = cf as String
        }

        let lower = devName.lowercased()
        let isHeadphones = isBluetoothAudioDevice(deviceID)
            || lower.contains("airpod") || lower.contains("headphone") || lower.contains("ear")
            || lower.contains("buds") || lower.contains("bose") || lower.contains("sony")

        return AudioInfo(deviceName: devName, volume: volumePercent, isMuted: isMuted, isHeadphones: isHeadphones)
    }

    func setVolume(to percent: Int) {
        let deviceID = currentDefaultOutputDevice()
        guard deviceID != 0 else { return }
        let clamped = Float32(max(0, min(100, percent))) / 100.0
        writeVolume(clamped, deviceID: deviceID, elements: outputVolumeElements(deviceID))
    }

    func toggleMute() -> Bool {
        let deviceID = currentDefaultOutputDevice()
        guard deviceID != 0 else { return false }
        let elements = outputVolumeElements(deviceID)
        let newMute = !readMuted(deviceID: deviceID, elements: elements)
        writeMuted(newMute, deviceID: deviceID, elements: elements)
        return newMute
    }

    func adjustVolume(by step: Int) -> Int {
        let current = getAudioInfo()
        let target = max(0, min(100, current.volume + step))
        setVolume(to: target)
        // 调节音量时自动解除静音
        if current.isMuted {
            _ = toggleMute()
        }
        return target
    }

    // MARK: - CoreAudio 音频变化实时监听

    /// 注册默认设备切换（系统对象）与当前默认设备音量/静音（设备对象）监听
    private func startAudioChangeMonitoring() {
        guard !audioMonitoringStarted else { return }
        audioMonitoringStarted = true

        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject),
                                       &defaultDeviceAddress,
                                       Self.audioListenerProc,
                                       audioListenerContext)
        attachVolumeListeners(to: currentDefaultOutputDevice())
    }

    /// 把音量/静音监听挂到指定设备；默认设备切换（如 AirPods 接入）后迁移到新设备
    private func attachVolumeListeners(to deviceID: AudioDeviceID) {
        guard deviceID != 0, deviceID != monitoredVolumeDeviceID else { return }
        if monitoredVolumeDeviceID != 0 {
            var oldVolumeAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var oldMuteAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListener(monitoredVolumeDeviceID, &oldVolumeAddress, Self.audioListenerProc, audioListenerContext)
            AudioObjectRemovePropertyListener(monitoredVolumeDeviceID, &oldMuteAddress, Self.audioListenerProc, audioListenerContext)
        }
        monitoredVolumeDeviceID = deviceID

        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListener(deviceID, &volumeAddress, Self.audioListenerProc, audioListenerContext)
        AudioObjectAddPropertyListener(deviceID, &muteAddress, Self.audioListenerProc, audioListenerContext)
    }

    /// HAL 回调线程触发：处理属性变化并广播（读值与赋值由订阅方在合适的队列完成）
    private func handleAudioPropertyChanged(objectID: AudioObjectID,
                                            addresses: UnsafePointer<AudioObjectPropertyAddress>?,
                                            count: Int) {
        guard let addresses = addresses else { return }
        for i in 0..<count {
            if addresses[i].mSelector == kAudioHardwarePropertyDefaultOutputDevice {
                attachVolumeListeners(to: currentDefaultOutputDevice())
            }
        }
        audioChangeSubject.send()
    }
}