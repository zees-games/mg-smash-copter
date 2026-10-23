#!/usr/bin/env bash
# Render the game and look at it. The check no assertion in this repository makes.
#
#   tools/shot.sh                     # from a player's eyes, 4 seconds in
#   tools/shot.sh --view=cover        # the loading cover, before it lifts
#   tools/shot.sh --view=field        # the whole field, from above and to one side
#   tools/shot.sh --view=lean         # a platform that has been leant on
#   tools/shot.sh --view=copter       # the chopper, close
#   tools/shot.sh --view=showdown     # the corners the round is finished in
#   tools/shot.sh --view=armed --sc-survival-seconds=10 --seconds=12   # a stand-in's gun, close
#   tools/shot.sh --view=hands --sc-survival-seconds=4 --seconds=1     # your own gun and its counter, in the showdown
#   tools/shot.sh --view=ring         # the ring from a pad, at eye height: its cover
#   tools/shot.sh --view=flank        # a perch on the flank, its catwalks, the ring side-on
#   tools/shot.sh --view=dais         # the ring's dais, low, from where a catwalk meets it
#   tools/shot.sh --view=jump         # the first jump the layout means, from behind it
#   tools/shot.sh --view=bridge       # a bridge leant on at one end, from beside it
#   tools/shot.sh --view=beacon       # an admin's beacon on a stand-in, from across the field
#   tools/shot.sh --view=killcam --seconds=2   # the round's last moment replayed (--seconds=8: the podium)
#   tools/shot.sh --view=blind        # the local player's own eyes, blinded, through the HUD
#   tools/shot.sh --view=spectate     # the local player, out, watching what the server allows
#   tools/shot.sh --view=spectate --sc-spectate-camera=0   # ...when it allows anybody
#   tools/shot.sh --workshop --view=field   # a fixture pack map, chosen as the M menu would
#   tools/shot.sh --ballot            # the layout vote's ballot over the frame, mid-vote
#   tools/shot.sh --view=walk         # a CONNECTED client running its own player, measured
#   tools/shot.sh --view=field --seconds=20 --out=res://screenshots/late.png
#   tools/shot.sh --view=field --sc-layout-ids=checker   # any --sc-* is the game's own config
#
# xvfb-run because this needs a rendering context and the machines this runs on have no
# display. `--headless` is NOT a substitute: it gives a null renderer and saves a frame of
# nothing, which is worse than no screenshot because it looks like one.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots

view="eyes"
seconds="4"
out=""
config=()

for arg in "$@"; do
    case "$arg" in
        --view=*)    view="${arg#*=}" ;;
        --seconds=*) seconds="${arg#*=}" ;;
        --out=*)     out="${arg#*=}" ;;
        --sc-*)      config+=("$arg") ;;
        --ballot|--workshop) config+=("$arg") ;;
        *)           echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

[ -n "$out" ] || out="res://screenshots/${view}.png"

# `walk` is a different program: a server and a connected client in one process
# (tools/net_shot.gd), because prediction only exists where there is a wire.
scene="res://tools/shot.tscn"
[ "$view" = "walk" ] && scene="res://tools/net_shot.tscn"

exec xvfb-run -a "${GODOT:-godot}" --path . --resolution 1280x720 \
    "$scene" -- "--seconds=$seconds" "--view=$view" "--out=$out" "${config[@]}"
