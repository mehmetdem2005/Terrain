@tool
extends Node3D
class_name TerrainChunkManager
# =====================================================================
#  TERRAIN CHUNK MANAGER  -  Godot 4.6
#  - OYUN MODU: WorkerThreadPool ile arka-thread streaming + LOD + collision
#  - EDITOR MODU: tum chunk'lari aninda yukler (proje acilir acilmaz gorunur)
#  Chunk formati: ham half-float (.bin), terrain_baker.gd uretir.
# =====================================================================

@export_group("Paths")
## Birlestirilmis chunk verisi (tek dosya - Android'de guvenilir)
@export_file("*.bin") var data_file: String = "res://terrain/terrain_data.bin"
## Birlestirilmis metadata dosyasi
@export_file("*.json") var meta_file: String = "res://terrain/terrain_meta.json"

@export_group("Target")
## Etrafinda chunk yuklenecek node (oyuncu fare / kamera) - sadece oyun modu
@export var target_path: NodePath

@export_group("World Scale")
## Bir texel'in metre karsiligi. CHUNK GENISLIGI = texel_size * 128.
@export var texel_size: float = 1.0
## Ham yukseklik degerinin (0..1) metre karsiligi
@export var height_scale: float = 12.0
## Tum araziye uygulanan dikey ofset (metre)
@export var height_offset: float = 0.0
## Acik ise arazi dunya orijinine ortalanir
@export var auto_center: bool = true
## auto_center kapaliyken arazinin baslangic kosesi
@export var terrain_origin: Vector3 = Vector3.ZERO

@export_group("Editor Preview")
## Editorde araziyi gosterir (proje acilinca otomatik kurulur)
@export var show_in_editor: bool = true
## Editor onizlemesinin kullanacagi LOD indeksi (0 = en detayli)
@export var editor_preview_lod: int = 1
## Editor onizlemesini yeniden kurar
@warning_ignore("unused_private_class_variable")
@export_tool_button("Onizlemeyi Yenile") var _btn_refresh = _editor_refresh

@export_group("Streaming")
## Oyun baslarken kamera cevresinde KAC chunk aninda yuklensin
@export var initial_sync_radius: int = 3
## Hedef cevresinde kac chunk yuklensin (yaricap, chunk cinsinden)
@export var load_radius: int = 4
## Bu yaricapin disindaki chunk'lar bosaltilir (>= load_radius olmali)
@export var unload_radius: int = 6
## Her degerlendirmede en fazla kac yeni yukleme istegi acilsin
@export var max_ops_per_frame: int = 3
## Saniyede chunk listesinin kac kez yeniden degerlendirilecegi (sn)
@export var update_interval: float = 0.15

@export_group("LOD")
## LOD gecis mesafeleri (metre). Boyut = lod_subdivisions - 1 olmali
@export var lod_distances: PackedFloat32Array = PackedFloat32Array([90.0, 220.0])
## Her LOD icin PlaneMesh subdivide sayisi. Son eleman en uzak LOD.
@export var lod_subdivisions: PackedInt32Array = PackedInt32Array([110, 40, 14])
## LOD gecisinde titremeyi onleyen tampon bant (metre)
@export var lod_hysteresis: float = 15.0
## Chunk kenarlarina sarkan "etek" derinligi (metre). Farkli LOD'lu
## komsular arasindaki bosluklari gizler. Gizli geometri oldugu icin
## fazla derin olmasi sorun degil; bosluk gorursen artir.
@export var skirt_depth: float = 30.0

@export_group("Collision")
@export var enable_collision: bool = true
## Hedef cevresinde kac chunk'a collision verilsin (yaricap)
@export var collision_radius: int = 2
## Collision Z ekseni gorsel ile ters cikarsa acin
@export var collision_flip_z: bool = false
@export_flags_3d_physics var collision_layer: int = 1

