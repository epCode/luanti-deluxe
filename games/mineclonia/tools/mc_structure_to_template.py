#!/usr/bin/env python3
"""Convert Minecraft structure templates (gzip NBT, *.nbt) into Mineclonia
mcl_levelgen structure templates (*.dat: zstd-compressed core.serialize'd
Lua tables, see execute_save in mods/MAPGEN/mcl_levelgen/jigsaw.lua and
read_structure_template in templates.lua).

The MC files are Mojang assets: they and the generated templates are for
local use only and must not be committed or distributed (the output
directory is listed in .git/info/exclude).

Usage:
  mc_structure_to_template.py [--report FILE] SRC_DIR DST_DIR [PREFIX]

Every *.nbt below SRC_DIR is converted to DST_DIR/<relative path>.dat.
Block states are mapped to Mineclonia nodes by map_state(); an unmapped
state aborts the conversion.  A report of every block state seen, its
count and its mapping is printed (and written to --report FILE).

Template format (Minecraft coordinates, x-major, then y, z minor):
  nodes[i] = (meta_index << 24) + cid * 256 + param2, structure void
  positions use the node "mcl_levelgen:structure_void"; names[cid] = node
  name; metadata[meta_index] = {fields = {...}, inventory = {list = {...}}};
  jigsaws = node indices of jigsaw blocks (in MC's palette order: sorted by
  y, x, z), nodes_to_construct = (dx << 20) + (dy << 10) + dz.
Extra field mc_jigsaws (used by mcl_levelgen's Minecraft jigsaw placer):
  {x, y, z, front, top, name, pool, target, joint, placement_priority,
   selection_priority, turns_into} per jigsaw, same order as `jigsaws`.

Param2 values are those of the node as it would appear in Luanti when the
unrotated template is placed: Minecraft north (-Z) is Luanti +Z.
"""

import gzip
import os
import struct
import subprocess
import sys

# ----------------------------------------------------------------------
# NBT reader.
# ----------------------------------------------------------------------

def read_nbt(data):
    pos = [0]

    def rd(n):
        b = data[pos[0]:pos[0] + n]
        if len(b) != n:
            raise ValueError("truncated NBT")
        pos[0] += n
        return b

    def payload(t):
        if t == 1:
            return struct.unpack(">b", rd(1))[0]
        if t == 2:
            return struct.unpack(">h", rd(2))[0]
        if t == 3:
            return struct.unpack(">i", rd(4))[0]
        if t == 4:
            return struct.unpack(">q", rd(8))[0]
        if t == 5:
            return struct.unpack(">f", rd(4))[0]
        if t == 6:
            return struct.unpack(">d", rd(8))[0]
        if t == 7:
            n = struct.unpack(">i", rd(4))[0]
            return list(rd(n))
        if t == 8:
            n = struct.unpack(">H", rd(2))[0]
            return rd(n).decode("utf-8")
        if t == 9:
            et = rd(1)[0]
            n = struct.unpack(">i", rd(4))[0]
            return [payload(et) for _ in range(n)]
        if t == 10:
            d = {}
            while True:
                tt = rd(1)[0]
                if tt == 0:
                    return d
                n = struct.unpack(">H", rd(2))[0]
                name = rd(n).decode("utf-8")
                d[name] = payload(tt)
        if t == 11:
            n = struct.unpack(">i", rd(4))[0]
            return list(struct.unpack(">%di" % n, rd(4 * n)))
        if t == 12:
            n = struct.unpack(">i", rd(4))[0]
            return list(struct.unpack(">%dq" % n, rd(8 * n)))
        raise ValueError("bad NBT tag %d" % t)

    t = rd(1)[0]
    n = struct.unpack(">H", rd(2))[0]
    rd(n)
    return payload(t)

# ----------------------------------------------------------------------
# Lua serialization (core.deserialize-compatible).
# ----------------------------------------------------------------------

def lua_str(s):
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == '"' or ch == "\\":
            out.append("\\" + ch)
        elif ch == "\n":
            out.append("\\n")
        elif o < 32 or o == 127:
            out.append("\\%03d" % o)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)

