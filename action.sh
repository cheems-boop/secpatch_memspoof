#!/system/bin/sh
# KernelSU 模块页「执行」按钮：重新应用 + 打印当前档位（不会杀 zygote）
MODDIR=${0%/*}
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin:$PATH

"$MODDIR/bin/apply.sh" action >/dev/null 2>&1

S=$(sh "$MODDIR/bin/state.sh" 2>/dev/null)
getv() { printf '%s\n' "$S" | awk -F= -v k="$1" '$1==k { print substr($0, length(k)+2); exit }'; }

K1=ro.build.version.security_patch
K2=ro.vendor.build.security_patch

echo "════════ 安全补丁日期伪装 ════════"
printf '%-32s %-10s %-10s %s\n' "属性" "配置" "当前值" "分区真值"
printf '%-32s %-10s %-10s %s\n' "$K1" "$(getv cfg.$K1)" "$(getv now.$K1)" "$(getv real.$K1)"
printf '%-32s %-10s %-10s %s\n' "$K2" "$(getv cfg.$K2)" "$(getv now.$K2)" "$(getv real.$K2)"
echo "──────────────────────────────────"
echo "刷新策略  : $(getv refresh)    （reboot=重启生效 / zygote=立即刷新）"
echo "漂移守护  : $(getv guard) / $(getv guard_action)    （report=只记录不改写）"
echo "PIF 目标值: $(getv pif)"
echo "守护进程  : $(getv watchd)"
echo "zygote快照: $(getv snap)    （ok=Build 字段与属性同源）"
echo "──────────────────────────────────"
echo "改配置两种方式："
echo "  1) 模块页 → 打开（WebUI 图形界面，推荐）"
echo "  2) sh $MODDIR/bin/setconf.sh -a ro.vendor.build.security_patch 2026-10-05"
echo "设置页那一行需重启手机 或 点「立即刷新界面」后才会变"
