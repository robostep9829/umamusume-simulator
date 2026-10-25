@tool
extends RefCounted
class_name MotionBlurUniforms

## Per-frame GPU inputs of MotionBlurEffect: the push-constant block and the
## reprojection uniform buffer. Authoring-time tuning (shutter angle, sample
## count, threshold) lives in motion_blur.glsl as compile-time constants, so
## only values that change every frame are carried here.

## Must match `MB_SAMPLE_COUNT` in motion_blur.glsl.
const SAMPLE_COUNT := 4
## Must match `MB_MAX_STEPS` in motion_blur.glsl.
const MAX_REPROJECTION_STEPS := 32

## Push-constant block: vec2 raster_size, vec2 reserved.
var raster_size := Vector2.ZERO

## MAX_REPROJECTION_STEPS step matrices followed by the inverse projection,
## column-major, matching the std140 Reprojection block.
var _reprojection := PackedFloat32Array()


func _init() -> void:
	_reprojection.resize((MAX_REPROJECTION_STEPS + 1) * 16)
	set_inverse_projection(Projection.IDENTITY)


func set_step(p_index: int, p_step: Projection) -> void:
	_write_matrix(p_index * 16, p_step)


func set_inverse_projection(p_projection: Projection) -> void:
	_write_matrix(MAX_REPROJECTION_STEPS * 16, p_projection)


func to_push_constants() -> PackedByteArray:
	return PackedFloat32Array([raster_size.x, raster_size.y, 0.0, 0.0]).to_byte_array()


func to_reprojection_bytes() -> PackedByteArray:
	return _reprojection.to_byte_array()


func _write_matrix(p_offset: int, p_projection: Projection) -> void:
	for column in range(4):
		var col := p_projection[column] as Vector4
		_reprojection[p_offset + column * 4 + 0] = col.x
		_reprojection[p_offset + column * 4 + 1] = col.y
		_reprojection[p_offset + column * 4 + 2] = col.z
		_reprojection[p_offset + column * 4 + 3] = col.w
