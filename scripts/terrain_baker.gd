@tool
extends Node
class_name TerrainBaker
# =====================================================================
#  TERRAIN BAKER  -  Godot 4.6  (CDLOD)
#  EXR heightmap -> TEK global yukseklik verisi + quadtree min/max meta.
#    terrain/height.bin       (HR x HR, FORMAT_RF, ham 0..1)
#    terrain/cdlod_meta.json  (boyut + leaf min/max piramidi)
#  Eski 10x10 sabit chunk YOK; quadtree = 2^(lod_levels-1) yaprak/yan.
#  Kullanim: TerrainBaker node'unu sec -> Inspector "ARAZI HAZIRLA".
# =====================================================================

@export_group("Bake")
@export_file("*.exr") var source_exr: String = "res://heightmap/yarimada_16bit.exr"
@export_file("*.bin") var height_file: String = "res://terrain/height.bin"
@export_file("*.json") var meta_file: String = "res://terrain/cdlod_meta.json"
## Quadtree LOD seviyesi (yaprak/yan = 2^(levels-1)). 7 -> 64x64=4096 blok.
@export var lod_levels: int = 7
## Paylasilan grid mesh cozunurlugu (kenar basina hucre)
@export var leaf_grid: int = 32
## Arazi EXR'a gore aynali cikarsa ac
@export var flip_y: bool = false

@warning_ignore("unused_private_class_variable")
@export_tool_button("ARAZI HAZIRLA") var _btn_bake = bake


func bake() -> void:
	var src := Image.load_from_file(source_exr)
	if src == null:
		var tex := load(source_exr) as Texture2D
		if tex != null:
			src = tex.get_image()
	if src == null:
		push_error("[Baker] EXR yuklenemedi: " + source_exr)
		return
	src.convert(Image.FORMAT_RF)
	if flip_y:
		src.flip_y()

	var leaves := 1 << (lod_levels - 1)          # yaprak/yan
	var hr := leaves * leaf_grid + 1             # global heightmap cozunurluk
	if src.get_width() != hr or src.get_height() != hr:
		src.resize(hr, hr, Image.INTERPOLATE_BILINEAR)
	print("[Baker] HR=%d  leaves=%d/yan  grid=%d" % [hr, leaves, leaf_grid])

	# --- global height.bin (RF) ---
	var hf := FileAccess.open(height_file, FileAccess.WRITE)
	if hf == null:
		push_error("[Baker] height yazilamadi: " + height_file)
		return
	hf.store_buffer(src.get_data())
	hf.close()

	# --- leaf (LOD0) min/max -> cy*leaves+cx sirasi ---
	var cell := (hr - 1) / leaves                # bir yaprak kac texel
	var g_min := INF
	var g_max := -INF
	var leaf_minmax := []
	for ly in leaves:
		for lx in leaves:
			var c_min := INF
			var c_max := -INF
			var x0 := lx * cell
			var y0 := ly * cell
			for y in range(y0, y0 + cell + 1):
				for x in range(x0, x0 + cell + 1):
					var h := src.get_pixel(x, y).r
					c_min = minf(c_min, h)
					c_max = maxf(c_max, h)
			leaf_minmax.append({"min": c_min, "max": c_max})
			g_min = minf(g_min, c_min)
			g_max = maxf(g_max, c_max)

	var meta := {
		"hr": hr,
		"leaves": leaves,
		"leaf_grid": leaf_grid,
		"lod_levels": lod_levels,
		"format": "rf",
		"data_min": g_min,
		"data_max": g_max,
		"leaf_minmax": leaf_minmax,
	}
	var mf := FileAccess.open(meta_file, FileAccess.WRITE)
	mf.store_string(JSON.stringify(meta))
	mf.close()

	print("[Baker] ARAZI HAZIR -> HR=%d  %d yaprak  aralik %.4f .. %.4f"
			% [hr, leaves * leaves, g_min, g_max])
	if Engine.is_editor_hint():
		var fs := EditorInterface.get_resource_filesystem()
		if fs:
			fs.scan()
