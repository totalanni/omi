# Apple Watch Changes — Omi App

## Overview

This document describes all modifications made to the Omi app's Apple Watch integration to enable:

1. **Continuous background recording** — the Watch keeps recording even when the screen is off or the wrist is down
2. **Local storage fallback** — when the phone is unreachable, audio is saved directly to the Watch
3. **Automatic sync** — pending recordings are sent to the phone when the WCSession reconnects
4. **Streaming mode toggle** — user can switch between real-time streaming and local-only saving
5. **Watch menu** — a menu overlay for start/stop recording, sync, and mode switching
6. **Auto-reconnect watchdog** — the Dart layer tries to reconnect every 60 seconds, with no retry limit
7. **Quick Action button** — the Watch app can be opened via Quick Action and immediately start recording

---

## Files Modified

### 1. `app/ios/omiWatchApp/WatchLocalStorage.swift` (NEW)

**Purpose:** Stores audio recordings locally on the Watch when the phone is unreachable.

**Key features:**
- Singleton `WatchLocalStorage.shared`
- Stores `.pcm` files in `Application Support/omi_recordings/`
- `saveChunk(_:chunkIndex:sessionKey:)` — saves an audio chunk to disk
- `saveRecording(_:sessionKey:)` — saves a complete recording
- `listPending()` — returns all pending recordings sorted by chunk index
- `deletePending(_:)` — removes a synced file
- `clearAll()` — removes all pending files
- `pendingCount` / `hasPendingFiles` — computed properties for UI
- `syncToPhone(session:completion:)` — sends all pending files to the phone via WCSession
- `startPeriodicSync(session:)` — periodic sync attempts every 30 seconds
- `stopPeriodicSync()` — stops the periodic sync timer

**How it works:**
- When the WCSession is unreachable (phone out of range, watch sleeping), audio chunks are saved to the Watch's disk
- When the WCSession becomes reachable again, `syncToPhone` sends all pending files to the phone
- The phone's `AppDelegate.swift` receives these files via the `syncPendingRecording` message handler and forwards them to Flutter for processing

---

### 2. `app/ios/omiWatchApp/WatchAudioRecorderViewModel.swift`

**Purpose:** The main view model that controls recording, streaming, and sync on the Watch.

**Key changes:**

#### Streaming Mode
- **`StreamingMode` enum** with two values:
  - `.stream` — sends audio to the phone in real-time when reachable
  - `.local` — saves audio locally on the Watch and syncs when the phone reconnects
- **`streamingMode`** published property, persisted to `UserDefaults`
- **`setStreamingMode(_:)`** — switches between modes, saves preference

#### Phone Reachability
- **`isPhoneReachable`** published property — updated on every heartbeat
- **`hasPendingFiles`** published property — shows when recordings are waiting to sync

#### Heartbeat
- **`heartbeatTimer`** — sends a `heartbeat` message every 10 seconds
- Keeps the WCSession alive and detects when the phone becomes unreachable
- If `sendMessage` fails, falls back to `transferUserInfo`

#### Recording
- **`startRecording()`** — checks microphone permission, sets up audio session, starts AVAudioEngine
- **`stopRecording()`** — stops the engine, sends final chunk, cleans up
- **`processAudioBuffer(_:)`** — resamples audio to 16kHz, buffers for 1.5-second chunks
- **`bufferAndSendAudioData(_:)`** — accumulates audio data and sends when buffer is full

#### Streaming Logic
- In `.stream` mode: chunks are sent to the phone via `sendMessage`
- If the phone becomes unreachable mid-send: the chunk falls back to local save
- In `.local` mode: all chunks save locally regardless of phone reachability

#### Sync
- **`syncPendingToPhone()`** — manual sync trigger (called from the watch menu)
- **`sessionDidBecomeReachable`** — auto-sync when the session becomes reachable
- **`syncPending` message handler** — phone can request a sync

#### Scene Phase
- **`scenePhase`** handling in `ContentView.swift` re-activates the WCSession when the watch wakes
- Recording continues even when the screen is off (AVAudioEngine keeps running)

---

### 3. `app/ios/omiWatchApp/ContentView.swift`

**Purpose:** The main watch UI with recording button, status indicators, and menu.

**Key changes:**

#### Recording Button
- Large circular button with Omi logo
- Toggles between start/stop recording
- Ripple animation while recording
- Timer display showing elapsed recording time

#### Status Indicators
- **Connection status** — green dot "Connected" / red dot "Offline"
- **Pending sync indicator** — yellow "Pending Sync" when files are waiting

#### Menu
- **Menu button** (ellipsis icon) at the bottom
- **Menu overlay** with:
  - **Start/Stop Recording** — toggle
  - **Sync to Phone** — manual sync (disabled when no pending files)
  - **Mode: Stream/Local** — toggle streaming mode
  - **Close** — dismiss menu

#### Scene Phase
- **`@Environment(\.scenePhase)`** — watches for active/inactive transitions
- When the watch becomes active (wrist up, screen on): re-activates WCSession via `WKApplication.shared().reopen()`

---

### 4. `app/ios/omiWatchApp/omiwatchApp.swift`

