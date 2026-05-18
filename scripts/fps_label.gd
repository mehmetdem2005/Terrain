extends Label
# Kucuk FPS gostergesi (sol ust). Sadece gorsel, girisi engellemez.

func _process(_dt: float) -> void:
	text = "FPS %d" % Engine.get_frames_per_second()
