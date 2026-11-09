# 설계 정본 (2026-10-28)

## 1. 식별 모델 — 아이디가 곧 사람

- `users.handle`: 로그인 아이디. 소문자 영문·숫자·밑줄, 3~20자, 유일. 바꿀 수 없다.
- `users.display_name`: 화면 표시 이름(2~20자). 바꿀 수 있다.
- 비밀번호는 `node:crypto` `scrypt` 로 해시(무작위 16바이트 솔트, N=16384, r=8, p=1, 64바이트).
- 토큰은 무작위 32바이트(base64url). 서버는 SHA-256 해시만 저장. 유효 30일.
- 전화번호·이메일 필드는 없다. 친구·방 초대·시그널링 수신자 지정은 전부 `handle` 로 한다.

## 2. 서버 API (v1, JSON, `Authorization: Bearer <token>`)

| 메서드·경로 | 본문 | 응답 | 비고 |
|---|---|---|---|
| `POST /v1/auth/signup` | `{handle, password, displayName}` | `201 {user, token}` | 중복 아이디 `409` |
| `POST /v1/auth/login` | `{handle, password}` | `200 {user, token}` | 실패 `401` |
| `POST /v1/auth/logout` | — | `204` | 토큰 폐기. 그 토큰으로 열린 SSE 연결도 즉시 닫는다(다른 기기의 토큰은 유지) |
| `GET /v1/me` | — | `{user, room: null 또는 {code, name, createdBy, createdAt, members}}` | `left_at IS NULL`인 방 중 `joined_at`이 가장 최근인 하나(동률은 방 ID 내림차순) |
| `GET /v1/users/{handle}` | — | `{user}` 공개 정보(handle, displayName) | 없으면 `404`, 아이디 형식이 틀리면 `400` |
| `PATCH /v1/me` | `{displayName}` | `200 {user}` | 표시 이름 변경 |
| `GET /v1/contacts` | — | `{contacts:[user]}` | |
| `POST /v1/contacts` | `{handle}` | `201 {contact}` | 자기 자신·중복 `409` |
| `DELETE /v1/contacts/{handle}` | — | `204` | |
| `POST /v1/rooms` | `{name?, invitees?:[handle]}` | `201 {room}` | 만든 사람은 자동 참여 |
| `GET /v1/rooms/{code}` | — | `{room, members:[{handle, displayName, joinedAt}]}` | |
| `POST /v1/rooms/{code}/join` | — | `200 {room}` | 코드는 대소문자 구분 없이 받아 대문자로 정규화 |
| `POST /v1/rooms/{code}/leave` | — | `204` | |
| `GET /v1/rooms/{code}/events` | — | `text/event-stream` | 아래 이벤트 |
| `POST /v1/rooms/{code}/signal` | `{to: handle, kind, payload}` | `202` | `kind` ∈ offer·answer·ice·custom |

SSE 이벤트(`event:` 이름 / `data:` JSON): `hello{self}`, `member-joined{handle}`, `member-left{handle}`, `signal{from, kind, payload}`, 15초마다 `: ping` 주석.

시그널링을 WebSocket 이 아니라 SSE + POST 로 한 이유: Node 내장 모듈만으로 되고(설치 승인 불필요), 음성 시그널링은 초당 수 건이라 충분하다. WebSocket 으로 바꿀 일이 생기면 이 두 엔드포인트만 교체한다.

저장소는 `node:sqlite`(파일 `server/data/hdapp.sqlite`). 표: `users`, `tokens`, `contacts`, `rooms`, `room_members`.

## 3. 앱 구조 (`android/app`, 패키지 `kr.modumoa.hdapp`)

| 패키지 | 역할 |
|---|---|
| `auth` | 회원가입·로그인 화면, 토큰 보관(`SharedPreferences`, 프로토타입) |
| `net` | `HttpURLConnection` 기반 API 클라이언트, SSE 구독(코루틴) |
| `contacts` | 친구 목록·아이디로 추가 |
| `room` | 방 만들기·코드로 참여·참여자(아이디) 목록. 버튼은 둘로 나눈다: 「통화 참여/통화 끊기」(FGS·마이크만 켜고 끔, 방에는 남음)와 「방 나가기」(서버 leave + 통화 끊기 + 목록으로) |
| `audio` | **마이크 경로 결정**(아래 4절)·입력 레벨 측정 |
| `call` | `CallForegroundService`(FGS 유형 `microphone`, 알림 카테고리 `service`·ongoing — Pleos 에서 `call` 카테고리는 런처 통화 카드로 가고 버튼이 반응하지 않았음), `MediaEngine` 인터페이스 + `NoopMediaEngine` |