@export_group("Rendering")
@export var terrain_shader: Shader
## Opsiyonel arazi dokusu. Bos ise shader yukseklige gore renklendirir
@export var albedo_texture: Texture2D
@export var cast_shadows: bool = false

@export_group("Debug")
@export var verbose_log: bool = false


# --- ic durum ---
var _target: Node3D
var _meta: Dictionary
var _chunks_per_side: int = 0
var _verts: int = 129
var _tile_bytes: int = 0
var _data_bytes: PackedByteArray = PackedByteArray()
var _chunk_world: float = 128.0
var _origin: Vector3 = Vector3.ZERO
var _lod_meshes: Array[Mesh] = []

var _active: Dictionary = {}
var _pending: Dictionary = {}            # "x_y" -> task_id
var _results: Dictionary = {}            # "x_y" -> Image (thread'den)
var _results_mutex := Mutex.new()
var _pool: Array[MeshInstance3D] = []
var _accum: float = 0.0
var _editor_nodes: Array[Node] = []


func _ready() -> void:
	if Engine.is_editor_hint():
		_editor_refresh()
		return

	if target_path != NodePath():
		_target = get_node_or_null(target_path) as Node3D
	if _target == null:
		push_warning("TerrainChunkManager: 'target_path' atanmamis.")
	if terrain_shader == null:
		push_error("TerrainChunkManager: 'terrain_shader' atanmamis.")
		return
	if not _load_meta():
		return
	_build_lod_meshes()
	_initial_fill()
	_accum = update_interval
	if verbose_log:
		print("[Terrain] %dx%d chunk | chunk %.1f m | yarimada %.0f m"
			% [_chunks_per_side, _chunks_per_side, _chunk_world,
			   _chunks_per_side * _chunk_world])


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _target == null or _chunks_per_side == 0:
		return
	_poll_loads()
	_accum += delta
	if _accum < update_interval:
		return
	_accum = 0.0
	_update_chunks()


# === EDITOR ONIZLEME =================================================
func _editor_refresh() -> void:
	_clear_editor_preview()
	if not show_in_editor:
		return
	if terrain_shader == null:
		push_warning("Editor onizleme: 'terrain_shader' atanmamis.")
		return
	if not _load_meta():
		return
	_build_lod_meshes()
	var lod_i := clampi(editor_preview_lod, 0, _lod_meshes.size() - 1)
	var mesh := _lod_meshes[lod_i]
	var count := 0
	for cy in _chunks_per_side:
		for cx in _chunks_per_side:
			var img := _load_chunk_image(cx, cy)
			if img == null:
				continue
			var mi := MeshInstance3D.new()
			mi.name = "preview_%d_%d" % [cx, cy]
			mi.mesh = mesh
			mi.position = _chunk_pos(cx, cy)
			mi.material_override = _make_material(ImageTexture.create_from_image(img))
			add_child(mi)
			mi.owner = null
			_editor_nodes.append(mi)
			count += 1
	if verbose_log:
		print("[Terrain] Editor onizleme: %d chunk yuklendi." % count)


func _clear_editor_preview() -> void:
	for n in _editor_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_editor_nodes.clear()


# === METADATA & YARDIMCILAR ==========================================
func _load_meta() -> bool:
	if not FileAccess.file_exists(meta_file):
		push_error("Metadata bulunamadi: " + meta_file)
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(meta_file))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Metadata cozumlenemedi.")
		return false
	_meta = parsed
	_chunks_per_side = int(_meta.get("chunks_per_side", 0))
	_verts = int(_meta.get("verts_per_chunk", 129))
	_tile_bytes = int(_meta.get("tile_bytes", _verts * _verts * 4))
	_chunk_world = float(int(_meta.get("chunk", 128))) * texel_size
	if auto_center:
		var half := _chunk_world * float(_chunks_per_side) * 0.5
		_origin = Vector3(-half, terrain_origin.y, -half)
	else:
		_origin = terrain_origin
	# Birlestirilmis veri dosyasini bir kez ac, baytlari bellege al
	if not FileAccess.file_exists(data_file):
		push_error("Veri dosyasi bulunamadi: " + data_file)
		return false
	_data_bytes = FileAccess.get_file_as_bytes(data_file)
	var expected := _tile_bytes * _chunks_per_side * _chunks_per_side
	if _data_bytes.size() != expected:
		push_error("Veri dosyasi boyutu hatali: %d / beklenen %d"
			% [_data_bytes.size(), expected])
		return false
	return _chunks_per_side > 0


