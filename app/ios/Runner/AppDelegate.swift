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
  private let routeEvents: FlutterEventChannel
  private let levels = UnavoEventStream()
  private let calls = UnavoEventStream()
  private let routes = UnavoEventStream()
  private var observers: [NSObjectProtocol] = []
  private var engine: AVAudioEngine?
  private var tapInstalled = false
  private var capture: Capture = .none
  private var meterGeneration = 0
  private var routeWork: DispatchWorkItem?
  private var routeSignature = ""
  private var sessionActive = false
  private var requestedOutput: String? // nil prefers external devices, then speaker
  private var interrupted = false
  private var resumeFailed = false
  private var connectedExternalOutputs = Set<String>()
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
    routeEvents = FlutterEventChannel(name: "unavo/audio/routes", binaryMessenger: messenger)
    levels.snapshot = { [weak self] in self?.audioState() ?? [:] }
    calls.snapshot = { [weak self] in self?.callEvent() ?? [:] }
    routes.snapshot = { [weak self] in self?.outputState() ?? [:] }
    audioEvents.setStreamHandler(levels)
    callEvents.setStreamHandler(calls)
    routeEvents.setStreamHandler(routes)
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
    observe(AVAudioSession.routeChangeNotification) { [weak self] note in
      guard let self = self else { return }
      if let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
         reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
        // Rebuild on hardware removal, including a headset hidden by a speaker override.
        self.connectedExternalOutputs.removeAll()
      }
      self.scheduleRouteRefresh()
    }
    observe(.AVAudioEngineConfigurationChange) { [weak self] note in
      guard let self = self, let changed = note.object as? AVAudioEngine, changed === self.engine else { return }
      self.scheduleRouteRefresh()
    }
    observe(AVAudioSession.interruptionNotification) { [weak self] note in
      guard let self = self, let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            self.capture != .none else { return }
      if type == AVAudioSession.InterruptionType.began.rawValue {
        self.interrupted = true
        self.resumeFailed = false
        self.stopMeter()
        // Keep room, AVAudioSession ownership and WebRTC peers. Suspend tracks.
        self.emitAudio()
      } else if type == AVAudioSession.InterruptionType.ended.rawValue {
        do {
          try self.session.setActive(true)
          self.sessionActive = true
          try self.applyOutputRoute()
          try self.startMeter()
          self.interrupted = false
          self.audioError = nil
        } catch {
          self.resumeFailed = true
          self.audioError = "통화 오디오를 재개하지 못했습니다. 다시 연결해 주세요."
        }
        self.emitAudio()
      }
    }
    observe(AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in
      guard let self = self, self.capture != .none else { return }
      do {
        self.sessionActive = false
        try self.configureSession()
        try self.session.setActive(true)
        self.sessionActive = true
        try self.applyOutputRoute()
        try self.startMeter()
        self.interrupted = false
        self.audioError = nil
        self.emitAudio()
      } catch { self.endForSystemEvent("오디오 서비스를 재개하지 못했습니다. 다시 연결해 주세요.") }
    }
    observe(UIApplication.didEnterBackgroundNotification) { [weak self] _ in
      guard let self = self, self.capture == .preview else { return }
      do { try self.releaseCapture() } catch { self.audioError = error.localizedDescription }
      self.emitAudio()
    }
    do {
      // 카테고리만 설정하고 사용자가 시험/통화를 시작하기 전에는 활성화하지 않는다.
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
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
    return ["id": inputID(port), "type": inputType(port), "name": port.portName,
            "webrtcDeviceId": port.uid]
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
    if requestedOutput == "speaker" || requestedOutput == "receiver" {
      return devices.first { $0.portType == .builtInMic }
    }
    if let route = requestedOutput, let port = devices.first(where: { outputName($0.portType) == route }) { return port }
    if requestedOutput == nil {
      for route in ["bluetooth", "carAudio", "headphones"] {
        if let port = devices.first(where: { outputName($0.portType) == route }) { return port }
      }
    }
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
            "isCallActive": capture == .call,
            "error": audioError as Any? ?? NSNull()]
  }

  private func callState() -> [String: Any] {
    return ["roomCode": roomCode as Any? ?? NSNull(),
            "selfHandle": selfHandle as Any? ?? NSNull(), "isStarting": starting,
            "isActive": active, "isStopping": stopping, "error": callError as Any? ?? NSNull()]
  }

  private func emitAudio() {
    levels.sink?(audioState())
    routes.sink?(outputState())
  }

  private func outputName(_ type: AVAudioSession.Port) -> String? {
    switch type {
    case .builtInSpeaker: return "speaker"
    case .builtInReceiver: return "receiver"
    case .bluetoothHFP, .bluetoothLE: return "bluetooth"
    case .headphones, .headsetMic, .usbAudio: return "headphones"
    case .carAudio: return "carAudio"
    default: return nil
    }
  }

  private func availableOutputs() -> [String] {
    let external = Set((session.availableInputs ?? []).compactMap { outputName($0.portType) }
      + session.currentRoute.outputs.compactMap { outputName($0.portType) })
    connectedExternalOutputs.formUnion(external.filter { ["bluetooth", "carAudio", "headphones"].contains($0) })
    return ["bluetooth", "carAudio", "headphones", "speaker", "receiver"].filter {
      $0 == "speaker" || $0 == "receiver" || connectedExternalOutputs.contains($0)
    }
  }

  private func outputState() -> [String: Any] {
    return ["route": session.currentRoute.outputs.compactMap { outputName($0.portType) }.first ?? "speaker",
            "available": availableOutputs(), "interrupted": interrupted, "resumeFailed": resumeFailed,
            "error": audioError as Any? ?? NSNull()]
  }

  private func configureSession() throws {
    var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
    // defaultToSpeaker must be removed for an explicit receiver choice.
    if requestedOutput == "receiver" { options.remove(.defaultToSpeaker) }
    let mode: AVAudioSession.Mode = capture == .preview ? .default : .voiceChat
    if session.category != .playAndRecord || session.mode != mode || session.categoryOptions != options {
      try session.setCategory(.playAndRecord, mode: mode, options: options)
    }
  }

  private func applyOutputRoute() throws {
    if resumeFailed {
      try session.setActive(true)
      sessionActive = true
      interrupted = false
      resumeFailed = false
    }
    if let route = requestedOutput, !availableOutputs().contains(route) { requestedOutput = nil }
    try configureSession()
    // .none allows Bluetooth HFP, wired and CarPlay to win over default speaker.
    let speaker = requestedOutput == "speaker"
    let isSpeaker = session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    if !speaker { try session.overrideOutputAudioPort(.none) }
    refreshDevices()
    try applyPreferredInput()
    if speaker && !isSpeaker { try session.overrideOutputAudioPort(.speaker) }
  }
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
      case "getOutputRoute": result(outputState())
      case "setOutputRoute":
        guard active else { throw failure("통화 연결 후 출력을 변경해 주세요.") }
        guard let route = args["route"] as? String, availableOutputs().contains(route) else {
          throw failure("선택한 출력 장치가 연결되어 있지 않습니다.")
        }
        requestedOutput = route
        try applyOutputRoute()
        audioError = nil
        refreshDevices(); emitAudio(); result(outputState())
      case "setSpeakerphone":
        guard active else { throw failure("통화 연결 후 출력을 변경해 주세요.") }
        requestedOutput = (args["enabled"] as? Bool) == true ? nil : "receiver"
        try applyOutputRoute()
        audioError = nil
        refreshDevices(); emitAudio()
        result(session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker })
      default: result(FlutterMethodNotImplemented)
      }
    } catch {
      audioError = error.localizedDescription
      emitAudio()
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
      case "setMuted": result(nil) // WebRTC track state is owned by Dart.
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
      try configureSession()
      try session.setActive(true)
      sessionActive = true
      refreshDevices()
      try applyOutputRoute()
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
    // WebRTC owns the voice-processing input during calls. The native bridge
    // keeps AVAudioSession and routing active, and meters previews only.
    guard capture == .preview else { return }
    let audioEngine = AVAudioEngine()
    engine = audioEngine
    let input = audioEngine.inputNode
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
    requestedOutput = nil
    interrupted = false
    resumeFailed = false
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
      if self.capture != .none && !self.interrupted {
        do {
          // Applying .none repeatedly can itself emit route-change notifications.
          // Only correct a default/explicit route when it no longer matches.
          let actual = self.session.currentRoute.outputs.compactMap { self.outputName($0.portType) }.first
          let preferred = self.requestedOutput ?? self.availableOutputs().first
          if actual != preferred { try self.applyOutputRoute() }
          if self.capture == .preview && (self.engine?.isRunning != true || self.routeSignature != self.currentSignature()) {
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
    routeEvents.setStreamHandler(nil)
  }
}
