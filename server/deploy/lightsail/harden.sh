#!/usr/bin/env bash
# 우나보 서버 VM 메모리 보강 — Lightsail nano(RAM 412 MB, 스왑 없음)에서 2026-11-06 먹통 2건 뒤 적용(결정 2 = A+B)
# 근거: docs/ARCHITECTURE.md "서버(Lightsail nano) 먹통 2건과 조치". 멱등이라 여러 번 실행해도 된다.
# 사용법: sudo bash harden.sh   (실서버 unavo-dev 에는 2026-11-06 21:35 KST 에 같은 내용을 적용했다)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "sudo 로 실행해 주세요"; exit 1; }

# A. 자동 업데이트·펌웨어 갱신 끄기 — unattended-upgrades(피크 147 MB)·fwupd(매시간 ~145 MB)가 OOM 을 냈다.
#    보안 업데이트는 배포 때 수동으로 올린다(README).
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer
systemctl mask --now fwupd-refresh.timer fwupd-refresh.service

# B. 1 GB 스왑 파일 — 메모리가 바닥나도 먹통 대신 느려지게.
if [ ! -f /swapfile ]; then
  fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile
fi
swapon /swapfile 2>/dev/null || true
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

echo "== 결과"
for u in apt-daily.timer apt-daily-upgrade.timer fwupd-refresh.timer fwupd-refresh.service; do
  printf '%s: ' "$u"; systemctl is-enabled "$u" 2>&1 || true
done
swapon --show
free -m | head -2
