#!/system/bin/sh
# 痕迹自查：把「检测方能看到的差异」逐项列出来并给出风险等级
# 高危 = 基本一查一个准；中 = 需交叉比对才发现；低 = App 无权限或极罕见
set -u
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin:$PATH
MODDIR=$(cd "${0%/*}/.." && pwd)
. "$MODDIR/bin/lib.sh"

high=0; mid=0; low=0
say() { printf '  %s %-58s %s\n' "$1" "$2" "$3"; }

bootid=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
snap_boot=$(grep -m1 '^#boot_id=' "$SNAP" 2>/dev/null | cut -d= -f2)

now_y=$(date +%Y); now_m=$(date +%m); now_m=${now_m#0}

for k in $(conf_keys | sort -u); do
    protected "$k" && continue
    now=$(getprop "$k" 2>/dev/null)
    real=$(kv "$BASE" "$k")
    [ -z "$real" ] && real=$(disk_val "$k")

    echo "[$k]"
    say "·" "当前 native 值" "$now"
    say "·" "分区真值" "${real:-—}"

    # 1) native vs zygote 快照（Java Build 字段缓存的版本）
    if [ -z "$snap_boot" ] || [ "$snap_boot" != "$bootid" ]; then
        say "?" "zygote 快照" "缺失或非本次开机（重启后自动建立）"; mid=$((mid+1))
    else
        snap=$(kv "$SNAP" "$k")
        if [ "$snap" = "$now" ]; then
            say "✓" "与 zygote 快照一致（Build 字段同源）" "$snap"
        else
            say "✗" "与 zygote 快照不一致 → SystemProperties 与 Build 对比即暴露" "$snap"; high=$((high+1))
        fi
    fi

    # 2) 是否超出“未来”
    if is_date "$now"; then
        ty=${now%%-*}; tmp2=${now#*-}; tm=${tmp2%%-*}; tm=${tm#0}
        diff=$(( (ty * 12 + tm) - (now_y * 12 + now_m) ))
        if [ "$diff" -gt 0 ]; then
            say "✗" "值为未来日期（超前 $diff 个月）" "$now"; high=$((high+1))
        else
            say "✓" "日期不超前当前月份" "$now"
        fi

        # 2b) 补丁时效：落后当前月会直接拉低 Play Integrity 判定（这是功能性指标，不是痕迹）
        lag=$(( (now_y * 12 + now_m) - (ty * 12 + tm) ))
        if [ "$lag" -gt 0 ]; then
            say "!" "补丁落后当前月 $lag 个月（会掉 Play Integrity）" "$now"; mid=$((mid+1))
        else
            say "✓" "补丁时效达标（当月最新补丁日）" "$now"
        fi
    fi

    # 3) 与 PIF 口径
    p=$(pif_val)
    if [ -n "$p" ]; then
        if [ "$p" = "$now" ]; then say "✓" "与 pif.prop SECURITY_PATCH 一致" "$p"
        else say "!" "与 pif.prop 不一致" "pif=$p"; mid=$((mid+1)); fi
    fi

    # 4) 分区里没有这个属性：可能是运行期才设的属性（正常），也可能是凭空创建（异常）
    if [ -z "$real" ]; then
        say "!" "分区 build.prop 里没有该属性（可能为运行期属性）" "—"; mid=$((mid+1))
    fi
done

# 5) system vs vendor 是否成对一致
a=$(getprop ro.build.version.security_patch); b=$(getprop ro.vendor.build.security_patch)
echo "[成对一致性]"
if [ "$a" = "$b" ]; then say "✓" "system / vendor 补丁日期相同" "$a"
else say "!" "system 与 vendor 不同（厂商也可能不同，中风险）" "sys=$a vnd=$b"; mid=$((mid+1)); fi

# 6) persist.* 落盘痕迹
echo "[落盘痕迹]"
if getprop | grep -qE '^\[persist\..*security_patch'; then
    say "✗" "存在 persist.* 补丁属性（真实落盘，重启不会消失）" "—"; high=$((high+1))
else
    say "✓" "无 persist.* 补丁属性（纯内存，重启即还原）" "—"
fi

# 7) 可见性
echo "[可见性]"
say "·" "/system/build.prop 权限" "$(ls -l /system/build.prop 2>/dev/null | awk '{print $1" "$3":"$4}')"
say "·" "模块目录" "$(ls -dZ "$MODDIR" 2>/dev/null | grep -o 'u:object_r:[a-z_]*')（App 无权限读 /data/adb）"
say "·" "日志" "$(stat -c %s "$LOG" 2>/dev/null || echo 0) 字节"

echo "---------------------------------------------"
printf '风险统计：高危 %s 项 / 中危 %s 项\n' "$high" "$mid"
echo "注：属性层能做到的极限是“所有读取方看到同一个值”；"
echo "    构建号、指纹、attestation patchLevel 与本机硬件证据的不匹配属于外部事实，无法用属性伪造。"
