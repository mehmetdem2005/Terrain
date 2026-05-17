@tool
extends Node3D
class_name TerrainChunkManager
# =====================================================================
#  CDLOD TERRAIN MANAGER  -  Godot 4.6  (YALNIZ Forward Mobile)
#  Eski 100 sabit chunk + skirt sistemi KALDIRILDI. Yerine:
#   - quadtree LOD secimi (kameraya gore dinamik blok)
#   - tek paylasilan grid mesh + tek global heightmap dokusu
#   - shader'da geomorphing -> pop YOK, catlak YOK, skirt YOK
#   - fareyi takip eden tek kayan HeightMapShape3D collision
#  Veriyi terrain_baker.gd "ARAZI HAZIRLA" uretir.
# =====================================================================

@export_group("Paths")
@export_file("*.bin") var height_file: String = "res://terrain/height.bin"
@export_file("*.json") var meta_file: String = "res://terrain/cdlod_meta.json"

@export_group("Target")
@export var target_path: NodePath

@export_group("World")
## Arazinin dunya kenar uzunlugu (metre)
@export var world_size: float = 5120.0
## Ham yukseklik (0..1) -> metre
@export var height_scale: float = 340.0
@export var height_offset: float = 0.0
## Acik ise arazi dunya orijinine ortali
@export var auto_center: bool = true

@export_group("CDLOD")
## LOD0 (en detayli) gorunur menzili (metre). range_i = base_range * 2^i
@export var base_range: float = 140.0
## Geomorph baslangic orani (menzilin bu kadarindan sonra morph baslar)
@export var morph_start_ratio: float = 0.72
## Havuz ust siniri (ayni anda cizilebilecek blok)
@export var max_nodes: int = 1024

@export_group("Collision")
@export var enable_collision: bool = true
## Fare cevresi collision penceresi (texel; tek collider, fareyi takip eder)
@export var collision_window: int = 129
## Hedef bu kadar metre kayinca collision penceresi yeniden kurulur
@export var collision_rebuild_dist: float = 24.0
@export_flags_3d_physics var collision_layer: int = 1

@export_group("Rendering")
@export var terrain_shader: Shader

@export_group("Editor Preview")
@export var show_in_editor: bool = true
## Editor onizlemesinin tek-tip cizecegi LOD seviyesi
@export var editor_preview_level: int = 3

@export_group("Debug")
@export var verbose_log: bool = false


# --- ic durum ---
var _target: Node3D
var _hr: int = 0
var _leaves: int = 0
var _leaf_grid: int = 32
var _lod_levels: int = 7
var _world_min: Vector2 = Vector2.ZERO
var _height_tex: ImageTexture
var _height_img: Image
var _grid_mesh: ArrayMesh
var _ranges: PackedFloat32Array = PackedFloat32Array()
var _lvl_min: Array = []          # Array[PackedFloat32Array] per level
var _lvl_max: Array = []
var _pool: Array[MeshInstance3D] = []
var _used: int = 0
var _frustum: Array = []
var _cam_pos: Vector3 = Vector3.ZERO
var _col_body: StaticBody3D
var _col_shape: HeightMapShape3D
var _col_center: Vector2 = Vector2(INF, INF)
var _editor_busy: bool = false
var _editor_nodes: Array[Node] = []


func _ready() -> void:
	if Engine.is_editor_hint():
		_editor_refresh()
		return
	add_to_group("terrain")
	if target_path != NodePath():
		_target = get_node_or_null(target_path) as Node3D
	if not _init_common():
		return
	if verbose_log:
		print("[CDLOD] HR=%d leaves=%d grid=%d levels=%d world=%.0fm"
			% [_hr, _leaves, _leaf_grid, _lod_levels, world_size])


func _process(_dt: float) -> void:
	if Engine.is_editor_hint():
		return
	if _target == null or _grid_mesh == null:
		return
	var cam := _get_camera()
	if cam == null:
		return
	_cam_pos = cam.global_position
	_build_frustum(cam)
	_used = 0
	var root_lv := _lod_levels - 1
	_lod_select(root_lv, 0, 0)
	for i in range(_used, _pool.size()):
		_pool[i].visible = false
	if enable_collision:
		_update_collision()


