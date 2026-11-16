import Foundation
import AVFoundation

final class AudioCapture {
    private let engine = AVAudioEngine()
    private var tapped = false
    private var configurationObserver: NSObjectProtocol?
    var onAudio: ((Data, Float) -> Void)?
    var onError: ((String) -> Void)?
    func start() throws {
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else { throw AppFailure("无法打开麦克风，请检查系统声音设置。") }
        input.installTap(onBus: 0, bufferSize: 2048, format: source) { [weak self] inputBuffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * 24_000 / source.sampleRate) + 32)
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false; var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return inputBuffer
            }
            if let error { self?.onError?("音频转换失败：\(error.localizedDescription)"); return }
            guard let samples = output.floatChannelData?[0], output.frameLength > 0 else { return }
            var pcm = Data(capacity: Int(output.frameLength) * 2); var power: Float = 0
            for i in 0..<Int(output.frameLength) {
                let x = max(-1, min(1, samples[i])); power += x * x
                var value = Int16(x * 32767).littleEndian
                withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
            }
            self?.onAudio?(pcm, sqrt(power / Float(output.frameLength)))
        }
        tapped = true
        do {
            engine.prepare(); try engine.start()
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                self?.onError?("麦克风设备发生变化，录音已暂停。确认设备后点击继续。")
            }
        } catch { stop(); throw error }
    }
    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver); self.configurationObserver = nil }
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
    }
    deinit { stop() }
}
struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
