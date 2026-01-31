#!/system/bin/sh

# ================= 全局配置 =================
WORK_DIR="/data/local/tmp"
CONFIG_FILE="$WORK_DIR/proxy.conf"
PROCESS_NAME="ceshi_proxy"
V2RAY_BIN="$WORK_DIR/v2ray"
LOCAL_PORT=10809

# [新增] 远程公告地址 (请修改为你自己的 Raw 文本链接)
# 示例链接是一个 Hello World，你可以替换成你的 Gist 或 GitHub Raw 地址
NOTICE_URL="https://raw.githubusercontent.com/microsoft/vscode/main/LICENSE.txt" 
# 注意：上面的链接只是为了测试(它是VSCode的协议)，建议你替换成类似 "https://pastebin.com/raw/xxxxx" 这种纯文本

# 颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ================= 1. 配置管理模块 =================

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

save_config() {
    echo "SOCKS_IP='$SOCKS_IP'" > "$CONFIG_FILE"
    echo "SOCKS_PORT='$SOCKS_PORT'" >> "$CONFIG_FILE"
    echo "SOCKS_USER='$SOCKS_USER'" >> "$CONFIG_FILE"
    echo "SOCKS_PASS='$SOCKS_PASS'" >> "$CONFIG_FILE"
    echo "PROXY_MODE='$PROXY_MODE'" >> "$CONFIG_FILE"
    echo "APP_LIST='$APP_LIST'" >> "$CONFIG_FILE"
}

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

# ================= 2. 核心功能模块 =================

get_app_uid() {
    grep "^$1 " /data/system/packages.list | awk '{print $2}'
}

flush_rules() {
    iptables -t nat -D OUTPUT -j CESHI_PROXY >/dev/null 2>&1
    iptables -t nat -F CESHI_PROXY >/dev/null 2>&1
    iptables -t nat -X CESHI_PROXY >/dev/null 2>&1
}

apply_rules() {
    load_config
    iptables -t nat -N CESHI_PROXY
    
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

do_stop() {
    flush_rules
    pkill -f "$PROCESS_NAME"
    pkill -f "$V2RAY_BIN"
    rm "$WORK_DIR/config.json" 2>/dev/null
    rm "$WORK_DIR/$PROCESS_NAME" 2>/dev/null
}

daemon_entry() {
    load_config
    generate_v2ray_json
    nohup "$V2RAY_BIN" run -c "$WORK_DIR/config.json" >/dev/null 2>&1 &
    V2RAY_PID=$!
    flush_rules
    apply_rules
    while true; do
        if ! kill -0 $V2RAY_PID 2>/dev/null; then
            nohup "$V2RAY_BIN" run -c "$WORK_DIR/config.json" >/dev/null 2>&1 &
            V2RAY_PID=$!
        fi
        sleep 30
    done
}

do_start() {
    if [ ! -f "$V2RAY_BIN" ]; then
        echo "错误: 未找到 $V2RAY_BIN"
        read -r temp
        return
    fi
    do_stop
    cp /system/bin/sh "$WORK_DIR/$PROCESS_NAME"
    chmod 755 "$WORK_DIR/$PROCESS_NAME"
    cat "$0" > "$WORK_DIR/proxy_script_run.sh"
    nohup "$WORK_DIR/$PROCESS_NAME" "$WORK_DIR/proxy_script_run.sh" daemon_mode >/dev/null 2>&1 &
    echo "${GREEN}服务已启动!${NC}"
    sleep 1
}

# ================= 3. [新增] 远程公告模块 =================

fetch_announcement() {
    echo -e "${CYAN}正在获取远程公告...${NC}"
    
    # 临时存放文件
    TMP_NOTICE="$WORK_DIR/notice.tmp"
    rm "$TMP_NOTICE" 2>/dev/null
    
    # 尝试使用 curl (设置3秒超时)
    if command -v curl >/dev/null 2>&1; then
        curl -s --connect-timeout 3 "$NOTICE_URL" > "$TMP_NOTICE"
    # 尝试使用 wget (设置3秒超时)
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 3 -O "$TMP_NOTICE" "$NOTICE_URL"
    fi
    
    # 检查是否获取成功
    if [ -s "$TMP_NOTICE" ]; then
        echo -e "${YELLOW}================= [ 公 告 ] =================${NC}"
        # 限制显示行数，防止公告太长刷屏 (这里限制显示前10行)
        head -n 10 "$TMP_NOTICE"
        echo -e "${YELLOW}=============================================${NC}"
        rm "$TMP_NOTICE"
        
        echo "按回车键进入菜单..."
        read temp
    else
        # 如果获取失败（没网或者超时），不打扰用户，直接跳过或显示一行
        echo -e "${RED}[!] 无法获取公告 (网络超时或无网络)${NC}"
        sleep 0.5
    fi
}

# ================= 4. 交互界面模块 =================

input_config() {
    # ... (保持不变，省略以节省空间) ...
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
    echo -e "${GREEN}配置已保存。${NC}"
    read temp
}

show_status() {
    pid=$(pgrep -f "$PROCESS_NAME")
    if [ -n "$pid" ]; then
        echo -e "状态: ${GREEN}运行中${NC} (PID: $pid)"
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
        echo "3. 修改配置"
        echo "4. 查看配置"
        echo "0. 退出"
        echo "----------------------------"
        printf "请选择: "
        read choice
        case $choice in
            1) do_start ;;
            2) do_stop; sleep 1 ;;
            3) input_config ;;
            4) 
                echo -e "\nServer: $SOCKS_IP:$SOCKS_PORT\nAPP: $APP_LIST"
                read temp 
                ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

# ================= 入口判断 =================

if [ "$1" = "daemon_mode" ]; then
    daemon_entry
else
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 Root 权限运行此脚本 (su)"
        exit 1
    fi
    
    # [新增] 启动前先获取并显示公告
    fetch_announcement
    
    menu_loop
fi
