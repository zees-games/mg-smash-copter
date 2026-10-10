# Pack delivery: what a delivered game may not do

This game is delivered as a signed dot-cloud pack and was the first verified by a real client on a real socket against a delivered pack (dot-server-deploy's `examples/smash_client.tscn`). Three suites and every render passed on a game that would not run mounted; publishing, booting a server, rendering the delivered map and running stand-ins for twenty rounds found what is below. The family view is dot-cloud's [mounting](../../dot-cloud/docs/mounting.md) and [publishing](../../dot-cloud/docs/publishing.md); mg-buses-from-hell's [delivery.md](../../mg-buses-from-hell/docs/delivery.md) has the sixth form (an imported model's own texture dependency).

## No `class_name`, anywhere in this repository

**A mounted pack's `class_name` globals are not registered in the host**, so a delivered game using one mounts, loads its scenes, and has every script dead with nothing reporting it. Every script is reached by a relative `preload` and every subclass by a relative `extends`. `dot-server-deploy/tools/check.sh` refuses a new one in any game repository.

## Every `res://` path goes through `ScPaths.rebase()`, where it is DEFINED

`static var CRATE_SCENE := ScPaths.rebase("res://…")`, never a `const` wrapped at each call site: the second is one new call site away from a prop that does not spawn in a delivered round, and `check.sh` cannot follow a `const` to its uses. `headless_run`'s delivery section scans every shipped script for a bare `"res://…"` naming one of this game's directories and fails naming the line.

## The seventh form: a path already rewritten, rebased again

`ScPropBody` loads its model from an exported `model_path`. **The publisher rewrites every `res://` string inside a `.tscn`, `.tres` and `.import` onto the mount prefix, and none inside a `.gd`.** So the exported value arrives absolute, and `rebase()` prefixed it again: `res://dot_cloud/tmc/smash/0.1.0/dot_cloud/tmc/smash/0.1.0/assets/kenney/car/debris-tire.glb`, long enough that the doubling reads as noise. It is the second and third forms (scene paths, script strings) meeting, and only exists because both are closed. **`rebase()` returns a path already under the root unchanged.**

**And the check for it passed with the bug put back.** Built in, `root()` is `res://` and every `res://` path is under it, so every property of `rebase()` that matters in a pack is a tautology: the idempotence was asserted, the fix reverted, and the suite stayed green. `ScPaths.rebase_onto(path, root)` exists so the suite can hand it a real mount prefix, and `rebase()` is one line over it. **Arming a guard means checking it fails**; this is why that rule is in the family's notes.

## Models are loaded by PATH, not instanced as `ext_resource`

A `.tscn` records an external resource as an absolute path plus a UID, and inside a mounted pack neither resolved (mg-buses-from-hell shipped a round where every crate's mesh loaded and its texture did not). `ScPropBody` loads through `rebase()` and puts the atlas on by hand where one is missing, which in a build does nothing. **The two Kenney kits' `Textures/colormap.png` are different files with the same name**, so each kit has its own folder; flattening them paints the survival props in the car kit's palette.

## The weapon pack's art is named by the addon

`ZeeWeaponArtTable` and `ZeeViewArms` say `res://assets/…`, which inside a mount is the host's root: every gun and the arms load invisible, one WARN each. `ScClient._ready` calls `ZeeModelCache.set_asset_root(ScPaths.root())` and `_exit_tree` puts `res://` back, because the static outlives this game in a shell that loads the next. A pack using a newer addon API than the client shell was built with fails to parse; rebuild the shell before publishing a pack that needs it.

## Project settings do not travel

- **Gravity**: `physics/3d/default_gravity` is left at 9.8 here, and `ScConfig.gravity` is the number the game is tuned against. `ScGame._apply_gravity` writes it onto the world's own physics SPACE, not the global setting, because a server and a client in one process are two worlds. It also makes the low-gravity special one line.
- **The renderer**: the client shell renders with `gl_compatibility` (the browser is its target), and so does this project; lighting is tuned by rendering under it.

## Importing before packing

`dot-server-deploy`'s pack step needs this project imported first (`godot --headless --path ../mg-smash-copter --import`): a pack cannot import itself.