빌드: AGP 9.1.0 · Kotlin 2.4.0 · Gradle 9.3.1 · compileSdk 37 · **minSdk 28(Pleos 요구)** · **targetSdk 34(Pleos Connect 에뮬레이터 API 34)** · Compose BOM 2026.09.00 · JDK 17 타깃. 모든 액티비티에 `distractionOptimized=true` 메타데이터(주행 중 가려지지 않게, 에뮬레이터 실측 §8.2).

## 4. 마이크 정책 (`audio.MicRouter`)

1. `PackageManager.hasSystemFeature(FEATURE_AUTOMOTIVE)` 이면 **차량 모드**.
2. `AudioManager.getDevices(GET_DEVICES_INPUTS)` 로 입력 장치를 모은다. Pleos 에뮬레이터 실측 7개: Built-In Mic, Built-In Back Mic, Remote Submix In, FM Tuner, Tone Generator 0·1, Echo-Reference Mic.
3. 후보 순위
   - 차량 모드: `TYPE_BUILTIN_MIC` → (없으면) `TYPE_BLUETOOTH_SCO`·`TYPE_USB_HEADSET`·`TYPE_WIRED_HEADSET` → 나머지. `TYPE_ECHO_REFERENCE`·`TYPE_FM_TUNER`·`TYPE_REMOTE_SUBMIX`·`TYPE_TELEPHONY`·`TYPE_BUS` 는 제외.
   - 폰 모드: `BLUETOOTH_SCO`·`USB_HEADSET`·`WIRED_HEADSET` → `BUILTIN_MIC`.
4. 적용: `AudioManager.mode = MODE_IN_COMMUNICATION`, 오디오 포커스 `GAIN_TRANSIENT`(`USAGE_VOICE_COMMUNICATION`), `AudioRecord(VOICE_COMMUNICATION, 16 kHz, 모노, 16비트)` 에 `setPreferredDevice()` 로 **입력만** 고정한다. 통신(출력) 장치는 플랫폼 기본에 맡긴다 — 에뮬레이터 실측(2026-10-28)에서 `VOICE_COMMUNICATION` 용도만으로 차량 통화 버스 `bus4_call_out` 이 활성화됐고, `setCommunicationDevice()` 는 출력 장치용이라 입력 id 와 짝이 맞지 않는다. 오디오 객체 생성·시작·정지는 메인 스레드가 아니라 IO 디스패처에서 한다(실측 716 ms 멈춤). 통화가 끝나면 전부 되돌린다(`MODE_NORMAL`, 포커스 반납).
5. `AudioDeviceCallback` 으로 장치가 꽂히거나 빠지면 다시 고른다. 사용자가 수동으로 고른 장치는 그 장치가 사라질 때까지 유지한다.
6. 검증용 로그 태그 `HDAUDIO`: `mode=car|phone`, `inputs=[type:name#id,...]`, `chosen=type:name#id`, 100 ms 마다 `rms=NNN`. 장치 이름은 `productName` 에 `address` 가 있으면 덧붙인다(에뮬레이터는 7개 전부 productName 이 "Car on arm64 emulator" 라 id·주소로만 구별된다).
7. 레벨 표시는 dBFS 로그 눈금(−60 dBFS=0, 0 dBFS=1). 마이크 화면에 「마이크 시험」 토글을 두어 통화에 참여하지 않아도 화면이 보이는 동안 입력 레벨을 본다(FGS 없음, 화면을 떠나면 중지).

근거: 에뮬레이터 실측에서 `MODE_IN_COMMUNICATION`·`AUDIOFOCUS_GAIN_TRANSIENT`·마이크 입력·`bus4_call_out` 출력이 모두 동작(2026-10-23 P2). AEC·덕킹은 OEM HAL 몫이라 실차 검증 항목으로 남긴다.

