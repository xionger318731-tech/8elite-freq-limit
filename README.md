# 8elite限频

> 骁龙 8 至尊版（SM8750 / SM8850）动态 CPU 限频模块
> KernelSU / APatch · 不改调度器 · 卸载零残留

天花板跟着实际负载走：**CPU 需要多少就给多少 + 一点余量**。
静止锁 748MHz，需求上来时按需抬到官方上限。

**V1.3 起控制律整体重写为「双判据容积伺服（DCS）」**——旧版的平方律是乘性随机游走，会被节点回读和 `oiface` 抢写带偏；新版改用绝对量判据 + 不饱和判据。

**V1.4fix 修掉三类致命 bug**（详见 [docs/NOTES.md](docs/NOTES.md) 第九节）：
- 守护进程被 KernelSU 管理器的 app cgroup 冻结 → WebUI 报"服务未运行"、watchdog 反复错杀堆叠实例
- `map_big.conf` / `map_prime.conf` 是**凭空写的假表**（声称 748800 不存在、超大核压不下去），已按实测重写
- `/system/bin/sh` 是 32 位算术，频率 × 千分比系数会溢出成负数，满载反而降频

---

## 原理（V1.3 · DCS）

三条独立的量，各管一件事：

**① 需求密度前馈（绝对量，cap-invariant）**

```
need = 忙时平均频率 × 利用率 / 目标占用
```

不拿回读节点当基准，所以不会随节点漂移；`oiface` 抢写也不影响判据。

**② 撞顶率伺服（不饱和判据）**

```
cap = need × (1 + K × (撞顶率 − 死区))
```

撞顶率 = 一个窗口里 CPU 跑在接近天花板频率的时间占比。
CPU 使用率在负载侧会饱和（满载恒 100%，分不清"需要 2G"和"需要 3.5G"），撞顶率不会。

**③ 整机功耗外环**

`|current_now| × voltage_now / 1e6` 读整机功耗，在 **35–75%** 区间自动整定"目标占用"，消灭魔法常数，换机型不用重标。WiFi / 数据两套预算。

**另外三件抗抖动的设计**

- **内部权威 cap 副本**：节点值只用于对账，不作为迭代基准
- **按包学习稳态 cap**：切回应用直接回到上次稳态，没有重收敛过程
- **触摸 / 冷启动瞬时抬频**：毫秒级感知，替代旧版固定 15s 锁 2.4G 的浪费窗口

**只压频率上限，不关核心。**

8 个核心始终全部在线（`online: 0-7`），模块只调整每个簇的最高频率。
不写 `core_ctl`、不写 `cpuN/online`，核心数量始终由官方调度决定。

---

## 状态

```
init        初始化
boot        开机保护（前 60s 不干预）
disabled    已关闭（mode=learn / enabled=0）
off         熄屏            → 交还官方
charging    充电            → 放开
panic       过热（≥90°C）   → 彻底让路
rich_wait   升档待确认
boost       需求逼近        → 升档
hold        跟随中 / 交互中 → 保持
save        富余            → 降档省电
rich        需求富余（累积确认中）
```

---

## 参数（都可被 `config.conf` 覆盖）

| 参数 | 默认 | 含义 |
|---|---|---|
| `window_ms` | 200 | 决策窗口，静置时自动拉伸到 500ms |
| `target_load` | 50 | 目标占用%，由功耗外环在 35–75 内整定 |
| `sat_hi` / `sat_lo` | 300 / 60 | 撞顶率死区（‰） |
| `k_up` / `k_dn` | 1200 / 600 | 伺服上行 / 下行增益（×1000） |
| `floor_big` / `floor_prime` | 748800 / 1017600 | 各簇地板频率 |
| `prime_on` / `prime_off` | 2000000 / 1500000 | 超大核 engage / release 阈值（双阈值迟滞） |
| `pwr_budget` / `pwr_budget_wifi` | 2200 / 2700 | 整机功耗预算 mW |
| `touch_floor` | 1363200 | 触摸期间大核下限 |
| `launch_ms` | 2500 | 冷启动保护窗口 |

内置的响应约束：升档 2 tick 确认、降档 8 tick 确认，单 tick 最多 +50% / −25%；温度 ≥62°C 起软增益，≥82°C 压到 55% 增益，≥90°C 彻底让路。

---

## 三档风格

| 风格 | 目标占用 | 适用 |
|---|---|---|
| `eco` 省电（默认） | 基准 −5% | 续航优先 |
| `balance` 均衡 | 基准不变 | 日常 |
| `perf` 流畅 | 基准 +20% | 游戏 / 重载 |

WebUI 里切换。

---

## 安装

1. 下载 `8elite_V1.4fix.zip`
2. KernelSU / APatch 管理器 → 模块 → 从本地安装
3. 重启

