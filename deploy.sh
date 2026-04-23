#!/usr/bin/env bash
# =============================================================================
# cloud-browser 一键部署脚本
#
# 用法:
#   ./deploy.sh <user@host>                               # 默认端口 3000 + 9222
#   ./deploy.sh <user@host> --dir /opt/my-dir
#   ./deploy.sh <user@host> --web-port 3000 --cdp-port 9222
#   ./deploy.sh <user@host> --rotate                      # 重新生成密码和 token
#   ./deploy.sh <user@host> --swap 2g                     # 在目标机创建 swap (推荐 2-4g)
#
# 前置要求 (远端):
#   - Docker + docker compose 已安装
#   - SSH 免密登录
#   - 防火墙放开 web-port 和 cdp-port
#
# 幂等行为:
#   - 首次部署: 生成随机密码 + token + 自签证书 (SAN 含服务器地址)
#   - 重复部署: 复用 .env 里现有凭据；但会把新字段合并进去（例如从 .env.example 来的新变量）
#   - --rotate: 重新生成密码+token+证书
#   - --swap:   只在目标机无 swap 或 swap 小于指定值时才创建，幂等安全
# =============================================================================

set -euo pipefail

# ------------------------------------------------------------------
# 参数解析
# ------------------------------------------------------------------
TARGET=""
REMOTE_DIR="/opt/cloud-browser"
WEB_PORT=""
CDP_PORT=""
ROTATE=0
SWAP_SIZE=""

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
    --swap)          SWAP_SIZE="$2";  shift 2 ;;
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
         .env.example \
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
  Web UI:  https://$SSH_HOST:${WEB_PORT:-(见 .env)}/
  CDP:     http://$SSH_HOST:${CDP_PORT:-(见 .env)}/<TOKEN>
  凭据轮换: $([[ $ROTATE -eq 1 ]] && echo "是 (重置密码+token)" || echo "否 (沿用现有)")
  Swap:    ${SWAP_SIZE:-不管}
===============================================
EOF

# ------------------------------------------------------------------
# 1. 远端环境检查 + 资源探测
# ------------------------------------------------------------------
echo "[1/6] 检查远端环境 ..."
read -r REMOTE_MEM_MB REMOTE_CPU REMOTE_SWAP_MB < <(ssh -o ConnectTimeout=10 "$TARGET" '
  set -e
  command -v docker >/dev/null             || { echo "❌ 远端无 docker" >&2; exit 2; }
  docker compose version >/dev/null 2>&1   || { echo "❌ 远端 docker compose 不可用" >&2; exit 2; }
  docker info >/dev/null 2>&1              || { echo "❌ 远端 docker daemon 不通" >&2; exit 2; }
  command -v openssl >/dev/null            || { echo "❌ 远端无 openssl" >&2; exit 2; }
  awk "/^MemTotal:/ {mem=\$2/1024} /^SwapTotal:/ {sw=\$2/1024} END {print int(mem), sw+0}" /proc/meminfo \
      | awk -v c=$(nproc) "{print \$1, c, int(\$2)}"
')

echo "  ↳ 目标机: ${REMOTE_CPU} CPU / ${REMOTE_MEM_MB} MB RAM / ${REMOTE_SWAP_MB} MB swap"

# ------------------------------------------------------------------
# 2. 低配告警 & 可选创建 swap
# ------------------------------------------------------------------
if [[ -n "$SWAP_SIZE" ]]; then
  echo "[2/6] 配置 swap ($SWAP_SIZE) ..."
  ssh "$TARGET" "SWAP_SIZE='$SWAP_SIZE' bash -s" <<'SWAP_EOF'
set -euo pipefail
# 换算目标 MB
case "$SWAP_SIZE" in
  *g|*G) TARGET_MB=$(( ${SWAP_SIZE%[gG]} * 1024 )) ;;
  *m|*M) TARGET_MB=${SWAP_SIZE%[mM]} ;;
  *)     TARGET_MB=$SWAP_SIZE ;;
esac
CUR_MB=$(awk '/^SwapTotal:/ {print int($2/1024)}' /proc/meminfo)
if (( CUR_MB >= TARGET_MB )); then
  echo "  ↳ 已有 ${CUR_MB}MB swap >= 目标 ${TARGET_MB}MB，跳过"
  exit 0
fi
if [[ -f /swapfile ]]; then
  swapoff /swapfile 2>/dev/null || true
  rm -f /swapfile
