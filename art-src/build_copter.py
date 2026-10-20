"""Builds assets/models/copter_body.glb for mg-smash-copter.

Run:  blender -b -P art-src/build_copter.py -- [--render out.png]
Base: Kenney Space Kit craft_cargoB.glb (CC0, art-src/craft_cargoB.glb). Changes: the pod is
stretched to the 2.2 x 1.8 x 5.0 m hull the collider uses and its roof lifted into a cabin,
then a canopy, tail boom, fin, tail-rotor hub, rotor mast and hub, skids and struts, an
engine cowl and a stripe are modelled onto it. The rotors themselves are NOT in the file:
sc_copter_body.gd keeps them as code nodes ("Rotor", "TailRotor") because it spins them.
Blender axes: +Y is the nose (exports as Godot -Z), +Z up.
"""
import bpy, bmesh, sys, os
from mathutils import Vector

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "..", "assets", "models", "copter_body.glb")
render = sys.argv[sys.argv.index("--render") + 1] if "--render" in sys.argv else None

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=os.path.join(here, "craft_cargoB.glb"))
base = next(o for o in bpy.data.objects if o.type == "MESH")
for o in list(bpy.data.objects):
    if o.type == "EMPTY":
        o.select_set(True)
bpy.ops.object.select_all(action="DESELECT")
base.parent = None
base.matrix_world.identity()
base.name = "Hull"

# Stretch the pod to the hull box (2.2 x 5.0 x 1.8), centred.
bpy.context.view_layer.objects.active = base
bbmin = Vector([min(v.co[i] for v in base.data.vertices) for i in range(3)])
bbmax = Vector([max(v.co[i] for v in base.data.vertices) for i in range(3)])
size = bbmax - bbmin
ctr = (bbmax + bbmin) / 2
for v in base.data.vertices:
    c = v.co - ctr
    v.co = Vector((-c.x * 2.2 / size.x, -c.y * 5.0 / size.y, c.z * 1.8 / size.z))  # turned round: its thrusters face aft
base.data.update()

def mat(name, rgba, metal=0.0, rough=0.5):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    b.inputs["Base Color"].default_value = rgba
    b.inputs["Metallic"].default_value = metal
    b.inputs["Roughness"].default_value = rough
    return m

PAINT = mat("CopterPaint", (0.82, 0.16, 0.10, 1), 0.1, 0.45)
DARK = mat("CopterDark", (0.08, 0.09, 0.10, 1), 0.3, 0.6)
GLASS = mat("CopterGlass", (0.35, 0.6, 0.75, 1), 0.0, 0.1)
STRIPE = mat("CopterStripe", (0.95, 0.8, 0.1, 1), 0.0, 0.5)

def part(name, prim, loc, scale, m, rot=(0, 0, 0), **kw):
    if prim == "cube":
        bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot)
    elif prim == "cyl":
        bpy.ops.mesh.primitive_cylinder_add(vertices=12, radius=0.5, depth=1, location=loc, rotation=rot)
    elif prim == "sphere":
        bpy.ops.mesh.primitive_uv_sphere_add(segments=14, ring_count=8, radius=0.5, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.name = name
    o.scale = scale
    bpy.ops.object.transform_apply(scale=True, rotation=True)
    o.data.materials.append(m)
    bpy.ops.object.shade_smooth() if prim != "cube" else None
    return o

# Canopy over the nose (glass), engine cowl behind the mast, tail boom and fin.
part("Canopy", "sphere", (0, 1.55, 0.25), (1.9, 2.1, 1.3), GLASS)
part("Cowl", "cube", (0, -0.5, 1.0), (1.3, 1.9, 0.6), PAINT)
part("Mast", "cyl", (0, 0, 1.5), (0.32, 0.32, 0.5), DARK)
part("RotorHub", "cyl", (0, 0, 1.78), (0.55, 0.55, 0.14), DARK)
part("Boom", "cube", (0, -3.6, 0.35), (0.5, 3.0, 0.5), PAINT)
part("Fin", "cube", (0, -4.9, 1.05), (0.18, 0.9, 1.2), PAINT)
part("TailHub", "cyl", (0.14, -4.9, 1.05), (0.2, 0.2, 0.26), DARK, rot=(0, 1.5708, 0))
part("Stripe", "cube", (0, -3.6, 0.35), (0.52, 2.2, 0.12), STRIPE)
for s, n in ((-1, "L"), (1, "R")):
    # Closes the open Kenney pod box on each side of the nose (it showed a dark hole from the front).
    part("PodCap" + n, "cube", (s * 0.78, 2.5, -0.28), (0.7, 0.14, 1.12), PAINT)
    part("Skid" + n, "cube", (s * 0.95, 0, -1.15), (0.28, 4.0, 0.26), DARK)
    # Two stout struts a side (fore and aft), not one thin one.
    for k, sy in (("F", 1.0), ("A", -1.0)):
        part("Strut" + n + k, "cube", (s * 0.82, sy, -0.62), (0.3, 0.3, 0.9), DARK)
    part("SkidToe" + n, "cube", (s * 0.95, 2.0, -1.05), (0.28, 0.4, 0.26), DARK, rot=(0.6, 0, 0))

bpy.ops.object.select_all(action="DESELECT")
for o in bpy.data.objects:
    if o.type == "MESH":
        o.select_set(True)
bpy.context.view_layer.objects.active = base
bpy.ops.object.join()
bpy.context.active_object.name = "CopterBody"
os.makedirs(os.path.dirname(out), exist_ok=True)
bpy.ops.export_scene.gltf(filepath=out, export_format="GLB", use_selection=True, export_yup=True)
print("wrote", out)

if render:
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.samples = 12
    sc.cycles.use_denoising = False
    sc.cycles.device = "CPU"
    sc.render.resolution_x = 640
    sc.render.resolution_y = 420
    w = bpy.data.worlds.new("w"); w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.5, 0.65, 0.85, 1)
    sc.world = w
    bpy.ops.object.light_add(type="SUN", rotation=(0.8, 0.3, 0.6))
    bpy.context.active_object.data.energy = 4
    for i, loc in enumerate(((7, 7, 3.5), (-7, 5, 2), (0, 9, 1.0))):
        bpy.ops.object.camera_add(location=loc)
        cam = bpy.context.active_object
        cam.rotation_euler = (Vector((0, 0, 0.3)) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
        sc.camera = cam
        sc.render.filepath = render.replace(".png", "_%d.png" % i)
        bpy.ops.render.render(write_still=True)