## 5. 통화(미디어) — 보류 중

- 경로: libwebrtc(Android) + Opus 20 ms 모노 + NetEq + 손실 시 FEC + SFU(한국 리전) + TURN + ICE restart. 자세한 근거는 `~/dist/modumoa-group-call-voip/`.
- 지금은 `MediaEngine` 인터페이스(`join(room, self)`, `leave()`, `setMuted()`, `onRemoteSpeaking(handle)`) 와 `NoopMediaEngine` 만 둔다. libwebrtc 의존성 추가는 **Q-4 승인 뒤**.
- 참여 흐름은 "출발 전 보이는 화면에서 참여 → FGS 유지 → 망 바뀌면 자동 재합류" 로 고정(GMS 없음·API 34 마이크 FGS 제한 때문).

## 6. 결정 대기 (태곤 님)

- Q-3 앱 이름·패키지명(`kr.modumoa.hdapp` 임시).
- Q-4 libwebrtc(Android AAR)·SFU 설치 승인.
- 서버 배포 위치(Cloud Run 등)와 TURN 운영 주체.

## 7. 단일 앱·모드 분기·플랫폼 채널 3종 (Flutter F1, 2026-10-29)

앱은 `app/`의 Flutter 단일 프로젝트다. Android applicationId와 iOS bundle ID는 `kr.modumoa.hdapp`이다. 폰 레이아웃을 기본으로 사용하고, Android `FEATURE_AUTOMOTIVE`가 true이면 `DeviceMode.car`로 분기한다. F1의 `CarShell`은 같은 폰 화면을 감싸며 F2에서 차량 레이아웃으로 교체한다. 별도 폰/차량 앱을 만들지 않는다.

Dart는 인증·서버 주소·HTTP/SSE·방 세션·미디어 엔진 인터페이스 및 화면 상태를 소유한다. 상태 관리는 ChangeNotifier, 화면 이동은 기본 Navigator다. HTTP/SSE는 dart:io HttpClient, 영속 저장은 shared_preferences, SVG 아이콘은 flutter_svg를 사용한다.

플랫폼 채널은 세 종류다. `unavo/device`는 automotive/마이크 기능을 조회한다. `unavo/audio`는 기존 Kotlin MicRouter의 장치 선택·자동 복귀·권한·입력 시험·스피커 출력을 연결하고 `unavo/audio/levels`에서 100ms 레벨 상태를 받는다. `unavo/call`은 microphone foreground service를 시작/종료하며 `unavo/call/events`에서 상태·알림 끊기·방 열기 이벤트를 받는다.

Android 입력 시험은 앱 소유 MicRouter가 관리하고 화면 이탈·통화 시작 전에 중지한다. F3 통화 캡처는 WebRTC가 소유하며 FGS는 포커스와 microphone 서비스 수명을 관리한다. iOS도 AVAudioSession을 네이티브 채널이 관리하고 통화 중 AVAudioEngine 미터를 중지한다. 통화 끊기는 미디어·마이크·FGS만 정리하고 방 멤버십/SSE를 유지한다. 방 나가기는 서버 leave까지 수행한다. 알림의 비공개 브로드캐스트는 네이티브 통화 상태를 종료하고 Dart에 WebRTC 정리를 전달한다.

Android SDK는 min 28 / target 34 / compile 37이다. 모든 Flutter 화면은 같은 서버 API와 같은 계정을 사용한다. Android/iOS의 기본 MediaEngine은 F3의 WebRtcMediaEngine이며, Noop은 테스트·미지원 플랫폼용이다. 기존 `android/` Compose 차량 앱의 캡처 구현은 이 변경에 포함하지 않는다.

## 8. 4인 음성 풀 메시와 TURN (Flutter F3, 2026-11-03)

`MeshCoordinator`는 Flutter에 의존하지 않고 피어 생성·SDP 순서·ICE 대기열·정원을 관리한다. 새 통화 참여자가 `hello.members` 및 이후 멤버 갱신의 기존 참여자에게 offer를 보낸다. 기존 참여자는 member-joined에서 offer를 만들지 않는다. 동시 offer는 handle 사전순으로 작은 쪽이 유지하고, 큰 쪽은 피어를 교체해 answer한다. 협상 ID로 늦은 answer·ICE·끊기 이벤트를 구분하며, SDP 이전 ICE는 보관한다. 입장 순서상 첫 4명만 통화할 수 있고 나머지는 기존 통화를 방해하지 않고 대기한다.

