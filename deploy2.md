# deploy2.sh 使用文档

`deploy2.sh` 是 MCP Gateway 服务的部署管理脚本（`deploy.sh` 的优化版），提供服务启停、状态查询、日志跟踪、启动预检、日志轮转等能力。

---

## 1. 前置条件

| 依赖 | 说明 |
|---|---|
| Linux 服务器 | 脚本为 bash 脚本，需在 Linux/WSL 环境运行 |
| Java 运行环境 | 服务器上需有 `java` 命令（JRE 8+ 或 JDK） |
| jar 包 | 默认查找脚本同目录下的 `mcp-gateway-1.0.0.jar` |

> 脚本会自动切换到自身所在目录执行，因此**在任意路径下调用均可**，jar、日志、pid 文件都固定在脚本所在目录。

---

## 2. 快速开始

```bash
# 1. 上传脚本与 jar 包到服务器同一目录（例如 /opt/mcp-gateway/）
chmod +x deploy2.sh

# 2.（推荐）创建敏感配置文件 deploy.env，不要提交到 git
#    注意：使用 KEY=value 格式（不带 export），bash 与 systemd 均可读取
cat > deploy.env <<'EOF'
MCP_GATEWAY_MASTER_KEY='your-master-key'
MCP_GATEWAY_ADMIN_PASSWORD='your-admin-password'
EOF
chmod 600 deploy.env

# 3. 启动服务
./deploy2.sh start

# 4. 查看状态 / 跟踪日志
./deploy2.sh status
./deploy2.sh log

# 5.（可选）设置开机自启，见第 7 节
sudo ./deploy2.sh install
```

不带参数执行 `./deploy2.sh` 会打印帮助信息。

---

## 3. 子命令

| 命令 | 作用 | 说明 |
|---|---|---|
| `./deploy2.sh start` | 启动服务 | 预检 → 轮转日志 → 后台启动 → 最多等 30 秒探测端口就绪 |
| `./deploy2.sh stop` | 停止服务 | 先优雅停止（`kill`），30 秒未退出则 `kill -9` 强制结束 |
| `./deploy2.sh restart` | 重启服务 | 依次执行 stop + start |
| `./deploy2.sh status` | 查看状态 | 运行中输出 PID 和端口；未运行时退出码为 1 |
| `./deploy2.sh log` | 跟踪日志 | 等价于 `tail -n 200 -f mcp-gateway.log`，`Ctrl+C` 退出 |
| `sudo ./deploy2.sh install` | 安装开机自启 | 生成并启用 systemd 服务、立即启动（详见第 7 节） |
| `sudo ./deploy2.sh uninstall` | 卸载开机自启 | 停止并移除 systemd 服务 |

**退出码约定**（便于脚本/CI 集成）：

- 成功：`0`
- 未运行（`status`）：`1`
- 预检失败/启动异常：`1`（输出带 `[时间戳] 错误:` 前缀）

---

## 4. 配置项

所有配置均支持**环境变量覆盖**，优先级：**环境变量 > deploy.env > 脚本默认值**。

### 4.1 脚本行为配置

| 变量 | 默认值 | 说明 |
|---|---|---|
| `JAR_FILE` | `mcp-gateway-1.0.0.jar` | jar 包路径（相对脚本目录或绝对路径） |
| `PID_FILE` | `mcp-gateway.pid` | PID 文件路径 |
| `LOG_FILE` | `mcp-gateway.log` | 日志文件路径 |
| `LOG_MAX_BYTES` | `10485760`（10MB） | 日志超过该大小时轮转为 `.log.1` |
| `JAVA_OPTS` | 空 | 额外 JVM 参数，如 `-Xms256m -Xmx512m` |
| `ENV_FILE` | `<脚本目录>/deploy.env` | 敏感配置文件路径 |

### 4.2 服务配置（MCP_GATEWAY_*）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `MCP_GATEWAY_BASE_URL` | `http://127.0.0.1:9998` | 网关基础地址 |
| `MCP_GATEWAY_BIND_ADDRESS` | `0.0.0.0` | 监听地址 |
| `MCP_GATEWAY_PORT` | `9998` | 监听端口 |
| `MCP_GATEWAY_ADMIN_USERNAME` | `admin` | 管理员用户名 |
| `MCP_GATEWAY_ADMIN_PASSWORD` | 空 | 管理员密码（**建议配置**，为空会输出警告） |
| `MCP_GATEWAY_MASTER_KEY` | 无 | 主密钥（**建议配置**，缺失会输出警告） |
| `MCP_GATEWAY_DOWNSTREAM_INSECURE_SKIP_TLS_VERIFY` | `true` | 跳过下游 TLS 证书校验 |

### 4.3 使用示例

