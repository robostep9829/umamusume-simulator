extends ColorRect
class_name FaceCam

@export var character_controller: ThirdPersonController

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.
	var viewport : SubViewport = character_controller.get_node("Skeleton3D/SubViewport")
	viewport.size = self.size
	var texture = viewport.get_texture()
	var material : ShaderMaterial = self.material
	material.set_shader_parameter("render_target", texture)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass
	
func _gui_input(event: InputEvent) -> void:
	pass
