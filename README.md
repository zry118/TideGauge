# 潮汐表 TideGauge

**当前版本 1.4**（构建 6）

菜单栏系统监控：常驻显示 CPU / 内存 / 网络流速，点开是一块 60 秒滚动曲线 + 进程榜。

零权限 —— 只读系统计数器（`host_processor_info` / `host_statistics64` / `sysctl` /
`getifaddrs` / `proc_pid_rusage`），不碰辅助功能、不碰屏幕录制，没有任何授权弹窗。

## 下载

到 [Releases](../../releases) 页面下载最新版 **TideGauge-1.4.zip**，解压后把
`TideGauge.app` 拖进「应用程序」文件夹，打开即在菜单栏常驻。

首次启动 macOS 会拦截（个人开发者没有 $99/年的 Apple 公证）：右键点
app 图标 →「打开」→ 在弹窗里再点一次「打开」即可，之后照常启动。
也可以终端里跑一次 `xattr -cr /Applications/TideGauge.app` 永久放行。

- 系统要求：macOS 14.0+，**Apple Silicon**（M 系列芯片）
- 零权限、零依赖、不联网——只读系统计数器，没有任何授权弹窗

## 版本记录

- **1.4** — 新增「状态栏图标」开关：关掉后只显示文字，状态项再窄约 19pt；
  固定宽度内边距改为探针实测值（带图标 38pt / 纯文字 20pt），
  修正 1.3 公式在极端网速下可能截断一个字符的问题
- **1.3** — 收紧固定宽度：最宽值贴现实（网速 99.9M / 容量 999.9G），
  只开网速约 131pt、默认三项约 231pt，比 1.2 省 16~18pt
- **1.2** — 修复菜单栏只显示图标不显示文字（MenuBarExtra 限制，改 NSStatusItem）；
  固定宽度防图标抖动
- **1.1** — 菜单栏显示项配置：CPU/内存/网络/磁盘/负载开关、网速样式、刷新间隔
- **1.0** — 初版：菜单栏监控、60 秒曲线、进程榜

## 用法

```
open TideGauge.app          # 菜单栏常驻，点图标开面板
TideGauge --selftest        # 43 项自检（含真实系统计数器冒烟）
TideGauge --render out.png  # 离屏渲染面板图（假数据，确定性输出）
TideGauge --render out.png --settings   # 离屏渲染设置页
```

## 界面

- 菜单栏：`20%  7.5G  ↑198K↓510K`（显示项、顺序、网速样式、图标均可配置）
- 面板 320×580，头部齿轮切换设置页：
  - **菜单栏显示**：CPU / 内存 / 网络 / 磁盘 / 负载逐项开关
  - **状态栏图标**：关掉后菜单栏只留文字（预览区同步显示效果）
  - **网速样式**：双向 / 仅下载 / 仅上传
  - **刷新间隔**：1 / 2 / 3 / 5 秒
  - **菜单栏预览**：实时预览拼装效果
  - 设置写 UserDefaults（`tg.*`），重启后保留
- 主面板：四张数据卡 + CPU 60 秒曲线 + 网络双线 + 进程榜前 8
- 底部：开机启动开关 + 退出

## 数据口径

| 指标 | 来源 | 说明 |
|---|---|---|
| CPU% | `host_processor_info` + `PROCESSOR_CPU_LOAD_INFO` | 全核汇总，Δbusy/Δtotal |
| 内存 | `host_statistics64` + `HOST_VM_INFO64` | 已用 = 应用 + 联动 + 压缩（活动监视器口径） |
| 网络 | `getifaddrs` + `if_data` | 只统计 `en*` 物理网卡，排除 lo0 / 桥接 |
| 进程 | `sysctl(KERN_PROC_ALL)` + `proc_pid_rusage` | 增量 CPU%（可超 100%，多核累加） |
| 磁盘 | `statfs("/")` | f_bavail × f_bsize |
| 运行时长 | `sysctl(CTL_KERN, KERN_BOOTTIME)` | |
| 负载 | `getloadavg` | 1 分钟 |

## 实现要点

**采样器依赖注入。** 所有系统调用收进 `Sampler` 的一组闭包，真 app 接系统计数器，
自检和渲染接确定性假数据（LCG 伪随机）。核心逻辑 —— 差值换算、环形缓冲、
排序截断、格式化 —— 不碰真实系统也能完整测试。

**tick(at:) 时间注入。** 速率 = Δbytes/Δt，紧密循环调用 tick() 会把 dt 钳到 1ms、
速率爆表 500 倍。`tick(at:)` 让自检和渲染按 1 秒间隔灌数据，输出才可信。

**NSStatusItem + NSPopover，不是 MenuBarExtra。** 声明式 SwiftUI 菜单栏场景
（MenuBarExtra）写起来更短，但实测在这个 macOS 版本上它的
`Label(title, systemImage:)` **只渲染图标、不渲染文字**（最小复现验证过），
菜单栏状态根本显示不出来。改用 NSStatusItem：`button.image` 挂 template 图标、
`button.title` 挂状态文字，指标变化时经 `objectWillChange` 订阅异步更新
（willSet 时读到的是旧值，要 `DispatchQueue.main.async` 到下一周期再读）。

