@tool
extends RefCounted
class_name MotionBlurFocus

## Screen-space capsule that MotionBlurEffect keeps sharp. ThirdPersonController
## hands it the camera and the character's feet/head; the projection and the
## viewport-size cache live here. The render callback reads a snapshot of the
## result (that callback runs on the rendering thread, hence the mutex).
##
## Layout: feet.xy, head.xy, radius.xy (all UV), distance (m), half depth (m).
## A non-positive distance disables the focus.

const DISABLED_DISTANCE := -1.0

static var _mutex := Mutex.new()
static var _data := PackedFloat32Array([
	0.0, 0.0, 0.0, 0.0, 0.0, 0.0, DISABLED_DISTANCE, 0.5,
])

# Viewport size is queried once per viewport and refreshed by its signal.
static var _viewport: Viewport = null
static var _viewport_size := Vector2.ZERO
static var _size_changed := Callable()


static func update_focus(
	p_camera: Camera3D,
	p_feet: Vector3,
	p_head: Vector3,
	p_radius: float,
	p_half_depth: float
) -> void:
	if not p_camera:
		clear()
		return
	var viewport := p_camera.get_viewport()
	if not viewport:
		clear()
		return
	_cache_viewport(viewport)
	if _viewport_size.x <= 0.0 or _viewport_size.y <= 0.0:
		clear()
		return
	if p_camera.is_position_behind(p_feet) or p_camera.is_position_behind(p_head):
		clear()
		return

	var center := (p_feet + p_head) * 0.5
	var center_screen := p_camera.unproject_position(center)
	var radius_px := p_camera.unproject_position(
		center + p_camera.global_transform.basis.x * p_radius
	).distance_to(center_screen)
	var view_center := p_camera.global_transform.affine_inverse() * center

	_write_focus(
		p_camera.unproject_position(p_feet) / _viewport_size,
		p_camera.unproject_position(p_head) / _viewport_size,
		Vector2(radius_px, radius_px) / _viewport_size,
		-view_center.z,
		p_half_depth
	)


static func clear() -> void:
	_mutex.lock()
	_data[6] = DISABLED_DISTANCE
	_mutex.unlock()


static func get_focus() -> PackedFloat32Array:
	_mutex.lock()
	var snapshot := _data.duplicate()
	_mutex.unlock()
	return snapshot


static func _cache_viewport(p_viewport: Viewport) -> void:
	if p_viewport == _viewport:
		return
	if _size_changed.is_valid() and is_instance_valid(_viewport):
		if _viewport.size_changed.is_connected(_size_changed):
			_viewport.size_changed.disconnect(_size_changed)
	_viewport = p_viewport
	_viewport_size = p_viewport.get_visible_rect().size
	_size_changed = _on_viewport_size_changed.bind(p_viewport)
	p_viewport.size_changed.connect(_size_changed)


static func _on_viewport_size_changed(p_viewport: Viewport) -> void:
	_viewport_size = p_viewport.get_visible_rect().size


static func _write_focus(
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
