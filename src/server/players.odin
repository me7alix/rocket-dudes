package server

import "core:sync"
import "core:math/rand"
import "core:math"
import "core:time"
import "../shared"
import rl "vendor:raylib"

@(private="file")
prev: time.Tick
@(private="file")
physicIters := 6
@(private="file")
deltaTime: f32

player_handle_explosion :: proc(plinf: ^shared.PlayerInfo, expPacket: shared.PacketExplosion) {
	if shared.intersect_circle_rect(expPacket.pos, shared.ROCKET_EXP_RAD, 
		plinf.pos, plinf.pos + shared.PLAYER_RECT) {

		expVec := (plinf.pos + shared.PLAYER_RECT/2.0) - expPacket.pos
		maxRad := expPacket.rad + shared.PLAYER_RECT.y/2.0
		normForce := math.clamp(1 - rl.Vector2Length(expVec) / maxRad, 0, 1)

		plinf.vel += rl.Vector2Normalize(expVec) * normForce * shared.ROCKET_EXP_FORCE
		if plinf.id != expPacket.id {
			plinf.health -= normForce * shared.ROCKET_EXP_DAMAGE
			if plinf.health <= 0 {
				player_respawn(plinf)
			}
		}
	}
}

@(private="file")
player_respawn :: proc(plinf: ^shared.PlayerInfo) {
	plinf.pos = shared.MAP_POS + 
	{shared.MAP_SIZE*rand.float32(), -200}
	plinf.health = 100
	plinf.vel = {0, 0}
}

@(private="file")
player_update_physic :: proc(plinf: ^shared.PlayerInfo) {
	for i := 0; i < physicIters; i+=1 {
		plinf.vel.y += 20 * deltaTime / f32(physicIters)
		plinf.pos += plinf.vel / f32(physicIters) * deltaTime / 0.016
		if plinf.moveDir == -1 {
			plinf.pos.x -= deltaTime * shared.PLAYER_SPEED / f32(physicIters)
			plinf.lastMoveDir = -1
		}
		if plinf.moveDir == 1 {
			plinf.pos.x += deltaTime * shared.PLAYER_SPEED / f32(physicIters)
			plinf.lastMoveDir = 1
		}
		shared.map_solve_collision(m, plinf)
	}
	if plinf.onGround {
		plinf.vel.x = 0
	}
	if plinf.pos.y > shared.MAP_POS.y + shared.MAP_SIZE + 200 {
		player_respawn(plinf)
	}
}

players_update_thread :: proc() {
	curr := time.tick_now()
	deltaDur := time.tick_diff(prev, curr)
	deltaTime = f32(time.duration_seconds(deltaDur))
	prev = curr

	for _, &player in players {
		player.shootingTimer += deltaTime
		player.diggingTimer += deltaTime
		player_update_physic(&player.playerInfo)
	}

}
