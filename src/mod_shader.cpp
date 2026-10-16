// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "mod_shader.h"
#include "exceptions.h"
#include "util/serialize.h"

void serializeModShaderUniforms(std::ostream &os, const ModShaderUniforms &uniforms)
{
	writeU16(os, uniforms.size());
	for (const auto &[name, values] : uniforms) {
		os << serializeString16(name);
		writeU8(os, values.size());
		for (f32 v : values)
			writeF32(os, v);
	}
}

ModShaderUniforms deSerializeModShaderUniforms(std::istream &is)
{
	ModShaderUniforms uniforms;
	u16 count = readU16(is);
	for (u16 i = 0; i < count; i++) {
		std::string name = deSerializeString16(is);
		u8 size = readU8(is);
		if (!ModShaderDef::isValidUniformSize(size))
			throw SerializationError("invalid mod shader uniform size");
		std::vector<f32> values(size);
		for (f32 &v : values)
			v = readF32(is);
		uniforms[name] = std::move(values);
	}
	return uniforms;
}

void ModShaderDef::serialize(std::ostream &os) const
{
	writeU8(os, 0); // version
	writeU8(os, (u8)type);
	writeS16(os, order);
	os << serializeString32(vertex);
	os << serializeString32(fragment);
	writeU16(os, files.size());
	for (const auto &[name, source] : files) {
		os << serializeString16(name);
		os << serializeString32(source);
	}
	writeU8(os, textures.size());
	for (const auto &texture : textures)
		os << serializeString16(texture);
	serializeModShaderUniforms(os, uniforms);
}

void ModShaderDef::deSerialize(std::istream &is)
{
	if (readU8(is) != 0)
		throw SerializationError("unsupported mod shader version");
	u8 t = readU8(is);
	if (t > (u8)ModShaderType::OVERRIDE)
		throw SerializationError("invalid mod shader type");
	type = (ModShaderType)t;
	order = readS16(is);
	vertex = deSerializeString32(is);
	fragment = deSerializeString32(is);
	files.clear();
	u16 file_count = readU16(is);
	for (u16 i = 0; i < file_count; i++) {
		std::string name = deSerializeString16(is);
		files[name] = deSerializeString32(is);
	}
	textures.clear();
	u8 texture_count = readU8(is);
	for (u8 i = 0; i < texture_count; i++)
		textures.push_back(deSerializeString16(is));
	if (textures.size() > MAX_TEXTURES)
		textures.resize(MAX_TEXTURES);
	uniforms = deSerializeModShaderUniforms(is);
}
