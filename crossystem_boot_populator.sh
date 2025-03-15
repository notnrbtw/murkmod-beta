#!/bin/bash

# crossystem.sh v3.0.0
# made by r58Playz and stackoverflow
# emulates crossystem but with static values to trick chromeos and google
# version history:
# v3.0.0 - implemented mutable crossystem values
# v2.0.0 - implemented all functionality
# v1.1.1 - hotfix for stupid crossystem
# v1.1.0 - implemented <var>?<value> functionality (searches for value in var)
# v1.0.0 - basic functionality implemented

# script gutted by rainestorme for murkmod

# Define ROOT variable if not set
if [ -z "$ROOT" ]; then
    ROOT="/"
    echo "ROOT variable is not defined, using default: $ROOT"
fi

. /usr/share/misc/chromeos-common.sh || :

csys() {
    if [ "$COMPAT" == "1" ]; then
        crossystem "$@"
    elif test -f "$ROOT/usr/bin/crossystem.old"; then
        "$ROOT/usr/bin/crossystem.old" "$@"
    else
        "$ROOT/usr/bin/crossystem" "$@"
    fi
}

sed_escape() {
    echo -n "$1" | while read -n1 ch; do
        if [[ "$ch" == "" ]]; then
            echo -n "\n"
        fi
        echo -n "\\x$(printf %x \'"$ch")"
    done
}

# The only reason this blob is still here is because I don't want to add network dependency for a boot-time script
raw_crossystem_sh() {
    base64 -d <<-EOF | bunzip2 -dc
    # Insert base64-encoded data here as per original script
EOF
}

drop_crossystem_sh() {
    # Replace spaces to avoid issues with the read command in sed
    vals=$(sed "s/ /THIS_IS_A_SPACE_DUMBASS/g" <<<"$(crossystem_values)")
    raw_crossystem_sh | sed -e "s/#__SED_REPLACEME_CROSSYSTEM_VALUES#/$(sed_escape "$vals")/g" | sed -e "s/THIS_IS_A_SPACE_DUMBASS/ /g" >"$ROOT/usr/bin/crossystem"
    chmod 777 "$ROOT/usr/bin/crossystem"
    echo "crossystem script updated successfully"
}

escape() {
    case $1 in
        '' | *[!0-9]*) echo -n "\"$1\"" ;;
        *) echo -n "$1" ;;
    esac
}

crossystem_values() {
    readarray -t csys_lines <<<"$(csys)"
    for element in "${csys_lines[@]}"; do
        line_stripped=$(echo "$element" | sed -e "s/#.*//g" | sed -e 's/ .*=/=/g')
        # sed 1: cuts out all chars after the #
        # sed 2: cuts out all spaces before =
        IFS='=' read -r -a pair <<<"$line_stripped"

        key=${pair[0]}
        # cut out all characters after an instance of 2 spaces in a row
        val="$(echo ${pair[1]} | sed -e 's/  .*//g')"
        
        # Handle specific key replacements
        case $key in
            "devsw_cur" | "devsw_boot" | "recoverysw_boot" | "recoverysw_cur" | "alt_os_enabled")
                val=0
                ;;
            "mainfw_type")
                val="normal"
                ;;
            "mainfw_act")
                val="A"
                ;;
            "cros_debug")
                val=1
                ;;
            "dev_boot_legacy" | "dev_boot_signed_only" | "dev_boot_usb" | "dev_enable_udc")
                val=0
                ;;
            "dev_default_boot")
                val="disk"
                ;;
        esac

        echo "$key=$(escape "$val")"
    done
}

# Back up old crossystem before replacing
if [ -f "$ROOT/usr/bin/crossystem" ]; then
    mv "$ROOT/usr/bin/crossystem" "$ROOT/usr/bin/crossystem.old"
    echo "Old crossystem backed up."
else
    echo "No original crossystem file found, skipping backup."
fi

drop_crossystem_sh