# === KURULUM =========================================================
func _init_common() -> bool:
	if not FileAccess.file_exists(meta_file):
		push_error("[CDLOD] meta yok: " + meta_file)
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(meta_file))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[CDLOD] meta cozumlenemedi.")
		return false
	var meta: Dictionary = parsed
	_hr = int(meta.get("hr", 0))
	_leaves = int(meta.get("leaves", 0))
	_leaf_grid = int(meta.get("leaf_grid", 32))
	_lod_levels = int(meta.get("lod_levels", 7))
	if _hr <= 0 or _leaves <= 0:
		push_error("[CDLOD] meta gecersiz.")
		return false
	if not FileAccess.file_exists(height_file):
		push_error("[CDLOD] height yok: " + height_file)
		return false
	var bytes := FileAccess.get_file_as_bytes(height_file)
	var expected := _hr * _hr * 4
	if bytes.size() != expected:
		push_error("[CDLOD] height boyutu hatali: %d / %d" % [bytes.size(), expected])
		return false
	_height_img = Image.create_from_data(_hr, _hr, false, Image.FORMAT_RF, bytes)
	_height_tex = ImageTexture.create_from_image(_height_img)

	var half := world_size * 0.5 if auto_center else 0.0
	_world_min = Vector2(-half, -half)

	_build_pyramid(meta.get("leaf_minmax", []))
	_build_grid_mesh(_leaf_grid)

	_ranges = PackedFloat32Array()
	for i in _lod_levels:
		_ranges.append(base_range * pow(2.0, float(i)))
	return true


func _build_pyramid(leaf_minmax: Array) -> void:
	_lvl_min = []
	_lvl_max = []
	var s := _leaves
	var lvl0_min := PackedFloat32Array()
	var lvl0_max := PackedFloat32Array()
	lvl0_min.resize(s * s)
	lvl0_max.resize(s * s)
	for i in range(s * s):
		var e: Dictionary = leaf_minmax[i] if i < leaf_minmax.size() else {"min": 0.0, "max": 1.0}
		lvl0_min[i] = float(e.get("min", 0.0))
		lvl0_max[i] = float(e.get("max", 1.0))
	_lvl_min.append(lvl0_min)
	_lvl_max.append(lvl0_max)
	var cur := s
	while cur > 1:
		var nxt := cur >> 1
		var pm := _lvl_min[_lvl_min.size() - 1] as PackedFloat32Array
		var px := _lvl_max[_lvl_max.size() - 1] as PackedFloat32Array
		var nm := PackedFloat32Array()
		var nX := PackedFloat32Array()
		nm.resize(nxt * nxt)
		nX.resize(nxt * nxt)
		for y in nxt:
			for x in nxt:
				var a := (2 * y) * cur + (2 * x)
				var b := a + 1
				var c := a + cur
				var d := c + 1
				nm[y * nxt + x] = minf(minf(pm[a], pm[b]), minf(pm[c], pm[d]))
				nX[y * nxt + x] = maxf(maxf(px[a], px[b]), maxf(px[c], px[d]))
		_lvl_min.append(nm)
		_lvl_max.append(nX)
		cur = nxt


func _build_grid_mesh(g: int) -> void:
	var n := g + 1
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for j in n:
		for i in n:
			var u := float(i) / float(g)
			var v := float(j) / float(g)
			verts.append(Vector3(u, 0.0, v))   # [0..1] XZ
			uvs.append(Vector2(u, v))
	for j in g:
		for i in g:
			var a := j * n + i
			var b := a + 1
			var c := a + n
			var d := c + 1
			# cull_back ile UST yuzey gorunecek dogru sarim
			idx.append_array([a, b, c, b, d, c])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	_grid_mesh = ArrayMesh.new()
	_grid_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	# genis custom AABB: shader vertex'i tasidigi icin culling'i biz yapariz
	_grid_mesh.custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))


# === QUADTREE LOD SECIMI ============================================
func _node_size(lv: int) -> float:
	return world_size / float(_leaves >> lv)


func _node_aabb(lv: int, nx: int, ny: int) -> AABB:
	var sz := _node_size(lv)
	var per := _leaves >> lv
	var mn: PackedFloat32Array = _lvl_min[lv]
	var mx: PackedFloat32Array = _lvl_max[lv]
	var hi := mx[ny * per + nx] * height_scale + height_offset
	var lo := mn[ny * per + nx] * height_scale + height_offset
	var ox := _world_min.x + float(nx) * sz
	var oz := _world_min.y + float(ny) * sz
	return AABB(Vector3(ox, lo, oz),
				Vector3(sz, maxf(hi - lo, 1.0), sz))


