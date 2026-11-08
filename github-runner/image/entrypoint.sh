#!/bin/bash
set -euo pipefail
cd /home/runner
registration_token="$(/usr/bin/python3 register.py)"
unset GITHUB_APP_PRIVATE_KEY
./config.sh --url "$GH_URL" --token "$registration_token" --unattended --ephemeral \
  --labels "$RUNNER_LABELS" --name "aca-$(hostname)" --work _work
unset registration_token
exec ./run.sh
