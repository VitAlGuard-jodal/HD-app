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

## 메모리 보강 (2026-11-06, 결정 2 = A+B)

nano 플랜은 RAM 412 MB·스왑 0 이라 우분투 자동 업데이트(unattended-upgrades)와 fwupd 가 돌 때마다 OOM 이 났고, 11/6 에는 두 번 먹통이 됐다(원인은 `docs/ARCHITECTURE.md`). 새 VM 이나 재구축 때 한 번 실행한다.

```
ssh -i <pem> ubuntu@<IP> 'sudo bash -s' < deploy/lightsail/harden.sh   # apt 타이머 off · fwupd-refresh mask · 1 GB 스왑
```

자동 업데이트를 껐으므로 보안 업데이트는 배포 때 `sudo apt-get update && sudo apt-get upgrade -y` 로 직접 올린다(스왑이 있어 OOM 없이 끝난다, 통화 중이 아닐 때).
