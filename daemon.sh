#!/bin/bash

run_plugin() {
    local script=$1
    while true; do
        bash "$script"
    done & disown
}

wait_for_startup() {
    while true; do
        if [ "$(cryptohome --action=is_mounted)" == "true" ]; then
            break
        fi
        sleep 1
    done
}

get_largest_cros_blockdev() {
    local largest size dev_name tmp_size remo
    size=0
    for blockdev in /sys/block/*; do
        dev_name="${blockdev##*/}"
        echo "$dev_name" | grep -q '^\(loop\|ram\)' && continue
        tmp_size=$(cat "$blockdev"/size)
        remo=$(cat "$blockdev"/removable)
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

doas() {
    ssh -t -p 1337 -i /rootkey -oStrictHostKeyChecking=no root@127.0.0.1 "$@"
}

lsbval() {
    local key="$1"
    local lsbfile="${2:-/etc/lsb-release}"

    if ! echo "${key}" | grep -Eq '^[a-zA-Z0-9_]+$'; then
        return 1
    fi

    sed -E -n -e \
        "/^[[:space:]]*${key}[[:space:]]*=/ {
            s:^[^=]+=[[:space:]]*::
            s:[[:space:]]+$::
            p
        }" "${lsbfile}"
}

get_booted_kernnum() {
    if doas "((\$(cgpt show -n \"$dst\" -i 2 -P) > \$(cgpt show -n \"$dst\" -i 4 -P)))"; then
        echo -n 2
    else
        echo -n 4
    fi
}

opposite_num() {
    case "$1" in
        2) echo -n 4 ;;
        4) echo -n 2 ;;
        3) echo -n 5 ;;
        5) echo -n 3 ;;
        *) return 1 ;;
    esac
}

# Ensure TPM ownership is taken
{
    until tpm_manager_client take_ownership; do
        echo "Failed to take ownership of TPM!"
        sleep 0.5
    done

    # Manage racer process
    {
        launch_racer(){
            echo "Launching racer at $(date)"
            {
                if which device_management_client >/dev/null 2>&1; then
                    while true; do
                        device_management_client --action=remove_firmware_management_parameters >/dev/null 2>&1
                    done
                else
                    while true; do
                        cryptohome --action=remove_firmware_management_parameters
