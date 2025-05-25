package server

import "core:sync"
import "core:math/rand"
import "core:math"
import "core:time"
import "../logic"
import rl "vendor:raylib"

physicIters := 4
deltaTime: f32

player_handle_explosion :: proc(plinf: ^logic.PlayerInfo, expPacket: logic.PacketExplosion) {
	if logic.intersect_circle_rect(expPacket.pos, logic.ROCKET_EXP_RAD, 
		plinf.pos, plinf.pos + logic.PLAYER_RECT) {

		expVec := (plinf.pos + logic.PLAYER_RECT/2.0) - expPacket.pos
		maxRad := expPacket.rad + logic.PLAYER_RECT.y/2.0
		normForce := math.clamp(1 - rl.Vector2Length(expVec) / maxRad, 0, 1)

		plinf.vel += rl.Vector2Normalize(expVec) * normForce * logic.ROCKET_EXP_FORCE
		if plinf.id != expPacket.id {
			plinf.health -= normForce * logic.ROCKET_EXP_DAMAGE
			if plinf.health <= 0 {
				player_respawn(plinf)
			}
		}
	}
}

player_respawn :: proc(plinf: ^logic.PlayerInfo) {
	plinf.pos = logic.MAP_POS + 
	{logic.MAP_SIZE*rand.float32(), -200}
	plinf.health = 100
	plinf.vel = {0, 0}
}

player_update_physic :: proc(plinf: ^logic.PlayerInfo) {
	for i := 0; i < physicIters; i+=1 {
		plinf.vel.y += 20 * deltaTime / f32(physicIters)
		plinf.pos += plinf.vel / f32(physicIters) * deltaTime / 0.016
		if plinf.moveDir == -1 {
			plinf.pos.x -= deltaTime * logic.PLAYER_SPEED / f32(physicIters)
			plinf.lastMoveDir = -1
		}
		if plinf.moveDir == 1 {
			plinf.pos.x += deltaTime * logic.PLAYER_SPEED / f32(physicIters)
			plinf.lastMoveDir = 1
		}
		logic.map_solve_collision(m, plinf)
	}
	if plinf.onGround {
		plinf.vel.x = 0
	}
	if plinf.pos.y > logic.MAP_POS.y + logic.MAP_SIZE + 200 {
		player_respawn(plinf)
	}
}

players_update_thread :: proc() {
	prev: time.Tick

	for {
		curr := time.tick_now()
		deltaDur := time.tick_diff(prev, curr)
		deltaTime = f32(time.duration_seconds(deltaDur))
		prev = curr

		if sync.mutex_guard(&psMutex) {
			for _, &player in players {
				player.shootingTimer += deltaTime
				player.diggingTimer += deltaTime
				player_update_physic(&player.playerInfo)
			}
		}

		time.sleep(time.Millisecond * 10)
	}
}
