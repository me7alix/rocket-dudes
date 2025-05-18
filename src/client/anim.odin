package client

import rl "vendor:raylib"
import "core:sync"
import "core:math"
import "core:fmt"
import "../logic"

Animation :: struct {
	texture: rl.Texture2D,
	txPos: rl.Vector2,
	size: rl.Vector2,
	offset: rl.Vector2,
	delta, length: i32,
	spriteID: i32,
	speed: f32,
}

animWalkR := Animation{
	txPos = {0, 78},
	size = {-47, 45},
	offset = {-3, 5},
	length = 10,
	delta = 49,
}

animWalkL := Animation{
	txPos = {0, 78},
	size = {47, 45},
	offset = {-13, 5},
	length = 10,
	delta = 49,
}

animIdleR := Animation{
	txPos = {5, 18},
	size = {-47, 45},
	offset = {-3, 8},
	length = 1,
}

animIdleL := Animation{
	txPos = {5, 18},
	size = {47, 45},
	offset = {-14, 8},
	length = 1,
}

animJumpR := Animation{	
	txPos = {0, 204},
	size = {-47, 55},
	offset = {-3, 5},
	length = 4,
	delta = 47,
}

animJumpL := Animation{
	txPos = {0, 204},
	size = {47, 55},
	offset = {-14, 5},
	length = 4,
	delta = 47,
}

animBombExpl := Animation{
	txPos = {0, 507},
	size = {45, 30},
	offset = {-20, -5},
	length = 16,
	delta = 40,
}

anim_draw :: proc(a: ^Animation, pos: rl.Vector2, destSize: rl.Vector2 = {0, 0}) {
	txPos := a.txPos + {f32(a.delta*(a.spriteID%a.length)), 0}
	rl.DrawTextureRec(a.texture, {txPos.x, txPos.y, a.size.x, a.size.y}, pos+a.offset, rl.WHITE)
}

player_anim :: proc(pi: logic.PlayerInfo, isMe: bool, intrPos: rl.Vector2) {
	pos := intrPos 
	if isMe {
		pos = screenPlayerPos
	}

	if pi.onGround {
		if pi.moveDir > 0 {
			animWalkR.spriteID = i32(rl.GetTime() * 9)
			anim_draw(&animWalkR, pos)
		} else if pi.moveDir < 0 {
			animWalkL.spriteID = i32(rl.GetTime() * 9)
			anim_draw(&animWalkL, pos)
		} else {
			if pi.lastMoveDir > 0 {
				anim_draw(&animIdleR, pos)
			} else {
				anim_draw(&animIdleL, pos)
			}
		}
	} else {
		spriteID := i32(0)
		if math.abs(pi.vel.y) < 3 {
			spriteID = 3
		} else if math.abs(plinf.vel.y) < 8 {
			spriteID = 2
		} else if math.abs(plinf.vel.y) < 12 {
			spriteID = 1
		} else {
			spriteID = 0
		}
		if pi.lastMoveDir > 0 {
			animJumpR.spriteID = spriteID
			anim_draw(&animJumpR, pos)
		} else {
			animJumpL.spriteID = spriteID
			anim_draw(&animJumpL, pos)
		}
	}
}

ExplosionAnim :: struct {
	pos: rl.Vector2,
	anim: Animation,
	timer: f32,
}

explAnims: [dynamic]ExplosionAnim
eaMutex: sync.Mutex

expl_anim_add :: proc(pos: rl.Vector2) {
	if sync.mutex_guard(&eaMutex) {
		append(&explAnims, ExplosionAnim{pos, animBombExpl, 0.0})
	}
}

expl_anim_update :: proc() {
	if sync.mutex_guard(&eaMutex) {
		for i := 0; i < len(explAnims); i+=1 {
			explAnims[i].anim.spriteID = i32(explAnims[i].timer * 13)
			if explAnims[i].anim.spriteID >= explAnims[i].anim.length {
				unordered_remove(&explAnims, i)
				i -= 1
				continue
			}
			anim_draw(&explAnims[i].anim, explAnims[i].pos-camera.pos)
			explAnims[i].timer += rl.GetFrameTime()
		}
	}
}
