@tool
extends CharacterBody3D
class_name ThirdPersonController

## Movement tuning
@export var move_speed: float = 1.6
@export var sprint_speed: float = 7.0
@export var acceleration: float = 10.0
@export var jump_velocity: float = 4.5
@export var rotation_speed: float = 12.0

# Auto run: after N seconds without any movement input the character runs
# forward on its own. Pressing "move_back" interrupts it. 0 disables.
@export var auto_run_delay: float = 0.0

## Camera tuning
@export var mouse_sensitivity: float = 0.003
@export var min_pitch: float = -60.0   # look down limit (degrees)
@export var max_pitch: float = 70.0    # look up limit (degrees)

## Sprint camera
@export var normal_spring_length: float = 1.5
@export var sprint_spring_length: float = 2.5
@export var sprint_zoom_time: float = 0.2

@export var normal_spring_position: Vector3 = Vector3(0.5, 0.0, 0.0)
@export var sprint_spring_position: Vector3 = Vector3(0.0, 0.0, 0.0)

## Motion-blur focus: the character is kept sharp while the world blurs.
@export var blur_focus_head_height: float = 1.7
@export var blur_focus_radius: float = 0.55
@export var blur_focus_depth: float = 0.55

@export var player_data: PlayerData:
	set(value):
		player_data = value
		_update_character_mesh()


# Cached node references
@onready var camera_pivot: Node3D = $CameraPivot
@onready var skeleton: Node3D = $Skeleton3D
@onready var spring: SpringArm3D = $CameraPivot/SpringArm3D
@onready var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
@onready var animation_tree: AnimationTree = $AnimationTree

# Gravity pulled from project settings so it stays consistent
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

# Camera rotation state
var _yaw: float = 0.0
var _pitch: float = 0.0

# Sprint tracking
var _sprint_timer: float = 0.0
var is_sprinting: bool = false
var speed_mul: float = 1.0

# Auto run tracking
var _idle_time: float = 0.0
var auto_forward: bool = false
var _auto_run_time: float = 0.0

const MAX_SPEED := 20.0
const LOG_GROWTH := 0.2

const WALK_ANIM_SPEED := 1.6
const SPRINT_ANIM_SPEED := 7.0
const STRIDE_ANIM_SPEED := 14.0

func _ready() -> void:
	# The arm must not see the character it is attached to. The body's collider is one
	# physics step behind its own pivot, and the arm's cast only overlooks it while the
	# pivot still overlaps it: past `capsule_radius * physics_ticks_per_second` - the
	# capsule's 0.352 m at 60 Hz, about 21 m/s - the character outruns that stale
	# collider, the cast starts hitting it, and the camera collapses onto the pivot.
	spring.add_excluded_object(get_rid())
	if not Engine.is_editor_hint():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_update_character_mesh()


func _exit_tree() -> void:
	MotionBlurFocus.clear()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_update_blur_focus()


func _update_character_mesh() -> void:
	if not player_data or not player_data.character:
		return
	var old: Node3D = get_node_or_null("Skeleton3D")
	if not old:
		return
	for child in old.get_children():
		if child is MeshInstance3D:
			old.remove_child(child)
			child.queue_free()
	var new_mesh: Node3D = player_data.character.instantiate()
	old.replace_by(new_mesh)
	old.queue_free()
	skeleton = new_mesh
	
	if player_data.spring_bone_settings:
		for child in skeleton.get_children():
			if child is SpringBoneSimulator3D:
				player_data.spring_bone_settings.apply_to(child)
				break
	if animation_tree:
		animation_tree.set_active(false)
		animation_tree.set_active(true)
	$MorphController.wake()


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch -= event.relative.y * mouse_sensitivity
		_pitch = clamp(_pitch, deg_to_rad(min_pitch), deg_to_rad(max_pitch))

	# Toggle mouse capture with Escape so you can click away
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = (
			Input.MOUSE_MODE_VISIBLE
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			else Input.MOUSE_MODE_CAPTURED
		)


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_update_camera()
	_handle_movement(delta)


func _update_camera() -> void:
	# Yaw rotates the pivot horizontally, pitch tilts it vertically
	camera_pivot.rotation.y = _yaw
	camera_pivot.rotation.x = _pitch


