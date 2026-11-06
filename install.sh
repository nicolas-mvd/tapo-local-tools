#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
    printf '%s\n' 'Usage: tapo-install [--camera-1 IPV4] [--camera-2 IPV4] [--no-linger]'
    printf '%s\n' 'The first install prompts for any missing camera addresses. A reinstall keeps the configured addresses unless overridden.'
}

fail() { printf 'Tapo install: %s\n' "$*" >&2; exit 1; }

camera1='' camera2='' linger_requested=1
while (($#)); do
    case "$1" in
        --camera-1|--camera-2)
            [[ $# -ge 2 && -n $2 && $2 != --* ]] || fail "$1 needs a private IPv4 address."
            if [[ $1 == --camera-1 ]]; then camera1=$2; else camera2=$2; fi
            shift 2 ;;
        --no-linger) linger_requested=0; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; fail "Unknown option: $1" ;;
    esac
done

[[ -e /etc/NIXOS ]] || fail 'Run this installer on NixOS.'
(( EUID != 0 )) || fail 'Run the installer as your own NixOS user, without sudo.'
[[ -t 0 && -t 2 ]] || fail 'An interactive terminal is required. Use ssh -t if connecting over SSH.'
[[ -n ${HOME:-} ]] || fail 'HOME is not set.'
package=${TAPO_INSTALL_PACKAGE:-}
[[ -x $package/bin/tapo-login && -x $package/bin/tapo-motion-recorder ]] \
    || fail 'Use the packaged nix run installer.'
for required in nix-store systemctl loginctl python3 flock; do
    command -v "$required" >/dev/null || fail "Required command is missing: $required."
done

unit=tapo-motion-recorder.service
config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
config_dir=$config_home/tapo-motion-recorder
state_dir=${XDG_STATE_HOME:-"$HOME/.local/state"}/tapo-motion-recorder
data_dir=${XDG_DATA_HOME:-"$HOME/.local/share"}/tapo-motion-recorder
archive=$data_dir/clips
unit_dir=$config_home/systemd/user
unit_file=$unit_dir/$unit
current=$config_dir/current
package_root=$state_dir/package
marker='# Managed by tapo-install'

# These paths become systemd unit values. Reject whitespace, substitutions and
# specifiers instead of relying on shell quoting rules in the unit parser.
for dir in "$config_home" "$state_dir" "$data_dir" "$package"; do
    [[ $dir =~ ^/[A-Za-z0-9_./-]+$ ]] \
        || fail 'HOME, XDG directories and the Nix package need ordinary absolute paths.'
done

private_dir() {
    [[ ! -L $1 ]] || fail "Refusing to use a symlink as the private directory: $1"
    install -d -m 0700 -- "$1"
    [[ -d $1 && -O $1 ]] || fail "Private directory is not owned by this user: $1"
}
private_dir "$config_dir"
private_dir "$state_dir"
private_dir "$data_dir"
[[ ! -L $state_dir/install.lock ]] || fail 'Install lock must not be a symlink.'
exec 9>"$state_dir/install.lock"
flock -n 9 || fail 'Another Tapo install is running.'

system_unit=$(systemctl show --property=LoadState --value "$unit" 2>/dev/null || true)
[[ $system_unit != loaded ]] \
    || fail 'A system-wide Tapo unit is already configured. Disable that deployment before using this installer.'

user_bus() {
    if systemctl --user show-environment >/dev/null 2>&1; then return 0; fi
    local runtime
    runtime=$(loginctl show-user "$UID" --property=RuntimePath --value 2>/dev/null || true)
    runtime=${runtime:-/run/user/$UID}
    [[ -S $runtime/bus && -O $runtime/bus ]] || return 1
    export XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus"
    systemctl --user show-environment >/dev/null 2>&1
}

linger_on() {
    [[ $(loginctl show-user "$UID" --property=Linger --value 2>/dev/null || true) == yes ]]
}

try_linger() {
    linger_on && return 0
    (( linger_requested )) && command -v sudo >/dev/null || return 1
    printf '%s\n' 'Enabling your user service manager at boot and after logout (sudo may prompt).'
    sudo loginctl enable-linger "$UID"
}

if ! user_bus; then
    try_linger || fail 'Cannot reach your systemd user manager. Use a normal NixOS login session.'
    for _ in 1 2 3 4 5; do
        user_bus && break
        sleep 1
    done
    user_bus || fail 'Cannot reach your systemd user manager after enabling linger.'
fi

install -d -- "$unit_dir"
fragment=$(systemctl --user show --property=FragmentPath --value "$unit" 2>/dev/null || true)
[[ -z $fragment || $fragment == "$unit_file" ]] \
    || fail 'A user unit with the same name is managed elsewhere.'
if [[ -e $unit_file || -L $unit_file ]]; then
    [[ -f $unit_file && ! -L $unit_file && -O $unit_file ]] || fail 'Existing user unit is not managed by this installer.'
    IFS= read -r first_line < "$unit_file" || fail 'Existing user unit is not managed by this installer.'
    [[ $first_line == "$marker" ]] || fail 'Existing user unit is not managed by this installer.'
fi

previous_profile='' previous_package=''
if [[ -e $current || -L $current ]]; then
    [[ -L $current ]] || fail 'Existing current profile is not managed by this installer.'
    previous_profile=$(readlink -- "$current")
    [[ $(dirname -- "$previous_profile") == "$config_dir" && ${previous_profile##*/} == .profile.* \
        && -d $previous_profile && ! -L $previous_profile && -O $previous_profile ]] \
        || fail 'Existing current profile is not managed by this installer.'
fi
if [[ -e $package_root || -L $package_root ]]; then
    [[ -L $package_root ]] || fail 'Existing Nix GC root is not managed by this installer.'
    previous_package=$(readlink -- "$package_root")
fi

if [[ -z $previous_profile ]]; then
    if [[ -z $camera1 ]]; then
        IFS= read -r -p 'Cam 1 private IPv4 address: ' camera1 || fail 'Camera setup canceled.'
    fi
    if [[ -z $camera2 ]]; then
        IFS= read -r -p 'Cam 2 private IPv4 address: ' camera2 || fail 'Camera setup canceled.'
    fi
fi

profile=$(mktemp -d -- "$config_dir/.profile.XXXXXXXXXX")
staged_unit='' activating=0 complete=0 was_active=0 was_enabled=0

remove_profile() {
    local file
    for file in config.json camera-tokens.json previous-unit new-link old-link; do
        if [[ -e $1/$file || -L $1/$file ]]; then rm -- "$1/$file"; fi
    done
    rmdir -- "$1" 2>/dev/null || true
}

cleanup() {
    local status=$?
    trap - EXIT
    set +e
    if (( activating && ! complete )); then
        printf '%s\n' 'Activation failed. Restoring the previous user service.' >&2
        systemctl --user stop "$unit"
        if (( ! was_enabled )); then systemctl --user disable "$unit"; fi
        if [[ -f $profile/previous-unit ]]; then
            cp -- "$profile/previous-unit" "$unit_file"
        elif [[ -e $unit_file ]]; then
            rm -- "$unit_file"
        fi
        if [[ -n $previous_profile ]]; then
            ln -s -- "$previous_profile" "$profile/old-link"
            mv -Tf -- "$profile/old-link" "$current"
        elif [[ -L $current ]]; then
            rm -- "$current"
        fi
        if [[ -n $previous_package ]]; then
            nix-store --add-root "$package_root" --indirect --realise "$previous_package" >/dev/null
        elif [[ -L $package_root ]]; then
            rm -- "$package_root"
        fi
        systemctl --user daemon-reload
        if (( was_active )); then systemctl --user start "$unit"; fi
    fi
    if [[ -n $staged_unit && -e $staged_unit ]]; then rm -- "$staged_unit"; fi
    if (( ! complete )); then remove_profile "$profile"; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

python3 - "$previous_profile" "$profile/config.json" "$archive" "$camera1" "$camera2" <<'PY'
from ipaddress import IPv4Address, IPv4Network
import json
from pathlib import Path
import sys

previous, destination, archive, camera1, camera2 = sys.argv[1:]
hosts = {}
try:
    if previous:
        old = json.loads((Path(previous) / "config.json").read_text())
        hosts = {camera["id"]: camera["host"] for camera in old["cameras"]}
        if set(hosts) != {"1", "2"}:
            raise ValueError("Existing profile must contain camera IDs 1 and 2.")
    for camera_id, override in (("1", camera1), ("2", camera2)):
        host = override or hosts.get(camera_id)
        if not isinstance(host, str):
            raise ValueError(f"Camera {camera_id} needs a private IPv4 address.")
        address = IPv4Address(host)
        if not any(address in IPv4Network(network) for network in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")):
            raise ValueError(f"Camera {camera_id} needs a private IPv4 address.")
        hosts[camera_id] = str(address)
    if hosts["1"] == hosts["2"]:
        raise ValueError("Camera addresses must be different.")
except (OSError, KeyError, TypeError, ValueError) as error:
    sys.exit(f"Tapo camera configuration: {error}")
config = {"cameras": [{"id": key, "host": hosts[key]} for key in ("1", "2")], "recordingsDir": archive}
Path(destination).write_text(json.dumps(config, indent=2) + "\n")
PY

"$package/bin/tapo-login" --config "$profile/config.json" \
    --token-file "$profile/camera-tokens.json" --require-discovery
env -u CREDENTIALS_DIRECTORY TAPO_CONFIG="$profile/config.json" TAPO_TOKEN_FILE="$profile/camera-tokens.json" \
    "$package/bin/tapo-motion-recorder" --check

if systemctl --user is-active --quiet "$unit"; then was_active=1; fi
if systemctl --user is-enabled --quiet "$unit"; then was_enabled=1; fi
if [[ -f $unit_file ]]; then cp -- "$unit_file" "$profile/previous-unit"; fi
staged_unit=$(mktemp -- "$unit_dir/.tapo-motion-recorder.XXXXXXXXXX")
cat > "$staged_unit" <<UNIT
$marker
[Unit]
Description=Tapo camera motion recorder
ConditionPathExists=$current/camera-tokens.json

[Service]
ExecStart=$package/bin/tapo-motion-recorder
Environment=TAPO_CONFIG=$current/config.json
LoadCredential=camera-tokens.json:$current/camera-tokens.json
UMask=0077
NoNewPrivileges=yes
Restart=on-failure
RestartSec=15s
KillMode=mixed
TimeoutStopSec=45s

[Install]
WantedBy=default.target
UNIT

activating=1
nix-store --add-root "$package_root" --indirect --realise "$package" >/dev/null
ln -s -- "$profile" "$profile/new-link"
mv -Tf -- "$profile/new-link" "$current"
mv -Tf -- "$staged_unit" "$unit_file"
systemctl --user daemon-reload
systemctl --user enable "$unit"
systemctl --user restart "$unit"
systemctl --user is-active --quiet "$unit" || fail 'The recorder did not stay active.'
complete=1

if [[ -e $profile/previous-unit ]]; then rm -- "$profile/previous-unit"; fi
if [[ -n $previous_profile ]]; then remove_profile "$previous_profile"; fi
if ! try_linger; then
    printf '%s\n' 'User lingering is off. Recording can stop when you log out and will start on login.'
fi
printf 'Recording service: %s\nClips: %s\nLogs: journalctl --user -u %s -f\n' "$unit" "$archive" "$unit"
