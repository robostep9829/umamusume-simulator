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

const _VERTEX_SOURCE: String = """
#version 450
layout(location = 0) out vec2 uv_interp;
void main() {
	const vec2 triangle[3] = vec2[3](vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0));
	vec2 in_pos = triangle[gl_VertexIndex];
	uv_interp = in_pos * 0.5 + 0.5;
	gl_Position = vec4(in_pos, 0.0, 1.0);
}
"""

const _FRAG_SOURCE: String = """
layout(location = 0) in vec2 uv_interp;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D color_tex;
#ifdef USE_MSAA_DEPTH
// With MSAA the mobile renderer never writes the resolved RB_TEX_DEPTH
// (depth resolve for compositor effects is unsupported), so read the
// multisampled depth attachment itself.
layout(set = 0, binding = 1) uniform sampler2DMS depth_tex;
#else
layout(set = 0, binding = 1) uniform sampler2D depth_tex;
#endif

// One matrix per tap: maps this frame's clip position to the position the
// same world point had at an earlier point of the exposure. Interpolating the
// camera pose makes rotation follow its true arc instead of a straight chord.
layout(set = 1, binding = 0, std140) uniform Reprojection {
	mat4 steps[32];
	mat4 inv_projection;
} reproj;

layout(push_constant, std430) uniform Ctrl {
	vec4 params;  // raster_size.xy (px), max_radius_px, strength
	vec4 params2; // sample_count, center_keep, center_radius, far_expo
	vec4 params3; // center_pos.xy, exposure (baked into steps), reserved
	vec4 params4; // far_falloff_distance (m), motion_threshold_px, -, -
} ctrl;

float sample_depth(vec2 p_uv) {
#ifdef USE_MSAA_DEPTH
	return texelFetch(depth_tex, ivec2(p_uv * ctrl.params.xy), 0).x;
#else
	return textureLod(depth_tex, p_uv, 0.0).x;
#endif
}

vec2 project_uv(mat4 p_matrix, vec4 p_clip) {
	vec4 out_clip = p_matrix * p_clip;
	return (out_clip.xy / out_clip.w) * 0.5 + 0.5;
}

// Reversed-Z: depth = 1 at the near plane, 0 at the far plane/sky. Unproject
// the NDC point to recover the true linear view distance in metres.
float linear_distance(vec2 p_uv, float p_depth) {
	vec4 view = reproj.inv_projection * vec4(p_uv * 2.0 - 1.0, p_depth, 1.0);
	return abs(view.z / view.w);
}

// Blur envelope: reduced around the character's screen position and in the
// far distance.
float blur_weight(vec2 p_uv, float p_distance) {
	float depth_w = 1.0;
	if (ctrl.params2.w > 0.0) {
		depth_w = pow(clamp(ctrl.params4.x / max(p_distance, 0.001), 0.0, 1.0), ctrl.params2.w);
	}

	float aspect = ctrl.params.x / ctrl.params.y;
	vec2 d = (p_uv - ctrl.params3.xy) * vec2(aspect, 1.0);
	float dist = length(d);
	float radial_w = ctrl.params2.y + (1.0 - ctrl.params2.y) * smoothstep(ctrl.params2.z * 0.25, ctrl.params2.z, dist);

	return clamp(depth_w * radial_w, 0.0, 1.0);
}

void main() {
	vec4 base_color = textureLod(color_tex, uv_interp, 0.0);
	int samples = int(ctrl.params2.x);
	if (samples < 2 || ctrl.params.w <= 0.0) {
		out_color = base_color;
		return;
	}

	float depth = sample_depth(uv_interp);
	float distance = linear_distance(uv_interp, depth);
	if (depth <= 0.0) {
		out_color = base_color; // Reversed depth: far plane / sky is 0.0.
		return;
	}

	vec4 clip = vec4(uv_interp * 2.0 - 1.0, depth, 1.0);
	vec2 previous_uv = project_uv(reproj.steps[0], clip);
	float vel_px = length((previous_uv - uv_interp) * ctrl.params.xy);

	// Blur envelope: fade with the center/distance envelope and the velocity
	// threshold. `amount` shortens the whole arc toward the current pixel so
	// strength and max radius still act as artistic controls.
	float weight = blur_weight(uv_interp, distance);
	float gate = 1.0;
	if (ctrl.params4.y > 0.0) {
		// Fade in over a small feather so the threshold does not leave a
		// hard contour where slow pixels cross it.
		float feather = max(ctrl.params4.y * 0.25, 1.0);
		gate = smoothstep(ctrl.params4.y, ctrl.params4.y + feather, vel_px);
	}
	float amount = min(1.0, ctrl.params.z / max(vel_px, 1e-6)) * ctrl.params.w * weight * gate;
	if (amount * vel_px < 0.05) {
		out_color = base_color;
		return;
	}

	// Integrate along the arc. The last tap is the current pixel itself
	// (base_color), so taps 0..samples-2 plus the base cover the exposure
	// evenly. A tap that lands on a nearer surface is an occlusion, so it is
	// rejected instead of bleeding a hidden object into the blur.
	vec4 sum = base_color;
	float weight_sum = 1.0;
	for (int i = 0; i < samples - 1; i++) {
		vec2 tap_uv = clamp(mix(uv_interp, project_uv(reproj.steps[i], clip), amount),
			vec2(0.001), vec2(0.999));
		float tap_distance = linear_distance(tap_uv, sample_depth(tap_uv));
		float visible = step(distance * 0.75, tap_distance);
		sum += textureLod(color_tex, tap_uv, 0.0) * visible;
		weight_sum += visible;
	}
	out_color = sum / weight_sum;
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

@export_range(0.0, 1.0, 0.01) var motion_strength: float = 0.9
@export_range(2, 32, 1) var motion_sample_count: int = 16
@export_range(0.0, 256.0, 0.5) var motion_max_radius_px: float = 32.0
## Minimum screen-space motion (pixels per 1/60 s exposure) that produces
## blur. Slower pixels fade smoothly to no blur; 0 disables the gate.
@export_range(0.0, 64.0, 0.5) var motion_threshold_px: float = 0.0
## Fraction of full blur kept at the blur-suppression anchor.
@export_range(0.0, 1.0, 0.05) var center_keep: float = 0.1
## Radius (in units of screen height) of the suppressed region; blur recovers
## to full past this radius.
@export_range(0.0, 1.0, 0.05) var center_radius: float = 0.22
## Exponent of the far-distance falloff (0 = no distance falloff).
@export_range(0.0, 4.0, 0.1) var far_falloff: float = 1.0
## Distance (metres) at which full blur has decayed; closer is fully blurred.
@export_range(1.0, 500.0, 1.0) var falloff_distance: float = 45.0
## Screen-space anchor of the suppression region (UV, y grows downward).
@export var center_pos: Vector2 = Vector2(0.5, 0.4)

## Must match the `steps[32]` array size in the shader.
const MAX_REPROJECTION_STEPS := 32

var rd: RenderingDevice = null

var _shader: RID = RID()
var _shader_msaa_depth: bool = false
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
		if _blit_pipeline.is_valid():
			rd.free_rid(_blit_pipeline)
		if _blit_shader.is_valid():
			rd.free_rid(_blit_shader)


## Compiles the vertex + fragment stages into a single shader program.
## Returns true once the shader is valid. Two variants exist: one sampling a
## normal depth texture, one sampling a multisampled depth attachment.
func _create_shader(msaa_depth: bool) -> bool:
	if _shader.is_valid() and _shader_msaa_depth == msaa_depth:
		return true
	if not rd:
		return false

	if _shader.is_valid():
		rd.free_rid(_shader)
		_shader = RID()
		_pipeline = RID()
		_pipeline_format = -1

	var body := _FRAG_SOURCE
	if msaa_depth:
		body = "#define USE_MSAA_DEPTH 1\n" + body

	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_vertex = _VERTEX_SOURCE
	source.source_fragment = "#version 450\n" + body

	var spirv := rd.shader_compile_spirv_from_source(source)
	for message: String in [spirv.compile_error_vertex, spirv.compile_error_fragment]:
		if not message.is_empty():
			push_error("MotionBlurEffect shader compile error: %s" % message)
			return false

	_shader = rd.shader_create_from_spirv(spirv)
	_shader_msaa_depth = msaa_depth
	return _shader.is_valid()


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
			(MAX_REPROJECTION_STEPS + 1) * 16 * 4, PackedByteArray(), 0
		)
		if not _reprojection_buffer.is_valid():
			return false

	return true


func _pack_matrix(mat: Projection) -> PackedFloat32Array:
	var packed := PackedFloat32Array()
	packed.resize(16)
	for column in range(4):
		var col := mat[column] as Vector4
		packed[column * 4 + 0] = col.x
		packed[column * 4 + 1] = col.y
		packed[column * 4 + 2] = col.z
		packed[column * 4 + 3] = col.w
	return packed


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

	var samples: int = clampi(motion_sample_count, 2, MAX_REPROJECTION_STEPS)
	var inverse_projection: Projection = current_projection.inverse()
	var steps := PackedFloat32Array()
	steps.resize(MAX_REPROJECTION_STEPS * 16)
	for i in range(MAX_REPROJECTION_STEPS):
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
		var packed := _pack_matrix(step_projection)
		for column in range(16):
			steps[i * 16 + column] = packed[column]
	steps.append_array(_pack_matrix(inverse_projection))

	rd.buffer_update(_reprojection_buffer, 0, steps.size() * 4, steps.to_byte_array())
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
		blit_source.source_vertex = _VERTEX_SOURCE
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

		# Pass 1: sample the resolved color + depth buffers, write blurred
		# output into our own texture (reading and writing the same
		# framebuffer attachment is not allowed).
		var result_fb: RID = rd.framebuffer_create([result_view])
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

		var push_constants := PackedFloat32Array([
			size.x, size.y,
			motion_max_radius_px, motion_strength,
			float(motion_sample_count), center_keep, center_radius, far_falloff,
			center_pos.x, center_pos.y, fps_scale, 0.0,
			falloff_distance, motion_threshold_px, 0.0, 0.0,
		])

		var draw_list := rd.draw_list_begin(result_fb)
		rd.draw_list_bind_render_pipeline(draw_list, _pipeline)
		rd.draw_list_bind_vertex_array(draw_list, _vertex_array)
		rd.draw_list_bind_uniform_set(draw_list, sampler_set, 0)
		rd.draw_list_bind_uniform_set(draw_list, reproj_set, 1)
		rd.draw_list_set_push_constant(draw_list, push_constants.to_byte_array(), push_constants.size() * 4)
		rd.draw_list_draw(draw_list, false, 1)
		rd.draw_list_end()

		# Pass 2: blit the blurred result back into the resolved color buffer
		# with blending disabled (strict source replacement).
		var blit_fb: RID = rd.framebuffer_create([color_rid])
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
