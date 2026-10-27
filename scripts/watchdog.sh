#!/system/bin/sh
# ============================================================
# 8elite限频 看门狗 v1.0
#   1. 脚本被清 → 从模块恢复
#   2. 守护挂了 → 拉起
#   3. 状态超时（卡死）→ 重启
# 每 60 秒检查一次，开销可忽略
# ============================================================

D=/data/adb/eta_sched
MOD=/data/adb/modules/eta_sched
OBS=/storage/emulated/0/Android/8elite/obs
LOG="$OBS/watchdog.log"

mkdir -p "$OBS" 2>/dev/null

while :; do
    # 自愈脚本
    if [ ! -f "$D/daemon.sh" ]; then
        mkdir -p "$D" 2>/dev/null
        cp -f "$MOD"/scripts/*.sh "$D"/ 2>/dev/null
        chmod 755 "$D"/*.sh 2>/dev/null
        echo "$(date '+%m-%d %H:%M:%S') 恢复脚本" >> "$LOG"
    fi

    # 守护存活
    p=""
    [ -f "$OBS/daemon.pid" ] && read -r p < "$OBS/daemon.pid" 2>/dev/null
    if [ -z "$p" ] || [ ! -d "/proc/$p" ]; then
        rm -f "$OBS/daemon.lock"
        setsid sh "$D/daemon.sh" >/dev/null 2>&1 < /dev/null &
        echo "$(date '+%m-%d %H:%M:%S') 拉起守护" >> "$LOG"
        sleep 3
        continue
    fi

    # 状态超时（>3 分钟没更新 = 卡死）
    # 注意：daemon 写入的 ts 是 /proc/uptime 的秒数（零 fork），
    #       这里必须用同一个时钟，不能用 date +%s（epoch），否则永远超时误杀。
    if [ -f "$OBS/state" ]; then
        ts=$(awk -F= '/^ts=/{print $2}' "$OBS/state" 2>/dev/null)
        up=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
        now=${up:-0}
        case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
        if [ "$ts" -gt 0 ] && [ $((now - ts)) -gt 180 ]; then
            kill -9 "$p" 2>/dev/null
            rm -f "$OBS/daemon.lock"
            echo "$(date '+%m-%d %H:%M:%S') 状态超时，重启守护" >> "$LOG"
        fi
    fi

    sleep 60
done
