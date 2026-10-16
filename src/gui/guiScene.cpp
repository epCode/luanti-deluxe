// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2020 Jean-Patrick Guerrero <jeanpatrick.guerrero@gmail.com>

#include "guiScene.h"

#include <SViewFrustum.h>
#include <AnimatedMeshSceneNode.h>
#include <IVideoDriver.h>
#include <ISceneManager.h>
#include "client/shader.h"
#include "nodedef.h"
#include "porting.h"
#include "client/mesh.h"
#include "client/minecraft_animator.h"
#include "client/renderingengine.h"
#include <cmath>

GUIScene::GUIScene(gui::IGUIEnvironment *env,
		scene::ISceneManager *smgr,
		gui::IGUIElement *parent,
		IShaderSource *shdsrc,
		core::recti rect,
		s32 id)
	: IGUIElement(gui::EGUIET_ELEMENT, env, parent, id, rect)
{
	m_driver = env->getVideoDriver();
	m_smgr = smgr->createNewSceneManager(false);

	m_cam = m_smgr->addCameraSceneNode(0, v3f(0.f, 0.f, -100.f), v3f(0.f));
	m_cam->setFOV(30.f * core::DEGTORAD);

	ShaderFeatures features;
	features.skinning = true;
	u32 shader_id = shdsrc->getShaderRaw("fs_model_shader", true, features);
	m_material_type = shdsrc->getShaderInfo(shader_id).material;
}

GUIScene::~GUIScene()
{
	setMesh(nullptr);

	m_smgr->drop();
}

scene::AnimatedMeshSceneNode *GUIScene::setMesh(scene::IAnimatedMesh *mesh)
{
	if (m_mesh) {
		m_mesh->remove();
		m_mesh = nullptr;
	}
	m_mc_animator.reset();

	if (!mesh)
		return nullptr;

	m_mesh = m_smgr->addAnimatedMeshSceneNode(mesh);
	m_mesh->setPosition(-m_mesh->getBoundingBox().getCenter());
	m_mesh->animateJoints();

	return m_mesh;
}

void GUIScene::setTexture(u32 idx, video::ITexture *texture)
{
	video::SMaterial &material = m_mesh->getMaterial(idx);
	material.MaterialType = m_material_type;
	material.TextureLayers[0].Texture = texture;
	material.FogEnable = false;
	material.TextureLayers[0].MinFilter = video::ETMINF_NEAREST_MIPMAP_NEAREST;
	material.TextureLayers[0].MagFilter = video::ETMAGF_NEAREST;
	material.BackfaceCulling = false;
	material.ZWriteEnable = video::EZW_AUTO;
}

void GUIScene::draw()
{
	m_driver->clearBuffers(video::ECBF_DEPTH);

	// Control rotation speed based on time
	u64 new_time = porting::getTimeMs();
	u64 dtime_ms = 0;
	if (m_last_time != 0)
		dtime_ms = porting::getDeltaMs(m_last_time, new_time);
	m_last_time = new_time;

	core::rect<s32> oldViewPort = m_driver->getViewPort();
	m_driver->setViewPort(getAbsoluteClippingRect());

	if (m_bgcolor != 0) {
		core::recti borderRect =
				Environment->getRootGUIElement()->getAbsoluteClippingRect();
		Environment->getSkin()->draw3DSunkenPane(
			this, m_bgcolor, false, true, borderRect, 0);
	}

	core::dimension2d<s32> size = getAbsoluteClippingRect().getSize();
	m_smgr->getActiveCamera()->setAspectRatio((f32)size.Width / (f32)size.Height);

	if (!m_target) {
		updateCamera(m_smgr->addEmptySceneNode());
		rotateCamera(v3f(0.f));
		m_cam->bindTargetAndRotation(true);
	}

	// Continuous rotation
	if (m_inf_rot)
		rotateCamera(v3f(0.f, -0.03f * (float)dtime_ms, 0.f));

	if (m_initial_rotation && m_mesh) {
		rotateCamera(v3f(m_custom_rot.X, m_custom_rot.Y, 0.f));
		calcOptimalDistance();

		// The Minecraft yaw facing the camera (the model's Z is
		// Minecraft's -Z, Minecraft yaw y faces (-sin y, cos y))
		v3f to_cam = m_cam_pos - m_target_pos;
		m_face_yaw = -std::atan2(to_cam.X, -to_cam.Z) * core::RADTODEG;

		m_initial_rotation = false;
	}

	cameraLoop();
	if (m_mc_animator)
		stepProceduralAnimation(dtime_ms / 1000.0f);
	try {
		m_smgr->drawAll();
	} catch (...) {
		// Don't leave the whole screen squeezed into this element's rect
		m_driver->setViewPort(oldViewPort);
		throw;
	}

	m_driver->setViewPort(oldViewPort);
}

