package logic

import rl "vendor:raylib"
import "core:math"

Voxel :: struct {
	isIntact, isColored: bool,
	children: [4]u32,
}

voxelsPos := [4]rl.Vector2 {
	{0, 0}, {1, 0},
	{0, 1}, {1, 1},
}

ROOT_VOX :: 0
MAX_VOXELS :: 100000
VOX_SIZE :: 3000
MAX_DEPTH :: 11
MAP_POS :: rl.Vector2{100, 200}

Map :: struct {
	voxels: [MAX_VOXELS]Voxel,
	emptyIndces: [MAX_VOXELS]u32,
	ptr: u32,
}

MAX_MAP_CHANGES :: 4096

MapChange :: struct {
	pos: rl.Vector2,
	rad: f32, 
}

MapChanges :: struct {
	count: u32,
	changes: [MAX_MAP_CHANGES]MapChange,
}

map_add :: proc(m: ^Map, voxel: Voxel) -> u32 {
	m.voxels[m.emptyIndces[m.ptr]] = voxel
	m.ptr -= 1
	return m.emptyIndces[m.ptr + 1]
}

map_remove :: proc(m: ^Map, ind: u32) {
	m.ptr += 1
	m.emptyIndces[m.ptr] = ind
}


intersect_circle_rect :: proc(
	cpos: rl.Vector2,
	crad: f32,
	bmin, bmax: rl.Vector2
) -> bool {
	closestX := math.clamp(cpos.x, bmin.x, bmax.x)
	closestY := math.clamp(cpos.y, bmin.y, bmax.y)

	dx := cpos.x - closestX
	dy := cpos.y - closestY

	return dx*dx + dy*dy <= crad * crad
}

map_accept_change :: proc(m: ^Map, change: MapChange) {
	map_remove_circle(m, change.pos, change.rad)
}

map_remove_circle :: proc(m: ^Map,
	spos: rl.Vector2,
	srad: f32
) { 
	remove_circle_req :: proc(
		m: ^Map,
		spos: rl.Vector2, 
		srad: f32,
		vpos: rl.Vector2,
		vi: u32,
		depth: u32
	) {
		size := VOX_SIZE / math.pow_f32(2, f32(depth))
		if intersect_circle_rect(spos, srad, vpos, vpos+size) {
			if depth == MAX_DEPTH {
				m.voxels[vi].isColored = false
				m.voxels[vi].isIntact = true
				return
			}
			if m.voxels[vi].isIntact {
				m.voxels[vi].isIntact = false
				for i := 0; i < 4; i+=1 {
					m.voxels[vi].children[i] = map_add(m, Voxel{
						isIntact = true,
						isColored = m.voxels[vi].isColored,
					})
				}
			}
			m.voxels[vi].isColored = false
			for i := 0; i < 4; i+=1 {
				remove_circle_req(m, spos, srad, vpos + voxelsPos[i] * size * 0.5,
					m.voxels[vi].children[i], depth+1)
			}
			for i := 0; i < 4; i+=1 {
				vox := m.voxels[m.voxels[vi].children[i]]
				if !(vox.isIntact && !vox.isColored) {
					return 
				}
			}
			m.voxels[vi].isIntact = true
			m.voxels[vi].isColored = false
			for i := 0; i < 4; i+=1 {
				map_remove(m, m.voxels[vi].children[i]) 
			}
		}
	}

	remove_circle_req(
		m, spos, srad,
		MAP_POS, ROOT_VOX, 0
	)
}

map_add_circle :: proc(
	m: ^Map,
	spos: rl.Vector2,
	srad: f32
) {
	add_circle_req :: proc(
		m: ^Map, spos: rl.Vector2, srad: f32, 
		vpos: rl.Vector2, vi: u32, depth: u32
	) {
		size := VOX_SIZE / math.pow_f32(2, f32(depth))
		if intersect_circle_rect(spos, srad, vpos, vpos+size) {
			if depth == MAX_DEPTH {
				m.voxels[vi].isColored = true
				m.voxels[vi].isIntact = true
				return
			}
			if m.voxels[vi].isIntact {
				m.voxels[vi].isIntact = false
				for i := 0; i < 4; i+=1 {
					m.voxels[vi].children[i] = map_add(m, Voxel{
						isIntact = true,
						isColored = m.voxels[vi].isColored,
					})
				}
			}
			m.voxels[vi].isColored = true
			for i := 0; i < 4; i+=1 {
				add_circle_req(m, spos, srad, vpos + voxelsPos[i] * size * 0.5,
					m.voxels[vi].children[i], depth+1)
			}
			for i := 0; i < 4; i+=1 {
				vox := m.voxels[m.voxels[vi].children[i]]
				if !(vox.isIntact && vox.isColored) {
					return 
				}
			}
			m.voxels[vi].isIntact = true
			m.voxels[vi].isColored = true
			for i := 0; i < 4; i+=1 {
				map_remove(m, m.voxels[vi].children[i]) 
			}
		}
	}

	add_circle_req(m, spos, srad, MAP_POS, ROOT_VOX, 0)
}

