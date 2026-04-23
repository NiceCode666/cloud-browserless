#!/usr/bin/env bash
# =============================================================================
# cloud-browser 一键部署脚本
#
# 用法:
#   ./deploy.sh <user@host>                               # 默认端口 3000 + 9222
#   ./deploy.sh <user@host> --dir /opt/my-dir
#   ./deploy.sh <user@host> --web-port 3000 --cdp-port 9222
#   ./deploy.sh <user@host> --rotate                      # 重新生成密码和 token
#
# 前置要求 (远端):
#   - Docker + docker compose 已安装
#   - SSH 免密登录
#   - 防火墙放开 web-port 和 cdp-port
#
# 行为:
#   - 首次部署: 生成随机密码 + token + 自签证书 (SAN 含服务器地址)
#   - 重复部署: 默认复用已有 .env 凭据 (加 --rotate 才轮换)
#   - 幂等: 可反复跑
# =============================================================================

set -euo pipefail

# ------------------------------------------------------------------
# 参数解析
# ------------------------------------------------------------------
TARGET=""
REMOTE_DIR="/opt/cloud-browser"
WEB_PORT="3000"
CDP_PORT="9222"
ROTATE=0

usage() {
  grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)       usage ;;
    --dir)           REMOTE_DIR="$2"; shift 2 ;;
    --web-port)      WEB_PORT="$2";   shift 2 ;;
    --cdp-port)      CDP_PORT="$2";   shift 2 ;;
    --rotate)        ROTATE=1;        shift ;;
    -*)              echo "未知参数: $1" >&2; usage ;;
    *)               if [[ -z "$TARGET" ]]; then TARGET="$1"; else echo "多余参数: $1" >&2; usage; fi; shift ;;
  esac
done

[[ -z "$TARGET" ]] && { echo "缺少 <user@host>" >&2; usage; }

# ------------------------------------------------------------------
# 本地前置
# ------------------------------------------------------------------
cd "$(dirname "$0")"

for f in docker-compose.yml \
         chromium/wrapped-chromium \
         chromium/autostart \
         chromium/autostart_wayland \
         gateway/nginx.conf; do
  [[ -f "$f" ]] || { echo "❌ 缺少文件: $f (请在项目根目录运行)" >&2; exit 1; }
done

SSH_HOST="${TARGET##*@}"

cat <<EOF
===============================================
  目标: $TARGET
  目录: $REMOTE_DIR
  Web UI  -> https://$SSH_HOST:$WEB_PORT/
  CDP     -> http://$SSH_HOST:$CDP_PORT/<TOKEN>
  凭据轮换: $([[ $ROTATE -eq 1 ]] && echo "是 (重置密码+token)" || echo "否 (沿用现有)")
===============================================
EOF

# ------------------------------------------------------------------
# 1. 远端环境检查
# ------------------------------------------------------------------
echo "[1/5] 检查远端 Docker 环境 ..."
ssh -o ConnectTimeout=10 "$TARGET" '
  set -e
  command -v docker >/dev/null             || { echo "❌ 远端无 docker"        >&2; exit 2; }
  docker compose version >/dev/null 2>&1   || { echo "❌ 远端 docker compose 不可用" >&2; exit 2; }
  docker info >/dev/null 2>&1              || { echo "❌ 远端 docker daemon 不通"     >&2; exit 2; }
  command -v openssl >/dev/null            || { echo "❌ 远端无 openssl"       >&2; exit 2; }
'

# ------------------------------------------------------------------
# 2. 同步文件
# ------------------------------------------------------------------
echo "[2/5] 同步项目文件到 $TARGET:$REMOTE_DIR ..."
ssh "$TARGET" "mkdir -p '$REMOTE_DIR'"
rsync -az \
  --exclude='chromium-config/' \
  --exclude='gateway/certs/' \
  --exclude='.env' \
  --exclude='.git/' \
  --exclude='.claude/' \
  --exclude='deploy.sh' \
  --exclude='.DS_Store' \
  docker-compose.yml chromium gateway \
  "$TARGET:$REMOTE_DIR/"