bool GUIScene::OnEvent(const SEvent &event)
{
	if (m_mouse_ctrl && event.EventType == EET_MOUSE_INPUT_EVENT) {
		if (event.MouseInput.Event == EMIE_LMOUSE_PRESSED_DOWN) {
			m_last_pos = v2f((f32)event.MouseInput.X, (f32)event.MouseInput.Y);
			return true;
		} else if (event.MouseInput.Event == EMIE_MOUSE_MOVED) {
			if (event.MouseInput.isLeftPressed()) {
				m_curr_pos = v2f((f32)event.MouseInput.X, (f32)event.MouseInput.Y);

				rotateCamera(v3f(
					m_last_pos.Y - m_curr_pos.Y,
					m_curr_pos.X - m_last_pos.X, 0.f));

				m_last_pos = m_curr_pos;
				return true;
			}
		}
	}

	return gui::IGUIElement::OnEvent(event);
}

void GUIScene::setStyles(const std::array<StyleSpec, StyleSpec::NUM_STATES> &styles)
{
	StyleSpec::State state = StyleSpec::STATE_DEFAULT;
	StyleSpec style = StyleSpec::getStyleFromStatePropagation(styles, state);

	setNotClipped(style.getBool(StyleSpec::NOCLIP, false));
	setBackgroundColor(style.getColor(StyleSpec::BGCOLOR, m_bgcolor));

	m_look_at_cursor = style.getBool(StyleSpec::LOOK_AT_CURSOR, false);
	const bool mc_player = m_mesh &&
			m_mesh->getMesh()->getMeshType() == scene::EAMT_SKINNED &&
			style.get(StyleSpec::PROCEDURAL_ANIMATION, "") == "minecraft_player";
	if (mc_player && !m_mc_animator) {
		m_mc_animator = std::make_unique<MinecraftPlayerAnimator>();
		// Models with slim arms have a joint "Slim_Arms"
		m_mc_slim = m_mesh->getJointNode("Slim_Arms");
		m_mesh->setOnAnimateCallback([this](f32) {
			m_mc_animator->apply(m_mesh);
		});
	} else if (!mc_player && m_mc_animator) {
		m_mc_animator.reset();
		if (m_mesh)
			m_mesh->setOnAnimateCallback(nullptr);
	}
}

std::optional<v2f> GUIScene::project(v3f pos) const
{
	m_cam->updateMatrices();
	core::matrix4 m = m_cam->getProjectionMatrix() * m_cam->getViewMatrix();
	f32 v[4];
	m.transformVect(v, pos);
	if (v[3] <= 0.0f)
		return std::nullopt;
	core::recti rect = getAbsoluteClippingRect();
	return v2f(rect.UpperLeftCorner.X + (v[0] / v[3] + 1.0f) * 0.5f * rect.getWidth(),
			rect.UpperLeftCorner.Y + (1.0f - v[1] / v[3]) * 0.5f * rect.getHeight());
}

void GUIScene::stepProceduralAnimation(f32 dtime)
{
	MinecraftPlayerAnimator::Input in;
	in.slim = m_mc_slim;
	if (m_look_at_cursor) {
		// GuiInventory.drawEntityOnScreen measures the cursor from 50 GUI
		// pixels above the feet, with the player 30 pixels per block.
		// The model has 10 units per block, its feet at its origin.
		m_mesh->updateAbsolutePosition();
		v3f feet = m_mesh->getAbsolutePosition();
		auto feet_px = project(feet);
		auto block_px = project(feet + v3f(0.0f, 10.0f, 0.0f));
		auto eyes_px = project(feet + v3f(0.0f, 10.0f * 50.0f / 30.0f, 0.0f));
		auto *cursor = RenderingEngine::get_raw_device()->getCursorControl();
		if (feet_px && block_px && eyes_px && cursor) {
			f32 per_block = feet_px->Y - block_px->Y;
			if (per_block > 0.0f) {
				v2f c = v2f::from(cursor->getPosition());
				in.inventory_cursor = v2f(eyes_px->X - c.X, eyes_px->Y - c.Y) *
						(30.0f / per_block);
				in.inventory_yaw = m_face_yaw;
			}
		}
	}
	m_mc_animator->step(dtime, in);
}