`GET /v1/turn`은 인증 후 만료 Unix 초와 handle로 username을 만들고 HMAC-SHA1(secret, username)의 base64 credential을 발급한다. STUN은 자격 없이, TURN은 secret이 있을 때만 제공하며 응답은 no-store다. WebRtcMediaEngine은 TTL의 80% 시점에 설정을 갱신한다. 안정된 피어의 ICE restart는 작은 handle이 제안하고, 응답이 없는 오퍼는 새 피어로 교체해 오래된 TURN 후보가 재전송되지 않게 한다.

로컬은 오디오 트랙 하나를 각 피어에 공유하고, 음소거는 enabled만 바꾼다. 원격 음성은 네이티브 WebRTC 재생을 사용하며 500ms마다 수신 audioLevel > 0.02를 발화로 표시한다. 실제 통신·라우팅과 알림/백그라운드 동작은 실기기 검증 대상이다.

테스트용 ICE 정책 스위치(F5a, 2026-11-04): `--dart-define=UNAVO_ICE_POLICY=relay` 를 주면 PeerConnection 에 `iceTransportPolicy: relay` 를 넣어 TURN 경로를 강제한다. 기본은 `all` 이며 설정 키를 생략한다. 같은 커밋에서 오디오 SDP 의 transport-cc(rtcp-fb 줄과 transport-wide-cc extmap 줄)를 양쪽 SDP 에서 제거한다 — 음성 전용이라 TWCC 대역폭 추정이 필요 없고, 차가 보낸 꼬인 수신 보고가 폰 WebRTC 를 초당 10만 줄 로그로 질식시켜 40초 만에 죽던 문제(iPhone 12 ↔ Pleos, TURN 경로 실측) 를 막는다. iOS 는 WebRTC 로그 수준을 error 로 내린다.

**createOffer 제약 맵(F5c, 2026-11-05).** flutter_webrtc 네이티브의 `createOffer` 제약은 `mandatory` 맵과 `optional` 리스트 아래에 WebRTC 키 이름(`IceRestart`, `OfferToReceiveAudio`, `OfferToReceiveVideo`)으로만 전달되며, 최상위의 `iceRestart`·`offerToReceiveAudio` 같은 키는 iOS·Android 모두 무시한다. `app/lib/call/webrtc_media_engine.dart`의 `offerConstraints`가 이 제약 맵의 단일 출처이며, ICE 재시작을 요청할 때만 `mandatory`에 `IceRestart: true`를 포함한다. 11/5 아이폰 와이파이→LTE 전환 실측에서 최상위 키로는 재시작이 일어나지 않아(로컬 ufrag 불변) 통화가 영구 끊김으로 남았던 결함의 수정이다.

**시그널 백로그와 SSE 침묵 타임아웃(F6a/F6b, 2026-11-06).** 참여자의 데이터가 끊기면 그 SSE 소켓은 서버 쪽에서 한동안 살아 있는 것으로 남아, `hub.sendTo` 가 죽은 소켓에 쓰고도 `delivered:true` 를 돌려준다(11/6 실측: 차 데이터 차단 뒤 서버가 끊김을 안 시각이 2분 뒤). 그래서 서버는 signal 을 수신자별로 60초·64건까지 보관(`RoomEventHub.queueSignal`)하고, 수신자가 events 를 다시 열면 hello 직후 보관분을 순서대로 재전송한다(`replaySignals`). 앱의 `MeshCoordinator.onSignal` 은 negotiationId 로 중복 offer/answer 를 무시하므로 재전송은 안전하다. leave 시 그 수신자 몫은 지운다(`clearSignals`). 앱은 SSE 원시 바이트 침묵 타임아웃을 35초에서 20초(서버 ping 15초 + 여유 5초, `ApiClient.sseSilenceTimeout`)로 줄여 죽은 연결을 더 빨리 다시 연다.

