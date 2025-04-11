#!/bin/sh
#
# Copyright 2011 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#

# Determine script directory
SCRIPT_DIR=$(dirname "$0")
PROG=$(basename "$0")
: "${GPT:=cgpt}"
: "${FUTILITY:=futility}"

# The tag when the rootfs is changed.
TAG_NEEDS_TO_BE_SIGNED="/root/.need_to_be_signed"

# List of Temporary files and mount points.
TEMP_FILE_LIST=$(mktemp)
TEMP_DIR_LIST=$(mktemp)

# URL pointing to your fork of Murkmod
MURKMOD_URL="https://github.com/notnrbtw/murkmod-beta"

# Finds and loads the 'shflags' library
load_shflags() {
  if [ -f /usr/share/misc/shflags ]; then
    . /usr/share/misc/shflags
  elif [ -f "${SCRIPT_DIR}/lib/shflags/shflags" ]; then
    . "${SCRIPT_DIR}/lib/shflags/shflags"
  else
    echo "ERROR: Cannot find the required shflags library."
    return 1
  fi
  DEFINE_boolean debug $FLAGS_FALSE "Provide debug messages" "d"
}

# Functions for debug output
info() { echo "${PROG}: INFO: $*" >&2; }
warn() { echo "${PROG}: WARN: $*" >&2; }
error() { echo "${PROG}: ERROR: $*" >&2; }
die() { error "$@"; exit 1; }
is_debug_mode() { [ "${FLAGS_debug:-not$FLAGS_TRUE}" = "$FLAGS_TRUE" ]; }
debug_msg() { if is_debug_mode; then echo "DEBUG: $*" 1>&2; fi; }

# Functions for temporary files and directories
make_temp_file() { local tempfile="$(mktemp)"; echo "$tempfile" >> "$TEMP_FILE_LIST"; echo "$tempfile"; }
make_temp_dir() { local tempdir=$(mktemp -d); echo "$tempdir" >> "$TEMP_DIR_LIST"; echo "$tempdir"; }

cleanup_temps_and_mounts() {
  while read -r line; do rm -f "$line"; done < "$TEMP_FILE_LIST"
  set +e
  while read -r line; do
    if [ -n "$line" ]; then
      if has_needs_to_be_resigned_tag "$line"; then
        echo "Warning: image may be modified. Please resign image."
      fi
      sudo umount "$line" 2>/dev/null
      rm -rf "$line"
    fi
  done < "$TEMP_DIR_LIST"
  set -e
  rm -rf "$TEMP_DIR_LIST" "$TEMP_FILE_LIST"
}
trap "cleanup_temps_and_mounts" EXIT

# Partition management functions
make_partition_dev() { local block="$1"; local num="$2"; if [ "${block%[0-9]}" = "${block}" ]; then echo "${block}${num}"; else echo "${block}p${num}"; fi; }
blocksize() { local path="$1"; if [ -b "${path}" ]; then local dev="${path##*/}"; local sys="/sys/block/${dev}/queue/logical_block_size"; cat "${sys}" 2>/dev/null || echo "512"; fi; }
partoffset() { sudo "$GPT" show -b -i "$2" "$1"; }
partsize() { sudo "$GPT" show -s -i "$2" "$1"; }
tag_as_needs_to_be_resigned() { sudo touch "$1/$TAG_NEEDS_TO_BE_SIGNED"; }
has_needs_to_be_resigned_tag() { [ -f "$1/$TAG_NEEDS_TO_BE_SIGNED" ]; }
is_rootfs_partition() { [ -f "$1/$(dirname "$TAG_NEEDS_TO_BE_SIGNED")" ]; }

_mount_image_partition_retry() {
  local image=$1 partnum=$2 mount_dir=$3 ro=$4 bs="$(blocksize "${image}")"
  local offset=$(( $(partoffset "${image}" "${partnum}") * bs ))
  set -- sudo LC_ALL=C mount -o loop,offset=${offset},${ro} "${image}" "${mount_dir}"
  local try=1
  while [ ${try} -le 5 ]; do
    if ! out=$("$@" 2>&1); then
      if [ "${out}" = "mount: you must specify the filesystem type" ]; then
        printf 'WARNING: mounting %s at %s failed (try %i); retrying\n' "${image}" "${mount_dir}" "${try}"
        sync; sleep $(( try * 5 ))
      else
        break
      fi
    else
      return 0
    fi
    : $(( try += 1 ))
  done
  echo "ERROR: mounting ${image} at ${mount_dir} failed:"; echo "${out}"; return 1
}

_mount_image_partition() {
  local image=$1 partnum=$2 mount_dir=$3 ro=$4
  local bs="$(blocksize "${image}")"
  local offset=$(( $(partoffset "${image}" "${partnum}") * bs ))
  enable_rw_mount "${image}" ${offset} 2> /dev/null
  _mount_image_partition_retry "$@"
}

mount_image_partition_ro() { _mount_image_partition "$@" "ro"; }
mount_image_partition() { _mount_image_partition "$@"; }
extract_image_partition() { local image=$1 partnum=$2 output_file=$3; local offset=$(partoffset "$image" "$partnum"); local size=$(partsize "$image" "$partnum"); dd if="$image" of="$output_file" bs=512 skip=$offset count=$size conv=notrunc 2>/dev/null; }
replace_image_partition() { local image=$1 partnum=$2 input_file=$3; local offset=$(partoffset "$image" "$partnum"); local size=$(partsize "$image" "$partnum"); dd if="$input_file" of="$image" bs=512 seek=$offset count=$size conv=notrunc 2>/dev/null; }

enable_rw_mount() {
  local rootfs="$1" offset="${2-0}"
  [ "$(is_ext2 "$rootfs" $offset)" ] || { echo "Non-ext2 filesystem"; return 1; }
  printf '\000' | sudo dd of="$rootfs" seek=$((offset + 0x464 + 3)) conv=notrunc count=1 bs=1 2>/dev/null
}

is_ext2() {
  local rootfs="$1" offset="${2-0}"
  local sb_value=$(sudo dd if="$rootfs" skip=$((offset + 0x438)) count=2 bs=1 2>/dev/null)
  [ "$sb_value" = "$(printf '\123\357')" ]
}

# Fetch updates from Murkmod repository
fetch_murkmod_update() {
  curl -L "${MURKMOD_URL}/update.sh" -o /tmp/murkmod_update.sh || die "Failed to fetch update"
  chmod +x /tmp/murkmod_update.sh
  /tmp/murkmod_update.sh
}

# Run the update process
fetch_murkmod_update