def lua_val(v):
    if v is None:
        return "nil"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, (list, tuple)):
        return "{" + ",".join(lua_val(x) for x in v) + "}"
    if isinstance(v, dict):
        parts = []
        for k in sorted(v.keys(), key=lambda k: (isinstance(k, str), k)):
            if isinstance(k, int):
                parts.append("[%d]=%s" % (k, lua_val(v[k])))
            elif k.isidentifier():
                parts.append("%s=%s" % (k, lua_val(v[k])))
            else:
                parts.append("[%s]=%s" % (lua_str(k), lua_val(v[k])))
        return "{" + ",".join(parts) + "}"
    raise TypeError(type(v))

def lua_serialize(v):
    return "return " + lua_val(v)

# ----------------------------------------------------------------------
# Geometry helpers.
# ----------------------------------------------------------------------

# Minecraft direction -> Luanti unit vector (MC north = -Z = Luanti +Z).
LDIR = {
    "north": (0, 0, 1), "south": (0, 0, -1),
    "east": (1, 0, 0), "west": (-1, 0, 0),
    "up": (0, 1, 0), "down": (0, -1, 0),
}
OPPOSITE = {"north": "south", "south": "north", "east": "west",
            "west": "east", "up": "down", "down": "up"}
CW = {"north": "east", "east": "south", "south": "west", "west": "north"}
CCW = {v: k for k, v in CW.items()}

def dir_to_facedir(v):
    # core.dir_to_facedir (horizontal only).
    x, _, z = v
    if abs(x) > abs(z):
        return 1 if x > 0 else 3
    return 0 if z > 0 else 2

def dir_to_wallmounted(v):
    return {(0, 1, 0): 0, (0, -1, 0): 1, (1, 0, 0): 2, (-1, 0, 0): 3,
            (0, 0, 1): 4, (0, 0, -1): 5}[v]

def facing_front(f):
    """param2 of a facedir node whose front (the -Z face of the unrotated
    node, e.g. a furnace's mouth) points towards MC direction F."""
    v = LDIR[f]
    return dir_to_facedir((-v[0], 0, -v[2]))

def rot_xz(p, deg):
    # irrlicht vector3d::rotateXZBy
    import math
    x, y, z = p
    r = math.radians(deg)
    cs, sn = round(math.cos(r)), round(math.sin(r))
    return (x * cs - z * sn, y, x * sn + z * cs)

def rot_yz(p, deg):
    import math
    x, y, z = p
    r = math.radians(deg)
    cs, sn = round(math.cos(r)), round(math.sin(r))
    return (x, y * cs - z * sn, y * sn + z * cs)

def rot_xy(p, deg):
    import math
    x, y, z = p
    r = math.radians(deg)
    cs, sn = round(math.cos(r)), round(math.sin(r))
    return (x * cs - y * sn, x * sn + y * cs, z)

def facedir_transform(p, facedir):
    # transformNodeBox in src/mapnode.cpp
    axisdir = facedir >> 2
    f = facedir & 3
    if f == 1:
        p = rot_xz(p, -90)
    elif f == 2:
        p = rot_xz(p, 180)
    elif f == 3:
        p = rot_xz(p, 90)
    if axisdir == 1:
        p = rot_yz(p, 90)
    elif axisdir == 2:
        p = rot_yz(p, -90)
    elif axisdir == 3:
        p = rot_xy(p, -90)
    elif axisdir == 4:
        p = rot_xy(p, 90)
    elif axisdir == 5:
        p = rot_xy(p, -180)
    return p

def octants_of_boxes(boxes, facedir):
    """Set of octant centres (+-1 per axis, Luanti coordinates) covered by
    the node boxes rotated by facedir."""
    occ = set()
    for sx in (-1, 1):
        for sy in (-1, 1):
            for sz in (-1, 1):
                c = (sx * 0.25, sy * 0.25, sz * 0.25)
                # Rotate the sample point backwards = test the rotated box:
                # rotate each box instead.
                for b in boxes:
                    x1, y1, z1, x2, y2, z2 = b
                    p1 = facedir_transform((x1, y1, z1), facedir)
                    p2 = facedir_transform((x2, y2, z2), facedir)
                    lo = [min(p1[i], p2[i]) for i in range(3)]
                    hi = [max(p1[i], p2[i]) for i in range(3)]
                    if all(lo[i] < c[i] < hi[i] for i in range(3)):
                        occ.add((sx, sy, sz))
                        break
    return frozenset(occ)