/**
 * Sets the frame loop range for the mesh
 */
void GUIScene::setFrameLoop(f32 begin, f32 end)
{
	// Rigged meshes without animations (e.g. procedurally animated models)
	// have no track 0 to play.
	if (m_mesh->getMesh()->getTrackCount() == 0)
		return;
	auto &anim = m_mesh->getAnimation().tracks[0];
	anim.setFrameRange(begin, end);
	anim.cur_frame = anim.fps >= 0 ? begin : end;
}

/**
 * Sets the animation speed (FPS) for the mesh
 * @note setFrameLoop() must be called before this
 */
void GUIScene::setAnimationSpeed(f32 speed)
{
	if (m_mesh->getAnimation().tracks.count(0) == 0)
		return;
	m_mesh->getAnimation().tracks.at(0).fps = speed;
}

/* Camera control functions */

inline void GUIScene::calcOptimalDistance()
{
	core::aabbox3df box = m_mesh->getBoundingBox();
	f32 width  = box.MaxEdge.X - box.MinEdge.X;
	f32 height = box.MaxEdge.Y - box.MinEdge.Y;
	f32 depth  = box.MaxEdge.Z - box.MinEdge.Z;
	f32 max_width = width > depth ? width : depth;

	m_cam->updateMatrices(); // Updates the frustum
	const scene::SViewFrustum *f = m_cam->getViewFrustum();
	f32 cam_far = m_cam->getFarValue();
	f32 far_width = core::line3df(f->getFarLeftUp(), f->getFarRightUp()).getLength();
	f32 far_height = core::line3df(f->getFarLeftUp(), f->getFarLeftDown()).getLength();

	core::recti rect = getAbsolutePosition();
	f32 zoomX = rect.getWidth() / max_width;
	f32 zoomY = rect.getHeight() / height;
	f32 dist;

	if (zoomX < zoomY)
		dist = (max_width / (far_width / cam_far)) + (0.5f * max_width);
	else
		dist = (height / (far_height / cam_far)) + (0.5f * max_width);

	m_cam_distance = dist;
	m_update_cam = true;
}

void GUIScene::updateCamera(scene::ISceneNode *target)
{
	m_target = target;
	updateTargetPos();

	m_last_target_pos = m_target_pos;
	updateCameraPos();

	m_update_cam = true;
}

void GUIScene::updateTargetPos()
{
	m_last_target_pos = m_target_pos;
	m_target->updateAbsolutePosition();
	m_target_pos = m_target->getAbsolutePosition();
}

void GUIScene::setCameraRotation(v3f rot)
{
	correctBounds(rot);

	core::matrix4 mat;
	mat.setRotationDegrees(rot);

	m_cam_pos = mat.rotateAndScaleVect(v3f(0.f, 0.f, m_cam_distance));

	m_cam_pos += m_target_pos;
	m_cam->setPosition(m_cam_pos);
	m_update_cam = false;
}

bool GUIScene::correctBounds(v3f &rot)
{
	const float ROTATION_MAX_1 = 60.0f;
	const float ROTATION_MAX_2 = 300.0f;

	// Limit and correct the rotation when needed
	if (rot.X < 90.f) {
		if (rot.X > ROTATION_MAX_1) {
			rot.X = ROTATION_MAX_1;
			return true;
		}
	} else if (rot.X < ROTATION_MAX_2) {
		rot.X = ROTATION_MAX_2;
		return true;
	}

	// Not modified
	return false;
}

void GUIScene::cameraLoop()
{
	updateCameraPos();
	updateTargetPos();

	if (m_target_pos != m_last_target_pos)
		m_update_cam = true;

	if (m_update_cam) {
		m_cam_pos = m_target_pos + (m_cam_pos - m_target_pos).normalize() * m_cam_distance;

		v3f rot = getCameraRotation();
		if (correctBounds(rot))
			setCameraRotation(rot);

		m_cam->setPosition(m_cam_pos);
		m_cam->setTarget(m_target_pos);

		m_update_cam = false;
	}
}
