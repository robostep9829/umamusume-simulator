@tool
extends CompositorEffect
class_name MotionBlurEffect

## Full-screen camera motion blur implemented as a fragment-pipeline
## compositor effect (no storage image access, Mobile-renderer safe).
##
## The screen-space velocity of every pixel is re-derived from the depth
## buffer and the difference between this frame's and the previous frame's
## camera matrices, then the resolved color buffer is integrated along that
## velocity vector.
##
## The velocity is normalized to a fixed exposure time, so the blur looks the
## same regardless of the real frame rate. Depth is read straight from the
## multisampled depth attachment on the Mobile renderer (it never resolves
## depth for compositor effects).
##
## The shader lives in motion_blur.glsl. Authoring-time tuning (shutter angle,
## sample count, threshold) is compiled into it as constants;
## MotionBlurUniforms packs the per-frame push constants and the reprojection
## uniform buffer.

const _SHADER_PATH := "res://environment/compositor/motion_blur/motion_blur.glsl"
## Shader versions declared by the #[versions] section of motion_blur.glsl.
const _SHADER_VERSION := "default"
const _SHADER_VERSION_MSAA := "msaa"
const _SHADER_VERSION_DEBUG := "debug"
const _SHADER_VERSION_DEBUG_MSAA := "debug_msaa"

const _BLIT_VERTEX_SOURCE: String = """
#version 450
layout(location = 0) out vec2 uv_interp;
void main() {
	const vec2 triangle[3] = vec2[3](vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0));
	vec2 in_pos = triangle[gl_VertexIndex];
	uv_interp = in_pos * 0.5 + 0.5;
	gl_Position = vec4(in_pos, 0.0, 1.0);
}
"""

const _BLIT_FRAG_SOURCE := """
#version 450
precision highp float;
layout(location = 0) in vec2 uv_interp;
layout(location = 0) out vec4 out_color;
layout(set = 0, binding = 0) uniform sampler2D blur_tex;
void main() {
	out_color = textureLod(blur_tex, uv_interp, 0.0);
}
"""

var rd: RenderingDevice = null

## Tint the pixels the blur touches instead of applying it: red intensity is
## the sampled arc length relative to MB_MAX_RADIUS_PX.
@export var debug_view: bool = false

var _uniforms := MotionBlurUniforms.new()

var _shader: RID = RID()
var _shader_msaa_depth: bool = false
var _shader_debug: bool = false
var _pipeline: RID = RID()
var _pipeline_format: int = -1
var _vertex_array: RID = RID()
var _vertex_format: int = -1
var _color_sampler: RID = RID()
var _depth_sampler: RID = RID()
var _reprojection_buffer: RID = RID()
var _blit_shader: RID = RID()
var _blit_pipeline: RID = RID()
var _blit_pipeline_format: int = -1

# Reused across frames and views. Creating these framebuffers per frame leaked
# one RenderingDevice framebuffer per pass, which ran the game out of memory
# after a couple of minutes on Android.
var _result_fbs: Array[RID] = []
var _result_fb_views: Array[RID] = []
var _blit_fbs: Array[RID] = []
var _blit_fb_colors: Array[RID] = []

var _prev_transforms: Array[Transform3D] = []
var _prev_ticks: int = -1


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	# Depth is sampled directly (resolved or MSAA), so no resolved depth needed.
	access_resolved_depth = false
	rd = RenderingServer.get_rendering_device()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and rd:
		# Freeing the shader frees the dependent pipeline as well.
		if _shader.is_valid():
			rd.free_rid(_shader)
		if _reprojection_buffer.is_valid():
			rd.free_rid(_reprojection_buffer)
		if _color_sampler.is_valid():
			rd.free_rid(_color_sampler)
		if _depth_sampler.is_valid():
			rd.free_rid(_depth_sampler)
		if _vertex_array.is_valid():
			rd.free_rid(_vertex_array)
		# The rendering device graph owns framebuffers created through
		# framebuffer_create; freeing them here double-frees at teardown.
		if _blit_pipeline.is_valid():
			rd.free_rid(_blit_pipeline)
		if _blit_shader.is_valid():
			rd.free_rid(_blit_shader)


