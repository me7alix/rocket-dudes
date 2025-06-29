package server

import "core:net"
import "core:mem"
import "core:sync"
import "core:time"
import "core:fmt"
import "../shared/"
import rl "vendor:raylib"


@(private="file")
rocketBox := rl.Vector2{shared.ROCKET_RAD, shared.ROCKET_RAD}*2
@(private="file")
buf: [1024]u8
@(private="file")
prev: time.Tick
@(private="file")
physicIters := 6

@(private="file")
rocket_check_outside :: proc(rocket: shared.Rocket) -> bool {
	return rocket.pos.x > shared.MAP_POS.x + shared.MAP_SIZE + 1000 || 
	rocket.pos.x < shared.MAP_POS.x - 1000 ||
	rocket.pos.y > shared.MAP_POS.y + shared.MAP_SIZE + 1000 || 
	rocket.pos.y < shared.MAP_POS.y - 1200 
}

@(private="file")
rocket_check_meatshot :: proc(rocket: shared.Rocket, buf: []u8) -> bool {
	isHit := false

	change := shared.PacketMapChange{
		type = .MAP_CHANGE,
		mapChange = {rocket.pos, shared.ROCKET_EXP_RAD}
	}

	explosion := shared.PacketExplosion{
		type = .EXPLOSION,
		id = rocket.id,
		pos = rocket.pos,
		rad = shared.ROCKET_EXP_RAD,
	}

	if sync.mutex_guard(&tsMutex) {
		for _, player in players {
			if shared.intersect_circle_rect(rocket.pos, shared.ROCKET_RAD, player.playerInfo.pos,
				player.playerInfo.pos + shared.PLAYER_RECT) && rocket.id != player.playerInfo.id {
				isHit = true
				break
			}
		}
	}

	if isHit {
		if sync.mutex_guard(&mMutex) {
			shared.map_accept_change(m, change.mapChange)
		}

		if sync.mutex_guard(&mcMutex) {
			mapChanges.changes[mapChanges.count] = change.mapChange
			mapChanges.count += 1
		}

		if sync.mutex_guard(&tsMutex) {
			mem.copy(mem.raw_data(buf[:]), &change, size_of(change))
			for _, player in players {
				net.send_tcp(player.tcpSock, buf[:size_of(change)])
				time.sleep(time.Microsecond * 1)
			}

			time.sleep(time.Microsecond * 1500)
			mem.copy(mem.raw_data(buf[:]), &explosion, size_of(explosion))
			for _, &player in players {
				net.send_tcp(player.tcpSock, buf[:size_of(explosion)])
				player_handle_explosion(&player.playerInfo, explosion)
			}
		}
	}

	return isHit
}

@(private="file")
rocket_map_collision :: proc(rocket: shared.Rocket, buf: []u8) -> bool {
	sync.mutex_lock(&mMutex)
	isCollision := shared.map_detect_collision(m, rocket.pos-(rocketBox/2.0), rocketBox)
	sync.mutex_unlock(&mMutex)

	if !isCollision {
		return false
	}

	change := shared.PacketMapChange{
		type = .MAP_CHANGE,
		mapChange = {rocket.pos, shared.ROCKET_EXP_RAD}
	}

	explosion := shared.PacketExplosion{
		type = .EXPLOSION,
		id = rocket.id,
		pos = rocket.pos,
		rad = shared.ROCKET_EXP_RAD,
	}

	if sync.mutex_guard(&mMutex) {
		shared.map_accept_change(m, change.mapChange)
	}

	if sync.mutex_guard(&mcMutex) {
		mapChanges.changes[mapChanges.count] = change.mapChange
		mapChanges.count += 1
	}

	if sync.mutex_guard(&tsMutex) {
		mem.copy(mem.raw_data(buf[:]), &change, size_of(change))
		for _, player in players {
			net.send_tcp(player.tcpSock, buf[:size_of(change)])
			time.sleep(time.Microsecond * 1)
		}

		time.sleep(time.Microsecond * 1500)
		mem.copy(mem.raw_data(buf[:]), &explosion, size_of(explosion))
		for _, &player in players {
			net.send_tcp(player.tcpSock, buf[:size_of(explosion)])
			player_handle_explosion(&player.playerInfo, explosion)
		}
	}

	return true
}

rockets_udpate_thread :: proc() {
	curr := time.tick_now()
	deltaDur := time.tick_diff(prev, curr)
	deltaTime := f32(time.duration_seconds(deltaDur))
	prev = curr

	for iter := 0; iter < physicIters; iter+=1 {
		for i := 0; i < len(rockets); i+=1 {
			rockets[i].pos += rockets[i].dir * deltaTime * shared.ROCKET_SPEED / f32(physicIters)

			if rocket_map_collision(rockets[i], buf[:]) {
				unordered_remove(&rockets, i)
				i -= 1
			} else if rocket_check_outside(rockets[i]) {
				unordered_remove(&rockets, i)
				i -= 1
			} else if rocket_check_meatshot(rockets[i], buf[:]) {
				unordered_remove(&rockets, i)
				i -= 1
			}
		}
	}
}
