// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

/*
	Minecraft liquid flow for nodes with liquid_model = "minecraft".

	A port of Java Edition's FlowingFluid / WaterFluid / LavaFluid and the
	tick triggers of LiquidBlock (26.x):
	- every change at or next to a liquid node (LiquidBlock.onPlace and
	  neighborChanged) schedules a tick for it, tick_delay game ticks later;
	  a pending tick for the same node and content is never duplicated
	  (LevelChunkTicks.ticksPerPosition)
	- game ticks run at 20 Hz; the ticks due in a game tick are collected
	  first and run in scheduling order (LevelTicks)
	- a tick recomputes a flowing node from its neighbours (getNewLiquid),
	  then spreads down or towards the nearest way down within
	  slope_find_distance nodes (spread / getSpread / getSlopeDistance)

	Levels: param2 & 7 is Minecraft's fluid amount (1..7), falling liquid
	is LIQUID_FLOW_DOWN_MASK | 7 (amount 8), sources are amount 8.

	Luanti mapping of Minecraft block properties:
	- canHoldAnyFluid: air, floodable nodes and liquid nodes
	- isSolid (below a new source): walkable
	- beforeDestroyingBlock: the replaced node's on_flood
	- a different liquid below can only be flowed into if it has on_flood
	  (lava onto water: WaterFluid.canBeReplacedWith + LavaFluid.spreadTo)
	- LiquidBlock.shouldSpreadLiquid: the node's on_liquid_update
	- canPassThroughWall: the collision boxes of both nodes
	- LiquidBlockContainer / SimpleWaterloggedBlock: nodes with a
	  waterlogged_alternative; a waterlogged node (waterlogged_liquid) holds
	  a source of its liquid and ticks as that source
*/

#include "servermap.h"
#include "nodedef.h"
#include "mapblock.h"
#include "serverenvironment.h"
#include "scripting_server.h"
#include "voxelalgorithms.h"
#include "waterlogging.h"
#include "settings.h"
#include "profiler.h"
#include "util/directiontables.h"
#include <unordered_map>

namespace {

// Seconds per Minecraft game tick
constexpr float LIQUID_GAME_TICK = 0.05f;
// Game ticks run in one server step at most; a server that lags further
// behind lets liquids slow down instead of piling up work
constexpr int LIQUID_MAX_CATCH_UP_TICKS = 20;

// Direction.Plane.HORIZONTAL: NORTH, EAST, SOUTH, WEST
const v3s16 HORIZONTAL[4] = {
	v3s16(0, 0, -1), v3s16(1, 0, 0), v3s16(0, 0, 1), v3s16(-1, 0, 0),
};
enum { NORTH, EAST, SOUTH, WEST };
// getSpread returns an EnumMap, which iterates in Direction ordinal order
const int SPREAD_ORDER[4] = { NORTH, SOUTH, WEST, EAST };
// Level.updateNeighborsAt order (NeighborUpdater.UPDATE_ORDER), after the
// changed node itself (onPlace)
const v3s16 UPDATE_ORDER[7] = {
	v3s16(0, 0, 0),
	v3s16(-1, 0, 0), v3s16(1, 0, 0), v3s16(0, -1, 0),
	v3s16(0, 1, 0), v3s16(0, 0, -1), v3s16(0, 0, 1),
};

inline int opposite(int dir)
{
	return (dir + 2) & 3;
}

// FluidState
struct Fluid
{
	// Source content of the liquid; CONTENT_IGNORE: no liquid (empty)
	content_t type = CONTENT_IGNORE;
	bool source = false;
	bool falling = false;
	u8 amount = 0;

	bool empty() const { return type == CONTENT_IGNORE; }

	bool operator==(const Fluid &o) const
	{
		return type == o.type && source == o.source &&
			falling == o.falling && amount == o.amount;
	}
};

const LiquidFlowParams &flow_params_at(const ContentFeatures &f, s16 y)
{
	for (const LiquidFlowZone &zone : f.liquid_flow_zones) {
		if (y >= zone.y_min && y <= zone.y_max)
			return zone.params;
	}
	return f.liquid_flow;
}

bool is_minecraft_liquid(const ContentFeatures &f)
{
	return f.liquid_model == LIQUID_MODEL_MINECRAFT && f.liquid_type != LIQUID_NONE;
}

} // namespace

