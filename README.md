# MCP Gateway 部署脚本项目

本仓库提供 MCP Gateway 服务（Java）在 Linux 服务器上的部署与管理脚本，支持启停控制、状态查询、日志跟踪、日志轮转和 systemd 开机自启。

## 文件说明

| 文件 | 说明 |
|---|---|
| `mcp-gateway.sh` | **推荐使用**。服务管理脚本，详见 [mcp-gateway.md](mcp-gateway.md) |
| `mcp-gateway.md` | `mcp-gateway.sh` 完整使用文档 |
| `deploy.sh` | 旧版脚本，仅保留作参考，不建议继续使用 |
| `mcp-gateway-1.0.0.jar` | 服务 jar 包（不在仓库中，需自行放置到脚本同目录） |

## 快速开始

```bash
# 1. 将 mcp-gateway.sh 与 jar 包放到服务器同一目录（例如 /opt/mcp-gateway/）
chmod +x mcp-gateway.sh

# 2. 创建敏感配置文件 deploy.env（不要提交到 git）
#    格式为 KEY=value（不带 export），bash 与 systemd 均可读取
cat > deploy.env <<'EOF'
MCP_GATEWAY_MASTER_KEY='your-master-key'
MCP_GATEWAY_ADMIN_PASSWORD='your-admin-password'
EOF
chmod 600 deploy.env

# 3. 启动并查看状态
./mcp-gateway.sh start
./mcp-gateway.sh status

# 4.（可选）开启开机自启：机器重启后服务自动拉起，崩溃自动重启
sudo ./mcp-gateway.sh install
```

## 常用命令

```bash
./mcp-gateway.sh start     # 启动（含预检：java/jar/端口 + 端口就绪探测）
./mcp-gateway.sh stop      # 停止（优雅停止，30 秒超时后强制结束）
./mcp-gateway.sh restart   # 重启
./mcp-gateway.sh status    # 运行状态
./mcp-gateway.sh log       # 跟踪日志（tail -f）
```

安装 systemd 服务后，以上命令会自动转交 `systemctl`（见下一节）。

## 开机自启（systemd）

机器重启后服务自动拉起，基于 systemd 实现：

```bash
sudo ./mcp-gateway.sh install     # 安装：生成系统服务 + 开启开机自启 + 立即启动
sudo ./mcp-gateway.sh uninstall   # 卸载：停止服务并关闭开机自启
```

**安装后：**

- 生成单元文件 `/etc/systemd/system/mcp-gateway.service`，服务由 systemd 以 `java -jar` 前台方式运行
- **崩溃自动重启**：进程异常退出后 5 秒自动拉起（`Restart=on-failure`）
- `mcp-gateway.sh start/stop/restart/status` 自动检测并转交 `systemctl`，脚本与 systemctl 混用不冲突
- 日志仍追加写入 `mcp-gateway.log`，`./mcp-gateway.sh log` 照常可用

**配置变更规则：**

- `deploy.env`（密钥等敏感配置）由 systemd 每次启动时重新读取 → 修改后执行 `./mcp-gateway.sh restart` 即可生效
- 端口、jar 路径等非敏感配置在安装时写入单元文件固化 → 修改后需重新执行 `sudo ./mcp-gateway.sh install`

**注意事项：**

- install/uninstall 需要 root 权限；要求 systemd ≥ 240（Ubuntu 20.04+ / Debian 11+ / CentOS 8+）
- systemd 模式下脚本的 `LOG_MAX_BYTES` 日志轮转不生效，长期运行建议为 `mcp-gateway.log` 配置 logrotate
- 无 systemd 的老系统可用 crontab 替代：`crontab -e` 添加一行 `@reboot /path/to/mcp-gateway.sh start`

## 配置

所有配置支持环境变量覆盖，优先级：**环境变量 > `deploy.env` > 脚本默认值**。

常用项（完整列表见 [mcp-gateway.md](mcp-gateway.md) 第 4 节）：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `MCP_GATEWAY_PORT` | `9998` | 服务端口 |
| `JAR_FILE` | `mcp-gateway-1.0.0.jar` | jar 包路径 |
| `JAVA_OPTS` | 空 | 额外 JVM 参数，如 `-Xmx512m` |
| `MCP_GATEWAY_MASTER_KEY` | 无 | 主密钥（建议在 `deploy.env` 中配置） |
| `MCP_GATEWAY_ADMIN_PASSWORD` | 空 | 管理员密码（建议配置） |

示例：

```bash
# 临时换端口启动
MCP_GATEWAY_PORT=8888 ./mcp-gateway.sh start

# 指定 jar 包并限制内存
JAR_FILE=/opt/mcp-gateway/mcp-gateway-2.0.0.jar JAVA_OPTS="-Xmx512m" ./mcp-gateway.sh start
```

## 安全须知

- 🔴 **`deploy.sh` 历史版本中硬编码的 Master Key 已随仓库公开，视为已泄露，请立即轮换**，并改用 `deploy.env` 管理密钥。
- `deploy.env` 应设置权限 `600`，并加入 `.gitignore`，**绝不提交到仓库**。
- 生产环境建议关闭 `MCP_GATEWAY_DOWNSTREAM_INSECURE_SKIP_TLS_VERIFY`（默认为 `true`，跳过下游 TLS 校验，仅适合测试）。

## mcp-gateway.sh 与旧版 deploy.sh 的主要差异

| 项目 | deploy.sh | mcp-gateway.sh |
|---|---|---|
| 密钥管理 | 硬编码在脚本中 | `deploy.env` / 环境变量外置 |
| 生命周期管理 | 仅启动 | start / stop / restart / status / log |
| 重复启动防护 | 无 | PID 文件 + 端口检查 |
| 启动预检与结果确认 | 无 | java/jar/端口预检 + 端口就绪探测 |
| 日志管理 | 单文件无限增长 | 按 10MB 自动轮转 |
| 开机自启 | 无 | systemd 一键安装（`install`），崩溃自动拉起 |

## 环境要求

- Linux（bash）、JRE/JDK 8+
- 开机自启功能需要 systemd ≥ 240（Ubuntu 20.04+ / Debian 11+ / CentOS 8+）

更多细节（子命令、配置项、故障排查）见 **[mcp-gateway.md](mcp-gateway.md)**。
