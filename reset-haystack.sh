#!/bin/sh
# Reset the local Linux or macOS client and server by backing up their config and data.
set -eu

case "${HOME:-}" in
    /*) ;;
    *) printf '%s\n' 'HOME must be an absolute path.' >&2; exit 1 ;;
esac

if pgrep -x 'haystack_game|haystack_server'; then
    printf '%s\n' 'Stop Haystack and its server before running this script.' >&2
    exit 1
else
    status=$?
    [ "$status" -eq 1 ] || exit "$status"
fi

case "$(uname -s)" in
    Linux)
        case "${XDG_CONFIG_HOME:-}" in
            /*) config=$XDG_CONFIG_HOME ;;
            *) config=$HOME/.config ;;
        esac
        case "${XDG_DATA_HOME:-}" in
            /*) data=$XDG_DATA_HOME ;;
            *) data=$HOME/.local/share ;;
        esac
        set -- config data
        ;;
    Darwin)
        set -- application-support
        ;;
    *) printf '%s\n' 'This script supports only Linux and macOS.' >&2; exit 1 ;;
esac

backup=
for kind do
    case "$kind" in
        config) base=$config ;;
        data) base=$data ;;
        application-support) base=$HOME/Library/"Application Support" ;;
    esac
    for app in haystack haystack-server; do
        source=$base/$app
        [ -d "$source" ] || continue
        if [ -z "$backup" ]; then
            backup=$(mktemp -d "$HOME/haystack-backup.XXXXXX")
            printf 'Backup: %s\n' "$backup"
        fi
        mkdir -p "$backup/$kind"
        mv -- "$source" "$backup/$kind/"
        printf 'Moved %s\n' "$source"
    done
done

if [ -z "$backup" ]; then
    printf '%s\n' 'No local Haystack config or data found.'
fi
