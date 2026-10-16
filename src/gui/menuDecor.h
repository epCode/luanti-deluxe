// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once

#include "irrlichttypes.h"
#include <SColor.h>
#include <rect.h>
#include <dimension2d.h>
#include <string>
#include <vector>
#include <IVideoDriver.h>

class ISimpleTextureSource;

// Slowly rotating cube-map background for the main menu, like Minecraft's
// title screen. Faces use Minecraft's panorama_0..5 order:
// front, right, back, left, up, down.
class MenuPanorama
{
public:
	bool isActive() const { return m_faces[0] != nullptr; }
	// Loads all six faces; clears the panorama and returns false if one is missing
	bool setFaces(ISimpleTextureSource *tsrc, const std::vector<std::string> &paths);
	void clear();
	void setSpeed(f32 degrees_per_second) { m_speed = degrees_per_second; }
	void draw(video::IVideoDriver *driver, f32 dtime);

private:
	video::ITexture *m_faces[6] = {};
	f32 m_speed = 1.5f;
	f32 m_yaw = 0.0f;
	f32 m_time = 0.0f;
};

// Tilted, pulsing text at the corner of the menu header (Minecraft's splash text)
class MenuSplash
{
public:
	~MenuSplash();
	void set(const std::string &text, video::SColor color);
	bool isActive() const { return !m_text.empty(); }
	// header: where the header image was drawn, empty if there is none
	void draw(video::IVideoDriver *driver, const core::recti &header, f32 dtime);

private:
	void freeTexture();

	std::wstring m_text;
	video::SColor m_color;
	video::IVideoDriver *m_driver = nullptr;
	video::ITexture *m_texture = nullptr;
	// Font size and text the texture was rendered for
	u32 m_rendered_size = 0;
	core::dimension2du m_text_size;
	f32 m_time = 0.0f;
};
