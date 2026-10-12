import AVFoundation
import MediaPlayer
import UIKit

/// Turns hardware volume presses into terminal actions while a terminal is visible.
/// iOS has no API for this: presses are seen as output-volume changes, the system HUD is hidden by an
/// off-screen MPVolumeView, and only the extremes are nudged so both buttons keep working.
@MainActor
final class VolumeButtonMonitor: NSObject {
    var onPress: (_ up: Bool) -> Void = { _ in }
    private let volumeView = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
    private var observation: NSKeyValueObservation?
    private weak var hostView: UIView?
    private var dictating = false
    private var observationID = UUID()
    private var ownVolumes: [Float] = []

    var isRunning: Bool { hostView != nil }

    func start(in view: UIView) {
        guard hostView == nil else { return }
        hostView = view
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(suspend), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(resume), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(dictationStarted), name: SpeechInputController.willRecord, object: nil)
        center.addObserver(self, selector: #selector(dictationStopped), name: SpeechInputController.didStopRecording, object: nil)
        resume()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        suspend()
        hostView = nil
        dictating = false
    }

    @objc private func suspend() {
        observationID = UUID()
        observation = nil
        ownVolumes = []
        volumeView.removeFromSuperview()
    }

    @objc private func resume() {
        guard observation == nil, !dictating, UIApplication.shared.applicationState == .active,
              let hostView else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, mode: .default, options: .mixWithOthers)
            try session.setActive(true)
        } catch { return }
        volumeView.alpha = 0.01
        hostView.addSubview(volumeView)
        let id = observationID
        observation = session.observe(\.outputVolume, options: [.old, .new]) { [weak self] _, change in
            guard let old = change.oldValue, let new = change.newValue else { return }
            Task { @MainActor in
                guard let self, self.observationID == id else { return }
                self.volumeChanged(from: old, to: new)
            }
        }
        nudgeExtreme(session.outputVolume)
    }

    @objc private func dictationStarted() {
        dictating = true
        suspend()
    }

    @objc private func dictationStopped() {
        dictating = false
        resume()
    }

    private func volumeChanged(from old: Float, to new: Float) {
        guard observation != nil, UIApplication.shared.applicationState == .active, old != new else { return }
        if let index = ownVolumes.firstIndex(where: { abs($0 - new) < 0.001 }) {
            ownVolumes.remove(at: index)
            return
        }
        onPress(new > old)
        nudgeExtreme(new)
    }

    private func nudgeExtreme(_ volume: Float) {
        guard volume <= 0 || volume >= 1 else { return }
        let value: Float = volume <= 0 ? 1 / 16 : 15 / 16
        let id = observationID
        DispatchQueue.main.async { [weak self] in
            guard let self, self.observationID == id, self.observation != nil,
                  UIApplication.shared.applicationState == .active,
                  let slider = self.volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
            self.ownVolumes.append(value)
            slider.value = value
        }
    }
}
