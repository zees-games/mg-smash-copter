extends Node

const ScCopterNet := preload("sc_copter_net.gd")
const ScEvent := preload("sc_event.gd")
const ScEvents := preload("sc_events.gd")
const ScNetCommand := preload("sc_net_command.gd")
const ScNetLink := preload("sc_net_link.gd")
const ScPlatformNet := preload("sc_platform_net.gd")
const ScPlayerNet := preload("sc_player_net.gd")
const ScToyNet := preload("sc_toy_net.gd")
const ScPropNet := preload("sc_prop_net.gd")
const ScRequest := preload("sc_request.gd")

const ScContent := preload("../sc_content.gd")
const ScGame := preload("../sc_game.gd")
const ScPlatforms := preload("../sc_platforms.gd")
const ScPlayer := preload("../sc_player.gd")

const CHANNEL := "sc.net"

## Bytes of acknowledgement in front of every input packet. [method DotNetManager.encode_ack].
const ACK_BYTES := 4

## Commands in every input packet: this tick's and the four before it, so a lost packet
## costs the server no tick unless the next four are lost too. Over WebSocket nothing is
## ever lost; over ENet (the desktop client, since servers went dual-stack) one command a
## packet was a tick the server ran on the previous command for every packet dropped.
## game-arena measured it first: 80% of ticks with the right command at 20% loss with one
## copy, 99-100% with three, and five closed the rest (2026-10-09).
const INPUT_COPIES := 5

## How often the round clock and the numbers behind it go out, in ticks.
##
## [b]Twice a second, not per tick and not per snapshot.[/b] What it carries changes when a
## platform goes or a second passes, and a client told sixty-four times a second would be
## paying for sixty-two copies of the same six numbers. The clock itself is advanced on the
## client between messages — see [method _apply_clock].
const CLOCK_EVERY := 32

## The client has been told who it is. [param player_id] is the session id.
signal hello_received(player_id: int)

## Somebody joined, left or changed sides. Client side; the HUD and a scoreboard read it.
signal roster_changed(player_id: int)

## A round began or ended.
signal round_changed(number: int, began: bool, winner: int)

## The round changed half. Client side.
signal phase_received(phase: int)

## Something strange started or stopped.
signal special_received(special_id: StringName, starting: bool, blurb: String)

## Somebody died, and what did it.
signal death_received(player_id: int, by: int, why: StringName)

## A platform came off its pillar. What a client shakes the screen for.
signal collapse_received(index: int, why: StringName)

## A barrel went off, where, and how far it reached.
signal blast_received(at: Vector3, radius: float)

## A player got into or out of a chopper. The camera and the HUD read it.
signal seat_changed(player_id: int, seated: bool)

## A survivor was handed a weapon. The HUD names it.
signal armed_received(player_id: int, weapon_id: StringName)
## Your shot landed (see [signal ScGame.hit_landed]); only ever to the shooter.
signal hit_received(point: Vector3, killed: bool, headshot: bool)

signal notice_received(text: String)

## Client side: the server moved this client's own camera. [param mode] is
## [enum DotSpectatorView.Mode]; the view has already been adopted by the world's mirror.
signal spectate_received(viewer: int, mode: int, target: int)

## Client side: something landed on a platform. What a client makes a noise about.
signal impact_received(at: Vector3, outcome: int, impulse: float)

## Client side: somebody else used their weapon [param times] times since the last
## snapshot. [param kind] is one of `ZeeWeaponNet.KIND_*`. Relayed from that player's own
## behaviour, because a client builds those one per JOIN and nothing else could find them.
signal weapon_used_by(session_id: int, times: int, kind: int)

## Client side: a prop or a chopper arrived, at [param at]. What the cannon's bang is heard
## from — see `ScAudio.on_prop_appeared` for why "arrived at the muzzle" means "fired".
signal prop_arrived(at: Vector3, vehicle: bool)

## Somebody pressed Enter. Server side, and the only thing this bridge does with chat.
##
## [b]The bridge carries chat and decides nothing about it.[/b] Who may say what, on which
## channel, how often and who hears it are [DotChatRouter]'s, and the router is the services
## layer's.
signal say_requested(peer_id: int, channel_id: StringName, text: String)