func _chunk_pos(cx: int, cy: int) -> Vector3:
	return _origin + Vector3((cx + 0.5) * _chunk_world, 0.0,
							 (cy + 0.5) * _chunk_world)


## Birlestirilmis veriden bir chunk'i offset ile keser, half-float Image dondurur.
func _load_chunk_image(cx: int, cy: int) -> Image:
	if _data_bytes.is_empty():
		return null
	var index := cy * _chunks_per_side + cx
	var offset := index * _tile_bytes
	if offset + _tile_bytes > _data_bytes.size():
		return null
	var slice := _data_bytes.slice(offset, offset + _tile_bytes)
	return Image.create_from_data(_verts, _verts, false, Image.FORMAT_RF, slice)


func _build_lod_meshes() -> void:
	_lod_meshes.clear()
	for sub in lod_subdivisions:
		_lod_meshes.append(_build_grid_mesh(int(sub), skirt_depth))


## Duz grid mesh uretir:
##  - Yarim-texel hizali UV: kenar vertex'leri texel merkezine oturur,
##    boylece komsu chunk'larla AYNI yukseklik degerini orneklerler -> dikis yok.
##  - Skirt: kenar boyunca asagi sarkan duvar -> LOD bosluklarini gizler.
func _build_grid_mesh(subdiv: int, skirt: float) -> ArrayMesh:
	subdiv = maxi(subdiv, 1)
	var hw := _chunk_world * 0.5
	var n := subdiv + 1                        # kenar basina vertex
	var res := float(_verts)                   # texture cozunurlugu (129)
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()

	# --- ana grid ---
	for j in n:
		for i in n:
			var tx := float(i) / float(subdiv)
			var tz := float(j) / float(subdiv)
			verts.append(Vector3(-hw + tx * _chunk_world, 0.0,
								  -hw + tz * _chunk_world))
			# yarim-texel hizali UV
			uvs.append(Vector2((0.5 + tx * (res - 1.0)) / res,
							   (0.5 + tz * (res - 1.0)) / res))
			norms.append(Vector3.UP)
	for j in subdiv:
		for i in subdiv:
			var a := j * n + i
			var b := a + 1
			var c := a + n
			var d := c + 1
			idx.append_array([a, c, b, b, c, d])

	# --- skirt (kenar duvari, gizli oldugu icin cift tarafli) ---
	if skirt > 0.0:
		var base := verts.size()
		var ring: Array[int] = []
		for i in n: ring.append(i)                                  # ust
		for j in range(1, n): ring.append(j * n + (n - 1))          # sag
		for i in range(n - 2, -1, -1): ring.append((n - 1) * n + i) # alt
		for j in range(n - 2, 0, -1): ring.append(j * n)            # sol
		for ri in ring:
			verts.append(verts[ri] + Vector3(0.0, -skirt, 0.0))
			uvs.append(uvs[ri])
			norms.append(Vector3.UP)
		var rc := ring.size()
		for k in rc:
			var ta := ring[k]
			var tb := ring[(k + 1) % rc]
			var ba := base + k
			var bb := base + ((k + 1) % rc)
			# her iki sarim yonu -> hangi taraftan bakilirsa gorunur
			idx.append_array([ta, tb, ba, tb, bb, ba])
			idx.append_array([ta, ba, tb, tb, ba, bb])

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


