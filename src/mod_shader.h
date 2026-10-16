// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once

#include "irrlichttypes.h"
#include <iostream>
#include <map>
#include <string>
#include <vector>

// Client shaders that mods set per player
// (see `ObjectRef:set_shader` and friends in lua_api.md)

enum class ModShaderType : u8
{
	// Full-screen pass over the final image, after the built-in post-processing
	POSTPROCESS,
	// Replaces the source files of a built-in shader (e.g. "nodes_shader")
	OVERRIDE,
};

// Uniform name -> 1, 2, 3, 4, 9 or 16 floats (float, vec2-4, mat3, mat4)
typedef std::map<std::string, std::vector<f32>> ModShaderUniforms;

struct ModShaderDef
{
	ModShaderType type = ModShaderType::POSTPROCESS;
	// Post-processing passes run in ascending order (ties: by name)
	s16 order = 0;
	// GLSL sources, empty = the built-in one
	std::string vertex;
	std::string fragment;
	// Override: further source files of the shader by file name,
	// for files that other shaders `#include` (e.g. "pixel_shadows.glsl")
	std::map<std::string, std::string> files;
	// Post-processing: textures bound to texture2 and texture3
	std::vector<std::string> textures;
	ModShaderUniforms uniforms;

	static constexpr size_t MAX_TEXTURES = 2;
	// A uniform may hold up to a mat4
	static constexpr size_t MAX_UNIFORM_SIZE = 16;
	static bool isValidUniformSize(size_t size)
	{
		return (size >= 1 && size <= 4) || size == 9 || size == 16;
	}

	void serialize(std::ostream &os) const;
	void deSerialize(std::istream &is);
};

void serializeModShaderUniforms(std::ostream &os, const ModShaderUniforms &uniforms);
ModShaderUniforms deSerializeModShaderUniforms(std::istream &is);

// TOCLIENT_MOD_SHADER actions
enum ModShaderAction : u8
{
	MOD_SHADER_SET,
	MOD_SHADER_REMOVE,
	MOD_SHADER_RESET,
	MOD_SHADER_SET_UNIFORMS,
};
