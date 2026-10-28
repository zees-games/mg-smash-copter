extends DotGameModule

const ScNetBridge := preload("net/sc_net_bridge.gd")
const ScServices := preload("sc_services.gd")
const ScMapConfig := preload("sc_map_config.gd")
const ScAmbience := preload("sc_ambience.gd")
## The workbench kind of the ambience cvar set (saved to cfg/.../ambience/server.yml).
const AMBIENT_KIND := "ambience"

const ScGame := preload("sc_game.gd")
const ScLayouts := preload("sc_layouts.gd")
const ScPlayer := preload("sc_player.gd")
const ScSpecials := preload("sc_specials.gd")
const ScAvatars := preload("sc_avatars.gd")
const ScVote := preload("sc_vote.gd")
const ScMapSession := preload("sc_map_session.gd")

## Seconds between checks of how many people are in the round.
const ROSTER_INTERVAL := 2.0


## The `sc_bots` cvar, held so the tick does not look it up sixty times a second.
var _bots: DotConVar = null

## dot-workbench over the config and the block rules; the F9 panel off a dedicated server, the HTTP page only with `workbench.enabled`.
var workbench: DotGameWorkbench = null

## `mp_forcecamera`, kept so the deprecated `sc_spectate_camera` writes through it.
var _force_camera_cvar: Object = null

## How many stand-ins, from how many people: dot-server's one rule for every game. See
## [method _keep_the_round_full].
var _quota: DotBotQuota = null

var _since_roster_check: float = 0.0

## How many stand-ins this module has put in, so it can take them out again.
var _bot_ids: Array[StringName] = []

## The players' vote for the next layout; null when it could not be built.
var vote: ScVote = null

## dot-map's session over the layouts: the catalogue `map`, `maps`, `mapinfo` and the ballot list.
var maps: ScMapSession = null

## The drawn ballot's notice topic. The client shell draws one menu per topic.
const LAYOUT_BALLOT_TOPIC := &"map_ballot"


## A number as an operator would type it: `34`, not `34.000000`.
##
## Not `%g`: the parser accepts it and the format fails at runtime inside `_game_load`.
static func _number(value: float) -> String:
	return "%d" % int(round(value)) if is_equal_approx(value, round(value)) else "%.3f" % value


func _on_say_requested(peer_id: int, channel_id: StringName, text: String) -> void:
	var said: DotResult = services.call("say", peer_id, channel_id, text)

	if said.ok:
		return

	# Back to the one person who asked. A refusal broadcast would be a rate limit announced
	# to the server.
	bridge.call("notice", peer_id, said.error.message)


## A `!command` typed into chat. Run through the console as the person who typed it, with that
## player's own flags, so `!kick` is refused by the same file that refuses it at the console.
func _on_chat_command(peer_id: int, command: String, args: PackedStringArray) -> void:
	if server == null:
		return

	var session := server.session_of(peer_id)

	if session == null:
		return

	for reply in server.run_command_as_uid(
		session.uid(), command, args, DotCmdContext.Source.CHAT
	):
		bridge.call("notice", peer_id, reply)


func _cmd_say(ctx: DotCmdContext) -> void:
	var text := ctx.rest()

	if text.strip_edges() == "":
		ctx.reply("Say what?")
		return

	if services == null or services.get("chat") == null:
		ctx.reply("This server has no chat.")
		return

	var announced: Variant = services.get("chat").call("announce", text, ScServices.CH_ALL)

	if announced is DotResult and not (announced as DotResult).ok:
		ctx.reply_error(announced)
		return

	ctx.reply("Said: %s" % text)


func _cmd_status(ctx: DotCmdContext) -> void:
	var world := game as ScGame

	if world == null:
		ctx.reply("No world.")
		return

	ctx.reply_lines(world.describe_lines())


func _cmd_net(ctx: DotCmdContext) -> void:
	if bridge == null:
		ctx.reply("No bridge; this server is not replicating anything.")
		return

	ctx.reply_lines(bridge.call("describe_lines"))

	if services != null:
		ctx.reply_lines(services.call("describe_lines"))


func _cmd_layouts(ctx: DotCmdContext) -> void:
	var world := game as ScGame

	if world == null:
		ctx.reply("No world.")
		return

	var lines := PackedStringArray(["the layouts this server plays"])

	for layout in ScLayouts.all(world.config):
		lines.append("  %-11s w=%-5s %s" % [
			String(layout.id), _number(layout.weight), layout.blurb,
		])

	lines.append("playing: %s" % (String(world.layout.id) if world.layout != null else "-"))
	ctx.reply_lines(lines)


func _cmd_specials(ctx: DotCmdContext) -> void:
	var world := game as ScGame

	if world == null:
		ctx.reply("No world.")
		return

	var lines := PackedStringArray(["the specials this server may draw"])
	var allowed: Dictionary = {}

	for special in ScSpecials.available(world.config):
		allowed[special.id] = true

	for special in ScSpecials.all():
		lines.append("  %-9s %-14s %s%s" % [
			String(special.id),
			special.display_name,
			"" if allowed.has(special.id) else "(excluded) ",
			special.blurb,
		])

	lines.append("in force: %s" % (world.special_line() if not world.active.is_plain() else "-"))
	ctx.reply_lines(lines)
