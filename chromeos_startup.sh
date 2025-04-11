#!/bin/bash

rm -f /fakemurk_startup_log
rm -r /fakemurk_startup_err
rm -f /fakemurk-log

touch /startup_log
chmod 775 /startup_log
exec 3>&1 1>>/startup_log 2>&1

run_plugin() {
    bash "$1"
}

runjob() {
    clear
    trap 'kill -2 $! >/dev/null 2>&1' INT
    (
        $@
    )
    trap '' INT
    clear
}

. /usr/share/misc/chromeos-common.sh
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
DST=$(get_largest_cros_blockdev)
if [ -z "$DST" ]; then
    DST=/dev/mmcblk0
fi

cat <<EOF >/usr/share/chromeos-assets/text/boot_messages/en/block_devmode_virtual.txt
ChromeOS detected developer mode and is trying to disable it to comply with FWMP.
This is most likely a bug and should be reported to the Murkmod Issues page: 
https://github.com/notnrbtw/murkmod-beta/issues
EOF

cat <<EOF >/usr/share/chromeos-assets/text/boot_messages/en/self_repair.txt
System is attempting self-repair.
If this issue persists, please report it at:
https://github.com/notnrbtw/murkmod-beta/issues
EOF

echo "System performing startup checks..." >/usr/share/chromeos-assets/text/boot_messages/en/power_wash.txt

crossystem.old block_devmode=0 

# Stage SSHD
if [ ! -f /sshd_staged ]; then
    echo "Staging sshd..."
    mkdir -p /ssh/root
    chmod -R 777 /ssh/root

    echo "Generating SSH keypair..."
    ssh-keygen -f /ssh/root/key -N '' -t rsa >/dev/null
    cp /ssh/root/key /rootkey
    chmod 600 /ssh/root
    chmod 644 /rootkey

    echo "Creating SSH config..."
    cat >/ssh/config <<-EOF
AuthorizedKeysFile /ssh/%u/key.pub
StrictModes no
HostKey /ssh/root/key
Port 1337
EOF

    touch /sshd_staged
    echo "SSHD staged."
fi

if [ -f /population_required ]; then
    echo "Populating crossystem..."
    /sbin/crossystem_boot_populator.sh
    vpd -i RW_VPD -s check_enrollment=1
    rm -f /population_required
fi

echo "Launching SSHD..."
/usr/sbin/sshd -f /ssh/config &

if [ -f /logkeys/active ]; then
    echo "Found logkeys flag, launching..."
    /usr/bin/logkeys -s -m /logkeys/keymap.map -o /mnt/stateful_partition/keylog
fi

if [ ! -f /stateful_unfucked ]; then
    echo "Formatting stateful partition..."
    if mkfs.ext4 -F "${DST}p1"; then
        touch /stateful_unfucked
        echo "Stateful partition formatted, rebooting..."
        reboot
    else
        echo "ERROR: Failed to format stateful partition!"
    fi
else
    echo "Stateful already formatted, mounting..."
    stateful_dev="${DST}p1"
    first_mount_dir=$(mktemp -d)
    if mount "$stateful_dev" "$first_mount_dir"; then
        echo "Mounted stateful partition."
    else
        echo "ERROR: Failed to mount stateful partition!" >&2
        exit 1
    fi

    plugin_dir="$first_mount_dir/murkmod/plugins"
    temp_dir=$(mktemp -d)

    cp -r "$plugin_dir"/* "$temp_dir"
    umount "$stateful_dev"
    rmdir "$first_mount_dir"

    for file in "$temp_dir"/*.sh; do
        if grep -q "startup_plugin" "$file"; then
            echo "Starting plugin $file..."
            runjob run_plugin "$file"
        fi
    done

    echo "Startup complete. Handing over to real startup..."
    if [ ! -f /new-startup ]; then
        exec /sbin/chromeos_startup.sh.old
    else 
        exec /sbin/chromeos_startup.old
    fi
fi
