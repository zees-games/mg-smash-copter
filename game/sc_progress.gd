extends Node

const ScPlayer := preload("sc_player.gd")
const ScPlatforms := preload("sc_platforms.gd")

## What a player keeps from a round: the numbers this game produces, and what they earn.
##
## [b]The numbers are the ones only this game has.[/b] A deathmatch counts kills; a floor
## game's interesting figures are about the floor — how many rounds somebody was still
## standing when the clock ran out, how many landings on their own platform they were not
## under, how many platforms went over with them on them. Each is declared once, in
## [method schema], counted as it happens and reported by dot-stats as a DELTA — "add one",
## never "now has forty" — so two servers reporting one player add up rather than overwrite.
##
## [b]Achievements are rules over those numbers and nothing else.[/b] dot-achievements never
## hears about a platform or a cannon; it hears that a number moved, through
## [DotAchievementStatsLink] — which is the differencer between dot-stats' SESSION totals
## and a lifetime total, and the reason this is not one `connect`. Wiring `recorded` straight
## into `record` would add the running total to the lifetime total on every reading.
##
## [b]Stand-ins are never counted.[/b] An empty server here is a server full of them, and an
## achievement a bot can earn is noise in every log an operator reads; a stand-in's numbers
## are also no player's numbers, so reporting them would be filing figures against nobody.
##
## [b]Server side, and on an offline client — wherever the world is authoritative.[/b] A
## connected client's world decides nothing, so it counts nothing; what a player is told is
## a notice from the server when they earn something.
##
## [b]A player's numbers are filed under their scoped profile key when they have one[/b] —
## dot-user's per-server derivation, which outlives a connection and can never carry a site
## account id (dot-stats' reporter refuses a `backbone:` key before it leaves the process,
## and this one is not one). [member durable_key_fn] supplies it; without one, or for a
## guest dot-user keeps no profile for, the key is the world's id, `u<session>`, and lasts a
## connection. The world's ids stay the world's: only what is handed to dot-stats and
## dot-achievements changes, through [method _key].
##
## [b]Fixed when counting begins, for the rest of the session.[/b] Counting begins on a
## player's first number, which is nearly always after dot-platform has admitted them; one
## who scored before their profile arrived keeps the session key until they reconnect,
## because moving half a session's numbers to another key mid-flight would file the second
## half against a total the first half never reached.

const CHANNEL := "sc.progress"


## Rounds a player was in from the start to the end.
const ROUNDS_PLAYED := &"sc.rounds_played"
## Rounds a player was still up when the clock ran out, and was thrown into the corners.
const ROUNDS_SURVIVED := &"sc.rounds_survived"
## Rounds their side won, however it won.
const ROUNDS_WON := &"sc.rounds_won"
## Rounds their side won in the showdown with them still standing in it.
const SHOWDOWN_WINS := &"sc.showdown_wins"
## People on another side they put out in the corners.
const SHOWDOWN_KILLS := &"sc.showdown_kills"
## The most of those in one round. A BEST, so it is the high-water mark, not a sum.
const BEST_ROUND_KILLS := &"sc.best_round_kills"
const DEATHS := &"sc.deaths"
## Deaths that were running out of map, which in this game is most of them.
const FALLS := &"sc.falls"
## Platforms that went over by LEAN — somebody stood in the wrong place — with them on it.
const PLATFORMS_TIPPED := &"sc.platforms_tipped"
## Things the cannon landed on their own platform that missed them.
const PROPS_DODGED := &"sc.props_dodged"

## Somebody earned something. [param player_id] is theirs; the world tells them.
signal earned(player_id: StringName, title: String, points: int)

var stats: DotStatsTracker = null
var achievements: DotAchievementTracker = null
var link: DotAchievementStatsLink = null

## The world's own dictionaries, shared. See [ScSpectate] for why not a reference to it.
var players: Dictionary = {}
var sides: Dictionary = {}

## Metres from a landing inside which a player was not "missed". The world's own hurt
## radius, handed in rather than copied.
var hurt_radius: float = 2.4

## Players present when this round began. Only they have played it.
var _in_round: Dictionary = {}

## player id -> kills in this round, for [constant BEST_ROUND_KILLS].
var _round_kills: Dictionary = {}

## Whether this round reached the corners.
var _reached_showdown: bool = false

## `func(player_id: StringName) -> String`: the durable key to file this player under, or
## "" for none. Set by the module from dot-platform; see the class note.
var durable_key_fn: Callable = Callable()

