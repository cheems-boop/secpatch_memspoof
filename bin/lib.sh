#!/system/bin/sh
# =====================================================================
# 公共函数库（被 apply.sh / verify.sh / watchd.sh / patchctl / restore.sh source）
# 调用方应已设置 MODDIR；未设置时按 $0 向上推一级
# =====================================================================
# MODDIR 推导：正常调用形如 sh <moddir>/bin/xxx.sh，$0 是绝对路径。
# 但若有人在 `sh -c` 里 source 本文件，$0 会是 "sh"，推导会失败并退化到当前目录，
# 从而在奇怪的地方建出 log/ 目录（实际踩过）。因此做一次路径校验 + 硬编码兼底。
# 校验条件不是“MODDIR 为空”，而是“MODDIR 里没有 prop.conf”：
# 调用方常先写一句 MODDIR=$(cd "${0%/*}/.." && pwd)，从错误 cwd 启动时那句会算出一个
# 看起来合法但错的目录，从而在 /data 或当前目录里建 log/（实际踩过）。
if [ -z "${MODDIR:-}" ] || [ ! -f "${MODDIR:-}/prop.conf" ]; then
    _d=$(cd "${0%/*}/.." 2>/dev/null && pwd) || _d=""
    if [ -n "$_d" ] && [ -f "$_d/prop.conf" ]; then
        MODDIR="$_d"
    else
        MODDIR=/data/adb/modules/secpatch_memspoof
    fi
    unset _d
fi
# 用户配置放在模块目录之外：KSU 装新版会整目录替换，
# 若直接用模块内的 prop.conf，每次升级都会把用户改的日期打回默认值。
# 优先用 /data/adb/secpatch_memspoof.conf（用户层），不存在才用模块自带的默认。
UCONF=/data/adb/secpatch_memspoof.conf

# 每次读取都重新判断用哪份配置。
# 不能在 source 时定死：守护进程是长命的，用户第一次改配置会新建 UCONF，
# 定死的话守护会一直盯着旧文件，之后的变更全收不到（实际踩过）。
conf_file() {
    if [ -f "$UCONF" ]; then printf '%s' "$UCONF"; else printf '%s' "$MODDIR/prop.conf"; fi
}
CONF=$(conf_file)
LOG="$MODDIR/log/apply.log"
BASE="$MODDIR/log/baseline.conf"
SNAP="$MODDIR/log/zygote_snapshot.conf"

mkdir -p "$MODDIR/log" 2>/dev/null
chmod 700 "$MODDIR/log" 2>/dev/null
chmod 600 "$LOG" 2>/dev/null

# resetprop 定位：优先 KSU 的软链，否则纯 ksud（需子命令），最后 PATH
RP=""
for c in /data/adb/ksu/bin/resetprop "$(command -v resetprop 2>/dev/null)" /data/adb/ksud; do
    [ -n "$c" ] && [ -x "$c" ] && { RP="$c"; break; }
done

rp_set() {   # $1=key $2=value
    case "$RP" in
        "")      return 1 ;;
        */ksud)  "$RP" resetprop -n "$1" "$2" ;;
        *)       "$RP" -n "$1" "$2" ;;
    esac
}

log() { echo "$(date '+%F %T') [$1] $2" >> "$LOG"; }

