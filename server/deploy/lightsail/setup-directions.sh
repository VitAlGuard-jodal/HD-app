#!/usr/bin/env bash
# 네이버 Directions 5 키를 unavo 서비스 env 로만 넘긴다(값을 출력하지 않음). 길찾기 켜기·끄기는 ROUTE_PROVIDER 로 따로 한다.
# 사용: setup-directions.sh <고정 IP> <pem 키 경로> <키 파일 경로> [disabled|naver]
#   키 파일: NAVER_DIRECTIONS_KEY_ID=… / NAVER_DIRECTIONS_KEY=… 두 줄(주석 줄은 무시). 반영은 다음 서비스 재시작 때.
set -euo pipefail
HOST="${1:?고정 IP}"; KEY="${2:?pem 키 경로}"; ENVF="${3:?키 파일 경로}"; MODE="${4:-disabled}"
case "$MODE" in disabled|naver) ;; *) echo "네 번째 인자는 disabled 또는 naver" >&2; exit 2 ;; esac
HERE="$(cd "$(dirname "$0")" && pwd)"
export UNAVO_KEY="$KEY"
RSH="$HERE/rsh.sh"
# 값은 읽어 출력하지 않고, 두 줄의 형식과 자리표시 여부만 센다.
[ "$(grep -cE '^NAVER_DIRECTIONS_KEY_ID=[[:graph:]]+$' "$ENVF")" = 1 ] && [ "$(grep -cE '^NAVER_DIRECTIONS_KEY=[[:graph:]]+$' "$ENVF")" = 1 ] \
  || { echo "키 파일에 형식이 맞는 두 줄이 없음" >&2; exit 1; }
[ "$(grep -E '^NAVER_DIRECTIONS_KEY' "$ENVF" | grep -c '여기에_')" = 0 ] || { echo "자리표시가 남아 있음" >&2; exit 1; }
grep -E '^NAVER_DIRECTIONS_KEY(_ID)?=' "$ENVF" \
  | "$RSH" "ubuntu@$HOST" 'sudo install -d -m 700 /etc/unavo && sudo tee /etc/unavo/directions.env >/dev/null && sudo chmod 600 /etc/unavo/directions.env'
printf '[Service]\nEnvironmentFile=/etc/unavo/directions.env\nEnvironment=ROUTE_PROVIDER=%s\n' "$MODE" \
  | "$RSH" "ubuntu@$HOST" 'sudo tee /etc/systemd/system/unavo.service.d/directions.conf >/dev/null && sudo chmod 600 /etc/systemd/system/unavo.service.d/directions.conf && sudo systemctl daemon-reload'
echo "설치 완료: ROUTE_PROVIDER=$MODE (다음 재시작부터 적용)"