class MinecraftLiquidTicker
{
public:
	MinecraftLiquidTicker(ServerMap *map, ServerEnvironment *env,
			std::map<v3s16, MapBlock*> &modified_blocks) :
		m_map(map),
		m_ndef(map->getNodeDefManager()),
		m_env(env),
		m_modified_blocks(modified_blocks)
	{}

	// FlowingFluid.tick
	void tick(v3s16 pos, MapNode n)
	{
		const ContentFeatures &f = m_ndef->get(node_liquid_content(m_ndef, n));
		m_source = f.liquid_alternative_source_id;
		m_flowing = f.liquid_alternative_flowing_id;
		const ContentFeatures &fsource = m_ndef->get(m_source);
		m_params = flow_params_at(fsource, pos.Y);
		m_renewable = fsource.liquid_renewable;

		Fluid fluid = fluidAt(n);
		if (!fluid.source) {
			Fluid fresh = getNewLiquid(pos, n);
			if (fresh.empty()) {
				fluid = fresh;
				n = MapNode(CONTENT_AIR);
				setLiquidNode(pos, n);
			} else if (!(fresh == fluid)) {
				fluid = fresh;
				n = makeNode(fresh);
				setLiquidNode(pos, n);
				m_map->scheduleMinecraftLiquidTick(pos, n.getContent(),
						m_params.tick_delay);
			}
		}
		spread(pos, n, fluid);
	}

	// Lighting, falling nodes and callbacks for everything changed
	void finish()
	{
		if (m_changed.empty())
			return;
		voxalgo::update_lighting_nodes(m_map, m_changed, m_modified_blocks);
		if (!m_env)
			return;
		for (const v3s16 &p : m_check_for_falling)
			m_env->getScriptIface()->check_for_falling(p);
		m_env->getScriptIface()->on_liquid_transformed(m_changed);
	}

private:
	MapNode getNode(v3s16 p)
	{
		return m_map->getNode(p);
	}

	// BlockState.getFluidState; waterlogged nodes hold a source
	Fluid fluidAt(MapNode n) const
	{
		const ContentFeatures &f = m_ndef->get(n);
		Fluid fluid;
		if (f.liquid_type == LIQUID_SOURCE) {
			fluid.type = f.liquid_alternative_source_id;
			fluid.source = true;
			fluid.amount = 8;
		} else if (f.liquid_type == LIQUID_FLOWING) {
			fluid.type = f.liquid_alternative_source_id;
			fluid.falling = n.param2 & LIQUID_FLOW_DOWN_MASK;
			fluid.amount = fluid.falling ? 8 : (n.param2 & LIQUID_LEVEL_MASK);
		} else if (f.isWaterlogged()) {
			fluid.type = m_ndef->get(f.waterlogged_liquid_id).liquid_alternative_source_id;
			fluid.source = true;
			fluid.amount = 8;
		}
		return fluid;
	}

	bool isSame(const Fluid &fluid) const
	{
		return !fluid.empty() && fluid.type == m_source;
	}

	bool isSourceBlockOfThisType(const Fluid &fluid) const
	{
		return isSame(fluid) && fluid.source;
	}

	// BlockState.getCollisionShape, cached per node state
	const NodeShape &shapeAt(v3s16 p, MapNode n)
	{
		static const NodeShape empty;
		const ContentFeatures &f = m_ndef->get(n);
		if (!f.walkable)
			return empty;
		u8 neighbors = 0;
		if (f.drawtype == NDT_NODEBOX && f.node_box.type == NODEBOX_CONNECTED)
			neighbors = n.getNeighbors(p, m_map);
		u32 key = n.getContent() | (u32)n.param2 << 16 | (u32)neighbors << 24;
		auto it = m_shapes.find(key);
		if (it != m_shapes.end())
			return it->second;
		return m_shapes.emplace(key, node_collision_shape(m_ndef, n, neighbors))
				.first->second;
	}

	// FlowingFluid.canPassThroughWall: whether liquid can pass between
	// source and the target next to it in direction dir
	bool canPassThroughWall(v3s16 dir, v3s16 source_pos, MapNode source,
			v3s16 target_pos, MapNode target)
	{
		const NodeShape &target_shape = shapeAt(target_pos, target);
		if (target_shape.kind == NodeShape::BLOCK)
			return false;
		const NodeShape &source_shape = shapeAt(source_pos, source);
		if (source_shape.kind == NodeShape::BLOCK)
			return false;
		if (source_shape.kind == NodeShape::EMPTY && target_shape.kind == NodeShape::EMPTY)
			return true;
		return !shapes_merged_face_occludes(source_shape, target_shape, dir);
	}

