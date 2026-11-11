#!/system/bin/sh
# 开机完成后再校正一次（防止别家 post-fs-data 覆盖），然后拉起配置监听 + 漂移守护
MODDIR=${0%/*}
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin:$PATH
mkdir -p "$MODDIR/log"
# 自愈：从 zip 安装时可能丢掉可执行位，而本模块多处是直接执行脚本
chmod 755 "$MODDIR"/*.sh "$MODDIR"/bin/* 2>/dev/null
chmod 700 "$MODDIR/log" 2>/dev/null
chmod 600 "$MODDIR/log"/*.log 2>/dev/null

i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 60 ]; do sleep 1; i=$((i+1)); done

"$MODDIR/bin/apply.sh" service >/dev/null 2>&1

. "$MODDIR/bin/lib.sh"

# 环境不支持时不要起守护：否则它会每 30 秒报一次漂移、而重写永远失败
if [ -z "$RP" ]; then
    log service "找不到 resetprop（需要 KernelSU / ksud）→ 不启动守护"
    exit 0
fi

start_daemon "$MODDIR/bin/watchd.sh"

# 自检：起完 3 秒看一眼，没起来就记一笔（否则用户永远不知道守护没跑）
sleep 3
if watchd_alive; then
    log service "守护进程已启动 pid=$(cat "$WATCHD_PID" 2>/dev/null)"
else
    log service "守护进程启动失败（持续报错请看 log/apply.log）"
fi
exit 0