## Loads the precompiled vertex + fragment stages from motion_blur.glsl.
## Returns true once the shader is valid. The file provides normal and debug
## versions, each with a resolved-depth and a multisampled-depth variant.
func _create_shader(msaa_depth: bool) -> bool:
	if _shader.is_valid() and _shader_msaa_depth == msaa_depth and _shader_debug == debug_view:
		return true
	if not rd:
		return false

	if _shader.is_valid():
		rd.free_rid(_shader)
		_shader = RID()
		_pipeline = RID()
		_pipeline_format = -1

	var shader_file := load(_SHADER_PATH) as RDShaderFile
	if not shader_file:
		push_error("MotionBlurEffect: cannot load %s" % _SHADER_PATH)
		return false
	if not shader_file.base_error.is_empty():
		push_error("MotionBlurEffect shader parse error: %s" % shader_file.base_error)
		return false

	var version := _shader_version(msaa_depth)
	var spirv: RDShaderSPIRV = shader_file.get_spirv(version)
	if not spirv:
		push_error("MotionBlurEffect: shader version '%s' is missing" % version)
		return false
	for message: String in [spirv.compile_error_vertex, spirv.compile_error_fragment]:
		if not message.is_empty():
			push_error("MotionBlurEffect shader compile error: %s" % message)
			return false

	_shader = rd.shader_create_from_spirv(spirv)
	_shader_msaa_depth = msaa_depth
	_shader_debug = debug_view
	return _shader.is_valid()


func _shader_version(msaa_depth: bool) -> String:
	if debug_view:
		return _SHADER_VERSION_DEBUG_MSAA if msaa_depth else _SHADER_VERSION_DEBUG
	return _SHADER_VERSION_MSAA if msaa_depth else _SHADER_VERSION


func _create_resources(msaa_depth: bool) -> bool:
	if not _create_shader(msaa_depth):
		return false

	if not _vertex_array.is_valid():
		# The fullscreen triangle is hardcoded in the vertex shader
		# (gl_VertexIndex); only an empty vertex format/array is required
		# so the pipeline can be created and a draw issued.
		_vertex_format = rd.vertex_format_create([])
		_vertex_array = rd.vertex_array_create(3, _vertex_format, [])
		if not _vertex_array.is_valid():
			return false

	if not _reprojection_buffer.is_valid():
		var color_state := RDSamplerState.new()
		color_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		color_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		color_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_color_sampler = rd.sampler_create(color_state)

		var depth_state := RDSamplerState.new()
		depth_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		depth_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
		depth_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
		_depth_sampler = rd.sampler_create(depth_state)

		_reprojection_buffer = rd.uniform_buffer_create(
			_uniforms.to_reprojection_bytes().size(), PackedByteArray(), 0
		)
		if not _reprojection_buffer.is_valid():
			return false

	return true