# 简易目录锁（mkdir 原子，跨文件系统可靠）；带陈旧检测。
# 用于防止并发 apply / refresh 互踩（比如 WebUI 连点、守护 reload 与手动 apply 撞车）。
lock_acquire() {   # $1=名字 $2=最多等几秒（默认 8）
    _ld="$MODDIR/log/.$1.lock"
    _lim=${2:-8}; _i=0
    _myboot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    while :; do
        if mkdir "$_ld" 2>/dev/null; then
            # 同时记 pid 与 boot_id：重启后残留的锁能一眼认出来
            printf '%s %s\n' "$$" "$_myboot" > "$_ld/pid" 2>/dev/null
            unset _ld _lim _i _myboot
            return 0
        fi
        _lp=$(awk '{print $1}' "$_ld/pid" 2>/dev/null)
        _lb=$(awk '{print $2}' "$_ld/pid" 2>/dev/null)
        _stale=0
        if [ -z "$_lp" ]; then
            # 持锁者可能刚 mkdir、还没写 pid；给 2 秒宽限。
            # 一直没 pid 就是异常残留（之前没这条，锁会永久插死）
            [ "$_i" -ge 2 ] && _stale=1
        elif [ -n "$_lb" ] && [ "$_lb" != "$_myboot" ]; then
            _stale=1                                   # 跨重启的残留锁
        elif [ ! -d "/proc/$_lp" ]; then
            _stale=1                                   # 持锁进程已死
        else
            # PID 活但持锁超龄：可能是 PID 被复用，或持锁进程自己卡死
            _mt=$(stat -c %Y "$_ld/pid" 2>/dev/null || echo 0)
            _now=$(date +%s)
            [ "$_mt" -gt 0 ] && [ $((_now - _mt)) -gt "${LOCK_TTL:-180}" ] && _stale=1
        fi
        if [ "$_stale" = 1 ]; then
            rm -rf "$_ld" 2>/dev/null
            continue
        fi
        _i=$((_i+1))
        [ "$_i" -ge "$_lim" ] && { unset _ld _lim _i _lp _lb _stale _myboot; return 1; }
        sleep 1
    done
}

# 释放：只删自己的锁。
# 无条件 rm 会有 ABA 问题：我的锁被判陈旧、别人抢到后，我结束时把别人的锁删了 → 双持有。
lock_release() {
    _ld="$MODDIR/log/.$1.lock"
    _lp=$(awk '{print $1}' "$_ld/pid" 2>/dev/null)
    [ "$_lp" = "$$" ] && rm -rf "$_ld" 2>/dev/null
    unset _ld _lp
}

trim() { printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# 按 key 精确取值（不用 grep：属性名里的 . 会当正则通配符，可能误匹配到别的属性）
kv() {   # $1=文件 $2=key
    awk -F= -v k="$2" '$1==k { print substr($0, length(k)+2); exit }' "$1" 2>/dev/null | tr -d '\r'
}

cfg() {   # 读配置的某个项（refresh/guard/...），每次动态定位配置文件
    kv "$(conf_file)" "$1" | sed 's/[[:space:]]*$//'
}

# 严格日期校验：格式 + 月份 01-12 + 日期 01-31（之前只看格式，2026-13-05 也会通过）
is_date() {
    case "$1" in
        [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]) ;;
        *) return 1 ;;
    esac
    _ym=${1%%-*}; _rest=${1#*-}
    _mm=${_rest%%-*}; _dd=${_rest#*-}
    _mm=${_mm#0}; _dd=${_dd#0}
    [ -n "$_mm" ] || _mm=0
    [ -n "$_dd" ] || _dd=0
    [ "$_mm" -ge 1 ] && [ "$_mm" -le 12 ] || { unset _ym _rest _mm _dd; return 1; }
    [ "$_dd" -ge 1 ] && [ "$_dd" -le 31 ] || { unset _ym _rest _mm _dd; return 1; }
    unset _ym _rest _mm _dd
    return 0
}

disk_val() {   # 分区 build.prop 里的真值
    for f in /vendor/build.prop /system/build.prop /odm/build.prop /system_ext/build.prop /product/build.prop; do
        [ -f "$f" ] || continue
        v=$(kv "$f" "$1")
        [ -n "$v" ] && { echo "$v"; return 0; }
    done
    return 1
}

pif_val() {    # PlayIntegrityFix 的目标值
    for p in /data/adb/pif.prop /data/adb/modules/playintegrityfix/pif.prop; do
        [ -f "$p" ] || continue
        v=$(kv "$p" SECURITY_PATCH | sed 's/[[:space:]]*$//')
        [ -n "$v" ] && { echo "$v"; return 0; }
    done
    return 1
}

resolve() {   # $1=原始值 $2=属性名
    case "$1" in
        auto)     date '+%Y-%m-05' ;;
        ref:pif)  pif_val || date '+%Y-%m-05' ;;
        ref:disk) disk_val "$2" ;;
        *)        echo "$1" ;;
    esac
}

