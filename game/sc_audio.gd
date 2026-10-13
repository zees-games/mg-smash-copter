extends Node

const ScPaths := preload("sc_paths.gd")
const ScPlatforms := preload("sc_platforms.gd")

## What this game makes a noise about, and the noise, on the client.
##
## [b]Until this existed the game made no sound at all, and in THIS game that is not a
## polish item.[/b] The cannon is behind you as often as in front of you, and the only
## warning a player standing on a platform gets of a monolith on its way is looking up at
## the right moment. The one warning that works without looking is a bang from the middle of
## the map — and the second is the platform under your feet creaking before it goes, which
## is information the tilt bar gives only to somebody reading it.
##
## [b]A catalogue of ids and a table of stand-ins, which is the family's shape.[/b] dot-audio
## decides what is audible, how many at once, how far away it stops mattering and what loses
## to what; [method sound_catalogue] is those decisions, as a document naming paths nobody
## has produced yet. [method sound_recipes] says which synthesised voice stands in for each
## id until they are — and [DotAudioSinkGodot] consults the file before the stand-in, so
## dropping a real `.ogg` into `audio/` switches that one id over with no code change.
##
## [b]Never on a server, and never deciding anything.[/b] Every hook here is called by
## [ScClient] from something the world or the wire already said, and none of them changes
## the simulation — so a client still downloading content, a machine with no sound card and
## a headless suite all run the same code and differ only in whether a speaker moves.
## dot-audio picks its own null sink when there is no device.
##
## [b]The beacon's ping is not here, deliberately.[/b] [DotFxBeacon] synthesises its own tone
## on its own [AudioStreamPlayer3D], and `headless_run` pins its rate to once a second; it
## predates this layer and moving it is a change to a tested behaviour with nothing to gain
## but tidiness. The day real audio ships, `beacon` is the id it moves to.

const CHANNEL := "sc.audio"

## Where the real files go when somebody produces them. Rebased, because a delivered pack
## mounts this game somewhere other than `res://`, and a path that did not follow it would
## be a path the stand-in always answers for.
static var SOUND_DIR := ScPaths.rebase("res://audio")

# --- The ids -----------------------------------------------------------------

## The cannon firing. From the middle of the map, heard everywhere.
const CANNON_FIRE := &"cannon_fire"
## Something landing on a platform and leaning it.
const IMPACT_LIGHT := &"impact_light"
## Something landing hard enough to take a platform down.
const IMPACT_HEAVY := &"impact_heavy"
## A platform nearing the angle it comes off its pillar at. See [method present].
const PLATFORM_CREAK := &"platform_creak"
## A platform coming off its pillar.
const PLATFORM_COLLAPSE := &"platform_collapse"
## A barrel going off.
const BARREL_BLAST := &"barrel_blast"
## Somebody else running out of map.
const PLAYER_FELL := &"player_fell"
## Somebody else crushed, shot or blown up.
const PLAYER_DOWN := &"player_down"
## You. Flat, because being out is not somewhere in the world.
const YOU_ARE_OUT := &"you_are_out"
const ROUND_START := &"round_start"
const ROUND_END := &"round_end"
## Everybody still up is thrown into the corners.
const SHOWDOWN_TELEPORT := &"showdown_teleport"
## The weapons go hot.
const SHOWDOWN_GO := &"showdown_go"
## Something strange started.
const SPECIAL := &"special"
## A weapon used, by what KIND of use rather than by weapon. See [method weapon_sound].
const WEAPON_SHOT := &"weapon_shot"
const WEAPON_SWING := &"weapon_swing"
const WEAPON_LAUNCH := &"weapon_launch"
const WEAPON_BEAM := &"weapon_beam"
const WEAPON_THROW := &"weapon_throw"
## A key that did something the interface is answering, and one that was refused.
const UI_CLICK := &"ui_click"
const UI_DENY := &"ui_deny"

## Metres from the muzzle within which a prop that appears was just fired.
##
## [b]Why a distance and not an event.[/b] A client learns about a prop when it arrives, and
## it arrives the same way whether the cannon just fired it or it was already in the air when
## this client joined — which would be a volley of bangs on every join. A prop that turns up
## at the mouth of the tube was fired this tick; one that turns up anywhere else was not.
const MUZZLE_REACH := 6.0

