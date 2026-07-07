@tool
extends Node
class_name MorphController

var _morph_values: Dictionary = {}
var morph_control: MorphControl = preload("res://scripts/data/morph_control/morph_control_table.tres")

var target_skeleton: Node3D
var face_mesh: Node3D
var blend_shape_cache: Dictionary[StringName, int]


static func _morph_names() -> PackedStringArray:
	return PackedStringArray([
		"にこり右", "にこり左", "真面目右", "真面目左",
		"困る右", "困る左", "困る２", "怒り右", "怒り左", "怒り２",
		"下右", "下左", "上右", "上左", "眉左", "眉右",
		"ｳｨﾝｸ２右", "ウィンク２", "ウィンク右", "ウィンク",
		"ｷﾘｯ", "なごみ", "びっくり", "じと目", "瞳小",
		"笑い目", "笑い目２", "ぷく～_左", "ぷく～_右", "ん",
		"~~", "にっこり", "口角上げ", "□", "▲", "ω□",
		"にやり２", "にやり3", "にやり", "にぃー",
		"あ", "い", "う", "お", "え", "口角下げ",
		"ぺろっ", "てへぺろ", "ぺろっ2", "てへぺろ2", "ぺろっ3",
		"口上", "口下", "口左", "口右", "口横広げ", "口横狭い",
	])


func _get_property_list() -> Array:
	var props: Array = []
	for _name in _morph_names():
		props.append({
			"name": _name,
			"type": TYPE_FLOAT,
			"usage": PROPERTY_USAGE_DEFAULT,
		})
	return props


func _get(property: StringName):
	if property in _morph_values:
		return _morph_values[property]
	return null


func _set(property: StringName, value: Variant) -> bool:
	if property in _morph_values or property in _morph_names():
		_morph_values[property] = value
		if face_mesh:
			_blend_apply(property, value)
		return true
	return false

func _ready() -> void:
	wake()


func wake() -> void:
	var root := get_parent()
	target_skeleton = get_node("../Skeleton3D")
	var mesh_name := "007_mtl_chr1041_50_face_001"
	
	if root.has_method("get_player_data"):
			var pd = root.get_player_data()
			if pd and pd.face_mesh:
				mesh_name = pd.face_mesh
	elif "player_data" in root:
		var pd = root.player_data
		if pd and pd.face_mesh:
			mesh_name = pd.face_mesh

	face_mesh = target_skeleton.find_child(mesh_name)
	if face_mesh == null:
		push_warning("MorphController: face mesh '%s' not found" % mesh_name)
		return

	blend_shape_cache.clear()
	for i in face_mesh.get_blend_shape_count():
		var bl_name = face_mesh.mesh.get_blend_shape_name(i)
		blend_shape_cache[bl_name] = i

	for property in _morph_values:
		var value = _morph_values[property]
		if value:
			_blend_apply(property, value)


func _blend_apply(property: StringName, value: float) -> void:
	if not morph_control.entities.has(property):
		return
	var raw_names = morph_control.entities[property].names.values()
	for i in raw_names.slice(0, 1):
		var fuzzy_names: Array[StringName] = blend_shape_cache.keys().filter(func(x): return i in x)
		var fuzzy_name = fuzzy_names[0] if len(fuzzy_names) > 0 else &""
		var remap_idx = blend_shape_cache.get(fuzzy_name, 0)
		face_mesh.set_blend_shape_value(remap_idx, value)
	