**Purpose:** The watch app entry point with Quick Action handler.

**Key changes:**

#### Quick Action Handler
- **`WKApplicationDelegate`** — handles `WKApplication.shared().open()`
- When the app is opened via Quick Action: immediately starts recording
- **`WatchAudioRecorderViewModel.shared`** — shared reference for the Quick Action handler to access

#### App Structure
- `WindowGroup` with `WatchRecorderView`
- `WKApplicationDelegate` for Quick Action support

---

### 5. `app/ios/Runner/AppDelegate.swift` (iOS host)

**Purpose:** The iOS app's delegate that handles WCSession messages from the Watch.

**Key changes:**

#### `applicationDidBecomeActive`
- Re-activates the WCSession when the iOS app returns to foreground
- Sends `syncPending` message to the Watch to trigger a sync of any pending recordings

#### `didReceiveMessage` handler
- **`syncPendingRecording`** — receives pending files from the Watch and forwards them to Flutter
- **`setStreamingMode`** — receives streaming mode changes from the Watch
- **`heartbeat`** — receives heartbeat messages (no-op, just confirms connection)

#### `didReceiveUserInfo` handler
- Same handlers as `didReceiveMessage` for background delivery
- **`syncPendingRecording`** — receives pending files in background mode

---

### 6. `app/lib/services/devices.dart` (Dart)

**Purpose:** The device service that manages device connections.

**Key changes:**

#### Reconnection Watchdog
- **`_startReconnectionWatchdog()`** — starts a periodic timer
- **Every 60 seconds** — checks if the Watch is connected
- If not connected: re-discovers and reconnects
- **No retry limit** — keeps trying forever
- **`stop()`** — cancels the watchdog timer

#### How it works:
1. `DeviceService.start()` calls `_startReconnectionWatchdog()`
2. Every 60 seconds, the watchdog checks `_connectedDevice`
3. If the Watch is not connected, it runs discovery and attempts to connect
4. If the Watch is connected, it does nothing
5. This runs indefinitely until `stop()` is called

---

### 7. `app/lib/services/devices/connectors/apple_watch_connection.dart` (Dart)

**Purpose:** The Apple Watch connection class.

**Key changes:**

#### Auto-Reconnect
- **`connect()`** — retries up to 3 times with 2-second delays
- If all retries fail, logs an error and gives up
- **`_triggerPendingSync()`** — sends a `syncPending` request to the Watch after connecting

#### How it works:
1. `connect()` is called by the watchdog
2. It tries to connect up to 3 times
3. If successful, it triggers a pending sync
4. If all retries fail, the watchdog will try again in 60 seconds

---

### 8. `app/lib/services/devices/transports/watch_transport.dart` (Dart)

**Purpose:** The transport layer for the Watch connection.

**Key changes:**

#### `requestWatchSync()`
- New method that calls the native `requestWatchSync()` via Pigeon
- Triggers a sync of pending recordings from the Watch to the phone

---

### 9. `app/lib/pigeon_interfaces.dart` (Dart)

**Purpose:** The Pigeon interface definitions for Dart↔iOS communication.

**Key changes:**

#### `requestWatchSync()`
- New method added to `WatchRecorderHostAPI`
- `@SwiftFunction('requestWatchSync()')`
- Returns `Future<void>`

---

### 10. `app/ios/Runner/RecorderHostApiImpl.swift` (iOS native)

**Purpose:** The iOS native implementation of the Watch recorder host API.

**Key changes:**

#### `requestWatchSync()`
- Sends a `syncPending` message to the Watch via WCSession
- Triggers the Watch to sync all pending recordings to the phone

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        Apple Watch                               │
│                                                                 │
│  ┌──────────────────────┐     ┌──────────────────────┐         │
│  │  WatchAudioRecorder  │     │   WatchLocalStorage   │         │
│  │  ViewModel           │────▶│   (saves .pcm files)  │         │
│  │                      │     └──────────┬───────────┘         │
│  │  - startRecording()  │                │                     │
│  │  - stopRecording()   │                │ syncToPhone()        │
│  │  - heartbeat         │                ▼                     │
│  │  - streamingMode     │     ┌──────────────────────┐         │
│  │  - isPhoneReachable  │     │     WCSession         │         │
│  └──────────────────────┘     └──────────┬───────────┘         │
│                                          │                     │
└──────────────────────────────────────────┼─────────────────────┘
                                           │
              ┌────────────────────────────┼────────────────────┐
              │                             │                    │
              ▼                             ▼                    │
   ┌─────────────────────┐     ┌─────────────────────┐          │
   │   iOS AppDelegate   │     │  RecorderHostApi    │          │
   │   (WCSession        │     │  Impl (Pigeon)      │          │
   │   delegate)         │     │                     │          │
   │                     │     │  - requestWatchSync()│          │
   │  - syncPending      │     └─────────────────────┘          │
   │  - setStreamingMode │                                     │
   └──────────┬──────────┘                                     │
              │                                                 │
              ▼                                                 │
   ┌─────────────────────┐                                     │
   │   Flutter/Dart      │                                     │
   │                     │                                     │
   │  - DeviceService    │                                     │
   │    (watchdog 60s)   │                                     │
   │  - AppleWatch       │                                     │
   │    Connection        │                                     │
   │  - WatchTransport   │                                     │
   └─────────────────────┘                                     │
              │                                                 │
              ▼                                                 │
   ┌─────────────────────┐                                     │
   │   Audio Processing  │                                     │
   │   (Flutter)         │                                     │
   └─────────────────────┘                                     │
                                                              │
                                                              │
   ┌──────────────────────────────────────────────────────────┘
   │
   │  Auto-reconnect: every 60 seconds, no retry limit
   │  Streaming: real-time when reachable, local save when not
   │  Sync: auto on reconnect, manual via menu
   │
   └──────────────────────────────────────────────────────────────