## The fraction of the collapse lean at which a platform creaks, and at which it may again.
##
## [b]Two numbers, because one is a platform that creaks forty times a second.[/b] A lean
## sitting on the threshold crosses it on every snapshot as it wobbles; hysteresis is what
## makes a creak mean "this one is going" rather than "this one exists".
const CREAK_AT := 0.7
const CREAK_CLEARS_AT := 0.5

var manager: DotAudioManager = null

## Everybody's footsteps by what they stand on, and the bed under the whole game: dot-audio's
## stock (Kenney's footsteps, generated beds, all CC0; the addon's stock/CREDITS.md).
## Forty metres up on a slab in the open: wind is the whole world's sound.
var steps: DotAudioFootsteps = null
var ambience: DotAudioAmbience = null

## Where the cannon's mouth is. [ScClient] sets it from `ScArena.muzzle()`, which is the one
## place that number is written.
var muzzle := Vector3.INF

## deck index -> true while that platform has creaked and not yet settled back.
var _creaking: Dictionary = {}


# --- The document -------------------------------------------------------------

## Every id, in the order a reader would look for them.
static func ids() -> Array[StringName]:
	var out: Array[StringName] = [
		CANNON_FIRE, IMPACT_LIGHT, IMPACT_HEAVY, PLATFORM_CREAK, PLATFORM_COLLAPSE,
		BARREL_BLAST, PLAYER_FELL, PLAYER_DOWN, YOU_ARE_OUT,
		ROUND_START, ROUND_END, SHOWDOWN_TELEPORT, SHOWDOWN_GO, SPECIAL,
		WEAPON_SHOT, WEAPON_SWING, WEAPON_LAUNCH, WEAPON_BEAM, WEAPON_THROW,
		UI_CLICK, UI_DENY,
		# dot-player-char's dead bodies.
		DotPlayerDeathReactions.SOUND_THUD, DotPlayerDeathReactions.SOUND_FACE_PLANT,
		DotPlayerDeathReactions.SOUND_SLUMP, DotPlayerDeathReactions.SOUND_WHOOSH,
	]
	# dot-props' toys.
	for row: Dictionary in DotPropToySounds.rows():
		out.append(StringName(row["id"]))
	# A typed array plus a typed array is an untyped one: appended, not added.
	out.append_array(DotAudioStock.ids())
	return out


