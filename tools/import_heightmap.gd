extends SceneTree

# Tek seferlik: yarimada_16bit.exr -> Terrain3D bolge verisi.
# Calistir: godot --headless -s tools/import_heightmap.gd

const SRC := "res://heightmap/yarimada_16bit.exr"
const DST := "res://terrain/terrain_data"
const WORLD_M := 5120.0
const HEIGHT_M := 340.0

var _t: Terrain3D
var _f := 0
var _done := false


func _initialize() -> void:
	print("[imp] basliyor")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DST))
	_t = Terrain3D.new()
	_t.collision_mode = 0
	get_root().add_child(_t)
	print("[imp] tree'ye eklendi; frame bekleniyor")


func _process(_delta: float) -> bool:
	if _done:
		return true
	_f += 1
	if _t.data == null:
		if _f < 120:
			return false
		push_error("[imp] data " + str(_f) + " frame sonra hala null")
		return true
	print("[imp] data hazir (frame ", _f, ")")
	_do_import()
	_done = true
	return true


func _do_import() -> void:
	var img := Terrain3DUtil.load_image(SRC, ResourceLoader.CACHE_MODE_IGNORE)
	if img == null:
		push_error("[imp] EXR yuklenemedi")
		return
	var sz := img.get_size()
	_t.vertex_spacing = WORLD_M / float(maxi(sz.x - 1, 1))
	print("[imp] EXR ", sz, " vertex_spacing=", _t.vertex_spacing)
	var imgs: Array[Image] = []
	imgs.resize(Terrain3DRegion.TYPE_MAX)
	imgs[Terrain3DRegion.TYPE_HEIGHT] = img
	print("[imp] import_images...")
	_t.data.import_images(imgs, Vector3.ZERO, 0.0, HEIGHT_M)
	print("[imp] import bitti, bolge=", _t.data.get_region_count())
	_t.data.calc_height_range(true)
	_t.data.save_directory(DST)
	print("[imp] save -> ", DST)
	var h0 = _t.data.get_height(Vector3(0.0, 0.0, 0.0))
	var h1 = _t.data.get_height(Vector3(100.0, 0.0, 100.0))
	print("[imp] get_height(0,0)=", h0, " (100,100)=", h1, " IMPORT BITTI")
