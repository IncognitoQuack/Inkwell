import AVFoundation
import AppKit
import Speech
import SwiftUI

/// Records audio while you write, plays it back with the ink "replaying" in sync, and transcribes it
/// on-device so what was said is searchable. Strokes written during a recording remember the moment.
final class AudioController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var recordingTime: Double = 0
    @Published private(set) var playing: UUID?
    @Published private(set) var isPaused = false
    @Published private(set) var playTime: Double = 0
    @Published private(set) var transcribing: Set<UUID> = []

    private unowned let session: NotebookSession
    weak var canvas: CanvasView?
    private var recorder: AVAudioRecorder?
    private var recordingID = UUID()
    private var recordingStart = Date()
    private var recordingPage = UUID()
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var task: SFSpeechRecognitionTask?

    init(session: NotebookSession) {
        self.session = session
    }

    deinit {
        timer?.invalidate()
        recorder?.stop()
        player?.stop()
        task?.cancel()
    }

    // MARK: Recording

    func toggleRecording() { isRecording ? stopRecording() : startRecording() }

    func startRecording() {
        guard !isRecording else { return }
        stopPlayback()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { ok ? self.beginRecording() : self.explainMicrophone() }
            }
        default:
            explainMicrophone()
        }
    }

    private func explainMicrophone() {
        let alert = NSAlert()
        alert.messageText = "Inkwell can’t use the microphone."
        alert.informativeText = "Turn on Inkwell in System Settings › Privacy & Security › Microphone, then try again."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private var tempURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("inkwell-rec-\(recordingID.uuidString).m4a") }

    private func beginRecording() {
        recordingID = UUID()
        recordingStart = Date()
        recordingPage = session.currentPage?.id ?? session.notebook.pages[0].id
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                                       AVEncoderBitRateKey: 64_000, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        do {
            let r = try AVAudioRecorder(url: tempURL, settings: settings)
            guard r.record() else { throw CocoaError(.fileWriteUnknown) }
            recorder = r
            isRecording = true
            recordingTime = 0
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.recordingTime = self?.recorder?.currentTime ?? 0
            }
            canvas?.showHUD("Recording: ink you write now is linked to the audio", symbol: "record.circle")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func stopRecording() {
        guard isRecording, let r = recorder else { return }
        let duration = r.currentTime
        r.stop()
        recorder = nil
        isRecording = false
        timer?.invalidate()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard duration > 0.5, let data = try? Data(contentsOf: tempURL), !data.isEmpty else {
            canvas?.showHUD("Recording too short: not kept", symbol: "mic.slash")
            return
        }
        let asset = session.addAsset(data)
        let rec = Recording(id: recordingID, asset: asset, started: recordingStart, duration: duration, page: recordingPage)
        session.addRecording(rec)
        canvas?.showHUD("Recording saved (\(Self.time(duration)))", symbol: "waveform")
        transcribe(rec)
    }

    /// For a stroke just finished: (recording, seconds into it when the stroke began), if recording.
    func anchor(forStrokeLasting seconds: Double) -> (UUID, Double)? {
        guard isRecording, let r = recorder else { return nil }
        return (recordingID, max(0, r.currentTime - max(0, seconds)))
    }

    // MARK: Playback

    func play(_ rec: Recording, from offset: Double = 0) {
        if isRecording { stopRecording() }
        if playing == rec.id, let p = player {
            if isPaused { p.play(); isPaused = false; startTicking() } else { p.pause(); isPaused = true; timer?.invalidate() }
            return
        }
        stopPlayback()
        guard let data = session.notebook.assets[rec.asset] else { NSSound.beep(); return }
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.currentTime = max(0, min(offset, p.duration - 0.05))
            p.play()
            player = p
            playing = rec.id
            isPaused = false
            startTicking()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func seek(to t: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(t, p.duration))
        tick()
    }

    private func startTicking() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard let p = player, let id = playing else { return }
        playTime = p.currentTime
        canvas?.setReplay(recording: id, time: p.currentTime)
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        if playing != nil { canvas?.setReplay(recording: nil, time: 0) }
        playing = nil
        isPaused = false
        if !isRecording { timer?.invalidate() }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.stopPlayback() }
    }

    func delete(_ rec: Recording) {
        let alert = NSAlert()
        alert.messageText = "Delete this recording?"
        alert.informativeText = "The ink stays; only the audio and its transcript are removed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if playing == rec.id { stopPlayback() }
        session.removeRecording(rec.id)
    }

    // MARK: Transcription (on-device when available)

    func transcribe(_ rec: Recording) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else { return } // transcripts are optional; recording still works
                self.runTranscription(rec)
            }
        }
    }

    private func runTranscription(_ rec: Recording) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, let data = session.notebook.assets[rec.asset] else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inkwell-tx-\(rec.id.uuidString).m4a")
        guard (try? data.write(to: url)) != nil else { return }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition // privacy first
        request.shouldReportPartialResults = false
        transcribing.insert(rec.id)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if result?.isFinal == true || error != nil {
                let text = result?.bestTranscription.formattedString ?? ""
                DispatchQueue.main.async {
                    self.transcribing.remove(rec.id)
                    if !text.isEmpty { self.session.setTranscript(text, for: rec.id) }
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    static func time(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

extension CanvasView {
    /// Audio replay: strokes from the recording written after `time` are drawn faint.
    func setReplay(recording: UUID?, time: Double) {
        let old = replay?.recording
        replay = recording.map { ($0, time) }
        for pv in pageViews where pv.page.strokes.contains(where: { $0.recording != nil && ($0.recording == recording || $0.recording == old) }) {
            pv.needsDisplay = true
        }
    }

    /// Plays the recording behind the selected ink, from where the earliest selected stroke was written.
    func playSelection() {
        guard let sel = selection, let audio else { return }
        let anchored = sel.page.page.strokes.filter { sel.strokes.contains($0.id) && $0.recording != nil }
        guard let first = anchored.min(by: { ($0.recordingOffset ?? 0) < ($1.recordingOffset ?? 0) }),
              let rec = session.notebook.recordings.first(where: { $0.id == first.recording }) else {
            showHUD("No audio was recorded with this ink", symbol: "speaker.slash")
            return
        }
        audio.play(rec, from: max(0, (first.recordingOffset ?? 0) - 1))
    }

    var selectionHasAudio: Bool {
        guard let sel = selection else { return false }
        return sel.page.page.strokes.contains { sel.strokes.contains($0.id) && $0.recording != nil }
    }
}

/// The recordings popover: record, play/pause with a scrubber, transcripts, delete.
struct AudioPanel: View {
    @ObservedObject var audio: AudioController
    @ObservedObject var session: NotebookSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { audio.toggleRecording() } label: {
                    Label(audio.isRecording ? "Stop" : "Record", systemImage: audio.isRecording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(audio.isRecording ? Color.red : .primary)
                }
                .controlSize(.large)
                if audio.isRecording {
                    Text(AudioController.time(audio.recordingTime)).font(.title3.monospacedDigit()).foregroundStyle(.red)
                }
                Spacer()
            }
            Text("While recording, everything you write is linked to the moment it was written. Select ink and choose Play to hear what was said.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if session.notebook.recordings.isEmpty {
                Text("No recordings yet.").foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(session.notebook.recordings.reversed()) { rec in row(rec) }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func row(_ rec: Recording) -> some View {
        let active = audio.playing == rec.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { audio.play(rec) } label: {
                    Image(systemName: active && !audio.isPaused ? "pause.circle.fill" : "play.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rec.title).font(.callout.weight(.medium))
                    Text(AudioController.time(rec.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) { audio.delete(rec) } label: { Image(systemName: "trash") }.buttonStyle(.plain).help("Delete recording")
            }
            if active {
                Slider(value: Binding(get: { audio.playTime }, set: { audio.seek(to: $0) }), in: 0...max(rec.duration, 0.1))
            }
            if audio.transcribing.contains(rec.id) {
                Label("Transcribing…", systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary)
            } else if let t = rec.transcript {
                Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
            } else {
                Button("Transcribe") { audio.transcribe(rec) }.controlSize(.small)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(active ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04)))
    }
}
