@tool
extends MeshInstance3D
const MAPREND_VERSION := "0.2.3b"   # fix: read signed int8 for altitude
# 9/1/25 <--- now it renders negative z values correctly.... !!!!!!!

@export var map_mul_path: String = "res://assets/data/map0.mul"
@export var tiles_w: int = 16
@export var tiles_h: int = 16
@export var z_scale: float = 0.5

@export var rebuild_now: bool = false : set = _do_rebuild
@export var export_obj_now: bool = false : set = _do_export
@export var clear_now: bool = false : set = _do_clear
@export var out_obj_path: String = "res://assets/maps/map_small.obj"

var _H: PackedFloat32Array

const SUBDIV_PER_TILE: int = 6
const EPS: float = 0.5

func _ready() -> void:
	if Engine.is_editor_hint():
		_load_heights()
		_build_mesh()

func _do_rebuild(v: bool) -> void:
	if !Engine.is_editor_hint() or !v: return
	rebuild_now = false
	_load_heights()
	_build_mesh()

func _do_export(v: bool) -> void:
	if !Engine.is_editor_hint() or !v: return
	export_obj_now = false
	if _H.is_empty(): _load_heights()
	_export_obj()

func _do_clear(v: bool) -> void:
	if !Engine.is_editor_hint() or !v: return
	clear_now = false
	if mesh and mesh is ArrayMesh: (mesh as ArrayMesh).clear_surfaces()
	mesh = null
	_H = PackedFloat32Array()

# --- helpers ---
static func _read_i8(f: FileAccess) -> int:
	# FileAccess.get_8() returns 0..255. Convert to signed -128..127.
	var b := f.get_8()
	return b - 256 if b >= 128 else b

# ================= MUL loader =================
func _load_heights() -> void:
	var f := FileAccess.open(map_mul_path, FileAccess.READ)
	if f == null:
		push_error("MapRend: cannot open %s" % map_mul_path)
		return
	f.big_endian = false

	_H = PackedFloat32Array()
	_H.resize(tiles_w * tiles_h)

	var bx_count := int(ceil(tiles_w / 8.0))
	var by_count := int(ceil(tiles_h / 8.0))
	var block_size := 196 # 4 + 64*(2+1)

	var need_bytes := bx_count * by_count * block_size
	if need_bytes > f.get_length():
		push_warning("MapRend: need %d bytes, file has %d" % [need_bytes, f.get_length()])

	var min_h := 9999
	var max_h := -9999

	# column-major blocks: (bx * blocks_down + by) * 196
	for bx in range(bx_count):
		for by in range(by_count):
			var block_index := bx * by_count + by
			var seek_pos := block_index * block_size
			if seek_pos + block_size > f.get_length(): continue
			f.seek(seek_pos)

			f.get_32() # header

			for cy in range(8):
				for cx in range(8):
					if f.get_position() + 3 > f.get_length(): break
					var tile_id := f.get_16() & 0xFFFF
					var z := _read_i8(f)              # <-- signed altitude!
					var x := bx * 8 + cx
					var y := by * 8 + cy
					if x < tiles_w and y < tiles_h:
						_H[y * tiles_w + x] = float(z)
						if z < min_h: min_h = z
						if z > max_h: max_h = z

	f.close()
	print_rich("[b]MapRend[/b] heights loaded: %dx%d tiles (blocks %dx%d), z range %d..%d" %
		[tiles_w, tiles_h, bx_count, by_count, min_h, max_h])

# ================= Sampling & normals =================
func _tile_h(tx: int, ty: int) -> float:
	tx = clampi(tx, 0, tiles_w - 1)
	ty = clampi(ty, 0, tiles_h - 1)
	return _H[ty * tiles_w + tx] * z_scale

