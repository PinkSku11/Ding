// Records from the Mac's microphone for some seconds, so the build machine can check how Ding takes it.
// Built under two names: "corespeechd", like Siri listening for "Hey Siri", and "Recorder", like a call.
import AVFoundation

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 12 : 12
let engine = AVAudioEngine()
let input = engine.inputNode
let format = input.outputFormat(forBus: 0)
guard format.channelCount > 0, format.sampleRate > 0 else {
    print("no microphone on this Mac")
    exit(2)
}
var buffers = 0
input.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in
    DispatchQueue.main.async { buffers += 1 }
}
do {
    try engine.start()
} catch {
    print("can't record: \(error.localizedDescription)")
    exit(3)
}
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
engine.stop()
print("recorded \(buffers) buffers in \(Int(seconds)) s")
