#!/system/bin/sh
# 输出机器可读状态（给 WebUI 用）：每行 key=value，无空格、无颜色
set -u
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin:$PATH
MODDIR=$(cd "${0%/*}/.." && pwd)
. "$MODDIR/bin/lib.sh"

echo "refresh=$(cfg refresh)"
echo "guard=$(cfg guard)"
echo "guard_action=$(cfg guard_action)"
echo "max_ahead=$(cfg max_ahead)"
echo "pif=$(pif_val)"
echo "rp=$RP"
echo "watchd=$(watchd_alive && echo on || echo off)"

for k in $(conf_keys | sort -u); do
    echo "cfg.$k=$(cfg "$k")"
    echo "now.$k=$(getprop "$k" 2>/dev/null)"
    real=$(kv "$BASE" "$k")
    [ -z "$real" ] && real=$(disk_val "$k")
    echo "real.$k=$real"
done

bootid=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
snap_boot=$(grep -m1 '^#boot_id=' "$SNAP" 2>/dev/null | cut -d= -f2)
if [ -n "$snap_boot" ] && [ "$snap_boot" = "$bootid" ]; then echo "snap=ok"; else echo "snap=missing"; fi
