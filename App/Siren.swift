import AVFoundation
import Foundation

/// Synthesised air-raid siren (rising/falling wail) and a soft "all clear" chime.
final class Siren: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var stopItem: DispatchWorkItem?
    private var player: AVAudioPlayer?
    private(set) var isPlaying = false

    private final class State { var phase = 0.0; var t = 0.0 }

    enum Sound { case siren, chime }

    func play(_ sound: Sound = .siren, seconds: Double, volume: Double) {
        stop()
        if sound == .siren, let url = Bundle.main.url(forResource: "siren", withExtension: "m4a"),
           let p = try? AVAudioPlayer(contentsOf: url) {
            p.numberOfLoops = -1
            p.volume = Float(max(0, min(1, volume)))
            p.prepareToPlay()
            if p.play() {
                player = p
                isPlaying = true
                let item = DispatchWorkItem { [weak self] in self?.stop() }
                stopItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
                return
            }
        }
        let out = engine.outputNode.outputFormat(forBus: 0)
        let sr = out.sampleRate > 0 ? out.sampleRate : 44_100
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else { return }
        let st = State()
        let n = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            for f in 0..<Int(frameCount) {
                var v: Double
                switch sound {
                case .siren:
                    let cycle = 5.0
                    let x = st.t.truncatingRemainder(dividingBy: cycle) / cycle
                    let ramp = x < 0.45 ? x / 0.45 : (x < 0.55 ? 1 : (1 - x) / 0.45)
                    let freq = 380 + 620 * ramp
                    st.phase += 2 * .pi * freq / sr
                    // slightly richer than a pure sine
                    v = 0.55 * sin(st.phase) + 0.2 * sin(2 * st.phase) + 0.08 * sin(3 * st.phase)
                case .chime:
                    let freq = st.t < 0.35 ? 880.0 : 660.0
                    st.phase += 2 * .pi * freq / sr
                    let env = max(0, 1 - (st.t.truncatingRemainder(dividingBy: 0.35) / 0.35))
                    v = 0.5 * sin(st.phase) * env
                }
                if st.phase > 2 * .pi * 1000 { st.phase = st.phase.truncatingRemainder(dividingBy: 2 * .pi) }
                // fade in / out to avoid clicks
                let fadeIn = min(1, st.t / 0.3)
                v *= fadeIn
                st.t += 1 / sr
                for b in bufs {
                    if let p = b.mData?.assumingMemoryBound(to: Float.self) { p[f] = Float(v) }
                }
            }
            return noErr
        }
        engine.attach(n)
        engine.connect(n, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = Float(max(0, min(1, volume)))
        node = n
        do { try engine.start(); isPlaying = true } catch { stop(); return }
        let item = DispatchWorkItem { [weak self] in self?.stop() }
        stopItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (sound == .chime ? 0.75 : seconds), execute: item)
    }

    func stop() {
        stopItem?.cancel(); stopItem = nil
        player?.stop(); player = nil
        if engine.isRunning { engine.stop() }
        if let n = node { engine.detach(n) }
        node = nil
        isPlaying = false
    }
}
