#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# new-api Codespaces 一键启动脚本
#
# 功能:
#   1. 检查并安装 Go (>=1.22)、Bun、MySQL、Redis
#   2. 启动 MySQL/Redis 服务
#   3. 按 .env 中的 SQL_DSN 配置 MySQL root 密码 + 创建 newapi 数据库
#   4. 安装后端 (go mod download) + 前端 (bun install) 依赖
#   5. 构建前端 (bun run build)
#   6. 后台启动后端服务并打印访问地址
#
# 用法:
#   chmod +x codespace-setup.sh
#   ./codespace-setup.sh
#
# 设计原则:
#   - 幂等: 重复执行不会破坏现有环境
#   - 可读: 每步都有日志
#   - 健壮: set -euo pipefail, 关键步骤有错误处理
# ------------------------------------------------------------------------------

set -euo pipefail

# ---------------------- 配置 ----------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
LOG_DIR="${SCRIPT_DIR}/logs"
APP_LOG="${LOG_DIR}/new-api.log"
PID_FILE="${SCRIPT_DIR}/.new-api.pid"

GO_MIN_VERSION="1.22"
GO_INSTALL_VERSION="1.25.1"   # 与 go.mod 对齐
APP_PORT="${PORT:-3000}"       # 后端默认端口

# ---------------------- 日志 ----------------------
log()   { printf "\033[1;34m[INFO]\033[0m  %s\n" "$*"; }
warn()  { printf "\033[1;33m[WARN]\033[0m  %s\n" "$*"; }
error() { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; }
ok()    { printf "\033[1;32m[OK]\033[0m    %s\n" "$*"; }

trap 'error "脚本在第 $LINENO 行失败,退出码 $?"; exit 1' ERR

# ---------------------- 工具函数 ----------------------
need_sudo() {
  if [[ $EUID -eq 0 ]]; then
    echo ""
  else
    echo "sudo"
  fi
}
SUDO="$(need_sudo)"

has_cmd() { command -v "$1" >/dev/null 2>&1; }

version_ge() {
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# ---------------------- 飞书机器人通知 ----------------------
FEISHU_WEBHOOK="https://open.feishu.cn/open-apis/bot/v2/hook/0dfdcf6b-8435-4978-b116-7364d9f3ac79"

# 根据标题关键词决定卡片颜色
_feishu_template() {
  local title="$1"
  if [[ "$title" == *"告警"* && "$title" == *"通知"* ]]; then
    echo "red"
  elif [[ "$title" == *"告警"* ]]; then
    echo "orange"
  elif [[ "$title" == *"通知"* ]]; then
    echo "green"
  else
    echo "blue"
  fi
}

# 发送飞书卡片消息: notify_feishu "标题" "markdown正文" ["来源"]
notify_feishu() {
  local title="$1"
  local content="$2"
  local source="${3:-Codespaces 自动部署}"
  local now
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  local template
  template="$(_feishu_template "$title")"

  if ! has_cmd jq; then
    warn "jq 未安装，跳过飞书通知"
    return 0
  fi

  jq -n \
    --arg title "$title" \
    --arg content "$content" \
    --arg template "$template" \
    --arg source "$source" \
    --arg now "$now" \
    '{
      msg_type: "interactive",
      card: {
        header: {
          title: { tag: "plain_text", content: $title },
          template: $template
        },
        elements: [
          { tag: "markdown", content: $content },
          { tag: "hr" },
          { tag: "note", elements: [
            { tag: "plain_text", content: ("来源：" + $source + " | 时间：" + $now) }
          ]}
        ]
      }
    }' | curl -s -X POST "$FEISHU_WEBHOOK" \
      -H 'Content-Type: application/json' \
      -d @- >/dev/null 2>&1 || true
}

# 错误时也通知
trap_handler() {
  local line="$1"
  local ec="$2"
  error "脚本在第 ${line} 行失败,退出码 ${ec}"
  notify_feishu "⚠️ 【告警】部署脚本执行失败" "**失败位置：** 第 ${line} 行\n**退出码：** ${ec}\n\n部署过程中发生错误，请检查日志。" "Codespaces 部署脚本"
  exit 1
}
trap 'trap_handler $LINENO $?' ERR

# ---------------------- 0. 校验环境 ----------------------
log "检查运行环境..."
if ! has_cmd apt-get; then
  error "本脚本仅支持基于 Debian/Ubuntu 的 Codespaces 环境 (依赖 apt-get)"
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  error ".env 文件不存在: $ENV_FILE"
  exit 1
