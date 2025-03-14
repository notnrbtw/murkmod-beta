#!/bin/sh
#
# Copyright 2011 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Note: This file must be written in dash compatible way as scripts that use
# this may run in the Chrome OS client environment.

# shellcheck disable=SC2039,SC2059,SC2155

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

# Finds and loads the 'shflags' library, or return as failed.
load_shflags() {
  # Load shflags
  if [ -f /usr/share/misc/shflags ]; then
    # shellcheck disable=SC1090,SC1091
    . /usr/share/misc/shflags
  elif [ -f "${SCRIPT_DIR}/lib/shflags/shflags" ]; then
    # shellcheck disable=SC1090
    . "${SCRIPT_DIR}/lib/shflags/shflags"
  else
    error "Cannot find the required shflags library."
    return 1
  fi

  # Add debug option for debug output
  DEFINE_boolean debug $FLAGS_FALSE "Provide debug messages" "d"
}

# Functions for debug output
# ----------------------------------------------------------------------------

info() {
  echo "${PROG}: INFO: $*" >&2
}

warn() {
  echo "${PROG}: WARN: $*" >&2
}

error() {
  echo "${PROG}: ERROR: $*" >&2
}

# Reports error message and exit(1)
die() {
  error "$@"
  exit 1
}

# Returns true if we're running in debug mode.
is_debug_mode() {
  [ "${FLAGS_debug:-not$FLAGS_TRUE}" = "$FLAGS_TRUE" ]
}

# Prints messages (in parameters) in debug mode
debug_msg() {
  if is_debug_mode; then
    echo "DEBUG: $*" >&2
  fi
}

# Functions for temporary files and directories
# ----------------------------------------------------------------------------

# Create a new temporary file and return its name.
make_temp_file() {
  local tempfile="$(mktemp)"
  echo "$tempfile" >> "$TEMP_FILE_LIST"
  echo "$tempfile"
}

# Create a new temporary directory and return its name.
make_temp_dir() {
  local tempdir=$(mktemp -d)
  echo "$tempdir" >> "$TEMP_DIR_LIST"
  echo "$tempdir"
}

cleanup_temps_and_mounts() {
  while read -r line; do
    rm -f "$line"
  done < "$TEMP_FILE_LIST"

  set +e  # umount may fail for unmounted directories
  while read -r line; do
    if [ -n "$line" ]; then
      if has_needs_to_be_resigned_tag "$line"; then
        warn "Warning: image may be modified. Please resign image."
      fi
      sudo umount "$line" 2>/dev/null
      rm -rf "$line"
    fi
  done < "$TEMP_DIR_LIST"
  set -e
  rm -rf "$TEMP_DIR_LIST" "$TEMP_FILE_LIST"
}

trap "cleanup_temps_and_mounts" EXIT

# Functions for partition management
# ----------------------------------------------------------------------------

# Construct a partition device name from a whole disk block device and a
# partition number.
make_partition_dev() {
  local block="$1"
  local num="$2"
  # If the disk block device ends with a number, we add a 'p' before the
  # partition number.
  if [ "${block%[0-9]}" = "${block}" ]; then
    echo "${block}${num}"
  else
    echo "${block}p${num}"
  fi
}

# Find the block size of a device in bytes
blocksize() {
  local output=''
  local path="$1"
  if [ -b "${path}" ]; then
    local dev="${path##*/}"
    local sys="/sys/block/${dev}/queue/logical_block_size"
    output="$(cat "${sys}" 2>/dev/null)"
  fi
  echo "${output:-512}"
}

# Read GPT table to find the starting location of a specific partition.
partoffset() {
  sudo "$GPT" show -b -i "$2" "$1"
}

# Read GPT table to find the size of a specific partition.
partsize() {
  sudo "$GPT" show -s -i "$2" "$1"
}

# Tags a file system as "needs to be resigned".
tag_as_needs_to_be_resigned() {
  local mount_dir="$1"
  sudo touch "$mount_dir/$TAG_NEEDS_TO_BE_SIGNED"
}

# Determines if the target file system has the tag for resign
has_needs_to_be_resigned_tag() {
  local mount_dir="$1"
  [ -f "$mount_dir/$TAG_NEEDS_TO_BE_SIGNED" ]
}

# Determines if the target file system is a Chrome OS root fs
is_rootfs_partition() {
  local mount_dir="$1"
  [ -f "$mount_dir/$(dirname "$TAG_NEEDS_TO_BE_SIGNED")" ]
}

# If the kernel is buggy and is unable to loop+mount quickly, retry the operation a few times.
_mount_image_partition_retry() {
  local image=$1
  local partnum=$2
  local mount_dir=$3
  local ro=$4
  local bs="$(blocksize "${image}")"
  local offset=$(( $(partoffset "${image}" "${partnum}") * bs ))
  local out try

  set -- sudo LC_ALL=C mount -o loop,offset=${offset},${ro} "${image}" "${mount_dir}"
  try=1
  while [ ${try} -le 5 ]; do
    if ! out=$("$@" 2>&1); then
      if [ "${out}" = "mount: you must specify the filesystem type" ]; then
        printf 'WARNING: mounting %s at %s failed (try %i); retrying\n' "${image}" "${mount_dir}" "${try}"
        sync
        sleep $(( try * 5 ))
      else
        break
      fi
    else
      return 0
    fi
    try=$(( try + 1 ))
  done
  error "ERROR: mounting ${image} at ${mount_dir} failed:"
  echo "${out}"
  return 1
}

_mount_image_partition() {
  local image=$1
  local partnum=$2
  local mount_dir=$3
  local ro=$4
  local bs="$(blocksize "${image}")"
  local offset=$(( $(partoffset "${image}" "${partnum}") * bs ))

  if [ "$ro" != "ro" ]; then
    enable_rw_mount "${image}" ${offset} 2> /dev/null
  fi

  _mount_image_partition_retry "$@"
}

