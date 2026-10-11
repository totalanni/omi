import Foundation
import Combine
import WatchConnectivity
import AVFoundation

@MainActor
class WatchAudioRecorderViewModel: NSObject, WatchRecorderControlling {
    @Published var isRecording: Bool = false
    @Published private(set) var recordingStartedAt: Date?
    @Published var hasPendingFiles: Bool = false
    @Published var isStreaming: Bool = false
    @Published var isPhoneReachable: Bool = false

    /// Streaming mode: .stream sends audio to phone in real-time when reachable.
    /// .local saves audio locally on the watch and syncs when phone reconnects.
    enum StreamingMode: String {
        case stream = "stream"
        case local = "local"
    }

    @Published var streamingMode: StreamingMode = .stream

    var session: WCSession
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var audioBuffer: AVAudioPCMBuffer?
    private var chunkIndex: Int = 0
    private var inputFormat: AVAudioFormat?
    private var audioConverter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var detectedSampleRate: Double = 0.0

    // Audio buffering for multi-second chunks
    private var chunkBuffer: Data = Data()
    private var bufferStartTime: Date?
    private let bufferDuration: TimeInterval = 1.5 // 1.5 second chunks

    // Local storage for offline recordings
    private var sessionKey: String = UUID().uuidString
    private var heartbeatTimer: Timer?
    private let heartbeatInterval: TimeInterval = 10.0 // 10 second heartbeat

    init(session: WCSession = .default) {
        self.session = session
        super.init()
        self.session.delegate = self
        session.activate()

        BatteryManager.shared.startBatteryMonitoring()
        BatteryManager.shared.sendWatchInfo()

        // Start periodic sync of any pending recordings
        WatchLocalStorage.shared.startPeriodicSync(session: session)

        // Start heartbeat to keep session alive
        startHeartbeat()

        // Load saved streaming mode preference
        if let savedMode = UserDefaults.standard.string(forKey: "watch_streaming_mode") {
            if let mode = StreamingMode(rawValue: savedMode) {
                self.streamingMode = mode
            }
        }
    }

    deinit {
        heartbeatTimer?.invalidate()
        WatchLocalStorage.shared.stopPeriodicSync()
    }

    // MARK: - Streaming Mode