fi
fallocate -l "${TARGET_MB}M" /swapfile
chmod 600 /swapfile
mkswap /swapfile >/dev/null
swapon /swapfile
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
echo "  ↳ 已创建 ${TARGET_MB}MB swap 并持久化到 /etc/fstab"
SWAP_EOF
else
  if (( REMOTE_MEM_MB < 4096 && REMOTE_SWAP_MB < 512 )); then
    cat <<WARN
[2/6] ⚠️  强烈建议: 目标机 ${REMOTE_MEM_MB}MB RAM 且无 swap。
          Chromium + 视频编码会瞬间吃满内存，没有 swap 就是 thrashing。
          建议: ./deploy.sh $TARGET --swap 2g
WARN
  else
    echo "[2/6] 跳过 swap 配置（未指定 --swap）"
  fi
fi

# ------------------------------------------------------------------
# 3. 同步文件
# ------------------------------------------------------------------
echo "[3/6] 同步项目文件到 $TARGET:$REMOTE_DIR ..."
ssh "$TARGET" "mkdir -p '$REMOTE_DIR'"
rsync -az \
  --exclude='chromium-config/' \
  --exclude='gateway/certs/' \
  --exclude='.env' \
  --exclude='.git/' \
  --exclude='.claude/' \
  --exclude='deploy.sh' \
  --exclude='.DS_Store' \
  docker-compose.yml .env.example chromium gateway \
  "$TARGET:$REMOTE_DIR/"

# ------------------------------------------------------------------
# 4. 远端初始化: 凭据、证书、token 注入、Plan A 预置、合并新 env
# ------------------------------------------------------------------
echo "[4/6] 远端初始化凭据 / 证书 / 配置 ..."
ssh "$TARGET" "\
  REMOTE_DIR='$REMOTE_DIR' \
  SSH_HOST='$SSH_HOST' \
  WEB_PORT_CLI='$WEB_PORT' \
  CDP_PORT_CLI='$CDP_PORT' \
  ROTATE='$ROTATE' \
  bash -s" <<'REMOTE_EOF'
set -euo pipefail
cd "$REMOTE_DIR"

# ---- 4.1 .env: 首次从 .env.example 拷贝 + 生成凭据；重跑则智能合并 ----
if [[ ! -f .env ]]; then
  NEW_PW=$(openssl rand -base64 18 | tr -d '+/=' | cut -c1-20)
  NEW_TOKEN=$(openssl rand -hex 24)
  # 从 .env.example 拷一份作为底，然后把敏感字段替换
  cp .env.example .env
  perl -i -pe 's|^WEB_PASSWORD=.*|WEB_PASSWORD='"$NEW_PW"'|;
               s|^CDP_TOKEN=.*|CDP_TOKEN='"$NEW_TOKEN"'|' .env
  chmod 600 .env
  echo "  ↳ 首次部署，已生成新 .env (含新密码和 token)"
elif [[ "$ROTATE" == "1" ]]; then
  NEW_PW=$(openssl rand -base64 18 | tr -d '+/=' | cut -c1-20)
  NEW_TOKEN=$(openssl rand -hex 24)
  perl -i -pe 's|^WEB_PASSWORD=.*|WEB_PASSWORD='"$NEW_PW"'|;
               s|^CDP_TOKEN=.*|CDP_TOKEN='"$NEW_TOKEN"'|' .env
  echo "  ↳ 已重置密码和 token"
