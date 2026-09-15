#!/usr/bin/env bash
# 兼容旧入口：转发到在线部署脚本 deploy/deploy.sh
# 新用法请直接：
#   curl -fsSL https://raw.githubusercontent.com/chinyau1/quant-Trader/main/deploy/deploy.sh | sudo bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [[ -n "${HERE:-}" && -f "$HERE/deploy.sh" ]]; then
  exec bash "$HERE/deploy.sh" "$@"
fi
curl -fsSL https://raw.githubusercontent.com/chinyau1/quant-Trader/main/deploy/deploy.sh | bash -s -- "$@"
