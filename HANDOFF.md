# 交接笔记（给重启/新会话后的自己看）

> 为什么有这份文件：本模块的 `patchctl refresh` 会重启 zygote，连带杀掉 MT，
> 正在进行的会话会丢失上下文。重启后先读这里，再动代码。

## 当前状态（2026-11-11 22:5x）

- 版本：`v1.4`（versionCode 4）
- 设备上属性：`2026-11-05` / `2026-11-05`，`audit` 高危 0 / 中危 0
- 守护：单实例运行中
- 交付物：`/storage/emulated/0/MT2/mcp/secpatch_memspoof-v1.4.zip`（≈38.7 KB，已校验）
- 源码：`/storage/emulated/0/MT2/mcp/secpatch_memspoof/`

## 已完成

- v1.4 累计修 38+ 个 bug（详见 CHANGELOG.md）
- 并发面：新增目录锁（ `lib.sh: lock_acquire/lock_release`），并修了锁自身的 3 个缺陷
  - 无 pid 文件 → 永久插死（已加 2 秒宽限）
  - PID 复用 → 永久插死（已加 boot_id + 180s 超龄）
  - 无条件 release → ABA 双持有（已加持有者校验）
- 安装面：升级不丢配置（用户层 `/data/adb/secpatch_memspoof.conf`）、可执行位自愈、无 resetprop 不起守护

## 已在真机验证的完整链路

1. `patchctl reset` → 属性回真值，配置变 `ref:disk`，再 apply 不复活 ✓
2. 卸载 + 重启 → 目录/用户层配置/守护全清，vendor 回 10-01，
   **system 仍 11-05（由 Oh My Keymint 维持）**，设置页显示 10月1日 ✓
3. zip 重装 + 重启 → 权限 755、baseline=10-01、快照=11-05、守护单实例、
   `audit` 0/0，**设置页显示 11月5日**（A/B 对比证明模块确实接管了这一行）✓
4. 改配置 12-05 → 重装 zip → 重启 → **用户层配置未丢**，日期仍 12-05 ✓

## 新学到的关键机制（很重要）

- **OMK/PIF 写 `ro.build.version.security_patch` 的时机在 zygote 启动之后**
  → 所以 zygote 快照可能 ≠ 当时的 live 属性。卸载后看到“设置页 10-01 但 grtpeorp 11-05”就是这个原因。
- **因此本模块写的值必须与 OMK/PIF 一致**（现在是 `2026-11-05`），
  否则会出现 native ≠ Java 快照，`audit` 会报“与 zygote 快照不一致”，且会掉 PI。
  这也是当时把值改成 `10-05` 反而掉 PI 的根因。
- **护栏不能定得太死**：`max_ahead=0` 把“选下个月”也拒了；默认已改为 **1**，
  且失败时现在会返回非 0 + WebUI 弹红横幅。

## 待办

1. ~~全新安装链路验证~~（已完成，见上）
2. 可选：WebUI 的日期选择器直接限制可选范围（与 max_ahead 联动）
3. 可选：`audit` 输出排版

## 关键设计约束（改代码前先确认）

1. `ro.*` 只能改内存（resetprop），**绝不** `-p`、**绝不**凭空创建属性
2. 设置页那一行 = **zygote 启动时快照**；改完必须重启或 `refresh`
3. 属性名里的 `.` 在 grep/sed 里是通配符 → 统一用 `lib.sh` 的 `kv()` / `conf_file()`
4. `comm` 是脚本名（`watchd.sh`）不是 `sh`；不能把“自己的子进程”排除掉（`setsid` 原地 exec）
5. 配置读取必须**每次动态定位**（`conf_file()`），不能在 source 时定死
