#!/usr/bin/env bash
# Quant-Trader 一键更新（已部署服务器）
# 拉代码 → 按需重建镜像 → 重启常驻容器。不删除 data/logs/.env/会话。
#
# 用法：
#   cd /opt/quant-trader
#   sudo bash deploy/update.sh
#   sudo bash deploy/update.sh --ref main --force
#   sudo bash deploy/update.sh --no-build
#
# 可选环境变量：
#   QT_PROJECT_DIR  部署目录（默认本脚本所在仓库根）
#   QT_REPO_URL     覆盖 origin 地址
#   QT_REF          分支或 tag（默认 main）
#   QT_REMOTE       远端名（默认 origin）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${QT_PROJECT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
REF="${QT_REF:-main}"
REMOTE="${QT_REMOTE:-origin}"
REPO_URL="${QT_REPO_URL:-https://github.com/chinyau1/quant-Trader.git}"
FORCE=false
BUILD=true

log() { printf '[quant-trader-update] %s\n' "$*"; }
die() { log "错误: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: sudo bash deploy/update.sh [选项]

  --ref <branch|tag>  更新到指定版本（默认 main）
  --remote <name>     远端名（默认 origin）
  --force             覆盖服务器上未提交的代码改动，不删除 data/logs/.env
  --no-build          跳过镜像重建（仅 configs 等 bind-mount 变更时）
  -h, --help          显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ref) REF="${2:-}"; shift 2 ;;
        --remote) REMOTE="${2:-}"; shift 2 ;;
        --force) FORCE=true; shift ;;
        --no-build) BUILD=false; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

require_root() {
    [[ ${EUID} -eq 0 ]] && return
    if groups 2>/dev/null | grep -qw docker && [[ -w "$PROJECT_DIR" ]] && docker ps >/dev/null 2>&1; then
        log "提示: 未使用 sudo，但 docker 权限正常，继续执行"
        return
    fi
    die '请使用 sudo 执行（sudo bash deploy/update.sh）'
}

require_project() {
    [[ -d "$PROJECT_DIR/.git" ]] || die "不是 Git 部署目录: $PROJECT_DIR"
    [[ -f "$PROJECT_DIR/docker-compose.yml" ]] || die "缺少 docker-compose.yml: $PROJECT_DIR"
    command -v docker >/dev/null || die 'Docker 未安装'
    docker compose version >/dev/null || die 'Docker Compose 不可用'
}

ensure_remote() {
    local current=""
    if git -C "$PROJECT_DIR" remote get-url "$REMOTE" >/dev/null 2>&1; then
        current="$(git -C "$PROJECT_DIR" remote get-url "$REMOTE")"
        if [[ -n "${QT_REPO_URL:-}" && "$current" != "$REPO_URL" ]]; then
            log "将远端 $REMOTE 切换为 $REPO_URL"
            git -C "$PROJECT_DIR" remote set-url "$REMOTE" "$REPO_URL"
        fi
        return
    fi
    log "远端 $REMOTE 不存在，添加 $REPO_URL"
    git -C "$PROJECT_DIR" remote add "$REMOTE" "$REPO_URL"
}

sync_code() {
    log "1/3 同步代码: $REMOTE/$REF"
    git config --global --add safe.directory "$PROJECT_DIR" 2>/dev/null || true
    ensure_remote
    if ! git -C "$PROJECT_DIR" diff --quiet \
        || ! git -C "$PROJECT_DIR" diff --cached --quiet; then
        [[ "$FORCE" == true ]] || die '检测到未提交代码改动；确认覆盖请加 --force（不会删除 data/logs/.env）'
        git -C "$PROJECT_DIR" reset --hard HEAD
        git -C "$PROJECT_DIR" clean -fd \
            -e data -e logs -e .env -e .service.env \
            -e dsh/root-dsh -e config/tdx_bridge.json -e config/broker_market.json \
            -e .update
    fi
    git -C "$PROJECT_DIR" fetch "$REMOTE" "$REF" \
        || die "git fetch $REMOTE $REF 失败"
    git -C "$PROJECT_DIR" checkout -B "$REF" "$REMOTE/$REF" 2>/dev/null \
        || git -C "$PROJECT_DIR" checkout -B "$REF" FETCH_HEAD 2>/dev/null \
        || git -C "$PROJECT_DIR" checkout --detach FETCH_HEAD \
        || die "checkout $REF 失败"
    log "HEAD: $(git -C "$PROJECT_DIR" rev-parse --short HEAD)"
}

image_fingerprint() {
    local f h out=""
    for f in \
        Dockerfile Dockerfile.dsh arena/Dockerfile dsh/proxy/Dockerfile \
        requirements.lock.txt docker-compose.yml; do
        if [[ -f "$PROJECT_DIR/$f" ]]; then
            h="$(sha256sum "$PROJECT_DIR/$f" | awk '{print $1}')"
            out="${out}${f}=${h}"$'\n'
        else
            out="${out}${f}=missing"$'\n'
        fi
    done
    printf '%s' "$out"
}

restart_services() {
    cd "$PROJECT_DIR"
    mkdir -p "$PROJECT_DIR/.update"
    local marker="$PROJECT_DIR/.update/image.sha256"
    local now
    now="$(image_fingerprint)"

    if [[ "$BUILD" != true ]]; then
        log '2/4 跳过镜像重建（--no-build）；data/logs/.env 保持不动'
        docker compose up -d --remove-orphans
        return
    fi

    log '2/4 重建镜像并启动常驻服务（不 down、不删 data/logs/.env）'
    docker compose up -d --build --remove-orphans
    printf '%s' "$now" > "$marker"
}

ensure_dsh_im() {
    if [[ "${QT_SKIP_DSH_IM:-false}" == true ]]; then
        log "跳过 dsh-im（QT_SKIP_DSH_IM=true）"
        return
    fi
    log '3/4 在远程 baymax-dsh 安装/确保 dsh-im 插件'
    cd "$PROJECT_DIR"
    if ! docker ps --format '{{.Names}}' | grep -qx baymax-dsh; then
        log "baymax-dsh 未运行，跳过 dsh-im"
        return
    fi
    if docker exec baymax-dsh dsh plugin --profile web add -w @xmanrui/dsh-im; then
        docker compose restart dsh
        log "dsh-im 已安装，已重启 baymax-dsh"
    else
        log "警告: dsh-im 安装失败，可稍后执行: docker exec baymax-dsh dsh plugin --profile web add -w @xmanrui/dsh-im"
    fi
}

health_check() {
    log '4/4 探活 Arena / API'
    cd "$PROJECT_DIR"
    local attempt code
    for attempt in $(seq 1 36); do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:8092/ || echo 000)"
        if [[ "$code" == 200 ]]; then
            docker compose ps --format 'table {{.Name}}\t{{.Status}}'
            log "更新完成 ✓ HEAD=$(git -C "$PROJECT_DIR" rev-parse --short HEAD)"
            return
        fi
        sleep 5
    done
    docker compose ps --format 'table {{.Name}}\t{{.Status}}' || true
    docker compose logs --tail 40 ui-arena api || true
    die '8092 未在约 3 分钟内返回 200。请查看: docker compose logs ui-arena'
}

main() {
    require_root
    require_project
    echo "========================================================================="
    echo " Quant-Trader 一键更新（保留 data / logs / .env）"
    echo " 目录: $PROJECT_DIR"
    echo " 版本: $REMOTE/$REF"
    echo "========================================================================="
    sync_code
    restart_services
    ensure_dsh_im
    health_check
}

main "$@"
