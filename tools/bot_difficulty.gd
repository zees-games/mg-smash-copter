extends Node

const ScConfig := preload("../game/sc_config.gd")
const ScGame := preload("../game/sc_game.gd")
const ScPlayer := preload("../game/sc_player.gd")

## How the stand-ins play at each `bot_difficulty`: whole rounds, headless, two of them at the
## preset against two reference stand-ins whose aim is pinned here and never follows a preset.
##
## [codeblock]
## tools/bot_difficulty.sh                        # every preset, 20 showdowns each
## tools/bot_difficulty.sh --rounds 10 --presets easy,hard
## tools/bot_difficulty.sh --full                 # whole rounds: the cannon and the floor too
## tools/bot_difficulty.sh --weapons ""           # the server's own random draw, not one rifle
## [/codeblock]
##
## [b]One rifle each by default.[/b] The server deals every survivor two weapons at random from
## eighteen, a hatchet against a sniper rifle included, and over twenty rounds that decides more
## fights than the preset does. `--weapons` names the pool (comma separated); empty is the
## server's own.
##
## [b]The showdown by default.[/b] The difficulty is how a stand-in turns, aims and fires, and
## only the second half has guns: a whole round is decided as often by the cannon putting a
## platform over in the first, which the preset does not touch. So by default the cannon is
## off and the platforms last five seconds, and every round is a fight; `--full` plays the
## real thing.
##
## [b]A measurement, not a suite.[/b] Nothing here passes or fails: the numbers are read, not
## banded. What it prints per preset: rounds won by each side, shot kills each way (the K/D
## that moves with the preset), how many on each side fell, and the stand-ins' measured
## first-shot reaction against the preset's `bot_reaction`.
##
## The reference is an ordinary player, the same numbers game-arena's `headless_bots` pins
## (reacts in 0.35 s, opens 4 degrees off and settles to 1.5, turns at 450 deg/s), on medium's
## view cone and range. Side 1 is the preset, side 2 the reference; the layouts vary by round.

const TICK_RATE := 64

## The reference stand-in: an ordinary player, pinned, whatever `bot_difficulty` says.
const REFERENCE_PROFILE := {
	"reaction": 0.35, "notice": 0.2, "aim_error": 4.0, "aim_settle": 0.7, "aim_floor": 1.5,
	"turn_rate": 450.0, "turn_smooth": 0.5, "prediction": 0.5, "fire_cone": 5.0,
	"burst": 0.5, "burst_pause": 0.3, "burst_range": 15.0,
}

const PRESET_SIDE := 1
const REFERENCE_SIDE := 2
const PER_SIDE := 2

var _rounds := 20
var _full := false
var _weapons: PackedStringArray = PackedStringArray(["rifle"])
var _presets: PackedStringArray = PackedStringArray(DotBotProfile.PRESETS)

var _game: ScGame = null
var _reference: DotBotSettings = null
var _tally: Dictionary = {}
var _rounds_done := 0
var _reactions: Array[float] = []
var _seen_shot: Dictionary = {}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_full = args.has("--full")
	for i in range(args.size() - 1):
		if args[i] == "--rounds":
			_rounds = maxi(int(args[i + 1]), 1)
		elif args[i] == "--presets":
			_presets = args[i + 1].split(",", false)
		elif args[i] == "--weapons":
			_weapons = args[i + 1].split(",", false)

	_reference = DotBotSettings.new()
	var _medium := _reference.set_difficulty("medium")
	for field: String in REFERENCE_PROFILE:
		var _set := _reference.set_value(field, str(REFERENCE_PROFILE[field]))

	print("smash-copter bot difficulty: %d %s per preset, %d a side, %s, preset (side 1) against a pinned reference (side 2)" % [
		_rounds, "whole rounds" if _full else "showdowns", PER_SIDE,
		"the server's weapon draw" if _weapons.is_empty() else "weapons " + ",".join(_weapons)])
	print("")
	await _run()
	get_tree().quit(0)


func _run() -> void:
	var lines := PackedStringArray()

	for preset in _presets:
		var result: Dictionary = await _play(preset)
		var kd := float(result.kills) / maxf(float(result.deaths_shot), 1.0)
		var reaction := _median(result.reactions)
		var line := "%-9s rounds won %d-%d (%d drawn)  shot kills %d-%d (K/D %.2f)  fell %d-%d  first shot %.2f s after sight (bot_reaction %.2f, %d engagements)" % [
			preset, result.won, result.lost, result.drawn, result.kills, result.deaths_shot,
			kd, result.fell, result.ref_fell, reaction, DotBotProfile.preset_value(preset, "reaction"), (result.reactions as Array).size(),
		]
		print(line)
		lines.append(line)

	print("")
	print("summary")
	for line in lines:
		print("  " + line)


