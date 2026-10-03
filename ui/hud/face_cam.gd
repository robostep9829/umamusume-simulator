extends ColorRect
class_name FaceCam

@export var character_controller: ThirdPersonController


func _ready() -> void:
	var viewport: SubViewport = character_controller.get_node("Skeleton3D/SubViewport")
	viewport.size = size
	var face_material: ShaderMaterial = material
	face_material.set_shader_parameter("render_target", viewport.get_texture())
