extends RefCounted

const ScConfig := preload("sc_config.gd")

## The things that go wrong on purpose, as a catalogue of documents.
##
## [b]A special round is a set of multipliers, never a branch.[/b] Nothing in this file
## knows what a platform or a cannon is: it produces an [Active] with nine numbers on it
## and the rest of the game multiplies its own figures by them. That is the difference
## between adding a tenth special and editing nine files — and it is why the low-gravity
## round makes the props fall slower, the platforms lean lazily and the jumps hang without
## one line of code mentioning any of the three.
##
## [b]Two kinds, and the second one is the point.[/b] A special rolled at the start of a
## round is announced and lasts the round: it is a variant a player can plan around. One
## that arrives at ninety seconds is not — [GSRandomSchedule] decides when from the tick
## alone, so a server and a replay of it turn the gravity off at the same instant, and
## nobody on the server saw it coming.

const CHANNEL := "sc.specials"

## One thing that can go wrong, and what it multiplies.
##
## Every field is a multiplier on a configured number and every default is the identity,
## so a special that sets one field changes one thing and says so by omission.
class Special extends RefCounted:
	var id: StringName = &""
	var display_name: String = ""

	## What a player is told when it starts. One line, shouted.
	var blurb: String = ""

	## How likely this is against the others.
	var weight: float = 10.0

	## What the world's gravity is multiplied by. Reaches players, props and the chopper.
	var gravity_scale: float = 1.0

	## What the platforms' footing is multiplied by. Below one is ice.
	var grip_scale: float = 1.0

	## What the platforms' spring is multiplied by. Below one is a wobblier map.
	var stiffness_scale: float = 1.0

	## What the cannon's gap between shots is multiplied by. Below one is faster.
	var cannon_interval_scale: float = 1.0

	## What the cannon's volley size is multiplied by.
	var cannon_volley_scale: float = 1.0

	## How many tiers the cannon is allowed to climb past what the clock had earned.
	var cannon_tier_bonus: int = 0

	## What a player's running speed is multiplied by.
	var run_speed_scale: float = 1.0

	## How hard the wind blows, in newtons per kilogram, and which way at a heading of
	## zero. The direction is drawn per round; this is the strength.
	var wind: float = 0.0

	## Radians per second of lean thrown at every platform, per shake.
	var quake: float = 0.0

	## Seconds between shakes. Ignored when [member quake] is zero.
	var quake_interval: float = 3.0

	func describe() -> Dictionary:
		return {"id": String(id), "name": display_name}


## What is in force right now: the product of everything running, and nothing else.
##
## [b]Two specials can overlap and they multiply.[/b] A start-of-round low gravity and a
## mid-round barrage is a legitimate and very funny thing to be in the middle of, and the
## alternative — one at a time — would need a rule about which wins that nobody could
## predict from the outside.
class Active extends RefCounted:
	var gravity_scale: float = 1.0
	var grip_scale: float = 1.0
	var stiffness_scale: float = 1.0
	var cannon_interval_scale: float = 1.0
	var cannon_volley_scale: float = 1.0
	var cannon_tier_bonus: int = 0
	var run_speed_scale: float = 1.0
	var wind: float = 0.0
	var quake: float = 0.0
	var quake_interval: float = 3.0

	## The ids in force, for the HUD and for `describe()`.
	var ids: Array[StringName] = []

	func is_plain() -> bool:
		return ids.is_empty()

	func fold(special: Special) -> void:
		ids.append(special.id)
		gravity_scale *= special.gravity_scale
		grip_scale *= special.grip_scale
		stiffness_scale *= special.stiffness_scale
		cannon_interval_scale *= special.cannon_interval_scale
		cannon_volley_scale *= special.cannon_volley_scale
		cannon_tier_bonus += special.cannon_tier_bonus
		run_speed_scale *= special.run_speed_scale
		# The strongest wind and the strongest quake win rather than multiplying: two
		# winds at 1.0 each are not a wind at 1.0, and two multiplied would be a gale
		# nobody configured.
		wind = maxf(wind, special.wind)

		if special.quake > quake:
			quake = special.quake
			quake_interval = special.quake_interval


static func _make(
	p_id: StringName, p_name: String, p_weight: float, p_blurb: String
) -> Special:
	var special := Special.new()
	special.id = p_id
	special.display_name = p_name
	special.weight = p_weight
	special.blurb = p_blurb
	return special


