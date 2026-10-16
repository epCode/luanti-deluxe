// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once

#include "irrlichttypes.h"
#include "mod_shader.h"
#include <map>
#include <memory>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>

class Client;
class IWritableShaderSource;
class IShaderUniformSetterFactory;

namespace video {
	class ITexture;
}

/*
	Client shaders that the server's mods set for this player
	(see `ObjectRef:set_shader` in lua_api.md).

	Override shaders replace source files of built-in shaders, which are then
	recompiled in place. Post-processing shaders become full-screen passes that
	ModShaderPassesStep (render/secondstage.h) runs after the built-in ones.
*/
class ModShaderManager
{
public:
	struct Pass
	{
		std::string name;
		u32 shader_id;
		s16 order;
		video::ITexture *textures[ModShaderDef::MAX_TEXTURES] = {};
	};

	// Mod uniform values by shader name, read by the uniform setters
	struct UniformStore
	{
		std::unordered_map<std::string, ModShaderUniforms> uniforms;
	};

	ModShaderManager(Client *client);

	void set(const std::string &name, const ModShaderDef &def);
	void remove(const std::string &name);
	// Removes all mod shaders, restoring the built-in ones
	void reset();
	void setUniforms(const std::string &name, const ModShaderUniforms &uniforms);

	/// Active post-processing passes, in the order to run them
	const std::vector<Pass> &getPasses() const { return m_passes; }

	/// Returns (and forgets) messages about shaders that failed to compile,
	/// also those that were built on demand since the last call
	std::vector<std::string> takeErrors();

	/// Uniform setter factory to register with the shader source
	std::unique_ptr<IShaderUniformSetterFactory> createUniformSetterFactory();

	/// Name of the shader that a mod shader defines or overrides
	static std::string getShaderName(const std::string &name, const ModShaderDef &def);

private:
	// Source overrides of a definition, "name_of_shader/filename" -> program
	static std::map<std::string, std::string> getSourceFiles(
			const std::string &name, const ModShaderDef &def);
	// Swaps the sources of `old_def` for those of `new_def` (either may be null)
	void applySources(const std::string &name, const ModShaderDef *old_def,
			const ModShaderDef *new_def);
	void updatePasses();
	void collectErrors();

	Client *m_client;
	IWritableShaderSource *m_shsrc;
	std::map<std::string, ModShaderDef> m_defs;
	// Post-processing shader IDs by pass name; kept after removal for reuse
	std::map<std::string, u32> m_pass_shaders;
	std::vector<Pass> m_passes;
	std::shared_ptr<UniformStore> m_uniforms;
	std::vector<std::string> m_errors;
	// Shaders whose compile errors were reported already
	std::set<std::string> m_reported;
};
