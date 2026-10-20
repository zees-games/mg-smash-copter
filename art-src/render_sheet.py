"""Contact sheet of assets/models/copter_body.glb: front, side, three-quarter and top, of the fuselage.

Run on a box with Cycles on a GPU:
  blender -b -P art-src/render_sheet.py -- <glb> <out_prefix>
Blender axes: the glb's -Z (forward) arrives as +Y.
"""
import bpy, sys
from mathutils import Vector

glb, prefix = sys.argv[-2], sys.argv[-1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=glb)

# The collider box and rotor disc are not drawn: a Cycles render shows wire objects solid.

sc = bpy.context.scene
sc.render.engine = "CYCLES"
prefs = bpy.context.preferences.addons["cycles"].preferences
prefs.compute_device_type = "CUDA"
prefs.get_devices()
for d in prefs.devices:
    d.use = True
sc.cycles.device = "GPU"
sc.cycles.samples = 96
sc.render.resolution_x = 640
sc.render.resolution_y = 420
w = bpy.data.worlds.new("w")
w.use_nodes = True
w.node_tree.nodes["Background"].inputs[0].default_value = (0.55, 0.7, 0.9, 1)
sc.world = w
bpy.ops.object.light_add(type="SUN", rotation=(0.8, 0.3, 0.6))
bpy.context.active_object.data.energy = 4

views = {
    "front": (0, 11, 1.0),
    "side": (11, 0, 0.8),
    "threequarter": (8, 8, 4.5),
    "rear": (-6, -9, 3.5),
    "top": (0.01, 0.01, 12),
}
for name, loc in views.items():
    bpy.ops.object.camera_add(location=loc)
    cam = bpy.context.active_object
    cam.rotation_euler = (Vector((0, -0.6, 0.3)) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
    sc.camera = cam
    sc.render.filepath = "%s_%s.png" % (prefix, name)
    bpy.ops.render.render(write_still=True)
