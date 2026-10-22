# The netcode

`game/net/` and `game/sc_module.gd` (over dot-game's `DotGameModule`). `ScNetBridge` is the only file that names both halves.

## Who is authoritative

**A player's own feet are the only predicted thing.** Platforms, props and choppers are server-authoritative, and so is a pilot: a chopper's mirror is owner 0 on every client, and `ScPlayerNet` applies a rider's command without simulating the controller.

- **The local mirror is owned through `_mirror_owner(session_id)`** (and `_claim_local_player` for one that arrived before HELLO), the same fix as mg-buses-from-hell's: `is_owner` compares against this registry's own local peer, so the local peer id is the only right value, and the wire does not change. With owner 0 the client predicts nothing and still "agrees with the server"; see [testing.md](testing.md#assert-the-mechanism-not-the-symptom).
- **A predicted player on a floor that moves is corrected now and then by a centimetre.** The client draws the lean from snapshots it runs `INPUT_LEAD` ticks ahead of, so running across a platform leaning under you is corrected on about a fifth of snapshots, worst around 2 cm, no snaps. That is the floor being the server's, as it must be, and under what a player can see.

## What crosses

- **A platform replicates in four numbers, and the state is not interpolated.** Between two snapshots the lean should be between two leans; a platform that has come off its pillar takes its collider away on the tick the client is told, not smoothly. Half way between standing and gone is not a thing a floor can be.
- **The snapshot rate is 30** (`ScGame.NET_SNAPSHOT_RATE`), against buses' 20: the lean of the floor under you arrives only in a snapshot, and at 20 it updates in visible steps that read as stutter.
- **The layout's cell list** travels once a round ([design.md](design.md#the-map-is-a-description-not-a-build)).
- **The clock carries what a client cannot count**: platforms still up, because a client runs no platform model.
- **Weapons replicate as a counter, never an event per shot.** An RPC per shot needs a reliable channel for something worthless late, costs a packet per shot per watcher, and desynchronises from state (a flash from a weapon the same snapshot says is holstered). A four-bit counter in the snapshot plays one flash for a missed two, the correct amount of wrong. The magazine and reserve are **owner-only**: exact ammunition is information an opponent should not have. `net_fire_kind` (three bits) says what kind of use.
- **What a watcher's figure holds** is the slot the snapshot says is out, looked up among the weapons the server announced it dealt (`ARMED`, one event per weapon, selected first; `ScPlayer.dealt`, reset when a deal arrives for a new round). A slot alone names no weapon, since the pack puts several in each. No wire change: the event that existed, sent more than once.
- **Landings are an event (`IMPACT`)**; a client's props are frozen mirrors and it cannot see one land.
- **Spectating** is one `SPECTATE` event per view change to that player's peer alone, carrying the death position in this game's own bit-packed, session-keyed event ([client.md](client.md#being-out)). A step or the camera key is `Ask.SPECTATE`, answered from the server's `targets_for`, and the free-roam key is `Ask.ROAM` (the view then carries ROAMING); a refusal comes back as a notice.
- **Who somebody is** travels in JOIN after the side, as JSON capped at 1 KB (empty or unparseable is the stock person, never a refused join). A JOIN for a player the client has is "who they are now": `ScNetBridge.refresh_player`, on `player_admitted`, `player_renamed` and `player_avatar_changed`.
- **`net_blind` is owner-only**, like the magazine; `net_beacon` goes to everybody. There is no relevance change for a beacon (every player is already always relevant, and clearing a flag must not take a player out of snapshots).

## Two builds on one wire

`headless_net` registers, on each end, an optional message type the other has never heard of before the seal, and every later section plays over that: the tables cross at join, each end skips the other's newer message, and a client missing a required type (or requiring one the server lacks) is refused with dot-net's sentence. This game's two types are required; anything newer can be optional, so a published pack's server half talks to a client built from a different dot-net.

## Lag compensation and combat

- The world builds dot-combat with lag compensation OFF, and `ScNetBridge` turns it on in the same breath as it wires the rewind and restore callables (dot-net already records history). Otherwise dot-combat warns "unwired" at boot on a server where it works, or reports it on with nothing behind it. The shooter is not excluded from the rewind, because `resolve_shot` fixes the origin before it rewinds.
- Players need a `DotHitboxSet` and `combat.trace` set; a trace that finds nothing is a legitimate answer, so a missing one is silent.
- `DotCombatManager._ready` calls `setup()`; do not call it again after `add_child`.
- `ScPlayer.component()` is the seam `DotWeaponPlayerBridge` looks up; without it the bridge falls back to the body transform (yaw lives in the controller's state, not the node), and every shot pointed north.
- **Lag-compensation tracks**: a round begins inside `server_tick`, which records history for the identity list it took before the old field went, re-creating a track per forgotten platform. The bridge forgets them again once the manager's tick returns; `dedicated` counts orphaned tracks and asserts the engine reports no error.

## Freed bodies

A disconnect mid-round frees bodies under the bridge; `_apply_prop_gone` and `_forget_platforms` check `is_instance_valid` before casting. The field's own freeing rules are in [platforms.md](platforms.md#freeing-the-field).

## Messages: never preload yourself

**A script that `extends DotNetMessage` and preloads its own file leaks the whole script graph at exit** on a deployed server (measured by mg-buses-from-hell; see its [history](../../mg-buses-from-hell/docs/history.md#the-leak-that-was-one-line-of-a-message)). `sc_event.gd` and `sc_request.gd` are built with `new(kind, body)`, an `_init` whose arguments default, because dot-net's registry decodes with a bare `new()`. `dedicated`'s "exiting clean" reads every `DotNetMessage` script under `game/` as text and fails on a self-preload: the leak is printed after `quit()`, where no assertion can reach.

## The module

`sc_module.gd` subclasses `DotGameModule`; `sc_services.gd` subclasses `DotGameServices`. The identity layer is dot-platform's `DotPlatformIdentity` over `ScAvatars.schema()`, built before the services, with dot-platform's module loaded beside it; authentication stays the host's `dot_auth_server`. Ask the platform through its module's `player_for(session)`, never the hub by `"u%d"`, which finds nobody and falls through to stock silently.
