#!/bin/bash

# Logging setup
rm -f /fakemurk_startup_log
rm -r /fakemurk_startup_err
rm -f /fakemurk-log

touch /startup_log
chmod 775 /startup_log
exec 3>&1 1>>/startup_log 2>&1

# Helper functions
run_plugin() {
    bash "$1"
}

runjob() {
    clear
    trap 'kill -2 $! >/dev/null 2>&1' INT
    (
        # shellcheck disable=SC2068
        $@
    )
    trap '' INT
    clear
}

# Device detection
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

# Boot messages
cat <<EOF >/usr/share/chromeos-assets/text/boot_messages/en/block_devmode_virtual.txt
Oh fuck - ChromeOS is trying to kill itself.
ChromeOS detected developer mode and is trying to disable it to
comply with FWMP. This is most likely a bug and should be reported to
the murkmod GitHub Issues page.
EOF
cat <<EOF >/usr/share/chromeos-assets/text/boot_messages/en/self_repair.txt
oops UwU i did a little fucky wucky and your system is trying to
repair itself~ sorry OwO
EOF
echo "i sure hope you did that on purpose (powerwashing system)" >/usr/share/chromeos-assets/text/boot_messages/en/power_wash.txt

# Attempt to prevent devmode screen. (Verify GBB flags are correct in recovery mode)
echo "Attempting to disable devmode screen..."
crossystem.old block_devmode=0
echo "crossystem block_devmode set."

# SSHD setup
if [ ! -f /sshd_staged ]; then
    echo "Staging sshd..."
    mkdir -p /ssh/root
    chmod -R 777 /ssh/root

    echo "Generating ssh keypair..."
    ssh-keygen -f /ssh/root/key -N '' -t rsa >/dev/null
    cp /ssh/root/key /rootkey
    chmod 600 /ssh/root
    chmod 644 /rootkey

    echo "Creating config..."
    cat >/ssh/config <<-EOF
AuthorizedKeysFile /ssh/%u/key.pub
StrictModes no
HostKey /ssh/root/key
Port 1337
EOF

    touch /sshd_staged
    echo "Staged sshd."
fi

# Crossystem population
if [ -f /population_required ]; then
    echo "Populating crossystem..."
    /sbin/crossystem_boot_populator.sh
    echo "Done. Setting check_enrollment..."
    vpd -i RW_VPD -s check_enrollment=1
    echo "Removing flag..."
    rm -f /population_required
fi

# Start SSHD
echo "Launching sshd..."
/usr/sbin/sshd -f /ssh/config &

# Logkeys (optional)
if [ -f /logkeys/active ]; then
    echo "Found logkeys flag, launching..."
    /usr/bin/logkeys -s -m /logkeys/keymap.map -o /mnt/stateful_partition/keylog
fi

# Stateful partition handling
if [ ! -f /stateful_unfucked ]; then
    echo "Unfucking stateful..."
    yes | mkfs.ext4 "${DST}p1"
    touch /stateful_unfucked
    echo "Done, rebooting..."
    reboot
else
    echo "Stateful already unfucked, doing temp stateful mount..."
    stateful_dev="${DST}p1"
    first_mount_dir=$(mktemp -d)
    mount "$stateful_dev" "$first_mount_dir"
    echo "Mounted stateful on $first_mount_dir, looking for startup plugins..."

    plugin_dir="$first_mount_dir/murkmod/plugins"
    temp_dir=$(mktemp -d)

    cp -r "$plugin_dir"/* "$temp_dir"
    echo "Copied files to $temp_dir, unmounting and cleaning up..."

    umount "$stateful_dev"
    rmdir "$first_mount_dir"

    echo "Finding startup plugins..."
    for file in "$temp_dir"/*.sh; do
        if grep -q "startup_plugin" "$file"; then
            echo "Starting plugin $file..."
            runjob run_plugin "$file"
        fi
    done

    echo "Plugins run. Handing over to real startup..."
    if [ ! -f /new-startup ]; then
        exec /sbin/chromeos_startup.sh.old
    else
        exec /sbin/chromeos_startup.old
    fi
fi