STAIR_BOXES = {
    "": [(-0.5, -0.5, -0.5, 0.5, 0, 0.5), (-0.5, 0, 0, 0.5, 0.5, 0.5)],
    "_outer": [(-0.5, -0.5, -0.5, 0.5, 0, 0.5), (-0.5, 0, 0, 0, 0.5, 0.5)],
    "_inner": [(-0.5, -0.5, -0.5, 0.5, 0, 0.5), (-0.5, 0, 0, 0.5, 0.5, 0.5),
               (-0.5, 0, -0.5, 0, 0.5, 0)],
}

STAIR_CANDIDATES = {}
for _suffix, _boxes in STAIR_BOXES.items():
    for _fd in range(24):
        _occ = octants_of_boxes(_boxes, _fd)
        STAIR_CANDIDATES.setdefault(_occ, []).append((_suffix, _fd))

def quadrant(dirs):
    """Horizontal octant signs (sx, sz) in Luanti coords for the corner
    between two MC directions, or a half for one direction."""
    sx = sz = 0
    for d in dirs:
        v = LDIR[d]
        if v[0]:
            sx = v[0]
        if v[2]:
            sz = v[2]
    return sx, sz

def mc_stair_octants(facing, half, shape):
    full_y = -1 if half == "bottom" else 1  # the slab half
    step_y = -full_y
    occ = set()
    for sx in (-1, 1):
        for sz in (-1, 1):
            occ.add((sx, full_y, sz))

    def add_half(d):
        v = LDIR[d]
        for sx in (-1, 1):
            for sz in (-1, 1):
                if (v[0] and sx == v[0]) or (v[2] and sz == v[2]):
                    occ.add((sx, step_y, sz))

    def add_quarter(d1, d2):
        sx, sz = quadrant((d1, d2))
        occ.add((sx, step_y, sz))

    left, right = CCW[facing], CW[facing]
    if shape == "straight":
        add_half(facing)
    elif shape == "outer_left":
        add_quarter(facing, left)
    elif shape == "outer_right":
        add_quarter(facing, right)
    elif shape == "inner_left":
        add_half(facing)
        add_half(left)
    elif shape == "inner_right":
        add_half(facing)
        add_half(right)
    else:
        raise KeyError(shape)
    return frozenset(occ)

def stair_node(base, props):
    occ = mc_stair_octants(props["facing"], props["half"], props["shape"])
    cands = STAIR_CANDIDATES.get(occ)
    if not cands:
        raise KeyError("no stair node matches %r" % (props,))
    # Prefer the canonical param2 values used by Mineclonia's placement
    # code: 0-3 upright and 20-23 upside down.
    def score(c):
        fd = c[1]
        return 0 if (fd < 4 or fd >= 20) else 1
    cands = sorted(cands, key=score)
    suffix, fd = cands[0]
    return "mcl_stairs:stair_" + base + suffix, fd

# ----------------------------------------------------------------------
# Block state mapping.
# ----------------------------------------------------------------------

SIMPLE = {
    "minecraft:air": "air",
    "minecraft:cave_air": "air",
    "minecraft:blue_carpet": "mcl_wool:blue_carpet",
    "minecraft:cyan_carpet": "mcl_wool:cyan_carpet",
    "minecraft:gray_carpet": "mcl_wool:grey_carpet",
    "minecraft:light_blue_carpet": "mcl_wool:light_blue_carpet",
    "minecraft:blue_wool": "mcl_wool:blue",
    "minecraft:cyan_wool": "mcl_wool:cyan",
    "minecraft:gray_wool": "mcl_wool:grey",
    "minecraft:light_blue_wool": "mcl_wool:light_blue",
    "minecraft:blue_ice": "mcl_core:blue_ice",
    "minecraft:ice": "mcl_core:ice",
    "minecraft:packed_ice": "mcl_core:packed_ice",
    "minecraft:chiseled_deepslate": "mcl_deepslate:deepslate_chiseled",
    "minecraft:cobbled_deepslate": "mcl_deepslate:deepslate_cobbled",
    "minecraft:cracked_deepslate_bricks": "mcl_deepslate:deepslate_bricks_cracked",
    "minecraft:cracked_deepslate_tiles": "mcl_deepslate:deepslate_tiles_cracked",
    "minecraft:deepslate_bricks": "mcl_deepslate:deepslate_bricks",
    "minecraft:deepslate_tiles": "mcl_deepslate:deepslate_tiles",
    "minecraft:polished_deepslate": "mcl_deepslate:deepslate_polished",
    "minecraft:reinforced_deepslate": "mcl_deepslate:deepslate_reinforced",
    "minecraft:dark_oak_planks": "mcl_trees:wood_dark_oak",
    "minecraft:dirt": "mcl_core:dirt",
    "minecraft:glass": "mcl_core:glass",
    "minecraft:smooth_basalt": "mcl_blackstone:basalt_smooth",
    "minecraft:redstone_block": "mcl_redstone_torch:redstoneblock",
    "minecraft:soul_fire": "mcl_blackstone:soul_fire",
    "minecraft:soul_sand": "mcl_nether:soul_sand",
    "minecraft:stone_pressure_plate": None,  # handled below
    "minecraft:target": "mcl_target:target_off",
    "minecraft:dark_oak_fence": "mcl_fences:dark_oak_fence",
    "minecraft:structure_void": "mcl_levelgen:structure_void",
}