# ------------------------------------------------------------------
# 3. 远端初始化: 凭据、证书、token 注入、Plan A 预置
# ------------------------------------------------------------------
echo "[3/5] 远端初始化凭据 / 证书 / 配置 ..."
ssh "$TARGET" "\
  REMOTE_DIR='$REMOTE_DIR' \
  SSH_HOST='$SSH_HOST' \
  WEB_PORT='$WEB_PORT' \
  CDP_PORT='$CDP_PORT' \
  ROTATE='$ROTATE' \
  bash -s" <<'REMOTE_EOF'
set -euo pipefail
cd "$REMOTE_DIR"

# ---- 3.1 .env: 首次生成 / --rotate 重生成 / 否则保留 ----
if [[ ! -f .env || "$ROTATE" == "1" ]]; then
  NEW_PW=$(openssl rand -base64 18 | tr -d '+/=' | cut -c1-20)
  NEW_TOKEN=$(openssl rand -hex 24)
  cat > .env <<EOF
WEB_USER=admin
WEB_PASSWORD=$NEW_PW
CDP_TOKEN=$NEW_TOKEN
WEB_PORT=$WEB_PORT
CDP_PORT=$CDP_PORT
EOF
  chmod 600 .env
  echo "  ↳ 已写入新 .env (密码和 token 已重置)"
else
  # 已有 .env：保证端口是最新传进来的，其它保留
  grep -q '^WEB_PORT='  .env && sed -i.bak -E "s|^WEB_PORT=.*|WEB_PORT=$WEB_PORT|"  .env || echo "WEB_PORT=$WEB_PORT" >> .env
  grep -q '^CDP_PORT='  .env && sed -i.bak -E "s|^CDP_PORT=.*|CDP_PORT=$CDP_PORT|"  .env || echo "CDP_PORT=$CDP_PORT" >> .env
  rm -f .env.bak
  echo "  ↳ 沿用已有 .env 凭据（仅更新端口）"
fi

CDP_TOKEN=$(grep '^CDP_TOKEN=' .env | cut -d= -f2)

# ---- 3.2 把 nginx.conf 里的占位 token 换成当前 token (幂等) ----
#   匹配任意长度 >=40 的十六进制串，全文替换成当前 token
perl -i -pe 's|\b[0-9a-f]{40,}\b|'"$CDP_TOKEN"'|g' gateway/nginx.conf
TOK_COUNT=$(grep -c "$CDP_TOKEN" gateway/nginx.conf)
echo "  ↳ nginx.conf 内 token 出现 $TOK_COUNT 次 (应 >= 2)"

