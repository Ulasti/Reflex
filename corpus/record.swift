#!/usr/bin/env swift
// Corpus recorder — walks corpus/PHRASES.md top to bottom and records two takes
// per line, saving corpus/<folder>/<stem>__take<N>.wav.
// Usage: swift corpus/record.swift [--list] [--seconds N]

import AppKit
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
    NSSound(named: NSSound.Name(name))?.play()
    usleep(400_000)
}

let args = Array(CommandLine.arguments.dropFirst())
let listOnly = args.contains("--list")
var seconds = 5.0
if let i = args.firstIndex(of: "--seconds"), i + 1 < args.count, let s = Double(args[i + 1]) { seconds = s }

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

func record(_ url: URL) {
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
        guard rec.prepareToRecord(), rec.record(forDuration: seconds) else {
            print("  ! recorder did not start for \(url.lastPathComponent)")
            return
        }
        while rec.isRecording { usleep(50_000) }
        rec.stop()
    } catch {
        print("  ! \(error.localizedDescription)")
    }
}

print("Corpus recorder — \(items.count) lines (\(trainCount) train, \(heldoutCount) heldout)")
print("Each line: take1 then take2, \(Int(seconds)) s each, beeps mark start/end.")
print("Enter = record, s = skip line, q = quit. Rerun any time to resume.")
var saved = 0
for (n, item) in items.enumerated() {
    let have1 = FileManager.default.fileExists(atPath: fileURL(item, take: 1).path)
    let have2 = FileManager.default.fileExists(atPath: fileURL(item, take: 2).path)
    if have1 && have2 { continue }
    print("\n[\(n + 1)/\(items.count)] \(item.folder)/\(item.stem)  \"\(item.phrase)\"")
    print("  Enter = record, s = skip, q = quit: ", terminator: "")
    fflush(stdout)
    guard let answer = readLine() else { print(""); break }
    if answer.lowercased() == "q" { break }
    if answer.lowercased() == "s" { continue }
    try? FileManager.default.createDirectory(
        at: here.appendingPathComponent(item.folder), withIntermediateDirectories: true)
    for take in 1...2 {
        let url = fileURL(item, take: take)
        if FileManager.default.fileExists(atPath: url.path) {
            print("  take\(take) already recorded, skipped")
            continue
        }
        print("  take\(take) — speak after the beep")
        beep("Tink")
        record(url)
        beep("Pop")
        saved += 1
    }
}
print("\n\(saved) new takes saved. Rerun to resume.")
