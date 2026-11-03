#!/usr/bin/env bash
# 우나보 서버 VM 초기 설정 — Lightsail Ubuntu 24.04 에서 한 번만 실행
# 사용법: sudo bash setup.sh <도메인>   (deploy.sh setup 이 대신 호출한다)
set -euo pipefail
DOMAIN="${1:?사용법: sudo bash setup.sh <도메인>}"
[ "$(id -u)" -eq 0 ] || { echo "sudo 로 실행해 주세요"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y curl rsync xz-utils gnupg debian-keyring debian-archive-keyring apt-transport-https

# Node 24: 공식 배포 tarball + SHA256 검증 (파이프 실행 없음)
case "$(uname -m)" in x86_64) NARCH=x64 ;; aarch64) NARCH=arm64 ;; *) echo "지원하지 않는 아키텍처: $(uname -m)"; exit 1 ;; esac
BASE=https://nodejs.org/dist/latest-v24.x
TARBALL="$(curl -fsSL "$BASE/SHASUMS256.txt" | awk -v a="linux-$NARCH.tar.xz\$" '$2 ~ a {print $2; exit}')"
[ -n "$TARBALL" ] || { echo "Node 24 tarball 을 찾지 못했습니다"; exit 1; }
TMP="$(mktemp -d)"
( cd "$TMP" && curl -fsSLO "$BASE/$TARBALL" && curl -fsSL "$BASE/SHASUMS256.txt" | grep " $TARBALL\$" | sha256sum -c - )
mkdir -p /opt/node && tar -xJf "$TMP/$TARBALL" -C /opt/node --strip-components=1
ln -sf /opt/node/bin/node /usr/local/bin/node
ln -sf /opt/node/bin/npm /usr/local/bin/npm
rm -rf "$TMP"
echo "node $(/usr/local/bin/node --version)"

# Caddy: 공식 apt 저장소 (https 인증서 자동 발급·갱신)
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
apt-get update -y && apt-get install -y caddy

# 서비스 계정·디렉터리: 코드는 ubuntu 가 올리고(rsync), 서비스는 unavo 로 돈다
id -u unavo >/dev/null 2>&1 || useradd --system --home /opt/unavo --shell /usr/sbin/nologin unavo
mkdir -p /opt/unavo/server /var/lib/unavo
chown -R ubuntu:unavo /opt/unavo/server && chmod 750 /opt/unavo/server
chown -R unavo:unavo /var/lib/unavo && chmod 700 /var/lib/unavo

install -m 644 "$HERE/unavo.service" /etc/systemd/system/unavo.service
sed "s/__DOMAIN__/$DOMAIN/" "$HERE/Caddyfile" > /etc/caddy/Caddyfile
systemctl daemon-reload
systemctl enable unavo caddy >/dev/null
systemctl restart caddy
echo "초기 설정 완료 ($DOMAIN). 다음: deploy.sh push 로 코드를 올리면 unavo 서비스가 시작됩니다."