func _corner_h(ix: int, iy: int) -> float:
	var h00 := _tile_h(ix - 1, iy - 1)
	var h10 := _tile_h(ix,     iy - 1)
	var h01 := _tile_h(ix - 1, iy)
	var h11 := _tile_h(ix,     iy)
	return 0.25 * (h00 + h10 + h01 + h11)

func _h(x: float, y: float) -> float:
	var x0 := int(floor(x))
	var y0 := int(floor(y))
	var fx := x - float(x0)
	var fy := y - float(y0)
	var h00 := _corner_h(x0,     y0)
	var h10 := _corner_h(x0 + 1, y0)
	var h01 := _corner_h(x0,     y0 + 1)
	var h11 := _corner_h(x0 + 1, y0 + 1)
	return lerp(lerp(h00, h10, fx), lerp(h01, h11, fx), fy)

func _n(x: float, y: float) -> Vector3:
	var hL := _h(x - EPS, y)
	var hR := _h(x + EPS, y)
	var hD := _h(x, y - EPS)
	var hU := _h(x, y + EPS)
	return Vector3(-(hR - hL), 2.0, -(hU - hD)).normalized()

# ================= Mesh build / OBJ export (unchanged) =================
func _build_mesh() -> void:
	if _H.is_empty():
		push_warning("MapRend: no height data")
		return
	var sub := SUBDIV_PER_TILE
	var gw := tiles_w * sub + 1
	var gh := tiles_h * sub + 1
	var V := PackedVector3Array()
	var N := PackedVector3Array()
	V.resize(gw * gh)
	N.resize(gw * gh)
	for gy in range(gh):
		var y := float(gy) / float(sub)
		for gx in range(gw):
			var x := float(gx) / float(sub)
			var h := _h(x, y)
			var idx := gy * gw + gx
			V[idx] = Vector3(x, h, y)
			N[idx] = _n(x, y)
	var I := PackedInt32Array()
	I.resize((gw - 1) * (gh - 1) * 6)
	var w := 0
	for gy in range(gh - 1):
		for gx in range(gw - 1):
			var v00 := gy * gw + gx
			var v10 := v00 + 1
			var v01 := v00 + gw
			var v11 := v01 + 1
			I[w + 0] = v00; I[w + 1] = v10; I[w + 2] = v11
			I[w + 3] = v00; I[w + 4] = v11; I[w + 5] = v01
			w += 6
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = V
	arrays[Mesh.ARRAY_NORMAL] = N
	arrays[Mesh.ARRAY_INDEX]  = I
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	mat.roughness = 0.95
	m.surface_set_material(0, mat)
	mesh = m

func _v_index(gx: int, gy: int, gw: int) -> int:
	return gy * gw + gx + 1

func _export_obj() -> void:
	if _H.is_empty():
		push_warning("MapRend: no height data to export")
		return
	var sub := SUBDIV_PER_TILE
	var gw := tiles_w * sub + 1
	var gh := tiles_h * sub + 1
	var sb := PackedStringArray()
	sb.append("# maprend %s" % MAPREND_VERSION)
	sb.append("o uo_map_small")
	for gy in range(gh):
		var y := float(gy) / float(sub)
		for gx in range(gw):
			var x := float(gx) / float(sub)
			var h := _h(x, y)
			sb.append("v %f %f %f" % [x, h, y])
	for gy in range(gh - 1):
		for gx in range(gw - 1):
			var v00 := _v_index(gx,     gy,     gw)
			var v10 := _v_index(gx + 1, gy,     gw)
			var v01 := _v_index(gx,     gy + 1, gw)
			var v11 := _v_index(gx + 1, gy + 1, gw)
			sb.append("f %d %d %d" % [v00, v10, v11])
			sb.append("f %d %d %d" % [v00, v11, v01])
	var out := FileAccess.open(out_obj_path, FileAccess.WRITE)
	if out:
		out.store_string("\n".join(sb)); out.close()
	else:
		push_error("MapRend: cannot write OBJ to %s" % out_obj_path)
