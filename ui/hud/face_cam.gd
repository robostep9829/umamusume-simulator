extends ColorRect
class_name FaceCam

@export var character_controller: ThirdPersonController


func _ready() -> void:
	var viewport: SubViewport = character_controller.get_node("Skeleton3D/SubViewport")
	viewport.size = size
	# `self.` is needed because this local shadows the property it reads.
	var material: ShaderMaterial = self.material
	material.set_shader_parameter("render_target", viewport.get_texture())
