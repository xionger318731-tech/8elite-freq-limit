#!/system/bin/sh
command -v ui_print >/dev/null 2>&1 || ui_print(){ echo "$@"; }

DATA=/data/adb/eta_sched
BASE=/storage/emulated/0/Android/8elite

ui_print "*******************************"
ui_print "  8elite限频  V1.4fix2"
ui_print "  作者：罗霄山"
ui_print "*******************************"

ui_print "- 部署"
mkdir -p "$DATA/config" "$BASE/obs"
cp -f "$MODPATH/scripts/"*.sh "$DATA/" 2>/dev/null
cp -f "$MODPATH/config/"*.conf "$DATA/config/" 2>/dev/null
cp -f "$MODPATH/config/games.list" "$DATA/config/" 2>/dev/null
chmod 755 "$DATA"/*.sh 2>/dev/null

[ -f "$BASE/config.conf" ] || printf 'mode=auto\nenabled=1\nstyle=eco\n' > "$BASE/config.conf"

ui_print "- 启动"
sh "$DATA/ctl.sh" start 2>/dev/null

ui_print ""
ui_print "安装完成（V1.4fix2）"
ui_print "  静止约 1 秒落至 748M 底板（省电），重载直上 3.53G（流畅）"
ui_print "  触摸/冷启动瞬时抬频，不损失响应"
ui_print "  打开 WebUI 可切换省电/均衡/流畅"
ui_print ""