# ---- 3.3 自签证书 (Web UI 用)，SAN 含 localhost + 127.0.0.1 + 服务器地址 ----
mkdir -p gateway/certs
if [[ ! -f gateway/certs/cert.pem || "$ROTATE" == "1" ]]; then
  SAN="DNS:localhost,IP:127.0.0.1"
  if [[ -n "$SSH_HOST" && "$SSH_HOST" != "localhost" ]]; then
    if [[ "$SSH_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      SAN="$SAN,IP:$SSH_HOST"
    else
      SAN="$SAN,DNS:$SSH_HOST"
    fi
  fi
  # 附上探测到的本机主 IP（云机常见）
  PRIMARY_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  if [[ -n "$PRIMARY_IP" && "$PRIMARY_IP" != "$SSH_HOST" ]]; then
    SAN="$SAN,IP:$PRIMARY_IP"
  fi
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout gateway/certs/key.pem -out gateway/certs/cert.pem \
    -subj "/CN=cloud-chromium" \
    -addext "subjectAltName=$SAN" 2>/dev/null
  chmod 600 gateway/certs/key.pem
  echo "  ↳ 已生成自签证书 (SAN: $SAN)"
else
  echo "  ↳ 保留现有证书"
fi

# ---- 3.4 预置 Plan A 的 labwc autostart (必须在首次启动前) ----
mkdir -p chromium-config/.config/labwc
cat > chromium-config/.config/labwc/autostart <<'A'
#!/bin/bash
# Plan A: 开机不自动启动任何 App
exit 0
A
chmod +x chromium-config/.config/labwc/autostart
chown -R 1000:1000 chromium-config 2>/dev/null || true
echo "  ↳ 已预置 Plan A autostart"
REMOTE_EOF

# ------------------------------------------------------------------
# 4. 启动 + 兜底: gateway 共享 netns 要 force-recreate
# ------------------------------------------------------------------
echo "[4/5] 启动 docker compose ..."
ssh "$TARGET" "cd '$REMOTE_DIR' && docker compose up -d --remove-orphans"

echo "  ↳ 等 chromium 就绪 ..."
ssh "$TARGET" "cd '$REMOTE_DIR' && for i in \$(seq 1 30); do
  docker compose ps chromium --format '{{.Status}}' 2>/dev/null | grep -q '^Up' && exit 0
  sleep 2
done; echo 'chromium 未就绪'; exit 1"

echo "  ↳ 强制重建 gateway (共享 netns 需要) ..."
ssh "$TARGET" "cd '$REMOTE_DIR' && docker compose up -d --force-recreate cdp-gateway"
sleep 3

# ------------------------------------------------------------------
# 5. 验证
# ------------------------------------------------------------------
echo "[5/5] 端到端验证 ..."
CDP_TOKEN_VAL=$(ssh "$TARGET" "grep '^CDP_TOKEN=' '$REMOTE_DIR/.env' | cut -d= -f2")
WEB_PW=$(ssh "$TARGET" "grep '^WEB_PASSWORD=' '$REMOTE_DIR/.env' | cut -d= -f2")

probe() { curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "$@" 2>/dev/null || echo 000; }

UI_401=$(probe "https://$SSH_HOST:$WEB_PORT/")
UI_200=$(probe -u "admin:$WEB_PW" "https://$SSH_HOST:$WEB_PORT/")
CDP_404=$(probe "http://$SSH_HOST:$CDP_PORT/")
CDP_BAD=$(probe "http://$SSH_HOST:$CDP_PORT/wrong/json/version")
CDP_OK=$(probe "http://$SSH_HOST:$CDP_PORT/$CDP_TOKEN_VAL/json/version")

printf "  Web UI 无密码 : HTTP %-3s  (期望 401)\n" "$UI_401"
printf "  Web UI 带密码 : HTTP %-3s  (期望 200)\n" "$UI_200"
printf "  CDP 无 token  : HTTP %-3s  (期望 404)\n" "$CDP_404"
printf "  CDP 错 token  : HTTP %-3s  (期望 404)\n" "$CDP_BAD"
printf "  CDP 正确 token: HTTP %-3s  (期望 502 — 表示 Chromium 还没在桌面里打开；打开后 200)\n" "$CDP_OK"

# ------------------------------------------------------------------
# 输出最终信息
# ------------------------------------------------------------------
cat <<OUT

===============================================================
✅ 部署完成  ($TARGET)
===============================================================

◆ Web 云桌面
    URL :   https://$SSH_HOST:$WEB_PORT/
    用户:   admin
    密码:   $WEB_PW

◆ CDP (Chrome DevTools Protocol, 明文 + token)
    Token:  $CDP_TOKEN_VAL
    发现:   http://$SSH_HOST:$CDP_PORT/$CDP_TOKEN_VAL/json/version

    实时获取可用的 WS URL (alias 友好):
      curl -s "http://$SSH_HOST:$CDP_PORT/$CDP_TOKEN_VAL/json/version" \\
        | python3 -c "import sys,json;print(json.load(sys.stdin)['webSocketDebuggerUrl'])"

◆ 使用流程
    1. 浏览器开 Web UI，用户 admin + 上面密码登录
       (自签证书 → "继续访问" 即可)
    2. 进去是干净桌面 (Plan A)，右键打开 Chromium, 即带 CDP
       右键开 Terminal 后 \`proot-apps install firefox/vscode/...\` 装别的软件
    3. Chromium 必须先在桌面里开一次，CDP 9222 才会监听

◆ 维护
    ssh $TARGET "cd $REMOTE_DIR && docker compose ps"
    ssh $TARGET "cd $REMOTE_DIR && docker compose logs -f"
    ssh $TARGET "cd $REMOTE_DIR && docker compose down"

◆ 凭据文件:   $REMOTE_DIR/.env   (已 chmod 600)
◆ 数据目录:   $REMOTE_DIR/chromium-config/  (浏览器 profile + proot 装的 app)
===============================================================
OUT