## Builds one reprojection matrix per blur tap by interpolating the camera pose
## between the previous and the current frame (exposure scaled to 1/60 s).
## Rotating the camera then moves samples along their true arc instead of a
## straight chord, which removes the corner jaggies of a single-vector blur.
## Returns false on the first frame for a view (no history yet).
func _update_reprojection(
	view: int, view_count: int, scene_data: RenderSceneData, fps_scale: float
) -> bool:
	var current_projection: Projection = scene_data.get_view_projection(view)
	var current_transform: Transform3D = scene_data.get_cam_transform()

	if view >= _prev_transforms.size():
		# No history yet: record this frame and skip the blur.
		_prev_transforms.resize(view_count)
		_prev_transforms[view] = current_transform
		return false

	var previous_transform: Transform3D = _prev_transforms[view]
	_prev_transforms[view] = current_transform

	# Extrapolate the previous pose to a fixed 1/60 s exposure. Interpolating
	# from the current pose to this target keeps rotation on an arc.
	var current_rotation := Quaternion(current_transform.basis.orthonormalized())
	var previous_rotation := Quaternion(previous_transform.basis.orthonormalized())
	var rotation_delta := previous_rotation * current_rotation.inverse()
	var target_rotation := current_rotation
	var delta_angle := rotation_delta.get_angle()
	if delta_angle > 0.000001:
		# get_axis() is not guaranteed to be unit length for small angles, and
		# Quaternion(axis, angle) rejects non-normalized axes.
		var axis := rotation_delta.get_axis()
		if axis.length_squared() > 0.0:
			target_rotation = Quaternion(
				axis.normalized(), delta_angle * fps_scale
			) * current_rotation
	var target_origin := (
		current_transform.origin
		+ (previous_transform.origin - current_transform.origin) * fps_scale
	)

	var samples := MotionBlurUniforms.SAMPLE_COUNT
	var inverse_projection: Projection = current_projection.inverse()
	for i in range(MotionBlurUniforms.MAX_REPROJECTION_STEPS):
		var step_projection: Projection
		if i < samples:
			# steps[0] is the oldest pose, steps[samples-1] is the current
			# frame (identity). The shader integrates 0..samples-2 and uses the
			# base color as the current sample.
			var tau := 1.0 - float(i) / float(samples - 1)
			var pose := Transform3D(
				Basis(current_rotation.slerp(target_rotation, tau)),
				current_transform.origin.lerp(target_origin, tau)
			)
			step_projection = (
				current_projection
				* Projection(pose.affine_inverse() * current_transform)
				* inverse_projection
			)
		else:
			step_projection = Projection.IDENTITY
		_uniforms.set_step(i, step_projection)
	_uniforms.set_inverse_projection(inverse_projection)

	var payload := _uniforms.to_reprojection_bytes()
	rd.buffer_update(_reprojection_buffer, 0, payload.size(), payload)
	return true


func _ensure_pipeline(framebuffer_format: int) -> bool:
	if _pipeline.is_valid() and _pipeline_format == framebuffer_format:
		return true
	if _pipeline.is_valid():
		rd.free_rid(_pipeline)
		_pipeline = RID()

	var rasterizer := RDPipelineRasterizationState.new()
	rasterizer.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED

	var multisample := RDPipelineMultisampleState.new()
	multisample.sample_count = RenderingDevice.TEXTURE_SAMPLES_1

	var depth_stencil := RDPipelineDepthStencilState.new()

	var blend := RDPipelineColorBlendState.new()
	var blend_attachment := RDPipelineColorBlendStateAttachment.new()
	blend.attachments = [blend_attachment]

	_pipeline = rd.render_pipeline_create(
		_shader,
		framebuffer_format,
		_vertex_format,
		RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,
		rasterizer,
		multisample,
		depth_stencil,
		blend,
		0,
		0,
		[]
	)
	if _pipeline.is_valid():
		_pipeline_format = framebuffer_format
	return _pipeline.is_valid()


