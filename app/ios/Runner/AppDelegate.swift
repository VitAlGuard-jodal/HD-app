import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var audioBridge: UnavoAudioBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "UnavoAudioChannels") {
      audioBridge = UnavoAudioBridge(messenger: registrar.messenger())
    }
  }
}

// 이 파일은 이미 Runner의 Sources에 포함되어 있다. pbxproj 변경 없이 등록한다.
private final class UnavoEventStream: NSObject, FlutterStreamHandler {
  var sink: FlutterEventSink?
  var snapshot: (() -> [String: Any])?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    if let value = snapshot?() { events(value) }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}

/// Android AudioChannel/CallChannel과 같은 메서드 및 상태 맵을 제공한다.
/// 제어와 상태 발행은 main queue, PCM 계산은 AVAudioEngine의 tap에서 처리한다.
final class UnavoAudioBridge {
  private enum Capture { case none, preview, call }
  private let session = AVAudioSession.sharedInstance()
  private let audioMethods: FlutterMethodChannel
  private let callMethods: FlutterMethodChannel
  private let deviceMethods: FlutterMethodChannel
  private let audioEvents: FlutterEventChannel
  private let callEvents: FlutterEventChannel
  private let levels = UnavoEventStream()
  private let calls = UnavoEventStream()
  private var observers: [NSObjectProtocol] = []
  private var engine: AVAudioEngine?
  private var tapInstalled = false
  private var capture: Capture = .none
  private var meterGeneration = 0
  private var routeWork: DispatchWorkItem?
  private var routeSignature = ""
  private var sessionActive = false
  private var speakerRequested = false
  private var requestingPermission = false
  private var devices: [AVAudioSessionPortDescription] = []
  private var manualID: Int?
  private var selected: AVAudioSessionPortDescription?
  private var ids: [String: Int]
  private var level = 0.0
  private var rms = 0
  private var dbfs = -Double.infinity
  private var audioError: String?
  private var roomCode: String?
  private var selfHandle: String?
  private var starting = false
  private var active = false
  private var stopping = false
  private var callError: String?

