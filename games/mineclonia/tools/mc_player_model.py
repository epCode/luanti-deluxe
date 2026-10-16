#!/usr/bin/env python3
"""Generates the Minecraft player models (mcl_player_wide.glb and
mcl_player_slim.glb): the boxes of Minecraft's ModelPlayer (1.8), the armor
models (ModelBiped with inflation 1.0 and 0.5), the cape and the elytra (1.9),
one bone per model part. The engine poses the bones ("minecraft_player"
procedural animation), so the file has no animation.

Texture slots: 1 skin (64x64), 2 armor (helmet, chestplate, boots; 64x32),
3 leggings (64x32), 4 cape (64x32), 5 elytra (64x32).

Coordinates: Minecraft model space is in pixels, +Y down, the front facing -Z.
Luanti object space is left handed, +Y up, the front facing +Z, and the
player's 0.9375 render scale and the model's 1.5078125 block offset are baked
in (10 units per node). glTF is right handed, so its Z is negated.

usage: mc_player_model.py <output dir>
"""
import json, math, os, struct, sys

SCALE = 0.9375 / 16 * 10   # mesh units per model pixel
Y_OFFSET = 1.5078125 * 16  # model pixels from the model origin to the feet

def to_luanti(x, y, z):
	return (-x * SCALE, (Y_OFFSET - y) * SCALE, -z * SCALE)

def to_gltf(p):
	return (p[0], p[1], -p[2])

# Joints: name -> rest pivot in model pixels
def joints_for(slim):
	arm_y = 2.5 if slim else 2.0
	joints = {
		"Head": (0, 0, 0),
		"Body": (0, 0, 0),
		"Arm_Right": (-5, arm_y, 0),
		"Arm_Left": (5, arm_y, 0),
		"Leg_Right": (-1.9, 12, 0),
		"Leg_Left": (1.9, 12, 0),
		# Armor arms keep ModelBiped's pivot height
		"Armor_Arm_Right": (-5, 2, 0),
		"Armor_Arm_Left": (5, 2, 0),
		# Cape and elytra: their layers translate by 2 pixels backwards
		"Cape": (0, 0, 2),
		"Elytra_Left": (5, 0, 2),
		"Elytra_Right": (-5, 0, 2),
		# Item in hand (ModelBiped.postRenderArm + LayerHeldItem), posed by the engine
		"Wield_Item": (-6, arm_y + 7, 1),
		"Wield_Item_Left": (6, arm_y + 7, 1),
	}
	# Marks the slim model for the engine
	if slim:
		joints["Slim_Arms"] = (0, 0, 0)
	return joints