map_draw :: proc(m: ^Map, plpos: rl.Vector2) {
	draw_req :: proc(
		m: ^Map, plpos: rl.Vector2, ind: u32,
		pos: rl.Vector2, depth: u32
	) {
		size := VOX_SIZE / math.pow_f32(2, f32(depth))
		if m.voxels[ind].isIntact && m.voxels[ind].isColored {
			rl.DrawRectangleV(pos - plpos, {size, size}, rl.GREEN)
			//rl.DrawRectangleLines(i32((pos - plpos).x), i32((pos - plpos).y), i32(size), i32(size), rl.DARKGREEN)
		} 
		if !m.voxels[ind].isIntact {
			for i := 0; i < 4; i+=1 {
				draw_req(m, plpos, m.voxels[ind].children[i], 
					pos + voxelsPos[i] * (size / 2.0), depth+1)
			}
		}
	}

	draw_req(m, plpos, ROOT_VOX, MAP_POS, 0)
}

map_solve_collision :: proc(m: ^Map, plinf: ^PlayerInfo, onGround: ^bool) {
	onGround^ = false
	collide_req :: proc(
		m: ^Map, plinf: ^PlayerInfo, onGround: ^bool,
		vi: u32, vpos: rl.Vector2, depth: u32
	) {
		size := VOX_SIZE / math.pow_f32(2, f32(depth))

		if !(plinf.pos.x < vpos.x + size && plinf.pos.x + PLAYER_RECT.x > vpos.x &&
		plinf.pos.y < vpos.y + size && plinf.pos.y + PLAYER_RECT.y > vpos.y) { return }

		if m.voxels[vi].isIntact && m.voxels[vi].isColored {
			dt := (plinf.pos + PLAYER_RECT/2.0) - (vpos + size/2.0)
			//dt.x /= PLAYER_RECT.y / PLAYER_RECT.x
			if math.abs(dt.x) > math.abs(dt.y) {
				plinf.vel.x = 0
				if dt.x > 0 {
					plinf.pos.x = vpos.x + size 
				} else {
					plinf.pos.x = vpos.x - PLAYER_RECT.x
				}
			} else {
				plinf.vel.y = 0
				if dt.y > 0 {
					plinf.pos.y = vpos.y + size
				} else {
					plinf.pos.y = vpos.y - PLAYER_RECT.y
					onGround^ = true
				}
			}
		}

		if !m.voxels[vi].isIntact {
			for i := 0; i < 4; i+=1 {
				collide_req(m, plinf, onGround, m.voxels[vi].children[i], 
					vpos + voxelsPos[i] * size / 2.0, depth+1)
			}
		}
	}

	collide_req(m, plinf, onGround, 
		ROOT_VOX, MAP_POS, 0)
}

map_detect_collision :: proc(
	m: ^Map,
	pos: rl.Vector2, 
	rect: rl.Vector2
) -> bool {
	retVal := false
	collide_req :: proc(
		m: ^Map,
		pos: rl.Vector2,
		rect: rl.Vector2,
		vi: u32,
		vpos: rl.Vector2, 
		depth: u32,
		retVal: ^bool
	) {
		size := VOX_SIZE / math.pow_f32(2, f32(depth))

		if !(pos.x < vpos.x + size && pos.x + rect.x > vpos.x &&
		pos.y < vpos.y + size && pos.y + rect.y > vpos.y) { return }

		if m.voxels[vi].isIntact && m.voxels[vi].isColored {
			retVal^ = true
			return 
		}

		if !m.voxels[vi].isIntact {
			for i := 0; i < 4; i+=1 {
				collide_req(
					m, pos, rect, 
					m.voxels[vi].children[i], 
					vpos + voxelsPos[i] * size / 2.0, 
					depth+1, retVal
				)
			}
		}
	}

	collide_req(m, pos, rect, ROOT_VOX, MAP_POS, 0, &retVal)
	return retVal
}

map_alloc :: proc() -> ^Map {
	m := new(Map)
	m.ptr = MAX_VOXELS-1
	for i := u32(0); i < MAX_VOXELS; i+=1 {
		m.emptyIndces[i] = MAX_VOXELS-i-1;
	}
	map_add(m, Voxel{
		isIntact = true,
		isColored = true,
	})
	return m
}
