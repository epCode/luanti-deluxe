#!/usr/bin/env python3
"""Copies the deep dark textures and sounds of Minecraft Java 26.3 into
Mineclonia's game texture folder (games/mineclonia/textures, git-excluded:
Mojang assets, local use only) and writes the sound event table
mods/CORE/mcl_mcsounds/events.lua (names, weights, volumes, pitches only).

Animated textures: Minecraft's .mcmeta animations with "interpolate" blend
the frames every tick; Luanti's vertical_frames cannot, so those strips are
baked into one frame per game tick (frame length 0.05 s).

Usage: mc_deepdark_assets.py [MC_ASSET_ROOT]
  MC_ASSET_ROOT defaults to ~/.cache/mc-research/26.3/deepdark
"""

import json
import os
import shutil
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
GAME = os.path.dirname(HERE)
OUT_TEX = os.path.join(GAME, "textures")
OUT_SND = os.path.join(OUT_TEX, "mc_sounds")
EVENTS_LUA = os.path.join(GAME, "mods", "CORE", "mcl_mcsounds", "events.lua")

SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
    "~/.cache/mc-research/26.3/deepdark")
TEX = os.path.join(SRC, "assets", "minecraft", "textures")

# Minecraft texture -> Mineclonia name
TEXTURES = {
    "block/sculk.png": "mcl_sculk_sculk.png",
    "block/sculk_vein.png": "mcl_sculk_vein.png",
    "block/sculk_catalyst_top.png": "mcl_sculk_catalyst_top.png",
    "block/sculk_catalyst_side.png": "mcl_sculk_catalyst_side.png",
    "block/sculk_catalyst_bottom.png": "mcl_sculk_catalyst_bottom.png",
    "block/sculk_catalyst_top_bloom.png": "mcl_sculk_catalyst_top_bloom.png",
    "block/sculk_catalyst_side_bloom.png": "mcl_sculk_catalyst_side_bloom.png",
    "block/sculk_sensor_top.png": "mcl_sculk_sensor_top.png",
    "block/sculk_sensor_side.png": "mcl_sculk_sensor_side.png",
    "block/sculk_sensor_bottom.png": "mcl_sculk_sensor_bottom.png",
    "block/sculk_sensor_tendril_inactive.png": "mcl_sculk_sensor_tendril_inactive.png",
    "block/sculk_sensor_tendril_active.png": "mcl_sculk_sensor_tendril_active.png",
    "block/calibrated_sculk_sensor_top.png": "mcl_sculk_calibrated_sensor_top.png",
    "block/calibrated_sculk_sensor_input_side.png": "mcl_sculk_calibrated_sensor_input_side.png",
    "block/calibrated_sculk_sensor_amethyst.png": "mcl_sculk_calibrated_sensor_amethyst.png",
    "block/sculk_shrieker_top.png": "mcl_sculk_shrieker_top.png",
    "block/sculk_shrieker_side.png": "mcl_sculk_shrieker_side.png",
    "block/sculk_shrieker_bottom.png": "mcl_sculk_shrieker_bottom.png",
    "block/sculk_shrieker_inner_top.png": "mcl_sculk_shrieker_inner_top.png",
    "block/sculk_shrieker_can_summon_inner_top.png": "mcl_sculk_shrieker_can_summon_inner_top.png",
    "item/echo_shard.png": "mcl_sculk_echo_shard.png",
    "item/warden_spawn_egg.png": "mobs_mc_spawn_icon_warden.png",
    "item/music_disc_5.png": "mcl_jukebox_record_5.png",
    "item/disc_fragment_5.png": "mcl_jukebox_disc_fragment_5.png",
    "mob_effect/darkness.png": "mcl_potions_effect_darkness.png",
    "particle/vibration.png": "mcl_sculk_vibration.png",
    "particle/shriek.png": "mcl_sculk_shriek.png",
}
for i in range(16):
    TEXTURES["particle/sonic_boom_%d.png" % i] = "mobs_mc_sonic_boom_%d.png" % i
for i in range(7):
    TEXTURES["particle/sculk_charge_%d.png" % i] = "mcl_sculk_charge_%d.png" % i
for i in range(4):
    TEXTURES["particle/sculk_charge_pop_%d.png" % i] = "mcl_sculk_charge_pop_%d.png" % i
