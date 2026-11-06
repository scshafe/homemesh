import Foundation
import MetricKit
import os
import UIKit

/// The app's own rolling event log, kept in the app container as JSON lines, written and flushed per event so it
/// survives a crash. It never holds names or scan content: phases, errors with domain and code, counts, timings.
/// Capped at about 2 MB (the oldest half goes when it is full). It stays on the phone; Settings can put it in a file to share.
final class EventLog: @unchecked Sendable {
    static let shared = EventLog(url: EventLog.defaultURL)
    static let cap = 2 * 1024 * 1024

    private let url: URL
    private let lock = NSLock()
    private var last = 0.0

    init(url: URL) { self.url = url }

    static var defaultURL: URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("events.jsonl")
    }

    /// Appends one event. `t` is strictly increasing (milliseconds since the epoch), so it doubles as the upload cursor.
    func append(_ name: String, _ fields: [String: Any] = [:], now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        last = max(last + 1, (now.timeIntervalSince1970 * 1000).rounded())
        var o = fields
        o["t"] = last
        o["e"] = name
        guard JSONSerialization.isValidJSONObject(o), var line = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: line)
        try? h.synchronize()   // on disk now, not at exit
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.cap { trim() }
    }

    private func trim() {
        guard let data = try? Data(contentsOf: url) else { return }
        let from = data.count / 2
        guard let nl = data[from...].firstIndex(of: 0x0A) else { return }
        try? data[(nl + 1)...].write(to: url, options: .atomic)
    }

    /// The last `bytes` of the log, from the start of a line.
    func tail(bytes: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        if data.count <= bytes { return data }
        let from = data.count - bytes
        guard let nl = data[from...].firstIndex(of: 0x0A) else { return nil }
        return data[(nl + 1)...]
    }

    /// The events with `t` greater than `cursor`, as JSON lines, and the newest `t` among them.
    func lines(after cursor: Double) -> (data: Data, newest: Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var out = Data(), newest = cursor
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8), let t = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["t"] as? Double, t > cursor else { continue }
            out.append(d)
            out.append(0x0A)
            newest = max(newest, t)
        }
        return out.isEmpty ? nil : (out, newest)
    }
}

enum Diagnostics {
    /// Records one event (see `EventLog`). Safe from any thread.
    static func event(_ name: String, _ fields: [String: Any] = [:]) {
        EventLog.shared.append(name, fields)
    }

    /// The app, device and OS, once per launch.
    @MainActor static func launched() {
        let info = Bundle.main.infoDictionary ?? [:]
        event("launch", ["version": info["CFBundleShortVersionString"] as? String ?? "?", "build": info["CFBundleVersion"] as? String ?? "?", "commit": BuildInfo.commit,
                         "device": UIDevice.current.model, "os": UIDevice.current.systemVersion,
                         "thermal": thermal(), "low_power": ProcessInfo.processInfo.isLowPowerModeEnabled])
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            event("memory-warning", ["thermal": thermal()])
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            event("thermal", ["state": thermal()])
        }
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// MetricKit's crash and hang reports, kept on the phone beside the event log (nothing is sent anywhere) and put together for the share sheet.
@MainActor
final class DiagnosticsCollector: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticsCollector()

    /// Subscribes to MetricKit; payloads of past crashes and hangs arrive at launch.
    func start() {
        MXMetricManager.shared.add(self)
        for p in MXMetricManager.shared.pastDiagnosticPayloads { stash(p.jsonRepresentation()) }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let blobs = payloads.map { $0.jsonRepresentation() }
        Task { @MainActor in for b in blobs { self.stash(b) } }
    }

    private var dir: URL {
        let d = EventLog.defaultURL.deletingLastPathComponent().appendingPathComponent("diagnostics-reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func stash(_ json: Data) {
        guard !json.isEmpty else { return }
        let name = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).json"
        try? json.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    /// One text file: the recent events, then the crash and hang reports. Written to the temporary folder.
    func report() throws -> URL {
        var out = Data("homemesh diagnostics \(Date())\n\n== events (JSON lines) ==\n".utf8)
        if let events = EventLog.shared.tail(bytes: 400_000) { out.append(events) }
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for u in files.suffix(10) {
            out.append(Data("\n== crash or hang report \(u.lastPathComponent) ==\n".utf8))
            if let d = try? Data(contentsOf: u) { out.append(d) }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("homemesh-diagnostics.txt")
        try out.write(to: url, options: .atomic)
        return url
    }
}