## Frustum'u projeksiyon matrisinden cikar (Gribb-Hartmann). get_frustum()
## bu ortamda dejenere oldugu icin guvenilir kendi hesabimiz. Yalniz YAN 4
## plane (sol/sag/alt/ust) - terrain icin near/far gereksiz, derinlik
## konvansiyonundan bagimsiz.
func _build_frustum(cam: Camera3D) -> void:
	var p := cam.get_camera_projection()
	var v := Projection(cam.global_transform.affine_inverse())
	var m := p * v
	# satir i = (m.x[i], m.y[i], m.z[i], m.w[i])  (Godot Projection sutun-major)
	var r0 := Vector4(m.x.x, m.y.x, m.z.x, m.w.x)
	var r1 := Vector4(m.x.y, m.y.y, m.z.y, m.w.y)
	var r3 := Vector4(m.x.w, m.y.w, m.z.w, m.w.w)
	_frustum = [r3 + r0, r3 - r0, r3 + r1, r3 - r1]  # sol, sag, alt, ust


func _aabb_in_frustum(box: AABB) -> bool:
	# Gribb-Hartmann kanonik test: clip-space'te ic = (w + x >= 0) ... her
	# plane icin a*x+b*y+c*z+d >= 0. Kutunun bu plane yonunde EN uzak kosesi
	# (p-vertex) bile negatifse kutu tamamen disarida -> elenir.
	for pl in _frustum:
		var pv: Vector4 = pl
		var bx := box.position.x + (box.size.x if pv.x >= 0.0 else 0.0)
		var by := box.position.y + (box.size.y if pv.y >= 0.0 else 0.0)
		var bz := box.position.z + (box.size.z if pv.z >= 0.0 else 0.0)
		if pv.x * bx + pv.y * by + pv.z * bz + pv.w < 0.0:
			return false
	return true


func _sphere_hits_aabb(center: Vector3, r: float, box: AABB) -> bool:
	var cx := clampf(center.x, box.position.x, box.position.x + box.size.x)
	var cy := clampf(center.y, box.position.y, box.position.y + box.size.y)
	var cz := clampf(center.z, box.position.z, box.position.z + box.size.z)
	var dx := center.x - cx
	var dy := center.y - cy
	var dz := center.z - cz
	return dx * dx + dy * dy + dz * dz <= r * r


func _lod_select(lv: int, nx: int, ny: int) -> void:
	var box := _node_aabb(lv, nx, ny)
	if not _aabb_in_frustum(box):
		return
	if lv == 0:
		_emit(0, nx, ny)
		return
	if not _sphere_hits_aabb(_cam_pos, _ranges[lv - 1], box):
		_emit(lv, nx, ny)               # tum blok bu seviyede
		return
	# bir kismi daha detay istiyor -> cocuklara in
	var bx := nx * 2
	var by := ny * 2
	_lod_select(lv - 1, bx, by)
	_lod_select(lv - 1, bx + 1, by)
	_lod_select(lv - 1, bx, by + 1)
	_lod_select(lv - 1, bx + 1, by + 1)


func _emit(lv: int, nx: int, ny: int) -> void:
	if _used >= max_nodes:
		return
	var sz := _node_size(lv)
	var ox := _world_min.x + float(nx) * sz
	var oz := _world_min.y + float(ny) * sz
	var mi := _acquire(_used)
	var mat: ShaderMaterial = mi.material_override
	var endd := _ranges[lv]
	var startd := endd * morph_start_ratio
	mat.set_shader_parameter("node_origin", Vector2(ox, oz))
	mat.set_shader_parameter("node_size", sz)
	mat.set_shader_parameter("morph_start", startd)
	mat.set_shader_parameter("morph_end", endd)
	mat.set_shader_parameter("cam_pos", _cam_pos)
	mi.visible = true
	_used += 1


func _acquire(i: int) -> MeshInstance3D:
	while _pool.size() <= i:
		var mi := MeshInstance3D.new()
		mi.mesh = _grid_mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := ShaderMaterial.new()
		mat.shader = terrain_shader
		_set_static_uniforms(mat)
		mi.material_override = mat
		add_child(mi)
		mi.owner = null
		_pool.append(mi)
	return _pool[i]


