extends DotGameCheckSuite

## The state and the helpers every section of [code]headless_run.gd[/code] shares: its worlds, the tracked runner, walking and jumping.

const ScArena := preload("../game/sc_arena.gd")
const ScAudio := preload("../game/sc_audio.gd")
const ScCannon := preload("../game/sc_cannon.gd")
const ScBindings := preload("../game/sc_bindings.gd")
const ScConfig := preload("../game/sc_config.gd")
const ScContent := preload("../game/sc_content.gd")
const ScCopter := preload("../game/sc_copter.gd")
const ScFigure := preload("../game/sc_figure.gd")
const ScGame := preload("../game/sc_game.gd")
const ScHud := preload("../game/sc_hud.gd")
const ScKillcam := preload("../game/sc_killcam.gd")
const ScLayouts := preload("../game/sc_layouts.gd")
const ScMapSession := preload("../game/sc_map_session.gd")
const ScPlatforms := preload("../game/sc_platforms.gd")
const ScPaths := preload("../game/sc_paths.gd")
const ScClient := preload("../game/sc_client.gd")
const ScEvents := preload("../game/net/sc_events.gd")
const ScPlayer := preload("../game/sc_player.gd")
const ScProgress := preload("../game/sc_progress.gd")
const ScSpecials := preload("../game/sc_specials.gd")
const ScSpectate := preload("../game/sc_spectate.gd")
const ScSettings := preload("../game/sc_settings.gd")

const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)

var _sections_entered := 0
var _sections_finished := 0

## Every world this run has built and not yet taken down.
var _worlds: Array[ScGame] = []

## A player whose run is being measured, frame by frame, whichever helper is driving them:
## the horizontal metres they covered and the fastest they went. See [method _physics_frame].
var _tracked: ScPlayer = null
var _tracked_at := Vector3.ZERO
var _covered := 0.0
var _top_speed := 0.0


## How far below the deck the lip a runner leaves from has gone by the time they reach it.
## A lone runner from the middle to the edge at full speed, loading the deck as [ScGame] does:
## the rise the jump has to make up (about 0.3 m mid-edge, 0.7 m at a corner, against a 1.15 m apex).
func _run_up_dip(
	platforms: ScPlatforms, config: ScConfig, from: int, to: int, leave: float
) -> float:
	var deck := platforms.deck_at(from)
	var target := platforms.deck_at(to)
	deck.lean = Vector2.ZERO
	deck.lean_velocity = Vector2.ZERO
	deck.sink = 0.0
	deck.sink_velocity = 0.0

	var heading := Vector3(target.centre.x - deck.centre.x, 0.0, target.centre.z - deck.centre.z)
	heading = heading.normalized()
	var at := deck.centre
	var run := config.run_speed * TICK
	var travelled := 0.0

	while travelled < leave:
		travelled = minf(travelled + run, leave)
		at = deck.centre + heading * travelled
		platforms.begin_loads()
		platforms.add_load(from, at, config.player_mass, config.run_speed)
		platforms.step(TICK)

	var dip := config.deck_height - platforms.surface_y(from, at.x, at.z)

	deck.lean = Vector2.ZERO
	deck.lean_velocity = Vector2.ZERO
	deck.sink = 0.0
	deck.sink_velocity = 0.0

	return maxf(dip, 0.0)


func _cell_name(platforms: ScPlatforms, index: int) -> String:
	var deck := platforms.deck_at(index)
	return "(%d,%d)" % [deck.column, deck.row]


## The point [param s] metres along [param out] and [param w] across it from [param middle].
func _on_line(middle: Vector3, out: Vector2, across: Vector2, s: float, w: float) -> Vector3:
	var xz := out * s + across * w
	return Vector3(middle.x + xz.x, middle.y, middle.z + xz.y)


## Runs straight at [param target] until within [param stop] metres of it, or six seconds.
## Lets go of the key on arrival: the motor repeats its last command, so a runner nobody stops
## runs off the far side of the platform.
func _run_to(game: ScGame, player: ScPlayer, target: Vector3, stop: float) -> bool:
	for _i in range(int(6.0 * TICK_RATE)):
		var at := player.controller.state.position
		var toward := Vector3(target.x - at.x, 0.0, target.z - at.z)

		if toward.length() < stop:
			var still := DotFpsCommand.new()
			still.yaw = player.controller.state.yaw
			player.controller.apply_command(still)
			return true

		var command := DotFpsCommand.new()
		command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
		command.move = Vector2(0.0, 1.0)
		player.controller.apply_command(command)
		game.simulate(TICK)
		await _physics_frame()

	return false


