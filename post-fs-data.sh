#!/system/bin/sh
# 关键时机。KernelSU 的 post-fs-data 处于 init 的 post-fs-data trigger 内，
# 而 zygote-start 在其之后。此时写入的属性会被 zygote 读进
# Build.VERSION.SECURITY_PATCH，之后 fork 出的所有 App（含「设置」）都继承它。
# 错过这个时间点就只剩下「重启 zygote」或「hook」两条路。
MODDIR=${0%/*}
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin:$PATH
mkdir -p "$MODDIR/log"
# 自愈：从 zip 安装时可能丢掉可执行位，而本模块多处是直接执行脚本
chmod 755 "$MODDIR"/*.sh "$MODDIR"/bin/* 2>/dev/null
[ -f "$MODDIR/prop.conf" ] || exit 0
"$MODDIR/bin/apply.sh" post-fs-data >/dev/null 2>&1
# 紧接着把“zygote 即将看到的值”存成快照：日后 native 被 guard 改写时，
# audit 能靠它发现 Build 字段与 SystemProperties 不一致（最大的检测点）
"$MODDIR/bin/snapshot.sh" >/dev/null 2>&1
