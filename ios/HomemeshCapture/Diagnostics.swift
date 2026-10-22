import Foundation
import MetricKit
import os
import UIKit

/// The app's own rolling event log, kept in the app container as JSON lines, written and flushed per event so it
/// survives a crash. It never holds names or scan content: phases, errors with domain and code, counts, timings.
/// Capped at about 2 MB (the oldest half goes when it is full). Uploaded to the server on launch and after scan uploads
/// (`DiagnosticsUploader`); the server keeps it so the owner does not have to fetch logs from the phone.
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

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "diagnosticsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "diagnosticsEnabled") }
    }

    /// A stable id for this install (not tied to the person or the house): `ios-1a2b3c4d`.
    static var device: String {
        if let s = UserDefaults.standard.string(forKey: "diagnosticsDevice") { return s }
        let s = "ios-" + UUID().uuidString.prefix(8).lowercased()
        UserDefaults.standard.set(s, forKey: "diagnosticsDevice")
        return s
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

/// Sends the event log and MetricKit payloads to the server's `/api/diagnostics`.
@MainActor
final class DiagnosticsUploader: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticsUploader()
    private var client: (() -> Client)?
    private var sending = false
    private static let cursorKey = "diagnosticsCursor"

    /// Subscribes to MetricKit (payloads of past crashes and hangs arrive at launch) and remembers how to reach the server.
    func start(client: @escaping () -> Client) {
        self.client = client
        MXMetricManager.shared.add(self)
        for p in MXMetricManager.shared.pastDiagnosticPayloads { stash(p.jsonRepresentation()) }
        Task { await flush() }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let blobs = payloads.map { $0.jsonRepresentation() }
        Task { @MainActor in
            for b in blobs { self.stash(b) }
            await self.flush()
        }
    }

    // Payloads wait in a folder until the server has them.
    private var pendingDir: URL {
        let d = EventLog.defaultURL.deletingLastPathComponent().appendingPathComponent("diagnostics-pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func stash(_ json: Data) {
        guard !json.isEmpty else { return }
        let name = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).json"
        try? json.write(to: pendingDir.appendingPathComponent(name), options: .atomic)
    }

    /// Uploads the new events and any waiting MetricKit payloads; failures are kept for the next time. Does nothing when
    /// the Settings switch is off.
    func flush() async {
        guard Diagnostics.enabled, !sending, let client = client?() else { return }
        sending = true
        defer { sending = false }
        let dev = Diagnostics.device
        let cursor = UserDefaults.standard.double(forKey: Self.cursorKey)
        if let (data, newest) = EventLog.shared.lines(after: cursor) {
            do {
                _ = try await client.call("POST", "/api/diagnostics?device=\(dev)&kind=events", body: data)
                UserDefaults.standard.set(newest, forKey: Self.cursorKey)
            } catch {
                Self.log.error("event upload failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        for url in (try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil)) ?? [] {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                _ = try await client.call("POST", "/api/diagnostics?device=\(dev)&kind=metrickit", body: data)
                try? FileManager.default.removeItem(at: url)
            } catch {
                Self.log.error("diagnostic payload upload failed: \(error.localizedDescription, privacy: .public)")
                break
            }
        }
    }

    private static let log = Logger(subsystem: "homemesh.capture", category: "diagnostics")
}
