#!/usr/bin/env bash
# =============================================================================
# cloud-browser 本地运行脚本 (Mac / Linux 都可以)
#
# 用法:
#   ./run-local.sh                       # 启动/更新
#   ./run-local.sh --rotate              # 重置密码 + token
#   ./run-local.sh down                  # 停掉本地实例 (保留数据)
#   ./run-local.sh nuke                  # 停掉并删除所有数据 (chromium-config 保留, 删 .env.local 和 certs)
#
# 与 deploy.sh 的区别:
#   - 不用 SSH, 全部在本机 Docker 里跑
#   - 所有端口绑 127.0.0.1 (只有你自己能访问)
#   - 默认用中配预设 (1080p60, 4 核 6GB), 适合 M 系列 Mac / Ryzen 8C/16G 机器
#   - 配置文件: .env.local (不是 .env, 避免跟 deploy.sh 生成的远程配置冲突)
# =============================================================================

set -euo pipefail
cd "$(dirname "$0")"

# ------------------------------------------------------------------
# 参数
# ------------------------------------------------------------------
ACTION="up"
ROTATE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)  grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --rotate)   ROTATE=1; shift ;;
    down|nuke|up|restart|logs|ps|open)  ACTION="$1"; shift ;;
    *)          echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

COMPOSE=(docker compose
  --env-file .env.local
  -f docker-compose.yml
  -f docker-compose.local.yml
)

# ------------------------------------------------------------------
# 操作分发
# ------------------------------------------------------------------
case "$ACTION" in
  down)
    echo "🛑 停止本地实例..."
    "${COMPOSE[@]}" down --remove-orphans
    exit 0
    ;;
  nuke)
    echo "💣 删除本地实例和配置 (chromium-config 保留)..."
    "${COMPOSE[@]}" down --remove-orphans --volumes 2>/dev/null || true
    rm -f .env.local
    rm -rf gateway/certs
    echo "已删除 .env.local 和 gateway/certs/, chromium-config/ 保留"
    exit 0
    ;;
  logs)
    exec "${COMPOSE[@]}" logs -f
    ;;
  ps)
    exec "${COMPOSE[@]}" ps
    ;;
  restart)
    exec "${COMPOSE[@]}" restart
    ;;
  open)
    # 读取 .env.local 的密码并打开浏览器
    [[ ! -f .env.local ]] && { echo "未部署, 先跑 ./run-local.sh"; exit 1; }
    WEB_PORT=$(grep '^WEB_PORT=' .env.local | cut -d= -f2)
    echo "打开 https://localhost:${WEB_PORT:-3000}/"
    open "https://localhost:${WEB_PORT:-3000}/"
    exit 0
    ;;
esac

# ------------------------------------------------------------------
# up / 默认动作
# ------------------------------------------------------------------

# ---- 0. 前置检查 ----
command -v docker >/dev/null || { echo "❌ 没装 docker" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "❌ Docker Desktop 未启动" >&2; exit 2; }
command -v openssl >/dev/null || { echo "❌ 没装 openssl" >&2; exit 2; }

# ---- 1. 首次生成 / --rotate 重生成 .env.local ----
if [[ ! -f .env.local || "$ROTATE" == "1" ]]; then
  NEW_PW=$(openssl rand -base64 18 | tr -d '+/=' | cut -c1-20)
  NEW_TOKEN=$(openssl rand -hex 24)

  # 从 .env.example 扒配置结构, 替换凭据 + 用中配预设
  #  - 密码/token 换成新的
  #  - 启用中配预设的资源上限
  #  - 取消低内存模式 (本地资源够)
  cp .env.example .env.local
  perl -i -pe '
    # 凭据
    s|^WEB_PASSWORD=.*|WEB_PASSWORD='"$NEW_PW"'|;
    s|^CDP_TOKEN=.*|CDP_TOKEN='"$NEW_TOKEN"'|;
    # 端口 (本地用 13000/19222 避开常见冲突: 3000=dev server, 9222=本机 Chrome 自带)
    s|^WEB_PORT=.*|WEB_PORT=13000|;
    s|^CDP_PORT=.*|CDP_PORT=19222|;
    # 中配画质 (1080p60)
    s|^DISPLAY_WIDTH=.*|DISPLAY_WIDTH=1920|;
    s|^DISPLAY_HEIGHT=.*|DISPLAY_HEIGHT=1080|;
    s|^SELKIES_FRAMERATE=.*|SELKIES_FRAMERATE=60|;
    s|^SELKIES_VIDEO_BITRATE=.*|SELKIES_VIDEO_BITRATE=8000|;
    s|^SELKIES_AUDIO_BITRATE=.*|SELKIES_AUDIO_BITRATE=128000|;
    # 中配资源
    s|^CHROMIUM_MEM_LIMIT=.*|CHROMIUM_MEM_LIMIT=4g|;
    s|^CHROMIUM_CPUS=.*|CHROMIUM_CPUS=4|;
    s|^CHROMIUM_SHM_SIZE=.*|CHROMIUM_SHM_SIZE=2g|;
    # 关掉低内存模式 (本地资源不紧张)
    s|^CHROMIUM_LOW_MEMORY_MODE=.*|CHROMIUM_LOW_MEMORY_MODE=0|;
    s|^CHROMIUM_JS_HEAP_MB=.*|CHROMIUM_JS_HEAP_MB=2048|;
  ' .env.local
  chmod 600 .env.local

  if [[ "$ROTATE" == "1" ]]; then
    echo "🔁 已重置本地密码 + token"
  else
    echo "🆕 已生成 .env.local (中配预设)"
  fi
