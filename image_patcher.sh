#!/bin/bash
# image_patcher.sh - A script to patch ChromeOS recovery images

SSD_UTIL="/usr/share/vboot/bin/ssd_util"
ROOT=""
loop=""
milestone=""
bootsplash="0"
unfuckstateful="1"

# Display ascii info at the beginning
ascii_info() {
    echo "Murkmod Image Patcher"
    echo "======================"
    echo "Welcome to the image patching process."
}

# Trap signals for proper cleanup
traps() {
    trap 'echo "Exiting..."; exit 1' SIGINT SIGTERM
}

# Configure the required binaries and install dependencies
configure_binaries() {
    echo "Configuring binaries..."
    apt-get update && apt-get install -y curl jq
}

# Move binaries to the correct directories
move_bin() {
    if [ -f "$1" ]; then
        mv "$1" "$ROOT/usr/bin/"
    fi
}

# Patch the root filesystem with the necessary files
patch_root() {
    echo "Patching root filesystem..."
    
    # Install necessary files into the system
    install "chromeos_startup.sh" $ROOT/sbin/chromeos_startup.sh
    chmod 755 $ROOT/sbin/chromeos_startup.sh

    if [ "$milestone" -gt "116" ]; then
        echo "Detected newer version of CrOS, using new chromeos_startup"
        move_bin "$ROOT/sbin/chromeos_startup"
        install "chromeos_startup.sh" $ROOT/sbin/chromeos_startup
        chmod 755 $ROOT/sbin/chromeos_startup
        touch $ROOT/new-startup
    else
        move_bin "$ROOT/sbin/chromeos_startup.sh"
        install "chromeos_startup.sh" $ROOT/sbin/chromeos_startup.sh
        chmod 755 $ROOT/sbin/chromeos_startup.sh
    fi

    echo "Installing murkmod components..."
    install "daemon.sh" $ROOT/sbin/murkmod-daemon.sh
    move_bin "$ROOT/usr/bin/crosh"
    install "mush.sh" $ROOT/usr/bin/crosh

    echo "Installing startup services..."
    install "pre-startup.conf" $ROOT/etc/init/pre-startup.conf
    install "cr50-update.conf" $ROOT/etc/init/cr50-update.conf

    echo "Installing other utilities..."
    install "ssd_util.sh" $ROOT/usr/share/vboot/bin/ssd_util.sh
    install "image_patcher.sh" $ROOT/sbin/image_patcher.sh
    install "crossystem_boot_populator.sh" $ROOT/sbin/crossystem_boot_populator.sh
    install "ssd_util.sh" $ROOT/usr/share/vboot/bin/ssd_util.sh

    mkdir -p "$ROOT/etc/opt/chrome/policies/managed"
    install "pollen.json" $ROOT/etc/opt/chrome/policies/managed/policy.json

    echo "Setting correct permissions..."
    chmod 777 $ROOT/sbin/murkmod-daemon.sh $ROOT/usr/bin/crosh $ROOT/usr/share/vboot/bin/ssd_util.sh $ROOT/sbin/image_patcher.sh $ROOT/etc/opt/chrome/policies/managed/policy.json $ROOT/sbin/crossystem_boot_populator.sh $ROOT/usr/share/vboot/bin/ssd_util.sh    

    echo "Done."
}

# Fetch a specific value from lsb-release or another file
lsbval() {
    local key="$1"
    local lsbfile="${2:-/etc/lsb-release}"

    if ! echo "${key}" | grep -Eq '^[a-zA-Z0-9_]+$'; then
        return 1
    fi

    sed -E -n -e \
    "/^[[:space:]]*${key}[[:space:]]*=/{
      s:^[^=]+=[[:space:]]*:: 
      s:[[:space:]]+$:: 
      p 
    }" "${lsbfile}"
}

get_asset() {
    curl -s -f "https://api.github.com/repos/rainestorme/murkmod/contents/$1" | jq -r ".content" | base64 -d
}

