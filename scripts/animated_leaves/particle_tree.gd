@tool
extends MultiMeshInstance3D
class_name ParticleTree

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	var csv_file = FileAccess.open("res://worlds/scrolling_track/props/rural/tree_data/leaf_instances.csv", FileAccess.READ)
	csv_file.get_csv_line(",")
	for i in self.multimesh.instance_count:
		var line = csv_file.get_csv_line(",")
		var position := Vector3(float(line[0]), float(line[2]), -float(line[1]))
		var scale := Vector3(float(line[3]), float(line[5]), -float(line[4]))
		#var scale := Vector3(1.0, 1.0, 1.0)
		scale *= 0.2
		scale.y *= 3
		var rotation := Quaternion(float(line[7]), float(line[9]), -float(line[8]), float(line[6]))
		var transform := calc_transform_3d(position, rotation, scale)

		self.multimesh.set_instance_transform(i, transform)
	pass # Replace with function body.

func calc_transform_3d(position_3d: Vector3, rotation_3d: Quaternion, scale_3d: Vector3) -> Transform3D:
	# Create basis from rotation, then apply local scale
	var basis = Basis.from_euler(rotation_3d.get_euler()).scaled_local(scale_3d)
	# Combine basis and position into the final transform
	return Transform3D(basis, position_3d)

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass
