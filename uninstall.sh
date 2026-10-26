#!/system/bin/sh
# ============================================================
# 8elite限频 卸载 V1.2fix
#
# 【本模块的全部足迹】（审计结果）
#   写入：
#     /sys/class/thermal/cooling_device3/cur_state   ← 唯一功能性写入
#     /sys/class/thermal/cooling_device4/cur_state   ← 唯一功能性写入
#     /data/adb/eta_sched/                           运行目录
#     /storage/emulated/0/Android/8elite/            数据目录
#   从未触碰：
#     msm_performance/cpu_max_freq   官方 perf HAL 地盘
#     scaling_max_freq 的值          只 chmod 回 644
#     settings / 系统数据库           完全没有
#
# 【为什么 cooling 归 0 就等于还原】
#   cooling_device 的 state=0 是内核定义的「不干预」语义。
#   归 0 后，最终上限 = msm_performance 的值，也就是官方自己的值。
#   不需要「记住原值再还原」，所以不存在还原失败的可能。
#
# 【关键顺序】
#   必须先杀 watchdog，否则它 60 秒后把 daemon 拉回来。
# ============================================================

DATA=/data/adb/eta_sched
BASE=/storage/emulated/0/Android/8elite
OBS=$BASE/obs
CD_B=/sys/class/thermal/cooling_device3/cur_state
CD_P=/sys/class/thermal/cooling_device4/cur_state
POL_B=/sys/devices/system/cpu/cpufreq/policy0
POL_P=/sys/devices/system/cpu/cpufreq/policy6
MSM=/sys/kernel/msm_performance/parameters/cpu_max_freq

log(){ echo "[uninstall] $*"; }

# 精确杀：cmdline 必须形如 "sh /data/adb/eta_sched/xxx.sh"
# 不能用 *eta_sched* 模糊匹配，会误杀执行本脚本的 shell
kill_script(){
    local name="$1" n=0 pid pidn cmd
    for pid in /proc/[0-9]*; do
        pidn="${pid#/proc/}"
        case "$pidn" in ''|*[!0-9]*) continue ;; esac
        [ -r "$pid/cmdline" ] || continue
        cmd=$(tr '\0' ' ' < "$pid/cmdline" 2>/dev/null) || continue
        [ -z "$cmd" ] && continue
        case "$cmd" in
            "sh $DATA/$name "*|"sh $DATA/$name")
                kill -9 "$pidn" 2>/dev/null && n=$((n+1))
                ;;
        esac
    done
    [ "$n" -gt 0 ] && log "  终止 $name ×$n"
}

count_left(){
    local n=0 pid pidn cmd
    for pid in /proc/[0-9]*; do
        pidn="${pid#/proc/}"
        case "$pidn" in ''|*[!0-9]*) continue ;; esac
        [ -r "$pid/cmdline" ] || continue
        cmd=$(tr '\0' ' ' < "$pid/cmdline" 2>/dev/null) || continue
        case "$cmd" in "sh $DATA/"*) n=$((n+1)) ;; esac
    done
    echo "$n"
}

# 等官方 perf HAL 接管（它会周期性改写 msm_performance）
# 返回 1 表示已接管（频率等于或接近 cpuinfo_max）
wait_official(){
    local i=0 max_b max_p
    max_b=$(cat "$POL_B/cpuinfo_max_freq" 2>/dev/null)
    max_p=$(cat "$POL_P/cpuinfo_max_freq" 2>/dev/null)
    while [ $i -lt 8 ]; do
        local cur_b cur_p
        cur_b=$(cat "$POL_B/scaling_max_freq" 2>/dev/null)
        cur_p=$(cat "$POL_P/scaling_max_freq" 2>/dev/null)
        # 大核恢复到 cpuinfo_max 的 85% 以上，认为官方已接管
        if [ -n "$max_b" ] && [ -n "$cur_b" ] && [ "$cur_b" -ge $((max_b * 85 / 100)) ]; then
            return 0
        fi
        usleep 500000
        i=$((i+1))
    done
    return 1
}

# ============================================================
log "1/7 停止看门狗（切断自愈，必须第一步）"
kill_script "watchdog.sh"
sleep 1

