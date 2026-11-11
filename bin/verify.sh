#!/system/bin/sh
# 校验：配置期望值 vs 当前属性值。全部一致返回 0，有漂移返回 1
#   verify.sh          打印明细
#   verify.sh quiet    静默（给 watchd 用）
set -u
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin:$PATH
MODDIR=$(cd "${0%/*}/.." && pwd)
. "$MODDIR/bin/lib.sh"

quiet=${1:-}
total=0; drift=0
for k in $(conf_keys | sort -u); do
    protected "$k" && continue
    raw=$(cfg "$k")
    want=$(resolve "$raw" "$k")
    total=$((total+1))
    # 配置值非法/无法解析时不能静默跳过 —— 否则这一项永远检测不到漂移
    if ! is_date "$want"; then
        drift=$((drift+1))
        [ "$quiet" = quiet ] || echo "漂移  $k: 配置值无法解析为日期（配置=$raw 解析结果=${want:-<空>}）"
        continue
    fi
    cur=$(getprop "$k" 2>/dev/null)
    if [ "$cur" != "$want" ]; then
        drift=$((drift+1))
        [ "$quiet" = quiet ] || echo "漂移  $k: 应为 $want，实际 ${cur:-<无>}"
    fi
done

[ "$quiet" = quiet ] || echo "检查 $total 项，漂移 $drift 项"
[ "$drift" -eq 0 ]
