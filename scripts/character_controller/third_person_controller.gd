@tool
extends CharacterBody3D

## A single tick of movement this size is not running, it is the level moving the world
## back under the player (`TrackManager._snap_player`), so the camera is placed there
## with it rather than sliding after it.
const CAMERA_SNAP_DISTANCE := 2.0

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

## Camera trail: how long the camera takes to close the gap between where the character
## is and where it still is, and how far that gap may grow. Holding the camera where it
## was is what lets a fast run pull away from it instead of riding welded to its back; 0
## for [member camera_lag_time] puts it rigidly back on the character.
@export var camera_lag_time: float = 0.1
@export var camera_lag_max: float = 3.0

@export var player_data: PlayerData:
	set(value):
		player_data = value
		_update_character_mesh()

# Camera trail state: the pivot's authored offset, where the camera wanted to be last
# frame - a jump from that is a teleport, not speed - and where it actually is, in world
# space, which the body does not carry along.
var _pivot_rest: Vector3 = Vector3.ZERO
var _last_ideal: Vector3 = Vector3.ZERO
var _pivot_world: Vector3 = Vector3.ZERO


# Cached node references
@onready var camera_pivot: Node3D = $CameraPivot
@onready var skeleton: Node3D = $Skeleton3D
@onready var spring: Node3D = $CameraPivot/SpringArm3D
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

const WALK_ANIM_SPEED := 1.6
const SPRINT_ANIM_SPEED := 7.0
const STRIDE_ANIM_SPEED := 14.0

func _ready() -> void:
	_pivot_rest = camera_pivot.position
	_last_ideal = global_transform * _pivot_rest
	_pivot_world = _last_ideal
	if not Engine.is_editor_hint():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_update_character_mesh()


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
	# After the move, so the trail uses the position the body actually reached.
	_apply_camera_trail(delta)


func _update_camera() -> void:
	# Yaw rotates the pivot horizontally, pitch tilts it vertically
	camera_pivot.rotation.y = _yaw
	camera_pivot.rotation.x = _pitch


## Where the camera is, in world space: the pivot holds its own position and chases the
## character from there, so the character pulls away under acceleration and the camera
## cuts the corner on a turn, then closes up again. The faster the run, the further back
## it settles - `speed * camera_lag_time` in the steady state, 2 m at 20 m/s - which is
## what stops a fast run from looking welded to the character's back.
##
## The gap has to be a world space one. The pivot is a child of the body, so the body
## carries it along every step: reading its own position back each frame finds it
## sitting exactly at the pose again, with no gap to trail.
func _apply_camera_trail(delta: float) -> void:
	var ideal := global_transform * _pivot_rest
	var teleported := ideal.distance_to(_last_ideal) > CAMERA_SNAP_DISTANCE
	_last_ideal = ideal
	var here := _pivot_world
	if camera_lag_time > 0.0 and not teleported:
		here = here.lerp(ideal, 1.0 - exp(-delta / camera_lag_time))
		var gap := here - ideal
		if gap.length() > camera_lag_max:
			here = ideal + gap.normalized() * camera_lag_max
	else:
		here = ideal
	_pivot_world = here
	camera_pivot.global_position = here


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
		auto_forward = false
		_idle_time = 0.0
	# Force forward input while auto-running (unless the player is actively
	# holding backward, which already cancelled it this frame).
	if auto_forward and input_dir.y >= 0.0:
		speed_mul += 0.0002
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
	var speed := sprint_speed * speed_mul if is_sprinting else move_speed
	
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