  init(messenger: FlutterBinaryMessenger) {
    ids = UserDefaults.standard.dictionary(forKey: "unavo.audio.inputIDs") as? [String: Int] ?? [:]
    audioMethods = FlutterMethodChannel(name: "unavo/audio", binaryMessenger: messenger)
    callMethods = FlutterMethodChannel(name: "unavo/call", binaryMessenger: messenger)
    deviceMethods = FlutterMethodChannel(name: "unavo/device", binaryMessenger: messenger)
    audioEvents = FlutterEventChannel(name: "unavo/audio/levels", binaryMessenger: messenger)
    callEvents = FlutterEventChannel(name: "unavo/call/events", binaryMessenger: messenger)
    levels.snapshot = { [weak self] in self?.audioState() ?? [:] }
    calls.snapshot = { [weak self] in self?.callEvent() ?? [:] }
    audioEvents.setStreamHandler(levels)
    callEvents.setStreamHandler(calls)
    audioMethods.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(FlutterError(code: "cancelled", message: "오디오 채널이 닫혔습니다.", details: nil)); return }
      self.handleAudio(call, result)
    }
    callMethods.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(FlutterError(code: "cancelled", message: "통화 채널이 닫혔습니다.", details: nil)); return }
      self.handleCall(call, result)
    }
    deviceMethods.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "isAutomotive": result(false)
      case "hasMicrophone": result(self?.session.isInputAvailable ?? false)
      default: result(FlutterMethodNotImplemented)
      }
    }
    observe(AVAudioSession.routeChangeNotification) { [weak self] _ in self?.scheduleRouteRefresh() }
    observe(.AVAudioEngineConfigurationChange) { [weak self] note in
      guard let self = self, let changed = note.object as? AVAudioEngine, changed === self.engine else { return }
      self.scheduleRouteRefresh()
    }
    observe(AVAudioSession.interruptionNotification) { [weak self] note in
      guard let self = self, let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            type == AVAudioSession.InterruptionType.began.rawValue,
            self.capture != .none else { return }
      self.endForSystemEvent("다른 오디오가 우선되어 마이크를 중지했습니다. 다시 참여해 주세요.")
    }
    observe(AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in
      self?.endForSystemEvent("오디오 서비스가 재시작되었습니다. 다시 참여해 주세요.")
    }
    observe(UIApplication.didEnterBackgroundNotification) { [weak self] _ in
      guard let self = self, self.capture == .preview else { return }
      do { try self.releaseCapture() } catch { self.audioError = error.localizedDescription }
      self.emitAudio()
    }
    do {
      // 카테고리만 설정하고 사용자가 시험/통화를 시작하기 전에는 활성화하지 않는다.
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
    } catch { audioError = error.localizedDescription }
    refreshDevices()
  }

  private func observe(_ name: Notification.Name, handler: @escaping (Notification) -> Void) {
    observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: handler))
  }

  private func inputID(_ port: AVAudioSessionPortDescription) -> Int {
    if let id = ids[port.uid] { return id }
    let id = (ids.values.max() ?? 0) + 1
    ids[port.uid] = id
    UserDefaults.standard.set(ids, forKey: "unavo.audio.inputIDs")
    return id
  }

  private func inputType(_ port: AVAudioSessionPortDescription) -> Int {
    switch port.portType {
    case .builtInMic: return 15
    case .bluetoothHFP: return 7
    case .headsetMic: return 3
    case .usbAudio: return 22
    default: return 0
    }
  }

  private func deviceMap(_ port: AVAudioSessionPortDescription) -> [String: Any] {
    return ["id": inputID(port), "type": inputType(port), "name": port.portName]
  }

  private func refreshDevices() {
    devices = session.availableInputs ?? []
    // 활성화 전에는 availableInputs가 비어 있을 수 있다. 저장된 선택을 보존한다.
    if sessionActive, let id = manualID, !devices.contains(where: { inputID($0) == id }) {
      manualID = nil
    }
    selected = capture == .none ? preferredInput() : session.currentRoute.inputs.first
  }

  private func preferredInput() -> AVAudioSessionPortDescription? {
    if speakerRequested { return devices.first { $0.portType == .builtInMic } }
    if let id = manualID, let port = devices.first(where: { inputID($0) == id }) { return port }
    return devices.first { [7, 3, 22].contains(inputType($0)) }
      ?? devices.first { $0.portType == .builtInMic } ?? devices.first
  }

  private func audioState() -> [String: Any] {
    return ["mode": "phone", "devices": devices.map(deviceMap),
            "selected": selected.map(deviceMap) as Any? ?? NSNull(),
            "manualId": manualID as Any? ?? NSNull(), "level": level, "rms": rms, "dbfs": dbfs,
            "isRecording": capture != .none && engine?.isRunning == true,
            "isPreviewing": capture == .preview && engine?.isRunning == true,
            "error": audioError as Any? ?? NSNull()]
  }

  private func callState() -> [String: Any] {
    return ["roomCode": roomCode as Any? ?? NSNull(),
            "selfHandle": selfHandle as Any? ?? NSNull(), "isStarting": starting,
            "isActive": active, "isStopping": stopping, "error": callError as Any? ?? NSNull()]
  }

  private func emitAudio() { levels.sink?(audioState()) }
  private func callEvent() -> [String: Any] {
    var state = callState()
    state["event"] = "state"
    return state
  }
  private func emitCall() { calls.sink?(callEvent()) }
  private func permissions() -> [String: Bool] {
    // iOS에는 Android 포그라운드 서비스 알림 권한 전제 조건이 없다.
    return ["microphone": session.recordPermission == .granted, "notifications": true]
  }
  private func failure(_ message: String) -> NSError {
    return NSError(domain: "unavo.audio", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  private func handleAudio(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    do {
      switch call.method {
      case "getState": refreshDevices(); result(audioState())
      case "listInputs": refreshDevices(); result(devices.map(deviceMap))
      case "choose":
        manualID = args["id"] as? Int
        audioError = nil
        refreshDevices()
        if capture != .none {
          speakerRequested = false
          try session.overrideOutputAudioPort(.none)
          try applyPreferredInput()
          try startMeter()
        }
        refreshDevices(); emitAudio(); result(audioState())
      case "startPreview":
        guard UIApplication.shared.applicationState == .active else {
          throw failure("화면이 보이는 동안만 마이크 시험을 사용할 수 있습니다.")
        }
        if capture != .call { try startCapture(.preview) }
        result(nil)
      case "stopPreview":
        if capture == .preview { try releaseCapture(); emitAudio() }
        result(nil)
      case "permissions": refreshDevices(); result(permissions())
      case "requestPermissions":
        guard !requestingPermission else {
          result(FlutterError(code: "busy", message: "권한 요청을 확인해 주세요.", details: nil)); return
        }
        requestingPermission = true
        session.requestRecordPermission { [weak self] _ in
          DispatchQueue.main.async {
            guard let self = self else { result(FlutterError(code: "cancelled", message: "요청이 중단되었습니다.", details: nil)); return }
            self.requestingPermission = false
            self.refreshDevices(); self.emitAudio(); result(self.permissions())
          }
        }
      case "openSettings":
        guard let url = URL(string: UIApplication.openSettingsURLString) else { throw failure("설정을 열지 못했습니다.") }
        UIApplication.shared.open(url, options: [:]) { opened in
          result(opened ? nil : FlutterError(code: "audio_error", message: "설정을 열지 못했습니다.", details: nil))
        }
      case "setSpeakerphone":
        guard active else { throw failure("통화에 참여한 뒤 출력을 변경해 주세요.") }
        speakerRequested = args["enabled"] as? Bool ?? false
        try session.overrideOutputAudioPort(.none)
        try applyPreferredInput()
        try session.overrideOutputAudioPort(speakerRequested ? .speaker : .none)
        try startMeter()
        refreshDevices(); emitAudio()
        result(session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker })
      default: result(FlutterMethodNotImplemented)
      }
    } catch {
      if capture != .none { endForSystemEvent(error.localizedDescription) }
      else { audioError = error.localizedDescription; emitAudio() }
      result(FlutterError(code: "audio_error", message: error.localizedDescription, details: nil))
    }
  }

  private func handleCall(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    var ownsTransition = false
    do {
      switch call.method {
      case "getState": result(callState())
      case "start":
        guard let code = args["roomCode"] as? String, let handle = args["handle"] as? String,
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw failure("방 코드와 아이디를 확인해 주세요.")
        }
        guard !stopping, roomCode == nil || roomCode == code else {
          // 이미 활성화된 다른 통화는 잘못된 시작 요청으로 종료하지 않는다.
          result(FlutterError(code: "call_error", message: "현재 통화에서 나간 뒤 다른 방에 참여해 주세요.", details: nil)); return
        }
        if !active {
          ownsTransition = true
          roomCode = code; selfHandle = handle; starting = true; callError = nil; emitCall()
          try startCapture(.call)
          starting = false; active = true; emitCall()
        }
        result(callState())
      case "stop":
        ownsTransition = true
        stopping = true; emitCall()
        try releaseCapture()
        clearCall(); callError = nil; emitCall(); emitAudio()
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    } catch {
      if ownsTransition { endForSystemEvent(error.localizedDescription) }
      result(FlutterError(code: "call_error", message: error.localizedDescription, details: nil))
    }
  }

  private func startCapture(_ kind: Capture) throws {
    guard session.recordPermission == .granted else { throw failure("마이크 권한을 허용해 주세요.") }
    stopMeter()
    capture = kind
    audioError = nil
    do {
      try session.setCategory(.playAndRecord, mode: kind == .call ? .voiceChat : .default, options: [.allowBluetoothHFP])
      try session.setActive(true)
      sessionActive = true
      refreshDevices()
      try applyPreferredInput()
      try startMeter()
      refreshDevices(); emitAudio()
    } catch {
      try? releaseCapture()
      throw error
    }
  }

  private func applyPreferredInput() throws {
    guard let port = preferredInput() else { throw failure("사용 가능한 마이크가 없습니다.") }
    if session.preferredInput?.uid != port.uid { try session.setPreferredInput(port) }
  }

  private func currentSignature() -> String {
    return session.currentRoute.inputs.map { $0.uid }.joined(separator: ",")
      + ":\(session.sampleRate):\(session.inputNumberOfChannels)"
  }

  private func startMeter() throws {
    stopMeter()
    let audioEngine = AVAudioEngine()
    engine = audioEngine
    let input = audioEngine.inputNode
    if capture == .call { try input.setVoiceProcessingEnabled(true) }
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0,
          format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { throw failure("선택한 마이크를 시작하지 못했습니다.") }
    let generation = meterGeneration
    var sum = 0.0
    var samples = 0
    var frames = 0
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
      let frameCount = Int(buffer.frameLength)
      let channelCount = Int(buffer.format.channelCount)
      for channel in 0..<channelCount {
        for frame in 0..<frameCount {
          let sample = Double(channels[channel][frame])
          sum += sample * sample
        }
      }
      samples += frameCount * channelCount
      frames += frameCount
      guard Double(frames) / buffer.format.sampleRate >= 0.1 else { return }
      let normalized = sqrt(sum / Double(samples))
      let rms = min(32768, Int((normalized * 32768).rounded()))
      let dbfs = rms > 0 ? 20 * log10(Double(rms) / 32768) : -Double.infinity
      let level = max(0, min(1, (dbfs + 60) / 60))
      sum = 0; samples = 0; frames = 0
      DispatchQueue.main.async { [weak self] in
        guard let self = self, self.meterGeneration == generation, self.capture != .none else { return }
        self.rms = rms; self.dbfs = dbfs; self.level = level; self.emitAudio()
      }
    }
    tapInstalled = true
    audioEngine.prepare()
    try audioEngine.start()
    routeSignature = currentSignature()
  }

  private func stopMeter() {
    meterGeneration += 1
    engine?.stop()
    if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
    tapInstalled = false
    engine = nil
    level = 0; rms = 0; dbfs = -Double.infinity
  }

  private func releaseCapture() throws {
    routeWork?.cancel(); routeWork = nil
    capture = .none
    stopMeter()
    speakerRequested = false
    guard sessionActive else { return }
    defer { refreshDevices() }
    try? session.overrideOutputAudioPort(.none)
    try? session.setPreferredInput(nil)
    try session.setActive(false, options: .notifyOthersOnDeactivation)
    sessionActive = false
  }

  private func clearCall() {
    roomCode = nil; selfHandle = nil; starting = false; active = false; stopping = false
  }

  private func endForSystemEvent(_ message: String) {
    let hadCall = active || starting || capture == .call
    try? releaseCapture()
    audioError = message
    if hadCall { clearCall(); callError = message; emitCall() }
    emitAudio()
  }

  private func scheduleRouteRefresh() {
    routeWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      self.refreshDevices()
      if self.capture != .none {
        do {
          try self.applyPreferredInput()
          if self.engine?.isRunning != true || self.routeSignature != self.currentSignature() {
            try self.startMeter()
          }
          self.refreshDevices()
        } catch { self.endForSystemEvent(error.localizedDescription) }
      }
      self.emitAudio()
    }
    routeWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
  }

  deinit {
    routeWork?.cancel()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    stopMeter()
    if sessionActive { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
    audioMethods.setMethodCallHandler(nil)
    callMethods.setMethodCallHandler(nil)
    deviceMethods.setMethodCallHandler(nil)
    audioEvents.setStreamHandler(nil)
    callEvents.setStreamHandler(nil)
  }
}