    func setStreamingMode(_ mode: StreamingMode) {
        streamingMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "watch_streaming_mode")
        print("WatchAudioRecorderViewModel: Streaming mode set to \(mode.rawValue)")
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.sendHeartbeat()
        }
    }

    private func sendHeartbeat() {
        let heartbeatData: [String: Any] = [
            "method": "heartbeat",
            "timestamp": Date().timeIntervalSince1970
        ]
        if session.isReachable {
            session.sendMessage(heartbeatData, replyHandler: nil)
            isPhoneReachable = true
        } else {
            session.transferUserInfo(heartbeatData)
            isPhoneReachable = false
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else {
            return
        }

        // Check microphone permissions and setup audio session
        checkMicrophonePermissionAndSetup { [weak self] success in
            guard let self = self else {
                return
            }

            if success {
                self.setupAudioStreaming()
                self.recordingStartedAt = Date()
                self.isRecording = true
                self.sessionKey = UUID().uuidString
                self.session.sendMessage(["method": "startRecording", "sessionKey": self.sessionKey], replyHandler: nil)
            } else {
                self.session.sendMessage(["method": "recordingError", "error": "Microphone permission denied"], replyHandler: nil)
            }
        }
    }

    func stopRecording() {
        guard isRecording else {
            return
        }

        isRecording = false
        recordingStartedAt = nil
        isStreaming = false

        // Stop audio streaming
        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        inputNode = nil
        audioEngine = nil

        // Clean up resampling resources
        audioConverter = nil
        targetFormat = nil
        detectedSampleRate = 0.0

        // Send any remaining buffered data and final chunk
        sendFinalAudioChunk()

        // Reset buffer state
        chunkBuffer = Data()
        bufferStartTime = nil

        session.sendMessage(["method": "stopRecording", "sessionKey": sessionKey], replyHandler: nil)
    }

    // MARK: - Audio Buffering & Sending

    private func bufferAndSendAudioData(_ audioData: Data) {
        // Initialize buffer start time on first data
        if bufferStartTime == nil {
            bufferStartTime = Date()
        }

        // Add data to buffer
        chunkBuffer.append(audioData)

        // Check if we've buffered for target duration
        let currentTime = Date()
        guard let startTime = bufferStartTime else { return }
        let elapsedTime = currentTime.timeIntervalSince(startTime)

        if elapsedTime >= bufferDuration {
            // Send the accumulated buffer
            sendBufferedAudioChunk()

            // Reset buffer for next window
            chunkBuffer = Data()
            bufferStartTime = currentTime
        }
    }

    private func sendBufferedAudioChunk() {
        guard !chunkBuffer.isEmpty else { return }

        let messageData: [String: Any] = [
            "method": "sendAudioChunk",
            "audioChunk": chunkBuffer,
            "chunkIndex": chunkIndex,
            "isLast": false,
            "sampleRate": 16000.0,
            "sessionKey": sessionKey
        ]

        // Decide: stream to phone or save locally
        if streamingMode == .stream && session.isReachable {
            // Stream to phone in real-time
            session.sendMessage(messageData, replyHandler: nil) { error in
                // Phone became unreachable mid-send — save locally
                self.saveChunkLocally(chunkBuffer, chunkIndex: chunkIndex)
                self.chunkIndex += 1
            }
        } else {
            // Save locally (either in local mode or phone unreachable)
            saveChunkLocally(chunkBuffer, chunkIndex: chunkIndex)
            chunkIndex += 1
        }

        chunkIndex += 1
    }

    private func sendFinalAudioChunk() {
        if !chunkBuffer.isEmpty {
            sendBufferedAudioChunk()
        }

        let finalMessageData: [String: Any] = [
            "method": "sendAudioChunk",
            "audioChunk": Data(),
            "chunkIndex": chunkIndex,
            "isLast": true,
            "sampleRate": 16000.0,
            "sessionKey": sessionKey
        ]

        if session.isReachable {
            session.sendMessage(finalMessageData, replyHandler: nil) { error in
                self.session.transferUserInfo(finalMessageData)
            }
        } else {
            session.transferUserInfo(finalMessageData)
        }
    }

    // MARK: - Local Storage

    private func saveChunkLocally(_ data: Data, chunkIndex: Int) {
        let url = WatchLocalStorage.shared.saveChunk(data, chunkIndex: chunkIndex, sessionKey: sessionKey)
        if url != nil {
            print("WatchAudioRecorderViewModel: Saved chunk \(chunkIndex) locally")
            hasPendingFiles = WatchLocalStorage.shared.hasPendingFiles
        }
    }

    /// Manually trigger a sync of pending recordings to the phone.
    func syncPendingToPhone() {
        guard session.isReachable else {
            print("WatchAudioRecorderViewModel: Cannot sync — phone not reachable")
            return
        }
        WatchLocalStorage.shared.syncToPhone(session: session) {
            print("WatchAudioRecorderViewModel: Manual sync complete")
            self.hasPendingFiles = WatchLocalStorage.shared.hasPendingFiles
        }
    }

    // MARK: - Permissions

    private func checkMicrophonePermissionAndSetup(completion: @escaping (Bool) -> Void) {
        let audioSession = AVAudioSession.sharedInstance()

        let permissionStatus = audioSession.recordPermission

        switch permissionStatus {
        case .granted:
            setupAudioSessionAfterPermission(completion: completion)

        case .denied:
            completion(false)

        case .undetermined:
            // Request permission
            audioSession.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupAudioSessionAfterPermission(completion: completion)
                    } else {
                        completion(false)
                    }
                }
            }

        @unknown default:
            completion(false)
        }
    }

    private func setupAudioSessionAfterPermission(completion: @escaping (Bool) -> Void) {
        let audioSession = AVAudioSession.sharedInstance()

        do {
            try audioSession.setCategory(.playAndRecord,
                                       mode: .default,
                                       options: [.mixWithOthers, .allowBluetooth])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            completion(true)
        } catch {
            completion(false)
        }
    }

    func requestMicrophonePermissionOnly() {

        let audioSession = AVAudioSession.sharedInstance()
        let permissionStatus = audioSession.recordPermission

        switch permissionStatus {
        case .granted:
            session.sendMessage(["method": "microphonePermissionResult", "granted": true], replyHandler: nil)

        case .denied:
            session.sendMessage(["method": "microphonePermissionResult", "granted": false], replyHandler: nil)

        case .undetermined:
            // Request permission - this will show the permission dialog
            audioSession.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    self?.session.sendMessage([
                        "method": "microphonePermissionResult",
                        "granted": granted
                    ], replyHandler: nil)
                }
            }

        @unknown default:
            // Send failure result to main app
            session.sendMessage(["method": "microphonePermissionResult", "granted": false], replyHandler: nil)
        }
    }

    // MARK: - Audio Streaming

    private func setupAudioStreaming() {

        do {
            audioEngine = AVAudioEngine()
            inputNode = audioEngine?.inputNode

            let inputFormat = inputNode?.inputFormat(forBus: 0)
            print("Input format: \(String(describing: inputFormat))")
            let hardwareSampleRate = inputFormat?.sampleRate ?? 0
            print("Hardware microphone sample rate: \(hardwareSampleRate)Hz")
            print("Channels: \(inputFormat?.channelCount ?? 0)")

            // Store the detected sample rate
            self.detectedSampleRate = hardwareSampleRate

            guard let inputFormat = inputFormat else {
                print("Failed to get input format")
                return
            }
            self.inputFormat = inputFormat

            // Create target format for 16kHz resampling
            guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16000.0, channels: 1) else {
                print("Failed to create target format")
                return
            }
            self.targetFormat = targetFormat

            // Create audio converter for resampling
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                print("Failed to create audio converter")
                return
            }
            self.audioConverter = converter

            let bufferSize: AVAudioFrameCount = 512

            inputNode?.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] (buffer, time) in
                self?.processAudioBuffer(buffer)
            }

            try audioEngine?.start()
            isStreaming = true
            chunkIndex = 0

        } catch {
            print("Error details: \(error.localizedDescription)")
        }
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isStreaming else { return }

        // Validate buffer
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            print("Buffer has zero frames")
            return
        }

        // Resample audio to 16kHz
        let processedBuffer: AVAudioPCMBuffer
        if let converter = audioConverter, let targetFormat = targetFormat {
            let outputFrameCapacity = AVAudioFrameCount(ceil(Double(frameLength) * 16000.0 / detectedSampleRate))
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
                print("Failed to create output buffer for resampling")
                return
            }

            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

            if let error = error {
                print("Audio conversion error: \(error)")
                return
            }

            processedBuffer = outputBuffer
        } else {
            processedBuffer = buffer
        }

        // Convert resampled buffer to 16-bit PCM data
        let channelData = processedBuffer.floatChannelData?[0]

        var pcmData = [Int16]()
        var hasNonZeroData = false

        if let channelData = channelData {
            let processedFrameLength = Int(processedBuffer.frameLength)
            for i in 0..<processedFrameLength {
                let sample = channelData[i]

                if abs(sample) > 0.01 { hasNonZeroData = true }

                let pcmSample = Int16(max(-32768, min(32767, sample * 32767)))
                pcmData.append(pcmSample)
            }
        } else {
            print("No channel data available")
            return
        }

        let byteData = pcmData.withUnsafeBufferPointer { buffer in
            return Data(buffer: buffer)
        }

        // Buffer audio data for target-duration chunks
        bufferAndSendAudioData(byteData)
    }
}

