#!/system/bin/sh

# ================= 全局配置 =================
WORK_DIR="/data/local/tmp"
CONFIG_FILE="$WORK_DIR/proxy.conf"
PROCESS_NAME="ceshi_proxy"
V2RAY_BIN="$WORK_DIR/v2ray"
LOCAL_PORT=10809

# 颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ================= 1. 配置管理模块 =================

# 加载配置
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
    else
        # 默认值
        SOCKS_IP="127.0.0.1"
        SOCKS_PORT="1080"
        SOCKS_USER=""
        SOCKS_PASS=""
        PROXY_MODE="whitelist"
        APP_LIST="com.android.chrome"
    fi
}

# 保存配置
save_config() {
    echo "SOCKS_IP='$SOCKS_IP'" > "$CONFIG_FILE"
    echo "SOCKS_PORT='$SOCKS_PORT'" >> "$CONFIG_FILE"
    echo "SOCKS_USER='$SOCKS_USER'" >> "$CONFIG_FILE"
    echo "SOCKS_PASS='$SOCKS_PASS'" >> "$CONFIG_FILE"
    echo "PROXY_MODE='$PROXY_MODE'" >> "$CONFIG_FILE"
    echo "APP_LIST='$APP_LIST'" >> "$CONFIG_FILE"
}

# 生成 V2Ray JSON
generate_v2ray_json() {
    cat <<EOF > "$WORK_DIR/config.json"
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $LOCAL_PORT,
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "followRedirect": true },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    }
  ],
  "outbounds": [
    {
      "protocol": "socks",
      "settings": {
        "servers": [{
            "address": "$SOCKS_IP",
            "port": $SOCKS_PORT,
            "users": [{ "user": "$SOCKS_USER", "pass": "$SOCKS_PASS" }]
        }]
      }
    }
  ]
}
EOF
}

# ================= 2. 核心功能模块 (iptables & 进程) =================

get_app_uid() {
    grep "^$1 " /data/system/packages.list | awk '{print $2}'
}

# 清理环境
flush_rules() {
    iptables -t nat -D OUTPUT -j CESHI_PROXY >/dev/null 2>&1
    iptables -t nat -F CESHI_PROXY >/dev/null 2>&1
    iptables -t nat -X CESHI_PROXY >/dev/null 2>&1
}

# 应用规则
apply_rules() {
    load_config
    iptables -t nat -N CESHI_PROXY
    
    # 基础放行
    iptables -t nat -A CESHI_PROXY -d 0.0.0.0/8 -j RETURN
    iptables -t nat -A CESHI_PROXY -d 10.0.0.0/8 -j RETURN
    iptables -t nat -A CESHI_PROXY -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A CESHI_PROXY -d 172.16.0.0/12 -j RETURN
    iptables -t nat -A CESHI_PROXY -d 192.168.0.0/16 -j RETURN
    iptables -t nat -A CESHI_PROXY -d "$SOCKS_IP" -j RETURN

    for pkg in $APP_LIST; do
        uid=$(get_app_uid "$pkg")
        if [ -n "$uid" ]; then
            if [ "$PROXY_MODE" = "whitelist" ]; then
                iptables -t nat -A CESHI_PROXY -m owner --uid-owner "$uid" -p tcp -j REDIRECT --to-ports "$LOCAL_PORT"
            elif [ "$PROXY_MODE" = "blacklist" ]; then
                iptables -t nat -A CESHI_PROXY -m owner --uid-owner "$uid" -j RETURN
            fi
        fi
    done

    if [ "$PROXY_MODE" = "blacklist" ]; then
        iptables -t nat -A CESHI_PROXY -p tcp -j REDIRECT --to-ports "$LOCAL_PORT"
    fi

    iptables -t nat -A OUTPUT -p tcp -j CESHI_PROXY
}

# 停止服务
do_stop() {
    flush_rules
    pkill -f "$PROCESS_NAME"
    pkill -f "$V2RAY_BIN"
    rm "$WORK_DIR/config.json" 2>/dev/null
    rm "$WORK_DIR/$PROCESS_NAME" 2>/dev/null
}

# 守护进程逻辑 (被后台调用)
daemon_entry() {
    # 1. 生成配置
    load_config
    generate_v2ray_json
    
    # 2. 启动 V2Ray
    nohup "$V2RAY_BIN" run -c "$WORK_DIR/config.json" >/dev/null 2>&1 &
    V2RAY_PID=$!
    
    # 3. 应用规则
    flush_rules
    apply_rules
    
    # 4. 循环保活
    while true; do
        if ! kill -0 $V2RAY_PID 2>/dev/null; then
            nohup "$V2RAY_BIN" run -c "$WORK_DIR/config.json" >/dev/null 2>&1 &
            V2RAY_PID=$!
        fi
        sleep 30
    done
}