# Parts: (texture slot, joint, uv, box origin, box size, inflation, mirror)
def parts_for(slim):
	p = []
	skin = 0
	# ModelPlayer, 64x64
	p += [
		(skin, "Head", (0, 0), (-4, -8, -4), (8, 8, 8), 0.0, False),
		(skin, "Head", (32, 0), (-4, -8, -4), (8, 8, 8), 0.5, False),
		(skin, "Body", (16, 16), (-4, 0, -2), (8, 12, 4), 0.0, False),
		(skin, "Body", (16, 32), (-4, 0, -2), (8, 12, 4), 0.25, False),
		(skin, "Leg_Right", (0, 16), (-2, 0, -2), (4, 12, 4), 0.0, False),
		(skin, "Leg_Right", (0, 32), (-2, 0, -2), (4, 12, 4), 0.25, False),
		(skin, "Leg_Left", (16, 48), (-2, 0, -2), (4, 12, 4), 0.0, False),
		(skin, "Leg_Left", (0, 48), (-2, 0, -2), (4, 12, 4), 0.25, False),
	]
	if slim:
		p += [
			(skin, "Arm_Right", (40, 16), (-2, -2, -2), (3, 12, 4), 0.0, False),
			(skin, "Arm_Right", (40, 32), (-2, -2, -2), (3, 12, 4), 0.25, False),
			(skin, "Arm_Left", (32, 48), (-1, -2, -2), (3, 12, 4), 0.0, False),
			(skin, "Arm_Left", (48, 48), (-1, -2, -2), (3, 12, 4), 0.25, False),
		]
	else:
		p += [
			(skin, "Arm_Right", (40, 16), (-3, -2, -2), (4, 12, 4), 0.0, False),
			(skin, "Arm_Right", (40, 32), (-3, -2, -2), (4, 12, 4), 0.25, False),
			(skin, "Arm_Left", (32, 48), (-1, -2, -2), (4, 12, 4), 0.0, False),
			(skin, "Arm_Left", (48, 48), (-1, -2, -2), (4, 12, 4), 0.25, False),
		]
	# Armor: ModelBiped(1.0F), 64x32 (LayerBipedArmor.modelArmor)
	armor = 1
	p += [
		# Mineclonia's helmet textures are in the headwear area; Minecraft's
		# helmets (1.8) leave that area empty and draw on the 1.0 box
		(armor, "Head", (32, 0), (-4, -8, -4), (8, 8, 8), 1.0, False),
		(armor, "Body", (16, 16), (-4, 0, -2), (8, 12, 4), 1.0, False),
		(armor, "Armor_Arm_Right", (40, 16), (-3, -2, -2), (4, 12, 4), 1.0, False),
		(armor, "Armor_Arm_Left", (40, 16), (-1, -2, -2), (4, 12, 4), 1.0, True),
		(armor, "Leg_Right", (0, 16), (-2, 0, -2), (4, 12, 4), 1.0, False),
		(armor, "Leg_Left", (0, 16), (-2, 0, -2), (4, 12, 4), 1.0, True),
	]
	# Leggings: ModelBiped(0.5F), only the body and legs are shown
	legs = 2
	p += [
		(legs, "Body", (16, 16), (-4, 0, -2), (8, 12, 4), 0.5, False),
		(legs, "Leg_Right", (0, 16), (-2, 0, -2), (4, 12, 4), 0.5, False),
		(legs, "Leg_Left", (0, 16), (-2, 0, -2), (4, 12, 4), 0.5, True),
	]
	# Cape (ModelPlayer.bipedCape, texture size 64x32)
	p += [(3, "Cape", (0, 0), (-5, 0, -1), (10, 16, 1), 0.0, False)]
	# Elytra (ModelElytra, 1.9)
	p += [
		(4, "Elytra_Left", (22, 0), (-10, 0, 0), (10, 20, 2), 1.0, False),
		(4, "Elytra_Right", (22, 0), (0, 0, 0), (10, 20, 2), 1.0, True),
	]
	return p

TEX_SIZE = [(64, 64), (64, 32), (64, 32), (64, 32), (64, 32)]
TEX_NAMES = ["skin.png", "armor.png", "leggings.png", "cape.png", "elytra.png"]

def box_quads(uv, origin, size, infl, mirror, tex):
	"""Quads of a Minecraft ModelBox: [(4 vertices, 4 uvs)], vertices in
	model pixels relative to the part's pivot."""
	u, v = uv
	x1, y1, z1 = origin
	w, h, d = size
	x2, y2, z2 = x1 + w, y1 + h, z1 + d
	x1 -= infl; y1 -= infl; z1 -= infl
	x2 += infl; y2 += infl; z2 += infl
	if mirror:
		x1, x2 = x2, x1
	v7 = (x1, y1, z1); v0 = (x2, y1, z1); v1 = (x2, y2, z1); v2 = (x1, y2, z1)
	v3 = (x1, y1, z2); v4 = (x2, y1, z2); v5 = (x2, y2, z2); v6 = (x1, y2, z2)
	tw, th = tex
	def quad(verts, a, b, c, e):
		# TexturedQuad: vertex 0 at (c, b), 1 at (a, b), 2 at (a, e), 3 at (c, e)
		uvs = [(c / tw, b / th), (a / tw, b / th), (a / tw, e / th), (c / tw, e / th)]
		if mirror:
			verts = verts[::-1]
			uvs = uvs[::-1]
		return (verts, uvs)
	return [
		quad([v4, v0, v1, v5], u + d + w, v + d, u + d + w + d, v + d + h),
		quad([v7, v3, v6, v2], u, v + d, u + d, v + d + h),
		quad([v4, v3, v7, v0], u + d, v, u + d + w, v + d),
		quad([v1, v2, v6, v5], u + d + w, v + d, u + d + w + w, v),
		quad([v0, v7, v2, v1], u + d, v + d, u + d + w, v + d + h),
		quad([v3, v4, v5, v6], u + d + w + d, v + d, u + d + w + d + w, v + d + h),
	]

def sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def norm(a):
	l = math.sqrt(sum(c * c for c in a)) or 1
	return tuple(c / l for c in a)

def quat_from_euler_zyx(xr, yr, zr):
	"""Quaternion of Rz(zr) * Ry(yr) * Rx(xr) (ModelRenderer order)."""
	def q_axis(ax, ang):
		s = math.sin(ang / 2)
		return (ax[0] * s, ax[1] * s, ax[2] * s, math.cos(ang / 2))
	def mul(a, b):
		ax, ay, az, aw = a; bx, by, bz, bw = b
		return (aw * bx + ax * bw + ay * bz - az * by,
			aw * by - ax * bz + ay * bw + az * bx,
			aw * bz + ax * by - ay * bx + az * bw,
			aw * bw - ax * bx - ay * by - az * bz)
	return mul(mul(q_axis((0, 0, 1), zr), q_axis((0, 1, 0), yr)), q_axis((1, 0, 0), xr))

# Rest rotations (Minecraft model space angles) so that previews without the
# engine animation (formspec model[]) look like a standing player
def rest_rotation(name):
	if name == "Cape":
		return quat_from_euler_zyx(math.radians(-6), math.pi, 0)
	if name == "Elytra_Left":
		return quat_from_euler_zyx(math.pi / 12, 0, -math.pi / 12)
	if name == "Elytra_Right":
		return quat_from_euler_zyx(math.pi / 12, 0, math.pi / 12)
	return (0, 0, 0, 1)