func _set_static_uniforms(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("height_tex", _height_tex)
	mat.set_shader_parameter("world_min", _world_min)
	mat.set_shader_parameter("world_size", world_size)
	mat.set_shader_parameter("height_scale", height_scale)
	mat.set_shader_parameter("height_offset", height_offset)
	mat.set_shader_parameter("hr", float(_hr))
	mat.set_shader_parameter("grid_cells", float(_leaf_grid))


func _get_camera() -> Camera3D:
	if _target is Camera3D:
		return _target
	return get_viewport().get_camera_3d()


## Dunya (x,z) noktasindaki arazi yuksekligi (metre). Oyuncuyu zemine
## oturtmak / spawn icin disaridan cagrilabilir. Bilineer ornekleme.
func get_terrain_height(wx: float, wz: float) -> float:
	if _height_img == null or _hr <= 1:
		return height_offset
	var u := clampf((wx - _world_min.x) / world_size, 0.0, 1.0)
	var v := clampf((wz - _world_min.y) / world_size, 0.0, 1.0)
	var fx := u * float(_hr - 1)
	var fy := v * float(_hr - 1)
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var x1 := mini(x0 + 1, _hr - 1)
	var y1 := mini(y0 + 1, _hr - 1)
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var h00 := _height_img.get_pixel(x0, y0).r
	var h10 := _height_img.get_pixel(x1, y0).r
	var h01 := _height_img.get_pixel(x0, y1).r
	var h11 := _height_img.get_pixel(x1, y1).r
	var h := lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), ty)
	return h * height_scale + height_offset


# === COLLISION (fareyi takip eden tek kayan pencere) =================
func _update_collision() -> void:
	var w := collision_window
	var ws := world_size / float(_hr - 1)            # metre / texel
	var tp := _target.global_position
	if _col_center.distance_to(Vector2(tp.x, tp.z)) < collision_rebuild_dist \
	and _col_body != null:
		return
	# hedefin texel koordinati
	var tcx := int(round((tp.x - _world_min.x) / ws))
	var tcy := int(round((tp.z - _world_min.y) / ws))
	var x0 := clampi(tcx - w / 2, 0, _hr - w - 1)
	var y0 := clampi(tcy - w / 2, 0, _hr - w - 1)
	var data := PackedFloat32Array()
	data.resize(w * w)
	for ry in w:
		for rx in w:
			var hraw := _height_img.get_pixel(x0 + rx, y0 + ry).r
			data[ry * w + rx] = hraw * height_scale + height_offset
	if _col_body == null:
		_col_shape = HeightMapShape3D.new()
		_col_shape.map_width = w
		_col_shape.map_depth = w
		var cs := CollisionShape3D.new()
		cs.shape = _col_shape
		_col_body = StaticBody3D.new()
		_col_body.collision_layer = collision_layer
		_col_body.collision_mask = 0
		_col_body.add_child(cs)
		_col_body.scale = Vector3(ws, 1.0, ws)
		add_child(_col_body)
	_col_shape.map_data = data
	# pencere merkezinin dunya konumu (HeightMapShape3D merkezde ortali)
	var wcx := _world_min.x + (float(x0) + float(w - 1) * 0.5) * ws
	var wcz := _world_min.y + (float(y0) + float(w - 1) * 0.5) * ws
	_col_body.position = Vector3(wcx, 0.0, wcz)
	_col_center = Vector2(tp.x, tp.z)


# === EDITOR ONIZLEME ================================================
func _editor_refresh() -> void:
	if _editor_busy:
		return
	_editor_busy = true
	_clear_editor_preview()
	if not show_in_editor or terrain_shader == null:
		_editor_busy = false
		return
	if not _init_common():
		_editor_busy = false
		return
	var lv := clampi(editor_preview_level, 0, _lod_levels - 1)
	var per := _leaves >> lv
	var sz := _node_size(lv)
	for ny in per:
		for nx in per:
			var mi := MeshInstance3D.new()
			mi.name = "preview_%d_%d" % [nx, ny]
			mi.mesh = _grid_mesh
			var mat := ShaderMaterial.new()
			mat.shader = terrain_shader
			_set_static_uniforms(mat)
			mat.set_shader_parameter("node_origin",
				Vector2(_world_min.x + nx * sz, _world_min.y + ny * sz))
			mat.set_shader_parameter("node_size", sz)
			mat.set_shader_parameter("morph_start", 1e9)
			mat.set_shader_parameter("morph_end", 1e9)
			mat.set_shader_parameter("cam_pos", Vector3.ZERO)
			mi.material_override = mat
			add_child(mi)
			mi.owner = null
			_editor_nodes.append(mi)
	if verbose_log:
		print("[CDLOD] Editor onizleme: %d blok (lv %d)" % [per * per, lv])
	_editor_busy = false


func _clear_editor_preview() -> void:
	for nd in _editor_nodes:
		if is_instance_valid(nd):
			nd.queue_free()
	_editor_nodes.clear()
	for ch in get_children():
		if ch is MeshInstance3D and ch.name.begins_with("preview_"):
			ch.queue_free()
