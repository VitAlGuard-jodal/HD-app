#!/usr/bin/env bash
# 맥에서 실행. 사용법:
#   deploy.sh setup <고정IP> <pem키경로> <도메인>   VM 초기 설정(한 번)
#   deploy.sh push  <고정IP> <pem키경로>            서버 코드 올리고 재시작
#   deploy.sh logs  <고정IP> <pem키경로>            서비스 로그 꼬리
set -euo pipefail
CMD="${1:?사용법은 파일 머리 주석 참고}"; HOST="${2:?고정 IP}"; KEY="${3:?pem 키 경로}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$(cd "$HERE/../.." && pwd)"
export UNAVO_KEY="$KEY"
RSH="$HERE/rsh.sh"
ssh_run() { "$RSH" "ubuntu@$HOST" "$@"; }
case "$CMD" in
  setup)
    DOMAIN="${4:?도메인}"
    rsync -az -e "$RSH" "$HERE/" "ubuntu@$HOST:unavo-deploy/"
    ssh_run "sudo bash ~/unavo-deploy/setup.sh '$DOMAIN'"
    ;;
  push)
    rsync -az --delete --exclude test --exclude data --exclude deploy --exclude '*.sqlite*' \
      -e "$RSH" "$SERVER_DIR/" "ubuntu@$HOST:/opt/unavo/server/"
    ssh_run "sudo systemctl restart unavo && sleep 1 && systemctl is-active unavo && curl -s -o /dev/null -w 'local /v1/me -> %{http_code}\n' http://127.0.0.1:8787/v1/me"
    ;;
  logs)
    ssh_run "sudo journalctl -u unavo -n 50 --no-pager"
    ;;
  *) echo "알 수 없는 명령: $CMD"; exit 1 ;;
esac