## Everything a server may draw, before [member ScConfig.special_ids] narrows it.
static func all() -> Array[Special]:
	var out: Array[Special] = []

	var barrage := _make(&"barrage", "Barrage", 14.0, "BARRAGE — the cannon has opened up")
	barrage.cannon_interval_scale = 0.34
	barrage.cannon_volley_scale = 1.8
	out.append(barrage)

	var heavy := _make(&"heavy", "Heavy Ordnance", 11.0, "HEAVY — it is throwing the big ones")
	heavy.cannon_tier_bonus = 2
	# Slower, and it has to be: the same rate with the tiers unlocked is a map that is
	# gone in fifteen seconds, which is not a round anybody played.
	heavy.cannon_interval_scale = 1.55
	out.append(heavy)

	var feather := _make(&"feather", "Feather Fall", 12.0, "LOW GRAVITY — mind the landing")
	feather.gravity_scale = 0.42
	# The joke is that it is not a mercy. Everything falls slower, including the props,
	# so there is more in the air at once and the platforms have longer to lean before a
	# load slides off them.
	feather.stiffness_scale = 0.72
	feather.cannon_volley_scale = 1.4
	out.append(feather)

	var slick := _make(&"slick", "Black Ice", 12.0, "ICE — nothing is holding still")
	slick.grip_scale = 0.2
	out.append(slick)

	var gale := _make(&"gale", "Gale", 10.0, "WIND — everything is drifting")
	gale.wind = 5.5
	out.append(gale)

	var quake := _make(&"quake", "Aftershock", 10.0, "AFTERSHOCK — the pillars are moving")
	quake.quake = 0.42
	quake.quake_interval = 2.6
	out.append(quake)

	var jelly := _make(&"jelly", "Loose Pins", 11.0, "LOOSE PINS — the platforms have gone soft")
	jelly.stiffness_scale = 0.38
	out.append(jelly)

	var downpour := _make(&"downpour", "Downpour", 9.0, "STORM — wind, rain and a full magazine")
	downpour.wind = 3.6
	downpour.grip_scale = 0.55
	downpour.cannon_interval_scale = 0.62
	out.append(downpour)

	var rush := _make(&"rush", "Caffeine", 9.0, "EVERYBODY IS FASTER — including you")
	rush.run_speed_scale = 1.45
	# Faster people are a bigger load on a platform, which is the whole of this one: the
	# map gets no more dangerous and everybody makes it more dangerous themselves.
	out.append(rush)

	return out


## Every special this server is allowed to draw.
##
## [b]An allow-list of ids rather than a flag each, because the catalogue is data.[/b] An
## empty list is everything, which is the state a server that has never been configured
## should be in.
static func available(config: ScConfig) -> Array[Special]:
	var everything := all()

	if config.special_ids.is_empty():
		return everything

	var wanted: Dictionary = {}

	for id in config.special_ids:
		wanted[StringName(id)] = true

	var out: Array[Special] = []

	for special in everything:
		if wanted.has(special.id):
			out.append(special)

	if out.is_empty():
		# Said rather than silently ignored. An operator who mistyped every id would
		# otherwise have a server whose special rounds simply never happen, and nothing
		# anywhere would mention it.
		GSLog.warn(CHANNEL, "special_ids names nothing this game has", {
			"asked_for": ", ".join(config.special_ids),
			"available": ", ".join(ids()),
		})
		return everything

	return out


## One special drawn by weight, or null when none are available.
static func pick(config: ScConfig, stream: GSRandomStream) -> Special:
	var pool := available(config)

	if pool.is_empty():
		return null

	var weights := PackedFloat32Array()

	for special in pool:
		weights.append(maxf(special.weight, 0.0))

	var index := stream.next_weighted(weights)
	return pool[clampi(index, 0, pool.size() - 1)]


static func by_id(id: StringName) -> Special:
	for special in all():
		if special.id == id:
			return special

	return null


static func ids() -> PackedStringArray:
	var out := PackedStringArray()

	for special in all():
		out.append(String(special.id))

	return out


## The schedule a mid-round special fires on.
##
## [b]A pure function of the tick, which is the whole reason dot-core has one.[/b] A
## server and a replay of it, and two peers, all agree about when the gravity went off
## without anybody sending a message about it — and a schedule that drew from a stream
## per tick would give a different answer on a machine that had drawn a different number
## of times beforehand.
static func schedule(config: ScConfig, tick_rate: int) -> GSRandomSchedule:
	var plan := GSRandomSchedule.new()
	plan.mean_interval_ticks = int(maxf(config.special_mean_gap, 1.0) * float(tick_rate))
	plan.min_gap_ticks = int(maxf(config.special_min_gap, 1.0) * float(tick_rate))
	# A ramp, so the first one is never in the opening seconds: a round that goes strange
	# before anybody has found their feet is a round nobody understands losing.
	plan.ramp_ticks = int(12.0 * float(tick_rate))
	return plan