## World id -> the key their numbers are filed under, and back. Fixed at [method record]'s
## first reading for them.
var _keys: Dictionary = {}
var _ids: Dictionary = {}



static func ids() -> Array[StringName]:
	return [
		ROUNDS_PLAYED, ROUNDS_SURVIVED, ROUNDS_WON, SHOWDOWN_WINS, SHOWDOWN_KILLS,
		BEST_ROUND_KILLS, DEATHS, FALLS, PLATFORMS_TIPPED, PROPS_DODGED,
	]


## Every number, once. [b]`publish` on the ones a player page would show[/b]; deaths and
## rounds played are inputs to a ratio rather than figures anybody reads, and dot-stats
## defaults publishing off per stat for exactly that choice.
static func schema() -> DotStatsSchema:
	var out := DotStatsSchema.new()
	_add(out, ROUNDS_PLAYED, DotStatsDef.Kind.COUNTER, "Rounds played", "rounds", false)
	_add(out, ROUNDS_SURVIVED, DotStatsDef.Kind.COUNTER, "Rounds survived", "rounds", true)
	_add(out, ROUNDS_WON, DotStatsDef.Kind.COUNTER, "Rounds won", "rounds", true)
	_add(out, SHOWDOWN_WINS, DotStatsDef.Kind.COUNTER, "Showdowns won", "rounds", true)
	_add(out, SHOWDOWN_KILLS, DotStatsDef.Kind.COUNTER, "Showdown kills", "kills", true)
	_add(out, BEST_ROUND_KILLS, DotStatsDef.Kind.BEST, "Best showdown", "kills", true)
	_add(out, DEATHS, DotStatsDef.Kind.COUNTER, "Deaths", "deaths", false)
	_add(out, FALLS, DotStatsDef.Kind.COUNTER, "Falls", "falls", true)
	_add(out, PLATFORMS_TIPPED, DotStatsDef.Kind.COUNTER, "Platforms tipped", "platforms", true)
	_add(out, PROPS_DODGED, DotStatsDef.Kind.COUNTER, "Props dodged", "props", true)
	return out


static func _add(
	out: DotStatsSchema, id: StringName, kind: DotStatsDef.Kind, display: String,
	unit: String, publish: bool
) -> void:
	var def := DotStatsDef.make(id, kind, display)
	def.unit = unit
	def.publish = publish
	out.stats.append(def)


## What a player can earn, as rules over [method schema]'s numbers.
##
## [b]Every stat read here is one [method schema] declares and this file records[/b] — an
## achievement over a stat nothing reports never unlocks and nothing errors, which is this
## family's most repeated bug wearing a rosette. The suite checks it both ways.
##
## One stat, one merge: everything is SUM except the best round, which is HIGHEST —
## dot-achievements refuses a catalogue that reads one number both ways.
static func catalogue() -> DotAchievementCatalogue:
	var made: Array[DotAchievement] = []

	made.append(_sum(&"sc.still_standing", "Still Standing", ROUNDS_SURVIVED, 1.0, 10,
		"Be up when the clock runs out.", &"sc.survivor", 1))
	made.append(_sum(&"sc.sure_footed", "Sure-Footed", ROUNDS_SURVIVED, 25.0, 30,
		"Be up when the clock runs out, twenty-five times.", &"sc.survivor", 2))
	made.append(_sum(&"sc.last_ones_up", "Last Ones Up", SHOWDOWN_WINS, 1.0, 20,
		"Win a showdown, still standing in it."))
	made.append(_sum(&"sc.corner_marksman", "Corner Marksman", SHOWDOWN_KILLS, 10.0, 25,
		"Put ten people out in the corners."))
	made.append(_sum(&"sc.read_the_sky", "Read the Sky", PROPS_DODGED, 50.0, 20,
		"Not be under fifty things the cannon landed on your platform."))

	# A BEST: three in one showdown, not three over a career.
	var sweep := DotAchievement.make(&"sc.clean_sweep", "Clean Sweep", [
		DotAchievementRule.make(
			BEST_ROUND_KILLS, 3.0, DotAchievementRule.Op.AT_LEAST,
			DotAchievementRule.Merge.HIGHEST
		),
	])
	sweep.description = "Put three people out in one showdown."
	sweep.points = 30
	made.append(sweep)

	# Secret: both are earned by the mistake the game is about, which a player makes before
	# they know there is anything to earn — and the joke only works afterwards.
	var tipped := _sum(&"sc.tipping_point", "Tipping Point", PLATFORMS_TIPPED, 1.0, 10,
		"Stand where the platform could not take it.")
	tipped.secret = true
	made.append(tipped)

	var flyer := _sum(&"sc.frequent_flyer", "Frequent Flyer", FALLS, 10.0, 10,
		"Run out of map ten times.")
	flyer.secret = true
	made.append(flyer)

	var out := DotAchievementCatalogue.new()
	out.achievements = made
	return out