# 启动服务 (前端调用)
do_start() {
    if [ ! -f "$V2RAY_BIN" ]; then
        echo "错误: 未找到 $V2RAY_BIN"
        read -r temp
        return
    fi
    
    do_stop # 先清理
    
    # 伪装进程并启动
    cp /system/bin/sh "$WORK_DIR/$PROCESS_NAME"
    chmod 755 "$WORK_DIR/$PROCESS_NAME"
    
    # 关键：将当前脚本内容传递给伪装的进程执行
    # 这里我们把脚本自身复制一份，防止修改导致的问题
    cat "$0" > "$WORK_DIR/proxy_script_run.sh"
    
    nohup "$WORK_DIR/$PROCESS_NAME" "$WORK_DIR/proxy_script_run.sh" daemon_mode >/dev/null 2>&1 &
    
    echo "${GREEN}服务已启动!${NC}"
    sleep 1
}

# ================= 3. 交互界面模块 (TUI) =================

input_config() {
    echo -e "\n${CYAN}=== 修改配置 ===${NC}"
    
    printf "输入 SOCKS 服务器 IP [当前: $SOCKS_IP]: "
    read input
    [ -n "$input" ] && SOCKS_IP="$input"
    
    printf "输入 SOCKS 端口 [当前: $SOCKS_PORT]: "
    read input
    [ -n "$input" ] && SOCKS_PORT="$input"
    
    printf "输入 SOCKS 账号 [当前: $SOCKS_USER]: "
    read input
    [ -n "$input" ] && SOCKS_USER="$input"
    
    printf "输入 SOCKS 密码 [当前: $SOCKS_PASS]: "
    read input
    [ -n "$input" ] && SOCKS_PASS="$input"
    
    printf "代理模式 (whitelist/blacklist) [当前: $PROXY_MODE]: "
    read input
    [ -n "$input" ] && PROXY_MODE="$input"
    
    printf "APP 包名列表 (空格分隔) [当前: $APP_LIST]: "
    read input
    [ -n "$input" ] && APP_LIST="$input"
    
    save_config
    echo -e "${GREEN}配置已保存，请重启服务生效。${NC}"
    echo "按回车键返回..."
    read temp
}

show_status() {
    pid=$(pgrep -f "$PROCESS_NAME")
    if [ -n "$pid" ]; then
        echo -e "状态: ${GREEN}运行中${NC} (PID: $pid)"
        # 检查端口
        if netstat -tunl | grep -q ":$LOCAL_PORT"; then
             echo -e "端口: ${GREEN}正常 ($LOCAL_PORT)${NC}"
        else
             echo -e "端口: ${RED}异常 (V2Ray未监听)${NC}"
        fi
    else
        echo -e "状态: ${RED}未运行${NC}"
    fi
    echo "----------------------------"
}

menu_loop() {
    while true; do
        clear
        echo -e "${YELLOW}=== 安卓 Shell 代理管理器 ===${NC}"
        load_config
        show_status
        
        echo "1. 启动代理 (Start)"
        echo "2. 停止代理 (Stop)"
        echo "3. 修改配置 (账号/密码/APP)"
        echo "4. 查看当前配置"
        echo "0. 退出脚本"
        echo "----------------------------"
        printf "请选择 [0-4]: "
        read choice
        
        case $choice in
            1)
                echo "正在启动..."
                do_start
                ;;
            2)
                echo "正在停止..."
                do_stop
                sleep 1
                ;;
            3)
                input_config
                ;;
            4)
                echo ""
                echo "服务器: $SOCKS_IP : $SOCKS_PORT"
                echo "用户: $SOCKS_USER"
                echo "模式: $PROXY_MODE"
                echo "APP: $APP_LIST"
                echo ""
                echo "按回车键返回..."
                read temp
                ;;
            0)
                exit 0
                ;;
            *)
                echo "无效选项"
                sleep 1
                ;;
        esac
    done
}

# ================= 入口判断 =================

# 如果第一个参数是 daemon_mode，则进入后台守护模式
if [ "$1" = "daemon_mode" ]; then
    daemon_entry
else
    # 否则显示菜单
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 Root 权限运行此脚本 (su)"
        exit 1
    fi
    menu_loop
fi
