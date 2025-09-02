@tool
extends MeshInstance3D
const MAPREND_VERSION := "0.2.3a"   # fix: use get_16() & 0xFFFF; column-major; signed alt; LE
# This is working and utilized on 9/1/25 ... may have z value problems... to fix.... 7:22pm 9/1/25

# --- Minimal inputs ---
@export var map_mul_path: String = "res://assets/data/map0.mul"
@export var tiles_w: int = 16
@export var tiles_h: int = 16
@export var z_scale: float = 0.5

# --- Minimal actions ---
@export var rebuild_now: bool = false : set = _do_rebuild
@export var export_obj_now: bool = false : set = _do_export
@export var clear_now: bool = false : set = _do_clear
@export var out_obj_path: String = "res://assets/maps/map_small.obj"

var _H: PackedFloat32Array          # tile-center heights (tiles_w * tiles_h)

# Fixed internal settings:
const SUBDIV_PER_TILE: int = 6
const EPS: float = 0.5

func _ready() -> void:
	if Engine.is_editor_hint():
		_load_heights()
		_build_mesh()

# ================= UI handlers =================
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

# ================= MUL loader =================
# Reads enough 8x8 blocks to cover tiles_w x tiles_h; extra samples are ignored later.
func _load_heights() -> void:
	var f := FileAccess.open(map_mul_path, FileAccess.READ)
	if f == null:
		push_error("MapRend: cannot open %s" % map_mul_path)
		return

	# MUL is little-endian
	f.big_endian = false

	_H = PackedFloat32Array()
	_H.resize(tiles_w * tiles_h)

	var bx_count: int = int(ceil(tiles_w / 8.0))
	var by_count: int = int(ceil(tiles_h / 8.0))
	var block_size: int = 196  # 4 + 64*(2+1)

	var need_bytes: int = bx_count * by_count * block_size
	if need_bytes > f.get_length():
		push_warning("MapRend: reading %d bytes (need) from %d-byte file; truncation possible." % [need_bytes, f.get_length()])

	# Column-major block order in map.mul:
	# offset = (bx * blocks_down + by) * 196
	for bx in range(bx_count):
		for by in range(by_count):
			var block_index: int = bx * by_count + by
			var seek_pos: int = block_index * block_size
			if seek_pos + block_size > f.get_length():
				continue
			f.seek(seek_pos)

			# 4-byte header (unused)
			f.get_32()

			for cy in range(8):
				for cx in range(8):
					# Each cell: uint16 tile_id (unused), int8 altitude (signed)
					if f.get_position() + 3 > f.get_length():
						break
					var tile_id: int = f.get_16() & 0xFFFF  # keep LE, make unsigned if needed
					var z: int = f.get_8()                  # signed altitude (-128..127)
					# (tile_id currently unused; kept for clarity)
					var x: int = bx * 8 + cx
					var y: int = by * 8 + cy
					if x < tiles_w and y < tiles_h:
						_H[y * tiles_w + x] = float(z)
	f.close()

	print_rich("[b]MapRend[/b] heights loaded: %sx%s tiles, blocks %sx%s" % [tiles_w, tiles_h, bx_count, by_count])

# ================= Sampling & normals =================
func _tile_h(tx: int, ty: int) -> float:
	tx = clampi(tx, 0, tiles_w - 1)
	ty = clampi(ty, 0, tiles_h - 1)
	return _H[ty * tiles_w + tx] * z_scale

# Corner estimate from 4 neighboring tile centers
func _corner_h(ix: int, iy: int) -> float:
	var h00 := _tile_h(ix - 1, iy - 1)
	var h10 := _tile_h(ix,     iy - 1)
	var h01 := _tile_h(ix - 1, iy)
	var h11 := _tile_h(ix,     iy)
	return 0.25 * (h00 + h10 + h01 + h11)

# Continuous height at fractional (x,y)
func _h(x: float, y: float) -> float:
	var x0: int = int(floor(x))
	var y0: int = int(floor(y))
	var x1: int = x0 + 1
	var y1: int = y0 + 1
	var fx: float = x - float(x0)
	var fy: float = y - float(y0)
	var h00 := _corner_h(x0, y0)
	var h10 := _corner_h(x1, y0)
	var h01 := _corner_h(x0, y1)
	var h11 := _corner_h(x1, y1)
	return lerp(lerp(h00, h10, fx), lerp(h01, h11, fx), fy)

# Central-difference normal (smooth)
func _n(x: float, y: float) -> Vector3:
	var hL := _h(x - EPS, y)
	var hR := _h(x + EPS, y)
	var hD := _h(x, y - EPS)
	var hU := _h(x, y + EPS)
	var dx := hR - hL
	var dy := hU - hD
	return Vector3(-dx, 2.0, -dy).normalized()

# ================= Mesh build =================
func _build_mesh() -> void:
	if _H.is_empty():
		push_warning("MapRend: no height data")
		return

	var sub: int = SUBDIV_PER_TILE
	var gw: int = tiles_w * sub + 1
	var gh: int = tiles_h * sub + 1

	var V := PackedVector3Array()
	var N := PackedVector3Array()
	V.resize(gw * gh)
	N.resize(gw * gh)

	for gy in range(gh):
		var y: float = float(gy) / float(sub)
		for gx in range(gw):
			var x: float = float(gx) / float(sub)
			var h: float = _h(x, y)
			var idx: int = gy * gw + gx
			V[idx] = Vector3(x, h, y)   # Y-up
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
			# CCW
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

# ================= OBJ export =================
func _v_index(gx: int, gy: int, gw: int) -> int:
	return gy * gw + gx + 1

func _export_obj() -> void:
	if _H.is_empty():
		push_warning("MapRend: no height data to export")
		return

	var sub: int = SUBDIV_PER_TILE
	var gw: int = tiles_w * sub + 1
	var gh: int = tiles_h * sub + 1

	var sb := PackedStringArray()
	sb.append("# maprend %s" % MAPREND_VERSION)
	sb.append("o uo_map_small")

	# vertices
	for gy in range(gh):
		var y: float = float(gy) / float(sub)
		for gx in range(gw):
			var x: float = float(gx) / float(sub)
			var h: float = _h(x, y)
			sb.append("v %f %f %f" % [x, h, y])

	# faces CCW
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
		out.store_string("\n".join(sb))
		out.close()
	else:
		push_error("MapRend: cannot write OBJ to %s" % out_obj_path)