	// FlowingFluid.canHoldAnyFluid: air, floodable nodes, liquid nodes and
	// liquid containers (LiquidBlockContainer)
	bool canHoldAnyFluid(MapNode n) const
	{
		if (n.getContent() == CONTENT_AIR)
			return true;
		const ContentFeatures &f = m_ndef->get(n);
		return f.liquid_type != LIQUID_NONE || f.floodable || f.isLiquidContainer();
	}

	// SimpleWaterloggedBlock.canPlaceLiquid: a container only takes a
	// source of the liquid its waterlogged form holds
	bool canPlaceLiquid(const ContentFeatures &f, const Fluid &fluid) const
	{
		if (!fluid.source)
			return false;
		const ContentFeatures &wet = f.isWaterlogged() ? f :
				m_ndef->get(f.waterlogged_alternative_id);
		return wet.isWaterlogged() && m_ndef->get(wet.waterlogged_liquid_id)
				.liquid_alternative_source_id == fluid.type;
	}

	// FlowingFluid.canHoldSpecificFluid
	bool canHoldSpecificFluid(MapNode n, const Fluid &fluid) const
	{
		const ContentFeatures &f = m_ndef->get(n);
		return f.isLiquidContainer() ? canPlaceLiquid(f, fluid) : true;
	}

	bool canMaybePassThrough(v3s16 pos, MapNode n, v3s16 dir, v3s16 test_pos,
			MapNode test, const Fluid &test_fluid)
	{
		return !isSourceBlockOfThisType(test_fluid) && canHoldAnyFluid(test) &&
				canPassThroughWall(dir, pos, n, test_pos, test);
	}

	bool canPassThrough(v3s16 pos, MapNode n, v3s16 dir, v3s16 test_pos,
			MapNode test, const Fluid &test_fluid)
	{
		return canMaybePassThrough(pos, n, dir, test_pos, test, test_fluid) &&
				canHoldSpecificFluid(test, makeFlowing(1, false));
	}

	bool isWaterHole(v3s16 top_pos, MapNode top, v3s16 bottom_pos, MapNode bottom)
	{
		if (!canPassThroughWall(v3s16(0, -1, 0), top_pos, top, bottom_pos, bottom))
			return false;
		if (isSame(fluidAt(bottom)))
			return true;
		return canHoldAnyFluid(bottom) && canHoldSpecificFluid(bottom, makeFlowing(1, false));
	}

	// FluidState.canBeReplacedWith for a flow of this liquid
	bool canBeReplacedWith(MapNode n, const Fluid &fluid, bool down) const
	{
		if (fluid.empty())
			return true;
		if (isSame(fluid))
			return false;
		return down && m_ndef->get(n).has_on_flood;
	}

	Fluid makeSource() const
	{
		Fluid fluid;
		fluid.type = m_source;
		fluid.source = true;
		fluid.amount = 8;
		return fluid;
	}

	Fluid makeFlowing(u8 amount, bool falling) const
	{
		Fluid fluid;
		fluid.type = m_source;
		fluid.falling = falling;
		fluid.amount = amount;
		return fluid;
	}

	MapNode makeNode(const Fluid &fluid) const
	{
		if (fluid.empty())
			return MapNode(CONTENT_AIR);
		if (fluid.source)
			return MapNode(m_source);
		u8 param2 = fluid.falling ? (LIQUID_FLOW_DOWN_MASK | LIQUID_LEVEL_MAX) :
				(fluid.amount & LIQUID_LEVEL_MASK);
		return MapNode(m_flowing, 0, param2);
	}

