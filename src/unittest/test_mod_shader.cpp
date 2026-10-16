// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "test.h"

#include "exceptions.h"
#include "mod_shader.h"
#include <sstream>

class TestModShader : public TestBase
{
public:
	TestModShader() { TestManager::registerTestModule(this); }
	const char *getName() { return "TestModShader"; }

	void runTests(IGameDef *gamedef);

	void testSerializeDef();
	void testSerializeUniforms();
	void testInvalidUniformSize();
};

static TestModShader g_test_instance;

void TestModShader::runTests(IGameDef *gamedef)
{
	TEST(testSerializeDef);
	TEST(testSerializeUniforms);
	TEST(testInvalidUniformSize);
}

void TestModShader::testSerializeDef()
{
	ModShaderDef def;
	def.type = ModShaderType::OVERRIDE;
	def.order = -5;
	def.vertex = "void main() {}";
	def.fragment = std::string(70000, 'x'); // longer than a u16 length
	def.files["pixel_shadows.glsl"] = "// include";
	def.textures = {"a.png", "b.png^[invert:rgb"};
	def.uniforms["strength"] = {0.5f};
	def.uniforms["matrix"] = std::vector<f32>(16, 2.0f);

	std::ostringstream os(std::ios::binary);
	def.serialize(os);
	std::istringstream is(os.str(), std::ios::binary);
	ModShaderDef got;
	got.deSerialize(is);

	UASSERT(got.type == ModShaderType::OVERRIDE);
	UASSERTEQ(s16, got.order, -5);
	UASSERTEQ(std::string, got.vertex, def.vertex);
	UASSERTEQ(std::string, got.fragment, def.fragment);
	UASSERT(got.files == def.files);
	UASSERT(got.textures == def.textures);
	UASSERT(got.uniforms == def.uniforms);
}

void TestModShader::testSerializeUniforms()
{
	ModShaderUniforms uniforms;
	uniforms["a"] = {1.0f, 2.0f, 3.0f};
	uniforms["b"] = {-1.0f, 0.0f, 1.0f, 0.25f};

	std::ostringstream os(std::ios::binary);
	serializeModShaderUniforms(os, uniforms);
	std::istringstream is(os.str(), std::ios::binary);
	UASSERT(deSerializeModShaderUniforms(is) == uniforms);
}

void TestModShader::testInvalidUniformSize()
{
	UASSERT(ModShaderDef::isValidUniformSize(1));
	UASSERT(ModShaderDef::isValidUniformSize(4));
	UASSERT(ModShaderDef::isValidUniformSize(9));
	UASSERT(ModShaderDef::isValidUniformSize(16));
	UASSERT(!ModShaderDef::isValidUniformSize(0));
	UASSERT(!ModShaderDef::isValidUniformSize(5));
	UASSERT(!ModShaderDef::isValidUniformSize(17));

	// A malicious server must not get a 5-float uniform through
	ModShaderUniforms uniforms;
	uniforms["bad"] = std::vector<f32>(5, 1.0f);
	std::ostringstream os(std::ios::binary);
	serializeModShaderUniforms(os, uniforms);
	std::istringstream is(os.str(), std::ios::binary);
	EXCEPTION_CHECK(SerializationError, deSerializeModShaderUniforms(is));
}