## What this game makes a noise about, and the rules for each.
##
## [b]Positional for everything that happens somewhere, and the distances are the map's.[/b]
## The field is about sixty metres across and the corners are a hundred and twenty metres
## from it, so a cull distance that suits a corridor shooter would silence the cannon for
## anybody in the showdown and every collapse on the far side of the field. The things that
## are warnings — the cannon, a collapse — carry across the whole map on purpose.
static func sound_catalogue() -> DotAudioCatalogue:
	var c := DotAudioCatalogue.new()

	# The one sound that is a warning about the future. Everybody on the field hears it,
	# and hears it from the middle, which is where to look.
	c.add(_placed(CANNON_FIRE, 260.0, 30.0, 2, 90, 0.92, 1.05))
	c.add(_placed(IMPACT_LIGHT, 90.0, 12.0, 4, 40, 0.85, 1.15))
	c.add(_placed(IMPACT_HEAVY, 180.0, 20.0, 2, 75, 0.8, 1.0))

	# The warning the tilt bar gives only to somebody reading it. Cooldown per id rather than
	# per platform, which is dot-audio's granularity: two platforms going at once is one
	# creak, and the collapse after it is what says which.
	var creak := _placed(PLATFORM_CREAK, 70.0, 10.0, 2, 70, 0.55, 0.75)
	creak.cooldown_ms = 250
	c.add(creak)

	c.add(_placed(PLATFORM_COLLAPSE, 260.0, 30.0, 3, 85, 0.7, 0.9))
	c.add(_placed(BARREL_BLAST, 200.0, 24.0, 3, 88, 0.9, 1.1))
	c.add(_placed(PLAYER_FELL, 120.0, 14.0, 3, 60, 0.9, 1.1))
	c.add(_placed(PLAYER_DOWN, 120.0, 14.0, 3, 65, 0.95, 1.05))

	# Footsteps and ambience beds, the family's stock.
	DotAudioStock.add_to(c)

	c.add(_flat(YOU_ARE_OUT, &"SFX", 1, 100))
	c.add(_flat(ROUND_START, &"UI", 1, 80))
	c.add(_flat(ROUND_END, &"UI", 1, 80))
	c.add(_flat(SHOWDOWN_TELEPORT, &"UI", 1, 85))
	c.add(_flat(SHOWDOWN_GO, &"UI", 1, 85))
	c.add(_flat(SPECIAL, &"UI", 1, 70))

	# Weapons, by kind of use. Twenty-seven weapons in the pack is twenty-seven files nobody
	# has made; five kinds of use is the distinction a player acts on — something is being
	# fired at me, somebody is swinging, something is on its way.
	var shot := _placed(WEAPON_SHOT, 110.0, 14.0, 3, 80, 0.94, 1.06)
	shot.tags = [&"weapon"]
	c.add(shot)
	var swing := _placed(WEAPON_SWING, 30.0, 6.0, 2, 55, 0.9, 1.1)
	swing.tags = [&"weapon"]
	c.add(swing)
	var launch := _placed(WEAPON_LAUNCH, 140.0, 16.0, 2, 82, 0.95, 1.05)
	launch.tags = [&"weapon"]
	c.add(launch)
	# A beam is a use per tick for as long as it is held, so the cooldown is what makes it a
	# hum rather than sixty-four starts a second.
	var beam := _placed(WEAPON_BEAM, 90.0, 12.0, 1, 75, 1.0, 1.0)
	beam.cooldown_ms = 180
	beam.tags = [&"weapon"]
	c.add(beam)
	var throw := _placed(WEAPON_THROW, 40.0, 8.0, 2, 55, 0.95, 1.05)
	throw.tags = [&"weapon"]
	c.add(throw)

	var click := _flat(UI_CLICK, &"UI", 2, 60)
	click.cooldown_ms = 60
	c.add(click)
	var deny := _flat(UI_DENY, &"UI", 1, 60)
	deny.cooldown_ms = 250
	c.add(deny)

	# A body landing: dot-player-char's stock death sounds (Kenney, CC0), shipped in the addon.
	for row: Dictionary in DotPlayerDeathSounds.rows():
		var fall := _placed(row["id"], 45.0, 8.0, 3, 50, float(row["pitch_min"]), float(row["pitch_max"]))
		fall.path = row["path"]
		fall.variants = row["variants"]
		fall.gain_db = float(row["gain_db"])
		fall.cooldown_ms = int(row["cooldown_ms"])
		c.add(fall)

	# The field's toys: dot-props' stock toy sounds (Kenney, CC0), shipped in the addon.
	for row: Dictionary in DotPropToySounds.rows():
		var toy := _placed(row["id"], float(row["distance"]), 6.0, 3, 30, float(row["pitch_min"]), float(row["pitch_max"]))
		toy.path = row["path"]
		toy.variants = row["variants"]
		toy.gain_db = float(row["gain_db"])
		toy.cooldown_ms = int(row["cooldown_ms"])
		c.add(toy)

	return c