func _ensure_blit_pipeline(framebuffer_format: int) -> bool:
	if _blit_pipeline.is_valid() and _blit_pipeline_format == framebuffer_format:
		return true
	if _blit_pipeline.is_valid():
		rd.free_rid(_blit_pipeline)
		_blit_pipeline = RID()

	if not _blit_shader.is_valid():
		var blit_source := RDShaderSource.new()
		blit_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
		blit_source.source_vertex = _BLIT_VERTEX_SOURCE
		blit_source.source_fragment = _BLIT_FRAG_SOURCE

		var blit_spirv := rd.shader_compile_spirv_from_source(blit_source)
		if blit_spirv.compile_error_vertex.length() or blit_spirv.compile_error_fragment.length():
			printerr("MotionBlurEffect blit shader compile error: [v]=",
				blit_spirv.compile_error_vertex, " [f]=",
				blit_spirv.compile_error_fragment)
			return false

		_blit_shader = rd.shader_create_from_spirv(blit_spirv)
		if not _blit_shader.is_valid():
			return false

	var rasterizer := RDPipelineRasterizationState.new()
	rasterizer.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED

	var multisample := RDPipelineMultisampleState.new()
	multisample.sample_count = RenderingDevice.TEXTURE_SAMPLES_1

	var depth_stencil := RDPipelineDepthStencilState.new()

	# Disable blending entirely: the destination becomes exactly the source.
	var blend_attachment := RDPipelineColorBlendStateAttachment.new()
	blend_attachment.src_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
	blend_attachment.dst_color_blend_factor = RenderingDevice.BLEND_FACTOR_ZERO
	blend_attachment.src_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
	blend_attachment.dst_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ZERO
	blend_attachment.color_blend_op = RenderingDevice.BLEND_OP_ADD
	blend_attachment.alpha_blend_op = RenderingDevice.BLEND_OP_ADD
	blend_attachment.write_r = true
	blend_attachment.write_g = true
	blend_attachment.write_b = true
	blend_attachment.write_a = true
	var blend := RDPipelineColorBlendState.new()
	blend.attachments = [blend_attachment]

	_blit_pipeline = rd.render_pipeline_create(
		_blit_shader,
		framebuffer_format,
		_vertex_format,
		RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,
		rasterizer,
		multisample,
		depth_stencil,
		blend,
		0,
		0,
		[]
	)
	if _blit_pipeline.is_valid():
		_blit_pipeline_format = framebuffer_format
	return _blit_pipeline.is_valid()


## Returns a cached framebuffer for `view`, recreating it only when its
## attachment changes (a viewport resize). One array pair is kept per pass.
func _view_framebuffer(
	framebuffers: Array[RID], attachments: Array[RID], view: int, attachment: RID
) -> RID:
	while framebuffers.size() <= view:
		framebuffers.append(RID())
		attachments.append(RID())
	if framebuffers[view].is_valid() and attachments[view] == attachment:
		return framebuffers[view]
	# The old framebuffer is left to the rendering device graph; freeing it here
	# can double-free when the graph has already retired the attachment.
	framebuffers[view] = rd.framebuffer_create([attachment])
	attachments[view] = attachment
	return framebuffers[view]


