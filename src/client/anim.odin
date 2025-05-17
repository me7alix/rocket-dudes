package client

import rl "vendor:raylib"

Animation :: struct {
	texture: rl.Texture2D,
	txPos: rl.Vector2,
	size: rl.Vector2,
	offset: rl.Vector2,
	delta, length: i32,
	spriteID: i32,
	speed: f32,
}

anim_draw :: proc(a: ^Animation, pos: rl.Vector2) {
	txPos := a.txPos + {f32(a.delta*(a.spriteID%a.length)), 0}
	rl.DrawTextureRec(a.texture, {txPos.x, txPos.y, a.size.x, a.size.y}, pos+a.offset, rl.WHITE)
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