```bash
# 临时换端口启动（无需改脚本）
MCP_GATEWAY_PORT=8888 ./deploy2.sh start

# 指定其他 jar 包并限制 JVM 内存
JAR_FILE=/opt/mcp-gateway/mcp-gateway-2.0.0.jar \
JAVA_OPTS="-Xms256m -Xmx512m" \
./deploy2.sh start

# 指定其他敏感配置文件
ENV_FILE=/etc/mcp-gateway/prod.env ./deploy2.sh restart
```

---

## 5. 敏感信息管理（重要）

脚本本身**不包含**任何密钥。`MCP_GATEWAY_MASTER_KEY` 和 `MCP_GATEWAY_ADMIN_PASSWORD` 从以下来源读取（按优先级）：

1. 启动时的环境变量
2. `deploy.env` 文件（与脚本同目录，或用 `ENV_FILE` 指定）

`deploy.env` 使用 `KEY=value` 格式（**不带 `export`**），含空格的值用引号包裹。该格式可同时被 deploy2.sh（bash source）和 systemd（EnvironmentFile）解析。

**安全建议：**

- `deploy.env` 权限设为 `600`，并且**加入 `.gitignore`，绝不允许提交到仓库**
- 如果密钥曾经出现在 git 历史中（如旧版 `deploy.sh`），视为已泄露，应尽快**轮换密钥**

---

## 6. 故障排查

| 现象/报错 | 原因与处理 |
|---|---|
| `错误: 未找到 java 命令` | 服务器未安装 JRE/JDK，或 java 不在 PATH 中 |
| `错误: 未找到 mcp-gateway-1.0.0.jar` | jar 包不在脚本目录；确认文件名或用 `JAR_FILE=` 指定路径 |
| `错误: 端口 9998 已被占用` | 已有进程监听该端口：先 `./deploy2.sh stop`；若是其他程序占用，换端口 `MCP_GATEWAY_PORT=xxx ./deploy2.sh start` |
| `错误: 进程启动后异常退出` | jar 启动即崩溃，用 `./deploy2.sh log` 或 `tail -100 mcp-gateway.log` 查看具体报错（常见：密钥未配置、配置格式错误） |
| `端口 30 秒内未监听` | 服务可能仍在初始化，稍后再查 `./deploy2.sh status` 和日志；持续未就绪则查日志定位 |
| `start` 提示"服务已在运行" | PID 文件记录的进程仍存活，属正常防重复启动；如状态异常可 `rm mcp-gateway.pid` 后重试 |

---

## 7. 开机自启（systemd 托管）

机器重启后自动拉起服务，基于 systemd 实现：

```bash
# 安装：生成 /etc/systemd/system/mcp-gateway.service，开启开机自启并立即启动
sudo ./deploy2.sh install

# 卸载：停止服务并移除开机自启
sudo ./deploy2.sh uninstall
```

**安装后会发生什么：**

- 服务由 systemd 直接以 `java -jar` 前台方式运行，**崩溃后自动重启**（间隔 5 秒，`Restart=on-failure`）
- `deploy2.sh start/stop/restart/status` 会自动检测并**转交给 systemctl**，两种方式混用不会冲突
- 日志仍追加写入同一份 `mcp-gateway.log`，`./deploy2.sh log` 照常可用
- `deploy.env` 在每次启动时由 systemd 重新读取，改密钥**无需重装**；但端口、jar 路径等非敏感配置在安装时固化，修改后需**重新执行 install**

**注意事项：**

- install/uninstall 需要 root 权限；要求 systemd ≥ 240（Ubuntu 20.04+ / Debian 11+ / CentOS 8+）
- systemd 模式下脚本的 `LOG_MAX_BYTES` 轮转不生效，长期运行建议为 `mcp-gateway.log` 配置 logrotate
- 无 systemd 的老系统可退而求其次，`crontab -e` 添加一行：
  `@reboot /path/to/deploy2.sh start`

---

## 8. 与 deploy.sh 的差异

| 项目 | deploy.sh | deploy2.sh |
|---|---|---|
| 密钥管理 | 硬编码在脚本中（已泄露风险） | 环境变量 / deploy.env 外置 |
| 生命周期管理 | 仅启动 | start / stop / restart / status / log |
| 重复启动防护 | 无 | PID 文件 + 端口检查 |
| 启动预检 | 无 | java、jar、端口三重检查 |
| 启动结果确认 | 无 | 进程存活 + 端口就绪探测 |
| 日志管理 | 单文件无限增长 | 按 10MB 自动轮转 |
| 执行位置 | 须在脚本目录 | 任意路径 |
| 开机自启 | 无 | systemd 一键安装（`install`），崩溃自动拉起 |
