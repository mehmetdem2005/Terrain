extends SceneTree

# Terrain3D tarzi gri tonlu firca maskesi PNG'leri uretir.
# Calistir: godot --headless -s tools/gen_brushes.gd

const SIZE := 256
const OUT := "res://addons/terrain_tools/brushes/"


func _hash2(x: int, y: int) -> float:
	var n := (x * 73856093) ^ (y * 19349663)
	return float(n & 0xffff) / 65535.0


func _smooth(a: float, b: float, t: float) -> float:
	return smoothstep(a, b, t)


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var nz := FastNoiseLite.new()
	nz.noise_type = FastNoiseLite.TYPE_SIMPLEX
	nz.frequency = 0.03
	var cr := FastNoiseLite.new()
	cr.noise_type = FastNoiseLite.TYPE_CELLULAR
	cr.frequency = 0.025
	cr.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB

	var names := ["soft", "ring", "gauss", "square",
			"star", "noise", "splatter", "cracks"]
	for nm in names:
		var img := Image.create(SIZE, SIZE, false, Image.FORMAT_L8)
		for y in SIZE:
			for x in SIZE:
				var nx := (float(x) / float(SIZE - 1)) * 2.0 - 1.0
				var ny := (float(y) / float(SIZE - 1)) * 2.0 - 1.0
				var d := sqrt(nx * nx + ny * ny)
				var v := 0.0
				match nm:
					"soft":
						v = _smooth(1.0, 0.0, d)
					"ring":
						var k := (d - 0.62) / 0.2
						v = clampf(exp(-k * k), 0.0, 1.0)
					"gauss":
						v = clampf(exp(-d * d * 4.0) - 0.018, 0.0, 1.0)
					"square":
						var ch := maxf(absf(nx), absf(ny))
						v = 1.0 - _smooth(0.82, 1.0, ch)
					"star":
						if d < 1.0:
							var ang := atan2(ny, nx)
							var lobe := 0.5 + 0.5 * cos(ang * 5.0)
							var rad := 0.45 + 0.55 * pow(lobe, 1.5)
							v = _smooth(rad, rad * 0.55, d)
					"noise":
						var nn := nz.get_noise_2d(x, y) * 0.5 + 0.5
						v = _smooth(1.0, 0.0, d) * (0.25 + 0.75 * nn)
					"splatter":
						if d < 1.0:
							var s := cr.get_noise_2d(x, y) * 0.5 + 0.5
							v = clampf(_smooth(0.45, 0.62, s), 0.0, 1.0)
							v *= _smooth(1.0, 0.6, d)
					"cracks":
						if d < 1.0:
							var c := absf(cr.get_noise_2d(x, y))
							v = clampf(1.0 - _smooth(0.0, 0.10, c), 0.0, 1.0)
							v *= _smooth(1.0, 0.7, d)
				img.set_pixel(x, y, Color(v, v, v))
		var p: String = OUT + nm + ".png"
		img.save_png(p)
		print("yazildi: ", p)
	quit()
