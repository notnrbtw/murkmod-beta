#!/bin/bash

# Run a plugin in the background
run_plugin() {
    local script=$1
    while true; do
        bash "$script"
    done & disown
}

# Wait until the cryptohome is mounted
wait_for_startup() {
    while true; do
        if [ "$(cryptohome --action=is_mounted)" == "true" ]; then
            break
        fi
        sleep 1
    done
}

# Get the largest block device (excluding loops, RAM, and removable)
get_largest_cros_blockdev() {
    local largest size dev_name tmp_size remo
    size=0
    for blockdev in /sys/block/*; do
        dev_name="${blockdev##*/}"
        echo "$dev_name" | grep -q '^\(loop\|ram\)' && continue
        tmp_size=$(cat "$blockdev/size")
        remo=$(cat "$blockdev/removable")
        if [ "$tmp_size" -gt "$size" ] && [ "${remo:-0}" -eq 0 ]; then
            case "$(sfdisk -l -o name "/dev/$dev_name" 2>/dev/null)" in
                *STATE*KERN-A*ROOT-A*KERN-B*ROOT-B*)
                    largest="/dev/$dev_name"
                    size="$tmp_size"
                    ;;
            esac
        fi
    done
    echo "$largest"
}

# Simple SSH wrapper for elevated commands
doas() {
    ssh -t -p 1337 -i /rootkey -oStrictHostKeyChecking=no root@127.0.0.1 "$@"
}

# Extract a value from /etc/lsb-release or custom file
lsbval() {
  local key="$1"
  local lsbfile="${2:-/etc/lsb-release}"

  if ! echo "${key}" | grep -Eq '^[a-zA-Z0-9_]+$'; then
    return 1
  fi

  sed -E -n -e "/^[[:space:]]*${key}[[:space:]]*=/{
      s:^[^=]+=[[:space:]]*::;
      s:[[:space:]]+$::;
      p
  }" "${lsbfile}"
}

# Get the booted kernel number based on the device status
get_booted_kernnum() {
    if doas "((\$(cgpt show -n \"$dst\" -i 2 -P) > \$(cgpt show -n \"$dst\" -i 4 -P)))"; then
        echo -n 2
    else
        echo -n 4
    fi
}

# Get the opposite kernel number (2 <-> 4)
opposite_num() {
    case "$1" in
        "2") echo -n 4 ;;
        "4") echo -n 2 ;;
        "3") echo -n 5 ;;
        "5") echo -n 3 ;;
        *) return 1 ;;
    esac
}

# Main script body
{
    # Take TPM ownership and repeat if fails
    until tpm_manager_client take_ownership; do
        echo "Failed to take ownership of TPM!"
        sleep 0.5
    done

    # Launch racer to bypass firmware management parameters
    launch_racer() {
        echo "Launching racer at $(date)"
        if which device_management_client >/dev/null 2>&1; then
            while true; do
                device_management_client --action=remove_firmware_management_parameters >/dev/null 2>&1
            done
        else
            while true; do
                cryptohome --action=remove_firmware_management_parameters >/dev/null 2>&1
            done
        fi
    }
    launch_racer
    while true; do
        echo "Checking cryptohome status"
        if [ "$(cryptohome --action=is_mounted)" == "true" ]; then
            if [ -n "$RACERPID" ]; then
                echo "Logged in, terminating racer..."
                sleep 60
                kill -9 "$RACERPID"
                echo "Racer terminated at $(date)"
                unset RACERPID
            fi
        else
            if [ -z "$RACERPID" ]; then
                launch_racer
            fi
        fi
        sleep 10
    done
} &

# VPD management loop (for check_enrollment and devmode)
{
    while true; do
        vpd -i RW_VPD -s check_enrollment=0 >/dev/null 2>&1
        vpd -i RW_VPD -s block_devmode=0 >/dev/null 2>&1
        crossystem.old block_devmode=0 >/dev/null 2>&1
        sleep 15
    done
} &

# Disable extension processes based on Downloads folder contents
{
    while true; do
        if test -d "/home/chronos/user/Downloads/disable-extensions"; then
            kill -9 $(pgrep -f "\-\-extension\-process") 2>/dev/null
            sleep 0.5
        else
            sleep 5
        fi
    done
} &

# Handle emergency restore from backup (if flagged)
{
    echo "Waiting for boot on emergency restore..."
    wait_for_startup
    echo "Checking for restore flag..."
    if [ -f /mnt/stateful_partition/restore-emergency-backup ]; then
        echo "Restore flag found!"
        dst=$(get_largest_cros_blockdev)
        tgt_kern=$(opposite_num $(get_booted_kernnum))
        tgt_root=$(( $tgt_kern + 1 ))

        kerndev="${dst}p${tgt_kern}"
        rootdev="${dst}p${tgt_root}"

        if [ -f /mnt/stateful_partition/murkmod/kern_backup.img ] && [ -f /mnt/stateful_partition/murkmod/root_backup.img ]; then
            echo "Backup files found! Restoring kernel..."
            dd if=/mnt/stateful_partition/murkmod/kern_backup.img of=$kerndev bs=4M status=progress
            echo "Restoring rootfs..."
            dd if=/mnt/stateful_partition/murkmod/root_backup.img of=$rootdev bs=4M status=progress
            echo "Removing restore flag and backup files..."
            rm -f /mnt/stateful_partition/restore-emergency-backup
            rm -f /mnt/stateful_partition/murkmod/kern_backup.img
            rm -f /mnt/stateful_partition/murkmod/root_backup.img
            echo "Restored successfully!"
        else
            echo "Missing backup image, aborting restore!"
            rm -f /mnt/stateful_partition/restore-emergency-backup
        fi
    else 
        echo "No need to restore."
    fi
} &

# Handle daemon plugins (ensure they run after startup)
{
    echo "Waiting for boot on daemon plugins..."
    wait_for_startup
    echo "Finding daemon plugins..."
    for file in /mnt/stateful_partition/murkmod/plugins/*.sh; do
        if grep -q "daemon_plugin" "$file"; then
            echo "Spawning plugin $file..."
            run_plugin "$file"
        fi
        sleep 1
    done
} &

# Handle fix-mush task
{
    while true; do
        if test -d "/home/chronos/user/Downloads/fix-mush"; then
            cat << 'EOF' > /usr/bin/crosh
mush_info() {
    echo "This is an emergency backup shell! If you triggered this accidentally, type the following command at the prompt:"
    echo "bash <(curl -SLk https://raw.githubusercontent.com/notnrbtw/murkmod-beta/main/murkmod.sh)"
}

doas() {
    ssh -t -p 1337 -i /rootkey -oStrictHostKeyChecking=no root@127.0.0.1 "$@"
}

runjob() {
    trap 'kill -2 $! >/dev/null 2>&1' INT
    (
        # shellcheck disable=SC2068
        $@
    )
    trap '' INT
}

mush_info
runjob doas "bash"
EOF
            sleep 10
        else
            sleep 5
        fi
    done
} &
