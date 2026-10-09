#!/system/bin/sh
# Oh My Keymint - automatic scoop helper.
#
# This companion script adds two optional automations on top of a stock OMK
# installation:
#   * keep `scoop` in sync with the installed package set, and
#
#
# Everything is opt-in: both features stay disabled until the WebUI writes
# The WebUI writes `auto_apps=1` into the configuration file.
# touches OMK's cryptographic material and only calls the same
# `--webui-*` entry points the WebUI itself uses.
#
# SPDX-License-Identifier: AGPL-3.0-or-later

MODDIR=${0%/*}
# `${0%/*}` keeps the value unchanged when $0 has no slash, which happens when
# the script is invoked through a relative path. Fall back to the current dir.
[ "$MODDIR" = "$0" ] && MODDIR=.
STATE_DIR=/data/adb/omk
MODULE_DIR=$MODDIR

CONF_FILE=$STATE_DIR/autoscoop.conf
AUTO_PKG_FILE=$STATE_DIR/autoscoop.packages
EXCLUDE_FILE=$STATE_DIR/autoscoop.exclude
# Last automatic result plus a fingerprint of the installed set. Separate from
# the WebUI's copy because the two enumerate packages differently.
AUTO_STATE_FILE=$STATE_DIR/autoscoop.state.sh
PACKAGES_LIST=/data/system/packages.list

# PackageManager rewrites this file on every install and removal.
INOTIFY_MASK=mcdy
# The directory is watched, not the file. Measured on a real device, every
# install and removal replaced the file's inode (467699 -> 804795 -> 605523),
# so PackageManager writes a temporary file and renames it over the target. A
# watch bound to the old inode therefore dies with IN_IGNORED and the rename
# itself is never seen. The directory's inode is stable, so it keeps reporting:
#   m - subfile moved out   y - subfile moved in
#   c - subfile modified    d - subfile deleted
INOTIFY_WATCH_DIR=/data/system
INOTIFY_HANDLER=$STATE_DIR/.inotify-handler.sh
INOTIFY_LOCK=$STATE_DIR/.inotify-lock

TMP_DIR=$STATE_DIR/.autoscoop-tmp

# The three Google packages that the WebUI's recommended selection always adds.
# They belong to the baseline attestation surface and are part of the automatic
# set so opening the switch adds them without a separate recommended pass.
RECOMMENDED_SYSTEM_PKGS="com.google.android.gsf
com.google.android.gms
com.android.vending
com.coloros.sceneservice"

# Mirrors the WebUI recommended-selection exclusion list, so anything
# "Select recommended apps" skips is skipped here too. Add further entries to
# /data/adb/omk/autoscoop.exclude, one package name per line.
ROOT_TOOLS="me.weishu.kernelsu
com.rifsxd.ksunext
me.bmax.apatch
com.topjohnwu.magisk
io.github.huskydg.magisk
eu.chainfire.supersu
com.noshufou.android.su
org.lsposed.manager
de.robv.android.xposed.installer
org.meowcat.edxposed.manager
moe.shizuku.privileged.api
rikka.sui
com.tsng.hidemyapplist
org.frknkrc44.hma_oss
bin.mt.plus
bin.mt.plus.canary
com.termux"

umask 022

conf_get() {
  key=$1
  default=$2
  value=""
  if [ -f "$CONF_FILE" ]; then
    value=$(sed -n "s/^${key}=//p" "$CONF_FILE" 2>/dev/null | tail -n 1 | tr -d '\r')
  fi
  if [ -z "$value" ]; then
    echo "$default"
  else
    echo "$value"
  fi
}

conf_is_enabled() {
  [ "$(conf_get "$1" 0)" = "1" ] && return 0
  return 1
}

write_conf_line() {
  key=$1
  value=$2
  mkdir -p "$STATE_DIR" 2>/dev/null
  if [ ! -f "$CONF_FILE" ]; then
    : >"$CONF_FILE" 2>/dev/null
  fi
  if grep -q "^${key}=" "$CONF_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$CONF_FILE" 2>/dev/null
  else
    echo "${key}=${value}" >>"$CONF_FILE" 2>/dev/null
  fi
}

is_package_name() {
  echo "$1" | grep -Eq '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$'
}

find_binary() {
  name=$1
  for candidate in \
    "$STATE_DIR/$name" \
    "$MODULE_DIR/$name" \
    "$MODULE_DIR/libs/arm64-v8a/$name" \
    "$MODULE_DIR/libs/x86_64/$name" \
    "/data/adb/modules/oh_my_keymint/libs/arm64-v8a/$name"
  do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# --- scoop handling ---------------------------------------------------------

# Returns 0 whenever the query itself succeeded, even when scoop is empty. An
# empty list is a valid state (the user may have deselected everything) and must
# stay distinguishable from a helper that failed to answer.
get_scoop() {
  inject=$(find_binary inject) || return 1
  output=$("$inject" --webui-get-scoop 2>/dev/null) || return 1
  echo "$output" | tr -d '[]"' | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d' \
    | grep -E '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$' | sort -u
  return 0
}

set_scoop() {
  # $1: newline separated package names
  inject=$(find_binary inject) || return 1
  body=$(echo "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d' \
    | grep -E '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$' | sort -u)
  json=$(echo "$body" | awk 'NF { printf "%s\"%s\"", sep, $0; sep = "," }')
  payload=$(printf '[%s]' "$json" | base64 | tr -d '\n')
  [ -n "$payload" ] || return 1
  "$inject" --webui-set-scoop "$payload" >/dev/null 2>&1
}

# Run one package-manager query and echo its `package:` lines.
# Several spellings exist across Android versions and root implementations;
# try them in order and keep the first non-empty result.
query_package_manager() {
  filter=$1
  for command in \
    "/system/bin/pm list packages ${filter} --user 0" \
    "/system/bin/pm list packages ${filter}" \
    "/system/bin/cmd package list packages ${filter} --user 0" \
    "/system/bin/cmd package list packages ${filter}" \
    "pm list packages ${filter} --user 0" \
    "pm list packages ${filter}" \
    "cmd package list packages ${filter}"
  do
    raw=$(eval "$command" 2>/dev/null)
    if [ -n "$raw" ]; then
      echo "$raw"
      return 0
    fi
  done
  return 1
}

# Only third-party apps are ever synchronized. System packages, including
# OMK's own factory defaults such as Google Play services, are left untouched.
scan_packages() {
  raw=$(query_package_manager "-3")

  # Last resort: the data directories still list every installed package even
  # when PackageManager refuses to answer.
  if [ -z "$raw" ]; then
    raw=$(ls -1 /data/data 2>/dev/null | sed 's/^/package:/')
  fi

  echo "$raw" | sed -n 's/^package://p' | tr -d '\r' \
    | grep -E '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$' | sort -u
}

build_exclude_file() {
  mkdir -p "$TMP_DIR" 2>/dev/null
  target=$TMP_DIR/exclude
  : >"$target" 2>/dev/null
  echo "$ROOT_TOOLS" | sed '/^[[:space:]]*$/d' >>"$target"
  if [ -f "$EXCLUDE_FILE" ]; then
    grep -E '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$' "$EXCLUDE_FILE" 2>/dev/null >>"$target"
  fi
  sort -u "$target" 2>/dev/null
}

# Keeps only the baseline packages that are actually installed.
#
# `com.coloros.sceneservice` only exists on OPPO/OnePlus/realme builds. Adding
# it blindly put a package in scoop that the device does not have, which is both
# wrong and the reason the reported count grew by one after the first automatic
# refresh. The WebUI intersects its recommended set with the enumerated entries,
# so this does the same.
installed_recommended_system_pkgs() {
  installed=$(query_package_manager "-s" 2>/dev/null | sed -n 's/^package://p' \
    | tr -d '\r' | grep -E '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$' | sort -u)
  # Without a usable answer the previous behaviour is the safer fallback: the
  # baseline set is small and every entry is a known attestation surface.
  if [ -z "$installed" ]; then
    echo "$RECOMMENDED_SYSTEM_PKGS" | sed '/^[[:space:]]*$/d'
    return 0
  fi
  echo "$RECOMMENDED_SYSTEM_PKGS" | sed '/^[[:space:]]*$/d' \
    | while IFS= read -r pkg; do
        printf '%s\n' "$installed" | grep -qxF "$pkg" && printf '%s\n' "$pkg"
      done
}

# Refresh scoop from the installed package set.
#
# Manual entries survive: everything currently in scoop that was NOT written by
# a previous automatic refresh is treated as user-owned and kept as-is.
apply_auto_packages() {
  current=$(get_scoop) || {
    return 1
  }

  last_auto=""
  if [ -f "$AUTO_PKG_FILE" ]; then
    last_auto=$(grep -E '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$' "$AUTO_PKG_FILE" 2>/dev/null | sort -u)
  fi

  mkdir -p "$TMP_DIR" 2>/dev/null
  : >"$TMP_DIR/last_auto" 2>/dev/null
  [ -n "$last_auto" ] && echo "$last_auto" >"$TMP_DIR/last_auto"

  # manual = current - last_auto.
  # `grep -vxF -f` is not dependable across toybox builds, so the set
  # difference is done with awk. Comparing against ARGV[1] rather than using
  # `NR == FNR` matters: when the first file is empty, NR and FNR stay equal in
  # the second file too, which would silently swallow every existing entry.
  echo "$current" >"$TMP_DIR/current" 2>/dev/null
  manual=$(awk 'FILENAME == ARGV[1] { seen[$0] = 1; next } !($0 in seen)' \
    "$TMP_DIR/last_auto" "$TMP_DIR/current" 2>/dev/null)

  scanned=$(scan_packages)
  if [ -z "$scanned" ]; then
    return 1
  fi

  # Nothing was installed or removed since the last run, so reuse that result.
  # Recomputing can differ by a package because the enumeration is allowed to
  # resolve differently between runs, which makes the list drift on every
  # install or removal event.
  #
  # The baseline set is folded into the fingerprint too. When a package stops
  # qualifying - for example a build that never had `com.coloros.sceneservice`
  # - the stored result must be recomputed rather than reused.
  recommended_system=$(installed_recommended_system_pkgs)
  fingerprint=$(printf '%s\n' "$scanned" "$recommended_system" \
    | md5sum 2>/dev/null | cut -d' ' -f1)
  if [ -n "$fingerprint" ] && [ -f "$AUTO_STATE_FILE" ]; then
    stored=$(sed -n '1p' "$AUTO_STATE_FILE" 2>/dev/null)
    if [ "$fingerprint" = "$stored" ]; then
      reused=$(sed -n '2,$p' "$AUTO_STATE_FILE" 2>/dev/null \
        | grep -E '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$' | sort -u)
      if [ -n "$reused" ]; then
        merged=$(
          {
            echo "$manual"
            echo "$reused"
          } | sed '/^[[:space:]]*$/d' | sort -u
        )
        previous=$(echo "$current" | sort -u)
        if [ "$merged" != "$previous" ]; then
          set_scoop "$merged" || return 1
        fi
        echo "$(echo "$merged" | grep -c .)"
        return 0
      fi
    fi
  fi

  if [ -z "$scanned" ]; then
    return 1
  fi

  echo "$scanned" >"$TMP_DIR/scanned" 2>/dev/null
  auto=$(awk 'FILENAME == ARGV[1] { seen[$0] = 1; next } !($0 in seen)' \
    "$TMP_DIR/exclude" "$TMP_DIR/scanned" 2>/dev/null)
  [ -z "$auto" ] && auto=$scanned

  mkdir -p "$STATE_DIR" 2>/dev/null
  echo "$auto" >"$AUTO_PKG_FILE" 2>/dev/null
  chmod 0644 "$AUTO_PKG_FILE" 2>/dev/null

  merged=$(
    {
      echo "$manual"
      echo "$auto"
      echo "$recommended_system"
    } | sed '/^[[:space:]]*$/d' | sort -u
  )

  previous=$(echo "$current" | sort -u)
  if [ "$merged" = "$previous" ]; then
    [ -n "$fingerprint" ] && { echo "$fingerprint"; echo "$merged"; } >"$AUTO_STATE_FILE" 2>/dev/null
    echo "$(echo "$merged" | grep -c .)"
    return 0
  fi

  if set_scoop "$merged"; then
    [ -n "$fingerprint" ] && { echo "$fingerprint"; echo "$merged"; } >"$AUTO_STATE_FILE" 2>/dev/null
    count=$(echo "$merged" | grep -c .)
    scanned_count=$(echo "$auto" | grep -c .)
    manual_count=$(echo "$manual" | grep -c .)
    echo "$count"
    return 0
  fi

  return 1
}

# --- commands ---------------------------------------------------------------

cmd_get() {
  printf 'auto_apps=%s\n' "$(conf_get auto_apps 0)"
}

cmd_set() {
  for assignment in "$@"; do
    key=${assignment%%=*}
    value=${assignment#*=}
    [ "$key" = "$assignment" ] && continue
    case "$key" in
      auto_apps)
        case "$value" in
          0|1) write_conf_line "$key" "$value" ;;
        esac
        ;;
    esac
  done
  cmd_get
}

cmd_sync_packages() {
  # Surface the reason instead of a bare failure: the WebUI shows this text.
  if ! find_binary inject >/dev/null 2>&1; then
    echo "failed inject_not_found"
    return 1
  fi
  # An empty scoop is valid; only a helper that cannot answer is a failure.
  get_scoop >/dev/null 2>&1 || {
    echo "failed scoop_unreadable"
    return 1
  }
  scanned=$(scan_packages 2>/dev/null)
  if [ -z "$scanned" ]; then
    echo "failed no_packages_scanned"
    return 1
  fi
  build_exclude_file >/dev/null 2>&1
  count=$(apply_auto_packages)
  if [ -n "$count" ]; then
    echo "ok ${count}"
  else
    echo "failed write_rejected"
  fi
}

# Diagnostics: everything needed to tell why an automatic refresh did nothing.
cmd_status() {
  echo "helper_present=yes"
  echo "conf_file=$( [ -f "$CONF_FILE" ] && echo yes || echo no )"
  echo "auto_apps=$(conf_get auto_apps 0)"
  echo "inject=$(find_binary inject 2>/dev/null || echo not_found)"
  echo "keymint=$(find_binary keymint 2>/dev/null || echo not_found)"
  scanned=$(scan_packages 2>/dev/null)
  echo "scanned_count=$(echo "$scanned" | grep -c .)"
  current=$(get_scoop 2>/dev/null)
  echo "scoop_count=$(echo "$current" | grep -c .)"
  echo "packages_list=$( [ -f "$PACKAGES_LIST" ] && echo yes || echo no )"
}

# Disabling the automation hands every current entry back to the user: clear
# the automatic ledger so the next refresh keeps the whole list as manual.
cmd_disable_packages() {
  write_conf_line auto_apps 0
  : >"$AUTO_PKG_FILE" 2>/dev/null
  echo "ok"
}

# PackageManager is not usable before the framework finishes booting. Block
# until it answers so the first refresh is not silently skipped.
wait_for_package_manager() {
  attempts=0
  until [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -gt 150 ] && break
    sleep 2
  done
  # sys.boot_completed can flip before PackageManager answers queries. Give up
  # after a bounded wait so the first refresh is never blocked by a slow startup.
  attempts=0
  while [ -z "$(scan_packages)" ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -ge 60 ] && return 1
    sleep 5
  done
  return 0
}

# inotifyd is not always present as a standalone binary; busybox builds expose
# it as an applet.
find_inotifyd() {
  if command -v inotifyd >/dev/null 2>&1; then
    INOTIFY_BIN=$(command -v inotifyd 2>/dev/null)
    return 0
  fi
  for bb in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
    if [ -x "$bb" ] && "$bb" inotifyd --help >/dev/null 2>&1; then
      INOTIFY_BIN="$bb inotifyd"
      return 0
    fi
  done
  return 1
}

write_inotify_handler() {
  helper=$MODULE_DIR/autoscoop.sh
  [ -f "$helper" ] || helper=/data/adb/modules/oh_my_keymint/autoscoop.sh
  cat >"$INOTIFY_HANDLER" <<EOF
#!/system/bin/sh
# inotifyd calls: PROG ACTUAL_EVENTS FILE [SUBFILE]. The directory is watched,
# so match on the reported name and ignore everything else under /data/system.
found=
for arg in "\$@"; do
  case "\$arg" in
    *packages*) found=1 ;;
  esac
done
[ -z "\$found" ] && exit 0

# Honour the switch: inotifyd keeps watching even while it is off, so the
# handler is what stops any work from happening.
grep -q '^auto_apps=1' "$CONF_FILE" 2>/dev/null || exit 0

# One install fires several events. Only the first one past the lock syncs;
# the rescan it performs already reflects the changes the others reported.
mkdir "$INOTIFY_LOCK" 2>/dev/null || exit 0
sleep 2
# Called through sh so a missing executable bit on the helper cannot stop it.
sh "$helper" sync-packages >/dev/null 2>&1
rmdir "$INOTIFY_LOCK" 2>/dev/null
exit 0
EOF
  chmod 755 "$INOTIFY_HANDLER" 2>/dev/null
}

# Watches for installs and removals with inotifyd instead of polling, so an app
# added now is picked up immediately rather than on the next 15 second tick.
watch_packages() {
  wait_for_package_manager

  # Align once after boot so the list is already correct before any event.
  if conf_is_enabled auto_apps; then
    build_exclude_file >/dev/null 2>&1
    apply_auto_packages
  fi

  # Without inotifyd there is nothing to watch with. The WebUI still aligns the
  # list every time it is opened.
  find_inotifyd || return 0
  write_inotify_handler
  rm -rf "$INOTIFY_LOCK" 2>/dev/null

  # The directory's inode does not change, so this normally blocks for the
  # whole boot. The loop only matters if inotifyd dies or the directory goes
  # away; the sleep keeps a failing binary from spinning.
  while true; do
    if [ -d "$INOTIFY_WATCH_DIR" ]; then
      $INOTIFY_BIN "$INOTIFY_HANDLER" "${INOTIFY_WATCH_DIR}:${INOTIFY_MASK}" >/dev/null 2>&1
    fi
    sleep 4
  done
}

cmd_daemon() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  build_exclude_file >/dev/null 2>&1

  watch_packages &
  wait
}

first_autoscoop_pid() {
  for pid in $(autoscoop_pids); do
    echo "$pid"
    return 0
  done
  return 1
}

# List PIDs whose command line looks like our daemon. Scanning /proc keeps this
# independent of pgrep, which is not present on every device.
autoscoop_pids() {
  for dir in /proc/[0-9]*; do
    pid=${dir#/proc/}
    [ -r "$dir/cmdline" ] || continue
    cmd=$(tr '\0' ' ' <"$dir/cmdline" 2>/dev/null)
    case "$cmd" in
      *autoscoop.sh*daemon*) echo "$pid" ;;
    esac
  done
}

# Start the daemon if it is not already running. The WebUI calls this on every
# launch so the automation also recovers when service.sh could not start it.
daemon_alive() {
  [ -r "/proc/$1/cmdline" ] || return 1
  cmd=$(tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null)
  case "$cmd" in
    *daemon*) return 0 ;;
  esac
  return 1
}

cmd_ensure() {
  pidfile=$STATE_DIR/autoscoop-daemon.pid
  mkdir -p "$STATE_DIR" 2>/dev/null

  if [ -f "$pidfile" ]; then
    pid=$(cat "$pidfile" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && daemon_alive "$pid"; then
      echo "running"
      return 0
    fi
    rm -f "$pidfile" 2>/dev/null
  fi

  nohup sh "$MODDIR/autoscoop.sh" daemon >/dev/null 2>&1 &
  launched=$!
  echo "$launched" >"$pidfile" 2>/dev/null
  sleep 3

  if kill -0 "$launched" 2>/dev/null; then
    echo "started"
    return 0
  fi

  rm -f "$pidfile" 2>/dev/null
  echo "failed"
  return 1
}

usage() {
  echo "usage: autoscoop.sh {get|set k=v ...|sync-packages|disable-packages|status|ensure|daemon}"
}

case "$1" in
  get) cmd_get ;;
  set) shift; cmd_set "$@" ;;
  sync-packages) cmd_sync_packages ;;
  disable-packages) cmd_disable_packages ;;
  status) cmd_status ;;
  pids) autoscoop_pids ;;
  ensure) cmd_ensure ;;
  daemon) cmd_daemon ;;
  *) usage ;;
esac
