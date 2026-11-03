#!/usr/bin/env bash
# 우나보 TURN 서버(coturn) 설치 — Lightsail VM 에서 sudo 로 한 번 실행
# 사용법: sudo bash setup-turn.sh <도메인> <공인IP>
# 비밀값(static-auth-secret)은 /etc/unavo/turn.secret 에 만들고 unavo 서비스 env 로만 넘긴다(출력하지 않음).
# Lightsail 방화벽(3478 tcp+udp, 49152-65535 udp)은 별도로 연다.
set -euo pipefail
DOMAIN="${1:?도메인}"; PUBLIC_IP="${2:?공인 IP}"
[ "$(id -u)" -eq 0 ] || { echo "sudo 로 실행해 주세요"; exit 1; }
PRIVATE_IP="$(hostname -I | awk '{print $1}')"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y coturn openssl >/dev/null

install -d -m 700 /etc/unavo
SECRET_FILE=/etc/unavo/turn.secret
[ -s "$SECRET_FILE" ] || { umask 077; openssl rand -hex 32 > "$SECRET_FILE"; }
chmod 600 "$SECRET_FILE"
SECRET="$(cat "$SECRET_FILE")"

cat > /etc/turnserver.conf <<CONF
listening-port=3478
listening-ip=$PRIVATE_IP
external-ip=$PUBLIC_IP/$PRIVATE_IP
realm=$DOMAIN
server-name=$DOMAIN
fingerprint
lt-cred-mech
use-auth-secret
static-auth-secret=$SECRET
min-port=49152
max-port=65535
no-tls
no-dtls
no-multicast-peers
no-cli
simple-log
log-file=/var/log/turnserver.log
CONF
chown root:turnserver /etc/turnserver.conf && chmod 640 /etc/turnserver.conf
if grep -q '^#\?TURNSERVER_ENABLED=' /etc/default/coturn 2>/dev/null; then
  sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
else
  echo 'TURNSERVER_ENABLED=1' >> /etc/default/coturn
fi

# unavo 서버가 TURN 자격을 발급할 수 있게 비밀값을 systemd drop-in 으로 주입(root 전용 파일)
install -d -m 755 /etc/systemd/system/unavo.service.d
umask 077
cat > /etc/systemd/system/unavo.service.d/turn.conf <<ENV
[Service]
Environment=TURN_SECRET=$SECRET
Environment=TURN_REALM=$DOMAIN
Environment=TURN_URIS=turn:$DOMAIN:3478?transport=udp,turn:$DOMAIN:3478?transport=tcp,stun:$DOMAIN:3478
Environment=TURN_TTL_SECONDS=3600
ENV
chmod 600 /etc/systemd/system/unavo.service.d/turn.conf

systemctl daemon-reload
systemctl enable coturn >/dev/null
systemctl restart coturn
systemctl restart unavo
echo "coturn: $(systemctl is-active coturn) / unavo: $(systemctl is-active unavo)"
echo "TURN 설정 완료 ($DOMAIN, $PUBLIC_IP/$PRIVATE_IP)"
