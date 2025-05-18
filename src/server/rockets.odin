package server

import "core:net"
import "core:mem"
import "core:sync"
import "core:time"
import "core:fmt"
import "../logic/"
import rl "vendor:raylib"

rocketBox := rl.Vector2{logic.ROCKET_RAD, logic.ROCKET_RAD}*2

rocket_check_outside :: proc(rocket: logic.Rocket) -> bool {
	return rocket.pos.x > logic.MAP_POS.x + logic.VOX_SIZE + 1000 || 
	rocket.pos.x < logic.MAP_POS.x - 1000 ||
	rocket.pos.y > logic.MAP_POS.y + logic.VOX_SIZE + 1000 || 
	rocket.pos.y < logic.MAP_POS.y - 1200 
}

rocket_check_meatshot :: proc(rocket: logic.Rocket, buf: []u8) -> bool {
	isHit := false

	change := logic.PacketMapChange{
		type = .MAP_CHANGE,
		mapChange = {rocket.pos, logic.ROCKET_EXP_RAD}
	}

	explosion := logic.PacketExplosion{
		type = .EXPLOSION,
		id = rocket.id,
		pos = rocket.pos,
		rad = logic.ROCKET_EXP_RAD,
	}

	if sync.mutex_guard(&psMutex) {
		if sync.mutex_guard(&tsMutex) {
			for _, player in players {
				if logic.intersect_circle_rect(rocket.pos, logic.ROCKET_RAD, player.playerInfo.pos,
					player.playerInfo.pos + logic.PLAYER_RECT) && rocket.id != player.playerInfo.id {
					isHit = true
					break
				}
			}
		}
	}

	if isHit {
		if sync.mutex_guard(&mMutex) {
			logic.map_accept_change(m, change.mapChange)
		}
		if sync.mutex_guard(&mcMutex) {
			mapChanges.changes[mapChanges.count] = change.mapChange
			mapChanges.count += 1
		}
		if sync.mutex_guard(&tsMutex) {
			for _, pl in players {
				mem.copy(mem.raw_data(buf[:]), &change, size_of(change))
				net.send_tcp(pl.tcpSock, buf[:size_of(change)])
				time.sleep(time.Microsecond * 250)

				mem.copy(mem.raw_data(buf[:]), &explosion, size_of(explosion))
				net.send_tcp(pl.tcpSock, buf[:size_of(explosion)])
				time.sleep(time.Microsecond*250)
			}
		}
	}

	return isHit
}

rocket_map_collision :: proc(rocket: logic.Rocket, buf: []u8) -> bool {
	sync.mutex_lock(&mMutex)
	isCollision := logic.map_detect_collision(m, rocket.pos-(rocketBox/2.0), rocketBox)
	sync.mutex_unlock(&mMutex)

	if !isCollision {
		return false
	}

	change := logic.PacketMapChange{
		type = .MAP_CHANGE,
		mapChange = {rocket.pos, logic.ROCKET_EXP_RAD}
	}

	explosion := logic.PacketExplosion{
		type = .EXPLOSION,
		id = rocket.id,
		pos = rocket.pos,
		rad = logic.ROCKET_EXP_RAD,
	}

	if sync.mutex_guard(&mMutex) {
		logic.map_accept_change(m, change.mapChange)
	}

	if sync.mutex_guard(&mcMutex) {
		mapChanges.changes[mapChanges.count] = change.mapChange
		mapChanges.count += 1
	}

	if sync.mutex_guard(&psMutex) {
		if sync.mutex_guard(&tsMutex) {
			for _, player in players {
				mem.copy(mem.raw_data(buf[:]), &change, size_of(change))
				net.send_tcp(player.tcpSock, buf[:size_of(change)])
				time.sleep(time.Microsecond * 250)

				mem.copy(mem.raw_data(buf[:]), &explosion, size_of(explosion))
				net.send_tcp(player.tcpSock, buf[:size_of(explosion)])
				time.sleep(time.Microsecond * 250)
			}
		}
	}

	return true
}

rockets_udpate_thread :: proc() {
	buf: [2048]u8
	prev := time.tick_now()

	for {
		defer time.sleep(time.Millisecond * 6)

		curr := time.tick_now()
		deltaDur := time.tick_diff(prev, curr)
		dt := f32(time.duration_seconds(deltaDur))
		prev = curr

		for i := 0; i < len(rockets); i+=1 {
			rocket: logic.Rocket

			if sync.mutex_guard(&rsMutex) {
				rockets[i].pos += rockets[i].dir * dt * logic.ROCKET_SPEED
				rocket = rockets[i]
			}

			if rocket_map_collision(rocket, buf[:]) {
				if sync.mutex_guard(&rsMutex) {
					unordered_remove(&rockets, i)
				}
				i -= 1
			} else if rocket_check_outside(rocket) {
				if sync.mutex_guard(&rsMutex) {
					unordered_remove(&rockets, i)
				}
				i -= 1
			} else if rocket_check_meatshot(rocket, buf[:]) {
				if sync.mutex_guard(&rsMutex) {
					unordered_remove(&rockets, i)
				}
				i -= 1
			}
		}
	}
}
