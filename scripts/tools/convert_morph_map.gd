@tool
extends Node


func _ready():
	if Engine.is_editor_hint():
		return
	convert_()


func convert_():
	var path = "res://scripts/data/morph_control/map.txt"
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		printerr("Failed to open: ", path)
		return

	var morph_control = MorphControl.new()

	while not file.eof_reached():
		var line = file.get_line().strip_edges()
		if line.is_empty():
			continue

		var parts = line.split(" -> ")
		if parts.size() != 2:
			continue

		var expr = parts[0].strip_edges()
		var morphs_str = parts[1].strip_edges()

		morphs_str = morphs_str.trim_prefix("[").trim_suffix("]")
		var morph_names: Array[StringName] = []
		for m in morphs_str.split(","):
			var name = m.strip_edges().lstrip("'\"").rstrip("'\"")
			if not name.is_empty():
				morph_names.append(StringName(name))

		var entry = MorphControlEntry.new()
		for i in range(morph_names.size()):
			entry.names[i] = morph_names[i]
		morph_control.entities[StringName(expr)] = entry

	file.close()

	var out_path = "res://scripts/data/morph_control/morph_control_table.tres"
	var result = ResourceSaver.save(morph_control, out_path)
	if result == OK:
		print("Saved ", morph_control.entities.size(), " entries to ", out_path)
	else:
		printerr("Save failed: error code ", result)