	// FlowingFluid.getNewLiquid: what the liquid in n at pos should be
	Fluid getNewLiquid(v3s16 pos, MapNode n)
	{
		int highest = 0;
		int sources = 0;
		for (const v3s16 &dir : HORIZONTAL) {
			v3s16 p2 = pos + dir;
			MapNode n2 = getNode(p2);
			Fluid fluid = fluidAt(n2);
			if (isSame(fluid) && canPassThroughWall(dir, pos, n, p2, n2)) {
				if (fluid.source)
					sources++;
				highest = std::max<int>(highest, fluid.amount);
			}
		}

		if (sources >= 2 && m_renewable) {
			MapNode below = getNode(pos + v3s16(0, -1, 0));
			if (m_ndef->get(below).walkable || isSourceBlockOfThisType(fluidAt(below)))
				return makeSource();
		}

		v3s16 above_pos = pos + v3s16(0, 1, 0);
		MapNode above = getNode(above_pos);
		if (isSame(fluidAt(above)) &&
				canPassThroughWall(v3s16(0, 1, 0), pos, n, above_pos, above))
			return makeFlowing(8, true);

		int amount = highest - m_params.drop_off;
		return amount <= 0 ? Fluid() : makeFlowing(amount, false);
	}

	int sourceNeighborCount(v3s16 pos)
	{
		int count = 0;
		for (const v3s16 &dir : HORIZONTAL) {
			if (isSourceBlockOfThisType(fluidAt(getNode(pos + dir))))
				count++;
		}
		return count;
	}

	// FlowingFluid.spread
	void spread(v3s16 pos, MapNode n, const Fluid &fluid)
	{
		if (fluid.empty())
			return;

		v3s16 below_pos = pos + v3s16(0, -1, 0);
		MapNode below = getNode(below_pos);
		Fluid below_fluid = fluidAt(below);
		if (canMaybePassThrough(pos, n, v3s16(0, -1, 0), below_pos, below, below_fluid)) {
			Fluid fresh = getNewLiquid(below_pos, below);
			if (canBeReplacedWith(below, below_fluid, true) &&
					canHoldSpecificFluid(below, fresh)) {
				spreadTo(below_pos, fresh);
				if (sourceNeighborCount(pos) >= 3)
					spreadToSides(pos, n, fluid);
				return;
			}
		}

		if (fluid.source || !isWaterHole(pos, n, below_pos, below))
			spreadToSides(pos, n, fluid);
	}

	void spreadToSides(v3s16 pos, MapNode n, const Fluid &fluid)
	{
		int neighbor = fluid.falling ? 7 : fluid.amount - m_params.drop_off;
		if (neighbor <= 0)
			return;

		Fluid spreads[4];
		bool has_spread[4];
		getSpread(pos, n, spreads, has_spread);
		for (int dir : SPREAD_ORDER) {
			if (has_spread[dir])
				spreadTo(pos + HORIZONTAL[dir], spreads[dir]);
		}
	}

	// FlowingFluid.SpreadContext: caches nodes and holes on the plane of
	// the spreading node
	class SpreadContext
	{
	public:
		SpreadContext(MinecraftLiquidTicker *ticker, v3s16 origin) :
			m_ticker(ticker), m_origin(origin)
		{}

		MapNode getNode(v3s16 p)
		{
			auto it = m_nodes.find(key(p));
			if (it != m_nodes.end())
				return it->second;
			MapNode n = m_ticker->getNode(p);
			m_nodes.emplace(key(p), n);
			return n;
		}

		bool isHole(v3s16 p)
		{
			auto it = m_holes.find(key(p));
			if (it != m_holes.end())
				return it->second;
			MapNode n = getNode(p);
			v3s16 below = p + v3s16(0, -1, 0);
			bool hole = m_ticker->isWaterHole(p, n, below, m_ticker->getNode(below));
			m_holes.emplace(key(p), hole);
			return hole;
		}

	private:
		u16 key(v3s16 p) const
		{
			return (((p.X - m_origin.X + 128) & 0xFF) << 8) |
				((p.Z - m_origin.Z + 128) & 0xFF);
		}

		MinecraftLiquidTicker *m_ticker;
		v3s16 m_origin;
		std::unordered_map<u16, MapNode> m_nodes;
		std::unordered_map<u16, bool> m_holes;
	};

