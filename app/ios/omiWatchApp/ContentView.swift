import SwiftUI
import WatchKit

struct WatchRecorderView<Recorder: WatchRecorderControlling>: View {
    @ObservedObject var viewModel: Recorder
    @StateObject private var presentationController = RecordingPresentationController()
    @State private var isPressed = false
    @State private var showMenu = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Black background
                Color.black
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()

                    // Main recording button
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.1)) {
                            isPressed = true
                        }

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                isPressed = false
                            }
                        }

                        if viewModel.isRecording {
                            viewModel.stopRecording()
                        } else {
                            viewModel.startRecording()
                        }
                    }) {
                        ZStack {
                            if presentationController.phase.showsRecordingRipple {
                                RecordingRippleView()
                            }

                            // Main button circle (white background)
                            Circle()
                                .fill(Color.white)
                                .frame(width: 80, height: 80)
                                .scaleEffect(isPressed ? 1.05 : 1.0)
                                .animation(.easeInOut(duration: 0.15), value: isPressed)

                            Image("OmiLogo")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 40, height: 40)
                                .scaleEffect(isPressed ? 1.05 : 1.0)
                                .animation(.easeInOut(duration: 0.15), value: isPressed)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel(
                        viewModel.isRecording
                            ? Text("watch.accessibility.stopRecording")
                            : Text("watch.accessibility.startRecording")
                    )

                    Spacer()

                    // Status text
                    Group {
                        if viewModel.isRecording, let startedAt = viewModel.recordingStartedAt {
                            if presentationController.phase.showsRecordingRipple {
                                Text("Listening")
                                    .font(.system(size: 16, weight: .medium))
                                    .accessibilityLabel("watch.accessibility.recordingInProgress")
                            } else {
                                Text(startedAt, style: .timer)
                                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .accessibilityLabel("watch.accessibility.elapsedRecordingTime")
                                    .accessibilityValue(startedAt.formatted(date: .omitted, time: .standard))
                            }
                        } else {
                            Text("Tap to Record")
                                .font(.system(size: 16, weight: .medium))
                        }
                    }
                    .foregroundColor(.white)

                    // Connection status indicator
                    HStack(spacing: 4) {
                        Circle()
                            .fill(viewModel.isPhoneReachable ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(viewModel.isPhoneReachable ? "Connected" : "Offline")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }

                    // Pending files indicator
                    if viewModel.hasPendingFiles {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.circle")
                                .font(.system(size: 12))
                                .foregroundColor(.yellow)
                            Text("Pending Sync")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.yellow)
                        }
                    }

                    Spacer()
                        .frame(height: 10)

                    // Menu button
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showMenu.toggle()
                        }
                    }) {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 20))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel("watch.accessibility.menu")
                }
            }
        }
        .task(id: viewModel.recordingStartedAt) {
            await presentationController.update(
                isRecording: viewModel.isRecording,
                startedAt: viewModel.recordingStartedAt
            )
        }
        .onChange(of: scenePhase) { _ in
            // Re-activate WCSession when watch wakes from wrist-down/screen-off
            if scenePhase == .active {
                WKApplication.shared().reopen()
            }
        }
        // Menu overlay
        .overlay(alignment: .bottom) {
            if showMenu {
                WatchMenuView(viewModel: viewModel) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showMenu = false
                    }
                }
            }
        }
    }
}

// MARK: - Watch Menu View

struct WatchMenuView<Recorder: WatchRecorderControlling>: View {
    @ObservedObject var viewModel: Recorder
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            // Menu header
            Text("Omi Menu")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)

            Divider()
                .background(Color.white.opacity(0.2))

            // Start/Stop Recording
            Button(action: {
                if viewModel.isRecording {
                    viewModel.stopRecording()
                } else {
                    viewModel.startRecording()
                }
                onClose()
            }) {
                HStack {
                    Image(systemName: viewModel.isRecording ? "stop.circle" : "record.circle")
                        .font(.system(size: 14))
                    Text(viewModel.isRecording ? "Stop Recording" : "Start Recording")
                        .font(.system(size: 14))
                }
                .foregroundColor(.white)
            }

            // Sync Pending
            Button(action: {
                viewModel.syncPendingToPhone()
                onClose()
            }) {
                HStack {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 14))
                    Text("Sync to Phone")
                        .font(.system(size: 14))
                }
                .foregroundColor(.white)
                .disabled(!viewModel.hasPendingFiles)
            }

            // Streaming Mode
            Button(action: {
                if viewModel.streamingMode == .stream {
                    viewModel.setStreamingMode(.local)
                } else {
                    viewModel.setStreamingMode(.stream)
                }
                onClose()
            }) {
                HStack {
                    Image(systemName: viewModel.streamingMode == .stream ? "wifi" : "internaldrive")
                        .font(.system(size: 14))
                    Text(viewModel.streamingMode == .stream ? "Mode: Stream" : "Mode: Local")
                        .font(.system(size: 14))
                }
                .foregroundColor(.white)
            }

            // Close menu
            Button(action: {
                onClose()
            }) {
                Text("Close")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.95))
        .cornerRadius(12)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

// MARK: - Recording Ripple View

private struct RecordingRippleView: View {
    @State private var rippleScale: CGFloat = 1.0
    @State private var rippleOpacity: Double = 0.8

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 2)
                    .frame(width: 100, height: 100)
                    .scaleEffect(rippleScale)
                    .opacity(rippleOpacity)
                    .animation(
                        .easeOut(duration: 1.5)
                            .repeatForever(autoreverses: false)
                            .delay(Double(index) * 0.3),
                        value: rippleScale
                    )
            }
        }
        .onAppear {
            rippleScale = 2.5
            rippleOpacity = 0
        }
    }
}

#if canImport(WatchConnectivity)
    #Preview {
        WatchRecorderView(viewModel: WatchAudioRecorderViewModel())
    }
#endif