log "2/7 停止守护进程"
if [ -f "$OBS/daemon.pid" ]; then
    read -r p < "$OBS/daemon.pid" 2>/dev/null
    if [ -n "$p" ] && [ -d "/proc/$p" ]; then
        kill -TERM "$p" 2>/dev/null
        i=0
        while [ $i -lt 10 ]; do
            [ -d "/proc/$p" ] || break
            usleep 200000
            i=$((i+1))
        done
        [ -d "/proc/$p" ] && kill -9 "$p" 2>/dev/null
    fi
fi
kill_script "daemon.sh"

# 兜底：再扫一遍所有本模块脚本（防止历史版本残留）
kill_script "touch.sh"
kill_script "observe.sh"
kill_script "learn.sh"

usleep 600000

# ------------------------------------------------------------
log "3/7 归还 CPU 上限（cooling state 归 0 = 内核语义的不干预）"
echo 0 > "$CD_B" 2>/dev/null
echo 0 > "$CD_P" 2>/dev/null
usleep 400000
log "  cooling: $(cat $CD_B 2>/dev/null) / $(cat $CD_P 2>/dev/null)"

# ------------------------------------------------------------
log "4/7 修复节点权限（模块运行期间可能 chmod 过）"
chmod 644 "$POL_B/scaling_max_freq" 2>/dev/null
chmod 644 "$POL_P/scaling_max_freq" 2>/dev/null

# ------------------------------------------------------------
log "5/7 等待官方 perf HAL 接管（最多 4 秒）"
if wait_official; then
    log "  ✓ 官方已接管"
else
    log "  官方 perf HAL 尚未调整（它每 5-10 秒改写一次，属正常）"
fi

# ------------------------------------------------------------
log "6/7 清理数据目录"
rm -rf "$DATA" 2>/dev/null
rm -rf "$BASE" 2>/dev/null

# ------------------------------------------------------------
log "7/7 最终复核"
sleep 1

LEFT=$(count_left)
MAX_B=$(cat "$POL_B/cpuinfo_max_freq" 2>/dev/null)
MAX_P=$(cat "$POL_P/cpuinfo_max_freq" 2>/dev/null)
CUR_B=$(cat "$POL_B/scaling_max_freq" 2>/dev/null)
CUR_P=$(cat "$POL_P/scaling_max_freq" 2>/dev/null)
MSMV=$(cut -d' ' -f1 "$MSM" 2>/dev/null)
CDBV=$(cat "$CD_B" 2>/dev/null)
CDPV=$(cat "$CD_P" 2>/dev/null)
PERM_B=$(ls -l "$POL_B/scaling_max_freq" 2>/dev/null | awk '{print $1}')
PERM_P=$(ls -l "$POL_P/scaling_max_freq" 2>/dev/null | awk '{print $1}')

echo ""
echo "=============================================================="
echo "  卸载结果"
echo "=============================================================="
echo "  残留进程:   $LEFT"
[ -d "$DATA" ] && echo "  运行目录:   ⚠ 仍在" || echo "  运行目录:   ✓ 已删除"
[ -d "$BASE" ] && echo "  数据目录:   ⚠ 仍在" || echo "  数据目录:   ✓ 已删除"
echo ""
echo "  cooling:    cd3=$CDBV cd4=$CDPV   （0 = 不干预）"
echo "  节点权限:   p0=$PERM_B p6=$PERM_P   （应为 -rw-r--r--）"
echo ""
echo "  大核当前:   $CUR_B  （硬件上限 $MAX_B）"
echo "  超大核当前: $CUR_P  （硬件上限 $MAX_P）"
echo "  官方天花板: $MSMV"
echo ""
echo "  说明：卸载后最终频率 = 官方 msm_performance 的值。"
echo "        官方 perf HAL 每 5-10 秒会自己调整，属正常行为。"
echo "        只要 cooling 是 0、进程为 0，模块就没有任何影响。"
echo "=============================================================="

if [ "$LEFT" -eq 0 ] && [ "$CDBV" = "0" ] && [ "$CDPV" = "0" ]; then
    echo "  ✅ 卸载完成，已完全回归官方调度"
    exit 0
else
    echo "  ⚠ 存在异常，建议重启设备以彻底清理"
    exit 1
fi