fi

# ---- 2. 证书 (SAN: localhost, 127.0.0.1) ----
mkdir -p gateway/certs
if [[ ! -f gateway/certs/cert.pem || "$ROTATE" == "1" ]]; then
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout gateway/certs/key.pem -out gateway/certs/cert.pem \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1" 2>/dev/null
  chmod 600 gateway/certs/key.pem
  echo "🔐 生成自签证书 (localhost)"
fi

# ---- 3. 注入当前 token 到 nginx.conf ----
CDP_TOKEN=$(grep '^CDP_TOKEN=' .env.local | cut -d= -f2)
perl -i -pe 's|\b[0-9a-f]{40,}\b|'"$CDP_TOKEN"'|g' gateway/nginx.conf
echo "🔑 token 注入 nginx.conf ($(grep -c "$CDP_TOKEN" gateway/nginx.conf) 处)"

# ---- 4. 预置 Plan A autostart ----
mkdir -p chromium-config/.config/labwc
if [[ ! -f chromium-config/.config/labwc/autostart ]] || \
   ! grep -q 'Plan A' chromium-config/.config/labwc/autostart 2>/dev/null; then
  cat > chromium-config/.config/labwc/autostart <<'A'
#!/bin/bash
# Plan A: 开机不自动启动任何 App
exit 0
A
  chmod +x chromium-config/.config/labwc/autostart
  echo "🖥️  Plan A autostart 已就位"
fi

# ---- 5. 启动 ----
echo ""
echo "🚀 启动 docker compose..."
"${COMPOSE[@]}" up -d --remove-orphans

echo "  ↳ 等 chromium 就绪..."
for i in $(seq 1 30); do
  "${COMPOSE[@]}" ps chromium --format '{{.Status}}' 2>/dev/null | grep -q '^Up' && break
  sleep 2
done

echo "  ↳ 重建 gateway (共享 netns)..."
"${COMPOSE[@]}" up -d --force-recreate cdp-gateway
sleep 2

# ---- 6. 验证 ----
echo ""
echo "📊 验证..."
WEB_PORT=$(grep '^WEB_PORT=' .env.local | cut -d= -f2)
CDP_PORT=$(grep '^CDP_PORT=' .env.local | cut -d= -f2)
WEB_PW=$(grep '^WEB_PASSWORD=' .env.local | cut -d= -f2)

probe() { curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null || echo 000; }

UI_401=$(probe "https://localhost:$WEB_PORT/")
UI_200=$(probe -u "admin:$WEB_PW" "https://localhost:$WEB_PORT/")
CDP_404=$(probe "http://localhost:$CDP_PORT/")
CDP_OK=$(probe "http://localhost:$CDP_PORT/$CDP_TOKEN/json/version")

printf "  Web UI 无密码 : HTTP %-3s  (应 401)\n" "$UI_401"
printf "  Web UI 带密码 : HTTP %-3s  (应 200)\n" "$UI_200"
printf "  CDP 无 token  : HTTP %-3s  (应 404)\n" "$CDP_404"
printf "  CDP 带 token  : HTTP %-3s  (应 502 — 还没开 Chromium; 打开后 200)\n" "$CDP_OK"

# ---- 7. 输出 ----
cat <<OUT

===============================================================
✅ 本地实例就绪
===============================================================

◆ Web 云桌面
    URL :   https://localhost:$WEB_PORT/
    用户:   admin
    密码:   $WEB_PW

    自签证书, Chrome 会提示不安全 -> 高级 -> 继续访问.
    ./run-local.sh open   # 快捷打开

◆ CDP (Chrome DevTools Protocol)
    Token:  $CDP_TOKEN
    发现:   http://localhost:$CDP_PORT/$CDP_TOKEN/json/version

    实时拿 WS URL:
      curl -s "http://localhost:$CDP_PORT/$CDP_TOKEN/json/version" \\
        | python3 -c "import sys,json;print(json.load(sys.stdin)['webSocketDebuggerUrl'])"

◆ 常用命令
    ./run-local.sh           启动/更新
    ./run-local.sh ps        看容器状态
    ./run-local.sh logs      跟日志
    ./run-local.sh restart   重启
    ./run-local.sh down      停掉 (保留数据)
    ./run-local.sh nuke      彻底删除 (只保留 chromium-config)
    ./run-local.sh --rotate  重置密码+token
    ./run-local.sh open      浏览器打开 Web UI

◆ 配置文件
    .env.local                    # 凭据 + 画质 + 资源限制 (chmod 600)
    docker-compose.local.yml      # 本地覆盖 (绑 127.0.0.1)
    chromium-config/              # 浏览器持久数据 (登录态/扩展/下载)
    gateway/certs/                # 自签证书

◆ 调优:
    直接改 .env.local 再 ./run-local.sh restart 或 ./run-local.sh
    参数说明看 .env.example 或 README.md "性能调优" 章节
===============================================================
OUT
