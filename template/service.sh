MODDIR=${0%/*}
STATE_DIR=/data/adb/omk

mkdir -p "$STATE_DIR"

pid_matches_script() {
  pid=$1
  script=$2
  [ -r "/proc/$pid/cmdline" ] || return 1
  cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
  echo "$cmdline" | grep -F "$script" >/dev/null 2>&1
}

start_daemon() {
  script=$1
  pidfile=$2

  if [ -f "$pidfile" ]; then
    pid=$(cat "$pidfile" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && pid_matches_script "$pid" "$script"; then
      return 0
    fi
    rm -f "$pidfile"
  fi

  sh "$script" &
  pid=$!
  echo $pid > "$pidfile"
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null || ! pid_matches_script "$pid" "$script"; then
    rm -f "$pidfile"
    return 1
  fi
  return 0
}

start_daemon_with_arg() {
  script=$1
  arg=$2
  pidfile=$3

  if [ -f "$pidfile" ]; then
    pid=$(cat "$pidfile" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && pid_matches_script "$pid" "$script"; then
      return 0
    fi
    rm -f "$pidfile"
  fi

  # Detach from the boot shell: setsid leaves the caller's session and
  # </dev/null releases its stdin, so nothing holds a terminal open.
  if command -v setsid >/dev/null 2>&1; then
    setsid sh "$script" "$arg" </dev/null >/dev/null 2>&1 &
  else
    nohup sh "$script" "$arg" </dev/null >/dev/null 2>&1 &
  fi
  pid=$!
  echo $pid > "$pidfile"
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null || ! pid_matches_script "$pid" "$script"; then
    rm -f "$pidfile"
    return 1
  fi
  return 0
}

start_daemon "$MODDIR/daemon" "$STATE_DIR/keymint-daemon.pid"
start_daemon "$MODDIR/daemon-injector" "$STATE_DIR/injector-daemon.pid"
# Keep the Qualcomm Soter watchdog alive independently of the KeyMint route.
# It owns vendor.qti.hardware.soter.ISoter/default only when its persistent
# software-TA takeover flag requests it; otherwise the stock HAL remains active.
start_daemon "$MODDIR/soterta.sh" "$STATE_DIR/soterta-watchdog.pid"
# Optional automation: keep scoop aligned with the installed package set.
# Stays disabled until the WebUI turns it on.
start_daemon_with_arg "$MODDIR/autoscoop.sh" daemon "$STATE_DIR/autoscoop-daemon.pid"

# Resolve the active root implementation's resetprop binary.
RESETPROP_BIN="$(command -v resetprop 2>/dev/null)"
if [ -z "$RESETPROP_BIN" ]; then
  if [ -x /data/adb/ksu/bin/resetprop ]; then
    RESETPROP_BIN=/data/adb/ksu/bin/resetprop
  elif [ -x /data/adb/ap/bin/resetprop ]; then
    RESETPROP_BIN=/data/adb/ap/bin/resetprop
  elif [ -x /data/adb/magisk/resetprop ]; then
    RESETPROP_BIN=/data/adb/magisk/resetprop
  fi
fi

check_reset_prop() {
  local NAME="$1"
  local EXPECTED="$2"
  local VALUE
  VALUE=$("$RESETPROP_BIN" "$NAME")
  [ -z "$VALUE" ] || [ "$VALUE" = "$EXPECTED" ] || "$RESETPROP_BIN" -n "$NAME" "$EXPECTED"
}

contains_reset_prop() {
  local NAME="$1"
  local CONTAINS="$2"
  local NEWVAL="$3"
  case "$("$RESETPROP_BIN" "$NAME")" in
    *"$CONTAINS"*) "$RESETPROP_BIN" -n "$NAME" "$NEWVAL" ;;
  esac
}

if [ -n "$RESETPROP_BIN" ]; then
  "$RESETPROP_BIN" -w sys.boot_completed 0
  check_reset_prop "init.svc.adbd" "stopped"
  check_reset_prop "partition.odm.verified" "1"
  check_reset_prop "partition.product.verified" "1"
  check_reset_prop "partition.system.verified" "1"
  check_reset_prop "partition.system_ext.verified" "1"
  check_reset_prop "partition.vendor.verified" "1"
  check_reset_prop "persist.logd.size" ""
  check_reset_prop "persist.logd.size.crash" ""
  check_reset_prop "persist.logd.size.events" ""
  check_reset_prop "persist.logd.size.main" ""
  check_reset_prop "persist.logd.size.radio" ""
  check_reset_prop "persist.logd.size.system" ""
  check_reset_prop "persist.logd.size.tag" ""
  check_reset_prop "persist.sys.usb.config" "none"
  check_reset_prop "ro.adb.secure" "1"
  check_reset_prop "ro.boot.flash.locked" "1"
  check_reset_prop "ro.boot.realme.lockstate" "1"
  check_reset_prop "ro.boot.realmebootstate" "green"
  check_reset_prop "ro.boot.selinux" "enforcing"
  check_reset_prop "ro.boot.vbmeta.device_state" "locked"
  check_reset_prop "ro.boot.vbmeta.hash_alg" "sha256"
  check_reset_prop "ro.boot.verifiedbootstate" "green"
  check_reset_prop "ro.boot.veritymode" "enforcing"
  check_reset_prop "ro.boot.warranty_bit" "0"
  check_reset_prop "ro.build.tags" "release-keys"
  check_reset_prop "ro.build.type" "user"
  check_reset_prop "ro.crypto.state" "encrypted"
  check_reset_prop "ro.debuggable" "0"
  check_reset_prop "ro.force.debuggable" "0"
  check_reset_prop "ro.kernel.qemu" ""
  check_reset_prop "ro.oem_unlock_supported" "0"
  check_reset_prop "ro.secure" "1"
  check_reset_prop "ro.secureboot.lockstate" "locked"
  check_reset_prop "ro.vendor.boot.warranty_bit" "0"
  check_reset_prop "ro.vendor.warranty_bit" "0"
  check_reset_prop "ro.warranty_bit" "0"
  check_reset_prop "service.adb.root" "0"
  check_reset_prop "sys.oem_unlock_allowed" "0"
  check_reset_prop "sys.usb.adb.disabled" ""
  check_reset_prop "sys.usb.config" "none"
  check_reset_prop "vendor.boot.vbmeta.device_state" "locked"
  check_reset_prop "vendor.boot.verifiedbootstate" "green"
  contains_reset_prop "ro.boot.bootmode" "recovery" "unknown"
  contains_reset_prop "ro.bootloader" "engineering" "release"
  contains_reset_prop "ro.bootmode" "recovery" "unknown"
  contains_reset_prop "ro.build.description" "test-keys" "release-keys"
  contains_reset_prop "vendor.boot.bootmode" "recovery" "unknown"
  setprop ctl.restart logd
fi