fi

mkdir -p "$LOG_DIR"

# 加载 .env (安全逐行解析，支持含括号等特殊字符的值)
while IFS= read -r line || [[ -n "$line" ]]; do
  # 跳过注释和空行
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// }" ]] && continue
  # 只处理 KEY=VALUE 格式
  if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    # 去掉值两端的引号（单引号或双引号）
    val="${val#\"}" ; val="${val%\"}"
    val="${val#\'}" ; val="${val%\'}"
    export "$key=$val"
  fi
done < "$ENV_FILE"

if [[ -z "${SQL_DSN:-}" ]]; then
  error ".env 中缺少 SQL_DSN"
  exit 1
fi

# 解析 SQL_DSN: user:pass@tcp(host:port)/dbname
# 例: root:root@tcp(localhost:3306)/newapi
DSN_RE='^([^:]+):([^@]+)@tcp\(([^:]+):([0-9]+)\)/(.+)$'
if [[ ! "$SQL_DSN" =~ $DSN_RE ]]; then
  error "无法解析 SQL_DSN: $SQL_DSN"
  exit 1
fi
DB_USER="${BASH_REMATCH[1]}"
DB_PASS="${BASH_REMATCH[2]}"
DB_HOST="${BASH_REMATCH[3]}"
DB_PORT="${BASH_REMATCH[4]}"
DB_NAME="${BASH_REMATCH[5]%%\?*}"   # 去掉可能的 ?params

ok "解析 SQL_DSN: user=$DB_USER host=$DB_HOST:$DB_PORT db=$DB_NAME"

# 飞书通知: 脚本启动
notify_feishu "📌 【部署】Codespaces 环境初始化开始" "**环境：** ${CODESPACE_NAME:-本地}\n**数据库：** ${DB_NAME}\n**端口：** ${APP_PORT}\n\n开始安装依赖、构建前端、启动后端..."

# ---------------------- 1. 安装系统依赖 ----------------------
log "更新 apt 索引 (静默)..."
$SUDO apt-get update -qq

install_pkg_if_missing() {
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    log "安装 $pkg ..."
    $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >/dev/null
  else
    ok "$pkg 已安装"
  fi
}

install_pkg_if_missing curl
install_pkg_if_missing ca-certificates
install_pkg_if_missing build-essential
install_pkg_if_missing unzip
install_pkg_if_missing jq

# ---------------------- 2. Go ----------------------
install_go() {
  log "安装 Go ${GO_INSTALL_VERSION} ..."
  local arch
  case "$(uname -m)" in
    x86_64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) error "不支持的架构: $(uname -m)"; exit 1 ;;
  esac
  local tarball="go${GO_INSTALL_VERSION}.linux-${arch}.tar.gz"
  local url="https://go.dev/dl/${tarball}"
  curl -fsSL "$url" -o "/tmp/${tarball}"
  $SUDO rm -rf /usr/local/go
  $SUDO tar -C /usr/local -xzf "/tmp/${tarball}"
  rm -f "/tmp/${tarball}"
  # 持久化 PATH
  if ! grep -q '/usr/local/go/bin' /etc/profile.d/go.sh 2>/dev/null; then
    echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' | $SUDO tee /etc/profile.d/go.sh >/dev/null
  fi
  export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"
}

if has_cmd go; then
  current_go="$(go version | awk '{print $3}' | sed 's/go//')"
  if version_ge "$current_go" "$GO_MIN_VERSION"; then
    ok "Go 已安装: $current_go"
  else
    warn "Go 版本过低 ($current_go), 升级中..."
    install_go
  fi
else
  install_go
fi

export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"
ok "Go: $(go version)"

# ---------------------- 3. Bun ----------------------
if has_cmd bun; then
  ok "Bun 已安装: $(bun --version)"
else
  log "安装 Bun ..."
  curl -fsSL https://bun.sh/install | bash >/dev/null
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"
  if ! grep -q 'BUN_INSTALL' "$HOME/.bashrc" 2>/dev/null; then
    {
      echo 'export BUN_INSTALL="$HOME/.bun"'
      echo 'export PATH="$BUN_INSTALL/bin:$PATH"'
    } >> "$HOME/.bashrc"
  fi
  ok "Bun: $(bun --version)"
fi

# ---------------------- 4. MySQL ----------------------
install_pkg_if_missing mysql-server

