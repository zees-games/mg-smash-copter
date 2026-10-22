# mg-smash-copter docs

One subject per file. [CLAUDE.md](../CLAUDE.md) has the rules in one line each; these have the reasoning.

| File | What it covers |
| --- | --- |
| [design.md](design.md) | what the game is and its decisions: platforms not rigid bodies, shift is a brake, the cannon's tiers and aim, the map as a description, no dot-spawn, the showdown elsewhere, the chopper chassis, what a level is, teams and friendly fire, the layout vote |
| [platforms.md](platforms.md) | the platform model, integration, the normal's sign, load gain, slopes, bridges resting on lips, falls (`FLOOR_REACH`, the `pillar` layer), freeing the field, readability |
| [map.md](map.md) | layouts, jump reach both ways, islands, the throat, the layouts rebuilt to their blurbs, the showdown complex (ring cover, flanks, dais, catwalks, kerbs) |
| [netcode.md](netcode.md) | authority and prediction, what crosses (platforms, layout, clock, weapon counter, dealt weapons, spectating, identity), two builds on one wire, lag compensation and combat wiring, freed bodies, self-preloading messages, the module |
| [client.md](client.md) | the camera, being out, sound, figures and a gun in somebody's hand, HUD and admin overlays, settings |
| [services.md](services.md) | moderation tools and refusals, progress and achievements, identity and admission |
| [delivery.md](delivery.md) | the pack: no `class_name`, `rebase` at definition, the seventh form and `rebase_onto`, models by path, the weapon pack's asset root, gravity and renderer, import before packing |
| [bots.md](bots.md) | the stand-ins: dot-bot's aim and `bot_difficulty`, the `sc_bot_*` cvars, the showdown route round the cover, the trigger per weapon, measured presets |
| [soak.md](soak.md) | the bot soak: `./game.sh soak`, what it judges, the first run's findings |
| [testing.md](testing.md) | the three suites, their rules, asserting the mechanism, renders and the audio probe, the deployment check |
| [history.md](history.md) | bug narratives worth recognising again |
