#!/usr/bin/env bash
# rsync/ssh 공용 래퍼: 키 경로에 공백이 있어도 안전하게 전달한다 (deploy.sh 가 UNAVO_KEY 를 넘긴다)
exec ssh -i "${UNAVO_KEY:?UNAVO_KEY 미설정}" -o StrictHostKeyChecking=accept-new "$@"