AXIS_NODES = {
    "minecraft:deepslate": "mcl_deepslate:deepslate",
    "minecraft:dark_oak_log": "mcl_trees:tree_dark_oak",
    "minecraft:polished_basalt": "mcl_blackstone:basalt_polished",
}
AXIS_PARAM2 = {"y": 0, "x": 12, "z": 4}

STAIRS = {
    "minecraft:deepslate_brick_stairs": "deepslate_bricks",
    "minecraft:deepslate_tile_stairs": "deepslate_tiles",
    "minecraft:polished_deepslate_stairs": "deepslate_polished",
    "minecraft:cobbled_deepslate_stairs": "deepslate_cobbled",
}

SLABS = {
    "minecraft:deepslate_brick_slab": "deepslate_bricks",
    "minecraft:deepslate_tile_slab": "deepslate_tiles",
    "minecraft:polished_deepslate_slab": "deepslate_polished",
    "minecraft:cobbled_deepslate_slab": "deepslate_cobbled",
}

WALLS = {
    "minecraft:deepslate_brick_wall": "mcl_deepslate:deepslatebrickswall",
    "minecraft:deepslate_tile_wall": "mcl_deepslate:deepslatetileswall",
    "minecraft:polished_deepslate_wall": "mcl_deepslate:deepslatepolishedwall",
    "minecraft:cobbled_deepslate_wall": "mcl_deepslate:deepslatecobbledwall",
}

CANDLE_COLOURS = {
    "minecraft:candle": 0,
    "minecraft:white_candle": 1,  # mcl_dyes palette_index (white = 0) + 1
}

# Loot tables: MC id -> Mineclonia (mcl_levelgen.register_loot_table) id.
LOOT_TABLES = {
    "minecraft:chests/ancient_city": "mcl_levelgen:ancient_city_chest",
    "minecraft:chests/ancient_city_ice_box": "mcl_levelgen:ancient_city_ice_box_chest",
}

ITEMS = {
    "minecraft:golden_apple": "mcl_core:apple_gold",
    "minecraft:wooden_shovel": "mcl_tools:shovel_wood",
    "minecraft:deepslate": "mcl_deepslate:deepslate",
}

LOOT_TABLE_FIELD = "mcl_levelgen:loot_table"


class Unmapped(Exception):
    pass


def item_string(item):
    name = ITEMS.get(item["id"])
    if not name:
        raise Unmapped("item " + item["id"])
    count = item.get("count", 1)
    return name if count == 1 else "%s %d" % (name, count)


def inventory_list(size, items):
    lst = [""] * size
    for item in items:
        lst[item["Slot"]] = item_string(item)
    return lst


def wall_node(root, p):
    up = p["up"] == "true"
    sides = {d: p[d] for d in ("north", "south", "east", "west")}
    tall = any(v == "tall" for v in sides.values())
    conn = {d for d, v in sides.items() if v != "none"}
    if not up:
        if conn == {"east", "west"}:
            return root + ("_tall_flat" if tall else "_short_flat"), 0
        if conn == {"north", "south"}:
            return root + ("_tall_flat" if tall else "_short_flat"), 1
        raise Unmapped("wall up=false with sides %r" % sides)
    return root + ("_tall_pillar" if tall else "_short_pillar"), 0


REDSTONE_SIDE_BIT = {"south": 0x1, "west": 0x2, "north": 0x4, "east": 0x8}


