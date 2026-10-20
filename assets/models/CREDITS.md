# Models

`copter_body.glb` is the chopper's fuselage, built by `art-src/build_copter.py` (run with Blender in background mode).

- **Base**: `craft_cargoB` from Kenney's Space Kit ([kenney.nl](https://kenney.nl), CC0 1.0; licence in `LICENSE-kenney-space-kit.txt`, source copy in `art-src/craft_cargoB.glb`).
- **Changes**: the pod is stretched to the 2.2 x 1.8 x 5.0 m hull the collider uses and turned round, then a glass canopy, engine cowl, rotor mast and hub, tail boom with a stripe, fin, tail-rotor hub, skids, struts and skid toes are modelled onto it and joined into one mesh with four flat materials. The rotors are not in the file: `props/sc_copter_body.gd` spins them as code nodes.
