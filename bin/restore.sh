#!/system/bin/sh
# 把属性写回真值。优先用首次运行时的 baseline 快照，没快照才现场解析分区
set -u
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin:$PATH
MODDIR=$(cd "${0%/*}/.." && pwd)
. "$MODDIR/bin/lib.sh"

# --persist：同时把 prop.conf 里的值改成 ref:disk。
# 不加的话只改内存，下一次 apply（守护每小时 / 改配置 / 重启）会把伪装又写回来。
persist=0
case "${1:-}" in -p|--persist) persist=1 ;; esac

for k in $(conf_keys | sort -u); do
    protected "$k" && continue
    v=$(kv "$BASE" "$k")
    [ -z "$v" ] && v=$(disk_val "$k")
    if [ -z "$v" ]; then
        log RESTORE "$k 找不到真值，跳过"
        continue
    fi
    rp_set "$k" "$v" >/dev/null 2>&1
    log RESTORE "$k=$v (readback=$(getprop "$k" 2>/dev/null))"
    if [ "$persist" = 1 ]; then
        sh "$MODDIR/bin/setconf.sh" "$k" ref:disk >/dev/null 2>&1 \
            && log RESTORE "配置已改为 ref:disk：$k"
    fi
done
exit 0