def map_state(bid, p, nbt):
    """Return (node name, param2, metadata or None).  Raises Unmapped."""
    if bid in AXIS_NODES:
        return AXIS_NODES[bid], AXIS_PARAM2[p.get("axis", "y")], None
    if bid in STAIRS:
        name, fd = stair_node(STAIRS[bid], p)
        return name, fd, None
    if bid in SLABS:
        base = "mcl_stairs:slab_" + SLABS[bid]
        t = p["type"]
        return base + {"bottom": "", "top": "_top", "double": "_double"}[t], 0, None
    if bid in WALLS:
        name, param2 = wall_node(WALLS[bid], p)
        return name, param2, None
    if bid == "minecraft:stone_pressure_plate":
        return ("mcl_pressureplates:pressure_plate_stone_"
                + ("on" if p["powered"] == "true" else "off")), 0, None
    if bid in SIMPLE and SIMPLE[bid]:
        return SIMPLE[bid], 0, None
    if bid == "minecraft:grass_block":
        return "mcl_core:dirt_with_grass", 0, None
    if bid == "minecraft:water":
        if p.get("level", "0") != "0":
            raise Unmapped("flowing water")
        return "mcl_core:water_source", 0, None
    if bid == "minecraft:torch":
        return "mcl_torches:torch", 1, None
    if bid in ("minecraft:redstone_torch", "minecraft:redstone_wall_torch"):
        lit = p["lit"] == "true"
        if bid == "minecraft:redstone_torch":
            return ("mcl_redstone_torch:redstone_torch_" + ("on" if lit else "off")), 1, None
        # Wall torch facing F hangs on the block on the opposite side.
        att = LDIR[OPPOSITE[p["facing"]]]
        return ("mcl_redstone_torch:redstone_torch_" + ("on" if lit else "off") + "_wall",
                dir_to_wallmounted(att), None)
    if bid == "minecraft:ladder":
        att = LDIR[OPPOSITE[p["facing"]]]
        return "mcl_core:ladder", dir_to_wallmounted(att), None
    if bid in CANDLE_COLOURS:
        n = int(p["candles"])
        lit = p["lit"] == "true"
        return ("mcl_candles:candle_" + ("lit_" if lit else "") + str(n),
                CANDLE_COLOURS[bid], None)
    if bid == "minecraft:skeleton_skull":
        r = int(p["rotation"])
        # MC rotation r: 0 = face south, 4 = west, 8 = north, 12 = east.
        # degrotate 0 = face south (-Z), increasing like yaw: 60 = east.
        return "mcl_heads:skeleton", (240 - r * 15) % 240, None
    if bid == "minecraft:soul_lantern":
        if p["hanging"] == "true":
            return "mcl_lanterns:soul_lantern_ceiling", 0, None
        return "mcl_lanterns:soul_lantern_floor", 1, None
    if bid == "minecraft:chest":
        if p.get("type", "single") != "single":
            raise Unmapped("double chest")
        param2 = facing_front(p["facing"])
        meta = None
        if nbt is not None:
            if "LootTable" in nbt:
                lt = LOOT_TABLES.get(nbt["LootTable"])
                if not lt:
                    raise Unmapped("loot table " + nbt["LootTable"])
                meta = {"fields": {LOOT_TABLE_FIELD: lt}, "inventory": {}}
            elif nbt.get("Items"):
                meta = {"fields": {}, "inventory": {
                    "main": inventory_list(27, nbt["Items"]), "input": [""]}}
        return "mcl_chests:chest_small", param2, meta
    if bid == "minecraft:furnace":
        name = "mcl_furnaces:furnace_active" if p["lit"] == "true" else "mcl_furnaces:furnace"
        meta = None
        if nbt is not None and nbt.get("Items"):
            lists = {"src": [""], "fuel": [""], "dst": [""], "sorter": [""]}
            for item in nbt["Items"]:
                lists[{0: "src", 1: "fuel", 2: "dst"}[item["Slot"]]][0] = item_string(item)
            meta = {"fields": {}, "inventory": lists}
        return name, facing_front(p["facing"]), meta
    if bid == "minecraft:lectern":
        if p["has_book"] == "true":
            raise Unmapped("lectern with book")
        return "mcl_lectern:lectern", facing_front(p["facing"]), None
    if bid == "minecraft:campfire":
        name = "mcl_campfires:campfire_lit" if p["lit"] == "true" else "mcl_campfires:campfire"
        return name, facing_front(p["facing"]), None
    if bid == "minecraft:glass_pane":
        conn = {d for d in ("north", "south", "east", "west") if p[d] == "true"}
        if conn == {"east", "west"}:
            return "mcl_panes:pane_natural_flat", 0, None
        if conn == {"north", "south"}:
            return "mcl_panes:pane_natural_flat", 1, None
        return "mcl_panes:pane_natural", 0, None
    if bid == "minecraft:snow":
        n = int(p["layers"])
        return ("mcl_core:snow" if n == 1 else "mcl_core:snow_%d" % n), 0, None
    if bid == "minecraft:iron_trapdoor":
        if p["open"] == "true":
            raise Unmapped("open trapdoor")
        # Mineclonia stores the placer's look direction (= opposite of
        # MC's FACING); upside down trapdoors add 20 with 21/23 swapped.
        fd = dir_to_facedir(LDIR[OPPOSITE[p["facing"]]])
        if p["half"] == "top":
            fd = fd + 20
            fd = {21: 23, 23: 21}.get(fd, fd)
        return "mcl_doors:iron_trapdoor", fd, None
    if bid == "minecraft:lever":
        on = p["powered"] == "true"
        name = "mcl_lever:lever_" + ("on" if on else "off")
        face = p["face"]
        facing = p["facing"]
        if face == "wall":
            att = LDIR[OPPOSITE[facing]]
            return name, dir_to_facedir(att), None
        ew = facing in ("east", "west")
        if face == "floor":
            return name, 13 if ew else 10, None
        return name, 15 if ew else 8, None
    if bid == "minecraft:redstone_lamp":
        return ("mcl_redstone_lamp:lamp_" + ("on" if p["lit"] == "true" else "off")), 0, None
    if bid == "minecraft:note_block":
        return "mcl_noteblock:noteblock", int(p["note"]), None
    if bid == "minecraft:redstone_wire":
        flags = 0
        for d, bitv in REDSTONE_SIDE_BIT.items():
            v = p[d]
            if v == "side":
                flags |= bitv
            elif v == "up":
                flags |= bitv | (bitv << 4)
        name = "mcl_redstone:redstone" if flags == 0 else "mcl_redstone:wire_%02x" % flags
        return name, int(p["power"]), None
    if bid == "minecraft:repeater":
        powered = p["powered"] == "true"
        delay = int(p["delay"])
        out = OPPOSITE[p["facing"]]
        dir4 = {"north": 0, "east": 1, "south": 2, "west": 3}[out]
        if p["locked"] == "true":
            return ("mcl_repeaters:repeater_" + ("on" if powered else "off") + "_locked",
                    delay * 4 + dir4, None)
        return "mcl_repeaters:repeater_%s_%d" % ("on" if powered else "off", delay), dir4, None
    if bid == "minecraft:comparator":
        powered = p["powered"] == "true"
        mode = "comp" if p["mode"] == "compare" else "sub"
        out = OPPOSITE[p["facing"]]
        dir4 = {"north": 0, "east": 1, "south": 2, "west": 3}[out]
        meta = None
        if nbt is not None and nbt.get("OutputSignal", 0) != 0:
            meta = {"fields": {"output": str(nbt["OutputSignal"])}, "inventory": {}}
        return ("mcl_comparators:comparator_%s_%s" % ("on" if powered else "off", mode),
                dir4, meta)
    if bid == "minecraft:sticky_piston":
        name = "mcl_pistons:piston_sticky_" + ("on" if p["extended"] == "true" else "off")
        v = LDIR[p["facing"]]
        if v[1]:
            raise Unmapped("vertical piston")
        return name, dir_to_facedir((-v[0], 0, -v[2])), None
    if bid == "minecraft:piston_head":
        if p["type"] != "sticky" or p["short"] != "false":
            raise Unmapped("piston head %r" % p)
        v = LDIR[p["facing"]]
        if v[1]:
            raise Unmapped("vertical piston head")
        return "mcl_pistons:piston_pusher_sticky", dir_to_facedir((-v[0], 0, -v[2])), None
    if bid == "minecraft:sculk_sensor":
        if p["sculk_sensor_phase"] != "inactive":
            raise Unmapped("active sculk sensor")
        return "mcl_sculk:sensor", 0, None
    if bid == "minecraft:sculk":
        return "mcl_sculk:sculk", 0, None
    if bid == "minecraft:sculk_catalyst":
        return ("mcl_sculk:catalyst_bloom" if p.get("bloom") == "true"
                else "mcl_sculk:catalyst"), 0, None
    if bid == "minecraft:sculk_shrieker":
        return ("mcl_sculk:shrieker_can_summon" if p.get("can_summon") == "true"
                else "mcl_sculk:shrieker"), 0, None
    raise Unmapped("%s[%s]" % (bid, ",".join("%s=%s" % kv for kv in sorted(p.items()))))

