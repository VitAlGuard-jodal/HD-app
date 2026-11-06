#!/bin/sh
# Pleos 에뮬레이터의 차량 CALL 음량 그룹(CarAudioService, 기본 -25 dB = 45단계 중 20)을
# 하드웨어 음량 키로 최대(45 = 0 dB)까지 올린다. 앱 스트림 음량(5/5)과는 별개 값이다.
# 통화가 진행 중일 때(앱이 USAGE_VOICE_COMMUNICATION 포커스를 쥔 상태) 실행해야 키가 CALL 그룹에 간다.
# 사용: sh app/tool/pleos_call_volume.sh [serial=emulator-5554] [presses=25]
set -eu
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
SERIAL="${1:-emulator-5554}"
PRESSES="${2:-25}"
i=0
while [ "$i" -lt "$PRESSES" ]; do
  "$ADB" -s "$SERIAL" shell input keyevent 24 >/dev/null
  i=$((i + 1))
done
"$ADB" -s "$SERIAL" shell dumpsys car_service \
  | grep -B1 "Context: CALL -> Address: bus4_call_out" \
  | grep "Gain indexes"