func _play(preset: String) -> Dictionary:
	var config := ScConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.team_count = 2
	config.survival_seconds = 45.0 if _full else 5.0
	config.cannon_enabled = _full
	if not _weapons.is_empty():
		config.weapon_pool = _weapons
		config.weapons_granted = 1
	config.seed_value = 20261012 + hash(preset) % 1000

	_game = ScGame.new()
	_game.name = "World"
	_game.config = config
	_game.tick_rate = TICK_RATE
	_game.authoritative = true
	_game.register_service = false
	add_child(_game)
	_game.set_physics_process(false)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var _set := DotBotSettings.of(_game).set_difficulty(preset)
	_tally = {"won": 0, "lost": 0, "drawn": 0, "kills": 0, "deaths_shot": 0, "fell": 0, "ref_fell": 0, "reactions": []}
	_rounds_done = 0
	_seen_shot.clear()

	for i in range(PER_SIDE):
		var mine := _game.add_player(StringName("p%d" % i), "%s %d" % [preset, i], PRESET_SIDE)
		mine.is_bot = true
		var theirs := _game.add_player(StringName("r%d" % i), "reference %d" % i, REFERENCE_SIDE)
		theirs.is_bot = true
		var _pinned := DotBotSettings.attach(theirs, _reference)

	_game.round_over.connect(_on_round_over)
	_game.player_died.connect(_on_died)
	_game.start()

	var limit := int((config.survival_seconds + config.showdown_seconds + 30.0) * TICK_RATE) * _rounds

	for _t in range(limit):
		_game.simulate(1.0 / TICK_RATE)
		_note_first_shots()
		await get_tree().physics_frame

		if _rounds_done >= _rounds:
			break

	var out := _tally.duplicate(true)
	remove_child(_game)
	_game.queue_free()
	_game = null
	await get_tree().process_frame
	return out


func _on_round_over(_number: int, winner: int) -> void:
	_rounds_done += 1
	if winner == PRESET_SIDE:
		_tally.won += 1
	elif winner == REFERENCE_SIDE:
		_tally.lost += 1
	else:
		_tally.drawn += 1


func _on_died(player_id: StringName, by: StringName, why: StringName) -> void:
	var mine := String(player_id).begins_with("p")
	# A kill after the round is decided (the last shots in flight) decides nothing.
	if _game.phase == ScGame.Phase.IDLE:
		return
	if why == ScGame.DIED_SHOT and by != &"":
		if String(by).begins_with("p") and not mine:
			_tally.kills += 1
		elif String(by).begins_with("r") and mine:
			_tally.deaths_shot += 1
	elif why == ScGame.DIED_FELL:
		if mine:
			_tally.fell += 1
		else:
			_tally.ref_fell += 1


## Each preset stand-in's first shot of an engagement that began with the target already
## inside `bot_max_range`, measured from that first sight: what `bot_reaction` promises, in the
## real game. One begun across the map is left out, since its reaction ran out on the walk.
func _note_first_shots() -> void:
	var now: float = _game._bot_now()
	var max_range := DotBotSettings.of(_game).profile.max_range
	for id: StringName in _game.players:
		if not String(id).begins_with("p"):
			continue
		var aim: DotBotAim = _game._bot_aims.get(id)
		if aim == null or aim.target_id < 0:
			continue
		var key := "%s@%.4f" % [id, aim.engaged_at]
		if not _seen_shot.has(key):
			# Decided on the tick the engagement began, and only then.
			if now - aim.engaged_at > 1.5 / TICK_RATE:
				_seen_shot[key] = false
				continue
			var me: ScPlayer = _game.players[id]
			var them: ScPlayer = null
			for other_id: StringName in _game.players:
				if (_game.players[other_id] as ScPlayer).entity_id == aim.target_id:
					them = _game.players[other_id]
			_seen_shot[key] = them != null and me.eye_position().distance_to(them.eye_position()) <= max_range
		if _seen_shot[key] != true or is_nan(aim.first_shot_at):
			continue
		(_tally.reactions as Array).append(aim.first_shot_at - aim.engaged_at)
		_seen_shot[key] = false


static func _median(values: Array) -> float:
	if values.is_empty():
		return NAN
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[sorted.size() / 2])