static func _sum(
	id: StringName, title: String, stat: StringName, target: float, points: int,
	description: String, series: StringName = &"", tier: int = 0
) -> DotAchievement:
	var out := DotAchievement.make(id, title, [
		DotAchievementRule.make(
			stat, target, DotAchievementRule.Op.AT_LEAST, DotAchievementRule.Merge.SUM
		),
	])
	out.description = description
	out.points = points
	out.series = series
	out.tier = tier
	return out



## [param directory] empty keeps achievement progress in memory; see
## [member ScConfig.progress_directory]. [param report] is [member ScConfig.report_progress].
func setup(directory: String, report: bool) -> DotResult:
	stats = DotStatsTracker.new()
	stats.name = "Stats"
	stats.schema = schema()
	stats.report_to_backbone = report
	stats.define_on_start = report
	add_child(stats)

	var counted := stats.start()

	if not counted.ok:
		return counted.wrap("smash-copter stats")

	achievements = DotAchievementTracker.new()
	achievements.name = "Achievements"
	achievements.catalogue = catalogue()
	achievements.report_to_backbone = report
	# Not published: a server and a client in one process — every suite here — would fight
	# over one registry name, and the link below is handed the tracker directly.
	achievements.register_as = &""

	if directory != "":
		var file_store := DotAchievementStoreFile.new()
		file_store.directory = directory
		achievements.store = file_store
	else:
		achievements.store = DotAchievementStoreMemory.new()

	add_child(achievements)

	var awarded := achievements.start()

	if not awarded.ok:
		return awarded.wrap("smash-copter achievements")

	achievements.unlocked.connect(_on_unlocked)

	link = DotAchievementStatsLink.new()
	link.name = "StatsLink"
	link.tracker = achievements
	link.stats = stats
	add_child(link)

	return link.start().wrap("smash-copter's stats-to-achievements link")



## Files one reading for one person, and starts counting for them the first time.
##
## [b]Begun lazily, on the first number, and that is what keeps stand-ins out.[/b] A player
## is added to the world before a bridge or a client marks them a stand-in, so a check at
## join time would see every bot as a person; by the time anything is worth counting, the
## flag is set. The memory and file stores load synchronously, so the achievement tracker
## has them before the reading that follows.
func record(player_id: StringName, stat: StringName, value: float = 1.0) -> void:
	if stats == null:
		return

	var body: ScPlayer = players.get(player_id)

	if body == null or body.is_bot:
		return

	var key := _key(player_id)

	if not stats.has_player(key):
		stats.begin(key, body.display_name)
		_begin(key)

	var filed := stats.record(key, stat, value)

	if not filed.ok:
		# WARN: a number a player earned that nobody will ever see. It is a schema or a key
		# that is wrong, and it only ever happens for a reason worth looking at.
		DotLog.warn(CHANNEL, "a reading was refused", {
			"player": String(player_id), "stat": String(stat), "why": filed.error.message,
		})


## The key a player's numbers are filed under. Asked of [member durable_key_fn] once, then
## remembered; see the class note.
func _key(player_id: StringName) -> StringName:
	if _keys.has(player_id):
		return _keys[player_id]

	var key := player_id

	if durable_key_fn.is_valid():
		var durable := str(durable_key_fn.call(player_id))

		if durable != "":
			key = StringName(durable)

	_keys[player_id] = key
	_ids[key] = player_id
	return key


## Loads somebody's lifetime progress. A statement call, never assigned: the tracker's
## `begin` is a coroutine, and this is the family's pattern for starting one from code that
## is not — `await` inside, a bare call outside.
func _begin(player_id: StringName) -> void:
	var began: DotResult = await achievements.begin(String(player_id))

	if not began.ok:
		# WARN: this player will earn nothing this session, and they will not be told why.
		DotLog.warn(CHANNEL, "achievement progress could not be loaded", {
			"player": String(player_id), "why": began.error.message,
		})


## Saves somebody's progress as they go. See [method _begin].
func _end(player_id: StringName) -> void:
	var ended: DotResult = await achievements.end(String(player_id))

	if not ended.ok:
		DotLog.warn(CHANNEL, "achievement progress could not be saved", {
			"player": String(player_id), "why": ended.error.message,
		})


