// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "modshaders.h"
#include "client/client.h"
#include "client/camera.h"
#include "client/shader.h"
#include "client/texturesource.h"
#include "gettext.h"
#include "log.h"
#include "porting.h"
#include <ICameraSceneNode.h>
#include <algorithm>
#include <cstring>

namespace {

// (name_of_shader, filename)
typedef std::pair<std::string, std::string> SourceFile;

bool isValidName(const std::string &name)
{
	return !name.empty() && name.find_first_of("/\\") == std::string::npos &&
			name.find("..") == std::string::npos;
}

class ModShaderUniformSetter : public IShaderUniformSetter
{
	std::shared_ptr<ModShaderManager::UniformStore> m_store;
	std::string m_shader;
	Client *m_client;
	u64 m_start_time;
	bool m_is_pass;

	CachedPixelShaderSetting<float, 16> m_view_proj{"mViewProj"};
	CachedPixelShaderSetting<float, 16> m_inv_view_proj{"mInvViewProj"};
	CachedPixelShaderSetting<float> m_elapsed_time{"elapsedTime"};
	CachedPixelShaderSetting<float> m_time_of_day{"timeOfDay"};

public:
	ModShaderUniformSetter(std::shared_ptr<ModShaderManager::UniformStore> store,
			const std::string &shader, Client *client, u64 start_time) :
		m_store(std::move(store)),
		m_shader(shader),
		m_client(client),
		m_start_time(start_time),
		m_is_pass(str_starts_with(shader, MOD_POSTPROCESS_PREFIX))
	{}

	void onSetUniforms(video::IMaterialRendererServices *services) override
	{
		if (m_is_pass)
			setPassUniforms(services);

		if (m_store->uniforms.empty())
			return;
		auto it = m_store->uniforms.find(m_shader);
		if (it == m_store->uniforms.end())
			return;
		for (const auto &[name, values] : it->second) {
			s32 id = services->getPixelShaderConstantID(name.c_str());
			if (id >= 0)
				services->setPixelShaderConstant(id, values.data(), values.size());
		}
	}

private:
	void setPassUniforms(video::IMaterialRendererServices *services)
	{
		// Wraps every hour to keep its precision
		float elapsed = ((porting::getTimeMs() - m_start_time) % 3600000) / 1000.0f;
		m_elapsed_time.set(&elapsed, services);

		float time_of_day = m_client->getEnv().getTimeOfDayF();
		m_time_of_day.set(&time_of_day, services);

		// The world camera, not the transforms of the full-screen quad
		Camera *camera = m_client->getCamera();
		if (!camera || !camera->getCameraNode())
			return;
		auto *camera_node = camera->getCameraNode();
		core::matrix4 view_proj = camera_node->getProjectionMatrix();
		view_proj *= camera_node->getViewMatrix();
		m_view_proj.set(view_proj, services);
		core::matrix4 inv_view_proj;
		if (view_proj.getInverse(inv_view_proj))
			m_inv_view_proj.set(inv_view_proj, services);
	}
};

class ModShaderUniformSetterFactory : public IShaderUniformSetterFactory
{
	std::shared_ptr<ModShaderManager::UniformStore> m_store;
	Client *m_client;
	u64 m_start_time;

public:
	ModShaderUniformSetterFactory(std::shared_ptr<ModShaderManager::UniformStore> store,
			Client *client) :
		m_store(std::move(store)),
		m_client(client),
		m_start_time(porting::getTimeMs())
	{}

	IShaderUniformSetter *create(const std::string &name) override
	{
		return new ModShaderUniformSetter(m_store, name, m_client, m_start_time);
	}
};

} // namespace

ModShaderManager::ModShaderManager(Client *client) :
	m_client(client),
	m_shsrc(client->getShaderSource()),
	m_uniforms(std::make_shared<UniformStore>())
{}

std::unique_ptr<IShaderUniformSetterFactory> ModShaderManager::createUniformSetterFactory()
{
	return std::make_unique<ModShaderUniformSetterFactory>(m_uniforms, m_client);
}

std::string ModShaderManager::getShaderName(const std::string &name, const ModShaderDef &def)
{
	if (def.type == ModShaderType::POSTPROCESS)
		return MOD_POSTPROCESS_PREFIX + name;
	return name;
}

std::map<std::string, std::string> ModShaderManager::getSourceFiles(
		const std::string &name, const ModShaderDef &def)
{
	const std::string shader = getShaderName(name, def);
	std::map<std::string, std::string> files;
	if (!def.vertex.empty())
		files[shader + "/opengl_vertex.glsl"] = def.vertex;
	if (!def.fragment.empty())
		files[shader + "/opengl_fragment.glsl"] = def.fragment;
	if (def.type == ModShaderType::OVERRIDE) {
		for (const auto &[file, source] : def.files) {
			if (isValidName(file))
				files[shader + "/" + file] = source;
		}
	}
	return files;
}

