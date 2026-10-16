// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "menuDecor.h"
#include "client/fontengine.h"
#include "client/renderingengine.h"
#include "client/texturesource.h"
#include "settings.h"
#include "util/numeric.h"
#include "util/string.h"
#include <IVideoDriver.h>
#include <S3DVertex.h>
#include <SMaterial.h>
#include <IGUIFont.h>
#include <cmath>

/*
	MenuPanorama
*/

// Corners of each face (top-left, top-right, bottom-right, bottom-left) as seen
// from the centre of the cube, with +Z in front and +Y up
static const v3f FACE_CORNERS[6][4] = {
	{{-1, 1, 1}, { 1, 1, 1}, { 1,-1, 1}, {-1,-1, 1}}, // front
	{{ 1, 1, 1}, { 1, 1,-1}, { 1,-1,-1}, { 1,-1, 1}}, // right
	{{ 1, 1,-1}, {-1, 1,-1}, {-1,-1,-1}, { 1,-1,-1}}, // back
	{{-1, 1,-1}, {-1, 1, 1}, {-1,-1, 1}, {-1,-1,-1}}, // left
	{{-1, 1,-1}, { 1, 1,-1}, { 1, 1, 1}, {-1, 1, 1}}, // up
	{{-1,-1, 1}, { 1,-1, 1}, { 1,-1,-1}, {-1,-1,-1}}, // down
};

bool MenuPanorama::setFaces(ISimpleTextureSource *tsrc, const std::vector<std::string> &paths)
{
	clear();
	if (paths.size() != 6)
		return false;
	video::ITexture *faces[6];
	for (int i = 0; i < 6; i++) {
		faces[i] = tsrc->getTexture(paths[i]);
		if (!faces[i])
			return false;
	}
	std::copy(faces, faces + 6, m_faces);
	return true;
}

void MenuPanorama::clear()
{
	std::fill(m_faces, m_faces + 6, nullptr);
}

void MenuPanorama::draw(video::IVideoDriver *driver, f32 dtime)
{
	if (!isActive())
		return;

	m_time += dtime;
	m_yaw = std::fmod(m_yaw + m_speed * dtime, 360.0f);
	// Look slightly down, swaying gently
	const f32 pitch = (12.0f + 6.0f * std::sin(m_time * 0.07f)) * core::DEGTORAD;
	const f32 yaw = m_yaw * core::DEGTORAD;

	const auto screen = driver->getScreenSize();
	core::matrix4 projection, view;
	projection.buildProjectionMatrixPerspectiveFovLH(85.0f * core::DEGTORAD,
			(f32)screen.Width / std::max(1U, screen.Height), 0.05f, 10.0f);
	const v3f target(std::sin(yaw) * std::cos(pitch), -std::sin(pitch),
			std::cos(yaw) * std::cos(pitch));
	view.buildCameraLookAtMatrixLH(v3f(0, 0, 0), target, v3f(0, 1, 0));

	driver->setTransform(video::ETS_PROJECTION, projection);
	driver->setTransform(video::ETS_VIEW, view);
	driver->setTransform(video::ETS_WORLD, core::IdentityMatrix);

	video::SMaterial mat;
	mat.ZBuffer = video::ECFN_DISABLED;
	mat.ZWriteEnable = video::EZW_OFF;
	mat.BackfaceCulling = false;
	mat.FogEnable = false;
	mat.TextureLayers[0].TextureWrapU = video::ETC_CLAMP_TO_EDGE;
	mat.TextureLayers[0].TextureWrapV = video::ETC_CLAMP_TO_EDGE;
	mat.TextureLayers[0].MinFilter = video::ETMINF_LINEAR_MIPMAP_LINEAR;
	mat.TextureLayers[0].MagFilter = video::ETMAGF_LINEAR;

	static const u16 indices[6] = {0, 1, 2, 0, 2, 3};
	static const v2f uvs[4] = {{0, 0}, {1, 0}, {1, 1}, {0, 1}};
	const video::SColor white(255, 255, 255, 255);
	for (int f = 0; f < 6; f++) {
		mat.setTexture(0, m_faces[f]);
		driver->setMaterial(mat);
		video::S3DVertex vertices[4];
		for (int i = 0; i < 4; i++)
			vertices[i] = video::S3DVertex(FACE_CORNERS[f][i], v3f(0, 0, 0), white, uvs[i]);
		driver->drawIndexedTriangleList(vertices, 4, indices, 2);
	}
}

/*
	MenuSplash
*/

MenuSplash::~MenuSplash()
{
	freeTexture();
}