## The equilibrium lean one runner's weight at a bridge's end, or at a platform's edge, puts
## on it, on The Spine's own field.
func _spine_lean(on_bridge: bool) -> float:
	var config := ScConfig.new()
	var platforms := ScPlatforms.new()
	platforms.config = config
	add_child(platforms)
	platforms.build(ScLayouts.by_id(config, &"spine"))

	var index := -1

	for i in range(platforms.count()):
		if platforms.deck_at(i).is_bridge == on_bridge:
			index = i
			break

	var deck := platforms.deck_at(index)
	var half := platforms._footprint(deck)
	var at := deck.centre + (Vector3(0.0, 0.0, half.y * 0.9) if on_bridge \
		else Vector3(half.x * 0.9, 0.0, 0.0))
	var worst := 0.0

	for _i in range(8 * TICK_RATE):
		platforms.begin_loads()
		platforms.add_load(index, at, config.player_mass, config.run_speed)
		platforms.step(TICK)
		worst = maxf(worst, deck.tilt())

	remove_child(platforms)
	platforms.free()
	return worst


func _deck_at_cell(platforms: ScPlatforms, column: int, row: int) -> int:
	for i in range(platforms.count()):
		var deck := platforms.deck_at(i)

		if not deck.is_bridge and deck.column == column and deck.row == row:
			return i

	return -1


## Walks, with the brake held, to a point on whatever the player is standing on, and stops.
func _walk_to(game: ScGame, player: ScPlayer, target: Vector3) -> void:
	for _i in range(int(6.0 * TICK_RATE)):
		var at := player.controller.state.position
		var toward := Vector3(target.x - at.x, 0.0, target.z - at.z)
		var command := DotFpsCommand.new()
		command.yaw = player.controller.state.yaw

		if toward.length() < 0.4:
			player.controller.apply_command(command)
			game.simulate(TICK)
			await _physics_frame()
			break

		command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
		command.move = Vector2(0.0, 1.0)
		command.set_button(DotFpsCommand.BUTTON_WALK, true)
		player.controller.apply_command(command)
		game.simulate(TICK)
		await _physics_frame()

	# Let them and the platform settle, the way a person would before committing.
	await _step(game, 40)


## Runs at platform [param to] and jumps at the lip of [param from]. True if they land on it.
func _jump_across(game: ScGame, player: ScPlayer, from: int, to: int) -> bool:
	var platforms := game.platforms
	var target := platforms.deck_at(to).centre
	var jumped := false

	for _i in range(int(4.0 * TICK_RATE)):
		var at := player.controller.state.position
		var toward := Vector3(target.x - at.x, 0.0, target.z - at.z)
		var command := DotFpsCommand.new()
		command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
		command.move = Vector2(0.0, 1.0)

		# Off the last of the lip rather than past it. A capsule is half a metre across and a
		# deck leaning away under a runner stops holding them up a little before its edge.
		if not jumped and platforms.index_at(at.x, at.z) == from:
			var ahead := at + toward.normalized() * 0.6

			if platforms.index_at(ahead.x, ahead.z) != from:
				command.set_button(DotFpsCommand.BUTTON_JUMP, true)
				jumped = true

		player.controller.apply_command(command)
		game.simulate(TICK)
		await _physics_frame()

		if jumped and player.standing_on == to \
				and player.controller.state.mode == DotFpsState.Mode.GROUND:
			return true

		if player.controller.state.position.y < game.config.deck_height - 3.0:
			return false

	return false


func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1


func _world(configure: Callable = Callable()) -> ScGame:
	var config := ScConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.vary_layout = false

	if configure.is_valid():
		configure.call(config)

	var game := ScGame.new()
	game.name = "World%d" % _worlds.size()
	game.config = config
	game.tick_rate = TICK_RATE
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)

	_worlds.append(game)

	# Two frames, so the arena, the platforms and every collider are in the physics space
	# before anything is asserted about them. `add_child` does not put a shape in a space;
	# the next physics step does.
	await _physics_frame()
	await _physics_frame()

	return game


func _step(game: ScGame, ticks: int) -> void:
	for _i in range(ticks):
		game.simulate(TICK)
		await _physics_frame()


func _physics_frame() -> void:
	await get_tree().physics_frame

	if _tracked != null and is_instance_valid(_tracked) and _tracked.controller != null:
		var state := _tracked.controller.state
		_covered += Vector2(state.position.x - _tracked_at.x, state.position.z - _tracked_at.z).length()
		_top_speed = maxf(_top_speed, Vector2(state.velocity.x, state.velocity.z).length())
		_tracked_at = state.position


## Starts measuring [param player]'s run from where they stand.
func _track(player: ScPlayer) -> void:
	_tracked = player
	_tracked_at = player.controller.state.position if player != null else Vector3.ZERO
	_covered = 0.0
	_top_speed = 0.0


func _dispose(game: ScGame) -> void:
	_worlds.erase(game)

	if not is_instance_valid(game):
		return

	remove_child(game)
	game.free()
	await get_tree().process_frame