func _render_callback(p_effect_callback_type: int, p_render_data: RenderData) -> void:
	if p_effect_callback_type != effect_callback_type:
		return
	if not rd:
		return

	var scene_buffers: RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
	var scene_data: RenderSceneData = p_render_data.get_render_scene_data()
	if not scene_buffers or not scene_data:
		return

	var msaa_depth: bool = scene_buffers.get_msaa_3d() != RenderingServer.VIEWPORT_MSAA_DISABLED
	if not rd or not _create_resources(msaa_depth):
		return

	var size: Vector2i = scene_buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return

	var view_count := scene_buffers.get_view_count()

	# Exposure normalization: the reprojected velocity is a per-frame delta,
	# so at very high FPS it shrinks below the 1 px gate and blur disappears.
	# Scale it so the effective exposure time is 1/60 s regardless of the
	# real frame rate (clamped, since wall-clock delta is unreliable in
	# movie-writer mode / hitches).
	var fps_scale: float = 1.0
	if _prev_ticks > 0:
		var dt: float = float(Time.get_ticks_usec() - _prev_ticks) / 1e6
		if dt > 0.0001:
			fps_scale = clampf((1.0 / 60.0) / dt, 1.0 / 6.0, 8.0)
	_prev_ticks = Time.get_ticks_usec()

	_uniforms.raster_size = Vector2(size)
	_uniforms.set_focus(MotionBlurFocus.get_focus())
	var push_constants := _uniforms.to_push_constants()

	var color_format: int = rd.texture_get_format(scene_buffers.get_color_texture()).format
	var result_texture: RID = scene_buffers.create_texture(
		"motion_blur", "result", color_format,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT,
		RenderingDevice.TEXTURE_SAMPLES_1, size, view_count, 1, false, false
	)
	if not result_texture.is_valid():
		return

	for view: int in range(view_count):
		if not _update_reprojection(view, view_count, scene_data, fps_scale):
			continue

		var depth_rid: RID = scene_buffers.get_depth_layer(view, msaa_depth)
		if not depth_rid.is_valid():
			continue

		var color_rid: RID = scene_buffers.get_color_layer(view)
		if not color_rid.is_valid():
			continue

		var result_view: RID = scene_buffers.get_texture_slice("motion_blur", "result", view, 0, 1, 1)
		if not result_view.is_valid():
			continue

		# During editor/game teardown the callback can still receive scene
		# buffers whose textures are already gone. Binding one fails
		# uniform_set_create and leaves a broken set in the cache.
		if not rd.texture_is_valid(color_rid) or not rd.texture_is_valid(depth_rid):
			continue
		if not rd.texture_is_valid(result_view):
			continue

		# Pass 1: sample the resolved color + depth buffers, write blurred
		# output into our own texture (reading and writing the same
		# framebuffer attachment is not allowed).
		var result_fb: RID = _view_framebuffer(
			_result_fbs, _result_fb_views, view, result_view
		)
		if not result_fb.is_valid():
			continue
		if not _ensure_pipeline(rd.framebuffer_get_format(result_fb)):
			continue

		# Set 0: resolved color + depth as sampler2D uniforms.
		var color_uniform := RDUniform.new()
		color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		color_uniform.binding = 0
		color_uniform.add_id(_color_sampler)
		color_uniform.add_id(color_rid)

		var depth_uniform := RDUniform.new()
		depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		depth_uniform.binding = 1
		depth_uniform.add_id(_depth_sampler)
		depth_uniform.add_id(depth_rid)

		var sampler_set := UniformSetCacheRD.get_cache(_shader, 0, [color_uniform, depth_uniform])

		# Set 1: per-frame reprojection matrix uniform.
		var reproj_uniform := RDUniform.new()
		reproj_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		reproj_uniform.binding = 0
		reproj_uniform.add_id(_reprojection_buffer)
		var reproj_set := UniformSetCacheRD.get_cache(_shader, 1, [reproj_uniform])

		var draw_list := rd.draw_list_begin(result_fb)
		rd.draw_list_bind_render_pipeline(draw_list, _pipeline)
		rd.draw_list_bind_vertex_array(draw_list, _vertex_array)
		rd.draw_list_bind_uniform_set(draw_list, sampler_set, 0)
		rd.draw_list_bind_uniform_set(draw_list, reproj_set, 1)
		rd.draw_list_set_push_constant(draw_list, push_constants, push_constants.size())
		rd.draw_list_draw(draw_list, false, 1)
		rd.draw_list_end()

		# Pass 2: blit the blurred result back into the resolved color buffer
		# with blending disabled (strict source replacement).
		var blit_fb: RID = _view_framebuffer(
			_blit_fbs, _blit_fb_colors, view, color_rid
		)
		if not blit_fb.is_valid():
			continue
		if not _ensure_blit_pipeline(rd.framebuffer_get_format(blit_fb)):
			continue

		var blit_uniform := RDUniform.new()
		blit_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		blit_uniform.binding = 0
		blit_uniform.add_id(_color_sampler)
		blit_uniform.add_id(result_view)
		var blit_set := UniformSetCacheRD.get_cache(_blit_shader, 0, [blit_uniform])

		var blit_draw_list := rd.draw_list_begin(blit_fb)
		rd.draw_list_bind_render_pipeline(blit_draw_list, _blit_pipeline)
		rd.draw_list_bind_vertex_array(blit_draw_list, _vertex_array)
		rd.draw_list_bind_uniform_set(blit_draw_list, blit_set, 0)
		rd.draw_list_draw(blit_draw_list, false, 1)
		rd.draw_list_end()
