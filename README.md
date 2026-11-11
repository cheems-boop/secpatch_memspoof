# 安全补丁日期伪装（仅内存）

KernelSU 模块。把「设置 → 关于手机 → Android 安全更新」里显示的日期改成你想要的。
**只改写系统属性的共享内存，不碰任何分区、不落盘，重启即还原真值。**

> **作者**：DeepSeek ｜ **测试与真机验证**：[@cheems-boop](https://github.com/cheems-boop)

```
改前：2026年10月1日
改后：2026年10月5日
```

---

## 1. 它到底做了什么

Android 把安全补丁日期存在两个 `ro.*` 属性里，**值只存在于内存**：

| 属性 | 谁在用 |
|---|---|
| `ro.build.version.security_patch` | `Build.VERSION.SECURITY_PATCH`、设置页显示 |
| `ro.vendor.build.security_patch` | 厂商层自检、部分 App |

这两个值由 init 从各分区的 `build.prop` 读入属性共享区，而分区是**只读**的（EROFS），`ro.*` 又只允许写一次。
所以唯一可行的办法是：用 `resetprop -n` 直接改写属性共享内存（`/dev/__properties__`）。

**结果**：`getprop` 立刻变，但设置页不变——因为 `Build.VERSION.SECURITY_PATCH` 是 **zygote 启动时快照**，之后 fork 出的所有 App 继承这份快照。要让它变，只有两条路：

1. **开机前改**（本模块的 `post-fs-data.sh`，早于 zygote-start）
2. **重启 zygote**（`patchctl refresh`，所有 App 会被杀掉重启，约 3 秒）

---

## 2. 兼容性

- **KernelSU / KernelSU Next / SukiSU**：依赖 `ksud` 自带的 `resetprop`
- **Magisk**：未测试，本模块的挂载/脚本约定按 KSU 写
- **Android**：实测 Android 17 / ColorOS，理论 Android 10+
- 会自动接管 Termux 环境（检测到 `/data/data/com.termux/files/home` 就把 `PATH`/`HOME`/`TMPDIR` 指过去）

---

## 3. 安装

1. 下载 `secpatch_memspoof-v1.4.zip`
2. KernelSU 管理器 → 模块 → **从本地安装** → 选 zip
3. **重启手机**（让 `post-fs-data.sh` 在 zygote 之前生效）

> 不想重启也可以：装完后点模块页「**执行**」或跑 `patchctl apply` 先把属性写好，
> 再点「打开」→「立即刷新界面」让设置页生效。

---

## 4. 使用：三种方式

### ① WebUI（推荐，普通用户）

模块页 →「**打开**」：

- **当前状态**：每个属性的「配置 / 当前值 / 分区真值」三栏对照
- **想把日期改成多少**：日期选择器 + 「跟随 PIF」「当月 05 日」「恢复真值」三个捷径
- **策略**：刷新方式、漂移守护开关、守护动作
- **操作**：立即应用 / 立即刷新界面 / 痕迹体检 / 恢复真值 / 重启守护 / 接口诊断

### ② 模块页「执行」

打印一张状态表，不改任何东西。

### ③ 命令行

```sh
M=/data/adb/modules/secpatch_memspoof

sh $M/bin/patchctl show      # 配置 vs 当前值
sh $M/bin/patchctl diff      # 当前值 vs 分区真值（看伪装了几项）
sh $M/bin/patchctl audit     # 痕迹体检（按检测方视角打分）
sh $M/bin/patchctl doctor    # 环境/一致性/快照体检
sh $M/bin/patchctl apply     # 立即应用（不动 zygote）
sh $M/bin/patchctl refresh   # 应用并重启 zygote（设置页立刻刷新）
sh $M/bin/patchctl reset     # 关闭伪装（写回真值 + 配置改 ref:disk，持久）
sh $M/bin/patchctl on        # 重新开启伪装（配置回 ref:pif）
sh $M/bin/patchctl sync-pif  # 把目标日期回写 pif.prop（两份都改，带备份）
sh $M/bin/patchctl restart   # 重启守护进程
sh $M/bin/patchctl status    # 守护进程状态
sh $M/bin/patchctl log       # 最近日志
```

---

## 5. 配置（`prop.conf`）

```ini
refresh=reboot          # reboot | zygote | none
 guard=on                # on | off
 guard_interval=30      # 秒
guard_action=fix        # fix（漂移就改写）| report（只记日志）
max_ahead=0             # 目标日期最多超前当前月几个月

ro.build.version.security_patch=ref:pif
ro.vendor.build.security_patch=ref:pif
```

值的四种写法：

| 写法 | 含义 |
|---|---|
| `YYYY-MM-DD` | 固定日期，例 `2026-11-05` |
| `auto` | 当月 05 日，跨月自动推进 |
| `ref:pif` | 跟随 `/data/adb/pif.prop` 的 `SECURITY_PATCH`（**推荐**，与 Play Integrity Fix 口径一致） |
| `ref:disk` | 分区 `build.prop` 真值（= 关闭伪装） |

### 配置文件在哪（升级不丢）

| 文件 | 作用 |
|---|---|
| `prop.conf`（模块目录内） | **出厂默认值**，升级时会被新版覆盖 |
| `/data/adb/secpatch_memspoof.conf` | **你的实际配置**，第一次改配置时自动生成，升级/重装模块不会动 |

读取优先级：存在用户层配置就用它，否则用模块默认。要恢复默认：删掉 `/data/adb/secpatch_memspoof.conf` 即可。

改配置也可以用命令（带校验，不会写坏）：

```sh
sh bin/setconf.sh -a ro.vendor.build.security_patch 2026-11-05
sh bin/setconf.sh refresh zygote
sh bin/setconf.sh guard-action report   # 或 patchctl guard-action report
```

---

## 6. 为什么“只改属性”往往不够（重要）

改日期有三种可检测性，本模块能处理前两层：

| 层级 | 谁在看 | 状态 |
|---|---|---|
| 属性共享内存 | `getprop`、`SystemProperties.get`、设置页 | ✅ 本模块负责 |
| zygote 快照 | Java `Build.VERSION.SECURITY_PATCH` | ✅ `post-fs-data` 早写 + `audit` 校验一致性 |
| TEE 背书（keybox） | Play Integrity / 强完整性 | ❌ **改不了**，靠 keybox 方案（如 Oh My Keymint） |

所以：

- **能过**：靠读属性做版本门槛的 App、企业合规检查、部分风控
- **不能过**：Play Integrity 的强完整性、任何看硬件背书的检测
- **改了不等于修了漏洞**：真实安全状态一点没变

### 让值看起来不奇怪的经验

- 用 `ref:pif`，让系统属性、PIF 配置、attestation 三方口径一致
- 不要写未来日期（`max_ahead=0` 已经拦住）
- 补丁日期不要落后当前月（会拉低 Play Integrity 判定，`audit` 会提醒）

---

## 7. 目录结构

```
secpatch_memspoof/
├── module.prop           模块描述（KSU 读）
├── prop.conf             配置
├── post-fs-data.sh       开机阶段：zygote 启动前写入 + 记录快照
├── service.sh            开机完成：补一次 + 拉起守护
├── action.sh             模块页「执行」
├── uninstall.sh          卸载：停守护 + 清日志
├── bin/
│   ├── lib.sh            公共函数（MODDIR 推导 / resetprop / kv / 日期校验 / 守护定位）
│   ├── apply.sh          核心写入器（幂等 + 回读校验 + 基线快照）
│   ├── verify.sh         期望值 vs 当前值校验
│   ├── watchd.sh         守护：配置热加载 + 漂移检测 + 月度推进
│   ├── snapshot.sh       记录 zygote 启动时的值
│   ├── audit.sh          痕迹自查（按检测方视角打分）
│   ├── refresh.sh        重启 zygote 让设置页刷新
│   ├── restore.sh        写回真值（--persist 同时改配置）
│   ├── setconf.sh        安全地改一行配置（带校验）
│   ├── state.sh          机器可读状态（WebUI 用）
│   └── patchctl          命令行入口
├── webroot/index.html    WebUI
├── log/                  运行时生成（审计日志 / 基线 / 快照 / pid），已 gitignore 语义
├── README.md
├── CHANGELOG.md
└── LICENSE
```

---

## 8. FAQ

**Q：改完设置里没变？**
A：设置页读的是 zygote 启动时的快照。重启手机，或 `patchctl refresh`（会杀掉所有 App，约 3 秒）。

**Q：会不会掉 Play Integrity？**
A：把日期保持在「当月最新补丁日」就不容易掉；落后一个月是常见原因。`patchctl audit` 会直接告诉你。

**Q：会不会把一个 App 杀掉就变了？**
A：不会。实测杀掉「设置」进程再打开，显示仍是旧值 —— `Build` 类在 zygote 里就初始化完了。

**Q：能改 `ro.build.fingerprint` 之类的吗？**
A：代码层面能，但模块**主动拒绝**（`ro.boot.*` / `ro.secure` / `ro.debuggable` / `ro.build.tags|type|fingerprint`），那些归 PIF 管，碰了会直接打坏完整性。

**Q：日志在哪？会不会很大？**
A：`log/apply.log`，超过 256KB 自动轮转为 `.1`；权限 0600，目录 0700。

**Q：更新模块会丢配置吗？**
A：不会。你的配置在 `/data/adb/secpatch_memspoof.conf`，升级替换的是模块目录，不会动它。

**Q：怎么彻底卸干净？**
A：`patchctl reset` → 重启 → KSU 里删模块 → 再重启。属性本来就只在内存，重启即消失；
`uninstall.sh` 会一并删掉 `/data/adb/secpatch_memspoof.conf` 和 `log/`。

⚠️ 注意：如果你用过 `patchctl sync-pif`，它改的是 **Play Integrity Fix 的** `/data/adb/pif.prop`（已自动备份 `*.bak.<时间戳>`）。
卸载本模块**不会**还原它，需要手动 `cp` 备份回。

**Q：没装 Play Integrity Fix 能用吗？**
A：能。`ref:pif` 读不到 `pif.prop` 时会回退到「当月 05 日」。

**Q：支不支持 Magisk？**
A：不支持。模块依赖 KernelSU 的 `ksud resetprop`；检测不到时 `service.sh` 不会启动守护，
`apply.sh` 会在日志里写 `FATAL resetprop 不可用`。

---

## 9. 免责声明

本项目仅用于**学习属性机制与完整性检测原理**。它只改变显示的日期，**不能**提升设备真实安全性，也不应被用于欺骗他人或绕过合法合规要求。使用风险自负。

## 10. 许可

[MIT](LICENSE) · Copyright (c) 2026 DeepSeek

---

## 11. 致谢

- **实现与文档**：DeepSeek
- **真机测试、调试与反馈**：[@cheems-boop](https://github.com/cheems-boop)
  （全新安装链路、升级保配置、并发与边界场景均为其实机验证）
