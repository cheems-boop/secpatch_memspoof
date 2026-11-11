#!/system/bin/sh
# 卸载无需还原：属性只存在于内存，模块移除后重启即回到真值。
MODDIR=${0%/*}
PIDF="$MODDIR/log/watchd.pid"

# 优先用 pidfile 精确杀守护进程（ps 可能看不到/被限制）
if [ -f "$PIDF" ]; then
    p=$(cat "$PIDF" 2>/dev/null)
    if [ -n "$p" ] && [ -d "/proc/$p" ]; then
        grep -qa watchd "/proc/$p/cmdline" 2>/dev/null && kill "$p" 2>/dev/null
    fi
fi

# 兼底：用 lib 里的快速精确扫描（comm 预筛 + cmdline 精确匹配，不会误杀自己）
if [ -f "$MODDIR/bin/lib.sh" ]; then
    . "$MODDIR/bin/lib.sh" 2>/dev/null
    for q in $(watchd_pids 2>/dev/null); do
        kill "$q" 2>/dev/null
    done
    sleep 1
    # 再补一刀 -9，防止旧版 watchd 的 trap 不退出
    for q in $(watchd_pids 2>/dev/null); do
        kill -9 "$q" 2>/dev/null
    done
fi

# 用户层配置（放在模块目录外，升级不丢）
rm -f /data/adb/secpatch_memspoof.conf

rm -rf "$MODDIR/log"
exit 0