	// FlowingFluid.getSpread: the sides with the shortest way down
	void getSpread(v3s16 pos, MapNode n, Fluid spreads[4], bool has_spread[4])
	{
		int lowest = 1000;
		std::fill(has_spread, has_spread + 4, false);
		SpreadContext context(this, pos);

		for (int dir = 0; dir < 4; dir++) {
			v3s16 test_pos = pos + HORIZONTAL[dir];
			MapNode test = getNode(test_pos);
			Fluid test_fluid = fluidAt(test);
			if (!canMaybePassThrough(pos, n, HORIZONTAL[dir], test_pos, test, test_fluid))
				continue;

			Fluid fresh = getNewLiquid(test_pos, test);
			if (!canHoldSpecificFluid(test, fresh))
				continue;

			int distance = context.isHole(test_pos) ? 0 :
					getSlopeDistance(context, test_pos, test, 1, opposite(dir));

			if (distance < lowest)
				std::fill(has_spread, has_spread + 4, false);

			if (distance <= lowest) {
				if (canBeReplacedWith(test, test_fluid, false)) {
					spreads[dir] = fresh;
					has_spread[dir] = true;
				}
				lowest = distance;
			}
		}
	}

	int getSlopeDistance(SpreadContext &context, v3s16 pos, MapNode n, int pass, int from)
	{
		int lowest = 1000;
		for (int dir = 0; dir < 4; dir++) {
			if (dir == from)
				continue;
			v3s16 test_pos = pos + HORIZONTAL[dir];
			MapNode test = context.getNode(test_pos);
			if (!canPassThrough(pos, n, HORIZONTAL[dir], test_pos, test, fluidAt(test)))
				continue;
			if (context.isHole(test_pos))
				return pass;
			if (pass < m_params.slope_find_distance) {
				int distance = getSlopeDistance(context, test_pos, test, pass + 1,
						opposite(dir));
				lowest = std::min(lowest, distance);
			}
		}
		return lowest;
	}

	// FlowingFluid.spreadTo
	void spreadTo(v3s16 pos, const Fluid &fluid)
	{
		MapNode old = getNode(pos);
		const ContentFeatures &fold = m_ndef->get(old);
		if (fold.isLiquidContainer()) {
			// SimpleWaterloggedBlock.placeLiquid
			if (!fold.isWaterlogged() && canPlaceLiquid(fold, fluid)) {
				MapNode wet = old;
				wet.setContent(fold.waterlogged_alternative_id);
				setLiquidNode(pos, wet);
			}
			return;
		}
		MapNode n = makeNode(fluid);
		if (old.getContent() != CONTENT_AIR && m_env && fold.has_on_flood &&
				m_env->getScriptIface()->node_on_flood(pos, old, n))
			return;
		setLiquidNode(pos, n);
	}

	// Level.setBlock(pos, n, UPDATE_ALL)
	void setLiquidNode(v3s16 pos, MapNode n)
	{
		bool valid;
		MapNode old = m_map->getNode(pos, &valid);
		if (!valid || (old.getContent() == n.getContent() && old.param2 == n.param2))
			return;

		// Lighting is updated for all changes in finish()
		ContentLightingFlags f = m_ndef->getLightingFlags(n);
		n.setLight(LIGHTBANK_DAY, 0, f);
		n.setLight(LIGHTBANK_NIGHT, 0, f);
		m_map->setNode(pos, n);

		v3s16 blockpos = getNodeBlockPos(pos);
		MapBlock *block = m_map->getBlockNoCreateNoEx(blockpos);
		if (block) {
			m_modified_blocks[blockpos] = block;
			if (old.getContent() == CONTENT_AIR || n.getContent() == CONTENT_AIR)
				block->expireIsAirCache();
		}

		// Keep the first old node of a position for the lighting update
		if (m_changed_index.emplace(pos, m_changed.size()).second)
			m_changed.emplace_back(pos, old);

		if (!m_ndef->get(n).isLiquid() &&
				m_ndef->get(getNode(pos + v3s16(0, 1, 0))).floats)
			m_check_for_falling.push_back(pos);

		m_map->minecraftLiquidNodeChanged(pos);
	}

	ServerMap *m_map;
	const NodeDefManager *m_ndef;
	ServerEnvironment *m_env;
	std::map<v3s16, MapBlock*> &m_modified_blocks;

	// The liquid being ticked
	content_t m_source = CONTENT_IGNORE;
	content_t m_flowing = CONTENT_IGNORE;
	LiquidFlowParams m_params;
	bool m_renewable = false;

	std::unordered_map<u32, NodeShape> m_shapes;

	std::vector<std::pair<v3s16, MapNode>> m_changed;
	std::unordered_map<v3s16, size_t> m_changed_index;
	std::vector<v3s16> m_check_for_falling;
};