**차량 통화 음량은 CarAudioService 의 CALL 그룹이 정한다(2026-11-06).** Pleos 에뮬레이터 실측: 앱 수신 게인 100%·`STREAM_VOICE_CALL` 5/5 최대인데도 폰→차 소리가 운전 중 듣기엔 작았다. 원인은 그 아래 차량 오디오 서비스의 볼륨 그룹 게인으로, CALL 그룹(`bus4_call_out`)이 기본 −25 dB(45단계 중 20)였다(`dumpsys car_service` 의 `Gain indexes`). 이 값은 앱이 못 쓰고 하드웨어 음량 키로만 움직이며, 통화 중 VOLUME_UP 을 보내면 CALL 그룹만 올라간다(MUSIC 그룹 불변). 25번 보내 45(0 dB)로 올리자 앱 변경 없이 "적당" 판정(태곤 님). 결정: 차에는 추가 게인을 얹지 않는다(휠 음량을 올렸을 때 깨질 수 있음). 시연 전 `app/tool/pleos_call_volume.sh` 로 올린다. 실차의 기본 CALL 음량은 OEM 값이라 확인 필요.

**서버(Lightsail nano) 먹통 2건과 조치(2026-11-06).** 1차 15:56~16:07 KST: 우분투 자동 업데이트(`apt-daily-upgrade`, unattended-upgrades 메모리 피크 147 MB)와 fwupd 가 RAM 412 MB·스왑 0 인 VM 에서 같이 돌아 OOM·스래싱(부하 16~18). HTTPS·SSH·TURN 전부 무응답이었고 OOM 킬러가 두 번 죽인 뒤 돌아왔다. 우나보 서비스는 재시작 0회로 살아 있었다. 2차 16:42~21:30: 1차 스래싱 중 `systemd-networkd` 가 `ens5: Could not set route: Connection timed out → ens5: Failed` 로 인터페이스 관리를 포기해 DHCP 갱신이 멈췄고, 임대가 끝난 16:42 에 주소와 기본 경로가 사라졌다. OS 는 살아서 저널을 계속 썼지만(ssm-agent "network is unreachable") 네트워크만 죽어 상태 점검이 실패했고, 재부팅으로 복구했다. 저널을 보면 fwupd 가 11/3 부터 매시간 ~145 MB 를 할당하다 OOM 으로 죽기를 수십 번 반복한 만성 압박이 깔려 있었다. 조치(결정 2 = A+B, `server/deploy/lightsail/harden.sh`): apt 타이머 2개 disable, `fwupd-refresh` mask, 1 GB 스왑 파일(fstab). 앱에서는 설계대로 SSE 끊김 배너가 떴고, 요청 타임아웃은 Dart `Future.timeout` 기본 문구 "Future not completed" 로 보였다(사용자 문구로 바꿀 항목).

**서버 유휴 데몬 정리(결정 4, 2026-11-09).** 재부팅 뒤에도 유휴 사용량이 412 MB 중 243 MB 라, 이 VM 에서 할 일이 없는 우분투 기본 데몬 셋을 껐다(`harden.sh` C 절): multipathd(다중 경로 저장장치용, `multipath -ll` 대상 0개, RSS 27 MB), ModemManager(모뎀 0개), unattended-upgrades.service(종료 시 진행 중 업데이트를 기다리는 데몬, 타이머를 끈 뒤 용도 없음, RSS 18 MB). 적용 직후 243 → 197 MB, unavo·caddy·coturn 영향 없음. snapd 와 amazon-ssm-agent(합계 약 27 MB)는 Lightsail 브라우저 SSH 의존 여부를 확인하지 못해 남겼다. 부수 관찰: SSH 로그인 때마다 motd 의 `release-upgrade-motd`(check-new-release, 파이썬) 가 약 85 MB 를 잠깐 쓴다 — 로그인 순간에만 생기는 스파이크라 조치 보류.

## 9. 차량 캡처 잡음 제거(RNNoise)와 진단 스위치 (Flutter F7a·F7c, 2026-11-06~09)

