#!/usr/bin/env bash
# Quant-Trader 远程一键部署（Ubuntu / Debian）
#
# 在新服务器上执行：
#   curl -fsSL https://raw.githubusercontent.com/chinyau1/quant-Trader/main/deploy/full-deploy.sh | sudo bash
#
# 带模型 Key（sudo 默认丢环境变量，用 env 传入）：
#   curl -fsSL https://raw.githubusercontent.com/chinyau1/quant-Trader/main/deploy/full-deploy.sh \
#     | sudo env DEEPSEEK_API_KEY='sk-xxx' bash
#
# 可选环境变量：
#   QT_PROJECT_DIR     部署目录（默认 /opt/quant-trader）
#   QT_REPO_URL        Git 仓库（默认 chinyau1 fork）
#   QT_REF             分支或 tag（默认 main）
#   QT_DOCKER_MIRROR   Docker Hub 加速（默认 DaoCloud）
#   QT_SKIP_BOOTSTRAP  true=跳过免费行情初始化
#   QT_SKIP_BUILD      true=不重建镜像（已有镜像时）
#   QT_FORCE           true=覆盖部署目录未提交改动
#   QT_OPEN_DSH_LAN    true=把 dsh-proxy 绑到局域网 IP（默认只走 8093）
#   QUANTMIND_ROOT     已有 QuantMind 仓库路径（自动探测 /opt/quantmind 与 zbox 路径）
#   DEEPSEEK_API_KEY / OPENAI_API_KEY / GLM_API_KEY / JINA_API_KEY / API_TOKEN
#   TDX_BRIDGE_URL / TDX_BRIDGE_TOKEN
#
# 参数（curl 管道需用 bash -s）：
#   curl -fsSL ... | sudo bash -s -- --ref main --force

set -euo pipefail

PROJECT_DIR="${QT_PROJECT_DIR:-/opt/quant-trader}"
REPO_URL="${QT_REPO_URL:-https://github.com/chinyau1/quant-Trader.git}"
REF="${QT_REF:-main}"
DOCKER_MIRROR="${QT_DOCKER_MIRROR:-https://docker.m.daocloud.io}"
SKIP_BOOTSTRAP="${QT_SKIP_BOOTSTRAP:-false}"
SKIP_BUILD="${QT_SKIP_BUILD:-false}"
FORCE="${QT_FORCE:-false}"
OPEN_DSH_LAN="${QT_OPEN_DSH_LAN:-false}"

log() { printf '[quant-trader] %s\n' "$*"; }
die() { log "错误: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: sudo bash deploy/full-deploy.sh [选项]

  --ref <branch|tag>  部署代码版本（默认 main）
  --force             覆盖部署目录中未提交的代码改动，不删除 data/logs
  --skip-bootstrap    跳过免费行情初始化
  --skip-build        跳过镜像重建
  -h, --help          显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ref) REF="${2:-}"; shift 2 ;;
        --force) FORCE=true; shift ;;
        --skip-bootstrap) SKIP_BOOTSTRAP=true; shift ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
done

require_root() { [[ ${EUID} -eq 0 ]] || die '请使用 sudo 执行（curl ... | sudo bash）'; }

require_linux() {
    [[ "$(uname -s)" == Linux ]] || die '仅支持 Linux（Ubuntu / Debian）'
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}" in
            ubuntu|debian) ;;
            *) log "警告: 未验证的发行版 ${ID:-unknown}，按 Debian 系继续" ;;
        esac
    fi
}

