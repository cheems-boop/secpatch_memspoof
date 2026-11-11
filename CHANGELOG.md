# 更新日志

## [v1.4.1] - 2026-11-11

真机跑完整链路（卸载 → zip 重装 → 重启 → 改配置 → 再升级）时发现的问题。

### 修复
- **`max_ahead=0` 把“选下个月”也拒了**：用户想让它看起来更新，选 `2026-12-05` 正好超前 1 个月，
  被当成“一眼假”而拦截。默认改为 **1**（允许选到下个月），超前 2 个月以上才拦。
- **失败静默**：`setconf -a` 即使 apply 全失败也返回 0，除了日志以外没有任何提示
  → 现在 apply 失败时 `setconf` 返回 **1** 并打印原因与日志尾；WebUI 据此弹红色横幅。
- **被拦后不兜底**：apply 全程失败时一条都不写，vendor 反而留在真值，
  造成 “system≠vendor” 这个更明显的破绽 → 新增 `[HINT]` 汇总行，直接给出行动建议。

### 已验证（真机）
- 卸载 → 重启：模块目录 / 用户层配置 / 守护进程 全部清干净；
  vendor 回真值 10-01，system 仍 11-05（由 Oh My Keymint 维持），设置页显示 10月1日
- zip 安装 → 重启：权限 755 正确、baseline=2026-10-01、快照=11-05、
  守护单实例、`audit` 高危 0 / 中危 0，设置页显示 11月5日
- 改配置为 12-05 → 重装 zip → 重启：**用户层配置未丢**，日期仍为 12-05

## [v1.4] - 2026-11-11

以「读代码 + 在真机上复现」的方式做了一轮完整修 bug，累计 30+ 项。按类别：

### 修复 —— 正则当字面（8 处）
属性名里的 `.` 在 `grep`/`sed` 里是通配符，可能匹配到别的属性。
统一改成 `awk` 精确比对（`lib.sh` 的 `kv()`）：

- `cfg()` / `disk_val()` / `pif_val()`
- `audit.sh`（读基线、读快照）、`patchctl diff`、`restore.sh`、`state.sh`、`action.sh`
- `setconf.sh`：从 `grep` + `sed -i` 改为 `awk` 逐行重写（也不再整行误改）
- `patchctl guard` / `guard-action`：改为调用 `setconf.sh`

### 修复 —— 守护进程（10 处）
- Android 的 mksh 会把进程名改成脚本名（`comm=watchd.sh`），白名单漏了它 → 永远扫不到实例
- 命令替换的子 shell 继承同样 cmdline → 守护把自己当成已有实例而自杀
- 修上一条时加的「排除子进程」规则**误杀新守护**（`busybox setsid` 是原地 exec，PPID 就是调用者）
- `trap '...' EXIT INT TERM` 收到 TERM 只删 pidfile 不退出 → `kill` 无效、`restart` 杀不掉
- `patchctl status` 用 `*watchd.sh*` 通配 → 把执行它的 `sh -c <脚本>` 当实例打印
- `/proc/*/comm` 进程退出竞态刷错
- `watchd_alive` 从「pidfile + 扫描」改为「只认 pidfile」（避免自匹配）
- `guard_interval` 填非数字时 `[ -ge ]` 报错刷屏 → 强制归一
- `guard_action=report` 时每 30 秒记一行漂移日志 → 改为按漂移内容去重，并在恢复时记一行
- 补上之前只在日志里提过、实际不存在的 `patchctl restart`

### 修复 —— 日期与配置校验（5 处）
- `is_date` 只校格式 → 补上月/日范围（`2026-13-05`、`2026-00-10` 现在会被拒）
- `max_ahead` 误拦 `ref:pif`（PIF 更新到更新的补丁月时模块会静默失效）→ 只对写死的日期生效
- `verify.sh` 对无法解析的配置值 `continue` 跳过 → 现在计入漂移并报原因
- `setconf.sh` 给不存在的属性写配置 → 提前警告
- `prop.conf` 里的 TYPO 修正