start_mysql() {
  if has_cmd systemctl && systemctl list-units --type=service 2>/dev/null | grep -q mysql; then
    $SUDO systemctl start mysql || true
  fi
  # Codespaces 通常无 systemd, 用 service 或直接 mysqld_safe
  if ! pgrep -x mysqld >/dev/null 2>&1; then
    if has_cmd service; then
      $SUDO service mysql start >/dev/null 2>&1 || true
    fi
  fi
  if ! pgrep -x mysqld >/dev/null 2>&1; then
    log "用 mysqld_safe 后台启动 MySQL ..."
    $SUDO mkdir -p /var/run/mysqld
    $SUDO chown mysql:mysql /var/run/mysqld
    $SUDO bash -c 'nohup mysqld_safe --user=mysql >/var/log/mysqld.out 2>&1 &'
  fi
  # 等待端口就绪
  for i in {1..30}; do
    if (echo > "/dev/tcp/127.0.0.1/${DB_PORT}") >/dev/null 2>&1; then
      ok "MySQL 已就绪 (端口 ${DB_PORT})"
      return 0
    fi
    sleep 1
  done
  error "MySQL 启动超时"
  return 1
}

log "启动 MySQL 服务..."
start_mysql

configure_mysql() {
  log "配置 MySQL root 密码 / 数据库 ..."

  # 统一用 TCP 连接 (避免 socket 权限问题 errno 13)
  local TCP="-h 127.0.0.1 -P ${DB_PORT} --protocol=TCP"

  # 方式 A: 目标密码已设置好 (幂等)
  if mysql -u"$DB_USER" -p"$DB_PASS" $TCP -e "SELECT 1" >/dev/null 2>&1; then
    ok "MySQL 密码已正确配置"
  else
    local sql="
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED WITH mysql_native_password BY '${DB_PASS}';
FLUSH PRIVILEGES;
"
    # 方式 B: sudo + socket (权限足够时)
    if $SUDO mysql -u root -e "$sql" 2>/dev/null; then
      ok "已通过 sudo socket 设置 root 密码"
    # 方式 C: TCP 空密码 root (部分 Codespaces 镜像默认无密码)
    elif mysql -u root $TCP -e "$sql" 2>/dev/null; then
      ok "已通过 TCP 空密码 root 设置密码"
    else
      error "无法以管理员身份登录 MySQL 设置密码,请手动处理"
      exit 1
    fi
  fi

  # 创建数据库 (统一走 TCP)
  mysql -u"$DB_USER" -p"$DB_PASS" $TCP -e "
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
" 2>/dev/null
  ok "数据库 ${DB_NAME} 就绪"
}
configure_mysql

# ---------------------- 5. Redis ----------------------
install_pkg_if_missing redis-server

start_redis() {
  if pgrep -x redis-server >/dev/null 2>&1; then
    ok "Redis 已在运行"
    return
  fi
  if has_cmd systemctl && systemctl list-units --type=service 2>/dev/null | grep -q redis; then
    $SUDO systemctl start redis-server || true
  fi
  if ! pgrep -x redis-server >/dev/null 2>&1; then
    if has_cmd service; then
      $SUDO service redis-server start >/dev/null 2>&1 || true
    fi
  fi
  if ! pgrep -x redis-server >/dev/null 2>&1; then
    log "用 nohup 后台启动 Redis ..."
    $SUDO bash -c 'nohup redis-server --daemonize yes >/var/log/redis-codespace.log 2>&1'
  fi
  for i in {1..15}; do
    if (echo > /dev/tcp/127.0.0.1/6379) >/dev/null 2>&1; then
      ok "Redis 已就绪 (端口 6379)"
      return 0
    fi
    sleep 1
  done
  warn "Redis 启动超时 (项目可能仍可用内存缓存运行)"
}
log "启动 Redis 服务..."
start_redis

# ---------------------- 6. 后端依赖 ----------------------
log "下载 Go 依赖 ..."
cd "$SCRIPT_DIR"
go mod download
ok "Go 依赖完成"

# ---------------------- 7. 前端依赖 + 构建 ----------------------
log "安装前端依赖 (bun install) ..."
cd "$SCRIPT_DIR/web"
bun install --silent
ok "前端依赖完成"

# 飞书通知: 开始构建
notify_feishu "📌 【部署】前端构建开始" "**步骤：** Vite 生产构建\n**堆内存：** 2048MB\n**Swap：** 已启用 4GB\n\n正在构建前端..."

