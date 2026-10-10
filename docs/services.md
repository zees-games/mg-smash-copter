# Services: moderation, progression, identity

## The moderator's live tools, and what a floor game refuses

`ScServices` answers dot-game's `_mod_abilities` with noclip, freeze, speed and gravity (predicted modifiers, so a player an admin moves does not rubber-band), god, buddha, hp, slay and slap as ordinary damage, rename, blind, beacon, and teleports that go through `ScPlayer.place_at`, the one way to move a player here that also moves the tick the client draws from. `@team:<n>` is the side.

Refused, with the reason `modtools` prints: **respawn** (falling is how a round is lost, and putting a faller back decides it); **give** and **strip** (weapons are dealt at the handover, one each at random, and that draw is the second half's fairness). Anything that moves a body is refused while they fly the chopper. A round start is everybody's new body: it ends noclip and freeze and keeps god. Blind and beacon persist across a round (`ScServices.PERSIST_ON_RESPAWN`); `blind <p> <seconds>` is dot-moderation's timed toggle. What they draw is in [client.md](client.md#hud-admin-overlays-chat).

## What a player keeps

`ScProgress` declares ten numbers once: rounds played, survived (up when the clock ran out), won, showdowns won (your side won and you were standing), showdown kills, best showdown (a BEST), deaths, falls, platforms tipped (a collapse by LEAN with you on it: somebody's doing, not the cannon's), and props dodged (a landing on your platform that only leaned it and missed you by more than the hurt radius). Eight achievements are rules over them through `DotAchievementStatsLink`, the differencer between a session and a lifetime (wiring `recorded` into `record` would add the running total on every reading). Two are secret, because they are earned by the mistake the game is about.

- **Stand-ins are never counted**: an empty server is full of them. **A player is begun on their first number, not on join**, because a world adds a player before the bridge or client marks them a stand-in.
- **Authoritative worlds only**: a server, and an offline client (which says what was earned in the chat box). On a server an unlock is a notice to that one peer.
- **Memory by default** (`progress_directory`), dot-achievements' own default: a server that silently starts writing a file per player is noticed when the disk is full. **Reporting is off** (`report_progress`): it needs an integration credential this game does not configure.
- **Keys**: the player's scoped profile key when they have one, `u<session>` otherwise (a guest, a stand-in, a server with no platform). `ScProgress.durable_key_fn` is asked once, when counting begins (lazily, so nearly always after admission), and fixed for the session; `_key` is the only place a world id becomes a filing key.

## Who somebody is

dot-platform's identity layer ([netcode.md](netcode.md#the-module)). The game gains a scoped profile, a name, a face, and numbers that outlive a connection.

- **Admission finishes after seating**, and that is the case it is built for: dot-server has no stage between authentication and content, so a player is seated with a guest's name and the stock face whenever the profile store is slower than the join. dot-platform notifies `player_admitted` and `player_renamed`; the module hooks those and `player_avatar_changed` into one `refresh_player`.
- dot-platform resolves a first-time player to the same stock function over their scoped key (dot-user-avatar's `default_avatar_fn`), so a person has one face on every visit.
- **A guest keeps the stock face**: dot-user keeps no profile for a guest by default. A signed-in player's name is the site's: `platform_name` on one is refused with the reason.
