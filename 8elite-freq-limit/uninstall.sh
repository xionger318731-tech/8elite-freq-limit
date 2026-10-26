#!/system/bin/sh
# ============================================================
# 8elite限频 卸载 v1.0
#
# 关键顺序（踩过的坑）：
#   1. 先杀 watchdog，否则它 60 秒后把 daemon 拉回来
#   2. 按脚本名精确匹配，不能用 *eta_sched* 模糊匹配
#      （会误杀执行本脚本的 shell）
#   3. /proc 遍历必须过滤非数字目录
#
# 本模块足迹：
#   写：cooling_device3/4 cur_state、/data/adb/eta_sched、/storage/.../8elite
#   不碰：msm_performance、scaling_max_freq 的值、settings
# ============================================================

DATA=/data/adb/eta_sched
BASE=/storage/emulated/0/Android/8elite
OBS=$BASE/obs
CD_B=/sys/class/thermal/cooling_device3/cur_state
CD_P=/sys/class/thermal/cooling_device4/cur_state

log(){ echo "[uninstall] $*"; }

# 精确杀：cmdline 必须形如 "sh /data/adb/eta_sched/xxx.sh"
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

log "1/6 停止看门狗（切断自愈）"
kill_script "watchdog.sh"
sleep 1

log "2/6 停止守护"
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

usleep 500000

log "3/6 归还 CPU 上限"
echo 0 > "$CD_B" 2>/dev/null
echo 0 > "$CD_P" 2>/dev/null
usleep 300000
log "  cooling: $(cat $CD_B 2>/dev/null) / $(cat $CD_P 2>/dev/null)"

log "4/6 修复节点权限"
chmod 644 /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null
chmod 644 /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq 2>/dev/null

log "5/6 清理数据"
rm -rf "$DATA" 2>/dev/null
rm -rf "$BASE" 2>/dev/null

log "6/6 复核"
sleep 1
LEFT=$(count_left)
log "  残留进程: $LEFT"
[ -d "$DATA" ] && log "  ⚠ 运行目录仍在" || log "  运行目录已删"
[ -d "$BASE" ] && log "  ⚠ 数据目录仍在" || log "  数据目录已删"
log "  大核:   $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null)"
log "  超大核: $(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq 2>/dev/null)"
log "  官方:   $(cut -d' ' -f1 /sys/kernel/msm_performance/parameters/cpu_max_freq 2>/dev/null)"
log "  cooling: $(cat $CD_B 2>/dev/null) / $(cat $CD_P 2>/dev/null)"

if [ "$LEFT" -eq 0 ]; then
    log "✅ 卸载完成，零残留"
else
    log "⚠ 仍有 $LEFT 个进程，建议重启"
fi
exit 0
