#!/system/bin/sh
# v1.1 守护进程：
#   1) 配置热加载：prop.conf 一变就重新应用（refresh=zygote 时自动重启 zygote）
#   2) 漂移守护：每 guard_interval 秒校验一次，被别的模块/程序改回就自动重写
#   3) 月度推进：每小时重解析一次（auto 会随月份自动跳到当月 05 日）
set -u
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin:$PATH
MODDIR=$(cd "${0%/*}/.." && pwd)
. "$MODDIR/bin/lib.sh"

# 单实例：pidfile + /proc 校验（不依赖 flock/sha256sum 这类 busybox applet）
watchd_alive && exit 0
echo $$ > "$WATCHD_PID"
# 注意：TERM/INT 必须「删 pidfile 后退出」。
# 如果只写 rm，trap 执行完脚本会继续跑，kill 反而无效（实测 restart 杀不掉）。
trap 'rm -f "$WATCHD_PID"' EXIT
trap 'rm -f "$WATCHD_PID"; exit 0' INT TERM

# 配置签名：prop.conf + pif.prop 的 mtime/大小。
# 带上 pif.prop 才能跟住 PIF 的 autopif 自动更新（否则 ref:pif 最多滞后 1 小时）。
sig() {
    stat -c '%Y-%s' "$(conf_file)" 2>/dev/null   # 动态定位（用户层优先）
    stat -c '%Y-%s' /data/adb/pif.prop 2>/dev/null
}
last=$(sig)
now=$(date +%s)
t_guard=$now; t_hour=$now
drift_out=""      # 上次的漂移内容（去重用）
log watchd "启动 pid=$$ guard=$(cfg guard) interval=$(cfg guard_interval) refresh=$(cfg refresh)"

while :; do
    sleep 3
    now=$(date +%s)

    # --- 1) 配置变更 ---
    cur=$(sig)
    if [ -n "$cur" ] && [ "$cur" != "$last" ]; then
        last=$cur
        log watchd "检测到 prop.conf 变更，重新应用"
        "$MODDIR/bin/apply.sh" reload >/dev/null 2>&1
        case "$(cfg refresh)" in
            zygote) "$MODDIR/bin/refresh.sh" config-change ;;
        esac
        t_guard=$now
        continue
    fi

    # --- 2) 漂移守护 ---
    gi=$(cfg guard_interval)
    # 非数字会让 [ -ge ] 报错刷屏，这里强制归一为一个合理整数
    case "${gi:-}" in ''|*[!0-9]*) gi=30 ;; esac
    [ "$gi" -ge 5 ] 2>/dev/null || gi=30
    if [ "$(cfg guard)" = on ] && [ $((now - t_guard)) -ge "$gi" ]; then
        t_guard=$now
        # 漂移去重：只有“漂移内容”变了才记日志。
        # 否则 report 模式会每 30 秒刷一行，一天 2880 行，把审计日志淹了。
        if ! dout=$("$MODDIR/bin/verify.sh" 2>/dev/null); then
            if [ "$dout" != "$drift_out" ]; then
                drift_out="$dout"
                log drift "检测到属性漂移：$(printf '%s' "$dout" | tr '\n' ';')"
                if [ "$(cfg guard_action)" = report ]; then
                    log drift "guard_action=report，仅记录不重写"
                else
                    "$MODDIR/bin/apply.sh" guard-fix >/dev/null 2>&1
                    log drift "已自动重写（native 与 zygote 快照短暂不一致，彻底自洽需 patchctl refresh）"
                fi
            fi
        elif [ -n "${drift_out:-}" ]; then
            drift_out=""
            log drift "漂移已恢复"
        fi
    fi

    # --- 3) 月度推进 ---
    if [ $((now - t_hour)) -ge 3600 ]; then
        t_hour=$now
        before=$(getprop ro.build.version.security_patch 2>/dev/null)
        "$MODDIR/bin/apply.sh" hourly >/dev/null 2>&1
        after=$(getprop ro.build.version.security_patch 2>/dev/null)
        [ "$before" != "$after" ] && log auto "周期推进: $before -> $after（设置页需 patchctl refresh）"
    fi
done
