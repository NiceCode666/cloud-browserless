# cloud-browserless

把一台云服务器变成**一台浏览器**——可以用网页远程操作，也可以通过 CDP 协议做自动化。

基于 [linuxserver/chromium](https://docs.linuxserver.io/images/docker-chromium) + nginx 网关，一个 `docker-compose.yml` 跑起来，一个 `deploy.sh` 部署到任何有 Docker 的服务器。

---

## 特性

- **Web 云桌面**：浏览器打开即得一个完整的远程 Chromium 桌面，带剪贴板/上传下载/多分辨率
- **CDP 远程自动化**：Puppeteer / Playwright / [bridgic-browser](https://github.com/bridgic/bridgic-browser) 等直接通过 ws:// 连入
- **同一个 Chromium 实例**：Web UI 手动操作的和 CDP 控制的是**同一个浏览器**——cookies、登录态、打开的标签都共享
- **Plan A 干净桌面**：开机不自动拉任何 App，什么时候需要什么时候开；通过 `proot-apps` 可以装 Firefox / VSCode / Obsidian / LibreOffice 等
- **一键部署**：`./deploy.sh root@<server>` 幂等，首次生成密码+token+自签证书，重跑沿用
- **最小端口面**：对外只要 2 个端口（Web UI 一个、CDP 一个）

---

## 架构

```
                         ┌─────────────────────────────────────┐
浏览器 ──HTTPS:3000──▶   │ nginx gateway                       │
                         │   :3443 TLS ──HTTP──▶ selkies :3000 │ ──▶ labwc 桌面
                         │                                     │        └─▶ Chromium
   CDP 客户端 ─HTTP:9222▶│   :9443 HTTP + token 鉴权           │             ↑
                         │              └─────▶ chromium :9222 │─────────────┘
                         └─────────────────────────────────────┘
                         (nginx 与 chromium 共用网络命名空间)
```

- 外部流量只经过两个端口：**Web UI 端口**（默认 3000，HTTPS）和 **CDP 端口**（默认 9222，HTTP + token）
- selkies 原生端口（3000 HTTP / 3001 HTTPS）和 Chromium 的 CDP 原端口（9222）**都不对外暴露**
- nginx 通过 `network_mode: service:chromium` 共用 chromium 容器的 netns，可以直接打到其 `127.0.0.1:9222`

---

## 快速开始

### 准备

- 一台能 SSH 免密登录的服务器，已装 Docker + docker compose
- 防火墙 / 安全组放开 Web UI 和 CDP 两个端口（默认 3000 + 9222）
- 本地有 `rsync`, `openssl`, `ssh`, `curl`

### 一行部署

```bash
git clone git@github.com:NiceCode666/cloud-browserless.git
cd cloud-browserless
./deploy.sh root@<your-server>
```

脚本会：

1. 检查远端 Docker 环境
2. 同步项目文件到 `/opt/cloud-browser/`
3. 生成随机 Web 密码 + CDP token + 自签证书
4. 预置 Plan A 干净桌面
5. `docker compose up -d`
6. 端到端验证
7. **在终端里打印凭据和访问地址**

完整参数：

```bash
./deploy.sh root@<host>
./deploy.sh root@<host> --dir /opt/my-dir
./deploy.sh root@<host> --web-port 3000 --cdp-port 9222
./deploy.sh root@<host> --rotate           # 重新生成密码和 token
./deploy.sh --help
```

---

## 使用

### 场景 1：Web 云桌面（人手动用）

1. 浏览器打开 `https://<server>:3000/`
2. 自签证书警告 → "高级" → "继续访问"
3. Basic Auth 登录（凭据在 deploy 后的输出里，或服务器 `/opt/cloud-browser/.env`）
4. 进入干净桌面 → 右键菜单开 Chromium（启动后自动带 CDP）
5. 右键开 Terminal 就能 `proot-apps install firefox` / `vscode` / … 装其他软件，装完出现在右键菜单

### 场景 2：CDP 远程自动化

**必须先在 Web 桌面里打开一次 Chromium**，CDP 端口才会监听。

获取当前 WebSocket URL：

```bash
TOKEN=<deploy 时打印的 CDP token>
curl -s "http://<server>:9222/$TOKEN/json/version" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['webSocketDebuggerUrl'])"
# 输出类似:
# ws://<server>:9222/<TOKEN>/devtools/browser/<uuid>
```

**Puppeteer**：

```js
const browser = await puppeteer.connect({
  browserWSEndpoint: 'ws://<server>:9222/<TOKEN>/devtools/browser/<uuid>',
});
```

**Playwright**：

```python
from playwright.async_api import async_playwright
async with async_playwright() as p:
    browser = await p.chromium.connect_over_cdp(
        'ws://<server>:9222/<TOKEN>/devtools/browser/<uuid>'
    )
```

**bridgic-browser**：

```bash
WS=$(curl -s "http://<server>:9222/<TOKEN>/json/version" \
     | python3 -c "import sys,json;print(json.load(sys.stdin)['webSocketDebuggerUrl'])")
bridgic-browser open https://example.com --cdp "$WS"
```

> UUID 会随 Chromium 重启变化，所以上面这一行 `curl … | python3 …` 建议写成 shell alias，用的时候直接取。

---

## 性能调优

> **机器规格对体感影响极大**。在 2vCPU / 3GB RAM 的机器上，默认的 selkies 配置会让整机 load average 飙到 10+、操作延迟上秒。所以**所有调优项都通过 `.env` 可配置**，低配默认值保证能用，升级到生产规格的机器改几个数字就能跑到满画质。

### 调优原理图

```
                  ↑ 需要更多 CPU
 高画质(1080p60) ┃                   ┌─ GPU 硬编码    (8vCPU + GPU)
                 ┃                   │
                 ┃     高配预设 ─────┤
                 ┃                   └─ 软编码        (8vCPU, 无 GPU)
  中画质(1080p60)┃
                 ┃     中配预设  ─────── 软编码        (4vCPU/8GB)
                 ┃
  低画质(720p30) ┃     低配预设  ─────── 软编码+低内存模式 (2vCPU/3GB 默认)
                 ┃
                 ┃
                 └────────────────────────────────────→ 机器性能
```

### 三档预设（在 `.env` 里切换）

完整配置看项目根目录的 **`.env.example`**。服务器上对应文件是 `/opt/cloud-browser/.env`。

#### 低配（2vCPU / 3~4GB, **默认值**）

```env
DISPLAY_WIDTH=1280
DISPLAY_HEIGHT=720
SELKIES_FRAMERATE=30
SELKIES_VIDEO_BITRATE=4000
CHROMIUM_MEM_LIMIT=2g
CHROMIUM_CPUS=1.5
CHROMIUM_SHM_SIZE=1g
CHROMIUM_LOW_MEMORY_MODE=1
CHROMIUM_JS_HEAP_MB=512
```

体感：能用；1280×720 流畅滚动/输入；1080p 视频会卡。**强烈建议配合 2GB swap**（见下）。

#### 中配（4vCPU / 8GB, **推荐生产**）

```env
DISPLAY_WIDTH=1920
DISPLAY_HEIGHT=1080
SELKIES_FRAMERATE=60
SELKIES_VIDEO_BITRATE=8000
CHROMIUM_MEM_LIMIT=6g
CHROMIUM_CPUS=3
CHROMIUM_SHM_SIZE=2g
CHROMIUM_LOW_MEMORY_MODE=0
CHROMIUM_JS_HEAP_MB=2048
```

体感：无感，跟本地 Chrome 接近；多标签没压力。

#### 高配（8vCPU+ / 16GB+ / 带 GPU）

```env
DISPLAY_WIDTH=1920
DISPLAY_HEIGHT=1200
SELKIES_FRAMERATE=60
SELKIES_VIDEO_BITRATE=12000
SELKIES_ENCODER=vah264enc            # Intel/AMD GPU 硬编
# SELKIES_ENCODER=nvh264enc          # NVIDIA GPU（需要挂 /dev/nvidia*）
CHROMIUM_MEM_LIMIT=12g
CHROMIUM_CPUS=6
CHROMIUM_LOW_MEMORY_MODE=0
```

体感：丝滑，看视频/剪音频都行；GPU 硬编几乎不占 CPU。

### 改完怎么生效

两条路都行，挑顺手的：

```bash
# 方式 1: 本地改 .env.example → git push → 到服务器 pull 后改 .env → 重启
# 方式 2: 直接登录服务器改 .env，再重跑部署
ssh root@<server> "vim /opt/cloud-browser/.env"
./deploy.sh root@<server>     # 密码/token 不会被重置（除非加 --rotate）
```

### Swap 建议（低配机器强制要做）

对 3~4GB 的机器，**一定要加 swap**。没有 swap：
- Chromium + 视频编码 + PulseAudio 一瞬间就把内存填满
- 内核狂刷 page cache 来腾空间 → 50% 以上的时间是 `%iowait`
- SSH/sshd 都拿不到 CPU，服务器失联

部署脚本自带 swap 选项：

```bash
# 第一次部署时一起做
./deploy.sh root@<server> --swap 2g

# 已经部署过的机器单独加
./deploy.sh root@<server> --swap 2g
```

手工方式（如果不想用部署脚本）：

```bash
ssh root@<server>
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

### 诊断瓶颈

怀疑卡顿时，按顺序排查：

```bash
# 1. 网络：ping + 带宽
ping <server>                       # RTT 应 < 80ms；> 150ms 一定卡
# 2. 服务器 load / 内存
ssh <server> 'uptime; free -m | head -2'
# load average 应 < 核心数；若超过 2× 核心数，服务器扛不住
# available 应 > 500MB
# 3. 容器资源用量
ssh <server> 'docker stats --no-stream'
# CPU 总和接近 CHROMIUM_CPUS × 100% 说明编码达到上限，需升机器或降画质
# 4. Chromium 进程数
ssh <server> 'docker exec cloud-chromium pgrep -c chromium'
# 正常 5~15 个；突然变 30+ 多半是某个站起了很多 iframe 卡住了
```

### 常见故障 → 应对

| 症状 | 原因 | 解决 |
|---|---|---|
| 点哪都卡，鼠标也跟不上 | CPU 满载，编码跟不上 | 降分辨率/帧率，或升机器 |
| 操作几分钟后服务器失联（SSH 不通） | 内存不足 → thrashing | `./deploy.sh … --swap 2g` |
| chromium 突然消失 | `mem_limit` 被命中，OOM-kill | 调大 `CHROMIUM_MEM_LIMIT` 或升机器 |
| 打字有明显延迟 | 编码延迟 + 网络 RTT | 看 RTT，升配，或换更近机房 |
| 视频播放严重卡顿 | 码率给太低 / 编码跟不上 | 提 `SELKIES_VIDEO_BITRATE`，或升级 |

---

## 安全说明

当前**默认配置**下的安全模型：

| 通路 | 加密 | 认证 | 适用 |
|---|---|---|---|
| Web UI (`:3000`) | TLS（自签） | HTTP Basic Auth | 人手动用 |
| CDP (`:9222`) | **无 TLS，明文** | token 路径前缀 | 非敏感自动化（抓公开数据、测试） |
| SSH 隧道（`127.0.0.1:9223`） | SSH | SSH key | 敏感场景的后备通道 |

**CDP 现在是明文** —— 指令和数据会在公网明文传。如果你要用它抓取登录态/处理私密数据，**必须升级回 TLS**：

打开 `gateway/nginx.conf`，找到 CDP 网关那段，把：

```nginx
server {
  listen 9443;
  ...
}
```

改回：

```nginx
server {
  listen 9443 ssl http2;
  ssl_certificate     /etc/nginx/certs/cert.pem;
  ssl_certificate_key /etc/nginx/certs/key.pem;
  ...
  # sub_filter 里 ws:// 改回 wss://
}
```

然后 `./deploy.sh root@<server>` 重跑。客户端访问改用 `https://…` / `wss://…`，自签证书需要客户端配合（`NODE_EXTRA_CA_CERTS` 指向下载的 `cert.pem`，或换 Let's Encrypt 真证书）。

---

## 运维

```bash
# 查看状态
ssh root@<server> 'cd /opt/cloud-browser && docker compose ps'

# 看日志
ssh root@<server> 'cd /opt/cloud-browser && docker compose logs -f chromium'
ssh root@<server> 'cd /opt/cloud-browser && docker compose logs -f cdp-gateway'

# 重启
ssh root@<server> 'cd /opt/cloud-browser && docker compose restart'

# 完全停掉（保留数据）
ssh root@<server> 'cd /opt/cloud-browser && docker compose down'

# 更新到最新配置（再跑一遍部署脚本即可）
./deploy.sh root@<server>

# 轮换密码和 token
./deploy.sh root@<server> --rotate
```

## 数据和凭据位置

服务器端：

- `/opt/cloud-browser/.env` — 所有凭据（`chmod 600`）
- `/opt/cloud-browser/gateway/certs/` — 自签证书
- `/opt/cloud-browser/chromium-config/` — 浏览器 profile、proot 装的 App、下载文件

---

## 常见问题

**Q: 打开 `http://<server>:3000/` 显示黑屏 + 要求 HTTPS？**
A: selkies（KasmVNC）强制 HTTPS 才能跑桌面流（secure context）。直接用 `https://`，或 nginx 的 497 已经配置自动 301 跳转 HTTPS。

**Q: 进去是黑屏，右键只有 Terminal 和 Chrome？**
A: 这是 Plan A 的预期效果——裸的 labwc 窗口管理器，没面板。右键就是启动器；装了其他 App 会自动出现在右键菜单。

**Q: CDP 返回 502？**
A: Chromium 还没在桌面里打开。Plan A 不自动启动，必须用户从网页桌面里点 Chromium 一次。

**Q: UUID 变了？**
A: Chromium 重启（你在桌面里关了再开）后 UUID 变。重新 `curl /json/version` 拿即可。

**Q: 镜像拉不动（国内服务器）？**
A: `linuxserver/chromium:latest` 来自 Docker Hub，通常受益于国内 mirror。服务器 `/etc/docker/daemon.json` 配了 `registry-mirrors` 基本无痛。

---

## 文件清单

```
cloud-browserless/
├── deploy.sh                       # 一键部署脚本（含 swap、性能预设、幂等 .env 合并）
├── docker-compose.yml              # chromium + nginx 网关；资源上限/画质 全部从 env 读
├── .env.example                    # 所有可调参数文档化 + 三档预设
├── .gitignore
├── chromium/
│   ├── autostart                   # Plan A: 空 X11 autostart
│   ├── autostart_wayland           # Plan A: 空 Wayland autostart
│   └── wrapped-chromium            # 包装器：CDP + 低内存模式(可关) + 自定义参数
└── gateway/
    └── nginx.conf                  # CDP token 鉴权 + Web UI HTTPS 终结
```

运行后服务器上另外会产生（均在 `.gitignore`）：

- `.env` — 凭据和可调参数（首次由 `.env.example` 模板生成）
- `gateway/certs/` — 自签证书
- `chromium-config/` — 浏览器持久数据

---

## License

MIT
