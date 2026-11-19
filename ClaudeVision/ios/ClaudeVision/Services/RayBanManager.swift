import Foundation
import Combine
import UIKit
import MWDATCore
import MWDATCamera

@MainActor
class RayBanManager: NSObject, ObservableObject, FrameSource {

    // MARK: - FrameSource Protocol

    @Published var latestFrame: Data?
    @Published var latestImage: UIImage?
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var connectionStatus: FrameSourceStatus = .disconnected
    @Published var frameCount: Int = 0

    let sourceType: FrameSourceType = .rayBan

    // MARK: - State

    @Published var glassesName: String = "Not Connected"
    @Published var hasActiveDevice: Bool = false
    @Published var registrationState: String = "unregistered"
    @Published var isRegistered: Bool = false

    // DAT SDK (1.x: DeviceSession → Camera → Stream)
    // lazy: Wearables.shared must not be touched before Wearables.configure() runs
    private lazy var deviceSelector = AutoDeviceSelector(wearables: Wearables.shared)
    private var deviceSession: DeviceSession?
    private var camera: MWDATCamera.Camera?
    private let sessionTokens = ListenerTokenBag()
    private let streamTokens = ListenerTokenBag()
    private var deviceMonitorTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?

    private var frameInterval: TimeInterval = 1.0
    private var jpegQuality: CGFloat = 0.5
    private var lastCaptureTime: Date = .distantPast

    // MARK: - Configuration

    func configure(frameInterval: TimeInterval = 1.0, jpegQuality: CGFloat = 0.5) {
        self.frameInterval = frameInterval
        self.jpegQuality = jpegQuality
    }

    // MARK: - Registration (MUST complete before streaming)

    func startMonitoringRegistration() {
        let wearables = Wearables.shared
        registrationTask = Task { @MainActor in
            for await state in wearables.registrationStateStream() {
                switch state {
                case .registered:
                    self.registrationState = "registered"
                    self.isRegistered = true
                    print("[RayBan] Registration complete")
                case .registering:
                    self.registrationState = "registering"
                    print("[RayBan] Registration in progress...")
                case .available, .unavailable:
                    self.registrationState = "unregistered"
                    self.isRegistered = false
                    print("[RayBan] Not registered")
                @unknown default:
                    break
                }
            }
        }

        // Check current state
        let currentState = wearables.registrationState
        switch currentState {
        case .registered:
            isRegistered = true
            registrationState = "registered"
        case .registering:
            registrationState = "registering"
        case .available, .unavailable:
            registrationState = "unregistered"
        @unknown default:
            break
        }
    }

    func register() async {
        guard !isRegistered else {
            print("[RayBan] Already registered")
            return
        }

        do {
            print("[RayBan] Starting registration with Meta AI...")
            connectionStatus = .connecting
            try await Wearables.shared.startRegistration()
        } catch {
            print("[RayBan] Registration error: \(error)")
            connectionStatus = .error("Registration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - FrameSource Implementation

    func start() throws {
        guard !isRunning, deviceSession == nil else { return }

        // Re-check registration state directly from SDK
        let currentState = Wearables.shared.registrationState
        if currentState == .registered {
            isRegistered = true
            registrationState = "registered"
        }

        guard isRegistered else {
            print("[RayBan] Not registered (state: \(currentState)) — starting registration first")
            connectionStatus = .error("Tap 'Connect Glasses' in Settings to register with Meta AI first")
            Task { await register() }
            return
        }

        connectionStatus = .connecting
        startDeviceMonitoring()

        // Step 1: a DeviceSession connects to the glasses (no camera yet)
        let session: DeviceSession
        do {
            session = try Wearables.shared.createSession(deviceSelector: deviceSelector)
        } catch {
            connectionStatus = .error("Couldn't connect to glasses: \(error.localizedDescription)")
            return
        }
        deviceSession = session

        // Subscribe before start() so no state transitions are missed
        session.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in self?.handleSessionState(state) }
        }.store(in: sessionTokens)
        session.errorPublisher.listen { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("[RayBan] Session error: \(error)")
                self.connectionStatus = .error(error.localizedDescription)
            }
        }.store(in: sessionTokens)

        do {
            print("[RayBan] Starting device session...")
            try session.start()
        } catch {
            connectionStatus = .error("Couldn't connect to glasses: \(error.localizedDescription)")
            teardownSession()
        }
    }

