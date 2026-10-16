#!/usr/bin/env python3
"""Generates the Minecraft warden model (mobs_mc_warden.glb): the model
parts of Minecraft's WardenModel.createBodyLayer (Java Edition 26.3) with
their pivots and hierarchy, one bone per model part. The engine poses the
bones ("minecraft_warden" procedural animation), so the file has no
animation.

Mesh buffers (= texture slots), each a copy of the geometry of some parts,
like the model layers of WardenRenderer:
 1 base (all parts)                      mobs_mc_warden.png
 2 bioluminescent (head, arms, legs)     mobs_mc_warden_bioluminescent_layer.png
 3 pulsating spots 1 (body, head, arms, legs) mobs_mc_warden_pulsating_spots_1.png
 4 pulsating spots 2 (same parts)        mobs_mc_warden_pulsating_spots_2.png
 5 tendrils (both tendrils)              mobs_mc_warden.png
 6 heart (body)                          mobs_mc_warden_heart.png
All textures are 128x128 with Minecraft's box UV mapping.

Coordinates: Minecraft model space is in pixels, +Y down, the front facing -Z.
Luanti object space is left handed, +Y up, the front facing +Z, and the
model's 1.501 block offset (LivingEntityRenderer) is baked in (10 units per
node). glTF is right handed, so its Z is negated. Cubes of zero thickness
(ribcage, tendrils) keep only their two opposite faces, which makes them
double sided like Minecraft draws them.

usage: mc_warden_model.py <output dir>
"""
import json, math, os, struct, sys

SCALE = 10 / 16          # mesh units per model pixel
Y_OFFSET = 1.501 * 16    # model pixels from the model origin to the feet
TEX = (128, 128)

# Parts: name -> (parent, pivot offset, cubes [(uv, origin, size, mirror)])
PARTS = {
	"bone": (None, (0, 24, 0), []),
	"body": ("bone", (0, -21, 0), [((0, 0), (-9, -13, -4), (18, 21, 11), False)]),
	"right_ribcage": ("body", (-7, -2, -4), [((90, 11), (-2, -11, -0.1), (9, 21, 0), False)]),
	"left_ribcage": ("body", (7, -2, -4), [((90, 11), (-7, -11, -0.1), (9, 21, 0), True)]),
	"head": ("body", (0, -13, 0), [((0, 32), (-8, -16, -5), (16, 16, 10), False)]),
	"right_tendril": ("head", (-8, -12, 0), [((52, 32), (-16, -13, 0), (16, 16, 0), False)]),
	"left_tendril": ("head", (8, -12, 0), [((58, 0), (0, -13, 0), (16, 16, 0), False)]),
	"right_arm": ("body", (-13, -13, 1), [((44, 50), (-4, 0, -4), (8, 28, 8), False)]),
	"left_arm": ("body", (13, -13, 1), [((0, 58), (-4, 0, -4), (8, 28, 8), False)]),
	"right_leg": ("bone", (-5.9, -13, 0), [((76, 48), (-3.1, 0, -3), (6, 13, 6), False)]),
	"left_leg": ("bone", (5.9, -13, 0), [((76, 76), (-2.9, 0, -3), (6, 13, 6), False)]),
}

LIMBS = ["head", "left_arm", "right_arm", "left_leg", "right_leg"]
LAYERS = [
	("mobs_mc_warden.png", list(PARTS)),
	("mobs_mc_warden_bioluminescent_layer.png", LIMBS),
	("mobs_mc_warden_pulsating_spots_1.png", ["body"] + LIMBS),
	("mobs_mc_warden_pulsating_spots_2.png", ["body"] + LIMBS),
	("mobs_mc_warden.png", ["left_tendril", "right_tendril"]),
	("mobs_mc_warden_heart.png", ["body"]),
]

def global_pivot(name):
	parent, off, _ = PARTS[name]
	if parent is None:
		return off
	p = global_pivot(parent)
	return (p[0] + off[0], p[1] + off[1], p[2] + off[2])

def to_luanti(x, y, z):
	return (-x * SCALE, (Y_OFFSET - y) * SCALE, -z * SCALE)

def to_gltf(p):
	return (p[0], p[1], -p[2])

DIRS = {"DOWN": (0, -1, 0), "UP": (0, 1, 0), "WEST": (-1, 0, 0),
	"NORTH": (0, 0, -1), "EAST": (1, 0, 0), "SOUTH": (0, 0, 1)}