# Jigsaw blocks.

JIGSAW_PARAM2_UP = {"south": 0, "west": 1, "north": 2, "east": 3}
JIGSAW_PARAM2_DOWN = {"south": 20, "east": 21, "north": 22, "west": 23}
JIGSAW_PARAM2_HORIZ = {"north": 4, "south": 8, "east": 12, "west": 16}

def jigsaw_param2(front, top):
    if front == "up":
        return JIGSAW_PARAM2_UP[top]
    if front == "down":
        return JIGSAW_PARAM2_DOWN[top]
    return JIGSAW_PARAM2_HORIZ[front]

def parse_final_state(s):
    if "[" in s:
        bid, rest = s.split("[", 1)
        rest = rest.rstrip("]")
        props = dict(kv.split("=") for kv in rest.split(",") if kv)
    else:
        bid, props = s, {}
    if ":" not in bid:
        bid = "minecraft:" + bid
    return bid, props

def default_props(bid):
    # Default block states for jigsaw final states.
    if bid in AXIS_NODES:
        return {"axis": "y"}
    if bid in SLABS:
        return {"type": "bottom"}
    return {}

def pool_id(name):
    # Template pools are registered in the mcl_levelgen namespace.
    if name.startswith("minecraft:"):
        return "mcl_levelgen:" + name[len("minecraft:"):]
    return name