void MenuSplash::freeTexture()
{
	if (m_texture && m_driver)
		m_driver->removeTexture(m_texture);
	m_texture = nullptr;
	m_rendered_size = 0;
}

void MenuSplash::set(const std::string &text, video::SColor color)
{
	m_text = utf8_to_wide(text);
	m_color = color;
	m_time = 0.0f;
	freeTexture();
}

void MenuSplash::draw(video::IVideoDriver *driver, const core::recti &header, f32 dtime)
{
	if (m_text.empty())
		return;
	m_driver = driver;
	m_time += dtime;

	const auto screen = driver->getScreenSize();
	const bool have_header = header.getWidth() > 0 && header.getHeight() > 0;

	// Text height follows the header (or the window), in real pixels
	f32 text_px = have_header ? header.getHeight() * 0.32f : screen.Height * 0.05f;
	text_px = rangelim(text_px, 10.0f, 80.0f);
	const f32 font_scale = RenderingEngine::getDisplayDensity() *
			g_settings->getFloat("gui_scaling");
	const u32 font_size = std::max<u32>(6, std::round(text_px / std::max(font_scale, 0.1f)));

	if (!m_texture || font_size != m_rendered_size) {
		freeTexture();
		gui::IGUIFont *font = g_fontengine->getFont(font_size, FM_Standard);
		if (!font)
			return;
		const auto dim = font->getDimension(m_text.c_str());
		const s32 shadow = std::max<s32>(1, dim.Height / 10);
		m_text_size = core::dimension2du(dim.Width + shadow + 2, dim.Height + shadow + 2);
		m_texture = driver->addRenderTargetTexture(m_text_size, "menu_splash",
				video::ECF_A8R8G8B8);
		if (!m_texture)
			return;
		m_rendered_size = font_size;

		driver->setRenderTarget(m_texture, video::ECBF_COLOR, video::SColor(0, 0, 0, 0));
		// Darker copy underneath as a drop shadow
		const video::SColor shadow_color(m_color.getAlpha(), m_color.getRed() / 4,
				m_color.getGreen() / 4, m_color.getBlue() / 4);
		const core::recti rect(0, 0, m_text_size.Width, m_text_size.Height);
		font->draw(m_text.c_str(), rect + v2s32(shadow, shadow), shadow_color);
		font->draw(m_text.c_str(), rect, m_color);
		driver->setRenderTarget(nullptr, 0);
	}

	// Below the right end of the header, tilted up and pulsing
	v2f center;
	f32 max_width;
	if (have_header) {
		center = v2f(header.LowerRightCorner.X - header.getWidth() * 0.1f,
				header.LowerRightCorner.Y - header.getHeight() * 0.1f);
		max_width = header.getWidth() * 0.55f;
	} else {
		center = v2f(screen.Width * 0.72f, screen.Height * 0.18f);
		max_width = screen.Width * 0.4f;
	}
	f32 scale = 1.0f - 0.06f * std::fabs(std::sin(m_time * core::PI * 2.0f));
	scale *= std::min(1.0f, max_width / m_text_size.Width);

	const f32 hw = m_text_size.Width * scale / 2, hh = m_text_size.Height * scale / 2;
	const f32 angle = -20.0f * core::DEGTORAD;
	const f32 c = std::cos(angle), s = std::sin(angle);
	const v2f corners[4] = {{-hw, -hh}, {hw, -hh}, {hw, hh}, {-hw, hh}};
	// Render targets are stored upside down
	const v2f uvs[4] = {{0, 1}, {1, 1}, {1, 0}, {0, 0}};
	const video::SColor white(255, 255, 255, 255);
	video::S3DVertex vertices[4];
	for (int i = 0; i < 4; i++) {
		const v2f p = center + v2f(corners[i].X * c - corners[i].Y * s,
				corners[i].X * s + corners[i].Y * c);
		vertices[i] = video::S3DVertex(p.X, p.Y, 0, 0, 0, 0, white, uvs[i].X, uvs[i].Y);
	}

	video::SMaterial mat;
	mat.MaterialType = video::EMT_TRANSPARENT_ALPHA_CHANNEL;
	mat.setTexture(0, m_texture);
	mat.TextureLayers[0].MinFilter = video::ETMINF_LINEAR_MIPMAP_NEAREST;
	mat.TextureLayers[0].MagFilter = video::ETMAGF_LINEAR;
	driver->setMaterial(mat);
	static const u16 indices[6] = {0, 1, 2, 0, 2, 3};
	driver->draw2DVertexPrimitiveList(vertices, 4, indices, 2);
}
