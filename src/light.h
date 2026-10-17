// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2013 celeron55, Perttu Ahola <celeron55@gmail.com>

#pragma once
#include <cassert>
#include "config.h"
#include "irrlichttypes.h"

/*
	Lower level lighting stuff
*/

/*
	Light levels.

	Nodes may emit and receive light levels from 0 to LIGHT_LIMIT. Levels up
	to LIGHT_MAX are the classic ones; brighter levels reach further and are
	rendered brighter than LIGHT_MAX (up to about twice as bright), see
	decode_light_hdr().

	Direct sunlight is stored as LIGHT_SUN, which is above every artificial
	level, but it only spreads sideways as LIGHT_MAX (see diminish_light())
	and is reported to games as LIGHT_SUN_LEVEL.
*/

// Brightest classic light; sunlight spreads sideways with this level.
// If changed, this constant as defined in builtin/game/constants.lua must
// also be changed.
#define LIGHT_MAX 14
// Level reported for direct sunlight (MapNode::getLight())
#define LIGHT_SUN_LEVEL 15
// Brightest light a node may emit or receive
#define LIGHT_LIMIT 60
// Stored light value of direct sunlight
#define LIGHT_SUN 61

/*
	param1 layout of nodes with light: bits 0-5 hold the day bank and
	bits 6-11 the night bank.
*/
#define LIGHT_BANK_BITS 6
#define LIGHT_BANK_MASK 0x3F

inline u16 pack_light(u8 day, u8 night)
{
	return (day & LIGHT_BANK_MASK) | ((night & LIGHT_BANK_MASK) << LIGHT_BANK_BITS);
}

inline u8 unpack_light_day(u16 param1)
{
	return param1 & LIGHT_BANK_MASK;
}

inline u8 unpack_light_night(u16 param1)
{
	return (param1 >> LIGHT_BANK_BITS) & LIGHT_BANK_MASK;
}

// Stored light that a node gives to its neighbors
inline u8 diminish_light(u8 light)
{
	if (light == LIGHT_SUN)
		return LIGHT_MAX;
	return light > 0 ? light - 1 : 0;
}

// Level as reported to games: direct sunlight becomes LIGHT_SUN_LEVEL
inline u8 light_level(u8 stored_light)
{
	return stored_light == LIGHT_SUN ? LIGHT_SUN_LEVEL : stored_light;
}

/*
	Light bank layout.

	Classic layout (default): the day bank holds max(sunlight, artificial light)
	and the night bank holds artificial light only.

	Separate sky light layout (game.conf `separate_sky_light = true`): the day
	bank holds sky light only and the night bank holds block (artificial) light
	only, like Minecraft's sky and block light.
	MapNode::getLight(LIGHTBANK_DAY, ...) keeps reporting max(sky, block) so
	gameplay code and the classic renderer see the same values as before; the
	light propagation code and the Minecraft renderer read the raw banks.

	Set once by the server from its game, and by a client from the server's
	announcement before any map data is used.
*/
extern bool g_separate_sky_light;

// Brightest light a node may emit
inline u8 max_light_source()
{
	return LIGHT_LIMIT;
}

/*
	Light bank values in the param1 format used before extended light levels
	(4 bits per bank, the day bank holding LIGHT_SUN_LEVEL for sunlight).
	Used for old map data and protocols, and for the VoxelManip light data
	Lua API. Brighter levels are reduced to the classic maximum.
*/
inline u8 legacy_light_from_stored(u8 light, bool day_bank)
{
	if (light == LIGHT_SUN)
		return day_bank ? LIGHT_SUN_LEVEL : LIGHT_MAX;
	// The night (block light) bank could hold 15 with separate sky light
	u8 cap = !day_bank && g_separate_sky_light ? LIGHT_SUN_LEVEL : LIGHT_MAX;
	return light > cap ? cap : light;
}

inline u8 legacy_light_to_stored(u8 light, bool day_bank)
{
	light &= 0x0F;
	if (day_bank && light == LIGHT_SUN_LEVEL)
		return LIGHT_SUN;
	return light;
}

inline u8 legacy_pack_light(u16 param1)
{
	return legacy_light_from_stored(unpack_light_day(param1), true) |
		(legacy_light_from_stored(unpack_light_night(param1), false) << 4);
}

inline u16 legacy_unpack_light(u8 legacy)
{
	return pack_light(legacy_light_to_stored(legacy & 0x0F, true),
		legacy_light_to_stored(legacy >> 4, false));
}

#if IS_CLIENT_BUILD

/**
 * \internal
 *
 * \warning DO NOT USE this directly; it is here simply so that decode_light()
 * can be inlined.
 *
 * Array size is #LIGHT_SUN + 1
 *
 * The array is a lookup table to convert the internal representation of light
 * (brightness) to the display brightness. Levels up to LIGHT_SUN_LEVEL map to
 * 0..255; brighter (extended) levels go above that, see LIGHT_HDR_MAX.
 *
 */
extern const u16 *light_decode_table;

// Brightest value decode_light_hdr() may return
#define LIGHT_HDR_MAX 510

// 0 <= light <= LIGHT_SUN
// 0 <= return value <= LIGHT_HDR_MAX
inline u16 decode_light_hdr(u8 light)
{
	if (light > LIGHT_SUN)
		light = LIGHT_SUN;
	return light_decode_table[light];
}

// Like decode_light_hdr(), but limited to the classic range
// 0 <= return value <= 255
inline u8 decode_light(u8 light)
{
	u16 v = decode_light_hdr(light);
	return v > 255 ? 255 : v;
}

// 0.0 <= light <= 1.0
// 0.0 <= return value <= 1.0
float decode_light_f(float light_f);

// Update light value table using the specified gamma
void set_light_curve(float gamma);

/*
	Shape of the brightness curve above LIGHT_SUN_LEVEL:
	0 at LIGHT_SUN_LEVEL, rising with diminishing steps to 1 at LIGHT_LIMIT.
	The same shape is used by the lightmap shaders (lightmapOverbright()).
*/
float light_overbright_shape(float level);

#endif

// 0 <= daylight_factor <= 1000
// 0 <= lightday, lightnight <= LIGHT_LIMIT (levels as reported to games)
// 0 <= return value <= LIGHT_LIMIT
inline u8 blend_light(u32 daylight_factor, u8 lightday, u8 lightnight)
{
	u32 c = 1000;
	u32 l = ((daylight_factor * lightday + (c - daylight_factor) * lightnight)) / c;
	if (l > LIGHT_LIMIT)
		l = LIGHT_LIMIT;
	return l;
}