装完即用。map 表已按本机实测写入；**换机型**才需要跑 `probe.sh` 重新校准。

---

## 使用

**WebUI**：管理器里点模块 → 打开 WebUI，可看实时状态（需求频率 / 撞顶率 / 整机功耗 / 目标占用）、切风格、开关限频。

**命令行**：

```bash
su -c 'sh /data/adb/eta_sched/ctl.sh status'        # 状态
su -c 'sh /data/adb/eta_sched/ctl.sh mode learn'    # 关闭（交还官方）
su -c 'sh /data/adb/eta_sched/ctl.sh release'       # 强制归还
su -c 'sh /data/adb/eta_sched/probe.sh'             # 环境探针 / map 校准
```

**配置**：`/storage/emulated/0/Android/8elite/config.conf`

```ini
mode=auto        # auto 启用 / learn 只观察
style=eco        # eco / balance / perf
target_load=50   # 目标占用基准，越低越激进
```

---

## map 表（已实测校准）

两张表都是在本机逐档写 `cur_state` 后读回 `scaling_max_freq` 得到的真值，不是推测：

```
大核  cooling_device0: state 0..15 → 3072000 ... 1152000, 960000, 748800, 556800, 384000
超核  cooling_device1: state 0..15 → 3513600 ... 1958400, 1689600, 1401600, 1209600, 1017600
```

`state 0` 是**该 cooling 允许的最高档**，不是"不干预"。

**换机型 / 换系统版本后必须重跑 `probe.sh`**：它会逐档写 `cur_state` 并打印真实频率，
按输出替换两个 map 文件即可。`probe.sh` 同时检查 `time_in_state` 可用性
（DCS 主数据源，缺失则降级为轮询 `scaling_cur_freq`）、功耗节点、温区、抢写进程。

---

## 卸载

管理器里移除即可。cooling 归 0 = 内核「不干预」语义，不需要记住原值再还原：

```
残留进程: 0
运行目录已删除
数据目录已删除
cooling: 0 / 0
```

从未写入 `msm_performance` / `scaling_max_freq` 的值 / `settings`。
卸载后最终频率 = 官方 `msm_performance` 的值，官方 perf HAL 每 5–10 秒自己调整属正常行为。

---

## 兼容性

| 项目 | 支持 |
|---|---|
| 芯片 | SM8750 / SM8850 |
| 系统 | Android 14+ |
| Root | KernelSU / APatch |
| 冲突 | **不要**与其他限频 / 调度模块同时使用 |

---

## 技术说明

**写入通道**用 `thermal/cooling_device`，不是 `scaling_max_freq`：

```
/sys/class/thermal/cooling_device3/cur_state  → policy0 (cpu0-5)
/sys/class/thermal/cooling_device4/cur_state  → policy6 (cpu6-7)
```

原因：原生可写、语义安全（state=0 就是不干预，卸载归 0 即可）、不和官方热管理打架。

**官方天花板跟随**：每次读 `msm_performance` 当前值，目标 ≥ 官方上限时自动让路（state 归 0），永不试图放宽官方限制。

最终生效上限 = `min(msm_performance, cooling_state 映射值)`。

---

## 已知限制

- **只统计 policy 首核**：`time_in_state` 在本机只累计 policy 首核。CPU0 是主核，UI 线程倾向在此，有代表性但不代表全部负载。
- **`eco` 风格超大核压在地板 1017600**：核心始终在线（8 核全开），只是频率上限低。需要爆发力时切 `perf`。
- **仍是纯限频模块**：只借用「感知输入」（触摸协程 / 功耗读数 / 网络档位）做限频判据，不引入 cpuset 后台降级、`core_ctl` 等任何调度策略。
- **V1.2 时代的实测数字尚未在 V1.3 上复测**：静止锁 748MHz、写入通道未变，但控制律已重写，功耗与响应曲线需重新测。

---

## 开发记录

被实测推翻的方案、以及每版重写的理由都记在 [docs/NOTES.md](docs/NOTES.md)：

- ❌ `run_delay` 判断算力不足 —— 只反映调度竞争，与频率无关
- ❌ `gfxinfo` 掉帧率做反馈 —— 单次 5 秒，占空比 50%，反造卡顿
- ❌ 触摸事件判断静止 —— 幽灵触摸 30 秒 20 次误报
- ❌ V1.2 的平方律 —— 乘性随机游走 + 判据饱和，两个 tick 就放弃限频
- ✅ CPU 使用率 —— 2ms 读取，不受噪声干扰
- ✅ V1.3 需求密度 + 撞顶率 —— 绝对量 + 不饱和

---

## 作者

**罗霄山** · MIT License
