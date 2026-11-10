#!/bin/sh
# 在 niri 会话内、用 vkms 虚拟显卡跑 Denial（真显示器仍归 niri）
#
#   sudo modprobe vkms create_default_dev=1 enable_cursor=1     # 先执行一次（需要 root）
#   tools/denial-vkms.sh start|stop|status|shot
#
# 渲染仍走 NVIDIA render node，KMS 走 vkms；niri 不受影响。
set -u
LOG="$HOME/.cache/denial-vkms.log"
PIDFILE="$HOME/.cache/denial-vkms.pid"
BUNDLE="/usr/lib/denial/flutter"

find_vkms_card() {
  # 上游内核里 vkms 的驱动名是 faux_driver；也兼容 DRIVER=vkms。
  # 更稳的判据：存在一个 connected 的 Virtual-* 输出。
  for s in /sys/class/drm/card*-Virtual-*/status; do
    [ -f "$s" ] || continue
    [ "$(cat "$s" 2>/dev/null)" = "connected" ] || continue
    card=$(basename "$(dirname "$s")" | cut -d- -f1)
    echo "/dev/dri/$card"
    return 0
  done
  for ue in /sys/class/drm/card*/device/uevent; do
    [ -f "$ue" ] || continue
    if grep -qE '^DRIVER=(vkms|faux_driver)' "$ue" 2>/dev/null; then
      card=$(basename "$(dirname "$(dirname "$ue")")")
      echo "/dev/dri/$card"
      return 0
    fi
  done
  return 1
}

pick_render() {
  # 优先 NVIDIA（Denial 的 Sylk/Impeller 在 NV 上需要它）
  for r in /sys/class/drm/renderD*/device/uevent; do
    [ -f "$r" ] || continue
    if grep -q '^DRIVER=nvidia' "$r" 2>/dev/null; then
      echo "/dev/dri/$(basename "$(dirname "$(dirname "$r")")")"
      return 0
    fi
  done
  ls /dev/dri/renderD* 2>/dev/null | head -n1
}

case "${1:-status}" in
  start)
    DRM=$(find_vkms_card) || { echo "❌ 没找到 vkms 设备。先运行： sudo modprobe vkms create_default_dev=1 enable_cursor=1"; exit 1; }
    REND=$(pick_render)
    echo "  KMS 设备   : $DRM (vkms)"
    echo "  渲染设备   : $REND"
    for s in /sys/class/drm/card*"$(basename "$DRM")"*/status; do :; done
    # 确认 vkms 有连接的虚拟输出
    conn=$(for s in /sys/class/drm/*/status; do
             case "$s" in *"$(basename "$DRM")"-*) [ "$(cat "$s" 2>/dev/null)" = connected ] && basename "$s";; esac
           done | head -n1)
    [ -n "$conn" ] && echo "  虚拟输出   : $conn" || echo "  ⚠️ vkms 上没有已连接输出"
    DENIAL_DRM_DEVICE="$DRM" DENIAL_RENDER_DEVICE="$REND" \
      setsid --fork deniald --device "$DRM" --render-device "$REND" \
        --flutter-bundle "$BUNDLE" --output-config "$HOME/.local/state/denial/outputs.conf" --wayland \
        >"$LOG" 2>&1 &
    sleep 6
    pid=$(pgrep -n -x deniald || true)
    if [ -z "$pid" ]; then
      echo "❌ deniald 没起来，看日志："
      tail -n 20 "$LOG" | sed 's/^/    /'
      exit 1
    fi
    echo "$pid" > "$PIDFILE"
    echo "  ✅ deniald pid=$pid  （日志 $LOG）"
    echo "  Wayland socket: $(ls "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/wayland-* 2>/dev/null | tail -n1)"
    ;;
  stop)
    if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; fi
    pkill -x deniald 2>/dev/null
    echo "  已停止"
    ;;
  status)
    pid=$(pgrep -n -x deniald || true)
    if [ -z "$pid" ]; then echo "  deniald 未运行"; exit 0; fi
    rss=$(awk '/VmRSS/{printf "%.0f", $2/1024}' "/proc/$pid/status" 2>/dev/null)
    cpu=$(ps -o pcpu= -p "$pid" | tr -d ' ')
    vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ')
    echo "  pid=$pid  RSS=${rss}MB  CPU=${cpu}%  GPU合计=${vram}MiB"
    ;;
  shot)
    sock=$(ls "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/wayland-* 2>/dev/null | tail -n1)
    [ -n "$sock" ] || { echo "没有 Wayland socket"; exit 1; }
    out="${2:-/tmp/denial-vkms.png}"
    WAYLAND_DISPLAY="$(basename "$sock")" grim "$out" 2>&1 | sed 's/^/  /'
    [ -f "$out" ] && echo "  ✅ 截图 $out"
    ;;
  *)
    echo "用法: $0 start|stop|status|shot [输出png]"; exit 1;;
esac
