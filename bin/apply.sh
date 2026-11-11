#!/system/bin/sh
# ====================================================================
# v1.1 核心写入器：resetprop 直接改写属性共享内存
#   - 不写任何分区、不落盘（除审计日志），重启即恢复真值
#   - 只改本机已存在的属性，绝不凭空创建
#   - 受保护属性（PIF 管的）直接跳过
#   - 首次运行记录分区真值快照 baseline.conf
#   - 只在值不同时写，写完必回读校验
# ====================================================================
set -u
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin:$PATH
MODDIR=$(cd "${0%/*}/.." && pwd)
. "$MODDIR/bin/lib.sh"

[ -z "$RP" ] && { log FATAL "resetprop 不可用"; exit 1; }
[ -s "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 262144 ] && mv -f "$LOG" "$LOG.1"

# 串行化：多个 apply 同时跑会让 resetprop 交错、基线/日志也乱。
# 等不到锁就跳过（说明已有一个在干同样的事）。
if ! lock_acquire apply 8; then
    log WARN "另一个 apply 正在运行，本次跳过（trigger=${1:-manual}）"
    exit 0
fi
trap 'lock_release apply' EXIT INT TERM

# ---------- 1) 首次运行：记录分区真值快照 ----------
if [ ! -f "$BASE" ]; then
    tmp="$BASE.tmp.$$"; : > "$tmp"   # 带 $$：避免与另一个进程互踩
    for k in $(conf_keys | sort -u); do
        v=$(disk_val "$k")
        [ -z "$v" ] && v=$(getprop "$k" 2>/dev/null)
        [ -n "$v" ] && echo "$k=$v" >> "$tmp"
    done
    mv -f "$tmp" "$BASE" 2>/dev/null
    chmod 600 "$BASE" 2>/dev/null
    log BASE "已记录真值快照 $(wc -l < "$BASE" 2>/dev/null | tr -d ' ') 项"
fi

# ---------- 2) 应用配置 ----------
ok=0; skip=0; fail=0
while IFS= read -r line || [ -n "$line" ]; do
    line=$(trim "$line")
    case "$line" in ''|'#'*) continue;; esac
    case "$line" in *=*) ;; *) log WARN "格式错误: $line"; continue;; esac
    key=${line%%=*}
    case "$key" in ro.*|persist.*) ;; *) continue;; esac

    if protected "$key"; then
        log SKIP "$key 属于受保护属性（PIF/系统负责），本模块不碰"
        skip=$((skip+1)); continue
    fi

    raw=${line#*=}
    val=$(resolve "$raw" "$key")
    if ! is_date "$val"; then
        log WARN "$key 的值不是合法日期（$val），跳过"; fail=$((fail+1)); continue
    fi

    # 超前幅度校验：只对写死的日期生效。
    # ref:pif / auto 是“外部真源”，不能拦 —— 否则 PIF 更新到更新的补丁月时，模块会静默拒不写入。
    case "$raw" in
        auto|ref:pif|ref:disk) ;;
        *)
            ma=$(cfg max_ahead); [ -z "$ma" ] && ma=0
            ty=${val%%-*}; tm2=${val#*-}; tm=${tm2%%-*}; tm=${tm#0}
            ny=$(date +%Y); nm=$(date +%m); nm=${nm#0}
            if [ $(( ty * 12 + tm - ny * 12 - nm )) -gt "$ma" ]; then
                log WARN "$key 目标 $val 超前当前月 $ma 个月以上，拒绝写入"; fail=$((fail+1)); continue
            fi
            ;;
    esac

    cur=$(getprop "$key" 2>/dev/null)
    if [ -z "$cur" ]; then
        log SKIP "$key 本机不存在该属性，拒绝凭空创建"; skip=$((skip+1)); continue
    fi
    if [ "$cur" = "$val" ]; then
        log OK "$key=$val（已是目标值）"; skip=$((skip+1)); continue
    fi

    rp_set "$key" "$val" >/dev/null 2>&1
    back=$(getprop "$key" 2>/dev/null)
    if [ "$back" != "$val" ] && [ -x /data/adb/ksud ]; then
        /data/adb/ksud resetprop -n "$key" "$val" >/dev/null 2>&1
        back=$(getprop "$key" 2>/dev/null)
    fi
    if [ "$back" = "$val" ]; then
        log SET "$key: $cur -> $val"; ok=$((ok+1))
    else
        log FAIL "$key: want=$val readback=${back:-<unset>}"; fail=$((fail+1))
    fi
done <"$(conf_file)"

log SUM "set=$ok skip=$skip fail=$fail trigger=${1:-manual}${2:+ $2}"

# 一条都没写成功时给出明确的行动建议，而不是只丢几条 WARN。
# （之前 max_ahead 拦下后用户只看到“日期没变”，完全不知道原因）
if [ "$ok" -eq 0 ] && [ "$fail" -gt 0 ]; then
    _ma=$(cfg max_ahead); [ -z "$_ma" ] && _ma=1
    log HINT "全部写入失败。常见原因：目标日期超前超过 max_ahead=$_ma 个月（可在 prop.conf 调大），或日期非法。详见上方 WARN 行"
fi

[ "$fail" -eq 0 ]
