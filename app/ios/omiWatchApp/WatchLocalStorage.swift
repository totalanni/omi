import Foundation
import WatchConnectivity

/// Stores audio recordings locally on the Watch when the phone is unreachable.
/// Files are synced to the phone when the WCSession reconnects.
class WatchLocalStorage: NSObject {
    static let shared = WatchLocalStorage()

    private let directoryName = "omi_recordings"
    private var syncTimer: Timer?
    private var isSyncing = false

    private override init() {
        super.init()
        ensureDirectory()
    }

    // MARK: - Directory

    private var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(directoryName, isDirectory: true)
        return dir
    }

    private func ensureDirectory() {
        let dir = directoryURL
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Save

    /// Save an audio chunk to local storage. Returns the file URL.
    func saveChunk(_ data: Data, chunkIndex: Int, sessionKey: String) -> URL? {
        ensureDirectory()
        let filename = "\(sessionKey)_chunk_\(chunkIndex).pcm"
        let url = directoryURL.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("WatchLocalStorage: Failed to save chunk: \(error)")
            return nil
        }
    }

    /// Save a complete recording (all chunks concatenated).
    func saveRecording(_ data: Data, sessionKey: String) -> URL? {
        ensureDirectory()
        let filename = "\(sessionKey)_recording.pcm"
        let url = directoryURL.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("WatchLocalStorage: Failed to save recording: \(error)")
            return nil
        }
    }

    // MARK: - List pending

    struct PendingRecording {
        let url: URL
        let sessionKey: String
        let chunkIndex: Int
        let data: Data
    }

    func listPending() -> [PendingRecording] {
        ensureDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.fileSizeKey]) else {
            return []
        }
        var pending: [PendingRecording] = []
        for file in files {
            let name = file.lastPathComponent
            guard name.hasSuffix(".pcm") else { continue }
            do {
                let data = try Data(contentsOf: file)
                // Parse filename: <sessionKey>_chunk_<index>.pcm or <sessionKey>_recording.pcm
                let parts = name.split(separator: "_")
                let sessionKey = parts.count > 2 ? parts[0].description : name
                let chunkIndex = parts.count > 2 ? (Int(parts[2].replacingOccurrences(of: "chunk_", with: "")) ?? 0) : 0
                pending.append(PendingRecording(url: file, sessionKey: sessionKey, chunkIndex: chunkIndex, data: data))
            } catch {
                print("WatchLocalStorage: Failed to read \(name): \(error)")
            }
        }
        return pending.sorted { $0.chunkIndex < $1.chunkIndex }
    }

    func deletePending(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func clearAll() {
        try? FileManager.default.removeItem(at: directoryURL)
        ensureDirectory()
    }

    var pendingCount: Int {
        listPending().count
    }

    var hasPendingFiles: Bool {
        pendingCount > 0
    }

    // MARK: - Sync to phone

    /// Sync all pending recordings to the phone via WCSession.
    func syncToPhone(session: WCSession, completion: @escaping () -> Void) {
        guard !isSyncing else {
            completion()
            return
        }
        isSyncing = true

        let pending = listPending()
        guard !pending.isEmpty else {
            isSyncing = false
            completion()
            return
        }

        print("WatchLocalStorage: Syncing \(pending.count) pending recording(s) to phone")

        var synced = 0
        for item in pending {
            let messageData: [String: Any] = [
                "method": "syncPendingRecording",
                "sessionKey": item.sessionKey,
                "chunkIndex": item.chunkIndex,
                "audioData": item.data,
                "isLast": (synced == pending.count - 1)
            ]

            if session.isReachable {
                session.sendMessage(messageData, replyHandler: nil) { error in
                    print("WatchLocalStorage: sendMessage failed, falling back to transferUserInfo: \(error)")
                    session.transferUserInfo(messageData)
                    self.deletePending(item.url)
                    synced += 1
                    if synced == pending.count {
                        self.isSyncing = false
                        completion()
                    }
                }
            } else {
                session.transferUserInfo(messageData)
                self.deletePending(item.url)
                synced += 1
                if synced == pending.count {
                    self.isSyncing = false
                    completion()
                }
            }
        }

        if synced == 0 {
            isSyncing = false
            completion()
        }
    }

    /// Start periodic sync attempts (every 30 seconds) while recordings are pending.
    func startPeriodicSync(session: WCSession) {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.pendingCount > 0 else {
                self.syncTimer?.invalidate()
                return
            }
            self.syncToPhone(session: session) { }
        }
    }

    func stopPeriodicSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
}