```

## User Flow

### 1. Normal Operation (Phone in Range)
1. User taps the recording button on the Watch
2. `WatchAudioRecorderViewModel.startRecording()` is called
3. Audio is captured by AVAudioEngine, resampled to 16kHz
4. In `.stream` mode: chunks are sent to the phone in real-time via WCSession
5. The phone's `AppDelegate` receives the chunks and forwards them to Flutter
6. Flutter processes the audio (transcription, etc.)

### 2. Phone Out of Range
1. WCSession becomes unreachable
2. `isPhoneReachable` becomes false
3. In `.stream` mode: chunks fall back to local save
4. In `.local` mode: all chunks save locally
5. `WatchLocalStorage` saves the chunks to the Watch's disk
6. `hasPendingFiles` becomes true, showing the "Pending Sync" indicator

### 3. Phone Reconnects
1. WCSession becomes reachable
2. `sessionDidBecomeReachable` fires
3. `WatchLocalStorage.syncToPhone()` sends all pending files to the phone
4. The phone's `AppDelegate` receives the files and forwards them to Flutter
5. `hasPendingFiles` becomes false

### 4. Manual Sync
1. User taps the menu button (ellipsis icon)
2. User taps "Sync to Phone"
3. `syncPendingToPhone()` is called
4. All pending files are sent to the phone

### 5. Switching Streaming Mode
1. User taps the menu button
2. User taps "Mode: Stream" or "Mode: Local"
3. `setStreamingMode()` is called
4. The preference is saved to UserDefaults
5. Future recordings use the new mode

### 6. Quick Action
1. User taps the Quick Action button on the Watch
2. `WKApplicationDelegate` handles the open
3. `WatchAudioRecorderViewModel.shared.startRecording()` is called
4. Recording starts immediately

### 7. Auto-Reconnect
1. Dart `DeviceService` watchdog runs every 60 seconds
2. If the Watch is not connected, it re-discovers and reconnects
3. No retry limit — keeps trying forever
4. After reconnecting, `_triggerPendingSync()` sends a sync request

## Technical Details

### Audio Pipeline
1. **Capture:** AVAudioEngine input node captures at the hardware sample rate (typically 48kHz)
2. **Resample:** AVAudioConverter resamples to 16kHz mono
3. **Buffer:** Audio is buffered for 1.5-second chunks
4. **Send:** Chunks are sent via WCSession `sendMessage` or saved locally
5. **Sync:** Pending chunks are synced when the phone reconnects

### WCSession States
- **Active:** Phone and Watch are in range, messages flow both ways
- **Inactive:** Phone is out of range or Watch is sleeping, messages may be delayed
- **Deactivated:** Session is completely down, needs re-activation

### Scene Phase
- **Active:** Watch screen is on, user is interacting
- **Inactive:** Watch screen is off or wrist is down
- Recording continues in both states (AVAudioEngine keeps running)
- WCSession is re-activated when the watch becomes active

### Heartbeat
- Sent every 10 seconds
- Keeps the WCSession alive
- Detects when the phone becomes unreachable
- If `sendMessage` fails, falls back to `transferUserInfo`

### Local Storage
- Files are stored in `Application Support/omi_recordings/`
- Format: `<sessionKey>_chunk_<index>.pcm`
- Max 10 pending files (oldest deleted first)
- Synced to the phone when the WCSession reconnects

## Limitations

1. **Watch battery:** Continuous recording drains the Watch battery. The user should be aware of this.
2. **Storage:** The Watch has limited storage. Long recordings may fill up the disk.
3. **WCSession reliability:** WCSession can be flaky depending on phone/watch proximity and iOS version.
4. **Background execution:** The Watch app may be suspended by iOS in some cases. The scene phase handler helps, but it's not a guarantee.
5. **Audio quality:** 16kHz mono is lower quality than the original 48kHz stereo. This is a trade-off for bandwidth.

## Testing Checklist

- [ ] Recording starts and stops correctly
- [ ] Audio streams to the phone when in range
- [ ] Audio saves locally when phone is out of range
- [ ] Pending files sync when phone reconnects
- [ ] Manual sync works from the menu
- [ ] Streaming mode toggle works
- [ ] Quick Action starts recording
- [ ] Auto-reconnect watchdog works
- [ ] Scene phase handling works (wrist down/up)
- [ ] Heartbeat keeps the session alive
- [ ] Battery indicator updates
- [ ] Connection status indicator updates
