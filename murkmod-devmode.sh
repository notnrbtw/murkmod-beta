murkmod() {
    show_logo
    if [ -f /sbin/fakemurk-daemon.sh ]; then
        echo "!!! Your system already has a fakemurk installation! Continuing anyway, but emergency revert will not work correctly. !!!"
        echo "Instead, consider upgrading your fakemurk installation to murkmod or reinstalling CrOS from scratch."
    fi
    if [ -f /sbin/murkmod-daemon.sh ]; then
        echo "!!! Your system already has a murkmod installation! Continuing anyway, but emergency revert will not work correctly. !!!"
    fi
    echo "What version of murkmod do you want to install?"
    echo "If you're not sure, choose pheonix (v118) or the latest version. If you know what your original enterprise version was, specify that manually."
    echo " 1) og      (chromeOS v105)"
    echo " 2) mercury (chromeOS v107)"
    echo " 3) john    (chromeOS v117)"
    echo " 4) pheonix (chromeOS v118)"
    echo " 5) latest version"
    echo " 6) custom milestone (enter your version)"
    read -p "(1-6) > " choice

    case $choice in
        1) VERSION="105" ;;
        2) VERSION="107" ;;
        3) VERSION="117" ;;
        4) VERSION="118" ;;
        5) VERSION="latest" ;;
        6) 
            read -p "Enter milestone to target (e.g. 105, 107, 117, 118): " VERSION 
            ;;
        *) echo "Invalid choice, exiting." && exit ;;
    esac

    show_logo
    echo "You have selected version: $VERSION"
    read -p "Do you want to use the default ChromeOS bootsplash? [y/N] " use_orig_bootsplash
    case "$use_orig_bootsplash" in
        [yY][eE][sS]|[yY]) 
            USE_ORIG_SPLASH="1"
            ;;
        *)
            USE_ORIG_SPLASH="0"
            ;;
    esac
    show_logo
    echo "Finding recovery image..."
    local release_board=$(lsbval CHROMEOS_RELEASE_BOARD)
    local board=${release_board%%-*}
    
    # Fetch and set the URL based on the selected version
    if [ "$VERSION" == "latest" ]; then
        local builds=$(curl -ks https://chromiumdash.appspot.com/cros/fetch_serving_builds?deviceCategory=Chrome%20OS)
        local hwid=$(jq "(.builds.$board[] | keys)[0]" <<<"$builds")
        local hwid=${hwid:1:-1}
        local milestones=$(jq ".builds.$board[].$hwid.pushRecoveries | keys | .[]" <<<"$builds")
        VERSION=$(echo "$milestones" | tail -n 1 | tr -d '"')
        echo "Latest version is $VERSION"
    fi

    local url="https://raw.githubusercontent.com/rainestorme/chrome100-json/main/boards/$board.json"
    local json=$(curl -ks "$url")
    chrome_versions=$(echo "$json" | jq -r '.pageProps.images[].chrome')
    echo "Found $(echo "$chrome_versions" | wc -l) versions of chromeOS for your board on chrome100."
    echo "Searching for a match..."
    
    MATCH_FOUND=0
    for cros_version in $chrome_versions; do
        platform=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .platform')
        channel=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .channel')
        mp_token=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .mp_token')
        mp_key=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .mp_key')
        last_modified=$(echo "$json" | jq -r --arg version "$cros_version" '.pageProps.images[] | select(.chrome == $version) | .last_modified')
        
        if [[ $cros_version == $VERSION* ]]; then
            echo "Found a $VERSION match on platform $platform from $last_modified."
            MATCH_FOUND=1
            FINAL_URL="https://dl.google.com/dl/edgedl/chromeos/recovery/chromeos_${platform}_${board}_recovery_${channel}_${mp_token}-v${mp_key}.bin.zip"
            break
        fi
    done

    if [ $MATCH_FOUND -eq 0 ]; then
        echo "No match found on chrome100. Falling back to Chromium Dash."
        local builds=$(curl -ks https://chromiumdash.appspot.com/cros/fetch_serving_builds?deviceCategory=Chrome%20OS)
        local hwid=$(jq "(.builds.$board[] | keys)[0]" <<<"$builds")
        local hwid=${hwid:1:-1}

        # Get all milestones for the specified hwid
        milestones=$(jq ".builds.$board[].$hwid.pushRecoveries | keys | .[]" <<<"$builds")

        # Loop through all milestones
        echo "Searching for a match..."
        for milestone in $milestones; do
            milestone=$(echo "$milestone" | tr -d '"')
            if [[ $milestone == $VERSION* ]]; then
                MATCH_FOUND=1
                FINAL_URL=$(jq -r ".builds.$board[].$hwid.pushRecoveries[\"$milestone\"]" <<<"$builds")
                echo "Found a match!"
                break
            fi
        done
    fi

    if [ $MATCH_FOUND -eq 0 ]; then
        echo "No recovery image found for your board and target version. Exiting."
        exit
    fi
