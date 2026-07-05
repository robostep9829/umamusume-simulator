extends CharacterBody3D

## Movement tuning
@export var move_speed: float = 5.0
@export var sprint_speed: float = 8.0
@export var acceleration: float = 10.0
@export var jump_velocity: float = 4.5
@export var rotation_speed: float = 12.0

## Camera tuning
@export var mouse_sensitivity: float = 0.003
@export var min_pitch: float = -60.0   # look down limit (degrees)
@export var max_pitch: float = 70.0    # look up limit (degrees)

# Cached node references
@onready var camera_pivot: Node3D = $CameraPivot
@onready var mesh: Node3D = $Skeleton3D

# Gravity pulled from project settings so it stays consistent
var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

# Camera rotation state
var _yaw: float = 0.0
var _pitch: float = 0.0


func _ready() -> void:
	# Capture the mouse for a standard third person look feel
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	# Mouse look
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
	_update_camera()
	_handle_movement(delta)


func _update_camera() -> void:
	# Yaw rotates the pivot horizontally, pitch tilts it vertically
	camera_pivot.rotation.y = _yaw
	camera_pivot.rotation.x = _pitch


func _handle_movement(delta: float) -> void:
	# Apply gravity
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Jump
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity

	# Read input as a 2D vector (WASD by default)
	var input_dir: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")

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
	var speed := sprint_speed if Input.is_action_pressed("sprint") else move_speed

	# Smoothly accelerate toward the target horizontal velocity
	var target_velocity := direction * speed
	velocity.x = lerp(velocity.x, target_velocity.x, acceleration * delta)
	velocity.z = lerp(velocity.z, target_velocity.z, acceleration * delta)

	# Rotate the mesh to face movement direction
	if direction != Vector3.ZERO:
		var target_yaw := atan2(direction.x, direction.z)
		mesh.rotation.y = lerp_angle(mesh.rotation.y, target_yaw, rotation_speed * delta)

	move_and_slide()