def cube_polygons(uv, origin, size, mirror):
	"""ModelPart.Cube (26.3): [(4 vertices, 4 uvs, normal)], vertices in
	model pixels relative to the part's pivot, normals in model space."""
	xo, yo = uv
	min_x, min_y, min_z = origin
	w, h, d = size
	max_x, max_y, max_z = min_x + w, min_y + h, min_z + d
	if mirror:
		min_x, max_x = max_x, min_x
	t0 = (min_x, min_y, min_z); t1 = (max_x, min_y, min_z)
	t2 = (max_x, max_y, min_z); t3 = (min_x, max_y, min_z)
	l0 = (min_x, min_y, max_z); l1 = (max_x, min_y, max_z)
	l2 = (max_x, max_y, max_z); l3 = (min_x, max_y, max_z)
	u0 = xo; u1 = xo + d; u2 = xo + d + w; u22 = xo + d + w + w
	u3 = xo + d + w + d; u4 = xo + d + w + d + w
	v0 = yo; v1 = yo + d; v2 = yo + d + h
	tw, th = TEX
	def polygon(verts, a0, b0, a1, b1, facing):
		# ModelPart.Polygon: vertex 0 at (u1, v0), 1 at (u0, v0), 2 at (u0, v1), 3 at (u1, v1)
		uvs = [(a1 / tw, b0 / th), (a0 / tw, b0 / th), (a0 / tw, b1 / th), (a1 / tw, b1 / th)]
		if mirror:
			verts = verts[::-1]
			uvs = uvs[::-1]
			if facing in ("WEST", "EAST"):
				facing = "EAST" if facing == "WEST" else "WEST"
		return (verts, uvs, DIRS[facing])
	return [
		polygon([l1, l0, t0, t1], u1, v0, u2, v1, "DOWN"),
		polygon([t2, t3, l3, l2], u2, v1, u22, v0, "UP"),
		polygon([t0, l0, l3, t3], u0, v1, u1, v2, "WEST"),
		polygon([t1, t0, t3, t2], u1, v1, u2, v2, "NORTH"),
		polygon([l1, t1, t2, l2], u2, v1, u3, v2, "EAST"),
		polygon([l0, l1, l2, l3], u3, v1, u4, v2, "SOUTH"),
	]

def sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def dot(a, b): return sum(a[i] * b[i] for i in range(3))

