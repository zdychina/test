#!/bin/bash
# =====================================================================
# deploy2.sh — deploy.sh 优化版
#
# 改进点:
#   1. 敏感信息(MASTER_KEY/ADMIN_PASSWORD)不再硬编码, 支持从环境变量
#      或同目录 deploy.env 文件读取(建议将 deploy.env 加入 .gitignore)
#   2. 支持 start/stop/restart/status/log 子命令
#   3. PID 文件管理, 防止重复启动
#   4. 启动前预检: java、jar 包是否存在, 端口是否被占用
#   5. 启动后验证进程存活并探测端口就绪
#   6. 日志按大小自动轮转(默认 10MB)
#   7. 支持 systemd 开机自启: install 一键安装系统服务(崩溃自动拉起),
#      托管后 start/stop/restart/status 自动转交 systemctl
#
# 用法: ./deploy2.sh {start|stop|restart|status|log|install|uninstall}
# =====================================================================
set -euo pipefail

# ---------- 基础配置(均可用环境变量覆盖) ----------
JAR_FILE="${JAR_FILE:-mcp-gateway-1.0.0.jar}"
PID_FILE="${PID_FILE:-mcp-gateway.pid}"
LOG_FILE="${LOG_FILE:-mcp-gateway.log}"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-10485760}"   # 10MB
SERVICE_NAME="${SERVICE_NAME:-mcp-gateway}"  # systemd 服务名(install 时使用)

# 定位脚本所在目录, 保证 jar/日志/pid 的相对路径与调用位置无关
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------- 敏感配置: 环境变量 > deploy.env > 无默认值 ----------
# deploy.env 不入库, 内容示例:
#   export MCP_GATEWAY_MASTER_KEY='your-key'
#   export MCP_GATEWAY_ADMIN_PASSWORD='your-password'
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/deploy.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

MCP_GATEWAY_BASE_URL="${MCP_GATEWAY_BASE_URL:-http://127.0.0.1:9998}"
MCP_GATEWAY_BIND_ADDRESS="${MCP_GATEWAY_BIND_ADDRESS:-0.0.0.0}"
MCP_GATEWAY_PORT="${MCP_GATEWAY_PORT:-9998}"
MCP_GATEWAY_ADMIN_USERNAME="${MCP_GATEWAY_ADMIN_USERNAME:-admin}"
MCP_GATEWAY_DOWNSTREAM_INSECURE_SKIP_TLS_VERIFY="${MCP_GATEWAY_DOWNSTREAM_INSECURE_SKIP_TLS_VERIFY:-true}"
export MCP_GATEWAY_BASE_URL MCP_GATEWAY_BIND_ADDRESS MCP_GATEWAY_PORT \
       MCP_GATEWAY_ADMIN_USERNAME MCP_GATEWAY_DOWNSTREAM_INSECURE_SKIP_TLS_VERIFY

# ---------- 工具函数 ----------
info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()  { info "错误: $*"; exit 1; }

# 输出运行中进程的 PID; 未运行则返回非 0
get_pid() {
    [ -f "$PID_FILE" ] || return 1
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    echo "$pid"
}

is_running() { get_pid >/dev/null; }

# 服务是否已由 systemd 托管(已安装并 enable)
systemd_managed() {
    command -v systemctl >/dev/null 2>&1 && systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1
}

port_in_use() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | grep -q ":${MCP_GATEWAY_PORT} "
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | grep -q ":${MCP_GATEWAY_PORT} "
    else
        return 1   # 系统无可用工具时跳过检查
    fi
}

rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(wc -c <"$LOG_FILE")" -gt "$LOG_MAX_BYTES" ]; then
        mv -f "$LOG_FILE" "$LOG_FILE.1"
        info "日志已超过 $((LOG_MAX_BYTES / 1024 / 1024))MB, 轮转为 $LOG_FILE.1"
    fi
}

# ---------- 启动前预检 ----------
preflight() {
    command -v java >/dev/null 2>&1 || die "未找到 java 命令, 请先安装 JRE/JDK"
    [ -f "$JAR_FILE" ] || die "未找到 $JAR_FILE (可用 JAR_FILE=/path/to/app.jar 覆盖)"
    if port_in_use; then
        die "端口 $MCP_GATEWAY_PORT 已被占用, 请先执行 $0 stop 或用 MCP_GATEWAY_PORT 换端口"
    fi
    if [ -z "${MCP_GATEWAY_MASTER_KEY:-}" ]; then
        info "警告: 未设置 MCP_GATEWAY_MASTER_KEY, 建议在 deploy.env 或环境变量中提供"
    fi
    if [ -z "${MCP_GATEWAY_ADMIN_PASSWORD:-}" ]; then
        info "警告: MCP_GATEWAY_ADMIN_PASSWORD 为空, 管理接口处于无密码状态"
    fi
}