// MARK: - WCSessionDelegate

extension WatchAudioRecorderViewModel: WCSessionDelegate {
#if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {
        print("WatchAudioRecorderViewModel: Session became inactive")
        isPhoneReachable = false
    }
    public func sessionDidDeactivate(_ session: WCSession) {
        print("WatchAudioRecorderViewModel: Session deactivated")
        isPhoneReachable = false
    }
#endif

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        if activationState == .activated {
            print("WatchAudioRecorderViewModel: Session activated — syncing pending recordings")
            isPhoneReachable = true
            // Sync any pending recordings when session becomes active
            WatchLocalStorage.shared.syncToPhone(session: session) {
                print("WatchAudioRecorderViewModel: Sync complete")
                self.hasPendingFiles = WatchLocalStorage.shared.hasPendingFiles
            }
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        Task {
            guard let method = message["method"] as? String else { return }
            switch method {
            case "startRecording":
                self.startRecording()
            case "stopRecording":
                self.stopRecording()
            case "requestMicrophonePermission":
                self.requestMicrophonePermissionOnly()
            case "requestBattery":
                BatteryManager.shared.sendBatteryLevel()
            case "requestWatchInfo":
                BatteryManager.shared.sendWatchInfo()
            case "syncPending":
                // Phone is requesting a sync of pending recordings
                WatchLocalStorage.shared.syncToPhone(session: self.session) {
                    self.hasPendingFiles = WatchLocalStorage.shared.hasPendingFiles
                }
            case "setStreamingMode":
                if let modeString = message["mode"] as? String,
                   let mode = StreamingMode(rawValue: modeString) {
                    self.setStreamingMode(mode)
                }
            default:
                print("Unknown method: \(method)")
            }
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
        Task {
            guard let method = userInfo["method"] as? String else { return }
            switch method {
            case "requestBattery":
                BatteryManager.shared.sendBatteryLevel()
            case "requestWatchInfo":
                BatteryManager.shared.sendWatchInfo()
            case "syncPending":
                WatchLocalStorage.shared.syncToPhone(session: self.session) {
                    self.hasPendingFiles = WatchLocalStorage.shared.hasPendingFiles
                }
            case "setStreamingMode":
                if let modeString = userInfo["mode"] as? String,
                   let mode = StreamingMode(rawValue: modeString) {
                    self.setStreamingMode(mode)
                }
            default:
                print("Unknown background method: \(method)")
            }
        }
    }
}
