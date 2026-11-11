#!/system/bin/sh
# 安全地修改 prop.conf 的一项：校验后重写该行，可选用 -a 立即生效
#   setconf.sh ro.build.version.security_patch 2026-10-05
#   setconf.sh refresh zygote
#   setconf.sh guard_action report
set -u
export PATH=/system/bin:/system/xbin:/data/adb/ksu/bin:$PATH
MODDIR=$(cd "${0%/*}/.." && pwd)
. "$MODDIR/bin/lib.sh"

apply_now=0
[ "${1:-}" = "-a" ] && { apply_now=1; shift; }
key=${1:-}; val=${2:-}
[ -z "$key" ] && { echo "用法: setconf.sh [-a] KEY VALUE"; exit 1; }

case "$key" in
  refresh)
    case "$val" in reboot|zygote|none) ;; *) echo "refresh 只能是 reboot|zygote|none"; exit 1;; esac ;;
  guard)
    case "$val" in on|off) ;; *) echo "guard 只能是 on|off"; exit 1;; esac ;;
  guard_action)
    case "$val" in fix|report) ;; *) echo "guard_action 只能是 fix|report"; exit 1;; esac ;;
  max_ahead)
    case "$val" in ''|*[!0-9]*) echo "max_ahead 必须是非负整数"; exit 1;; esac ;;
  ro.*|persist.*)
    case "$val" in
      auto|ref:pif|ref:disk) ;;
      *) is_date "$val" || { echo "$key 的值必须是 YYYY-MM-DD 或 auto/ref:pif/ref:disk"; exit 1; } ;;
    esac
    # 提前提醒：本机没这个属性时，apply 会跳过（不凭空创建）
    if [ "$val" != "ref:disk" ] && [ -z "$(getprop "$key" 2>/dev/null)" ]; then
      echo "警告：本机不存在属性 $key，apply 时会跳过"
    fi ;;
  *) echo "不支持的配置项: $key"; exit 1 ;;
esac

# 配置统一写到用户层（升级不会被覆盖）：不存在时先从模块默认配置揄一份
if [ ! -f "$UCONF" ]; then
    if ! cp -f "$MODDIR/prop.conf" "$UCONF" 2>/dev/null; then
        echo "无法创建 $UCONF，配置将写入模块目录（升级会丢）"
        UCONF="$MODDIR/prop.conf"
    fi
fi
chmod 644 "$UCONF" 2>/dev/null
CONF="$UCONF"

# 用 awk 精确重写：grep/sed 会把 key 里的 . 当通配符，可能改错一行
awk -v k="$key" -v v="$val" '
    BEGIN { done = 0 }
    {
        if (!done) {
            p = index($0, "=")
            if (p > 1 && substr($0, 1, p - 1) == k) { print k "=" v; done = 1; next }
        }
        print
    }
    END { if (!done) print k "=" v }
' "$CONF" > "$CONF.tmp.$$" && mv -f "$CONF.tmp.$$" "$CONF"
# 临时名带 $$：并发调用（WebUI 连点、两个终端）不会互相覆盖半成品
chmod 644 "$CONF" 2>/dev/null

if [ "$apply_now" = 1 ]; then
    # 写入成功但应用失败时必须用非 0 退出码告知调用方（WebUI 靠它弹错）
    if "$MODDIR/bin/apply.sh" setconf; then
        echo "已写入并应用: $key=$val"
    else
        echo "已写入配置，但【应用失败】: $key=$val"
        echo "  常见原因：日期超前超过 max_ahead，或目标非法。最近日志："
        tail -n 5 "$LOG" 2>/dev/null | sed 's/^/    /'
        exit 1
    fi
else
    echo "已写入: $key=$val"
fi
exit 0
