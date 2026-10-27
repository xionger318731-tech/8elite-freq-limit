#!/system/bin/sh
# =====================================================================
# probe.sh — 8elite 限频 V1.3 上机前置校准工具
#
# 用途：
#   1. 打印 cooling_device 的 state -> 真实 scaling_max_freq 映射表
#      （用作替换 config/map_big.conf / map_prime.conf 的依据）
#      这一步必须做：V1 的 map 表 state0 是 3072000/3513600，
#      而 uninstall.sh 声称 "state 0 = 不干预"，两者必居其一为错
#   2. 检查 time_in_state 是否可用（DCS 算法的主要数据源）
#   3. 检查功耗读数节点是否可用
#   4. 检查是否存在会与自己抢写的其它模块
#
# 用法：  sh probe.sh          # 输出报告到屏幕
#         sh probe.sh > /sdcard/probe.txt
#
# 注意：扫描过程中会临时压低 CPU 上限，约 5-10 秒，结束后自动归 0。
#       全程在 root shell 下执行，勿在跑分时运行。
# =====================================================================

CPUFREQ=/sys/devices/system/cpu/cpufreq
THERMAL=/sys/class/thermal
MSM=/sys/kernel/msm_performance/parameters/cpu_max_freq
BAT=/sys/class/power_supply/battery

_rv=""
get(){ _rv=""; read -r _rv < "$1" 2>/dev/null; }
say(){ echo "$*"; }

say "=============================================================="
say " 8elite DVFS 环境探针"
say " $(date '+%F %T')"
say "=============================================================="
say ""

# ---------- 1. 拓扑 ----------
say "--- 1. CPU 拓扑 ---"
for d in $CPUFREQ/policy*/; do
    [ -d "$d" ] || continue
    get "${d}related_cpus"
    get "${d}scaling_available_frequencies"
    av="$_rv"
    get "${d}cpuinfo_max_freq"
    say "  ${d%/}  cpus=[$(cat "${d}related_cpus" 2>/dev/null)]  hwmax=$_rv"
    say "      avail: $av"
done
say ""

# ---------- 2. msm_performance / 官方天花板 ----------
say "--- 2. 官方天花板 (msm_performance) ---"
if [ -r "$MSM" ]; then
    say "  cpu_max_freq = $(cat $MSM 2>/dev/null)"
else
    say "  [不可读] $MSM"
fi
say ""

# ---------- 3. time_in_state（DCS 主数据源）----------
say "--- 3. cpufreq stats (time_in_state) ---"
for d in $CPUFREQ/policy*/; do
    f="${d}stats/time_in_state"
    if [ -r "$f" ]; then
        say "  [可用] $f"
        say "      $(head -c 200 "$f" 2>/dev/null | tr '\n' ' ')"
    else
        say "  [缺失] $f  -> DCS 将降级为轮询 scaling_cur_freq"
    fi
done
say ""

# ---------- 4. 功耗读数 ----------
say "--- 4. 功耗节点 ---"
for n in current_now voltage_now status capacity; do
    if [ -r "$BAT/$n" ]; then say "  [可用] $n = $(cat $BAT/$n 2>/dev/null)"
    else say "  [缺失] $n"; fi
done
say ""

# ---------- 5. 温区 ----------
say "--- 5. 温区 (type=cpu/soc 优先) ---"
for d in $THERMAL/thermal_zone*/; do
    [ -d "$d" ] || continue
    t=$(cat "${d}type" 2>/dev/null)
    v=$(cat "${d}temp" 2>/dev/null)
    say "  ${d%/}  type=$t  temp=$v"
done
say ""

# ---------- 6. 抢写检测 ----------
say "--- 6. 共存模块 / 抢写风险 ---"
for m in eta_tune x8u_eco eta_sched; do
    [ -d "/data/adb/modules/$m" ] && say "  [存在] /data/adb/modules/$m"
done
say "  直接写 scaling_max_freq 的进程（非本探针）:"
for pid in /proc/[0-9]*; do
    p=${pid#/proc/}
    case "$p" in ''|*[!0-9]*) continue ;; esac
    cmd=$(tr '\0' ' ' < "$pid/cmdline" 2>/dev/null)
    case "$cmd" in
        *probe.sh*) continue ;;
        *eta_tune*|*x8u_eco*|*oiface*|*thermal-engine*|*mi_thermal*) say "    pid=$p  $cmd" ;;
    esac
done
say ""

# ---------- 7. cooling_device 映射真表 ----------
say "--- 7. cooling_device -> 频率映射（校准核心）---"
for d in $THERMAL/cooling_device*/; do
    [ -d "$d" ] || continue
    t=$(cat "${d}type" 2>/dev/null)
    case "$t" in cpufreq-cpu*) ;; *) continue ;; esac

    get "${d}max_state"
    case "$_rv" in ''|*[!0-9]*) mx=0 ;; *) mx=$_rv ;; esac
    [ "$mx" -gt 20 ] && mx=20

    # 关联 policy：state 影响哪个 cluster 的 max
    say ""
    say "  == ${d%/}  type=$t  max_state=$mx =="

    i=0
    while [ "$i" -le "$mx" ]; do
        echo "$i" > "${d}cur_state" 2>/dev/null
        usleep 150000
        line="  state $i :"
        for p in $CPUFREQ/policy*/; do
            [ -d "$p" ] || continue
            line="$line  policy$(basename $p)=$(cat ${p}scaling_max_freq 2>/dev/null)"
        done
        say "$line"
        i=$((i+1))
    done
    echo 0 > "${d}cur_state" 2>/dev/null
done

say ""
say "=============================================================="
say " 校准完成，所有 cooling_device 已归 0"
say ""
say " 请把上面第 7 节的输出整理成 map 文件："
say "   config/map_big.conf   每行 '<state> <policy0的scaling_max_freq>'"
say "   config/map_prime.conf 每行 '<state> <policy6的scaling_max_freq>'"
say ""
say " 判定标准："
say "   若 state0 对应的 policy0 上限 == cpuinfo_max_freq -> 旧表确实错了，"
say "  旧表把最低也说成 3072000，意味着模块从未真正释放过。"
say "=============================================================="