def build(slim):
	joints = joints_for(slim)
	joint_names = list(joints)
	parts = parts_for(slim)
	prims = []
	for slot in range(len(TEX_SIZE)):
		pos, nrm, uvs, jnt, idx = [], [], [], [], []
		for (s, joint, uv, origin, size, infl, mirror) in parts:
			if s != slot:
				continue
			pivot = joints[joint]
			ji = joint_names.index(joint)
			for verts, quv in box_quads(uv, origin, size, infl, mirror, TEX_SIZE[slot]):
				# Vertices in model pixels (box coordinates are relative to the pivot)
				mv = [(p[0] + pivot[0], p[1] + pivot[1], p[2] + pivot[2]) for p in verts]
				lv = [to_luanti(*p) for p in mv]
				gv = [to_gltf(p) for p in lv]
				n = norm(cross(sub(gv[1], gv[0]), sub(gv[2], gv[0])))
				# Outward normal: away from the box center
				c = [sum(p[i] for p in gv) / 4 for i in range(3)]
				bc = to_gltf(to_luanti(*[pivot[i] + origin[i] + size[i] / 2 for i in range(3)]))
				out = norm(sub(c, bc))
				if sum(n[i] * out[i] for i in range(3)) < 0:
					n = tuple(-x for x in n)
				# Front face winding (counter-clockwise in glTF)
				order = [0, 1, 2, 3]
				if sum(cross(sub(gv[1], gv[0]), sub(gv[2], gv[0]))[i] * out[i] for i in range(3)) < 0:
					order = [0, 3, 2, 1]
				base = len(pos)
				for k in order:
					pos.append(gv[k]); nrm.append(n); uvs.append(quv[k]); jnt.append(ji)
				idx += [base, base + 1, base + 2, base, base + 2, base + 3]
		prims.append((pos, nrm, uvs, jnt, idx))

	# Binary buffer
	blob = bytearray()
	views, accessors = [], []
	def add(data, fmt, comp, typ, count, target=None, minmax=None):
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

	meshes_prims = []
	for slot, (pos, nrm, uvs, jnt, idx) in enumerate(prims):
		mn = [min(p[i] for p in pos) for i in range(3)]
		mx = [max(p[i] for p in pos) for i in range(3)]
		a_pos = add(b"".join(struct.pack("<3f", *p) for p in pos), None, 5126, "VEC3", len(pos), 34962, (mn, mx))
		a_nrm = add(b"".join(struct.pack("<3f", *p) for p in nrm), None, 5126, "VEC3", len(nrm), 34962)
		a_uv = add(b"".join(struct.pack("<2f", *p) for p in uvs), None, 5126, "VEC2", len(uvs), 34962)
		a_j = add(b"".join(struct.pack("<4B", j, 0, 0, 0) for j in jnt), None, 5121, "VEC4", len(jnt), 34962)
		a_w = add(b"".join(struct.pack("<4f", 1, 0, 0, 0) for _ in jnt), None, 5126, "VEC4", len(jnt), 34962)
		a_i = add(b"".join(struct.pack("<H", i) for i in idx), None, 5123, "SCALAR", len(idx), 34963)
		meshes_prims.append({
			"attributes": {"POSITION": a_pos, "NORMAL": a_nrm, "TEXCOORD_0": a_uv,
				"JOINTS_0": a_j, "WEIGHTS_0": a_w},
			"indices": a_i, "material": slot,
		})

	# Joint nodes (all children of the root), inverse bind = translation to the pivot
	nodes = [{"name": "Player", "children": list(range(2, 2 + len(joint_names)))},
		{"name": "Mesh", "mesh": 0, "skin": 0}]
	ibm = bytearray()
	for name in joint_names:
		t = to_gltf(to_luanti(*joints[name]))
		nodes.append({"name": name, "translation": list(t), "rotation": list(rest_rotation_gltf(name))})
		m = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -t[0], -t[1], -t[2], 1]
		ibm.extend(struct.pack("<16f", *m))
	a_ibm = add(bytes(ibm), None, 5126, "MAT4", len(joint_names))

	gltf = {
		"asset": {"version": "2.0", "generator": "mc_player_model.py"},
		"scene": 0,
		"scenes": [{"nodes": [0, 1]}],
		"nodes": nodes,
		"meshes": [{"name": "Player", "primitives": meshes_prims}],
		"skins": [{"joints": list(range(2, 2 + len(joint_names))), "inverseBindMatrices": a_ibm}],
		"materials": [{"name": TEX_NAMES[i], "pbrMetallicRoughness": {"baseColorTexture": {"index": i}}}
			for i in range(len(TEX_SIZE))],
		"textures": [{"source": i, "sampler": 0} for i in range(len(TEX_SIZE))],
		"samplers": [{"magFilter": 9728, "minFilter": 9728, "wrapS": 33071, "wrapT": 33071}],
		"images": [{"uri": n} for n in TEX_NAMES],
		"accessors": accessors,
		"bufferViews": views,
		"buffers": [{"byteLength": len(blob)}],
	}
	return gltf, bytes(blob)

def rest_rotation_gltf(name):
	# Model space rotations equal Luanti space rotations (the mapping is -I);
	# glTF negates Z: (x, y, z, w) -> (-x, -y, z, w)
	x, y, z, w = rest_rotation(name)
	return (-x, -y, z, w)

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
	for slim in (False, True):
		gltf, blob = build(slim)
		write_glb(os.path.join(out, "mcl_player_%s.glb" % ("slim" if slim else "wide")), gltf, blob)
