#!/usr/bin/env bash
# How the stand-ins play at each bot_difficulty: showdowns (or whole rounds), headless, two at the preset
# against two pinned reference stand-ins. A measurement to read, not a suite.
# --full plays whole rounds (cannon and floor too); --weapons "" uses the server's weapon draw.
#
#   tools/bot_difficulty.sh                              # every preset, 20 showdowns each, one rifle apiece
#   tools/bot_difficulty.sh --rounds 10 --presets easy,hard
#
# --fixed-fps runs the frames as fast as the machine can rather than in real time.
set -euo pipefail
cd "$(dirname "$0")/.."
exec timeout "${TIMEOUT:-3600}" "${GODOT:-godot}" --headless --fixed-fps 60 --path . res://tools/bot_difficulty.tscn -- "$@"
