extends Node


func _ready() -> void:
	var gpu_name := RenderingServer.get_video_adapter_name()
	if "Adreno" in gpu_name and "640" in gpu_name:
		get_viewport().scaling_3d_scale = 1.0