def build():
	names = list(PARTS)
	prims = []
	for tex, parts in LAYERS:
		pos, nrm, uvs, jnt, idx = [], [], [], [], []
		for name in names:
			if name not in parts:
				continue
			pivot = global_pivot(name)
			ji = names.index(name)
			for uv, origin, size, mirror in PARTS[name][2]:
				for verts, quv, n in cube_polygons(uv, origin, size, mirror):
					mv = [(p[0] + pivot[0], p[1] + pivot[1], p[2] + pivot[2]) for p in verts]
					gv = [to_gltf(to_luanti(*p)) for p in mv]
					c = cross(sub(gv[1], gv[0]), sub(gv[2], gv[0]))
					if dot(c, c) < 1e-12:
						continue # zero area (sides of flat cubes)
					# Model space normal -> Luanti (the mapping is -I) -> glTF
					gn = to_gltf((-n[0], -n[1], -n[2]))
					# Front face winding (counter-clockwise in glTF)
					order = [0, 1, 2, 3] if dot(c, gn) > 0 else [0, 3, 2, 1]
					base = len(pos)
					for k in order:
						pos.append(gv[k]); nrm.append(gn); uvs.append(quv[k]); jnt.append(ji)
					idx += [base, base + 1, base + 2, base, base + 2, base + 3]
		prims.append((pos, nrm, uvs, jnt, idx))

	blob = bytearray()
	views, accessors = [], []
	def add(data, comp, typ, count, target=None, minmax=None):
		while len(blob) % 4:
			blob.append(0)
		off = len(blob)
		blob.extend(data)
		view = {"buffer": 0, "byteOffset": off, "byteLength": len(data)}
		if target:
			view["target"] = target
		views.append(view)
		acc = {"bufferView": len(views) - 1, "componentType": comp, "count": count, "type": typ}
		if minmax:
			acc["min"], acc["max"] = minmax
		accessors.append(acc)
		return len(accessors) - 1

	mesh_prims = []
	for slot, (pos, nrm, uvs, jnt, idx) in enumerate(prims):
		mn = [min(p[i] for p in pos) for i in range(3)]
		mx = [max(p[i] for p in pos) for i in range(3)]
		a_pos = add(b"".join(struct.pack("<3f", *p) for p in pos), 5126, "VEC3", len(pos), 34962, (mn, mx))
		a_nrm = add(b"".join(struct.pack("<3f", *p) for p in nrm), 5126, "VEC3", len(nrm), 34962)
		a_uv = add(b"".join(struct.pack("<2f", *p) for p in uvs), 5126, "VEC2", len(uvs), 34962)
		a_j = add(b"".join(struct.pack("<4B", j, 0, 0, 0) for j in jnt), 5121, "VEC4", len(jnt), 34962)
		a_w = add(b"".join(struct.pack("<4f", 1, 0, 0, 0) for _ in jnt), 5126, "VEC4", len(jnt), 34962)
		a_i = add(b"".join(struct.pack("<H", i) for i in idx), 5123, "SCALAR", len(idx), 34963)
		mesh_prims.append({
			"attributes": {"POSITION": a_pos, "NORMAL": a_nrm, "TEXCOORD_0": a_uv,
				"JOINTS_0": a_j, "WEIGHTS_0": a_w},
			"indices": a_i, "material": slot,
		})

	# Nodes: 0 root, 1 mesh, 2.. the parts with Minecraft's hierarchy.
	# Rest translations: the pivot offsets; inverse bind = minus the global pivot.
	J = 2
	nodes = [{"name": "Warden", "children": [J + names.index("bone")]},
		{"name": "Mesh", "mesh": 0, "skin": 0}]
	ibm = bytearray()
	for name in names:
		parent, off, _ = PARTS[name]
		if parent is None:
			t = to_gltf(to_luanti(*off))
		else:
			t = to_gltf((-off[0] * SCALE, -off[1] * SCALE, -off[2] * SCALE))
		node = {"name": name, "translation": list(t)}
		children = [J + names.index(n) for n in names if PARTS[n][0] == name]
		if children:
			node["children"] = children
		nodes.append(node)
		g = to_gltf(to_luanti(*global_pivot(name)))
		m = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -g[0], -g[1], -g[2], 1]
		ibm.extend(struct.pack("<16f", *m))
	a_ibm = add(bytes(ibm), 5126, "MAT4", len(names))

	gltf = {
		"asset": {"version": "2.0", "generator": "mc_warden_model.py"},
		"scene": 0,
		"scenes": [{"nodes": [0, 1]}],
		"nodes": nodes,
		"meshes": [{"name": "Warden", "primitives": mesh_prims}],
		"skins": [{"joints": [J + i for i in range(len(names))], "inverseBindMatrices": a_ibm}],
		"materials": [{"name": "layer%d" % i, "pbrMetallicRoughness": {"baseColorTexture": {"index": i}}}
			for i in range(len(LAYERS))],
		"textures": [{"source": i, "sampler": 0} for i in range(len(LAYERS))],
		"samplers": [{"magFilter": 9728, "minFilter": 9728, "wrapS": 33071, "wrapT": 33071}],
		"images": [{"uri": tex} for tex, _ in LAYERS],
		"accessors": accessors,
		"bufferViews": views,
		"buffers": [{"byteLength": len(blob)}],
	}
	return gltf, bytes(blob)

def write_glb(path, gltf, blob):
	js = json.dumps(gltf, separators=(",", ":")).encode()
	js += b" " * ((4 - len(js) % 4) % 4)
	bl = blob + b"\0" * ((4 - len(blob) % 4) % 4)
	total = 12 + 8 + len(js) + 8 + len(bl)
	with open(path, "wb") as f:
		f.write(struct.pack("<4sII", b"glTF", 2, total))
		f.write(struct.pack("<I4s", len(js), b"JSON")); f.write(js)
		f.write(struct.pack("<I4s", len(bl), b"BIN\0")); f.write(bl)

if __name__ == "__main__":
	out = sys.argv[1]
	gltf, blob = build()
	write_glb(os.path.join(out, "mobs_mc_warden.glb"), gltf, blob)