**固定宽度防抖动。** `NSStatusItem.variableLength` 会让按钮宽度跟着文字涨落，
后面的系统图标被推着晃。改成按当前配置的**最宽可能文本**（`MenuLabel.widestText`）
测量出固定 length：数字再变，按钮宽度不变，图标钉死在原位。
显示项 / 图标开关变化时经 Config 订阅重算 length（同时换/摘图标）。
内边距是探针实测值：带图标 = 文字宽 + 38（20 按钮内边距 + 18 图标），
纯文字 = 文字宽 + 20，再 ×1.06 余量。等宽数字字体（monospacedDigit）会被
系统忽略，别费那劲——固定宽度已经解决抖动。

## 已知坑（都踩过）

1. **`host_statistics` + `HOST_CPU_LOAD_INFO` 在新系统上不可用**：只返回一个核的数据，
   且 `cpu_ticks` 字段顺序与文档不符，idle 恒为 0 —— 会让 CPU% 永远显示 100%。
   必须用 `host_processor_info`。
2. **`host_processor_info` 的参数位次**：第三个参数是「处理器数」，第五个才是
   integer_t 元素数。搞反了会按元素数当核数遍历（越界读 4 倍内存），
   `vm_deallocate` 也会少释放。
3. **`cpu_ticks` 顺序是 user/system/idle/nice**，不是 user/nice/system/idle。
4. **`vm_statistics64` 的字段是 `wire_count`**，没有 `wired_count`。
5. **`proc_pid_rusage` 第三个参数是 `rusage_info_t*`（void\*\*）**，Swift 导入成
   `UnsafeMutablePointer<UnsafeMutableRawPointer?>`，直接 `&ri` 编译不过，
   要 `withMemoryRebound` 重绑定。`ri_user_time` 是 uint64 纳秒，不是 timeval。
6. **`Font.Design` 没有 `monospacedDigit`**，只有 `.monospaced`。
7. **`Text("\(int)")` 会走 LocalizedStringKey**，1990 渲染成 "1,990"。
   所有数值先转 String 再进 Text（Fmt 的全部返回值都是 String）。
8. `SMAppService` 要 `import ServiceManagement`；登录项服务名是 `.mainApp`（旧名 `.mainAppService`）。
9. 离屏渲染画不了会碰系统服务的控件，渲染模式下开机启动开关退化为纯文本。
10. **`Picker(.segmented)` 也是 ImageRenderer 画不出的**（黄色禁止符号）。
    菜单栏类应用的分段选择一律用自制按钮实现，渲染和真机一致。
11. **`@Published` + `didSet { save() }` 的类，init 里逐个属性赋值会把半初始化状态写回**：
    interval 加载前还是默认值 1.0，第一次赋值触发 didSet → save() 就把 1.0
    覆盖了已存的 2.0。加 `isLoading` 护栏，init 结尾才置 false。
12. 菜单栏文本拼装是纯函数（`MenuLabel.text(...)`），配置断言全部走它，
    不依赖 UI。
13. **`MenuBarExtra` 的 Label 只显示图标不显示文字**（本机 macOS 27.x 实测，
    最小复现确认，非代码问题）。菜单栏要显示状态文字必须用 NSStatusItem。
    这条推翻了 README 早期"MenuBarExtra 是菜单栏应用的正解"的结论 ——
    MenuBarExtra 适合只有图标+菜单的场景，要状态文字就走 NSStatusItem。

## 验证

- `--selftest` 47/47 通过（连续两次运行可重复）：环形缓冲封顶、排序、自身进程排除、
  确定性输出、7 组格式化断言、9 组真实系统计数器冒烟、19 组配置与菜单栏文本断言
  （逐项开关、图标开关、三种网速样式、持久化往返、极端值不超最宽文本、
  固定宽度公式数值、自检后恢复默认）
- 打包后真实启动验证：菜单栏进程驻留、无 Dock 图标、无崩溃
- **菜单栏状态文字经真实菜单栏实截确认**：图标开 ` waveform ↑10K↓31K`、
  图标关 `↑3K↓16K`，两种模式均无截断（截图时需先唤出自动隐藏的菜单栏）
- 面板渲染图：`screenshot-panel.png`；设置页渲染图：`screenshot-settings.png`

## 已知边界

- 最宽取值贴现实：容量 999.9G（1TB）、网速 99.9M（≈100MB/s）、负载 99.99。
  单项超出会多 1 个字符，6% 余量能兜一个方向；收发同时超 100M/s 会轻微截断，
  macOS 不会换行或撑宽按钮
- 固定宽度按最宽可能值预留，实际文字短时按钮内右侧有留白（图标位置因此稳定，
  这是刻意取舍）。1.4 起只开网速：带图标约 144pt、纯文字约 125pt
