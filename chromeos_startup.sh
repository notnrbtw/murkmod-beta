#!/bin/bash

# Clear previous logs
rm -f /fakemurk_startup_log
rm -r /fakemurk_startup_err
rm -f /fakemurk-log

# Create and set permissions for startup log
touch /startup_log
chmod 775 /startup_log
exec 3>&1 1>>/startup_log 2>&1

# Function to run a plugin
run_plugin() {
    bash "$1"
}

# Function to run a job while handling interruptions
runjob() {
    clear
    trap 'kill -2 $! >/dev/null 2>&1' INT
    (
        "$@"
    )
    trap '' INT
    clear
}

# Source common functions
. /usr/share/misc/chromeos-common.sh

# Function to get the largest Chrome OS block device
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

# Set destination device
DST=$(get_largest_cros_blockdev)
if [ -z "$DST" ]; then
    DST=/dev/mmcblk0
fi

# Funny boot messages
cat <<EOF >/usr/share/chromeos-assets/text/boot_messages/en/block_devmode_virtual.txt
Oh no - ChromeOS is trying to disable developer mode!
This is likely a bug and should be reported to the murkmod GitHub Issues page.
EOF
cat <<EOF >/usr/share/chromeos-assets/text/boot_messages/en/self_repair.txt
Oops! Something went wrong, and your system is attempting to repair itself.
EOF

# Single-liner boot message
echo "Powerwashing system, I hope you did that on purpose." >/usr/share/chromeos-assets/text/boot_messages/en/power_wash.txt

# Prevent ChromeOS from disabling developer mode
crossystem.old block_devmode=0

# Stage SSH daemon setup
if [ ! -f /sshd_staged ]; then
    echo "Staging sshd..."
    mkdir -p /ssh/root
    chmod -R 700 /ssh/root

    echo "Generating SSH keypair..."
    ssh-keygen -f /ssh/root/key -N '' -t rsa >/dev/null
    cp /ssh/root/key /rootkey
    chmod 600 /ssh/root/key
    chmod 644 /rootkey

    echo "Creating SSH config..."
    cat >/ssh/config <<-EOF
AuthorizedKeysFile /ssh/%u/key.pub
StrictModes no
HostKey /ssh/root/key
Port 1337
EOF

    touch /sshd_staged
    echo "Staged sshd."
fi

# Populate crossystem if required
if [ -f /population_required ]; then
    echo "Populating crossystem..."
    /sbin/crossystem_boot_populator.sh
    echo "Done. Setting check_enrollment..."
    vpd -i RW_VPD -s check_enrollment=1
    echo "Removing flag..."
    rm -f /population_required
fi

# Launch SSH daemon
echo "Launching sshd..."
/usr/sbin/sshd -f /ssh/config &

# Launch logkeys if the flag is active
if [ -f /logkeys/active ]; then
    echo "Found logkeys flag, launching..."
    /usr/bin/logkeys -s -m /logkeys/keymap.map -o /mnt/stateful_partition/keylog &
fi

# Unmount and format stateful partition if necessary
if [ ! -f /stateful_unfucked ]; then
    echo "Unfucking stateful..."
    yes | mkfs.ext4 "${DST}p1"
    touch /stateful_unfucked
    echo "Done, rebooting..."
    reboot
else
    echo "Stateful already unfucked, performing temporary stateful mount..."
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
