extends RefCounted

## Every key this game reads, as one dot-menu [DotMenuBindings] table: the action, the setting
## that stores it, the words a player sees, the default, and the card it goes on.
##
## [b]A table, because four things read it:[/b] the client matches events against the actions,
## the settings document stores one binding per row, the menu's Controls page draws a key per
## row, and the help screen (H) lists them with the key each is on now. Until 2026-10-11 these
## were keycodes in `ScClient._unhandled_input`, which no page could show or move.
##
## [b]Walk is Shift, the brake[/b]: dot-player-controller's own walk action, so the sampler
## reads this row (see `ScPlayer.register_actions` for why Shift and not the addon's Alt). The
## chopper flies on the movement keys, so their rows say both. The chat keys are dot-game's
## chat window's own actions. H is help, in every game of the family (dot-menu adds the row),
## so nothing here may default to it.

const BOARD := &"sc_board"
const RELOAD := &"sc_reload"
const VIEW := &"sc_view"
const SCOREBOARD := &"sc_scoreboard"
## The spectator's free camera, on and off (`mp_freeroam`). Its flying keys are the movement keys.
const ROAM := &"sc_roam"
## dot-ui's chat window's actions, which dot-game's chat client leaves at their defaults.
const CHAT := &"chat_open"
const CHAT_TEAM := &"chat_open_team"
## Slots 1 to 5, the weapon pack's, in the showdown.
const SLOTS: Array[StringName] = [&"sc_slot_1", &"sc_slot_2", &"sc_slot_3", &"sc_slot_4", &"sc_slot_5"]


static func make() -> DotMenuBindings:
	var keys := DotMenuBindings.new()
	keys.add_movement("Movement", "Ctrl", "Crouch (chopper: down)")
	keys.add(&"dot_fps_forward", &"bind_forward", "Forward (chopper: tilt forward)", "W", "Movement")
	keys.add(&"dot_fps_back", &"bind_back", "Back (chopper: tilt back)", "S", "Movement")
	keys.add(&"dot_fps_left", &"bind_left", "Strafe left (chopper: turn)", "A", "Movement")
	keys.add(&"dot_fps_right", &"bind_right", "Strafe right (chopper: turn)", "D", "Movement")
	keys.add(&"dot_fps_jump", &"bind_jump", "Jump (chopper: up)", "Space", "Movement")
	keys.add(&"dot_fps_walk", &"bind_walk", "Walk: the brake on a leaning platform", "Shift", "Movement")
	# The wheel goes through the showdown's weapons (and is not jump); in the chopper it does nothing.
	var _wheel := keys.add_wheel_weapons()
	keys.add(BOARD, &"bind_board", "Get into or out of the chopper", "E", "Hands")
	keys.add(RELOAD, &"bind_reload", "Reload (in the showdown)", "R", "Hands")
	for i in range(SLOTS.size()):
		keys.add(SLOTS[i], StringName("bind_slot_%d" % (i + 1)), "Weapon slot %d (in the showdown)" % (i + 1), str(i + 1), "Hands")
	keys.add(CHAT, &"bind_chat", "Chat", "Y", "Communication")
	keys.add(CHAT_TEAM, &"bind_chat_team", "Chat to your side", "U", "Communication")
	keys.add(VIEW, &"bind_view", "First or third person", "F5", "General")
	keys.add(ROAM, &"bind_roam", "Free camera while out (move keys fly, Walk slow)", "G", "General")
	keys.add(SCOREBOARD, &"bind_scoreboard", "Scoreboard (hold)", "Tab", "General")
	return keys
