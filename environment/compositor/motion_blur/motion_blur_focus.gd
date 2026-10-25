@tool
extends RefCounted
class_name MotionBlurFocus

## Screen-space capsule that MotionBlurEffect keeps sharp. ThirdPersonController
## projects the character into it every frame; the render callback reads a
## snapshot of it (that callback runs on the rendering thread, hence the mutex).
##
## Layout: feet.xy, head.xy, radius.xy (all UV), distance (m), half depth (m).
## A non-positive distance disables the focus.

const DISABLED_DISTANCE := -1.0

static var _mutex := Mutex.new()
static var _data := PackedFloat32Array([
	0.0, 0.0, 0.0, 0.0, 0.0, 0.0, DISABLED_DISTANCE, 0.5,
])


static func set_focus(
	p_feet_uv: Vector2,
	p_head_uv: Vector2,
	p_radius_uv: Vector2,
	p_distance: float,
	p_half_depth: float
) -> void:
	_mutex.lock()
	_data[0] = p_feet_uv.x
	_data[1] = p_feet_uv.y
	_data[2] = p_head_uv.x
	_data[3] = p_head_uv.y
	_data[4] = p_radius_uv.x
	_data[5] = p_radius_uv.y
	_data[6] = p_distance
	_data[7] = p_half_depth
	_mutex.unlock()


static func clear() -> void:
	_mutex.lock()
	_data[6] = DISABLED_DISTANCE
	_mutex.unlock()


static func get_focus() -> PackedFloat32Array:
	_mutex.lock()
	var snapshot := _data.duplicate()
	_mutex.unlock()
	return snapshot
