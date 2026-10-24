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
#version 450

layout(location = 0) in vec2 uv_interp;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D color_tex;
layout(set = 0, binding = 1) uniform sampler2D depth_tex;

layout(set = 1, binding = 0, std140) uniform Reprojection {
	mat4 reprojection;
} reproj;

layout(push_constant, std430) uniform Ctrl {
	vec4 params;  // raster_size.xy (px), max_radius_px, strength
	vec4 params2; // sample_count, 0, 0, 0
} ctrl;

vec2 derive_motion_vector(vec2 p_uv, float p_depth, mat4 p_reprojection) {
	vec4 prev_ndc = p_reprojection * vec4(p_uv * 2.0 - 1.0, p_depth * 2.0 - 1.0, 1.0);
	return 0.5 + (prev_ndc.xy / prev_ndc.w) * 0.5 - p_uv;
}

void main() {
	vec4 base_color = textureLod(color_tex, uv_interp, 0.0);
	int samples = int(ctrl.params2.x);
	if (samples < 2 || ctrl.params.w <= 0.0) {
		out_color = base_color;
		return;
	}

	float depth = textureLod(depth_tex, uv_interp, 0.0).x;
	if (depth >= 1.0) {
		out_color = base_color; // Sky fragments hold no valid scene position.
		return;
	}

	vec2 velocity = derive_motion_vector(uv_interp, depth, reproj.reprojection);
	float vel_px = length(velocity * ctrl.params.xy);
	if (vel_px < 1.0) {
		out_color = base_color;
		return;
	}

	// Keep direction, clamp length to max radius and tone down by strength.
	float truncated_px = min(vel_px, ctrl.params.w) * ctrl.params.z;
	velocity *= truncated_px / vel_px;

	vec4 sum = base_color;
	for (int i = 1; i < samples; i++) {
		float t = float(i) / float(samples - 1);
		sum += textureLod(color_tex, uv_interp + velocity * t, 0.0);
	}
	out_color = sum / float(samples);
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

@export_range(0.0, 1.0, 0.01) var motion_strength: float = 0.45
@export_range(2, 32, 1) var motion_sample_count: int = 16
@export_range(0.0, 256.0, 0.5) var motion_max_radius_px: float = 24.0

var rd: RenderingDevice = null

var _shader: RID = RID()
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

var _prev_projections: Array[Projection] = []
var _prev_transforms: Array[Transform3D] = []


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
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
## Returns true once the shader is valid.
func _create_shader() -> bool:
	if _shader.is_valid():
		return true
	if not rd:
		return false

	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_vertex = _VERTEX_SOURCE
	source.source_fragment = _FRAG_SOURCE

	var spirv := rd.shader_compile_spirv_from_source(source)
	for message: String in [spirv.compile_error_vertex, spirv.compile_error_fragment]:
		if not message.is_empty():
			push_error("MotionBlurEffect shader compile error: %s" % message)
			return false

	_shader = rd.shader_create_from_spirv(spirv)
	return _shader.is_valid()


func _create_resources() -> bool:
	if not _create_shader():
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

		_reprojection_buffer = rd.uniform_buffer_create(64, PackedByteArray(), 0)
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


## Builds the same re-projection matrix the engine uses for depth derived
## motion vectors (FSR2/TAA): it maps the (uv, depth) of this frame to the
## position it projected to in the previous frame. Returns false on the
## first frame for a view (no history yet).
func _update_reprojection(view: int, view_count: int, scene_data: RenderSceneData) -> bool:
	var current_projection: Projection = scene_data.get_view_projection(view)
	var current_transform: Transform3D = scene_data.get_cam_transform()

	if view >= _prev_projections.size():
		# No history yet: record this frame and skip the blur.
		_prev_projections.resize(view_count)
		_prev_transforms.resize(view_count)
		_prev_projections[view] = current_projection
		_prev_transforms[view] = current_transform
		return false

	var previous_projection: Projection = _prev_projections[view]
	var previous_transform: Transform3D = _prev_transforms[view]
	_prev_projections[view] = current_projection
	_prev_transforms[view] = current_transform

	# Depth correction flips y and converts Vulkan-style depth (0..1) back to
	# GL-style clip space (-1..1), matching RenderingServer's conventions.
	var correction := Projection(
		Vector4(1.0, 0.0, 0.0, 0.0),
		Vector4(0.0, -1.0, 0.0, 0.0),
		Vector4(0.0, 0.0, -1.0, 0.0),
		Vector4(0.0, 0.0, 0.0, 1.0)
	)
	var reprojection: Projection = (
		(correction * previous_projection)
		* Projection(previous_transform.affine_inverse() * current_transform)
		* (correction * current_projection).inverse()
	)

	rd.buffer_update(_reprojection_buffer, 0, 64, _pack_matrix(reprojection).to_byte_array())
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
	if not rd or not _create_resources():
		return

	var scene_buffers: RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
	var scene_data: RenderSceneData = p_render_data.get_render_scene_data()
	if not scene_buffers or not scene_data:
		return

	var size: Vector2i = scene_buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return

	var view_count := scene_buffers.get_view_count()

	var color_format: int = rd.texture_get_format(scene_buffers.get_color_texture()).format
	var result_texture: RID = scene_buffers.create_texture(
		"motion_blur", "result", color_format,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT,
		RenderingDevice.TEXTURE_SAMPLES_1, size, view_count, 1, false, false
	)
	if not result_texture.is_valid():
		return

	for view: int in range(view_count):
		if not _update_reprojection(view, view_count, scene_data):
			continue

		var depth_rid: RID = scene_buffers.get_depth_layer(view, false)
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
			float(motion_sample_count), 0.0, 0.0, 0.0,
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