install() {
    TMP=$(mktemp)
    get_asset "$1" >"$TMP"
    if [ "$?" == "1" ] || ! grep -q '[^[:space:]]' "$TMP"; then
        echo "Failed to install $1 to $2"
        rm -f "$TMP"
        exit
    fi
    # Don't mv, that would break permissions
    cat "$TMP" >"$2"
    rm -f "$TMP"
}

# Get the version of the image passed by the user
get_image_version() {
    local image="$1"
    
    if [ ! -f "$image" ]; then
        echo "Image file does not exist."
        exit 1
    fi
    
    # Extract the version (replace with actual logic depending on your image format)
    milestone=$(blkid -o value -s VERSION "$image")
    if [ -z "$milestone" ]; then
        echo "Could not determine version from image."
        exit 1
    fi
    echo "Detected image version: $milestone"
}

# Main function to patch the image
main() {
    traps
    ascii_info
    configure_binaries
    echo "Using $SSD_UTIL"

    if [ -z "$1" ] || [ ! -f "$1" ]; then
        echo "You must specify the path to the recovery image."
        exit 1
    fi
    
    get_image_version "$1"

    # Set the bootsplash file
    if [ -z "$2" ]; then
        echo "Not using a custom bootsplash."
        bootsplash="0"
    elif [ "$2" == "cros" ]; then
        echo "Using default cros bootsplash."
        bootsplash="cros"
    elif [ ! -f "$2" ]; then
        echo "File $2 not found for custom bootsplash."
        bootsplash="0"
    else
        echo "Using custom bootsplash from $2"
        bootsplash=$2
    fi

    # Set the stateful partition behavior
    if [ -z "$3" ]; then
        unfuckstateful="1"
    else 
        unfuckstateful="$3"
    fi

    if [ "$unfuckstateful" == "1" ]; then
        echo "Stateful partition will be unfucked upon boot."  
    fi

    local bin=$1
    echo "Creating loop device..."
    local loop=$(losetup -f | tail -1)
    if [[ -z "$loop" ]]; then
        echo "No free loop device. Exiting..."
        exit 1
    else
        echo $loop
    fi

    echo "Setting up loop with $loop and $bin"
    losetup -P "$loop" "$bin"

    echo "Disabling kernel verity..."
    $SSD_UTIL --debug --remove_rootfs_verification -i ${loop} --partitions 4
    echo "Enabling RW mount..."
    $SSD_UTIL --debug --remove_rootfs_verification --no_resign_kernel -i ${loop} --partitions 2

    # Sync to ensure the changes are written
    sync

    echo "Mounting target..."
    mkdir /tmp/mnt || :
    mount "${loop}p3" /tmp/mnt

    ROOT=/tmp/mnt
    patch_root

    # Handle custom or default bootsplash
    if [ "$bootsplash" != "cros" ]; then
        if [ "$bootsplash" != "0" ]; then
            echo "Adding custom bootsplash..."
            for i in $(seq -f "%02g" 0 30); do
                rm $ROOT/usr/share/chromeos-assets/images_100_percent/boot_splash_frame${i}.png
            done
            cp $bootsplash $ROOT/usr/share/chromeos-assets/images_100_percent/boot_splash_frame00.png
        else
            echo "Adding murkmod bootsplash..."
            install "chromeos-bootsplash-v2.png" /tmp/bootsplash.png
            for i in $(seq -f "%02g" 0 30); do
                rm $ROOT/usr/share/chromeos-assets/images_100_percent/boot_splash_frame${i}.png
            done
            cp /tmp/bootsplash.png $ROOT/usr/share/chromeos-assets/images_100_percent/boot_splash_frame00.png
            rm /tmp/bootsplash.png
        fi
    fi

    if [ "$unfuckstateful" == "0" ]; then
        touch $ROOT/stateful_unfucked
        chmod 777 $ROOT/stateful_unfucked
    fi

    sleep 2
    sync
    echo "Done. Have fun."

    umount "$ROOT"
    sync
    losetup -D "$loop"
    sync
    sleep 2
    rm -rf /tmp/mnt
    leave
}

if [ "$0" = "$BASH_SOURCE" ]; then
    stty sane
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root."
        exit 1
    fi
    main "$@"
fi
