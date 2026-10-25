@tool
extends CompositorEffect
class_name TreeShadowEffect

## Renders the one tree shadow mask into a small RenderingDevice texture.
##
## Every rural tree samples this texture from its ground quad, so the whole pool
## costs a single pass instead of a viewport per prop. The tree is flattened onto
## the ground in the nearest hosting segment's frame and drawn with an
## orthographic, top-down clip mapping; the ground quads use the same frame, so
## the footprint points along the world sun and repeats identically under every
## tree.
##
## The pass only runs when the sun's angle in that frame changes, and it runs
## after the transparent scene pass, so receivers show the mask one frame later.

const VERTEX_SOURCE: String = """
#version 450
layout(location = 0) in vec3 position;
layout(push_constant, std430) uniform Params {
	// xyz: direction the sunlight travels, in the track frame.
	// w: half extent of the ground square, in metres.
	vec4 sun;
} params;
void main() {
	vec3 flat_point = position;
	flat_point += params.sun.xyz * (flat_point.y / max(-params.sun.y, 0.25));
	// +Z has to land on the same side of the mask the ground quad samples it
	// from: V grows with +Z, and clip-space Y grows downward in this pass.
	gl_Position = vec4(flat_point.x / params.sun.w, flat_point.z / params.sun.w, 0.0, 1.0);
}
"""

const FRAGMENT_SOURCE: String = """
#version 450
layout(location = 0) out vec4 out_color;
void main() {
	out_color = vec4(1.0);
}
"""

## About 0.6 degrees of sun movement in the track frame before re-rendering.
const ANGLE_EPSILON := 0.99995
const HALF_EXTENT := TreeShadowState.CELL_SIZE * 0.5

var rd: RenderingDevice = null

var _texture: RID = RID()
var _framebuffer: RID = RID()
var _shader: RID = RID()
var _pipeline: RID = RID()
var _vertex_format: int = -1
var _vertex_buffer: RID = RID()
var _vertex_array: RID = RID()
var _vertex_count: int = 0
var _last_sun := Vector3.ZERO
var _rendered := false
var _published := false


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	rd = RenderingServer.get_rendering_device()


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	# Clear synchronously, before the texture RID is freed: the receivers may
	# still draw one more teardown frame, and a material still pointing at the
	# freed mask fails uniform_set_create.
	TreeShadowState.clear_texture()
	if rd == null:
		return
	# Dependants first: the array owns the buffer, the pipeline owns the shader.
	for rid: RID in [
		_vertex_array, _vertex_buffer, _pipeline, _shader, _framebuffer, _texture,
	]:
		if rid.is_valid():
			rd.free_rid(rid)


func _render_callback(p_effect_callback_type: int, _p_render_data: RenderData) -> void:
	if p_effect_callback_type != effect_callback_type:
		return
	if rd == null:
		rd = RenderingServer.get_rendering_device()
		if rd == null:
			return

	var sun := TreeShadowState.sun_world
	if sun.y >= -TreeShadowState.MIN_SUN_HEIGHT:
		return

	# The nearest receiver publishes the hosting segment's forward each frame;
	# the mask shape is the sun relative to that track direction.
	var track_frame := Basis.looking_at(TreeShadowState.track_forward, Vector3.UP)
	var local_sun := (track_frame.inverse() * sun).normalized()
	if local_sun.y >= -TreeShadowState.MIN_SUN_HEIGHT:
		return
	if _rendered and local_sun.dot(_last_sun) > ANGLE_EPSILON:
		return
	if not _ensure_resources():
		return

	var push := PackedFloat32Array(
		[local_sun.x, local_sun.y, local_sun.z, HALF_EXTENT]
	).to_byte_array()
	var draw_list := rd.draw_list_begin(
		_framebuffer,
		RenderingDevice.DRAW_CLEAR_COLOR_ALL,
		PackedColorArray([Color(0.0, 0.0, 0.0, 0.0)]),
		1.0,
		0
	)
	rd.draw_list_bind_render_pipeline(draw_list, _pipeline)
	rd.draw_list_bind_vertex_array(draw_list, _vertex_array)
	rd.draw_list_set_push_constant(draw_list, push, push.size())
	rd.draw_list_draw(draw_list, false, 1)
	rd.draw_list_end()

	_last_sun = local_sun
	_rendered = true
	if not _published:
		_published = true
		# Texture2DRD is a main-thread resource; the effect runs on the render
		# thread, so hand the RID over on the next idle frame.
		TreeShadowState.set_rd_texture.call_deferred(_texture)


