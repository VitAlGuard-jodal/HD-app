# HD-app — 「모두모아」 Pleos Connect 앱

현대자동차 차량용 앱 개발 공모전 출품작의 코드 저장소입니다. 차량(Pleos Connect, Android Automotive API 34)과 폰에서 같이 도는 앱과, 회원가입·친구·통화 방을 담당하는 서버로 이루어집니다.

## 핵심 원칙

1. **사람은 전화번호가 아니라 아이디로 식별한다.** 회원가입 때 정한 아이디가 친구 추가·통화 방 초대·통화 중 발화자 표시의 유일한 식별자다. 전화번호는 어디에도 저장하지 않는다.
2. **통화는 앱 안의 데이터망 음성(WebRTC)으로 한다.** 일반 전화망으로는 제3자 앱이 디스코드식 그룹통화를 만들 수 없다는 조사 결론(2026-10-27 STORM)에 따른다. 미디어 엔진(libwebrtc)은 설치 승인(Q-4) 뒤 붙이며, 그 전까지는 `MediaEngine` 인터페이스 뒤의 빈 구현으로 둔다.
3. **차량에서 돌면 차량 마이크를 쓴다.** 앱이 자동차 기기(`FEATURE_AUTOMOTIVE`)임을 감지하면 입력 장치 중 차량 내장 마이크를 골라 통화 입력으로 잡고, 폰이면 헤드셋·내장 마이크 순으로 고른다. 사용자가 손으로 바꿀 수 있다.

## 구성

| 경로 | 내용 | 실행 |
|---|---|---|
| `server/` | 회원가입·로그인·친구·통화 방·시그널링 서버. Node 24 내장 모듈만 사용(의존성 0). | `cd server && node src/main.ts` |
| `android/` | Kotlin + Jetpack Compose 앱. Pleos Connect 에뮬레이터(API 34)와 폰 공용. | Android Studio 또는 `./gradlew :app:assembleDebug` |
| `docs/` | 설계 문서. `ARCHITECTURE.md` 가 정본. | — |

조사 보고서(그룹통화 통신 방식 STORM, 아키텍처 다이어그램)는 저장소 밖 `~/dist/modumoa-group-call-voip/` 에 있습니다.
