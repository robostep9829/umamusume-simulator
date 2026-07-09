extends Resource
class_name SpringBoneSettings

@export var external_force: Vector3 = Vector3.ZERO
@export var mutable_bone_axes: bool = true
@export var chains: Array[SpringBoneChainSettings]


func apply_to(simulator: SpringBoneSimulator3D) -> void:
	simulator.external_force = external_force
	simulator.mutable_bone_axes = mutable_bone_axes
	simulator.setting_count = chains.size()

	for i in chains.size():
		var c: SpringBoneChainSettings = chains[i]
		simulator.set_root_bone_name(i, c.root_bone_name)
		simulator.set_end_bone_name(i, c.end_bone_name)
		simulator.set_end_bone_direction(i, c.end_bone_direction)
		simulator.set_end_bone_length(i, c.end_bone_length)
		simulator.set_extend_end_bone(i, c.extend_end_bone)
		simulator.set_stiffness(i, c.stiffness)
		if c.stiffness_damping_curve:
			simulator.set_stiffness_damping_curve(i, c.stiffness_damping_curve)
		simulator.set_drag(i, c.drag)
		if c.drag_damping_curve:
			simulator.set_drag_damping_curve(i, c.drag_damping_curve)
		simulator.set_gravity(i, c.gravity)
		simulator.set_gravity_direction(i, c.gravity_direction)
		if c.gravity_damping_curve:
			simulator.set_gravity_damping_curve(i, c.gravity_damping_curve)
		simulator.set_radius(i, c.radius)
		if c.radius_damping_curve:
			simulator.set_radius_damping_curve(i, c.radius_damping_curve)
		simulator.set_rotation_axis(i, c.rotation_axis)
		simulator.set_rotation_axis_vector(i, c.rotation_axis_vector)
		simulator.set_center_from(i, c.center_from)
		simulator.set_center_bone_name(i, c.center_bone_name)
		simulator.set_center_node(i, c.center_node)
		simulator.set_individual_config(i, c.individual_config)
		simulator.set_enable_all_child_collisions(i, true)
		if c.individual_config:
			var joint_count: int = simulator.get_joint_count(i)
			for j in mini(c.joint_stiffness.size(), joint_count):
				simulator.set_joint_stiffness(i, j, c.joint_stiffness[j])
			for j in mini(c.joint_drag.size(), joint_count):
				simulator.set_joint_drag(i, j, c.joint_drag[j])
			for j in mini(c.joint_gravity.size(), joint_count):
				simulator.set_joint_gravity(i, j, c.joint_gravity[j])
			for j in mini(c.joint_gravity_direction.size(), joint_count):
				simulator.set_joint_gravity_direction(i, j, c.joint_gravity_direction[j])
			for j in mini(c.joint_radius.size(), joint_count):
				simulator.set_joint_radius(i, j, c.joint_radius[j])
			for j in mini(c.joint_rotation_axis.size(), joint_count):
				simulator.set_joint_rotation_axis(i, j, c.joint_rotation_axis[j])


func read_from(simulator: SpringBoneSimulator3D) -> void:
	external_force = simulator.external_force
	mutable_bone_axes = simulator.mutable_bone_axes

	var count: int = simulator.setting_count
	chains.resize(count)

	for i in count:
		var c: SpringBoneChainSettings = SpringBoneChainSettings.new()
		c.root_bone_name = simulator.get_root_bone_name(i)
		c.end_bone_name = simulator.get_end_bone_name(i)
		c.end_bone_direction = simulator.get_end_bone_direction(i)
		c.end_bone_length = simulator.get_end_bone_length(i)
		c.extend_end_bone = simulator.is_end_bone_extended(i)
		c.stiffness = simulator.get_stiffness(i)
		c.stiffness_damping_curve = simulator.get_stiffness_damping_curve(i)
		c.drag = simulator.get_drag(i)
		c.drag_damping_curve = simulator.get_drag_damping_curve(i)
		c.gravity = simulator.get_gravity(i)
		c.gravity_direction = simulator.get_gravity_direction(i)
		c.gravity_damping_curve = simulator.get_gravity_damping_curve(i)
		c.radius = simulator.get_radius(i)
		c.radius_damping_curve = simulator.get_radius_damping_curve(i)
		c.rotation_axis = simulator.get_rotation_axis(i)
		c.rotation_axis_vector = simulator.get_rotation_axis_vector(i)
		c.center_from = simulator.get_center_from(i)
		c.center_bone_name = simulator.get_center_bone_name(i)
		c.center_node = simulator.get_center_node(i)
		c.individual_config = simulator.is_config_individual(i)

		var joint_count: int = simulator.get_joint_count(i)
		if c.individual_config and joint_count > 0:
			c.joint_stiffness.resize(joint_count)
			c.joint_drag.resize(joint_count)
			c.joint_gravity.resize(joint_count)
			c.joint_gravity_direction.resize(joint_count)
			c.joint_radius.resize(joint_count)
			c.joint_rotation_axis.resize(joint_count)
			for j in joint_count:
				c.joint_stiffness[j] = simulator.get_joint_stiffness(i, j)
				c.joint_drag[j] = simulator.get_joint_drag(i, j)
				c.joint_gravity[j] = simulator.get_joint_gravity(i, j)
				c.joint_gravity_direction[j] = simulator.get_joint_gravity_direction(i, j)
				c.joint_radius[j] = simulator.get_joint_radius(i, j)
				c.joint_rotation_axis[j] = simulator.get_joint_rotation_axis(i, j)

		chains[i] = c