**구성.** 안드로이드 전용 플러그인 `app/packages/unavo_noise`(경로 의존성). flutter_webrtc 1.6.3 의 `AudioProcessingController.capturePostProcessing`(WebRTC 캡처 처리 **후단**) 에 `RnnoiseProcessor` 를 붙여 10 ms float32 프레임(int16 스케일)을 RNNoise(`src/rnnoise`, Xiph BSD-3, 사본·라이선스는 `licenses/rnnoise`) 로 처리한다. RNNoise 는 48 kHz·480 프레임만 받으므로 `WebRtcMediaEngine` 이 안드로이드에서 첫 flutter_webrtc 호출로 `WebRTC.initialize(audioSampleRate: 48000)` 을 건다. 어댑터는 뒤늦게 붙은 프로세서에 `initialize` 를 다시 불러 주지 않아 프로세서가 `numFrames*100` 으로 샘플레이트를 자가 인식한다. x86 에뮬레이터 빌드를 위해 상류 헤더를 함께 담고 `src/shim/os_support.h` 로 메모리 함수를 대체한다. 상류의 게인 감쇠 변경(bb18d2f)은 적용하지 않았다(오프라인 하네스: 지연 20 ms, 프레임 경계 클릭 없음, 게인 계단 p95 0.23 dB). iOS 는 같은 훅(`ExternalAudioProcessingDelegate`)이 있어 F7b 에서 같은 구조로 간다.

**스위치(`--dart-define`).** `UNAVO_NOISE=off` RNNoise 끔(프로세서를 떼어냄). `UNAVO_APM=off` getUserMedia 의 echoCancellation·noiseSuppression·autoGainControl 전부 false. `UNAVO_CAPTURE_DUMP=<초>` 캡처 처리 후단 신호를 16-bit PCM 으로 앱 외부 파일 폴더에 저장(`capture-in-*.pcm`, RNNoise 켜져 있으면 `capture-out-*.pcm` 도). 오디오 스레드는 복사·큐 적재만 하고 데몬 writer 가 쓴다. `UNAVO_CAPTURE_EXPORT_PORT=18085` 앱 안 루프백 HTTP 로 덤프를 내보낸다(`/list`, `/file/<이름>`, `/clear`). Pleos 에뮬레이터는 user 빌드·앱은 user 10 이라 adb 가 그 폴더를 못 읽어 이 통로가 필요하다. 회수: `adb forward tcp:18085 tcp:18085` 뒤 `curl http://127.0.0.1:18085/list`. 기본값(전부 미지정)에서는 세 스위치 모두 꺼져 기존 동작과 같다.

**11/9 실측(찌지직 원인).** 폰에서 "말하기 전부터 LP 표면음 같은 찌지직"이 들리던 문제는 RNNoise 도 48 kHz 도 아니었다(끈 빌드·F7a 이전 커밋 빌드 모두 동일). 캡처 덤프와 맥 마이크 동시 녹음을 비교하니 버스트 포락선이 일치했고(상관 0.70), 맥 마이크만 정지 15초=버스트 0, 타자 15초=초당 10.6 으로, **맥북 키보드·손 충격음이 몸체를 타고 내장 마이크로 들어간 것**이었다. 사슬: 충격음 → 에뮬레이터 호스트 오디오 경로 약 +14 dB(APM 을 꺼도 같음) → WebRTC NS 는 히스만 −13 dB → RNNoise 는 바닥을 −86 dBFS 로 지우되 충격음은 음성으로 판정(VAD p50 0.98, 82% > 0.5)해 통과 → 폰 +6 dB(200%). 무음 위에 툭툭만 남아 LP 질감이 된다. 에뮬레이터 캡처 스레드엔 기기 효과 체인이 0개라 처리는 WebRTC 것뿐이다. 조치(결정 6-A): 시연·녹화 중 맥에 손을 대지 않고 맥 입력 음량을 낮춰 피크(−2 dBFS) 여유를 둔다. RNNoise 의 VAD 로는 충격음과 말소리 시작부를 구별하지 못하므로(둘 다 ≈1.0) VAD 기반 충격음 억제는 쓰지 않는다. 측정 도구는 세션 스크래치(`analysis/analyze.py`·`analyze2.py`·`diag-run.sh`)에 있다.

