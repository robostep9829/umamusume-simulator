@tool
extends Node


func _ready():
	if Engine.is_editor_hint():
		return
	remap_()


func remap_():
	var glb_paths := PackedStringArray([
		"res://anim/face/celebration.glb",
	])

	for glb_path in glb_paths:
		_process_glb(glb_path)


const TARGET_NODE := "MorphController"

func _process_glb(glb_path: String):
	var src_lib = ResourceLoader.load(glb_path) as AnimationLibrary
	if src_lib == null:
		printerr("Failed to load: ", glb_path)
		return

	var base_name = glb_path.get_file().get_basename()
	var out_dir = "res://anim/face/remapped"
	DirAccess.make_dir_recursive_absolute(out_dir)
	var out_path = out_dir.path_join(base_name + "_face.tres")

	var dst_lib = AnimationLibrary.new()
	for anim_name in src_lib.get_animation_list():
		var src_anim = src_lib.get_animation(anim_name)
		var dst_anim = _remap_animation(src_anim)
		dst_lib.add_animation(anim_name, dst_anim)
		print("  Remapped: ", anim_name)

	var err = ResourceSaver.save(dst_lib, out_path)
	if err == OK:
		print("Saved %s (%d animations)" % [out_path, dst_lib.get_animation_list().size()])
	else:
		printerr("Save failed for %s: %s" % [out_path, error_string(err)])


func _remap_animation(src: Animation) -> Animation:
	var dst = Animation.new()
	dst.length = src.length
	dst.resource_name = src.resource_name

	for i in range(src.get_track_count()):
		var track_type = src.track_get_type(i)
		var track_path = src.track_get_path(i)
		var interp = src.track_get_interpolation_type(i)
		var key_count = src.track_get_key_count(i)

		var new_path = _rewrite_path(track_path)

		var dst_type = track_type
		if track_type == Animation.TYPE_BLEND_SHAPE:
			dst_type = Animation.TYPE_VALUE

		var new_idx = dst.add_track(dst_type)
		dst.track_set_path(new_idx, new_path)
		dst.track_set_interpolation_type(new_idx, interp)

		for j in range(key_count):
			var time = src.track_get_key_time(i, j)
			var value = src.track_get_key_value(i, j)
			var trans = src.track_get_key_transition(i, j)
			dst.track_insert_key(new_idx, time, value, trans)

	return dst


func _rewrite_path(path: NodePath) -> NodePath:
	var path_str = str(path)
	var colon = path_str.find(":")
	if colon >= 0:
		return NodePath(TARGET_NODE + path_str.substr(colon))
	return NodePath(TARGET_NODE)