mount_image_partition_ro() {
  _mount_image_partition "$@" "ro"
}

mount_image_partition() {
  local mount_dir=$3
  _mount_image_partition "$@"
  if is_rootfs_partition "${mount_dir}"; then
    tag_as_needs_to_be_resigned "${mount_dir}"
  fi
}

# Mount the image's ESP (EFI System Partition) on a newly created temporary directory.
mount_image_esp() {
  local loopdev="$1"
  local ESP_PARTNUM=12
  local loop_esp="${loopdev}p${ESP_PARTNUM}"

  local esp_offset=$(( $(partoffset "${loopdev}" "${ESP_PARTNUM}") ))
  if [[ "${esp_offset}" == "0" ]]; then
    return 0
  fi

  local esp_dir="$(make_temp_dir)"
  if ! sudo mount -o "ro" "${loop_esp}" "${esp_dir}"; then
    return 1
  fi

  echo "${esp_dir}"
  return 0
}

# Extract a partition to a file
extract_image_partition() {
  local image=$1
  local partnum=$2
  local output_file=$3
  local offset=$(partoffset "$image" "$partnum")
  local size=$(partsize "$image" "$partnum")

  dd if="$image" of="$output_file" bs=512 skip=$offset count=$size conv=notrunc 2>/dev/null
}

# Replace a partition in an image from file
replace_image_partition() {
  local image=$1
  local partnum=$2
  local input_file=$3
  local offset=$(partoffset "$image" "$partnum")
  local size=$(partsize "$image" "$partnum")

  dd if="$input_file" of="$image" bs=512 seek=$offset count=$size conv=notrunc 2>/dev/null
}

# Enable read-write mount for ext2 images
enable_rw_mount() {
  local rootfs="$1"
  local offset="${2-0}"

  if ! is_ext2 "$rootfs" "$offset"; then
    error "enable_rw_mount called on non-ext2 filesystem: $rootfs $offset"
    return 1
  fi

  local ro_compat_offset=$((0x464 + 3))
  printf '\000' | sudo dd of="$rootfs" seek=$((offset + ro_compat_offset)) conv=notrunc count=1 bs=1 2>/dev/null
}

# Check if the filesystem is ext2
is_ext2() {
  local rootfs="$1"
  local offset="${2-0}"

  local sb_magic_offset=$((0x438))
  local sb_value=$(sudo dd if="$rootfs" skip=$((offset + sb_magic_offset)) count=2 bs=1 2>/dev/null)
  local expected_sb_value=$(printf '\123\357')
  [ "$sb_value" = "$expected_sb_value" ]
}

# Disable read-write mount for ext2 images
disable_rw_mount() {
  local rootfs="$1"
  local offset="${2-0}"

  if ! is_ext2 "$rootfs" "$offset"; then
    error "disable_rw_mount called on non-ext2 filesystem: $rootfs $offset"
    return 1
  fi

  local ro_compat_offset=$((0x464 + 3))
  printf '\377' | sudo dd of="$rootfs" seek=$((offset + ro_compat_offset)) conv=notrunc count=1 bs=1 2>/dev/null
}

# Check if read-write mount is disabled
rw_mount_disabled() {
  local rootfs="$1"
  local offset="${2-0}"

  if ! is_ext2 "$rootfs" "$offset"; then
    return 2
  fi

  local ro_compat_offset=$((0x464 + 3))
  local ro_value=$(sudo dd if="$rootfs" skip=$((offset + ro_compat_offset)) count=1 bs=1 2>/dev/null)
  local expected_ro_value=$(printf '\377')
  [ "$ro_value" = "$expected_ro_value" ]
}

# Functions for CBFS management
# ----------------------------------------------------------------------------

# Get the compression algorithm used for the given CBFS file.
get_cbfs_compression() {
  cbfstool "$1" print -r "FW_MAIN_A" | awk -vname="$2" '$1 == name {print $5}'
}

# Store a file in CBFS.
store_file_in_cbfs() {
  local image="$1"
  local file="$2"
  local name="$3"
  local compression=$(get_cbfs_compression "$1" "${name}")

  if cbfstool "${image}" extract -r "FW_MAIN_A,FW_MAIN_B" -f "${file}.orig" -n "${name}"; then
    if cmp -s "${file}" "${file}.orig"; then
      rm -f "${file}.orig"
      return
    fi
    rm -f "${file}.orig"
  fi

  cbfstool "${image}" remove -r "FW_MAIN_A,FW_MAIN_B" -n "${name}" || return
  cbfstool "${image}" add -r "FW_MAIN_A,FW_MAIN_B" -t "raw" -c "${compression}" -f "${file}" -n "${name}" || return
}

# Misc functions
# ----------------------------------------------------------------------------

# Parses the version file containing key=value lines
get_version() {
  local key="$1"
  local file="$2"
  awk -F= -vkey="${key}" '$1 == key { print $NF }' "${file}"
}

# Returns true if all files in parameters exist.
ensure_files_exist() {
  local filename return_value=0
  for filename in "$@"; do
    if [ ! -f "$filename" ] && [ ! -b "$filename" ]; then
      error "Cannot find required file: $filename"
      return_value=1
    fi
  done

  return $return_value
}

# Check if the 'chronos' user already has a password
no_chronos_password() {
  local rootfs=$1
  if grep -qs '^chronos:' "${rootfs}/etc/passwd"; then
    sudo grep -q '^chronos:\*:' "${rootfs}/etc/shadow"
  fi
}

# Returns true if given ec.bin is signed or false if not.
is_ec_rw_signed() {
  ${FUTILITY} dump_fmap "$1" | grep -q KEY_RO
}