**소프트 바닥(F7d, 결정 7-A′, 2026-11-09).** RNNoise 가 조용한 바닥을 −95 dBFS 까지 지워 "완전한 무음 위의 충격음"이 LP 표면음처럼 들리는 대비를 줄이려고, `SoftFloor.kt` 가 RNNoise 출력에 2 프레임(960 샘플, RNNoise 지연과 동일) 늦춘 입력을 섞는다. 섞는 이득은 `min(0.5, TARGET_RMS/rIn)`(목표 −63 dBFS) 로 입력이 클수록 자동으로 줄고, 내릴 땐 즉시·올릴 땐 프레임당 20% 로 평활해 충격음·말소리가 들어오는 프레임엔 섞이지 않는다. 어택 제한(무음에서 열릴 때 상승 속도 제한)은 실제 캡처 시뮬레이션에서 충격음 감쇠 0·말소리 음절 사이 최대 −16 dB 손상이라 넣지 않았다. 실기기(Pleos 에뮬레이터, 타자 중) 전후: 조용한 프레임 −95.1 → −64.2 dBFS, 말소리 −0.26 dB, 충격음 출력은 소프트 바닥으로 되살아나지 않음(p50 −60.5), 조용 구간 1 ms 포락선 p99−p50 54 → 21 dB. 끄기: `--dart-define=UNAVO_NOISE_FLOOR=off`.

## 10. 통화 안정성 묶음 (F8a·F8b, 2026-11-09 코드리뷰 결함 수정)

**재참여 정책.** 엔진의 `MediaConnectionState.failed` 는 "모든 피어가 failed 이고 복구(ICE restart·재오퍼)가 소진된" 종단 실패에만 쓴다(`receiveConnectionState()` 한 곳에서 판정). TURN 자격 갱신 실패·수신 음량 적용 실패·마이크 선택 실패는 경고(`mediaError`)로만 올리고 기존 피어를 보존한다. `RoomSession` 은 종단 failed 에서만 1·2·4초 재참여를 건다. 이전에는 자격 갱신 타임아웃 하나로 멀쩡한 메시를 전부 허물었다.

**offer 시한과 돌아온 쪽의 재제안.** `meshOfferTimeout = 8초` 안에 answer 가 없으면 피어를 닫고 새 negotiationId 로 재오퍼(간격 8·16·24초, 최대 3회, 56초에 종단 실패). `MeshCoordinator.reconcile(members)` 는 살아 있는 피어도 진행 중 협상도 없는 상대에게 **새 멤버 규칙과 무관하게** offer 를 보낸다. `RoomSession` 은 SSE 재접속 뒤 `Hello`·`Reconnected` 에서 이미 미디어에 참여한 경우 `mediaEngine.reconcilePeers()` 를 부른다. 11/9 실측(상대 SSE 가 내려간 사이 보낸 offer 유실 → 양쪽 영구 대기)의 수정이다. 글레어는 기존 규칙(사전순으로 작은 handle 이 자기 offer 유지·재전송)대로.

**복귀 정책(태곤 님 결정 11/9).** 프로세스가 살아 있는 채 통신만 끊겼다 돌아오면(터널) 같은 방에 자동 재입장하고 통화를 잇는다(위 reconcile). 앱을 **새로 켠 경우**(사용자가 끈 것이든 시스템이 죽인 것이든)는 메인 화면에 머물고 마이크·통화를 자동으로 켜지 않는다. `restoreSession` 은 `/v1/me` 만 읽어 `RoomSession.restorableRoom` 에 두고, 폰 방 목록·차 대시보드가 "참여 중인 방" 카드(방 이름·코드 + 입장 아이콘) 한 장을 보여 준다. 카드 탭 → 기존 입장 경로(`open` → hello → 자동 통화). `AppServices.initialize()` 의 네이티브 통화 상태 기반 자동 open 도 제거했다.

**수신 이득 상한 100%.** libwebrtc 는 수신 볼륨을 saturated cast 로 곱하므로 ×2.0 이면 −6 dBFS 위 샘플이 전부 잘리고, 차 송신 피크는 0 dBFS 로 실측됐다. `callVolume` 0~100(저장값 200 은 읽을 때 100), 슬라이더 max 100, 엔진 `_playbackVolume ≤ 1.0`. 소리 크기는 출력 경로(스피커/수화부) 결함을 고쳐 확보한다(묶음 2).

