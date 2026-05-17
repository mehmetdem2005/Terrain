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

@export_group("Yumusatma")
## Heightmap yumusatma gecisi sayisi. 8-bit/dusuk bit derinlikli kaynaktaki
## "putur putur" basamaklanmayi (terracing) yok eder. 0 = kapali.
@export_range(0, 12) var smooth_iterations: int = 3
## Yumusatma penceresi yaricapi (texel). Buyudukce daha cok yumusar.
@export_range(1, 8) var smooth_radius: int = 2

@warning_ignore("unused_private_class_variable")
@export_tool_button("ARAZI HAZIRLA") var _btn_bake = bake


## Tek yonlu (yatay) kutu-blur, prefix-toplam ile O(n) (yaricaptan bagimsiz).
## "transpose" true ise dikey gecis icin tampon devrik kabul edilir.
func _blur_axis(buf: PackedFloat32Array, w: int, h: int, r: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(w * h)
	var pre := PackedFloat32Array()
	pre.resize(w + 1)
	for y in h:
		var base := y * w
		pre[0] = 0.0
		for x in w:
			pre[x + 1] = pre[x] + buf[base + x]
		for x in w:
			var a := maxi(0, x - r)
			var b := mini(w - 1, x + r)
			out[base + x] = (pre[b + 1] - pre[a]) / float(b - a + 1)
	return out


func _transpose(buf: PackedFloat32Array, w: int, h: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(w * h)
	for y in h:
		for x in w:
			out[x * h + y] = buf[y * w + x]
	return out


## Ayrilabilir kutu-blur (yatay + dikey), birkac gecis ~ Gauss.
func _smooth(buf: PackedFloat32Array, n: int, r: int, iters: int) -> PackedFloat32Array:
	var b := buf
	for _i in iters:
		b = _blur_axis(b, n, n, r)              # yatay
		b = _transpose(b, n, n)
		b = _blur_axis(b, n, n, r)              # dikey (devrik uzerinde)
		b = _transpose(b, n, n)
	return b


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

	# ham float tampon (RF, hr*hr)
	var H := src.get_data().to_float32_array()
	if smooth_iterations > 0 and smooth_radius > 0:
		H = _smooth(H, hr, smooth_radius, smooth_iterations)
		print("[Baker] yumusatma: %d gecis x yaricap %d"
				% [smooth_iterations, smooth_radius])

	# --- global height.bin (RF) ---
	var hf := FileAccess.open(height_file, FileAccess.WRITE)
	if hf == null:
		push_error("[Baker] height yazilamadi: " + height_file)
		return
	hf.store_buffer(H.to_byte_array())
	hf.close()

	# --- leaf (LOD0) min/max -> cy*leaves+cx sirasi ---
	@warning_ignore("integer_division")
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
				var row := y * hr
				for x in range(x0, x0 + cell + 1):
					var h := H[row + x]
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
