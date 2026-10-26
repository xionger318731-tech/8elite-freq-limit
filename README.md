# 8elite限频

> 针对高通骁龙 8 至尊版（SM8750 / SM8850）的**动态 CPU 限频模块**
> KernelSU / APatch 模块 · 不改调度器 · 卸载零残留

天花板跟着实际负载走：**CPU 需要多少就给多少 + 一点余量**。
静止时锁 748MHz，需要时自动抬到官方上限。

---

## 这是什么

官方调度（Qualcomm perf HAL）会给出远超实际需求的 CPU 频率上限。
实测：刷微信时 CPU 真正只需要 **0.78 ~ 1.03 GHz**，而官方上限给的是 **2.4 ~ 3.5 GHz**。

这个模块做的事很简单：

```
天花板 = 实际需求 × 余量
```

需求低就压低（省电），需求高就抬高（保流畅），全程自动。

**它不做的**：
- 不替换官方调度器（walt 保持原样）
- 不修改任何调度参数
- 不碰 `msm_performance`（那是官方 perf HAL 的地盘）
- 不写系统设置

---

## 实测效果

### 省电

| 场景 | 大核上限 | 电流 |
|---|---|---|
| 官方调度 | 3.07 GHz | 395 mA |
| 本模块（静止） | 748 MHz | **150 mA** |

**静止场景省电 62%**

### 流畅度

| 大核上限 | 冷启动耗时 | 相对 |
|---|---|---|
| 官方 2.4G | 441 ms | 基准 |
| **2.4G（本模块冷启动保护）** | **431 ms** | **比官方还快** |
| 2.0G | 536 ms | 1.22x |
| 1.78G | 584 ms | 1.32x |
| 1.15G | 678 ms | 1.54x |
| 384M | 2265 ms | 5.1x |

冷启动保护锁在 **2.4 GHz 实测无损点**，所以应用启动不受影响。

### 开销

- CPU：**0.165%**（系统总量）
- 内存：4 MB
- 唤醒：1 秒一次

---

## 工作原理

### 五个状态

```
idle    需求 < 阈值持续 2s           → 锁 748800（最低）
boost   需求 ≥ 天花板 95%(eco)       → 阶梯升 2 档
rich    需求 < 天花板 80%(eco) 持续1s → 降到 需求×余量
hold    中间地带                     → 保持不动
launch  前台切换 15s 内              → 锁 2.4G（无损点）
game    游戏前台                     → 完全不干预
off/hot 熄屏 / 过热                  → 交还官方
```

### 判据

用 **CPU0 的有效平均频率**（从 `time_in_state` 反演）：

```
有效频率 = Σ(档位频率 × 该档驻留时间) / Σ(驻留时间)
```

这是最本质的信号——CPU 实际用了多少，而不是"看起来忙不忙"。

### 三档风格

| 风格 | 余量 | 静止阈值 | 超大核介入 | 适用 |
|---|---|---|---|---|
| `eco` 省电 | 5% | < 1.3 GHz | 2.8 GHz | 续航优先（默认） |
| `balance` 均衡 | 12% | < 1.1 GHz | 2.2 GHz | 日常 |
| `perf` 流畅 | 35% | < 800 MHz | 1.5 GHz | 游戏 / 重载 |

---

## 安装

1. 下载 `8elite_V1.0.zip`
2. KernelSU / APatch 管理器 → 模块 → 从本地安装
3. 重启

装完即用，无需配置。

---

## 使用

### WebUI

KernelSU 管理器里点模块 → 打开 WebUI

可以：
- 查看实时状态（当前场景、需求、天花板）
- 切换省电 / 均衡 / 流畅
- 开关限频
- 一键归还全部限制

### 命令行

```bash
# 查看状态
su -c 'sh /data/adb/eta_sched/ctl.sh status'

# 启动 / 停止
su -c 'sh /data/adb/eta_sched/ctl.sh start'
su -c 'sh /data/adb/eta_sched/ctl.sh stop'

# 切换模式
su -c 'sh /data/adb/eta_sched/ctl.sh mode auto'    # 启用
su -c 'sh /data/adb/eta_sched/ctl.sh mode learn'   # 关闭（交还官方）

# 强制归还
su -c 'sh /data/adb/eta_sched/ctl.sh release'

# 日志
su -c 'sh /data/adb/eta_sched/ctl.sh log'
```

### 配置文件

`/storage/emulated/0/Android/8elite/config.conf`

```ini
mode=auto        # auto 启用 / learn 只观察
enabled=1
style=eco        # eco / balance / perf
```

---

## 卸载

管理器里移除即可。卸载脚本会：

1. 先杀 watchdog（切断自愈，否则它会 60 秒后把守护拉回来）
2. 停主守护
3. `cooling_device` 归 0（等价于官方原样）
4. 修复节点权限
5. 删除数据目录

**实测验证：卸载后残留进程 0 个，频率完全回到官方状态。**

---

## 兼容性

| 项目 | 支持 |
|---|---|
| 芯片 | 骁龙 8 至尊版 SM8750 / SM8850 |
| 系统 | Android 14+（ColorOS / HyperOS 等） |
| Root | KernelSU / APatch（Magisk 未测） |
| 冲突 | 不要与其他限频 / 调度模块同时使用 |

**为什么不要叠加**：多个模块同时写 `cooling_device` 会互相覆盖，结果不可预测。

---

## 技术细节

### 写入通道

用 `thermal/cooling_device` 而不是直接改 `scaling_max_freq`：

```
/sys/class/thermal/cooling_device3/cur_state  → policy0 (cpu0-5)
/sys/class/thermal/cooling_device4/cur_state  → policy6 (cpu6-7)
```

原因：

1. **原生可写**，不需要 chmod 绕过权限
2. **语义安全**：state=0 就是"不干预"，卸载时归 0 即可，不需要记住原值
3. **不和官方打架**：官方热管理也用这个通道，它会在温度高时自己接管

最终生效上限 = `min(msm_performance, cooling_state 映射值)`。

### 官方天花板跟随

官方 perf HAL 每 5–10 秒动态改写 `msm_performance`：

```
日用态  0:2400000  6:1689600
性能态  0:3072000  6:3513600
峰值态  0:3532800  6:4320000
```

模块每次都读当前值作为上限参考。**目标 ≥ 官方天花板时自动让路**（state 归 0），
所以永远不会试图"放宽"官方限制。

### 温度保护

大核温度 ≥ 72°C → 完全交还官方（避免和官方热管理冲突）。

---

## 已知限制

- **只统计 CPU0**：`time_in_state` 在本机只累计 policy 首核。这是特性也是限制——CPU0 是主核，UI 线程倾向在此，但不代表全部负载。
- **超大核在 eco 模式常关**：这省电但也意味着单核性能受限。需要单核爆发力时切 `perf`。
- **游戏完全不干预**：`games.list` 命中的包名一律交还官方。如果你想让游戏也省电，把包名从 `games.list` 删掉即可。

---

## 开发记录

这个模块的开发过程比较曲折，几个被实测推翻的假设记录在 [docs/NOTES.md](docs/NOTES.md)：

- ❌ 用 `run_delay` 判断"算力不足" —— 实测它只反映调度竞争，与频率无关
- ❌ 用 `gfxinfo` 掉帧率做反馈 —— 单次调用要 5 秒，占空比 50%，反而制造卡顿
- ❌ 用触摸事件判断"静止" —— 本机触摸屏有幽灵事件，30 秒 20 次误报
- ✅ 用 CPU 有效频率 —— 便宜（2ms）、本质、不受噪声干扰

---

## 作者

**罗霄山**

## 许可

MIT
