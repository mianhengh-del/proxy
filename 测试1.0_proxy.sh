#!/system/bin/sh

# ================= 配置区域 =================

# 代理核心监听的端口 (假设你的代理核心已经运行)
PROXY_PORT=10809
PROXY_IP="127.0.0.1"

# 模式选择: "whitelist" (只代理名单内的APP) 或 "blacklist" (代理除名单外所有的APP)
PROXY_MODE="whitelist"

# APP 名单 (填写包名，用空格隔开)
# 示例: 谷歌(com.android.chrome) 微信(com.tencent.mm)
APP_LIST="com.android.chrome com.google.android.youtube"

# 脚本运行目录 (临时存放伪装的二进制文件)
WORK_DIR="/data/local/tmp"
PROCESS_NAME="ceshi_proxy"

# ===========================================

# 检查 Root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 此脚本需要 Root 权限运行。"
    exit 1
fi

# 1. 进程伪装逻辑 (满足创建名为 ceshi_proxy 的进程)
setup_process_name() {
    # 如果当前运行的程序名不是 ceshi_proxy，则进行伪装
    current_proc=$(basename "$0")
    
    if [ "$current_proc" != "$PROCESS_NAME" ]; then
        echo "[*] 正在创建后台进程: $PROCESS_NAME ..."
        
        # 复制系统 shell 为 ceshi_proxy
        cp /system/bin/sh "$WORK_DIR/$PROCESS_NAME"
        chmod 755 "$WORK_DIR/$PROCESS_NAME"
        
        # 复制脚本内容到临时文件，供新进程执行
        cat "$0" > "$WORK_DIR/${PROCESS_NAME}_script.sh"
        
        # 使用伪装的 shell 执行脚本，并传入参数
        # nohup 保证后台运行
        nohup "$WORK_DIR/$PROCESS_NAME" "$WORK_DIR/${PROCESS_NAME}_script.sh" "daemon" >/dev/null 2>&1 &
        
        echo "[+] 脚本已在后台运行，进程名: $PROCESS_NAME"
        exit 0
    fi
}

# 获取 APP 的 UID (通过 packages.list 读取，比 dumpsys 快且轻量)
get_app_uid() {
    pkg_name=$1
    # packages.list 格式: pkgName uid ...
    uid=$(grep "^${pkg_name} " /data/system/packages.list | awk '{print $2}')
    if [ -n "$uid" ]; then
        echo "$uid"
    fi
}

# 清理旧的 iptables 规则
flush_rules() {
    iptables -t nat -D OUTPUT -j CESHI_PROXY >/dev/null 2>&1
    iptables -t nat -F CESHI_PROXY >/dev/null 2>&1
    iptables -t nat -X CESHI_PROXY >/dev/null 2>&1
    echo "[*] 旧规则已清理"
}

# 应用 iptables 规则
apply_rules() {
    echo "[*] 正在应用 $PROXY_MODE 模式规则..."
    
    # 新建链
    iptables -t nat -N CESHI_PROXY

    # 忽略本地回环和局域网
    iptables -t nat -A CESHI_PROXY -d 0.0.0.0/8 -j RETURN
    iptables -t nat -A CESHI_PROXY -d 10.0.0.0/8 -j RETURN
    iptables -t nat -A CESHI_PROXY -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A CESHI_PROXY -d 169.254.0.0/16 -j RETURN
    iptables -t nat -A CESHI_PROXY -d 172.16.0.0/12 -j RETURN
    iptables -t nat -A CESHI_PROXY -d 192.168.0.0/16 -j RETURN
    iptables -t nat -A CESHI_PROXY -d 224.0.0.0/4 -j RETURN
    iptables -t nat -A CESHI_PROXY -d 240.0.0.0/4 -j RETURN

    # 遍历 APP 名单获取 UID
    for pkg in $APP_LIST; do
        uid=$(get_app_uid "$pkg")
        if [ -n "$uid" ]; then
            if [ "$PROXY_MODE" = "whitelist" ]; then
                # 白名单模式：匹配到的 UID 转发到代理端口
                echo "    - 代理 APP: $pkg (UID: $uid)"
                iptables -t nat -A CESHI_PROXY -m owner --uid-owner "$uid" -p tcp -j REDIRECT --to-ports "$PROXY_PORT"
            elif [ "$PROXY_MODE" = "blacklist" ]; then
                # 黑名单模式：匹配到的 UID 直连 (RETURN)，其他的在后面统一转发
                echo "    - 直连 APP: $pkg (UID: $uid)"
                iptables -t nat -A CESHI_PROXY -m owner --uid-owner "$uid" -j RETURN
            fi
        else
            echo "    ! 未找到应用: $pkg"
        fi
    done

    # 模式收尾逻辑
    if [ "$PROXY_MODE" = "whitelist" ]; then
        # 白名单：除了上面指定的，其他都 RETURN (直连) - 其实不需要写，默认就是继续
        : 
    elif [ "$PROXY_MODE" = "blacklist" ]; then
        # 黑名单：除了上面 RETURN 的，其余所有流量都转发
        iptables -t nat -A CESHI_PROXY -p tcp -j REDIRECT --to-ports "$PROXY_PORT"
    fi

    # 将 OUTPUT 链流量导入自定义链
    iptables -t nat -A OUTPUT -p tcp -j CESHI_PROXY
    echo "[+] 代理规则生效中"
}

# 守护进程主循环
daemon_loop() {
    flush_rules
    apply_rules
    
    echo "[*] ceshi_proxy 守护进程运行中..."
    
    # 这是一个死循环，保持脚本在后台不退出，并监控状态
    while true; do
        # 每 60 秒检查一次核心代理端口是否存在
        if ! netstat -tunl | grep -q ":$PROXY_PORT"; then
            echo "[!] 警告: 代理核心端口 $PROXY_PORT 似乎未运行!"
        fi
        sleep 60
    done
}

# 停止逻辑
stop_proxy() {
    flush_rules
    # 杀掉名为 ceshi_proxy 的进程
    pkill -f "$PROCESS_NAME"
    echo "[*] 代理已关闭，进程已清理"
    rm "$WORK_DIR/$PROCESS_NAME" 2>/dev/null
    rm "$WORK_DIR/${PROCESS_NAME}_script.sh" 2>/dev/null
}

# ================= 入口逻辑 =================

case "$1" in
    start)
        setup_process_name # 这会派生出名为 ceshi_proxy 的后台进程
        ;;
    daemon)
        # 这是被后台进程调用的入口，不要手动运行这个
        daemon_loop
        ;;
    stop)
        stop_proxy
        ;;
    *)
        echo "用法: $0 {start|stop}"
        echo "  start: 启动代理并创建后台进程"
        echo "  stop : 清理规则并停止进程"
        ;;
esac