# ----------------------------------------------------------------------
# Conversion.
# ----------------------------------------------------------------------

class Converter:
    def __init__(self, prefix):
        self.prefix = prefix
        self.report = {}  # state string -> [count, mapping]

    def note(self, key, mapping):
        r = self.report.setdefault(key, [0, mapping])
        r[0] += 1

    def convert(self, path):
        d = read_nbt(gzip.open(path).read())
        sx, sy, sz = d["size"]
        if "palettes" in d:
            raise Unmapped("multiple palettes in " + path)
        palette = d["palette"]
        if d.get("entities"):
            raise Unmapped("entities in " + path)

        names = {}
        name_to_cid = {}

        def cid_of(name):
            if name not in name_to_cid:
                cid = len(name_to_cid) + 1
                name_to_cid[name] = cid
                names[cid] = name
            return name_to_cid[name]

        void = cid_of("mcl_levelgen:structure_void")
        n = sx * sy * sz
        nodes = [void * 256] * n
        metadata = {}
        to_construct = []
        jigsaw_infos = []

        def index(x, y, z):
            return (x * sy + y) * sz + z

        for b in d["blocks"]:
            x, y, z = b["pos"]
            st = palette[b["state"]]
            bid = st["id"]
            props = dict(st.get("properties", {}))
            props.pop("waterlogged", None)
            nbt = b.get("nbt")
            key = bid + ("[" + ",".join("%s=%s" % kv for kv in sorted(st.get("properties", {}).items())) + "]"
                         if st.get("properties") else "")
            idx = index(x, y, z)
            if bid == "minecraft:jigsaw":
                front, top = props["orientation"].split("_")
                fs = nbt.get("final_state", "minecraft:air")
                fbid, fprops = parse_final_state(fs)
                fprops = dict(default_props(fbid), **fprops)
                if fbid == "minecraft:structure_void":
                    turns_into, turns_param2 = "ignore", 0
                else:
                    turns_into, turns_param2, fmeta = map_state(fbid, fprops, None)
                    if turns_param2 != 0 or fmeta:
                        raise Unmapped("jigsaw final state with param2: " + fs)
                save = {
                    "name": nbt.get("name", "minecraft:empty"),
                    "target_pool": pool_id(nbt.get("pool", "minecraft:empty")),
                    "target_name": nbt.get("target", "minecraft:empty"),
                    "turns_into": turns_into,
                    "selection_priority": nbt.get("selection_priority", 0),
                    "placement_priority": nbt.get("placement_priority", 0),
                    "joint_type": 2 if nbt.get("joint", "rollable" if front in ("up", "down") else "aligned") == "rollable" else 1,
                }
                meta_id = len(metadata) + 1
                metadata[meta_id] = {
                    "fields": {"mcl_levelgen:structure_jigsaw_save_data": lua_serialize(save)},
                    "inventory": {},
                }
                cid = cid_of("mcl_levelgen:jigsaw_block")
                nodes[idx] = (meta_id << 24) + cid * 256 + jigsaw_param2(front, top)
                jigsaw_infos.append({
                    "idx": idx + 1, "x": x, "y": y, "z": z,
                    "front": front, "top": top,
                    "name": save["name"], "pool": save["target_pool"],
                    "target": save["target_name"],
                    "joint": "rollable" if save["joint_type"] == 2 else "aligned",
                    "placement_priority": save["placement_priority"],
                    "selection_priority": save["selection_priority"],
                    "turns_into": turns_into,
                })
                self.note(key + " (jigsaw)", "mcl_levelgen:jigsaw_block param2=%d" % jigsaw_param2(front, top))
                continue
            name, param2, meta = map_state(bid, props, nbt)
            if not (0 <= param2 <= 255):
                raise Unmapped("param2 out of range: %s" % key)
            self.note(key + (" +nbt" if meta else ""), "%s param2=%d%s" % (
                name, param2, " meta" if meta else ""))
            cid = cid_of(name)
            enc = cid * 256 + param2
            if meta is not None:
                meta_id = len(metadata) + 1
                if meta_id > 255:
                    raise Unmapped("too many metadata entries in " + path)
                metadata[meta_id] = meta
                enc += meta_id << 24
            nodes[idx] = enc
            loot = meta is not None and LOOT_TABLE_FIELD in meta["fields"]
            # Loot chests are constructed by the loot table handler.
            if CONSTRUCT(name) and not loot:
                to_construct.append((x << 20) + (y << 10) + z)

        # Jigsaws in MC palette order: sorted by y, then x, then z.
        jigsaw_infos.sort(key=lambda j: (j["y"], j["x"], j["z"]))
        tpl = {
            "nodes": nodes,
            "metadata": metadata,
            "names": names,
            "nodes_to_construct": sorted(to_construct),
            "jigsaws": [j["idx"] for j in jigsaw_infos],
            "mc_jigsaws": [{k: v for k, v in j.items() if k != "idx"} for j in jigsaw_infos],
            "width": sx, "height": sy, "length": sz,
            "data_blocks": [],
        }
        return tpl


