extends Resource
class_name SpringBoneChainSettings

@export var root_bone_name: StringName
@export var end_bone_name: StringName
@export var end_bone_direction: SkeletonModifier3D.BoneDirection
@export var end_bone_length: float = 0.0
@export var extend_end_bone: bool = false

@export var stiffness: float = 1.0
@export var stiffness_damping_curve: Curve
@export var drag: float = 0.4
@export var drag_damping_curve: Curve
@export var gravity: float = 0.0
@export var gravity_direction: Vector3 = Vector3.DOWN
@export var gravity_damping_curve: Curve
@export var radius: float = 0.02
@export var radius_damping_curve: Curve

@export var rotation_axis: SkeletonModifier3D.RotationAxis = SkeletonModifier3D.RotationAxis.ROTATION_AXIS_ALL
@export var rotation_axis_vector: Vector3 = Vector3(1, 0, 0)

@export var center_from: SpringBoneSimulator3D.CenterFrom = SpringBoneSimulator3D.CenterFrom.CENTER_FROM_WORLD_ORIGIN
@export var center_bone_name: StringName
@export var center_node: NodePath

@export var individual_config: bool = false
@export var joint_stiffness: Array[float]
@export var joint_drag: Array[float]
@export var joint_gravity: Array[float]
@export var joint_gravity_direction: Array[Vector3]
@export var joint_radius: Array[float]
@export var joint_rotation_axis: Array[SkeletonModifier3D.RotationAxis]
