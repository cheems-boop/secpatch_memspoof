#!/system/bin/sh
# 让「设置」等所有 App 重新从属性读取补丁日期：重启 zygote（init 会自动拉起）。
# 属性已经改好了，但 Build.VERSION.SECURITY_PATCH 是 zygote 启动时的快照，
# 不重启 zygote 的话设置页永远不会变。
# 代价：所有 App 被立刻杀死并重启（2~3 秒），不会丢数据，但会中断当前操作。
set -u
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin:$PATH
MODDIR=$(cd "${0%/*}/.." && pwd)
LOG="$MODDIR/log/apply.log"

# 并发保护：两个 refresh 同时跑会重复杀 zygote、并各自等 80 秒
. "$MODDIR/bin/lib.sh"
if ! lock_acquire refresh 5; then
    echo "$(date '+%F %T') [refresh] 已有另一个 refresh 在进行，跳过" >>"$LOG"
    exit 0
fi
trap 'lock_release refresh' EXIT INT TERM

# 先确保属性已经写对了；apply 失败就别白杀一次 zygote（所有 App 都会重启）
if ! "$MODDIR/bin/apply.sh" pre-refresh >/dev/null 2>&1; then
    echo "$(date '+%F %T') [refresh] apply 失败，放弃重启 zygote（详情看 log）" >>"$LOG"
    exit 1
fi

p=$(/system/bin/pidof zygote64)
[ -z "$p" ] && p=$(/system/bin/pidof zygote)
if [ -z "$p" ]; then
    echo "$(date '+%F %T') [refresh] 找不到 zygote 进程，已放弃" >>"$LOG"
    exit 1
fi

echo "$(date '+%F %T') [refresh] 杀掉 zygote pid=$p，由 init 重新拉起（原因=${1:-manual}）" >>"$LOG"
kill -9 $p

# 等新 zygote + system_server 起来，再重建快照。
# 不重建的话，refresh 之后 audit 会误报“native 与快照不一致”。
i=0
while [ $i -lt 40 ]; do
    if [ -n "$(/system/bin/pidof zygote64)" ] && [ -n "$(/system/bin/pidof system_server)" ]; then break; fi
    sleep 2; i=$((i+1))
done
sleep 6
"$MODDIR/bin/snapshot.sh" >/dev/null 2>&1 \
  && echo "$(date '+%F %T') [refresh] 新 zygote 已就绪，快照已按当前值重建" >>"$LOG" \
  || echo "$(date '+%F %T') [refresh] 快照重建失败" >>"$LOG"
exit 0