## Which synthesised voice stands in for each id until real audio is dropped into
## [member SOUND_DIR].
##
## [b]A table in the game rather than a guess in dot-audio.[/b] Which noise belongs to which
## id is this game's decision the same way the distances are. The choices worth reading
## against each other: the cannon is the heavy shot and a collapse is the boom, so the one
## that is a warning and the one that is a consequence never sound alike; a creak is the
## hurt voice pitched down, which is the nearest this synthesiser has to wood under load;
## and the teleport is the one upward sweep, because up reads as "on".
static func sound_recipes() -> Dictionary:
	return {
		CANNON_FIRE: DotAudioSynth.Voice.SHOT_HEAVY,
		IMPACT_LIGHT: DotAudioSynth.Voice.IMPACT,
		IMPACT_HEAVY: DotAudioSynth.Voice.BOOM,
		PLATFORM_CREAK: DotAudioSynth.Voice.HURT,
		PLATFORM_COLLAPSE: DotAudioSynth.Voice.BOOM,
		BARREL_BLAST: DotAudioSynth.Voice.BOOM,
		PLAYER_FELL: DotAudioSynth.Voice.DIE,
		PLAYER_DOWN: DotAudioSynth.Voice.HURT,
		YOU_ARE_OUT: DotAudioSynth.Voice.DIE,
		ROUND_START: DotAudioSynth.Voice.SPAWN,
		ROUND_END: DotAudioSynth.Voice.PICKUP,
		SHOWDOWN_TELEPORT: DotAudioSynth.Voice.SPAWN,
		SHOWDOWN_GO: DotAudioSynth.Voice.BLIP,
		SPECIAL: DotAudioSynth.Voice.PICKUP,
		WEAPON_SHOT: DotAudioSynth.Voice.SHOT,
		WEAPON_SWING: DotAudioSynth.Voice.STEP,
		WEAPON_LAUNCH: DotAudioSynth.Voice.SHOT_HEAVY,
		WEAPON_BEAM: DotAudioSynth.Voice.SHOT_TIGHT,
		WEAPON_THROW: DotAudioSynth.Voice.CLICK,
		UI_CLICK: DotAudioSynth.Voice.CLICK,
		UI_DENY: DotAudioSynth.Voice.DENY,
		# Stand-ins only for a build without dot-props' toy files.
		DotPropToySounds.BOUNCE: DotAudioSynth.Voice.IMPACT,
		DotPropToySounds.THUMP: DotAudioSynth.Voice.IMPACT,
		DotPropToySounds.KNOCK: DotAudioSynth.Voice.IMPACT,
		DotPropToySounds.PIN: DotAudioSynth.Voice.CLICK,
		DotPropToySounds.WOOD: DotAudioSynth.Voice.IMPACT,
		DotPropToySounds.RUBBER: DotAudioSynth.Voice.IMPACT,
		DotPropToySounds.PUNCH: DotAudioSynth.Voice.HURT,
		DotPropToySounds.METAL: DotAudioSynth.Voice.CLICK,
		DotPropToySounds.BELL: DotAudioSynth.Voice.PICKUP,
		DotPropToySounds.CLICK: DotAudioSynth.Voice.CLICK,
		DotPropToySounds.WATER: DotAudioSynth.Voice.STEP,
		DotPropToySounds.BOING: DotAudioSynth.Voice.SPAWN,
		DotPropToySounds.HORN: DotAudioSynth.Voice.BLIP,
		# Stand-ins only for a build without dot-player-char's files.
		DotPlayerDeathReactions.SOUND_THUD: DotAudioSynth.Voice.IMPACT,
		DotPlayerDeathReactions.SOUND_FACE_PLANT: DotAudioSynth.Voice.IMPACT,
		DotPlayerDeathReactions.SOUND_SLUMP: DotAudioSynth.Voice.STEP,
		DotPlayerDeathReactions.SOUND_WHOOSH: DotAudioSynth.Voice.SPAWN,
	}


## The id a kind of weapon use sounds like. `ZeeWeaponNet.KIND_*` in, an id or nothing out.
##
## [b]By kind, and that is the same number a watcher already receives.[/b] The snapshot says
## a weapon was used and what kind of use it was, in three bits, and not which weapon; a
## sound per weapon would need either the slot's definition looked up on every watcher or a
## wider field on the wire, for a distinction nobody hears across a showdown.
static func weapon_sound(kind: int) -> StringName:
	match kind:
		ZeeWeaponNet.KIND_SHOT:
			return WEAPON_SHOT
		ZeeWeaponNet.KIND_SWING:
			return WEAPON_SWING
		ZeeWeaponNet.KIND_SPAWN:
			return WEAPON_LAUNCH
		ZeeWeaponNet.KIND_BEAM:
			return WEAPON_BEAM
		ZeeWeaponNet.KIND_THROW:
			return WEAPON_THROW
		_:
			return &""