## Stops counting for somebody who left, and saves what they earned.
func leave(player_id: StringName) -> void:
	_in_round.erase(player_id)
	_round_kills.erase(player_id)

	var key: StringName = _keys.get(player_id, player_id)
	_keys.erase(player_id)
	_ids.erase(key)

	if stats == null or not stats.has_player(key):
		return

	var _values := stats.end(key)
	link.forget(String(key))
	_end(key)


func session_values(player_id: StringName) -> DotStatsValues:
	return stats.session_values(_keys.get(player_id, player_id)) \
		if stats != null else DotStatsValues.new()


## The key [param player_id]'s numbers are filed under. For a console command and a suite.
func filed_under(player_id: StringName) -> StringName:
	return _keys.get(player_id, player_id)



func on_round_began() -> void:
	_in_round.clear()
	_round_kills.clear()
	_reached_showdown = false

	for id: StringName in players:
		if int(sides.get(id, 0)) > 0:
			_in_round[id] = true


## The clock ran out. Everybody still up survived the first half.
func on_handover() -> void:
	_reached_showdown = true

	for id: StringName in players:
		if (players[id] as ScPlayer).is_alive():
			record(id, ROUNDS_SURVIVED)


## A round ended. [param winner] is a team id, or 0 for a draw.
func on_round_over(winner: int) -> void:
	for id: StringName in _in_round.keys():
		var body: ScPlayer = players.get(id)

		if body == null:
			continue

		record(id, ROUNDS_PLAYED)

		var side := int(sides.get(id, 0))

		if winner > 0 and side == winner:
			record(id, ROUNDS_WON)

			if _reached_showdown and body.is_alive():
				record(id, SHOWDOWN_WINS)

		var kills := int(_round_kills.get(id, 0))

		if kills > 0:
			record(id, BEST_ROUND_KILLS, float(kills))

	_in_round.clear()
	_round_kills.clear()


## Somebody is out. [param by] is who did it, or empty for the world.
func on_died(player_id: StringName, by: StringName, fell: bool, in_showdown: bool) -> void:
	record(player_id, DEATHS)

	if fell:
		record(player_id, FALLS)

	if by == &"" or by == player_id or not players.has(by):
		return

	# Not a team-mate. Friendly fire is off in this game, but a barrel somebody on your own
	# side set off is still somebody on your own side.
	if int(sides.get(by, 0)) == int(sides.get(player_id, 0)):
		return

	if in_showdown:
		record(by, SHOWDOWN_KILLS)
		_round_kills[by] = int(_round_kills.get(by, 0)) + 1


## A platform came off its pillar. Everybody standing on it when it went over by LEAN tipped
## it — which is the one collapse that is somebody's doing rather than the cannon's.
func on_platform_collapsed(index: int, why: StringName) -> void:
	if why != ScPlatforms.WHY_LEAN:
		return

	for id: StringName in players:
		var body: ScPlayer = players[id]

		if body.is_alive() and not body.riding and body.standing_on == index:
			record(id, PLATFORMS_TIPPED)


## Something landed on a platform and only leaned it. Everybody on that platform it missed
## has dodged it — and a landing that took the platform down dodged nobody.
func on_platform_struck(index: int, at: Vector3, outcome: int) -> void:
	if outcome != ScPlatforms.Impact.WOBBLE:
		return

	for id: StringName in players:
		var body: ScPlayer = players[id]

		if not body.is_alive() or body.riding or body.standing_on != index:
			continue

		var offset := body.controller.state.position + Vector3.UP * 0.9 - at

		if offset.length() > hurt_radius:
			record(id, PROPS_DODGED)


func _on_unlocked(player: String, achievement: DotAchievement) -> void:
	# INFO: what an admin keeps. "I did the thing and was not told" is answered here.
	DotLog.info(CHANNEL, "an achievement was unlocked", {
		"player": player, "achievement": String(achievement.id), "points": achievement.points,
	})
	# Back to the world's id: the world tells the player, and the world knows them by that.
	earned.emit(_ids.get(StringName(player), StringName(player)),
		achievement.display_name, achievement.points)


func describe() -> Dictionary:
	return {
		"tracking": stats.players().size() if stats != null else 0,
		"in_round": _in_round.size(),
		"achievements": achievements.catalogue.size() if achievements != null else 0,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if stats != null:
		out.append_array(stats.describe_lines())

	if achievements != null:
		out.append_array(achievements.describe_lines())

	return out