func _make_material(height_tex: Texture2D) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = terrain_shader
	mat.set_shader_parameter("height_tex", height_tex)
	mat.set_shader_parameter("height_scale", height_scale)
	mat.set_shader_parameter("height_offset", height_offset)
	mat.set_shader_parameter("chunk_world_size", _chunk_world)
	mat.set_shader_parameter("tex_texel", 1.0 / float(_verts - 1))
	mat.set_shader_parameter("use_albedo", albedo_texture != null)
	if albedo_texture != null:
		mat.set_shader_parameter("albedo_tex", albedo_texture)
	return mat


# === OYUN MODU: STREAMING ============================================
func _initial_fill() -> void:
	if _target == null:
		return
	var tpos := _target.global_position - _origin
	var ccx := int(floor(tpos.x / _chunk_world))
	var ccy := int(floor(tpos.z / _chunk_world))
	for dy in range(-initial_sync_radius, initial_sync_radius + 1):
		for dx in range(-initial_sync_radius, initial_sync_radius + 1):
			var cx := ccx + dx
			var cy := ccy + dy
			if cx < 0 or cy < 0 or cx >= _chunks_per_side or cy >= _chunks_per_side:
				continue
			var key := "%d_%d" % [cx, cy]
			if _active.has(key):
				continue
			var img := _load_chunk_image(cx, cy)
			if img != null:
				_spawn_chunk(key, ImageTexture.create_from_image(img))


func _update_chunks() -> void:
	var tpos := _target.global_position - _origin
	var ccx := int(floor(tpos.x / _chunk_world))
	var ccy := int(floor(tpos.z / _chunk_world))

	var ops := 0
	for dy in range(-load_radius, load_radius + 1):
		for dx in range(-load_radius, load_radius + 1):
			var cx := ccx + dx
			var cy := ccy + dy
			if cx < 0 or cy < 0 or cx >= _chunks_per_side or cy >= _chunks_per_side:
				continue
			var key := "%d_%d" % [cx, cy]
			if _active.has(key) or _pending.has(key):
				continue
			if ops >= max_ops_per_frame:
				break
			_request_chunk(cx, cy, key)
			ops += 1

	var to_remove: Array = []
	for key in _active.keys():
		var c: Dictionary = _active[key]
		if absi(int(c["cx"]) - ccx) > unload_radius \
		or absi(int(c["cy"]) - ccy) > unload_radius:
			to_remove.append(key)
	for key in to_remove:
		_despawn_chunk(key)

	for key in _active.keys():
		var c: Dictionary = _active[key]
		_apply_lod(c)
		_apply_collision(c, ccx, ccy)


func _request_chunk(cx: int, cy: int, key: String) -> void:
	var task := WorkerThreadPool.add_task(_load_chunk_task.bind(cx, cy, key))
	_pending[key] = task


func _load_chunk_task(cx: int, cy: int, key: String) -> void:
	var img := _load_chunk_image(cx, cy)
	_results_mutex.lock()
	_results[key] = img
	_results_mutex.unlock()


func _poll_loads() -> void:
	if _pending.is_empty():
		return
	var done: Array = []
	for key in _pending.keys():
		var task: int = _pending[key]
		if not WorkerThreadPool.is_task_completed(task):
			continue
		WorkerThreadPool.wait_for_task_completion(task)
		done.append(key)
		_results_mutex.lock()
		var img: Image = _results.get(key)
		_results.erase(key)
		_results_mutex.unlock()
		if img != null and not _active.has(key):
			_spawn_chunk(key, ImageTexture.create_from_image(img))
	for key in done:
		_pending.erase(key)