# 归 PIF / 系统负责的属性，本模块一律不碰（碰了会直接打坏 Play Integrity）
protected() {
    case "$1" in
        ro.boot.*|ro.secure|ro.debuggable|ro.force.debuggable) return 0 ;;
        ro.build.type|ro.build.tags|ro.build.fingerprint|ro.*.build.fingerprint|ro.*.build.tags|ro.*.build.type) return 0 ;;
    esac
    return 1
}

conf_keys() {   # 输出配置里所有待处理的属性名
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(trim "$line")
        case "$line" in ''|'#'*) continue;; esac
        case "$line" in *=*) ;; *) continue;; esac
        k=${line%%=*}
        case "$k" in ro.*|persist.*) echo "$k";; esac
    done < "$(conf_file)"
}

# busybox：flock/setsid/sha256sum 这些只是 applet，/data/adb/ksu/bin 里不一定有软链
BB=""
for c in /data/adb/ksu/bin/busybox "$(command -v busybox 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { BB="$c"; break; }
done

start_daemon() {   # $@ = 要后台常驻的命令
    if [ -n "$BB" ]; then
        "$BB" setsid "$@" >/dev/null 2>&1 &
    else
        nohup "$@" >/dev/null 2>&1 &
    fi
}

# 守护进程单实例/存活判定：pidfile + /proc，不用 flock（busybox applet 不一定有软链）
WATCHD_PID="$MODDIR/log/watchd.pid"

# 快速列出本模块 watchd 的 PID。
# 不能直接 for /proc/* 逐进程 tr（实测 1000+ 进程要 10 秒），
# 也不能用 ps（这个 ROM 的 ps 看不到脚本解释器进程），
# 所以先用 comm 内建读取预筛（不 fork），再只对少量候选精确核对 cmdline。
watchd_pids() {
    _w="$MODDIR/bin/watchd.sh"
    for _c in /proc/[0-9]*/comm; do
        [ -r "$_c" ] || continue          # 进程可能刚好退出，先判断可读，避免刷错
        { IFS= read -r _n < "$_c"; } 2>/dev/null || continue
        # 注意：Android 的 mksh 会把进程名改成脚本名（实测 comm=watchd.sh），
        # 所以除了 sh/ash/busybox 还要匹配 *watchd.sh，否则永远漏掉真正的实例
        case "$_n" in *watchd.sh|sh|ash|busybox|mksh) ;; *) continue ;; esac
        _p=${_c#/proc/}; _p=${_p%/comm}
        # 只排除自己（命令替换的子 shell 与调用者同 PID 语义，已足够）。
        # 注意：不能用「排除我的子进程」——start_daemon 用 busybox setsid 原地 exec，
        # 新守护的 PPID 恰好就是调用者自己，会被误杀（实际踩过）。
        [ "$_p" = "$$" ] && continue
        _cl=$( { tr '\0' ' ' < "/proc/$_p/cmdline"; } 2>/dev/null )
        # 精确匹配：必须是「/system/bin/sh <本模块 watchd.sh>」，
        # 这样绝不会像之前那样把执行本脚本的 sh -c 扫进去
        case "$_cl" in "/system/bin/sh $_w "*) echo "$_p" ;; esac
    done
}

# 判活：只看 pidfile（不扫描、不用命令替换）。
# watchd 自己启动时也调它，扫描版会把“自己的子 shell”当成已有实例而自杀。
watchd_alive() {
    [ -f "$WATCHD_PID" ] || return 1
    _p=$(cat "$WATCHD_PID" 2>/dev/null)
    [ -n "$_p" ] && [ -d "/proc/$_p" ] && grep -qa watchd "/proc/$_p/cmdline" 2>/dev/null
}

# 是否有任意实例在跑（用于启动前查重、状态展示）：走扫描，但已排除自身/子进程
watchd_any() { [ -n "$(watchd_pids)" ]; }
