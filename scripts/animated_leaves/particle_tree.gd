@tool
class_name ParticleTree
extends MultiMeshInstance3D

## Bakes a leaf layout out of a CSV into this node's [MultiMesh].
##
## The layout is 4,700 rows and the parse costs ~10 ms in GDScript, which is nothing
## for one tree - but the biome system builds hundreds of them: a 40-element pool
## holds 280 trees, and every element that scrolls into the window re-instantiates
## the trees of the segments that entered. The [MultiMesh] is a *shared*
## sub-resource of the scene (`resource_local_to_scene` is off), so each of those
## parses wrote the same 4,700 transforms into the same buffer: ~262 MB of CSV read
## and ~1.3 M `set_instance_transform()` calls per rebuild, for a result that was
## already there. The layout is applied once per [MultiMesh] instead, so a rebuild
## costs the trees their scene instantiation and nothing else.
##
## The scene also carries a baked copy of the layout, so a run with no CSV at all (a
## stripped export, a moved file) keeps the foliage it was saved with and says so,
## instead of silently losing it.

const LEAF_LAYOUT_PATH := "res://worlds/scrolling_track/props/rural/tree_data/leaf_instances.csv"

# The [MultiMesh]es a layout has been applied to, by instance id. Keyed by the mesh
# rather than by the path so that a scene whose mesh is local to the instance - its
# own buffer, its own copy of the layout - still gets its own pass, while the shared
# one is filled once. The entry is written only after a successful open, so a missing
# file is reported every time a tree is built rather than once.
static var _filled_meshes: Dictionary = {}


func _ready() -> void:
	if multimesh == null or _filled_meshes.has(multimesh.get_instance_id()):
		return
	var csv_file := FileAccess.open(LEAF_LAYOUT_PATH, FileAccess.READ)
	if csv_file == null:
		push_error(
			"ParticleTree (%s): cannot open `%s`, so the leaves keep the layout "
			% [name, LEAF_LAYOUT_PATH]
			+ "the scene was saved with."
		)
		return
	_filled_meshes[multimesh.get_instance_id()] = true

	csv_file.get_csv_line(",")  # the column headers
	for i in multimesh.instance_count:
		var row := csv_file.get_csv_line(",")
		if row.size() < 10:
			# A layout shorter than the mesh's instance count: the instances that are
			# not in it stay where the scene was saved, which is better than a
			# half-built tree.
			break
		var position := Vector3(float(row[0]), float(row[2]), -float(row[1]))
		var scale := Vector3(float(row[3]), float(row[5]), -float(row[4]))
		scale *= 0.2
		scale.y *= 3
		var rotation := Quaternion(float(row[7]), float(row[9]), -float(row[8]), float(row[6]))
		multimesh.set_instance_transform(i, calc_transform_3d(position, rotation, scale))
	csv_file.close()


func calc_transform_3d(
	position_3d: Vector3, rotation_3d: Quaternion, scale_3d: Vector3
) -> Transform3D:
	# Create basis from rotation, then apply local scale
	var basis = Basis.from_euler(rotation_3d.get_euler()).scaled_local(scale_3d)
	# Combine basis and position into the final transform
	return Transform3D(basis, position_3d)
