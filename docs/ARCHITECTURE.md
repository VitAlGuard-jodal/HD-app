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
| `GET /v1/me` | — | `{user}` | |
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