### 修复 —— 路径与一致性（5 处）
- `MODDIR` 推导：从错误的 cwd 启动时会在错误目录建 `log/` → 改为「目录里必须有 `prop.conf` 才认」
- `refresh.sh` 杀 zygote 后不重建快照 → `audit` 误报不一致；现在等新 zygote 就绪后自动重建
- `refresh.sh` 不检查 `apply.sh` 结果就杀 zygote → 现在 apply 失败就放弃
- `patchctl reset` **不持久**：只写内存，配置仍是 `ref:pif`，守护一小时后把伪装写回来（实测复现）
  → 改为 `restore.sh --persist` 同时把配置改成 `ref:disk`；新增 `patchctl on` 恢复
- `sync-pif` 只改一份 pif.prop，且备份无限积累 → 两份都改，备份只留最近 3 份

### 修复 —— 其他
- `service.sh` 拉起守护后不自检 → 加 3 秒后校验并写日志
- `uninstall.sh` 依赖 `ps` 找进程 → 改用 pidfile + `/proc` 精确匹配，TERM 后再补 `-9`
- `audit.sh` 把「不在 build.prop 里」判为高危 → 降为中危（可能是运行期属性）
- 性能：逐进程 `tr` 扫 1061 个进程要 **10 秒** → `comm` 内建预筛后 **0 秒**

### 修复 —— 安装与升级（4 处）
- **升级会覆盖用户配置**：KSU 装新版是整目录替换，`prop.conf` 会被打回默认
  → 用户配置改存 `/data/adb/secpatch_memspoof.conf`（模块目录外），升级不丢；卸载时一并清理
- **zip 里的可执行位丢失** → 模块直接执行的脚本会 `Permission denied`
  → `post-fs-data.sh` / `service.sh` 开头 `chmod 755` 自愈（实测 644 → 可执行）
- **无 `resetprop` 时守护仍启动** → 每 30 秒报一次漂移且重写永远失败
  → `service.sh` 检测不到 `resetprop` 就不启动守护，并写明确日志
- **`sync-pif` 只改一份 pif.prop** → 两份都改；备份只留最近 3 份

### 修复 —— 配置源一致性（3 处）
- **`CONF` 在 source 时只解析一次** → 用户第一次改配置创建了用户层文件后，
  长命的守护仍盯着旧文件，之后的配置变更（包括 `guard=off`）全收不到
  → 新增 `conf_file()` 动态解析，`cfg()` / `conf_keys()` / `sig()` / `apply.sh` 全部改用它
- `pif_val` 不去尾随空格 → `SECURITY_PATCH=2026-11-05 ` 会让整条规则被跳过
- `patchctl show` 显示的配置路径是启动时的快照 → 改为动态解析后的真实路径

### 新增
- `bin/audit.sh`：痕迹自查（快照一致性 / 未来日期 / 补丁时效 / PIF 口径 / 列对一致 / 落盘 / 可见性）
- `bin/setconf.sh`：带校验的安全改配置
- `bin/state.sh`：机器可读状态（WebUI 数据源）
- `bin/snapshot.sh`：记录 zygote 启动时的值（一致性基准）
- `patchctl on` / `patchctl restart`
- WebUI 的「接口诊断」：自动尝试 4 种 `ksu.exec` 调用姿势并打印 `ksu` 方法列表
- WebUI 表格改成「属性名占一行 + 三个值一行」，窄屏不再断字

## [v1.3] - 2026-11-11

### 新增
- **WebUI**（`webroot/index.html`）：图形配置界面
- `action.sh` 改为输出状态表
- `prop.conf` 顶部写明「最省心的改法」

### 修复
- WebUI 的 `ksu.exec` 第二参数必须是 JSON **字符串**，第三参数必须是**全局函数名**（传对象/函数会抛 Java 异常或无回调）
- `action.sh` 的 awk 解析把 key 按 `.` 切碎

## [v1.2] - 2026-11-11

### 新增
- 漂移守护（定期校验 + 自动重写）、月度自动推进
- 受保护属性黑名单（不碰 PIF 管的属性）
- `baseline` 真值快照
- `patchctl doctor` / `diff` / `sync-pif`

### 修复
- `flock`/`sha256sum`/`setsid` 只是 busybox applet，没有独立软链 → 守护静默退出

## [v1.1] - 2026-11-11

首个可用版本：
- `post-fs-data.sh` 在 zygote 启动前写入（这是让设置页变化的唯一时机）
- `service.sh` 开机补写 + 拉起守护
- `patchctl apply/refresh/reset`、审计日志、日志轮转
- 自动接管 Termux 工具链