log "构建前端 (bun run build) ..."
# Codespaces 默认机器仅 4GB RAM，需要多重优化防止 Node OOM

# 1. 添加 swap (部分容器可用)
if ! swapon --show=SIZE --noheadings | grep -q '4G'; then
  log "创建 swap 文件 (4GB) 以防 OOM ..."
  sudo fallocate -l 4G /swapfile 2>/dev/null
  sudo chmod 600 /swapfile 2>/dev/null
  sudo mkswap /swapfile 2>/dev/null
  sudo swapon /swapfile 2>/dev/null || true
fi

# 2. 释放系统缓存，为构建腾出内存
sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true

# 3. 允许内核内存超分配 — Node 可分配超过物理 RAM 的虚拟内存
#    这是 Redis 官方推荐的设置，对短生命周期的构建进程安全
sudo sysctl -w vm.overcommit_memory=1 2>/dev/null || true

# 4. 堆上限 3072MB — 超分配模式下 3GB 虚拟内存分配会成功，GC 有足够空间回收
export NODE_OPTIONS="--max-old-space-size=3072"

# 5. 两阶段构建: 先不压缩 (减少 Rollup 生成阶段峰值内存)
log "第一阶段: Vite 构建 (不压缩)..."
node ./node_modules/vite/bin/vite.js build --minify false

# 6. 用 esbuild (Go 实现, 内存占用 ~50MB) 压缩输出
log "第二阶段: esbuild 压缩..."
for f in ./dist/assets/*.js; do
  node ./node_modules/esbuild/bin/esbuild "$f" --minify --allow-overwrite --outfile="$f"
done
for f in ./dist/assets/*.css; do
  node ./node_modules/esbuild/bin/esbuild "$f" --minify --allow-overwrite --outfile="$f" --loader=css
done

ok "前端构建完成 -> web/dist"

# 飞书通知: 构建成功
notify_feishu "🔔 【通知】前端构建完成" "**状态：** ✅ 成功\n**输出目录：** web/dist\n**堆内存：** 2048MB"

# ---------------------- 8. 启动后端 (后台) ----------------------
cd "$SCRIPT_DIR"

# 如果已在跑, 先停掉
if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  warn "检测到旧进程 (PID=$(cat "$PID_FILE")), 先停止"
  kill "$(cat "$PID_FILE")" || true
  sleep 2
fi

log "后台启动 new-api ..."
# 通过 nohup + setsid 使其完全脱离当前 shell
nohup env PORT="$APP_PORT" go run main.go >"$APP_LOG" 2>&1 &
APP_PID=$!
echo "$APP_PID" > "$PID_FILE"

# 等待端口就绪
log "等待服务监听端口 ${APP_PORT} ..."
for i in {1..60}; do
  if (echo > "/dev/tcp/127.0.0.1/${APP_PORT}") >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    error "进程已退出, 查看日志: $APP_LOG"
    tail -n 50 "$APP_LOG" >&2 || true
    exit 1
  fi
  sleep 1
done

if ! (echo > "/dev/tcp/127.0.0.1/${APP_PORT}") >/dev/null 2>&1; then
  error "服务在 60s 内未监听 ${APP_PORT},日志: $APP_LOG"
  tail -n 50 "$APP_LOG" >&2 || true
  exit 1
fi

# ---------------------- 9. 打印访问地址 ----------------------
ok "===================================================="
ok "  new-api 启动成功"
ok "  PID:        $APP_PID  (写入 $PID_FILE)"
ok "  日志:       $APP_LOG"
ok "  本地地址:   http://localhost:${APP_PORT}"
if [[ -n "${CODESPACE_NAME:-}" ]] && [[ -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]]; then
  ok "  Codespaces: https://${CODESPACE_NAME}-${APP_PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
fi
ok "  停止命令:   kill \$(cat ${PID_FILE})"
ok "  查看日志:   tail -f ${APP_LOG}"
ok "===================================================="

# 飞书通知: 部署完成
ACCESS_URL="http://localhost:${APP_PORT}"
if [[ -n "${CODESPACE_NAME:-}" ]] && [[ -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]]; then
  ACCESS_URL="https://${CODESPACE_NAME}-${APP_PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
fi
notify_feishu "🔔 【通知】new-api 部署完成" "**状态：** ✅ 服务已启动\n**PID：** ${APP_PID}\n**访问地址：** ${ACCESS_URL}\n**停止命令：** kill \$(cat ${PID_FILE})\n**查看日志：** tail -f ${APP_LOG}"
