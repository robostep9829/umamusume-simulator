extends Node

## Cap rendering at 60 FPS: keeps mobile thermals and battery in check and
## matches the fixed 1/60 s exposure the motion blur normalizes to.
const MAX_FPS := 60


func _ready() -> void:
	var gpu_name := RenderingServer.get_video_adapter_name()
	if "Adreno" in gpu_name and "640" in gpu_name:
		get_viewport().scaling_3d_scale = 0.8
		Engine.max_fps = MAX_FPS