static func _placed(
	id: StringName,
	max_distance: float,
	unit_size: float,
	concurrent: int,
	priority: int,
	pitch_min: float,
	pitch_max: float
) -> DotAudioDef:
	var def := DotAudioDef.new()
	def.id = id
	def.path = "%s/%s.ogg" % [SOUND_DIR, String(id)]
	def.kind = DotAudioDef.Kind.POSITIONAL_3D
	def.bus = &"SFX"
	def.max_distance = max_distance
	def.unit_size = unit_size
	def.max_concurrent = concurrent
	def.priority = priority
	def.pitch_min = pitch_min
	def.pitch_max = pitch_max
	return def


static func _flat(id: StringName, bus: StringName, concurrent: int, priority: int) -> DotAudioDef:
	var def := DotAudioDef.new()
	def.id = id
	def.path = "%s/%s.ogg" % [SOUND_DIR, String(id)]
	def.bus = bus
	def.max_concurrent = concurrent
	def.priority = priority
	return def


# --- Building ---------------------------------------------------------------

func setup() -> DotResult:
	manager = DotAudioManager.new()
	manager.name = "Audio"
	manager.catalogue = sound_catalogue()
	manager.mixer = DotAudioMixer.new()
	# Not published: a client and a server in one process, which every suite here is, would
	# otherwise fight over one registry name — and nothing looks this up by name anyway.
	manager.register_as_service = false
	# A barrage, a collapse and a firefight at once is the busiest this game gets.
	manager.voices = 24
	# Measured toward the family's -17 LUFS (dot-audio docs/loudness.md): a 40 s stand-in round
	# read -21.5 LUFS integrated with the wind and the steps in.
	manager.loudness_trim_db = 4.0
	add_child(manager)

	var ready_now := manager.setup()

	if not ready_now.ok:
		return ready_now.wrap("smash-copter audio")

	steps = DotAudioFootsteps.new()
	steps.name = "Footsteps"
	steps.manager = manager
	steps.default_surface = &"concrete"
	add_child(steps)
	ambience = DotAudioAmbience.new()
	ambience.name = "Ambience"
	ambience.manager = manager
	ambience.fallback_bed = &"amb_wind"
	add_child(ambience)
	ambience.set_map_bed(&"amb_wind")

	# Only on a real sink: the manager has already decided whether there is a device, and a
	# headless process has nothing to bake for.
	var godot_sink := manager.sink as DotAudioSinkGodot

	if godot_sink != null:
		godot_sink.bank = DotAudioSynth.bank(manager.catalogue, sound_recipes())
		# INFO, once: the answer to "why does it sound like that" is in this line.
		DotLog.info(CHANNEL, "no audio files; synthesised stand-ins are in use", {
			"ids": sound_recipes().size(), "dir": SOUND_DIR,
		})

	return DotResult.success(null)


## Everybody this client knows steps, once a frame: players and bots alike.
func keep_walkers(bodies: Array) -> void:
	if steps != null:
		steps.keep(bodies)


## A map arrived: its bed and its ground. Empty keeps what is playing.
func on_map(bed: StringName, surface: StringName = &"") -> void:
	if ambience != null and bed != &"":
		ambience.set_map_bed(bed)
	if steps != null and surface != &"":
		steps.default_surface = surface


## Where the ears are, once a frame. The camera, which is the spectator's camera too.
func listen_from(at: Vector3) -> void:
	if manager != null:
		manager.listener_position = at


# --- What the client hears about ---------------------------------------------

## A prop turned up. The cannon's bang, if it turned up at the cannon's mouth.
func on_prop_appeared(at: Vector3) -> bool:
	if muzzle == Vector3.INF or at.distance_to(muzzle) > MUZZLE_REACH:
		return false

	return _at(CANNON_FIRE, at)