func _spawn_chunk(key: String, height_tex: Texture2D) -> void:
	var parts := key.split("_")
	var cx := int(parts[0])
	var cy := int(parts[1])

	var mi: MeshInstance3D = _pool.pop_back()
	if mi == null:
		mi = MeshInstance3D.new()
		add_child(mi)
	mi.visible = true
	mi.position = _chunk_pos(cx, cy)
	mi.material_override = _make_material(height_tex)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var cmin := height_offset
	var cmax := height_scale + height_offset
	var cm: Dictionary = _meta.get("chunks", {}).get(key, {})
	if not cm.is_empty():
		cmin = float(cm.get("min", 0.0)) * height_scale + height_offset
		cmax = float(cm.get("max", 1.0)) * height_scale + height_offset
	mi.custom_aabb = AABB(
		Vector3(-_chunk_world * 0.5, cmin - skirt_depth, -_chunk_world * 0.5),
		Vector3(_chunk_world, maxf(cmax - cmin, 0.1) + skirt_depth, _chunk_world))

	var c := {"node": mi, "cx": cx, "cy": cy, "tex": height_tex,
			  "lod": -1, "col_body": null}
	_active[key] = c
	_apply_lod(c)


func _apply_lod(c: Dictionary) -> void:
	var mi: MeshInstance3D = c["node"]
	var d := _target.global_position.distance_to(mi.global_position)
	var cur := int(c["lod"])
	var want := lod_subdivisions.size() - 1
	for i in lod_distances.size():
		var t := lod_distances[i]
		if cur != -1:
			if i < cur:
				t -= lod_hysteresis
			else:
				t += lod_hysteresis
		if d < t:
			want = i
			break
	if want != cur:
		c["lod"] = want
		mi.mesh = _lod_meshes[want]


func _apply_collision(c: Dictionary, ccx: int, ccy: int) -> void:
	if not enable_collision:
		return
	var near := absi(int(c["cx"]) - ccx) <= collision_radius \
			and absi(int(c["cy"]) - ccy) <= collision_radius
	var body: StaticBody3D = c["col_body"]
	if near and body == null:
		_build_collision(c)
	elif not near and body != null:
		body.queue_free()
		c["col_body"] = null


func _build_collision(c: Dictionary) -> void:
	var tex: Texture2D = c["tex"]
	var img := tex.get_image()
	if img == null:
		return
	if img.get_format() != Image.FORMAT_RF:
		img.convert(Image.FORMAT_RF)
	var w := img.get_width()
	var h := img.get_height()
	var raw := img.get_data().to_float32_array()

	var inv := 1.0 / texel_size
	var data := PackedFloat32Array()
	data.resize(w * h)
	for row in h:
		var src_row := (h - 1 - row) if collision_flip_z else row
		for col in w:
			var v := raw[src_row * w + col]
			data[row * w + col] = (v * height_scale + height_offset) * inv

	var shape := HeightMapShape3D.new()
	shape.map_width = w
	shape.map_depth = h
	shape.map_data = data

	var col := CollisionShape3D.new()
	col.shape = shape

	var body := StaticBody3D.new()
	body.collision_layer = collision_layer
	body.collision_mask = 0
	body.add_child(col)
	body.scale = Vector3(texel_size, texel_size, texel_size)
	body.position = (c["node"] as MeshInstance3D).position
	add_child(body)
	c["col_body"] = body


func _despawn_chunk(key: String) -> void:
	var c: Dictionary = _active[key]
	var mi: MeshInstance3D = c["node"]
	mi.visible = false
	mi.material_override = null
	mi.mesh = null
	c["lod"] = -1
	_pool.append(mi)
	var body: StaticBody3D = c["col_body"]
	if body != null:
		body.queue_free()
	_active.erase(key)


## Runtime arazi duzenleme sonrasi cagir: collision yeniden kurulur.
func refresh_chunk(cx: int, cy: int) -> void:
	var key := "%d_%d" % [cx, cy]
	if not _active.has(key):
		return
	var c: Dictionary = _active[key]
	var body: StaticBody3D = c["col_body"]
	if body != null:
		body.queue_free()
		c["col_body"] = null