**타임아웃 문구.** `api_client.dart` 의 모든 `.timeout` 에 `onTimeout` 을 주어 `ApiException(0,'timeout','서버 응답 없음')` 을 던진다("Future not completed" 제거).

**안드로이드 오디오 포커스·FGS.** 영구 `AUDIOFOCUS_LOSS` 는 캡처 해제 + "다른 오디오가 우선되어 통화가 중단되었습니다" 로 통화 종료(이전 동작 복원), `LOSS_TRANSIENT`/`CAN_DUCK` 은 `isInterrupted` 로 올려 폰·차 내 카드에 마이크 꺼짐 아이콘과 "다른 오디오 때문에 잠시 중단" 을 표시한다. `CallForegroundService` 는 출력 경로 전환 실패를 `outputError` 로만 보고하고 통화를 시작하며, 통화 중 마이크 경로 오류는 1초 뒤 한 번 재적용하고 재실패 시 깨끗이 종료한다(열화 상태 지속 금지).

**서버.** `RoomEventHub` 가 30초 주기(`unref`)로 만료된 시그널 백로그를 전역 스윕한다(이전엔 같은 수신자를 다시 만질 때만 정리돼 복귀 없는 사용자마다 최대 64건이 영구 잔류). `GET /v1/rooms/:code` 는 `publicRoom + listRoomMembers` 로 응답을 직접 구성한다(바이트 동일).

**테스트 주의(F8c).** 위젯 테스트에서 `pumpAndSettle` 은 주기 타이머(SSE·자격 갱신·재오퍼·애니메이션) 때문에 끝나지 않는다 — 고정 `pump` 만 쓴다. 가짜 MethodChannel 핸들러 **안**에서 `expect` 를 호출하면 실패가 호출 쪽 catchError 에 삼켜져 테스트에 드러나지 않는다 — 핸들러는 기록만 하고 본문에서 검증한다. 각 testWidgets 에 30초 timeout.

## 11. 잡음 제거 방향 (결정 9-A, 2026-11-09)

**RNNoise 는 기본값에서 끈다**(`UNAVO_NOISE` 기본 `off`, 플러그인·스위치는 실험용으로 유지). 근거: 11/9 실기기 캡처에서 RNNoise 가 사용자의 생목소리 프레임 56% 를 잡음으로 판정(VAD<0.5)해 32~46 dB 깎았고(TTS 음성은 0 dB 통과), 폰에서 "말하는데 아무 소리도 안 들림"의 직접 원인이었다. 기기 출력과 오프라인 RNNoise 출력이 0.1 dB 차이로 같아 구현 결함이 아니라 모델 판정이다. 원인 후보(WebRTC NS 선처리와의 이중 처리·낮은 SNR·마이크 거리)는 가르지 않았다.

**기본 체인** = WebRTC 내장 처리(에코 제거·잡음 억제·자동 이득). 완료 기준은 블루투스 핸즈프리 통화급(상대 말소리 지연·끊김 없음, 말 안 할 때 거슬리는 소리 없음). 기준을 넘으면 잡음 트랙은 종료하고, 새 잡음 변수가 떠올라도 소거법으로 확장하지 않는다. 부족하다고 판단될 때만 ① 캡처 A(WebRTC 처리 끔 + RNNoise)로 이중 처리 가설 확인 → ② 같은 훅에서 GTCRN(초소형·MIT) / DeepFilterNet3(지연 +40 ms·연산 9배) 를 캡처 도구로 "목소리 보존 0 dB·바닥 감쇠" 수치 비교해 이기는 것만 채택. 기획서 문구는 "WebRTC 표준 잡음 억제 적용, 학습형 모델은 실험 모듈로 탑재".

**시연 환경(결정 6-A).** 찌지직의 실제 음원은 맥북 키보드·손·쿨링팬 충격음이 몸체를 타고 내장 마이크로 들어간 것. 시연·녹화 중 맥에 손을 대지 않고 맥 입력 음량을 낮춰 피크(실측 0 dBFS)에 여유를 둔다. 같은 방에 폰과 차를 두면 에코 제거기가 자기 목소리를 에코로 지워(26~43 dB) 음질 판단이 왜곡되므로, 음질 시험은 폰 마이크 음소거 또는 다른 방에서 한다.
