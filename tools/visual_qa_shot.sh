#!/usr/bin/env bash
# Smash Copter's visual QA shot: the shared runner with this game's capture script (docs/testing.md).
exec bash "$(dirname "$0")/../addons/dot_game/tools/dot_game_visual_qa_shot.sh" --script tools/visual_qa.gd -- "$@"