for i in range(11):
    TEXTURES["particle/sculk_soul_%d.png" % i] = "mcl_sculk_soul_%d.png" % i


def bake_animation(src, meta):
    """Returns (image, frame_length_seconds) for a vertical strip."""
    anim = meta["animation"]
    img = Image.open(src).convert("RGBA")
    w, h = img.size
    fw = anim.get("width", w)
    fh = anim.get("height", fw)
    count = h // fh
    frames = [img.crop((0, i * fh, fw, (i + 1) * fh)) for i in range(count)]
    order = anim.get("frames")
    seq = []
    for f in (order if order else range(count)):
        if isinstance(f, dict):
            seq.append((f["index"], f.get("time", anim.get("frametime", 1))))
        else:
            seq.append((f, anim.get("frametime", 1)))
    if not anim.get("interpolate"):
        if all(t == seq[0][1] for _, t in seq) and order is None:
            return img, seq[0][1] * 0.05
        out_frames = []
        for idx, t in seq:
            out_frames += [frames[idx]] * t
    else:
        # TextureAtlasSprite.InterpolationData.uploadInterpolatedFrame:
        # mix = tick_in_frame / frame_time between this frame and the next
        out_frames = []
        for n, (idx, t) in enumerate(seq):
            nxt = seq[(n + 1) % len(seq)][0]
            for tick in range(t):
                mix = tick / t
                out_frames.append(Image.blend(frames[idx], frames[nxt], mix)
                                  if mix > 0 else frames[idx])
    out = Image.new("RGBA", (fw, fh * len(out_frames)))
    for i, f in enumerate(out_frames):
        out.paste(f, (0, i * fh))
    return out, 0.05


# Particle sprite sets as Luanti animation strips (frame i = sprite i)
STRIPS = {
    "mcl_sculk_charge.png": ["particle/sculk_charge_%d.png" % i for i in range(7)],
    "mcl_sculk_charge_pop.png": ["particle/sculk_charge_pop_%d.png" % i for i in range(4)],
    "mcl_sculk_soul.png": ["particle/sculk_soul_%d.png" % i for i in range(11)],
    "mobs_mc_sonic_boom.png": ["particle/sonic_boom_%d.png" % i for i in range(16)],
}


def make_strips():
    for dst, frames in STRIPS.items():
        imgs = [Image.open(os.path.join(TEX, f)).convert("RGBA") for f in frames]
        w, h = imgs[0].size
        out = Image.new("RGBA", (w, h * len(imgs)))
        for i, im in enumerate(imgs):
            out.paste(im, (0, i * h))
        out.save(os.path.join(OUT_TEX, dst))
        print("strip %s: %d frames of %dx%d" % (dst, len(imgs), w, h))


def copy_textures():
    anims = {}
    for src_rel, dst in TEXTURES.items():
        src = os.path.join(TEX, src_rel)
        meta_path = src + ".mcmeta"
        dst_path = os.path.join(OUT_TEX, dst)
        if os.path.exists(meta_path):
            with open(meta_path) as f:
                meta = json.load(f)
            img, length = bake_animation(src, meta)
            img.save(dst_path)
            fw = img.size[0]
            frames = img.size[1] // fw
            anims[dst] = (fw, frames, length)
        else:
            shutil.copyfile(src, dst_path)
    for name, (fw, frames, length) in sorted(anims.items()):
        print("animated %s: %d frames of %dpx, %.2f s each (%.2f s loop)" %
              (name, frames, fw, length, frames * length))