## Projects the character capsule through the camera so the motion blur can
## leave it sharp. The capsule follows the spring-arm framing, so it moves
## left/center and closer/farther together with the camera.
func _update_blur_focus() -> void:
	var viewport_size := camera.get_viewport().get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		MotionBlurFocus.clear()
		return

	var feet := global_transform * Vector3(0.0, 0.05, 0.0)
	var head := global_transform * Vector3(0.0, blur_focus_head_height, 0.0)
	if camera.is_position_behind(feet) or camera.is_position_behind(head):
		MotionBlurFocus.clear()
		return

	var center := (feet + head) * 0.5
	var center_screen := camera.unproject_position(center)
	var radius_px := camera.unproject_position(
		center + camera.global_transform.basis.x * blur_focus_radius
	).distance_to(center_screen)
	var view_center := camera.global_transform.affine_inverse() * center

	MotionBlurFocus.set_focus(
		camera.unproject_position(feet) / viewport_size,
		camera.unproject_position(head) / viewport_size,
		Vector2(radius_px, radius_px) / viewport_size,
		-view_center.z,
		blur_focus_depth
	)


## Auto run: idle counter. Any directional input resets the clock; only
## "move_back" cancels an auto-run that is already in progress.
func _apply_auto_run(input_dir: Vector2, delta: float) -> Vector2:
	if auto_run_delay <= 0.0:
		return input_dir
	var any_move := (
		Input.is_action_pressed("move_forward")
		or Input.is_action_pressed("move_back")
		or Input.is_action_pressed("move_left")
		or Input.is_action_pressed("move_right")
	)
	if any_move:
		_idle_time = 0.0
	else:
		_idle_time += delta
		if _idle_time >= auto_run_delay:
			auto_forward = true
	if Input.is_action_just_pressed("move_back"):
		speed_mul = 1.0
		_auto_run_time = 0.0
		auto_forward = false
		_idle_time = 0.0
	# Force forward input while auto-running (unless the player is actively
	# holding backward, which already cancelled it this frame).
	if auto_forward and input_dir.y >= 0.0:
		# Logarithmic rise: fast at first, flattening toward MAX_SPEED.
		_auto_run_time += delta
		speed_mul = minf(MAX_SPEED / sprint_speed, 1.0 + LOG_GROWTH * log(1.0 + _auto_run_time))
		return Vector2(input_dir.x, -1.0)
	return input_dir


func _handle_movement(delta: float) -> void:
	# Apply gravity
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Jump
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity

	# Read input as a 2D vector (WASD by default)
	var input_dir: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	input_dir = _apply_auto_run(input_dir, delta)

	# Convert input into a direction relative to where the camera faces
	var direction := Vector3.ZERO
	if input_dir != Vector2.ZERO:
		var forward := -camera_pivot.global_transform.basis.z
		var right := camera_pivot.global_transform.basis.x
		# Flatten so movement stays on the ground plane
		forward.y = 0.0
		right.y = 0.0
		direction = (forward * -input_dir.y + right * input_dir.x).normalized()

	# Choose speed based on sprint input
	is_sprinting = Input.is_action_pressed("sprint") or auto_forward
	var speed := minf(sprint_speed * speed_mul if is_sprinting else move_speed, MAX_SPEED)
	
	# Blend sprint and faster sprint animations
	animation_tree["parameters/sprint_spd/stride_blend/blend_amount"] = clampf(remap(speed, SPRINT_ANIM_SPEED, STRIDE_ANIM_SPEED, 0.0, 1.0), 0.0, 1.0)
	animation_tree["parameters/sprint_spd/stride_speed_mul/scale"] = clampf(remap(speed, STRIDE_ANIM_SPEED, 2 * STRIDE_ANIM_SPEED, 1.0, 2.0), 1.0, INF)
	
	if is_sprinting:
		_sprint_timer += delta
	else:
		_sprint_timer = 0.0

	var target_length := sprint_spring_length if _sprint_timer >= sprint_zoom_time else normal_spring_length
	spring.spring_length = lerpf(spring.spring_length, target_length, 3 * delta)
	var target_offset := sprint_spring_position if _sprint_timer >= sprint_zoom_time else normal_spring_position
	spring.position = lerp(spring.position, target_offset, acceleration * delta)
	
	# Smoothly accelerate toward the target horizontal velocity
	var target_velocity := direction * speed
	velocity.x = lerp(velocity.x, target_velocity.x, acceleration * delta)
	velocity.z = lerp(velocity.z, target_velocity.z, acceleration * delta)

	# Rotate the mesh to face movement direction
	if direction != Vector3.ZERO:
		var target_yaw := atan2(direction.x, direction.z)
		skeleton.rotation.y = lerp_angle(skeleton.rotation.y, target_yaw, rotation_speed * delta)
	
	move_and_slide()
