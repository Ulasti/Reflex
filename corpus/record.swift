#!/usr/bin/env swift
// Corpus recorder — walks corpus/PHRASES.md top to bottom and records two takes
// per line, saving corpus/<folder>/<stem>__take<N>.wav.
// Usage: swift corpus/record.swift [--list] [--seconds N]

import AVFoundation
import Darwin
import Foundation

struct Item {
    let folder: String
    let stem: String
    let phrase: String
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

func parse(_ text: String) -> [Item] {
    var items: [Item] = []
    var folder = ""
    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("## Part 1") { folder = "train"; continue }
        if line.hasPrefix("## Part 2") { folder = "heldout"; continue }
        if line.hasPrefix("## Part 3") { break }
        guard !folder.isEmpty, line.hasPrefix("- [ ] \""), let dash = line.range(of: "\" — ") else { continue }
        let phrase = String(line[line.index(line.startIndex, offsetBy: 7)..<dash.lowerBound])
        let stem = String(line[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
        items.append(Item(folder: folder, stem: stem, phrase: phrase))
    }
    return items
}

func fileURL(_ item: Item, take: Int) -> URL {
    here.appendingPathComponent(item.folder)
        .appendingPathComponent("\(item.stem)__take\(take).wav")
}

func beep(_ name: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    p.arguments = ["/System/Library/Sounds/\(name).aiff"]
    try? p.run()
    p.waitUntilExit()
}

let args = Array(CommandLine.arguments.dropFirst())
let listOnly = args.contains("--list")

guard let text = try? String(contentsOf: here.appendingPathComponent("PHRASES.md"), encoding: .utf8) else {
    FileHandle.standardError.write(Data("cannot read PHRASES.md next to the script\n".utf8))
    exit(2)
}
let items = parse(text)
let trainCount = items.filter { $0.folder == "train" }.count
let heldoutCount = items.count - trainCount

if listOnly {
    for (n, item) in items.enumerated() {
        print("\(n + 1). \(item.folder)/\(item.stem)  \"\(item.phrase)\"")
    }
    print("\ntotal \(items.count) = \(trainCount) train + \(heldoutCount) heldout")
    exit(0)
}

final class Flag { var ok = false }
switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
    break
case .notDetermined:
    let flag = Flag()
    let sem = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { ok in
        flag.ok = ok
        sem.signal()
    }
    sem.wait()
    if !flag.ok {
        print("Microphone permission denied. Enable it for your terminal app in System Settings > Privacy & Security > Microphone.")
        exit(3)
    }
default:
    print("Microphone access is off. Enable it for your terminal app in System Settings > Privacy & Security > Microphone.")
    exit(3)
}

func capturedSeconds(_ url: URL) -> Double {
    guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return 0 }
    return Double(file.length) / file.fileFormat.sampleRate
}

func recordTake(_ url: URL) -> Double {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    do {
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.isMeteringEnabled = true
        guard rec.prepareToRecord() else {
            print("  ! recorder did not prepare for \(url.lastPathComponent)")
            return 0
        }
        beep("Tink")
        print("  ● recording — press Enter to stop")
        fflush(stdout)
        guard rec.record() else {
            print("  ! recorder did not start — is Microphone allowed for your terminal?")
            return 0
        }
        // Pump the run loop while waiting for Enter: a fully blocked main thread
        // can leave the capture engine without a chance to run.
        let enter = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = readLine()
            enter.signal()
        }
        var nextReport = Date().addingTimeInterval(1.0)
        while enter.wait(timeout: .now()) == .timedOut {
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
            if Date() >= nextReport {
                rec.updateMeters()
                print(String(format: "    %.1f s  level %.0f dB", rec.currentTime, rec.averagePower(forChannel: 0)))
                fflush(stdout)
                nextReport = Date().addingTimeInterval(1.0)
            }
        }
        rec.stop()
        beep("Pop")
        return capturedSeconds(url)
    } catch {
        print("  ! \(error.localizedDescription)")
        return 0
    }
}

print("Corpus recorder — \(items.count) lines (\(trainCount) train, \(heldoutCount) heldout)")
print("Each take: Enter starts the recording, Enter again stops it, beeps mark both.")
print("Enter = record, s = skip line, q = quit. Rerun any time to resume.")
var saved = 0
outer: for (n, item) in items.enumerated() {
    let have1 = FileManager.default.fileExists(atPath: fileURL(item, take: 1).path)
    let have2 = FileManager.default.fileExists(atPath: fileURL(item, take: 2).path)
    if have1 && have2 { continue }
    print("\n[\(n + 1)/\(items.count)] \(item.folder)/\(item.stem)  \"\(item.phrase)\"")
    try? FileManager.default.createDirectory(
        at: here.appendingPathComponent(item.folder), withIntermediateDirectories: true)
    for take in 1...2 {
        let url = fileURL(item, take: take)
        if FileManager.default.fileExists(atPath: url.path) {
            print("  take\(take) already recorded, skipped")
            continue
        }
        print("  take\(take): Enter = record, s = skip line, q = quit: ", terminator: "")
        fflush(stdout)
        guard let answer = readLine() else { break outer }
        switch answer.lowercased() {
        case "q": break outer
        case "s": print("  line skipped"); continue outer
        default: break
        }
        let duration = recordTake(url)
        if duration < 0.5 {
            try? FileManager.default.removeItem(at: url)
            if duration == 0 {
                print("  no audio captured. Check System Settings > Privacy & Security > Microphone")
                print("  (your terminal app must be enabled) and the input device in Sound settings.")
            } else {
                print("  too short (\(String(format: "%.1f", duration)) s) — discarded, redo this take")
            }
        } else {
            saved += 1
            print("  ✓ \(item.stem)__take\(take) (\(String(format: "%.1f", duration)) s)")
        }
    }
}
print("\n\(saved) new takes saved. Rerun to resume.")