    private func startDeviceMonitoring() {
        deviceMonitorTask?.cancel()
        deviceMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await device in self.deviceSelector.activeDeviceStream() {
                self.hasActiveDevice = device != nil
                self.glassesName = device != nil ? "Meta Glasses" : "No Device"
                print("[RayBan] \(device != nil ? "Device active" : "No active device")")
            }
        }
    }

    private func handleSessionState(_ state: DeviceSessionState) {
        print("[RayBan] Session state: \(state.description)")
        switch state {
        case .started:
            // Step 2: once connected, check camera permission and add the camera
            if camera == nil { Task { await self.startCameraWithPermission() } }
        case .starting, .paused, .stopping:
            connectionStatus = .connecting
        case .stopped:
            teardownSession()
        case .idle:
            break
        }
    }

    private func startCameraWithPermission() async {
        do {
            var status = try await Wearables.shared.checkPermissionStatus(.camera)
            if status != .granted {
                print("[RayBan] Requesting camera permission (opens Meta AI)...")
                status = try await Wearables.shared.requestPermission(.camera)
            }
            guard status == .granted else {
                connectionStatus = .error("Camera permission denied. Grant it in the Meta AI app.")
                return
            }
        } catch {
            connectionStatus = .error("Camera permission error: \(error.localizedDescription)")
            return
        }
        beginStream()
    }

    private func beginStream() {
        guard camera == nil, let session = deviceSession, session.state == .started else { return }

        // raw frames so we can turn them straight into UIImages for Claude
        let config = StreamConfiguration(videoCodec: .raw, resolution: .high, frameRate: 24)
        let newCamera: MWDATCamera.Camera
        do {
            guard let c = try session.addCamera(config: config) else {
                connectionStatus = .error("Couldn't start the glasses camera. Try again.")
                return
            }
            newCamera = c
        } catch {
            connectionStatus = .error("Couldn't start the glasses camera: \(error.localizedDescription)")
            return
        }
        camera = newCamera
        let stream = newCamera.stream

        stream.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in self?.handleStreamState(state) }
        }.store(in: streamTokens)

        stream.videoFramePublisher.listen { [weak self] videoFrame in
            // Decode off the main thread; publish on it
            let image = videoFrame.makeUIImage()
            Task { @MainActor [weak self] in
                guard let self, let uiImage = image else { return }
                self.latestImage = uiImage
                self.frameCount += 1

                // Throttle JPEG for Claude
                let now = Date()
                if now.timeIntervalSince(self.lastCaptureTime) >= self.frameInterval {
                    self.lastCaptureTime = now
                    self.latestFrame = uiImage.jpegData(compressionQuality: self.jpegQuality)
                }
            }
        }.store(in: streamTokens)

        stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let msg = self.formatError(error)
                print("[RayBan] Stream error: \(msg)")
                self.connectionStatus = .error(msg)
            }
        }.store(in: streamTokens)

        print("[RayBan] Starting camera stream...")
        stream.start()
    }

    private func handleStreamState(_ state: StreamState) {
        print("[RayBan] Stream state: \(state)")
        switch state {
        case .streaming:
            isRunning = true
            connectionStatus = .connected
        case .stopped:
            isRunning = false
            streamTokens.clear()
            camera?.stop()
            camera = nil
            if deviceSession != nil { connectionStatus = .disconnected }
        case .waitingForDevice, .starting, .stopping, .paused:
            connectionStatus = .connecting
        }
    }

    private func teardownSession() {
        streamTokens.clear()
        sessionTokens.clear()
        camera = nil
        deviceSession = nil
        isRunning = false
        if case .error = connectionStatus {} else { connectionStatus = .disconnected }
    }

    func stop() {
        camera?.stop()
        deviceSession?.stop()   // terminal; cascades to the camera stream
        streamTokens.clear()
        sessionTokens.clear()
        camera = nil
        deviceSession = nil
        deviceMonitorTask?.cancel()
        deviceMonitorTask = nil
        isRunning = false
        connectionStatus = .disconnected
        latestFrame = nil
        latestImage = nil
        glassesName = "Not Connected"
        hasActiveDevice = false
    }

    func consumeFrame() -> Data? {
        return latestFrame
    }

    func cleanup() {
        stop()
        registrationTask?.cancel()
        registrationTask = nil
    }

    // MARK: - Error Formatting

    private func formatError(_ error: StreamError) -> String {
        switch error {
        case .deviceNotFound: return "Glasses not found. Power on and open hinges."
        case .deviceNotConnected: return "Glasses disconnected. Check Bluetooth."
        case .permissionDenied: return "Camera permission denied. Grant in Meta AI app Settings."
        case .hingesClosed: return "Open the glasses hinges to stream."
        case .thermalHot: return "Glasses overheating. Streaming paused."
        case .batteryLow: return "Glasses battery low."
        case .peakPowerLimit: return "Glasses power limit reached. Try again shortly."
        case .timeout: return "Connection timed out. Try again."
        case .videoStreamingError: return "Video stream failed. Restart app."
        default: return error.localizedDescription
        }
    }
}
