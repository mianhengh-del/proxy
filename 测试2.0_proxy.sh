#!/system/bin/sh

# ================= 用户配置区域 =================

# --- 远程 SOCKS5 服务器信息 ---
SOCKS_IP="1.2.3.4"          # 你的 SOCKS 服务器 IP
SOCKS_PORT=1080             # SOCKS 服务器端口
SOCKS_USER="myusername"     # SOCKS 账号 (留空则无密码)
SOCKS_PASS="mypassword"     # SOCKS 密码

# --- 模式设置 ---
# 模式: "whitelist" (只代理名单内的APP) 或 "blacklist" (代理除名单外所有的APP)
PROXY_MODE="whitelist"

# APP 名单 (填写包名，用空格隔开)
APP_LIST="com.android.chrome com.google.android.youtube"

# --- 内部配置 (通常无需修改) ---
WORK_DIR="/data/local/tmp"
PROCESS_NAME="ceshi_proxy"
V2RAY_BIN="$WORK_DIR/v2ray" # v2ray 二进制文件路径
LOCAL_PORT=10809            # 本地中转端口

# ===========================================

# 检查 Root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 此脚本需要 Root 权限运行。"
    exit 1
fi

# 检查 V2Ray 文件是否存在
if [ ! -f "$V2RAY_BIN" ]; then
    echo "错误: 未找到 V2Ray 核心文件: $V2RAY_BIN"
    echo "请先上传 v2ray 二进制文件并 chmod +x"
    exit 1
fi

# 1. 生成 V2Ray 配置文件 (JSON)
generate_config() {
    cat <<EOF > "$WORK_DIR/config.json"
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $LOCAL_PORT,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "$SOCKS_IP",
            "port": $SOCKS_PORT,
            "users": [
              { "user": "$SOCKS_USER", "pass": "$SOCKS_PASS" }
            ]
          }
        ]
      }
    }
  ]
}
EOF
}

# 2. 进程伪装与守护逻辑
setup_process_name() {
    current_proc=$(basename "$0")
    
    if [ "$current_proc" != "$PROCESS_NAME" ]; then
        echo "[*] 正在创建后台进程: $PROCESS_NAME ..."
        
        # 复制系统 shell 为 ceshi_proxy
        cp /system/bin/sh "$WORK_DIR/$PROCESS_NAME"
        chmod 755 "$WORK_DIR/$PROCESS_NAME"
        
        # 复制脚本内容
        cat "$0" > "$WORK_DIR/${PROCESS_NAME}_script.sh"
        
        # 启动伪装后的脚本
        nohup "$WORK_DIR/$PROCESS_NAME" "$WORK_DIR/${PROCESS_NAME}_script.sh" "daemon" >/dev/null 2>&1 &
        
        echo "[+] 脚本已在后台运行，进程名: $PROCESS_NAME"
        exit 0
    fi
}

# 获取 APP UID
get_app_uid() {
    grep "^$1 " /data/system/packages.list | awk '{print $2}'
}

# 清理规则
flush_rules() {
    iptables -t nat -D OUTPUT -j CESHI_PROXY >/dev/null 2>&1
    iptables -t nat -F CESHI_PROXY >/dev/null 2>&1
    iptables -t nat -X CESHI_PROXY >/dev/null 2>&1
}

# 应用 iptables 规则
apply_rules() {
    echo "[*] 正在应用 iptables 规则 ($PROXY_MODE)..."
    iptables -t nat -N CESHI_PROXY

    # 放行私有地址和组播
    iptables -t nat -A CESHI_PROXY -d 0.0.0.0/8 -j RETURN
    iptables -t nat -A CESHI_PROXY -d 10.0.0.0/8 -j RETURN
    iptables -t nat -A CESHI_PROXY -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A CESHI_PROXY -d 169.254.0.0/16 -j RETURN
    iptables -t nat -A CESHI_PROXY -d 172.16.0.0/12 -j RETURN
    iptables -t nat -A CESHI_PROXY -d 192.168.0.0/16 -j RETURN
    
    # 放行远程 SOCKS 服务器 IP (防止死循环)
    iptables -t nat -A CESHI_PROXY -d "$SOCKS_IP" -j RETURN

    for pkg in $APP_LIST; do
        uid=$(get_app_uid "$pkg")
        if [ -n "$uid" ]; then
            if [ "$PROXY_MODE" = "whitelist" ]; then
                echo "    - 代理 APP: $pkg ($uid)"
                iptables -t nat -A CESHI_PROXY -m owner --uid-owner "$uid" -p tcp -j REDIRECT --to-ports "$LOCAL_PORT"
            elif [ "$PROXY_MODE" = "blacklist" ]; then
                echo "    - 直连 APP: $pkg ($uid)"
                iptables -t nat -A CESHI_PROXY -m owner --uid-owner "$uid" -j RETURN
            fi
        fi
    done

    if [ "$PROXY_MODE" = "blacklist" ]; then
        # 黑名单模式：排除掉上面的，其余全部转发
        # 注意：排除 v2ray 自身防止回环 (重要)
        # 这里很难精确获取 v2ray 的 uid，通常建议 v2ray 用特定用户运行，
        # 但为简化脚本，我们假设 v2ray 由 root 运行，而 APP 是普通用户。
        iptables -t nat -A CESHI_PROXY -p tcp -j REDIRECT --to-ports "$LOCAL_PORT"
    fi

    iptables -t nat -A OUTPUT -p tcp -j CESHI_PROXY
}

# 守护进程主逻辑
daemon_loop() {
    # 1. 生成配置
    generate_config
    
    # 2. 启动 V2Ray (后台运行)
    # 必须确保 V2Ray 不会阻塞脚本
    echo "[*] 启动 V2Ray 核心..."
    nohup "$V2RAY_BIN" run -c "$WORK_DIR/config.json" >/dev/null 2>&1 &
    V2RAY_PID=$!
    
    # 3. 设置防火墙
    flush_rules
    apply_rules
    
    echo "[*] ceshi_proxy 服务已完全启动 (V2Ray PID: $V2RAY_PID)"
    
    # 4. 监控循环
    while true; do
        # 检查 V2Ray 进程是否存活
        if ! kill -0 $V2RAY_PID 2>/dev/null; then
            echo "[!] V2Ray 意外退出，正在重启..."
            nohup "$V2RAY_BIN" run -c "$WORK_DIR/config.json" >/dev/null 2>&1 &
            V2RAY_PID=$!
        fi
        sleep 60
    done
}

# 停止逻辑
stop_proxy() {
    flush_rules
    # 杀掉 ceshi_proxy 脚本进程
    pkill -f "$PROCESS_NAME"
    # 杀掉 v2ray 进程
    pkill -f "$V2RAY_BIN"
    
    echo "[*] 服务已停止，进程与规则已清理"
    
    # 清理临时文件
    rm "$WORK_DIR/$PROCESS_NAME" 2>/dev/null
    rm "$WORK_DIR/${PROCESS_NAME}_script.sh" 2>/dev/null
    rm "$WORK_DIR/config.json" 2>/dev/null
}

case "$1" in
    start)
        setup_process_name
        ;;
    daemon)
        daemon_loop
        ;;
    stop)
        stop_proxy
        ;;
    *)
        echo "用法: $0 {start|stop}"
        ;;
esac