void ServerMap::scheduleMinecraftLiquidTick(v3s16 p, content_t c, u16 delay)
{
	if (!m_liquid_tick_keys.insert(liquidTickKey(p, c)).second)
		return;
	m_liquid_ticks.push(LiquidTick{m_liquid_game_tick + delay, m_liquid_tick_seq++, p, c});
}

u16 ServerMap::minecraftLiquidTickDelay(v3s16 p, MapNode n) const
{
	const ContentFeatures &fsource = m_nodedef->get(m_nodedef->get(
			node_liquid_content(m_nodedef, n)).liquid_alternative_source_id);
	return flow_params_at(fsource, p.Y).tick_delay;
}

void ServerMap::minecraftLiquidUpdate(v3s16 p, MapNode n)
{
	// LiquidBlock.shouldSpreadLiquid (e.g. lava next to water hardening)
	if (m_nodedef->get(n).isLiquid() && m_nodedef->get(n).has_on_liquid_update && m_liquid_env &&
			m_liquid_env->getScriptIface()->node_on_liquid_update(p, n))
		return;
	// Waterlogged nodes tick as their liquid's source
	scheduleMinecraftLiquidTick(p, node_liquid_content(m_nodedef, n),
			minecraftLiquidTickDelay(p, n));
}

bool ServerMap::isMinecraftLiquidNode(MapNode n) const
{
	content_t c = node_liquid_content(m_nodedef, n);
	return c != CONTENT_IGNORE && is_minecraft_liquid(m_nodedef->get(c));
}

void ServerMap::minecraftLiquidNodeChanged(v3s16 p)
{
	// Liquids react with LiquidBlock.onPlace / neighborChanged, waterlogged
	// nodes with updateShape
	for (const v3s16 &dir : UPDATE_ORDER) {
		v3s16 p2 = p + dir;
		bool valid;
		MapNode n = getNode(p2, &valid);
		if (valid && isMinecraftLiquidNode(n))
			minecraftLiquidUpdate(p2, n);
	}
}

void ServerMap::stepMinecraftLiquids(float dtime,
		std::map<v3s16, MapBlock*> &modified_blocks)
{
	const u32 tick_limit = std::max(1, g_settings->getS32("liquid_loop_max"));
	int ticks_run = 0;
	m_liquid_tick_timer += dtime;
	while (m_liquid_tick_timer >= LIQUID_GAME_TICK) {
		if (ticks_run++ >= LIQUID_MAX_CATCH_UP_TICKS) {
			m_liquid_tick_timer = 0.0f;
			break;
		}
		m_liquid_tick_timer -= LIQUID_GAME_TICK;
		m_liquid_game_tick++;

		if (m_liquid_ticks.empty() || m_liquid_ticks.top().due > m_liquid_game_tick)
			continue;

		ScopeProfiler sp(g_profiler, "Server: liquid ticks");

		// LevelTicks.collectTicks: everything due now, in scheduling order
		std::vector<LiquidTick> due;
		while (!m_liquid_ticks.empty() && due.size() < tick_limit &&
				m_liquid_ticks.top().due <= m_liquid_game_tick) {
			due.push_back(m_liquid_ticks.top());
			m_liquid_tick_keys.erase(liquidTickKey(due.back().pos, due.back().content));
			m_liquid_ticks.pop();
		}

		MinecraftLiquidTicker ticker(this, m_liquid_env, modified_blocks);
		for (const LiquidTick &t : due) {
			bool valid;
			MapNode n = getNode(t.pos, &valid);
			// ServerLevel.tickFluid: only if the liquid is still there
			if (!valid || node_liquid_content(m_nodedef, n) != t.content ||
					!isMinecraftLiquidNode(n))
				continue;

			// Unloaded neighbours would look like holes or walls: wait for them
			bool loaded = true;
			for (const v3s16 &dir : g_6dirs) {
				MapNode n2 = getNode(t.pos + dir, &valid);
				if (!valid || n2.getContent() == CONTENT_IGNORE) {
					loaded = false;
					break;
				}
			}
			if (!loaded) {
				scheduleMinecraftLiquidTick(t.pos, t.content,
						minecraftLiquidTickDelay(t.pos, n));
				continue;
			}

			ticker.tick(t.pos, n);
		}
		ticker.finish();
	}
}