void ModShaderManager::applySources(const std::string &name,
		const ModShaderDef *old_def, const ModShaderDef *new_def)
{
	std::map<std::string, std::string> old_files, new_files;
	if (old_def)
		old_files = getSourceFiles(name, *old_def);
	if (new_def)
		new_files = getSourceFiles(name, *new_def);

	std::set<std::string> changed;
	auto set_override = [&](const std::string &key, const std::string &program) {
		// Shader names contain no slashes, see isValidName
		size_t slash = key.find('/');
		m_shsrc->setSourceOverride(key.substr(0, slash), key.substr(slash + 1), program);
		changed.insert(key);
	};
	for (const auto &it : old_files) {
		if (new_files.count(it.first) == 0)
			set_override(it.first, "");
	}
	for (const auto &it : new_files) {
		auto old = old_files.find(it.first);
		if (old == old_files.end() || old->second != it.second)
			set_override(it.first, it.second);
	}

	if (!changed.empty())
		m_shsrc->rebuildShadersUsing(changed);
}

void ModShaderManager::set(const std::string &name, const ModShaderDef &def)
{
	if (!isValidName(name)) {
		warningstream << "Ignoring mod shader with invalid name \"" << name
			<< "\"" << std::endl;
		return;
	}

	auto it = m_defs.find(name);
	if (it != m_defs.end() && it->second.type != def.type) {
		remove(name);
		it = m_defs.end();
	}

	infostream << "ModShaderManager: setting \"" << name << "\"" << std::endl;
	m_reported.erase(getShaderName(name, def));
	applySources(name, it != m_defs.end() ? &it->second : nullptr, &def);
	m_uniforms->uniforms[getShaderName(name, def)] = def.uniforms;
	m_defs[name] = def;

	if (def.type == ModShaderType::POSTPROCESS && m_pass_shaders.count(name) == 0) {
		try {
			// Built with the sources set above, see applySources
			m_pass_shaders[name] = m_shsrc->getShader(getShaderName(name, def),
					ShaderConstants(), video::EMT_SOLID);
		} catch (ShaderException &e) {
			errorstream << "ModShaderManager: " << e.what() << std::endl;
		}
	}

	updatePasses();
	collectErrors();
}

void ModShaderManager::remove(const std::string &name)
{
	auto it = m_defs.find(name);
	if (it == m_defs.end())
		return;

	infostream << "ModShaderManager: removing \"" << name << "\"" << std::endl;
	m_reported.erase(getShaderName(name, it->second));
	applySources(name, &it->second, nullptr);
	m_uniforms->uniforms.erase(getShaderName(name, it->second));
	m_defs.erase(it);

	updatePasses();
	collectErrors();
}

void ModShaderManager::reset()
{
	infostream << "ModShaderManager: resetting all shaders" << std::endl;

	// Restore all built-in sources with a single rebuild
	std::set<std::string> changed;
	for (const auto &[name, def] : m_defs) {
		for (const auto &it : getSourceFiles(name, def)) {
			size_t slash = it.first.find('/');
			m_shsrc->setSourceOverride(it.first.substr(0, slash),
					it.first.substr(slash + 1), "");
			changed.insert(it.first);
		}
	}
	if (!changed.empty())
		m_shsrc->rebuildShadersUsing(changed);

	m_defs.clear();
	m_reported.clear();
	m_uniforms->uniforms.clear();
	updatePasses();
	collectErrors();
}

void ModShaderManager::setUniforms(const std::string &name, const ModShaderUniforms &uniforms)
{
	auto it = m_defs.find(name);
	if (it == m_defs.end())
		return;

	auto &stored = m_uniforms->uniforms[getShaderName(name, it->second)];
	for (const auto &[uniform, values] : uniforms) {
		it->second.uniforms[uniform] = values;
		stored[uniform] = values;
	}
}

void ModShaderManager::updatePasses()
{
	m_passes.clear();
	for (const auto &[name, def] : m_defs) {
		if (def.type != ModShaderType::POSTPROCESS)
			continue;
		auto shader = m_pass_shaders.find(name);
		if (shader == m_pass_shaders.end())
			continue;

		Pass pass;
		pass.name = name;
		pass.shader_id = shader->second;
		pass.order = def.order;
		for (size_t i = 0; i < def.textures.size() && i < ModShaderDef::MAX_TEXTURES; i++) {
			if (!def.textures[i].empty())
				pass.textures[i] = m_client->getTextureSource()->getTexture(def.textures[i]);
		}
		m_passes.push_back(pass);
	}

	// m_defs is sorted by name, so equal orders stay sorted by name
	std::stable_sort(m_passes.begin(), m_passes.end(),
		[](const Pass &a, const Pass &b) { return a.order < b.order; });
}

void ModShaderManager::collectErrors()
{
	// Every variant of a shader fails, and variants are built on demand:
	// report each shader once
	std::set<std::string> failed;
	for (const auto &shader : m_shsrc->takeOverrideErrors()) {
		if (m_reported.insert(shader).second)
			failed.insert(shader);
	}

	for (const auto &shader : failed) {
		if (str_starts_with(shader, MOD_POSTPROCESS_PREFIX)) {
			std::string name = shader.substr(strlen(MOD_POSTPROCESS_PREFIX));
			m_errors.push_back(fmtgettext("Shader \"%s\" from the server failed to "
					"compile and is disabled. See debug.txt for details.", name.c_str()));
		} else {
			m_errors.push_back(fmtgettext("Shader override of \"%s\" from the server "
					"failed to compile, using the built-in shader. See debug.txt for details.",
					shader.c_str()));
		}
	}
}

std::vector<std::string> ModShaderManager::takeErrors()
{
	collectErrors();
	return std::move(m_errors);
}
