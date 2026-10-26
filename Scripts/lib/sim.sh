# Scripts/lib/sim.sh — simulator lookups shared by the gate scripts (sourced;
# bash 3.2 compatible; needs xcrun and python3). UDIDs compare
# case-insensitively everywhere.

# sim_device_record <udid> -> "<state>\t<name>\t<runtime>", or nothing.
sim_device_record() {
    xcrun simctl list devices -j | python3 -I -c '
import json, sys
want = sys.argv[1].upper()
for runtime, devices in json.load(sys.stdin).get("devices", {}).items():
    for d in devices:
        if d.get("udid", "").upper() == want:
            print(d.get("state", "?"), d.get("name", "?"), runtime, sep="\t")
            sys.exit(0)
' "$1"
}

# sim_device_field <udid> <state|name|runtime> -> the field; "Missing" (state)
# or "?" when there is no such device.
sim_device_field() {
    local record
    record="$(sim_device_record "$1")"
    if [[ -z "$record" ]]; then
        if [[ "$2" == "state" ]]; then echo "Missing"; else echo "?"; fi
        return 0
    fi
    case "$2" in
        state) printf '%s\n' "$record" | cut -f1 ;;
        name) printf '%s\n' "$record" | cut -f2 ;;
        runtime) printf '%s\n' "$record" | cut -f3 ;;
    esac
}

# sim_other_booted <udid> -> every booted device other than <udid>, one per line.
sim_other_booted() {
    xcrun simctl list devices -j | python3 -I -c '
import json, sys
me = sys.argv[1].upper()
for devices in json.load(sys.stdin).get("devices", {}).values():
    for d in devices:
        if d.get("state") == "Booted" and d.get("udid", "").upper() != me:
            print(d["udid"])
' "$1"
}
