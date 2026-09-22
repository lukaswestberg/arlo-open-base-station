#!/usr/bin/env bash
# Pull the latest code from your fork and deploy it to this host.
#
#   scripts/update.sh            # pull, then deploy if anything changed
#   scripts/update.sh --force    # deploy even if already up to date
#
# Only arlo and arlo-viewer restart; hostapd and DHCP are left alone, so
# cameras stay connected. config.yaml, arlo.db and .env are kept.
# Changes to WiFi/DHCP setup need a full `sudo scripts/install.sh`.

# Everything runs inside main() so bash has parsed the whole file before
# `git pull` can rewrite it underneath us.
main() {
    set -euo pipefail
    local repo owner before after
    repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    # git runs as the repo's owner, even if invoked with sudo.
    owner="$(stat -c %U "$repo")"
    as_owner() {
        if [ "$(id -un)" = "$owner" ]; then "$@"; else sudo -u "$owner" -H "$@"; fi
    }

    before="$(as_owner git -C "$repo" rev-parse HEAD)"
    as_owner git -C "$repo" pull --ff-only
    after="$(as_owner git -C "$repo" rev-parse HEAD)"

    if [ "$before" = "$after" ]; then
        echo "Already up to date ($(as_owner git -C "$repo" describe --always))."
        [ "${1:-}" = "--force" ] || exit 0
    else
        echo "New commits:"
        as_owner git -C "$repo" log --oneline "$before..$after" | sed 's/^/  /'
        if ! as_owner git -C "$repo" diff --quiet "$before" "$after" -- scripts/install.sh; then
            echo ""
            echo "Note: the installer changed. If these commits touch WiFi, DHCP or"
            echo "packages, follow up with a full run: sudo $repo/scripts/install.sh"
        fi
    fi

    echo ""
    exec sudo "$repo/scripts/install.sh" --update
}

main "$@"
exit