## Something landed on a platform. [param outcome] is [enum ScPlatforms.Impact].
func on_impact(at: Vector3, outcome: int, impulse: float = 0.0) -> bool:
	match outcome:
		ScPlatforms.Impact.WOBBLE:
			# Louder for a heavier blow, up to the point where a crate and a boulder would be
			# the same noise. The pitch is dot-audio's variation; the volume is information.
			return _at(IMPACT_LIGHT, at, clampf(0.45 + impulse / 3000.0, 0.45, 1.0))
		ScPlatforms.Impact.TOPPLED, ScPlatforms.Impact.SHATTERED:
			return _at(IMPACT_HEAVY, at)
		_:
			return false


func on_collapse(at: Vector3) -> bool:
	# A collapse is also the end of that platform's creak.
	return _at(PLATFORM_COLLAPSE, at)


func on_blast(at: Vector3) -> bool:
	return _at(BARREL_BLAST, at)


## Somebody is out. [param mine] is this client's own player, which is not a place.
func on_death(at: Vector3, fell: bool, mine: bool) -> bool:
	if mine:
		return _flat_play(YOU_ARE_OUT)

	return _at(PLAYER_FELL if fell else PLAYER_DOWN, at)


func on_round(began: bool) -> bool:
	_creaking.clear()
	return _flat_play(ROUND_START if began else ROUND_END)


func on_handover() -> bool:
	return _flat_play(SHOWDOWN_TELEPORT)


func on_showdown() -> bool:
	return _flat_play(SHOWDOWN_GO)


func on_special() -> bool:
	return _flat_play(SPECIAL)


## Somebody's weapon was used. [param kind] is `ZeeWeaponNet.KIND_*`.
##
## [b]Positional even for your own[/b], played at the camera, so it is at full volume and
## goes through the same pool, priorities and caps as everybody else's — a flat own-shot
## would be exempt from the concurrency cap that stops a minigun eating every voice.
func on_weapon(at: Vector3, kind: int) -> bool:
	var id := weapon_sound(kind)
	return _at(id, at) if id != &"" else false


func click() -> bool:
	return _flat_play(UI_CLICK)


func deny() -> bool:
	return _flat_play(UI_DENY)


## The creak, once a frame, from the leans this client already has.
##
## [b]Derived here and not sent, and that is the right way round for once.[/b] A client runs
## no platform model, but it does receive every platform's lean thirty times a second —
## that is the floor it is standing on. Whether a lean is near the collapse angle is a
## function of two numbers it has, and an event for it would be the server telling a client
## what the client's own snapshot already says. Returns how many platforms crossed into a
## creak this frame.
func present(platforms: ScPlatforms, collapse_lean: float) -> int:
	if platforms == null or collapse_lean <= 0.0:
		return 0

	var creaked := 0

	for index in range(platforms.count()):
		var deck := platforms.deck_at(index)

		if deck == null or not deck.is_standing():
			_creaking.erase(index)
			continue

		var fraction := deck.tilt() / collapse_lean

		if _creaking.has(index):
			if fraction < CREAK_CLEARS_AT:
				_creaking.erase(index)
			continue

		if fraction < CREAK_AT:
			continue

		_creaking[index] = true
		creaked += 1

		# Counted whether or not dot-audio plays it: the cooldown and the concurrency cap are
		# the manager's decision about the NOISE, and what this counts is the platform.
		var _heard := _at(PLATFORM_CREAK, deck.centre)

	return creaked


## A dead body's sound (dot-player-char's ragdolls), where it landed.
## A toy's sound (dot-props' toys): a bounce, where it happened.
func on_toy(id: StringName, at: Vector3, strength: float) -> bool:
	return _at(id, at, clampf(strength, 0.25, 1.0))


func on_body(id: StringName, at: Vector3, volume: float) -> bool:
	return _at(id, at, clampf(volume, 0.3, 1.0))


func _at(id: StringName, at: Vector3, volume: float = 1.0) -> bool:
	return manager != null and manager.play_at(id, at, volume) != 0


func _flat_play(id: StringName) -> bool:
	return manager != null and manager.play(id) != 0


func describe() -> Dictionary:
	var out := manager.describe() if manager != null else {}
	out["creaking"] = _creaking.size()
	return out
