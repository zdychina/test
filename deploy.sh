#!/bin/bash

# 配置环境变量
export MCP_GATEWAY_BASE_URL=http://ip:9998
export MCP_GATEWAY_MASTER_KEY=n6K26BWQ35pC9dIiQ0XtxyErv+M5aLjLagetPdlZmog=
export MCP_GATEWAY_BIND_ADDRESS=0.0.0.0
export MCP_GATEWAY_PORT=9998

export MCP_GATEWAY_ADMIN_USERNAME=admin
export MCP_GATEWAY_ADMIN_PASSWORD=
export MCP_GATEWAY_DOWNSTREAM_INSECURE_SKIP_TLS_VERIFY=true

# 后台启动服务并重定向日志
nohup java -jar mcp-gateway-1.0.0.jar > mcp-gateway.log 2>&1 &

echo "服务已在后台启动，日志记录在 mcp-gateway.log"