func _ensure_resources() -> bool:
	if TreeShadowState.vertex_count <= 0:
		return false

	if not _texture.is_valid():
		var format := RDTextureFormat.new()
		format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
		format.width = TreeShadowState.MASK_SIZE
		format.height = TreeShadowState.MASK_SIZE
		format.usage_bits = (
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
			| RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT
		)
		var view := RDTextureView.new()
		_texture = rd.texture_create(format, view, [])
		if not _texture.is_valid():
			return false
		_framebuffer = rd.framebuffer_create([_texture])
		if not _framebuffer.is_valid():
			return false
		_published = false
		_rendered = false

	if not _shader.is_valid():
		var source := RDShaderSource.new()
		source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
		source.source_vertex = VERTEX_SOURCE
		source.source_fragment = FRAGMENT_SOURCE
		var spirv := rd.shader_compile_spirv_from_source(source)
		if not spirv.compile_error_vertex.is_empty() or not spirv.compile_error_fragment.is_empty():
			push_error(
				"TreeShadowEffect shader compile error: [v]=%s [f]=%s"
				% [spirv.compile_error_vertex, spirv.compile_error_fragment]
			)
			return false
		_shader = rd.shader_create_from_spirv(spirv)
		if not _shader.is_valid():
			return false

	if _vertex_format < 0:
		var attribute := RDVertexAttribute.new()
		attribute.location = 0
		attribute.format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
		attribute.offset = 0
		attribute.stride = 12
		attribute.frequency = RenderingDevice.VERTEX_FREQUENCY_VERTEX
		_vertex_format = rd.vertex_format_create([attribute])
		if _vertex_format < 0:
			return false

	if not _pipeline.is_valid():
		_pipeline = _create_pipeline()
		if not _pipeline.is_valid():
			return false

	if not _vertex_array.is_valid() or _vertex_count != TreeShadowState.vertex_count:
		if _vertex_array.is_valid():
			rd.free_rid(_vertex_array)
		if _vertex_buffer.is_valid():
			rd.free_rid(_vertex_buffer)
		_vertex_count = TreeShadowState.vertex_count
		_vertex_buffer = rd.vertex_buffer_create(
			TreeShadowState.vertex_bytes.size(), TreeShadowState.vertex_bytes
		)
		if not _vertex_buffer.is_valid():
			return false
		_vertex_array = rd.vertex_array_create(
			_vertex_count, _vertex_format, [_vertex_buffer]
		)
		if not _vertex_array.is_valid():
			return false

	return true


func _create_pipeline() -> RID:
	var rasterizer := RDPipelineRasterizationState.new()
	rasterizer.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED

	var multisample := RDPipelineMultisampleState.new()
	multisample.sample_count = RenderingDevice.TEXTURE_SAMPLES_1

	var depth_stencil := RDPipelineDepthStencilState.new()

	var attachment := RDPipelineColorBlendStateAttachment.new()
	attachment.src_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
	attachment.dst_color_blend_factor = RenderingDevice.BLEND_FACTOR_ZERO
	attachment.src_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
	attachment.dst_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ZERO
	attachment.color_blend_op = RenderingDevice.BLEND_OP_ADD
	attachment.alpha_blend_op = RenderingDevice.BLEND_OP_ADD
	attachment.write_r = true
	attachment.write_g = true
	attachment.write_b = true
	attachment.write_a = true
	var blend := RDPipelineColorBlendState.new()
	blend.attachments = [attachment]

	return rd.render_pipeline_create(
		_shader,
		rd.framebuffer_get_format(_framebuffer),
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