detect_lan_ip() {
    local ip=""
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
    [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    printf '%s' "${ip:-127.0.0.1}"
}

detect_quantmind_root() {
    if [[ -n "${QUANTMIND_ROOT:-}" ]]; then
        printf '%s' "$QUANTMIND_ROOT"
        return
    fi
    local candidate
    for candidate in \
        /opt/quantmind \
        /home/zbox/projects/quantmind \
        /home/zbox/quantmind; do
        if [[ -d "$candidate" ]]; then
            printf '%s' "$candidate"
            return
        fi
    done
    printf '%s' /opt/quantmind
}

configure_docker_mirror() {
    [[ -n "$DOCKER_MIRROR" ]] || return 0
    log "配置 Docker 镜像加速: $DOCKER_MIRROR"
    DOCKER_MIRROR="$DOCKER_MIRROR" python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path("/etc/docker/daemon.json")
try:
    config = json.loads(path.read_text()) if path.exists() else {}
except json.JSONDecodeError as exc:
    raise SystemExit(f"Docker 配置文件格式错误: {exc}")

mirror = os.environ["DOCKER_MIRROR"]
mirrors = [mirror] + [item for item in config.get("registry-mirrors", []) if item != mirror]
config["registry-mirrors"] = mirrors
path.parent.mkdir(parents=True, exist_ok=True)
temporary = path.with_suffix(".json.quant-trader-tmp")
temporary.write_text(json.dumps(config, indent=2) + "\n")
temporary.replace(path)
PY
}

install_runtime() {
    log '1/6 安装系统依赖、Docker 与 Compose'
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ca-certificates curl git python3 openssl iproute2 docker.io
    if ! docker compose version >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin 2>/dev/null \
            || DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2
    fi
    configure_docker_mirror
    systemctl enable docker
    systemctl restart docker
    command -v docker >/dev/null || die 'Docker 安装失败'
    [[ -x /usr/bin/docker ]] || die '未找到 /usr/bin/docker（dsh 需要挂载该二进制）'
    docker compose version >/dev/null || die 'Docker Compose 不可用'
}

warn_ports() {
    local port
    for port in 8091 8092 8093 8887 3081 8100 8200 8300; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            log "警告: 端口 ${port} 已被占用，compose 启动可能失败"
        fi
    done
}

sync_code() {
    log "2/6 同步代码: $REF  ← $REPO_URL"
    git config --global --add safe.directory "$PROJECT_DIR" 2>/dev/null || true
    mkdir -p "$(dirname "$PROJECT_DIR")"

    if [[ -e "$PROJECT_DIR" && ! -d "$PROJECT_DIR/.git" ]]; then
        if [[ -n "$(ls -A "$PROJECT_DIR" 2>/dev/null)" ]]; then
            die "部署目录已存在且不是 Git 仓库（非空）: $PROJECT_DIR"
        fi
        rmdir "$PROJECT_DIR" 2>/dev/null || true
    fi

    if [[ ! -d "$PROJECT_DIR/.git" ]]; then
        if git clone --depth 1 --branch "$REF" "$REPO_URL" "$PROJECT_DIR"; then
            return
        fi
        log "带分支 clone 失败，改为默认分支再 checkout $REF"
        git clone --depth 1 "$REPO_URL" "$PROJECT_DIR" \
            || die "git clone 失败（国内访问 GitHub 可设 QT_REPO_URL 为镜像地址）"
        git -C "$PROJECT_DIR" fetch origin "$REF" 2>/dev/null || true
        git -C "$PROJECT_DIR" checkout "$REF" 2>/dev/null \
            || log "警告: 无法 checkout $REF，使用仓库默认分支"
        return
    fi

    if ! git -C "$PROJECT_DIR" diff --quiet \
        || ! git -C "$PROJECT_DIR" diff --cached --quiet; then
        [[ "$FORCE" == true ]] || die '检测到未提交代码改动；确认覆盖请加 --force 或 QT_FORCE=true'
        git -C "$PROJECT_DIR" reset --hard HEAD
        git -C "$PROJECT_DIR" clean -fd -e data -e logs -e .env -e .service.env \
            -e dsh/root-dsh -e config/tdx_bridge.json -e config/broker_market.json
    fi
    git -C "$PROJECT_DIR" fetch origin "$REF" \
        || die "git fetch 失败: $REPO_URL"
    git -C "$PROJECT_DIR" checkout -B "$REF" "origin/$REF" 2>/dev/null \
        || git -C "$PROJECT_DIR" checkout --detach "origin/$REF" 2>/dev/null \
        || git -C "$PROJECT_DIR" checkout --detach "$REF" \
        || die "无法切换到 $REF"
}

upsert_env() {
    local file="$1" key="$2" value="$3" empty_only="${4:-false}"
    local escaped
    escaped="$(printf '%s' "$value" | sed 's/[&|]/\\&/g')"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        local current
        current="$(sed -n "s/^${key}=//p" "$file" | head -1 | tr -d '"')"
        if [[ "$empty_only" == true && -n "$current" ]]; then
            return
        fi
        sed -i "s|^${key}=.*|${key}=${escaped}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

ensure_env() {
    log '3/6 生成运行配置'
    local env_file="$PROJECT_DIR/.env"
    local example="$PROJECT_DIR/.env.example"
    umask 077
    if [[ ! -f "$env_file" ]]; then
        [[ -f "$example" ]] || die "仓库缺少 .env.example"
        cp "$example" "$env_file"
        log "已从 .env.example 创建 $env_file"
    else
        log "复用已有 $env_file（不覆盖已填密钥）"
    fi

    local lan_ip qm_root
    lan_ip="$(detect_lan_ip)"
    qm_root="$(detect_quantmind_root)"
    mkdir -p \
        "$qm_root/data/quantdb" \
        "$qm_root/data/quantus" \
        "$qm_root/data/quanthk" \
        "$qm_root/data/quantfutures" \
        "$PROJECT_DIR/data" \
        "$PROJECT_DIR/logs" \
        "$PROJECT_DIR/dsh/root-dsh"

    upsert_env "$env_file" QUANTMIND_ROOT "$qm_root" true
    upsert_env "$env_file" QUANTMIND_DATA_DIR "$qm_root/data" true
    upsert_env "$env_file" QUANTMIND_QUANTDB_DIR "$qm_root/data/quantdb" true
    upsert_env "$env_file" QUANTMIND_QUANTUS_DIR "$qm_root/data/quantus" true
    upsert_env "$env_file" QUANTMIND_QUANTHK_DIR "$qm_root/data/quanthk" true
    upsert_env "$env_file" QUANTMIND_QUANTFUTURES_DIR "$qm_root/data/quantfutures" true
    upsert_env "$env_file" DSH_HOST "$lan_ip" true
    upsert_env "$env_file" DSH_UPSTREAM "http://host.docker.internal:3081" true
    if [[ "$OPEN_DSH_LAN" == true ]]; then
        upsert_env "$env_file" DSH_BIND_IP "$lan_ip" false
    else
        upsert_env "$env_file" DSH_BIND_IP "172.17.0.1" true
    fi

    local token
    token="$(sed -n 's/^API_TOKEN=//p' "$env_file" | head -1 | tr -d '"')"
    if [[ -z "$token" ]]; then
        token="$(openssl rand -hex 24)"
        upsert_env "$env_file" API_TOKEN "$token" false
        log "已生成 API_TOKEN（公网建议保留）"
    fi

    local key
    for key in \
        DEEPSEEK_API_KEY OPENAI_API_KEY OPENAI_API_BASE \
        GLM_API_KEY GLM_API_BASE JINA_API_KEY \
        TDX_BRIDGE_URL TDX_BRIDGE_TOKEN \
        THS_FUYAO_KEY QM_API_BASE; do
        if [[ -n "${!key:-}" ]]; then
            upsert_env "$env_file" "$key" "${!key}" false
        fi
    done

    if ! grep -Eq '^(DEEPSEEK_API_KEY|OPENAI_API_KEY|GLM_API_KEY)="?[^"]+' "$env_file"; then
        log "警告: 未检测到模型 API Key。模拟盘 agent 无法调用 LLM。"
        log "      重跑时传入: sudo env DEEPSEEK_API_KEY='sk-xxx' bash deploy/full-deploy.sh"
    fi
}

verify_repo_files() {
    local f
    for f in docker-compose.yml .env.example Dockerfile arena/Dockerfile \
             docker/entrypoint.sh configs/default_config.json \
             config/backend.yaml scripts/bootstrap_data.py; do
        [[ -f "$PROJECT_DIR/$f" ]] || die "仓库文件缺失: $f（clone 不完整）"
    done
}

start_services() {
    log '4/6 构建并启动常驻服务'
    cd "$PROJECT_DIR"
    warn_ports
    if [[ "$SKIP_BUILD" == true ]]; then
        docker compose up -d --remove-orphans
    else
        docker compose up -d --build --remove-orphans
    fi
}

bootstrap_data() {
    log '5/6 初始化免费行情（约 3–6 分钟）'
    cd "$PROJECT_DIR"
    if [[ "$SKIP_BOOTSTRAP" == true ]]; then
        log "已跳过行情初始化"
        return
    fi
    if [[ -s data/A_stock/merged.jsonl ]]; then
        log "检测到已有 A 股数据，跳过 bootstrap（覆盖请删 data/A_stock/merged.jsonl 后重跑）"
        return
    fi
    docker compose run --rm api python3 scripts/bootstrap_data.py \
        || log "警告: 行情初始化未完全成功（常见于 Yahoo 美股被墙）。A 股/港股可能仍可用，可稍后重跑该命令。"
}

health_check() {
    log '6/6 探活前端与 API'
    cd "$PROJECT_DIR"
    local attempt code
    for attempt in $(seq 1 36); do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:8092/ || echo 000)"
        if [[ "$code" == 200 ]]; then
            docker compose ps --format 'table {{.Name}}\t{{.Status}}'
            return
        fi
        sleep 5
    done
    docker compose ps --format 'table {{.Name}}\t{{.Status}}' || true
    docker compose logs --tail 40 ui-arena api || true
    die '8092 未在约 3 分钟内返回 200。请查看: docker compose logs ui-arena'
}

show_completion() {
    local lan_ip
    lan_ip="$(detect_lan_ip)"
    echo ""
    echo "========================================================================="
    echo " Quant-Trader 部署完成"
    echo " -------------------------------------------------------------------------"
    echo " 目录          : $PROJECT_DIR"
    echo " Arena 竞技场  : http://${lan_ip}:8092"
    echo " 交易智能体    : http://${lan_ip}:8093   （默认 admin / admin123，登录后请改）"
    echo " API           : http://${lan_ip}:8091"
    echo " -------------------------------------------------------------------------"
    echo " 下一步："
    echo "  1. 编辑 $PROJECT_DIR/.env 填入 DEEPSEEK_API_KEY / OPENAI_API_KEY（至少一个）"
    echo "     然后: cd $PROJECT_DIR && docker compose up -d"
    echo "  2. 可选冒烟（A股模拟盘跑 1 天）："
    echo "     docker compose --profile agents run --rm -e INIT_DATE=2026-08-28 -e END_DATE=2026-08-28 agent-cn"
    echo "  3. A股实盘：Windows 通达信桥就绪后填 TDX_BRIDGE_URL / TDX_BRIDGE_TOKEN"
    echo "  4. 更新代码: curl -fsSL .../deploy/full-deploy.sh | sudo bash"
    echo "========================================================================="
    echo ""
}

main() {
    require_root
    require_linux
    echo "========================================================================="
    echo " Quant-Trader 一键部署"
    echo " -------------------------------------------------------------------------"
    echo " 仓库: $REPO_URL"
    echo " 版本: $REF"
    echo " 目录: $PROJECT_DIR"
    echo " 预计: 装 Docker 2–5 分钟 + 首次构建镜像 5–15 分钟 + 行情 3–6 分钟"
    echo "========================================================================="
    install_runtime
    sync_code
    verify_repo_files
    ensure_env
    start_services
    bootstrap_data
    health_check
    show_completion
}

main "$@"
