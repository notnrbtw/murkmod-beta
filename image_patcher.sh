#!/bin/bash

# Ensure necessary scripts are sourced
image_patcher.sh

# Metadata
CURRENT_MAJOR=6
CURRENT_MINOR=1
CURRENT_VERSION=2 # Updated version for clarity

# Display script information
ascii_info() {
    echo -e " __ .\n _____ __ | | __ _____ ____ __| /\n / | | _ __ \\ |/ // \\ / _ \\ / __ | \n| Y Y \\ | /| | / <| Y Y ( <> ) // | \n||| // || ||_ _|| /_/_ | \n / / / /\n"
    echo " The fakemurk plugin manager - v$CURRENT_MAJOR.$CURRENT_MINOR.$CURRENT_VERSION"
}

nullify_bin() {
    cat <<-EOF >$1
    #!/bin/bash
    exit
    EOF
    chmod 777 $1
}

# Source common functions
. /usr/share/misc/chromeos-common.sh || :

# Error handling
traps() {
    set -e
    trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
    trap 'echo ""${last_command}" command failed with exit code $?. THIS IS A BUG, REPORT IT HERE https://github.com/MercuryWorkshop/fakemurk"' EXIT
}

leave() {
    trap - EXIT
    echo "Exiting successfully"
    exit
}

# Escape special characters for sed
sed_escape() {
    echo -n "$1" | while read -n1 ch; do
        if [[ "$ch" == "" ]]; then
            echo -n "\n"
        fi
        echo -n "\x$(printf %x '"$ch")"
    done
}

move_bin() {
    if test -f "$1"; then mv "$1" "$1.old"; fi
}

disable_autoupdates() {
    sed -i "$ROOT/etc/lsb-release" -e "s/CHROMEOS_AUSERVER=.*/CHROMEOS_AUSERVER=$(sed_escape "https://updates.gooole.com/update")/"
    move_bin "$ROOT/usr/sbin/chromeos-firmwareupdate"
    nullify_bin "$ROOT/usr/sbin/chromeos-firmwareupdate"
    rm -rf "$ROOT/opt/google/cr50/firmware/" || :
}

SCRIPT_DIR=$(dirname "$0")

configure_binaries() {
    if [ -f /sbin/ssd_util.sh ]; then
        SSD_UTIL=/sbin/ssd_util.sh
    elif [ -f /usr/share/vboot/bin/ssd_util.sh ]; then
        SSD_UTIL=/usr/share/vboot/bin/ssd_util.sh
    elif [ -f "${SCRIPT_DIR}/lib/ssd_util.sh" ]; then
        SSD_UTIL="${SCRIPT_DIR}/lib/ssd_util.sh"
    else
        echo "ERROR: Cannot find the required ssd_util script. Please ensure you're executing this script inside the directory it resides in."
        exit 1
    fi
}

patch_root() {
    echo "Staging populator..." >$ROOT/population_required >$ROOT/reco_patched
    echo "Murkmod-ing root..."
    echo "Disabling autoupdates..."
    disable_autoupdates
    local milestone=$(lsbval CHROMEOS_RELEASE_CHROME_MILESTONE $ROOT/etc/lsb-release)
    echo "Installing startup scripts..."
    move_bin "$ROOT/sbin/chromeos_startup.sh"
    
    if [ "$milestone" -ge "120" ]; then
        echo "Detected newer version of CrOS, using new chromeos_startup"
        move_bin "$ROOT/sbin/chromeos_startup"
        install "chromeos_startup.sh" $ROOT/sbin/chromeos_startup
        chmod 755 $ROOT/sbin/chromeos_startup
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
    mkdir -p "$ROOT/etc/opt/chrome/policies/managed"
    install "pollen.json" $ROOT/etc/opt/chrome/policies/managed/policy.json
    echo "Chmod-ing everything..."
    chmod 777 $ROOT/sbin/murkmod-daemon.sh $ROOT/usr/bin/crosh $ROOT/usr/share/vboot/bin/ssd_util.sh $ROOT/sbin/image_patcher.sh $ROOT/etc/opt/chrome/policies/managed/policy.json $ROOT/sbin/crossystem_boot_populator.sh $ROOT/usr/share/vboot/bin/ssd_util.sh
    echo "Done."
}

lsbval() {
    local key="$1"
    local lsbfile="${2:-/etc/lsb-release}"
    if ! echo "${key}" | grep -Eq '^[a-zA-Z0-9_]+$'; then return 1; fi
    sed -E -n -e "/^[[:space:]]${key}[[:space:]]=/{ s:^[^=]+=[[:space:]]*::; s:[[:space:]]+$::; p }" "${lsbfile}"
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
    cat "$TMP" >"$2"
    rm -f "$TMP"
}

main() {
    traps
    ascii_info
    configure_binaries
    echo $SSD_UTIL

    if [ -z $1 ] || [ ! -f $1 ]; then
        echo "$1 isn't a real file! You need to pass the path to the recovery image. Optional args: <unfuck stateful: int 0 or 1>"
        exit
    fi

    local bin=$1
    echo "Creating loop device..."
    local loop=$(losetup -f | tail -1)
    if [[ -z "$loop" ]]; then
        echo "No free loop device. Exiting..."
        exit 1
    fi
    echo $loop
    echo "Setting up loop with $loop and $bin"
    losetup -P "$loop" "$bin"

    echo "Disabling kernel verity..."
    $SSD_UTIL --debug --remove_rootfs_verification -i ${loop} --partitions 4
    echo "Enabling RW mount..."
    $SSD_UTIL --debug --remove_rootfs_verification --no_resign_kernel -i ${loop} --partitions 2

    sync
    echo "Mounting target..."
    mkdir /tmp/mnt || :
    mount "${loop}p3" /tmp/mnt

    ROOT=/tmp/mnt
    patch_root

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

# Run the script
if [ "$0" = "$BASH_SOURCE" ]; then
    stty sane
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root"
        exit
    fi
    main "$@"
fi
