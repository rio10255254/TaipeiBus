#!/bin/bash
# Checks the voice conversation's turn recording on macOS: TurnRecorder, copied out of
# AssistantInput.swift, takes 48 kHz microphone-like buffers (held, then released, as when a rider
# cuts in) and must write an AAC file that AVAudioFile reads back as 16 kHz mono of the right length.
set -euo pipefail
work="$(mktemp -d)"
{ echo 'import AVFoundation'; awk '/^final class TurnRecorder/,/^}/' ios/TaipeiBus/AssistantInput.swift; } > "$work/recorder.swift"
grep -q "func finish" "$work/recorder.swift"
cat > "$work/main.swift" <<'SWIFT'
import AVFoundation

let microphone = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
var phase = 0.0
func buffer() -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: microphone, frameCapacity: 1024)!
    buffer.frameLength = 1024
    for index in 0..<1024 {
        buffer.floatChannelData![0][index] = Float(sin(phase) * 0.3)
        phase += 2 * .pi * 440 / 48_000
    }
    return buffer
}

let recorder = TurnRecorder()
recorder.begin(holding: true)
// About 2.1 s while the answer speaks: only the last 1.5 s is kept.
for _ in 0..<100 { recorder.append(buffer()) }
recorder.release()
// About 2 s of the rider.
for _ in 0..<94 { recorder.append(buffer()) }
guard let data = recorder.finish() else { fatalError("no recording") }
let url = FileManager.default.temporaryDirectory.appendingPathComponent("check.m4a")
try data.write(to: url)
let file = try AVAudioFile(forReading: url)
let seconds = Double(file.length) / file.fileFormat.sampleRate
print("recording: \(data.count) bytes, \(file.fileFormat.sampleRate) Hz, \(file.fileFormat.channelCount) channel, \(String(format: "%.2f", seconds)) s")
precondition(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1, "not 16 kHz mono")
precondition(seconds > 3.0 && seconds < 3.9, "unexpected length")
precondition(data.count < 60_000, "too large to send")
// Nothing is left behind, and a discarded recording gives nothing.
recorder.begin(holding: false)
for _ in 0..<10 { recorder.append(buffer()) }
recorder.discard()
precondition(recorder.finish() == nil, "discarded recording returned")
let leftovers = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).filter { $0.hasPrefix("turn-") }
precondition(leftovers.isEmpty, "temporary recordings left: \(leftovers)")
print("Turn recording works.")
SWIFT
xcrun swiftc -O -o "$work/check" "$work/recorder.swift" "$work/main.swift"
"$work/check"
