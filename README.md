# 8elite限频

> 骁龙 8 至尊版（SM8750 / SM8850）动态 CPU 限频模块
> KernelSU / APatch · 不改调度器 · 卸载零残留

天花板跟着实际负载走：**CPU 需要多少就给多少 + 一点余量**。
静止锁 748MHz，满载 0.5 秒内升到 2.7GHz。

---

## 实测效果

| 项目 | 数值 |
|---|---|
| 静止（桌面） | 大核 748MHz / 超核 1017MHz |
| 静止电流 | 150 mA（官方 395 mA），**省电 62%** |
| 满载升档 | 960MHz → 2745MHz，**482ms** |
| 冷启动 | 431ms（官方 441ms，几乎无损） |
| 模块开销 | 0.3% 系统 CPU，4MB 内存 |

---

## 原理

**判据：CPU 使用率**（时间维度，不受限频影响）

实测：不同上限下 8 核满载使用率恒为 100%，空载 20–50%。
这比"有效频率"可靠——后者在被压到 748MHz 后，满载和空载看起来一样。

**公式：目标频率 = 当前频率 × (使用率 / 目标使用率)²**

用平方而非线性，因为饱和说明严重不足：

```
使用率 100%, 目标 50% → 4.0x  翻四倍
使用率  70%, 目标 50% → 1.96x 翻倍
使用率  50%, 目标 50% → 1.0x  不变
使用率  30%, 目标 50% → 0.36x 降档
```

**响应策略**：升档立即执行（防卡），降档累积 8 次确认（防抖）。

---

## 状态

```
idle      需求低           → 锁 748800
boost     使用率超目标     → 立即升档（平方换算）
rich      使用率低于目标   → 累积确认后降档
hold      中间地带         → 保持
launch    切到新应用 15s   → 锁 2.4G（实测无损点）
game      游戏前台         → 完全不干预
off/hot   熄屏 / 过热      → 交还官方
```

---

## 三档风格

| 风格 | 超大核 | 适用 |
|---|---|---|
| `eco` 省电（默认） | 常关，最省电 | 续航优先 |
| `balance` 均衡 | 大核到 1.8G 才介入 | 日常 |
| `perf` 流畅 | 更早介入 | 游戏 / 重载 |

WebUI 里切换。

---

## 安装

1. 下载 `8elite_V1.2.zip`
2. KernelSU / APatch 管理器 → 模块 → 从本地安装
3. 重启

装完即用，无需配置。

---

## 使用

**WebUI**：管理器里点模块 → 打开 WebUI，可看实时状态、切风格、开关限频。

**命令行**：

```bash
su -c 'sh /data/adb/eta_sched/ctl.sh status'   # 状态
su -c 'sh /data/adb/eta_sched/ctl.sh mode learn'  # 关闭（交还官方）
su -c 'sh /data/adb/eta_sched/ctl.sh release'  # 强制归还
```

**配置**：`/storage/emulated/0/Android/8elite/config.conf`

```ini
mode=auto        # auto 启用 / learn 只观察
style=eco        # eco / balance / perf
target_load=50   # 目标使用率，越低越激进
```

---

## 卸载

管理器里移除即可。实测零残留：

```
残留进程: 0
运行目录已删除
数据目录已删除
cooling: 0 / 0
大核: 3532800（= cpuinfo_max，完全放开）
```

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

- **只统计 CPU0**：`time_in_state` 在本机只累计 policy 首核。CPU0 是主核，UI 线程倾向在此，有代表性但不代表全部负载。
- **eco 模式超大核常关**：省电但单核性能受限，需要爆发力时切 `perf`。
- **游戏完全不干预**：`games.list` 命中的包名一律交还官方。

---

## 开发记录

开发过程中被实测推翻的三个方案记录在 [docs/NOTES.md](docs/NOTES.md)：

- ❌ `run_delay` 判断算力不足 —— 只反映调度竞争，与频率无关
- ❌ `gfxinfo` 掉帧率做反馈 —— 单次 5 秒，占空比 50%，反造卡顿
- ❌ 触摸事件判断静止 —— 幽灵触摸 30 秒 20 次误报
- ✅ CPU 使用率 —— 2ms 读取，不受噪声干扰

---

## 作者

**罗霄山** · MIT License
