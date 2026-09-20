@tool
extends CharacterBody3D

const WALK_ANIM_SPEED := 1.6
const SPRINT_ANIM_SPEED := 7.0
const STRIDE_ANIM_SPEED := 14.0

## A single tick of movement this size is not running, it is the level moving the
## world back under the player (`TrackManager._snap_player`), so the camera is placed
## there with it rather than sliding after it.
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

## Chase camera. The distance and the fov follow how fast the character is actually
## going, so 7 m/s and 21 m/s do not look the same from behind: they lerp between the
## normal and the sprint pair, and the fov opens from the camera's authored value to
## [member sprint_fov], as the speed runs from [member move_speed] to
## [member camera_full_speed]. Past that they keep going into the extra room of
## [member camera_over_speed], because the auto run has no top speed and a pose that
## stops answering the speed looks welded to the character's back.
##
## The shoulder offset answers to the sprint instead: over the shoulder at a walk,
## centred while sprinting, because that is the view a sprint is for - the whole road
## ahead, with the character on the centre line. Set [member sprint_spring_position] to
## [member normal_spring_position] to keep the shoulder line at every speed.
@export var normal_spring_length: float = 1.5
@export var sprint_spring_length: float = 2.5
@export var normal_spring_position: Vector3 = Vector3(0.5, 0.0, 0.0)
@export var sprint_spring_position: Vector3 = Vector3(0.0, 0.0, 0.0)
@export var camera_full_speed: float = 21.0
@export var sprint_fov: float = 62.0
## How much more pose the speed can buy past [member camera_full_speed], as a multiple
## of the normal-to-sprint swing: 1.0 lets it buy as much again, reaching a 3.5 m arm
## and a 73.8 degree fov on a long run. It keeps climbing at the same rate per m/s as
## the ramp below and eases into this, so there is no speed where the camera stops
## answering. 0 freezes the pose at [member camera_full_speed].
@export var camera_over_speed: float = 1.0

## Time constants, in seconds, and the gap they work within: how long the distance,
## offset and fov take to reach a pose, how long the camera takes to close a gap it is
## allowed to have, and the gap it aims to keep. That aim is where the pivot is pulled
## to rather than a limit on the gap - the character keeps gaining ground while the gap
## closes, so a run settles at about [member camera_lag_max] plus
## `speed * camera_lag_time` behind the character: 0.1 s is 2 m at 20 m/s, and that is
## what makes the camera trail further the faster the run goes. 0 for
## [member camera_lag_time] keeps it rigidly on the character's back.
@export var camera_pose_time: float = 0.25
@export var camera_lag_time: float = 0.1
@export var camera_lag_max: float = 1.0


@export var player_data: PlayerData:
	set(value):
		player_data = value
		_update_character_mesh()

# Gravity pulled from project settings so it stays consistent
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

# Sprint tracking (`is_sprinting` also drives the animation tree's transitions) and
# auto run, which any directional input resets and only `move_back` cancels.
var is_sprinting: bool = false
var speed_mul: float = 1.0
var auto_forward: bool = false

# Camera rotation and chase state
var _yaw: float = 0.0
var _pitch: float = 0.0
# The pivot's authored offset, the fov the pose opens from, and where the camera
# wanted to be last frame - a jump from that is a teleport, not speed.
var _pivot_rest: Vector3 = Vector3.ZERO
var _normal_fov: float = 50.2
var _last_ideal: Vector3 = Vector3.ZERO

# Auto run: seconds without input, and the flag that starts it (see `_apply_auto_run`)
var _idle_time: float = 0.0

# Cached node references
@onready var camera_pivot: Node3D = $CameraPivot
@onready var skeleton: Node3D = $Skeleton3D
@onready var spring: SpringArm3D = $CameraPivot/SpringArm3D
@onready var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
@onready var animation_tree: AnimationTree = $AnimationTree


func _ready() -> void:
	_pivot_rest = camera_pivot.position
	if camera != null:
		_normal_fov = camera.fov
	_last_ideal = global_transform * _pivot_rest
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
	# Aim before moving, because the movement direction is read off the pivot; pose
	# after, so it uses this frame's speed and the position the body actually reached.
	_update_camera()
	_handle_movement(delta)
	_apply_chase_pose(delta)


func _update_camera() -> void:
	# Yaw rotates the pivot horizontally, pitch tilts it vertically
	camera_pivot.rotation.y = _yaw
	camera_pivot.rotation.x = _pitch


## Where the camera sits and how wide it looks, from how fast the character is going.
func _apply_chase_pose(delta: float) -> void:
	var speed := Vector2(velocity.x, velocity.z).length()
	var fast := _speed_pose(speed)
	var pose := 1.0 - exp(-delta / maxf(camera_pose_time, 0.001))
	spring.spring_length = lerpf(
		spring.spring_length, lerpf(normal_spring_length, sprint_spring_length, fast), pose
	)
	# The offset follows the sprint input, not the speed: a sprint is asked for, and the
	# centred view is what it is for.
	var target_offset := sprint_spring_position if is_sprinting else normal_spring_position
	spring.position = spring.position.lerp(target_offset, pose)
	if camera != null:
		camera.fov = lerpf(camera.fov, lerpf(_normal_fov, sprint_fov, fast), pose)

	# The pose above is where the camera wants to be; this is the part of it that
	# cannot be reached instantly, so the character pulls away under acceleration and
	# the camera cuts the corner on a turn, then closes up again.
	var ideal := global_transform * _pivot_rest
	var teleported := ideal.distance_to(_last_ideal) > CAMERA_SNAP_DISTANCE
	_last_ideal = ideal
	if camera_lag_time <= 0.0 or teleported:
		camera_pivot.global_position = ideal
		return
	var target := ideal
	var trail := camera_pivot.global_position - ideal
	if trail.length() > camera_lag_max:
		target = ideal + trail.normalized() * camera_lag_max
	camera_pivot.global_position = camera_pivot.global_position.lerp(
		target, 1.0 - exp(-delta / camera_lag_time)
	)


## How far the pose has moved from the normal pair toward the sprint pair and past it:
## 0 at [member move_speed], 1 at [member camera_full_speed], and above that it keeps
## climbing at the same rate per m/s, easing into [member camera_over_speed] more.
func _speed_pose(speed: float) -> float:
	var span := maxf(camera_full_speed - move_speed, 0.001)
	var ramp := (speed - move_speed) / span
	if ramp <= 1.0:
		return clampf(ramp, 0.0, 1.0)
	return 1.0 + camera_over_speed * (1.0 - exp(-(ramp - 1.0)))


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
	animation_tree["parameters/sprint_spd/stride_blend/blend_amount"] = clampf(
		remap(speed, SPRINT_ANIM_SPEED, STRIDE_ANIM_SPEED, 0.0, 1.0), 0.0, 1.0
	)
	animation_tree["parameters/sprint_spd/stride_speed_mul/scale"] = clampf(
		remap(speed, STRIDE_ANIM_SPEED, 2 * STRIDE_ANIM_SPEED, 1.0, 2.0), 1.0, INF
	)

	# Smoothly accelerate toward the target horizontal velocity
	var target_velocity := direction * speed
	velocity.x = lerp(velocity.x, target_velocity.x, acceleration * delta)
	velocity.z = lerp(velocity.z, target_velocity.z, acceleration * delta)

	# Rotate the mesh to face movement direction
	if direction != Vector3.ZERO:
		var target_yaw := atan2(direction.x, direction.z)
		skeleton.rotation.y = lerp_angle(skeleton.rotation.y, target_yaw, rotation_speed * delta)

	move_and_slide()
