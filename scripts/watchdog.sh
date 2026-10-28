#!/system/bin/sh
# ============================================================
# 8elite限频 看门狗 v1.4fix
#   1. 脚本被清 → 从模块恢复
#   2. 守护挂了 → 拉起
#   3. 守护被系统冻结 → 解冻（不是卡死，不能杀）
#   4. 状态真超时（卡死）→ 重启
# 每 60 秒检查一次，开销可忽略
# ============================================================

D=/data/adb/eta_sched
MOD=/data/adb/modules/eta_sched
OBS=/storage/emulated/0/Android/8elite/obs
STATE=$D/state
LOG="$OBS/watchdog.log"

mkdir -p "$OBS" "$D" 2>/dev/null

# ---------------------------------------------------------------------
# 脱离 app 冻结域：ksu.exec 拉起的进程继承 KSU 管理器的 app cgroup，
# 管理器退后台整组被 cgroup.freeze，看门狗跟着一起冻住 → 自愈失效。
# 移到 cgroup v2 根（由 init 托管），永久免疫。
detach_freeze(){
    local cur
    while IFS= read -r cur; do
        case "$cur" in "0::/") return 0 ;; esac
    done < /proc/$$/cgroup 2>/dev/null
    echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null && return 0
    return 1
}
detach_freeze
echo $$ > "$D/watchdog.pid" 2>/dev/null
echo $$ > "$OBS/watchdog.pid" 2>/dev/null

# 判断进程是否被 cgroup freezer 挂起（wchan=do_freezer_trap 即被冻）
is_frozen(){
    local p="$1" w
    [ -d "/proc/$p" ] || return 1
    w=$(cat "/proc/$p/wchan" 2>/dev/null)
    case "$w" in do_freezer_trap) return 0 ;; esac
    return 1
}
# 把被冻的进程挪回根 cgroup，等价于解冻
thaw(){
    local p="$1"
    echo "$p" > /sys/fs/cgroup/cgroup.procs 2>/dev/null && return 0
    return 1
}

# 也把自己挪回根（防止被外部挪走）
[ "$1" = "--once" ] && ONCE=1 || ONCE=0

while :; do
    detach_freeze

    # 自愈脚本
    if [ ! -f "$D/daemon.sh" ]; then
        mkdir -p "$D" 2>/dev/null
        cp -f "$MOD"/scripts/*.sh "$D"/ 2>/dev/null
        chmod 755 "$D"/*.sh 2>/dev/null
        echo "$(date '+%m-%d %H:%M:%S') 恢复脚本" >> "$LOG"
    fi

    # 守护存活（pid 以 root 私有路径 $D/daemon.pid 为准，emulated 镜像仅兜底）
    p=""
    [ -f "$D/daemon.pid" ] && read -r p < "$D/daemon.pid" 2>/dev/null
    [ -z "$p" ] && [ -f "$OBS/daemon.pid" ] && read -r p < "$OBS/daemon.pid" 2>/dev/null

    if [ -z "$p" ] || [ ! -d "/proc/$p" ]; then
        rm -f "$D/daemon.lock"
        export PATH="/system/bin:/system/xbin:/sbin:/vendor/bin:$PATH"
        if command -v setsid >/dev/null 2>&1; then
            setsid sh "$D/daemon.sh" >/dev/null 2>&1 < /dev/null &
        else
            sh "$D/daemon.sh" >/dev/null 2>&1 < /dev/null &
        fi
        echo "$(date '+%m-%d %H:%M:%S') 拉起守护 pid=$!" >> "$LOG"
        sleep 5
        continue
    fi

    # 被冻结 → 解冻，绝不当成卡死杀掉
    if is_frozen "$p"; then
        if thaw "$p"; then
            echo "$(date '+%m-%d %H:%M:%S') 守护被系统冻结，已解冻 pid=$p" >> "$LOG"
            sleep 2
            continue
        fi
        echo "$(date '+%m-%d %H:%M:%S') 守护被冻结且无法解冻，重启 pid=$p" >> "$LOG"
        kill -9 "$p" 2>/dev/null
        rm -f "$D/daemon.lock"
        sleep 2
        continue
    fi

    # 状态超时（>3 分钟没更新 = 卡死）
    # 注意：daemon 写入的 ts 是 /proc/uptime 的秒数（零 fork），
    #       这里必须用同一个时钟，不能用 date +%s（epoch），否则永远超时误杀。
    stf="$STATE"
    [ -f "$stf" ] || stf="$OBS/state"
    if [ -f "$stf" ]; then
        ts=$(awk -F= '/^ts=/{print $2}' "$stf" 2>/dev/null)
        up=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
        now=${up:-0}
        case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
        if [ "$ts" -gt 0 ] && [ $((now - ts)) -gt 180 ]; then
            kill -9 "$p" 2>/dev/null
            rm -f "$D/daemon.lock"
            echo "$(date '+%m-%d %H:%M:%S') 状态超时，重启守护 pid=$p (ts=$ts now=$now)" >> "$LOG"
            sleep 2
            continue
        fi
    fi

    [ "$ONCE" = 1 ] && exit 0
    sleep 60
done
