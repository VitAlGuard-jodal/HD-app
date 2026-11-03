# Lightsail 배포 (unavo-dev)

- VM: AWS Lightsail 서울, Ubuntu 24.04, 5달러 플랜(nano_3_0), 고정 IP 15.164.140.33
- 도메인: https://unavo-dev.kimtaegon.kr (Cloudflare DNS, 프록시 끔 → Caddy 가 Let's Encrypt 자동 발급)
- 구성: Caddy(443) → 127.0.0.1:8787 Node 서버(systemd `unavo`, 사용자 `unavo`), DB `/var/lib/unavo/unavo.sqlite`

```
deploy/lightsail/deploy.sh setup <IP> <pem> <도메인>   # 최초 1회: Node 24(tarball+SHA256)·Caddy·systemd
deploy/lightsail/deploy.sh push  <IP> <pem>            # 코드 올리고 재시작
deploy/lightsail/deploy.sh logs  <IP> <pem>            # journalctl 꼬리
```

pem 키는 레포 밖(개인 정보 폴더)에 두고, 경로에 공백이 있어도 `rsh.sh` 래퍼가 처리한다.