# ---------- 子命令 ----------
start() {
    if systemd_managed; then
        info "服务已由 systemd 托管, 转交 systemctl"
        systemctl start "$SERVICE_NAME"
        return 0
    fi
    if is_running; then
        info "服务已在运行 (PID $(get_pid)), 无需重复启动"
        return 0
    fi
    rm -f "$PID_FILE"   # 清理残留的 pid 文件
    preflight
    rotate_log

    nohup java ${JAVA_OPTS:-} -jar "$JAR_FILE" >>"$LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" >"$PID_FILE"
    info "服务已启动 (PID $pid), 等待端口 $MCP_GATEWAY_PORT 就绪..."

    local i
    for i in $(seq 1 30); do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_FILE"
            die "进程启动后异常退出, 请查看 $LOG_FILE"
        fi
        port_in_use && break
        sleep 1
    done

    if port_in_use; then
        info "启动成功: 端口 $MCP_GATEWAY_PORT 已监听, 日志: $LOG_FILE"
    else
        info "端口 $MCP_GATEWAY_PORT 30 秒内未监听(可能仍在初始化), 日志: $LOG_FILE"
    fi
}

stop() {
    if systemd_managed; then
        info "服务已由 systemd 托管, 转交 systemctl"
        systemctl stop "$SERVICE_NAME"
        return 0
    fi
    if ! is_running; then
        info "服务未在运行"
        rm -f "$PID_FILE"
        return 0
    fi
    local pid
    pid="$(get_pid)"
    info "停止服务 (PID $pid)..."
    kill "$pid" 2>/dev/null || true

    local i
    for i in $(seq 1 30); do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_FILE"
            info "服务已停止"
            return 0
        fi
        sleep 1
    done
    info "优雅停止超时, 强制结束进程..."
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    info "服务已停止"
}

restart() {
    if systemd_managed; then
        info "服务已由 systemd 托管, 转交 systemctl"
        systemctl restart "$SERVICE_NAME"
        return 0
    fi
    stop
    start
}

status() {
    if systemd_managed; then
        systemctl status "$SERVICE_NAME"
        return 0
    fi
    if is_running; then
        info "运行中 (PID $(get_pid), 端口 $MCP_GATEWAY_PORT)"
    else
        info "未运行"
        exit 1
    fi
}

# ---------- 开机自启(systemd) ----------
install_service() {
    [ "$(id -u)" -eq 0 ] || die "安装系统服务需要 root 权限, 请执行: sudo $0 install"

    # 先停掉手动启动的实例, 避免端口冲突
    is_running && stop
    preflight

    local java_bin jar_path log_path
    java_bin="$(command -v java)"
    case "$JAR_FILE" in /*) jar_path="$JAR_FILE" ;; *) jar_path="$SCRIPT_DIR/$JAR_FILE" ;; esac
    case "$LOG_FILE"  in /*) log_path="$LOG_FILE"  ;; *) log_path="$SCRIPT_DIR/$LOG_FILE"  ;; esac

    cat >"/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=MCP Gateway Service
After=network.target

[Service]
Type=simple
WorkingDirectory=$SCRIPT_DIR
EnvironmentFile=-$ENV_FILE
Environment=MCP_GATEWAY_BASE_URL=$MCP_GATEWAY_BASE_URL
Environment=MCP_GATEWAY_BIND_ADDRESS=$MCP_GATEWAY_BIND_ADDRESS
Environment=MCP_GATEWAY_PORT=$MCP_GATEWAY_PORT
Environment=MCP_GATEWAY_ADMIN_USERNAME=$MCP_GATEWAY_ADMIN_USERNAME
Environment=MCP_GATEWAY_DOWNSTREAM_INSECURE_SKIP_TLS_VERIFY=$MCP_GATEWAY_DOWNSTREAM_INSECURE_SKIP_TLS_VERIFY
ExecStart=$java_bin ${JAVA_OPTS:-} -jar $jar_path
StandardOutput=append:$log_path
StandardError=append:$log_path
SuccessExitStatus=143
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"
    info "系统服务 $SERVICE_NAME 已安装并启动, 开机自启已开启"
    info "后续可继续使用 $0 的各子命令(自动转交 systemctl), 或直接使用 systemctl"
}

uninstall_service() {
    [ "$(id -u)" -eq 0 ] || die "卸载系统服务需要 root 权限, 请执行: sudo $0 uninstall"
    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    info "系统服务 $SERVICE_NAME 已停止并卸载, 开机自启已关闭"
}

usage() {
    cat <<EOF
用法: $0 {start|stop|restart|status|log|install|uninstall}
  start     启动服务
  stop      停止服务
  restart   重启服务
  status    查看运行状态
  log       跟踪日志 (tail -f)
  install   安装 systemd 服务并开启开机自启 (需 sudo)
  uninstall 卸载 systemd 服务, 关闭开机自启 (需 sudo)

可选环境变量: JAR_FILE, PID_FILE, LOG_FILE, LOG_MAX_BYTES, JAVA_OPTS,
              ENV_FILE 及所有 MCP_GATEWAY_* 配置项
EOF
}

# ---------- 入口 ----------
case "${1:-}" in
    start)     start ;;
    stop)      stop ;;
    restart)   restart ;;
    status)    status ;;
    install)   install_service ;;
    uninstall) uninstall_service ;;
    log)
        [ -f "$LOG_FILE" ] || die "日志文件 $LOG_FILE 不存在"
        exec tail -n 200 -f "$LOG_FILE"
        ;;
    *)       usage; exit 1 ;;
esac