else
  # 合并: .env.example 有但 .env 没有的 key，追加到 .env
  # 只看 "KEY=..." 形式的行，注释/预设行保留在 .env.example 里
  NEW_KEYS=()
  while IFS='=' read -r k _; do
    [[ -z "$k" || "$k" =~ ^# ]] && continue
    grep -qE "^$k=" .env || NEW_KEYS+=("$k")
  done < <(grep -E '^[A-Z_]+=' .env.example)
  if (( ${#NEW_KEYS[@]} > 0 )); then
    echo "  ↳ 检测到 .env.example 有新变量, 追加到现有 .env: ${NEW_KEYS[*]}"
    {
      echo ""
      echo "# --- 以下字段由部署脚本从 .env.example 合并补入 ---"
      for k in "${NEW_KEYS[@]}"; do
        grep -E "^$k=" .env.example | head -1
      done
    } >> .env
  else
    echo "  ↳ 沿用已有 .env（无新字段）"
  fi
fi

# 命令行传入的端口覆盖 .env
upd() {  # upd KEY VALUE
  local key="$1" val="$2"
  if grep -qE "^$key=" .env; then
    sed -i.bak "s|^$key=.*|$key=$val|" .env
  else
    echo "$key=$val" >> .env
  fi
  rm -f .env.bak
}
[[ -n "$WEB_PORT_CLI" ]] && upd WEB_PORT "$WEB_PORT_CLI"
[[ -n "$CDP_PORT_CLI" ]] && upd CDP_PORT "$CDP_PORT_CLI"

CDP_TOKEN=$(grep '^CDP_TOKEN=' .env | cut -d= -f2)

# ---- 4.2 nginx.conf 里塞入当前 token (幂等) ----
perl -i -pe 's|\b[0-9a-f]{40,}\b|'"$CDP_TOKEN"'|g' gateway/nginx.conf
echo "  ↳ nginx.conf 内 token 出现 $(grep -c "$CDP_TOKEN" gateway/nginx.conf) 次 (应 >= 2)"

# ---- 4.3 自签证书 ----
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

# ---- 4.4 预置 Plan A autostart ----
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
# 5. 启动 + 兜底
# ------------------------------------------------------------------
echo "[5/6] 启动 docker compose ..."
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
# 6. 验证
# ------------------------------------------------------------------
echo "[6/6] 端到端验证 ..."
read -r CDP_TOKEN_VAL WEB_PW WEB_PORT_VAL CDP_PORT_VAL < <(ssh "$TARGET" "
  awk -F= '
    /^CDP_TOKEN=/    {t=\$2}
    /^WEB_PASSWORD=/ {p=\$2}
    /^WEB_PORT=/     {w=\$2}
    /^CDP_PORT=/     {c=\$2}
    END {printf \"%s %s %s %s\\n\", t, p, w?w:3000, c?c:9222}
  ' '$REMOTE_DIR/.env'
")

probe() { curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "$@" 2>/dev/null || echo 000; }

UI_401=$(probe "https://$SSH_HOST:$WEB_PORT_VAL/")
UI_200=$(probe -u "admin:$WEB_PW" "https://$SSH_HOST:$WEB_PORT_VAL/")
CDP_404=$(probe "http://$SSH_HOST:$CDP_PORT_VAL/")
CDP_BAD=$(probe "http://$SSH_HOST:$CDP_PORT_VAL/wrong/json/version")
CDP_OK=$(probe "http://$SSH_HOST:$CDP_PORT_VAL/$CDP_TOKEN_VAL/json/version")

printf "  Web UI 无密码 : HTTP %-3s  (期望 401)\n" "$UI_401"
printf "  Web UI 带密码 : HTTP %-3s  (期望 200)\n" "$UI_200"
printf "  CDP 无 token  : HTTP %-3s  (期望 404)\n" "$CDP_404"
printf "  CDP 错 token  : HTTP %-3s  (期望 404)\n" "$CDP_BAD"
printf "  CDP 正确 token: HTTP %-3s  (期望 502 — Chromium 还未启动；打开后 200)\n" "$CDP_OK"

# ------------------------------------------------------------------
# 输出
# ------------------------------------------------------------------
cat <<OUT

===============================================================
✅ 部署完成  ($TARGET)
===============================================================

◆ Web 云桌面
    URL :   https://$SSH_HOST:$WEB_PORT_VAL/
    用户:   admin
    密码:   $WEB_PW

◆ CDP (Chrome DevTools Protocol, 明文 + token)
    Token:  $CDP_TOKEN_VAL
    发现:   http://$SSH_HOST:$CDP_PORT_VAL/$CDP_TOKEN_VAL/json/version

    实时获取可用的 WS URL:
      curl -s "http://$SSH_HOST:$CDP_PORT_VAL/$CDP_TOKEN_VAL/json/version" \\
        | python3 -c "import sys,json;print(json.load(sys.stdin)['webSocketDebuggerUrl'])"

◆ 性能调优
    编辑: $REMOTE_DIR/.env  (分辨率 / 帧率 / 资源上限 / 低内存模式等)
    详解: 根目录的 .env.example 或 README.md 的"性能调优"章节

◆ 维护
    ssh $TARGET "cd $REMOTE_DIR && docker compose ps"
    ssh $TARGET "cd $REMOTE_DIR && docker compose logs -f"
    ssh $TARGET "cd $REMOTE_DIR && docker compose down"
    ssh $TARGET "cd $REMOTE_DIR && docker stats --no-stream"   # 负载诊断

◆ 凭据文件:   $REMOTE_DIR/.env   (已 chmod 600)
◆ 数据目录:   $REMOTE_DIR/chromium-config/
===============================================================
OUT
