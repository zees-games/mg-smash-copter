extends Node

const ScBindings := preload("sc_bindings.gd")
const ScAudio := preload("sc_audio.gd")
const ScWeaponIcons := preload("sc_weapon_icons.gd")
const ScSettings := preload("sc_settings.gd")
const ScServices := preload("sc_services.gd")
const ScPlayerNet := preload("net/sc_player_net.gd")
const ScNetBridge := preload("net/sc_net_bridge.gd")
const ScNetCommand := preload("net/sc_net_command.gd")

const ScConfig := preload("sc_config.gd")
const ScMapConfig := preload("sc_map_config.gd")
const ScGame := preload("sc_game.gd")
const ScHud := preload("sc_hud.gd")
const ScPaths := preload("sc_paths.gd")
const ScPlayer := preload("sc_player.gd")
const ScKillcam := preload("sc_killcam.gd")
const ScSpecials := preload("sc_specials.gd")
const ScWorkshop := preload("sc_workshop.gd")

const CHANNEL := "sc.client"

## Where the camera sits behind the player in third person, in metres.
const CHASE_BACK := 4.6
const CHASE_UP := 2.1


@export var config_file: String = "user://cfg/smash-copter.json"

## Play alone even when a link is available. `--offline`.
@export var force_offline: bool = false

## How many stand-ins the offline field gets, so a round can actually run.
@export_range(0, 12, 1) var offline_bots: int = 3

## Which view the camera starts in.
@export var third_person: bool = false

var game: ScGame = null
## Asks a server whether this player may edit it (sv_workbench_remote); null offline.
var workbench_remote: DotGameWorkbenchRemoteClient = null
## The tuning panel's host: F9 solo, the admin's remote panel on a server that allows it.
var workbench: DotGameWorkbench = null
var player: ScPlayer = null
var camera: Camera3D = null

## Keeps the screen covered, and the local body and the input still, until the field, the
## player and the camera are all in. See [member DotGameClient.gate].
var gate: DotLoadGate = null

## dot-game's client platform: the cover, settings and menu, console, HUD theme, Tab, M, the
## pointer and the input block. See [DotGameClient].
var platform: DotGameClient = null
## Solo only: the subscribed map packs this client follows (null connected).
var workshop: ScWorkshop = null
var hud: ScHud = null
var chat: DotGameChatClient = null

## What the game sounds like. See [ScAudio].
var audio: ScAudio = null

## The player's own settings and the screen Escape opens. See [ScSettings].
var settings: ScSettings = null

## The player's console. See [method DotConsoleKit.build].
var console: DotConsoleController = null

## The weapons in this player's own hands, once the showdown has started. Drawn, never decided:
## every shot that matters is the server's; the rig is a view model that moves (deploy, reload,
## recoil), because a gun that never animates reads as a texture stuck to the screen.
var weapons: ZeeWeaponRig = null
var view_model: ZeeViewModel = null

var net: DotNetManager = null
var bridge: ScNetBridge = null
var link: Node = null

## The Tab board, the menu's. See [member DotGameClient.board].
var board: DotMenuScoreboard = null
## Records every frame and replays the round's last moment ([ScKillcam]); then the reveal.
var killcam: ScKillcam = null
var winner_reveal: DotWinnerReveal = null
## The server's `mp_killcam_time`; -1 until it has said, so the config's number stands.
var _killcam_sec: float = -1.0
var _round_ending: bool = false
var _round_end_winner: int = 0
var _round_end_number: int = 0
var _round_board_open: bool = false
var _hud_was_visible: bool = true

## When this client started, for an offline board's "time".
var _started_msec: int = Time.get_ticks_msec()

var _offline: bool = true
var _sampler: DotFpsSampler = null

## The spectator's free camera while roaming, and the mouse motion not yet turned into a look.
var _free_cam: DotSpectatorFreeCam = null
var _roam_look: Vector2 = Vector2.ZERO

## The tunables the settings' look is bound to offline. See [method _follow_look].
var _look_tunables: DotFpsTunables = null

## Which session this client is, once the server has said. -1 until then, so nothing matches
## before it does.
var _watch_id: int = -1

## The camera rig, in third person. Null in first.
var _arm: DotCameraBoom = null
var _fade: DotCameraFade = null

## How far above the player's feet the camera, or in third person the arm, is hung.
var _rig_height: float = 0.0

## Held buttons, read once a tick rather than sampled from an event queue.
var _firing: bool = false
var _alt: bool = false
var _reloading: bool = false
var _slot: int = 0



## Where the dead lie: dot-player-char's ragdolls under the game's (the server's) rules.
var ragdolls: DotPlayerRagdolls = null


## Seconds the drawn gun must be quiet before the server's count may overwrite it: longer than a
## shot's trip to the server and its snapshot back, so no shot still in flight is undone.
const DRAWN_SETTLE_SEC := 0.6

## Simulated seconds the drawn gun has gone without a trigger, a reload or a switch.
var _drawn_quiet: float = 0.0
