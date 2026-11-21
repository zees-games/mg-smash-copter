#!/usr/bin/env bash
# Smash Copter's visual QA shot: the shared runner with this game's capture script (docs/testing.md).
exec bash "$(dirname "$0")/../addons/gs_game/tools/gs_game_visual_qa_shot.sh" --script tools/visual_qa.gd -- "$@"