## A voice frame arrived. Server side; the payload is unparsed and must not be trusted —
## [method DotVoiceRouter.relay] is what stamps the speaker, from the peer id below.
signal voice_requested(peer_id: int, payload: PackedByteArray)

## Client side: one routed line, and one voice frame.
signal chat_received(wire: Dictionary)
signal voice_arrived(payload: PackedByteArray)

var game: ScGame = null
var net: DotNetManager = null
var link: ScNetLink = null

## Which session this process is. Zero on a server.
var local_player_id: int = 0

## Where the clock learns how long the link is, in milliseconds.
##
## dot-net never touches a transport and cannot measure it; dot-server's heartbeat already
## does ([method DotClientLink.ping_ms]). A client that feeds nothing has a clock that
## assumes an instant connection and stamps every command for a tick the server has already
## simulated — and the symptom is every command being discarded as late. Two games in this
## family shipped without a sample and read a median of an empty set.
var rtt_source: Callable = Callable()

## Where a voice frame goes on the server. Assigned by [DotGameModule] to the services
## layer's `relay_voice`, because the bridge is the only thing that names both ends.
var voice_relay_fn: Callable = Callable()

## `func(session_id: int) -> DotAvatar`: what a player looks like, asked once as they are
## seated. Assigned by the module, which is what has the identity layer; unset, or answering
## null, is the stock person, which is what everybody was before there was one.
var avatar_fn: Callable = Callable()

var _entities: Node = null

## session id -> [ScPlayerNet].
var _behaviours: Dictionary = {}

## The next session id handed to somebody the world made itself.
##
## [b]Well above anything dot-server will issue, and a bot needs one at all because of how a
## player id is written.[/b] Every id on the wire is `u<session>`, and a player called `bot`
## parses back to session ZERO — so two bots are one entry in [member _behaviours], and
## their JOIN carries a player id that is also dot-net's broadcast address.
const FIRST_BOT_SESSION := 900000

var _next_bot_session: int = FIRST_BOT_SESSION

## net id -> the behaviour replicating that body, on BOTH ends.
##
## [b]Keyed by net id rather than by instance id, and that is what makes the tick loop the
## same on both ends.[/b] A prop instance id and a vehicle instance id are two counters in
## two addons that both start at 1, so a table keyed on either holds two different things
## under one key the moment a chopper and a crate exist together.
var _bodies: Dictionary = {}

## Server only: `"p<instance>"`, `"v<instance>"` or `"d<index>"` -> net id, so a removal can
## find what to unregister.
var _net_of: Dictionary = {}

var _player_of_peer: Dictionary = {}
var _peer_of_player: Dictionary = {}
var _ready_peers: Dictionary = {}
## Server: peers whose READY came before their seat ([method add_player]). A client sends READY
## when its link says PLAYING, which the link decides itself after sending `loaded` on another
## channel; over ENet with loss the READY can overtake `loaded`, and a READY dropped here left
## that client waiting for a world for ever. Admitted when seated.
## Carries the game's profile runtime over this manager (rows down, for a remote admin's panel).
var profile_link: DotNetProfileLink = null
var _ready_unseated: Dictionary = {}

var _tick: int = 0
var _game_ticked_for: int = -1

## Server only: whether [method DotNetManager.server_tick] is on the stack, and the net ids
## let go of while it was.
##
## [b]A round re-laid mid-tick leaks a lag-compensation track per platform, for ever.[/b]
## The world ticks inside the first player behaviour's `_net_simulate`, so a round that ends
## there unregisters every platform while `server_tick` is still holding the identity list
## it took before simulating — and then records history for that list. The registry has
## already told the history to forget each id; the record makes a fresh track for it again,
## and nothing ever forgets it a second time. Twelve orphaned tracks per round, measured.
## Forgotten again here once the manager has let go of its list.
var _in_server_tick := false
var _unregistered_in_tick: Array[int] = []
var _client_ticked_for: int = -1

## The layout the client was last told about, so it can be re-sent to a late joiner.
var _layout_body: PackedByteArray = PackedByteArray()
