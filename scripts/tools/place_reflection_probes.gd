@tool
extends Node3D

@export_group("Grid Layout")
@export var grid_center: Vector3 = Vector3(0, 0, 0)
@export var grid_size: Vector2i = Vector2i(10, 10)
@export var probe_spacing: float = 30.0

@export_group("Sampling")
@export var terrain_parent_path: NodePath = NodePath("../uma-island")
@export var probe_height_offset: float = 2.0
@export var sample_search_radius: float = 12.0
@export var min_surface_height: float = -1000.0

@export_group("Probe Settings")
@export_enum("ReflectionProbe", "LightmapProbe") var probe_type: int = 0
@export var probe_size: Vector3 = Vector3(20, 10, 20)

@export_group("Actions")
@export var _generate: bool = false:
	set(v):
		if v and Engine.is_editor_hint():
			place_probes()
			_generate = false
			notify_property_list_changed()

@export var _clear: bool = false:
	set(v):
		if v and Engine.is_editor_hint():
			clear_probes()
			_clear = false
			notify_property_list_changed()


func place_probes() -> void:
	clear_probes()

	var probes_container := Node3D.new()
	probes_container.name = "Probes"
	add_child(probes_container, true)
	probes_container.set_owner(get_tree().edited_scene_root)

	var half_x := (grid_size.x - 1) * probe_spacing * 0.5
	var half_z := (grid_size.y - 1) * probe_spacing * 0.5
	var count := 0

	for ix in grid_size.x:
		for iz in grid_size.y:
			var x := grid_center.x - half_x + ix * probe_spacing
			var z := grid_center.z - half_z + iz * probe_spacing

			var surface_y: Variant = _sample_surface_y(x, z)
			if surface_y == null or surface_y < min_surface_height:
				continue

			var probe: Node3D
			if probe_type == 0:
				var rp := ReflectionProbe.new()
				rp.size = probe_size
				probe = rp
			else:
				probe = LightmapProbe.new()

			probe.name = "Probe_%d_%d" % [ix, iz]
			probe.position = Vector3(x, surface_y + probe_height_offset, z)
			probes_container.add_child(probe, true)
			probe.set_owner(get_tree().edited_scene_root)
			count += 1

	print("Placed %d %s probes." % [count, "reflection" if probe_type == 0 else "lightmap"])


func clear_probes() -> void:
	var existing := get_node_or_null("Probes")
	if existing:
		existing.queue_free()


func _sample_surface_y(x: float, z: float) -> Variant:
	var terrain_node := get_node_or_null(terrain_parent_path)
	if not terrain_node:
		return null

	var best_y := -INF
	var found := false
	var sqr_radius := sample_search_radius * sample_search_radius

	for child in terrain_node.get_children():
		var mi := child as MeshInstance3D
		if not mi or not mi.mesh:
			continue
		var mesh := mi.mesh
		var xform := mi.global_transform
		for surf_idx in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surf_idx)
			if arrays.is_empty():
				continue
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			if verts.is_empty():
				continue
			for v in verts:
				var global_v := xform * v
				var dx := global_v.x - x
				var dz := global_v.z - z
				if dx * dx + dz * dz <= sqr_radius:
					if global_v.y > best_y:
						best_y = global_v.y
						found = true

	return best_y if found else null
