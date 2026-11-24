extends GSPlayerGameServices

# Kept though unused here: they fix the order these scripts load in, and without them the headless run ends with 456 resources still in use (a load-order cycle between the client and server scripts).
const ScGame := preload("sc_game.gd")
const ScNetBridge := preload("net/sc_net_bridge.gd")
const ScPlayer := preload("sc_player.gd")

## Chat, voice and moderation, wired to this game's sides.
## Short because [GSGameServices] holds the rest; what is left is who can hear whom and where somebody is standing.
## Proximity is the channel that matters: the field is open air where everybody sees everybody, so the useful conversation is the four people on the next platform. About two platform pitches reaches neighbours but not the far end, which makes it a channel rather than a second "all".

# No `const CHANNEL`: [GSGameServices] declares one and GDScript refuses a redeclaration,
# which is the right refusal — one layer, one channel an operator can turn up.

const CH_ALL := &"all"
const CH_TEAM := &"team"
const CH_NEAR := &"near"
const CH_ADMIN := &"admin"
const CH_WHISPER := &"whisper"

## Metres a shout carries. About two platform pitches — see the class documentation.
const PROXIMITY_RANGE := 26.0

func _services_name() -> String:
	return "smash-copter"


func _chat_rules() -> Object:
	return chat_rules()


## The same rules, as a static a CLIENT can ask for without building a services layer.
## Static because a client calling `new()` on the [Node] to read two numbers would build and leak a moderation store and router, and inside a delivered pack would fail to compile: a script whose base class lives in the HOST build cannot hand its return type to a script in the mount.
static func chat_rules() -> GSChatRules:
	var rules := GSChatRules.new()
	rules.max_length = 140
	rules.refuse_over_length = false
	rules.allow_newlines = false
	rules.escape_markup = true
	rules.strip_invisible = true
	rules.collapse_whitespace = true
	rules.rate_per_minute = 22
	rules.burst = 4.0
	rules.flood_penalty_sec = 10.0
	rules.duplicate_window_sec = 8.0
	rules.duplicate_depth = 3
	rules.command_prefixes = PackedStringArray(["!", "/"])
	# An unclaimed `!command` is not broadcast: a player typing `!ban` at a server with no
	# such command would otherwise say "!ban" to everybody, which is worse than nothing
	# happening.
	rules.broadcast_unknown_commands = false
	rules.history_limit = 300
	return rules


func _chat_channels() -> Array:
	return chat_channels()


static func chat_channels() -> Array[GSChatChannel]:
	var out: Array[GSChatChannel] = []

	var everyone := GSChatChannel.make(CH_ALL, "All", GSChatChannel.Scope.EVERYONE)
	everyone.colour = Color(0.93, 0.94, 0.96)
	# Short, because a round is a few minutes: a backlog longer than the round is a
	# conversation from a game the new player was not in.
	everyone.backlog = 10
	everyone.history_limit = 200
	out.append(everyone)

	var team := GSChatChannel.make(CH_TEAM, "Team", GSChatChannel.Scope.TEAM)
	team.prefix = "[team]"
	team.colour = Color(0.55, 0.82, 0.95)
	# [b]No backlog, and the showdown is what makes that matter.[/b] A backlog is handed to
	# whoever joins, and a replayed team line in the second half of a round is one side's
	# plan handed to the people it is about.
	team.backlog = 0
	team.history_limit = 120
	out.append(team)

	var near := GSChatChannel.make(CH_NEAR, "Near", GSChatChannel.Scope.RADIUS)
	near.prefix = "[near]"
	near.colour = Color(0.82, 0.86, 0.72)
	near.radius = PROXIMITY_RANGE
	near.backlog = 0
	near.history_limit = 80
	out.append(near)

	var admin := GSChatChannel.make(CH_ADMIN, "Admin", GSChatChannel.Scope.EVERYONE)
	admin.prefix = "[ADMIN]"
	admin.colour = Color(0.98, 0.72, 0.35)
	admin.admin_only = true
	# A gag is about a player's speech; an admin who has been gagged has a bigger problem
	# than chat.
	admin.ignores_gag = true
	admin.backlog = 0
	out.append(admin)

	var whisper := GSChatChannel.make(CH_WHISPER, "Whisper", GSChatChannel.Scope.DIRECT)
	whisper.prefix = "[w]"
	whisper.colour = Color(0.78, 0.71, 0.93)
	whisper.backlog = 0
	out.append(whisper)

	return out


## The voice format, which both ends must agree on exactly.
## Static because the CLIENT builds one too; a differing sample rate is a stream of packets the router refuses as the wrong length, said to nobody ([method GSVoiceConfig.format_fingerprint]).
static func voice_format() -> GSVoiceConfig:
	var config := GSVoiceConfig.new()
	config.sample_rate = 16000
	config.frame_ms = 20.0
	config.codec_id = &"adpcm"
	# Push to talk, because the survival phase is two minutes of people shouting: open-mic voice across a side of six is six people reacting to six different platforms.
	config.push_to_talk = true
	config.activation_rms = 0.02
	config.hangover_ms = 250.0
	config.jitter_ms = 60.0
	config.jitter_max_ms = 400.0
	config.proximity_range = PROXIMITY_RANGE
	config.max_bytes_per_second = 6144
	return config


func _voice_config() -> Object:
	return voice_format()


## Voice goes to the whole server: every side is on the same field for the first two minutes with the same problem, and half the fun is hearing somebody else find out their platform was going.
## Team voice is a key away and is what the showdown is played on.
func _voice_default_channel() -> int:
	return GSVoiceRouter.Channel.ALL


## A pilot riding a platform is moved with it, not by an admin.
func _mod_movable(p: Object) -> bool:
	return not (p as ScPlayer).riding


func _mod_unsupported() -> Dictionary:
	return {
		"respawn": "falling is how a round is lost here, and putting a faller back decides it",
		"give": "weapons are handed out at the handover, one each at random, and that draw is the fight's fairness",
		"strip": "weapons are handed out at the handover, one each at random, and that draw is the fight's fairness",
		"burn": "nothing here burns a player",
	}

