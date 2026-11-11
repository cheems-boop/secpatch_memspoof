#!/system/bin/sh
# 记录「zygote 启动那一刻能看到的值」：post-fs-data 阶段应用后立即调用。
# 这个快照就是 Build.VERSION.* 会缓存的版本，
# 之后凡是被改写（guard / 手动 apply）都会导致 native 与 Java 层不一致 —— 那是最大的检测点。
set -u
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin:$PATH
MODDIR=$(cd "${0%/*}/.." && pwd)
. "$MODDIR/bin/lib.sh"

tmp="$SNAP.tmp.$$"   # 带 $$：与 refresh / post-fs-data 并发时不会互踩
{
    echo "#boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
    echo "#time=$(date '+%F %T')"
    for k in $(conf_keys | sort -u); do
        protected "$k" && continue
        echo "$k=$(getprop "$k" 2>/dev/null)"
    done
} > "$tmp"
mv -f "$tmp" "$SNAP" 2>/dev/null
chmod 600 "$SNAP" 2>/dev/null
log SNAP "已记录 zygote 快照（$(grep -c '^ro\.' "$SNAP" 2>/dev/null | tr -d ' ') 项）"