def CONSTRUCT(name):
    # Nodes whose on_construct must run after placement (as execute_save:
    # group container / redstone_wire / chest_entity / sign).
    return (name.startswith("mcl_chests:") or name.startswith("mcl_furnaces:")
            or name.startswith("mcl_redstone:") or name == "mcl_lectern:lectern"
            or name.startswith("mcl_campfires:"))


def zstd_compress(data):
    p = subprocess.run(["/usr/bin/zstd", "-q", "-19", "-c"], input=data,
                       stdout=subprocess.PIPE, check=True)
    return p.stdout


def main(argv):
    report_file = None
    if len(argv) > 1 and argv[1] == "--report":
        report_file = argv[2]
        argv = [argv[0]] + argv[3:]
    if len(argv) < 3:
        print(__doc__)
        return 2
    src, dst = argv[1], argv[2]
    conv = Converter(argv[3] if len(argv) > 3 else "")
    count = 0
    try:
        for root, _, files in os.walk(src):
            for f in sorted(files):
                if not f.endswith(".nbt"):
                    continue
                path = os.path.join(root, f)
                rel = os.path.relpath(path, src)[:-4] + ".dat"
                tpl = conv.convert(path)
                out = os.path.join(dst, rel)
                os.makedirs(os.path.dirname(out), exist_ok=True)
                data = lua_serialize(tpl).encode("utf-8")
                with open(out, "wb") as fh:
                    fh.write(zstd_compress(data))
                count += 1
    except Unmapped as e:
        print("ERROR: unmapped block state or data: %s" % e, file=sys.stderr)
        return 1
    lines = ["%-90s %7s  %s" % ("Minecraft block state", "count", "Mineclonia node")]
    for key in sorted(conv.report):
        n, mapping = conv.report[key]
        lines.append("%-90s %7d  %s" % (key, n, mapping))
    text = "\n".join(lines) + "\n"
    print(text)
    print("Converted %d templates into %s" % (count, dst))
    if report_file:
        with open(report_file, "w") as fh:
            fh.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