SOUND_EVENTS = [
    "block.sculk.break", "block.sculk.charge", "block.sculk.fall",
    "block.sculk.hit", "block.sculk.place", "block.sculk.spread",
    "block.sculk.step", "block.sculk_catalyst.bloom",
    "block.sculk_catalyst.break", "block.sculk_catalyst.fall",
    "block.sculk_catalyst.hit", "block.sculk_catalyst.place",
    "block.sculk_catalyst.step", "block.sculk_sensor.break",
    "block.sculk_sensor.clicking", "block.sculk_sensor.clicking_stop",
    "block.sculk_sensor.fall", "block.sculk_sensor.hit",
    "block.sculk_sensor.place", "block.sculk_sensor.step",
    "block.sculk_shrieker.break", "block.sculk_shrieker.fall",
    "block.sculk_shrieker.hit", "block.sculk_shrieker.place",
    "block.sculk_shrieker.shriek", "block.sculk_shrieker.step",
    "block.sculk_vein.break", "block.sculk_vein.fall",
    "block.sculk_vein.hit", "block.sculk_vein.place",
    "block.sculk_vein.step",
    "entity.warden.agitated", "entity.warden.ambient", "entity.warden.angry",
    "entity.warden.attack_impact", "entity.warden.death",
    "entity.warden.dig", "entity.warden.emerge", "entity.warden.heartbeat",
    "entity.warden.hurt", "entity.warden.listening",
    "entity.warden.listening_angry", "entity.warden.nearby_close",
    "entity.warden.nearby_closer", "entity.warden.nearby_closest",
    "entity.warden.roar", "entity.warden.sniff", "entity.warden.sonic_boom",
    "entity.warden.sonic_charge", "entity.warden.step",
    "entity.warden.tendril_clicks",
    "music.overworld.deep_dark", "music_disc.5",
    "block.amethyst_block.resonate",
]


def ogg_length(path):
    """Duration of an Ogg Vorbis file: last granule position / sample rate."""
    with open(path, "rb") as f:
        data = f.read()
    # Identification header: sample rate at offset 12 of the vorbis packet
    i = data.find(b"\x01vorbis")
    rate = int.from_bytes(data[i + 12:i + 16], "little")
    last = data.rfind(b"OggS")
    granule = int.from_bytes(data[last + 6:last + 14], "little")
    return granule / rate


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def fetch_sound(files, name):
    """Downloads a sound file missing from the local copy (asset index of
    the version, sounds/index.json)."""
    dst = os.path.join(files, name + ".ogg")
    if os.path.exists(dst):
        return
    import urllib.request
    with open(os.path.join(SRC, "sounds", "index.json")) as f:
        objects = json.load(f)["objects"]
    h = objects["minecraft/sounds/" + name + ".ogg"]["hash"]
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    urllib.request.urlretrieve(
        "https://resources.download.minecraft.net/%s/%s" % (h[:2], h), dst)
    print("downloaded", name)


def copy_sounds():
    with open(os.path.join(SRC, "sounds", "sounds.json")) as f:
        sounds = json.load(f)
    os.makedirs(OUT_SND, exist_ok=True)
    files = os.path.join(SRC, "sounds", "files")
    lines = [
        "-- Generated by tools/mc_deepdark_assets.py from Minecraft's",
        "-- sounds.json: the variants of each sound event. The sound files",
        "-- themselves are local Mojang assets (games/mineclonia/textures/mc_sounds).",
        "return {",
    ]
    for event in SOUND_EVENTS:
        spec = sounds[event]
        variants = []
        for i, e in enumerate(spec["sounds"]):
            if isinstance(e, str):
                e = {"name": e}
            if e.get("type") == "event":
                raise SystemExit("event references are not supported: " + event)
            base = "mcl_mc_" + event.replace(".", "_") + "_%d" % (i + 1)
            fetch_sound(files, e["name"])
            shutil.copyfile(os.path.join(files, e["name"] + ".ogg"),
                            os.path.join(OUT_SND, base + ".ogg"))
            if event.startswith("block."):
                # Node sounds are played by the engine, which picks a
                # random file of the group name.N.ogg
                group = "mcl_mc_" + event.replace(".", "_")
                shutil.copyfile(os.path.join(files, e["name"] + ".ogg"),
                                os.path.join(OUT_SND, "%s.%d.ogg" % (group, i + 1)))
            fields = ["name = " + lua_str(base)]
            for key in ("volume", "pitch", "weight", "attenuation_distance"):
                if key in e:
                    fields.append("%s = %s" % (key, e[key]))
            if e.get("stream"):
                fields.append("stream = true")
                fields.append("length = %.2f" % ogg_length(os.path.join(files, e["name"] + ".ogg")))
            variants.append("\t\t{" + ", ".join(fields) + "},")
        lines.append("\t[%s] = {" % lua_str(event))
        lines += variants
        lines.append("\t},")
    lines.append("}")
    os.makedirs(os.path.dirname(EVENTS_LUA), exist_ok=True)
    with open(EVENTS_LUA, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote %s (%d events)" % (EVENTS_LUA, len(SOUND_EVENTS)))


if __name__ == "__main__":
    copy_textures()
    make_strips()
    copy_sounds()
