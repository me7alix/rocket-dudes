package client

import "core:os"
import "core:fmt"
import "core:net"
import "core:time"
import "core:mem"
import "core:strings"
import "core:strconv"
import "core:sync"
import "core:thread"
import "core:math"
import "core:math/rand"
import "core:math/linalg"
import "base:runtime"
import rl "vendor:raylib"
import "../logic/"

m: ^logic.Map
mMutex: sync.Mutex
mapChanges: logic.MapChanges
mcMutex: sync.Mutex
gamestate: logic.Gamestate
prevGamestate: logic.Gamestate
gsMutex: sync.Mutex
plinf: logic.PlayerInfo
piMutex: sync.Mutex
serverEndp: net.Endpoint
sprites: rl.Texture2D

physicIters := 4
screenWidth := 800
screenHeight := 600
camera := logic.Camera{{0, 0}, 1.0}
screenPlayerPos := rl.Vector2{
	f32(screenWidth), f32(screenHeight)
} / 2.0 - logic.PLAYER_RECT/2.0
strBuf := strings.Builder{}

respawn :: proc() {
	plinf.pos = logic.MAP_POS + 
	{logic.VOX_SIZE*rand.float32(), -200}
	plinf.health = 100
	plinf.vel = {0, 0}
} 

tcp_receive_thread :: proc(sock: net.TCP_Socket) {
	buf: [size_of(logic.PacketMapChanges)]u8

	for {
		_, rerr := net.recv_tcp(sock, buf[:size_of(buf)])
		if rerr != nil {
			fmt.eprintf("tcp receiving error: %v\n", rerr) 
			return
		}

		packetType: logic.PacketType 
		mem.copy(&packetType, mem.raw_data(buf[:]), size_of(packetType))

		#partial switch packetType {
		case .PLAYER_ID:
			playerIDPacket := logic.PacketPlayerID{}
			mem.copy(&playerIDPacket, mem.raw_data(buf[:]), size_of(playerIDPacket))

			if sync.mutex_guard(&piMutex) {
				plinf.id = playerIDPacket.playerID
			}

		case .MAP_CHANGES:
			mapChangesPacket := logic.PacketMapChanges{}
			mem.copy(&mapChangesPacket, mem.raw_data(buf[:]), size_of(mapChangesPacket))

			if sync.mutex_guard(&mcMutex) {
				mapChanges = mapChangesPacket.mapChanges
				for i: u32 = 0; i < mapChanges.count; i+=1 {
					if sync.mutex_guard(&mMutex) {
						logic.map_accept_change(m, mapChanges.changes[i])
					}
				}
			}

		case .MAP_CHANGE:
			mapChangePacket := logic.PacketMapChange{}
			mem.copy(&mapChangePacket, mem.raw_data(buf[:]), size_of(mapChangePacket))

			if sync.mutex_guard(&mMutex) {
				logic.map_accept_change(m, mapChangePacket.mapChange)
			}

		case .EXPLOSION:
			expPacket := logic.PacketExplosion{}
			mem.copy(&expPacket, mem.raw_data(buf[:]), size_of(expPacket))

			if logic.intersect_circle_rect(expPacket.pos, logic.ROCKET_EXP_RAD, 
				plinf.pos, plinf.pos + logic.PLAYER_RECT) {

				expVec := (plinf.pos + logic.PLAYER_RECT/2.0) - expPacket.pos
				maxRad := expPacket.rad + logic.PLAYER_RECT.y/2.0
				normForce := math.clamp(1 - rl.Vector2Length(expVec) / maxRad, 0, 1)

				if sync.mutex_guard(&piMutex) {
					plinf.vel += rl.Vector2Normalize(expVec) * normForce * logic.ROCKET_EXP_FORCE
					if plinf.id != expPacket.id {
						plinf.health -= normForce * logic.ROCKET_EXP_DAMAGE
						if plinf.health <= 0 {
							respawn()
						}
					}
				}
			}

			expl_anim_add(expPacket.pos)
		}
	}
}

udp_send_playerinfo :: proc(sock: net.UDP_Socket, buf: []u8) {
	if sync.mutex_guard(&piMutex) {
		mem.copy(mem.raw_data(buf[:]), &plinf, size_of(plinf))
	}
	_, err := net.send_udp(sock, buf[:size_of(plinf)], serverEndp)
	if err != nil {
		fmt.eprintf("udp send error: %v\n", err)
		return
	}
}

udp_receive_thread :: proc(sock: net.UDP_Socket) {
	buf: [size_of(logic.Gamestate)]u8
	for {
		_, _, err := net.recv_udp(sock, buf[:])
		if err != nil {
			fmt.println("udp receive error:", err)
			return
		}

		if sync.mutex_guard(&gsMutex) {
			prevGamestate = gamestate
			mem.copy(&gamestate, mem.raw_data(buf[:]), size_of(gamestate))
		}
	}
}

tcp_send_map_change :: proc(tcpSock: net.TCP_Socket, buf: []u8) {
	screenCenter := rl.Vector2{f32(screenWidth), f32(screenHeight)}/2.0
	dig := rl.Vector2Normalize(rl.GetMousePosition()-screenCenter)*20+screenCenter
	packet := logic.PacketMapChange{
		type = .MAP_CHANGE,
		mapChange = logic.MapChange{
			pos = dig+camera.pos,
			rad = 40,
		}
	}
	mem.copy(mem.raw_data(buf[:]), &packet, size_of(packet))
	net.send_tcp(tcpSock, buf[:size_of(packet)])
}

tcp_send_launch_rocket :: proc(tcpSock: net.TCP_Socket, buf: []u8, myID: logic.ID) {
	packet := logic.PacketLaunchRocket{
		type = .ROCKET_LAUNCH,
		rocket = logic.Rocket{
			id = myID,
			pos = plinf.pos+logic.PLAYER_RECT/2.0,
			dir = rl.Vector2Normalize(rl.GetMousePosition()-(screenPlayerPos+logic.PLAYER_RECT/2.0)),
		}
	}
	mem.copy(mem.raw_data(buf[:]), &packet, size_of(packet))
	net.send_tcp(tcpSock, buf[:size_of(packet)])
}

request_player_id :: proc(tcpSock: net.TCP_Socket, buf: []u8) {
	playerIDPacket := logic.PacketPlayerID{type = .PLAYER_ID}
	mem.copy(mem.raw_data(buf[:]), &playerIDPacket, size_of(logic.PacketPlayerID))
	net.send_tcp(tcpSock, buf[:size_of(logic.PacketPlayerID)])
}

update_physic ::proc() -> bool {
	onGround := false	
	plinf.moveDir = 0

	if sync.mutex_guard(&piMutex) {
		for i := 0; i < physicIters; i+=1 {
			plinf.vel.y += 20 * rl.GetFrameTime() / f32(physicIters)
			plinf.pos += plinf.vel / f32(physicIters)
			if rl.IsKeyDown(rl.KeyboardKey.A) {
				plinf.pos.x -= rl.GetFrameTime() * logic.PLAYER_SPEED / f32(physicIters)
				plinf.moveDir = -1
				plinf.lastMoveDir = -1
			}
			if rl.IsKeyDown(rl.KeyboardKey.D) {
				plinf.pos.x += rl.GetFrameTime() * logic.PLAYER_SPEED / f32(physicIters)
				plinf.moveDir = 1
				plinf.lastMoveDir = 1
			}
			logic.map_solve_collision(m, &plinf, &onGround)
		}
		if onGround {
			plinf.vel.x = 0
		}
		if plinf.pos.y > logic.MAP_POS.y + logic.VOX_SIZE + 200 {
			respawn()
		}
		if rl.IsKeyDown(rl.KeyboardKey.SPACE) && onGround {
			plinf.vel.y += -10
		}
		camera.pos = plinf.pos-screenPlayerPos
	}

	return onGround
}

draw_all :: proc(myID: logic.ID) {
	rl.BeginDrawing()
	rl.ClearBackground(rl.BLUE)

	if sync.mutex_guard(&gsMutex) {
		for i := 0; i < int(gamestate.playersCount); i+=1 {
			if gamestate.players[i].id != myID {
				plPos := linalg.lerp(prevGamestate.players[i].pos, gamestate.players[i].pos, rl.GetFrameTime())-camera.pos
				//rl.DrawRectangleV(plPos, logic.PLAYER_RECT, rl.YELLOW)
				player_anim(gamestate.players[i], false, plPos)

				strings.builder_reset(&strBuf)
				fmt.sbprint(&strBuf, i32(gamestate.players[i].health))
				cstr, _ := strings.to_cstring(&strBuf)
				rl.DrawText(cstr, i32(plPos.x), i32(plPos.y)-14, 16, rl.RED)
			}
		}

		for i := 0; i < int(gamestate.rocketsCount); i+=1 {
			rocketPos := gamestate.rockets[i].pos
			if linalg.distance(prevGamestate.rockets[i].pos, gamestate.rockets[i].pos) < logic.ROCKET_RAD*2 {
				rocketPos = linalg.lerp(prevGamestate.rockets[i].pos, gamestate.rockets[i].pos, rl.GetFrameTime())
			}
			rl.DrawCircleV(rocketPos-camera.pos, logic.ROCKET_RAD, rl.YELLOW)
		}
	}

	if sync.mutex_guard(&mMutex) {
		logic.map_draw(m, camera.pos)
	}

	strings.builder_reset(&strBuf)
	if sync.mutex_guard(&piMutex) {
		fmt.sbprint(&strBuf, i32(plinf.health))
	}
	cstr, _ := strings.to_cstring(&strBuf)
	//rl.DrawRectangleV(screenPlayerPos, logic.PLAYER_RECT, rl.RED)
	player_anim(plinf, true, {})
	rl.DrawText(cstr, i32(screenPlayerPos.x), i32(screenPlayerPos.y)-14, 16, rl.RED)

	expl_anim_update()

	rl.EndDrawing()
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.println("Usage: [ADDRESS]:[PORT]")
		return
	} else {
		val, ok := net.parse_endpoint(os.args[1])
		if !ok {
			fmt.eprintln("invalid data")
			return
		} else {
			serverEndp = val
		}
	}

	explAnims = make([dynamic]ExplosionAnim)
	defer delete(explAnims)

	m = logic.map_alloc()
	defer free(m)

	buf: [2048]u8 
	plinf.pos = {300, 0}
	plinf.health = 100
	shootingTimer: f32 = 0

	udpSock, _ := net.make_unbound_udp_socket(.IP4); 
	defer net.close(udpSock)

	tcpSock, _ := net.dial_tcp_from_endpoint(serverEndp) 
	defer net.close(tcpSock) 

	thread.create_and_start_with_poly_data(udpSock, udp_receive_thread)
	thread.create_and_start_with_poly_data(tcpSock, tcp_receive_thread)

	request_player_id(tcpSock, buf[:])

	rl.SetTraceLogLevel(rl.TraceLogLevel.NONE)
	rl.InitWindow(i32(screenWidth), i32(screenHeight), "Rocket dudes")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	sprites = rl.LoadTexture("res/sprites.png")
	defer rl.UnloadTexture(sprites)

	animWalkR.texture = sprites
	animWalkL.texture = sprites
	animIdleR.texture = sprites	
	animIdleL.texture = sprites
	animJumpR.texture = sprites
	animJumpL.texture = sprites
	animBombExpl.texture = sprites

	for !rl.WindowShouldClose() {
		shootingTimer += rl.GetFrameTime()

		sync.mutex_guard(&piMutex)
		myID := plinf.id
		sync.mutex_unlock(&piMutex)

		if rl.IsMouseButtonPressed(rl.MouseButton.RIGHT) {
			tcp_send_map_change(tcpSock, buf[:])
		}

		if rl.IsMouseButtonDown(rl.MouseButton.LEFT) && shootingTimer > 0.8 {
			shootingTimer = 0
			tcp_send_launch_rocket(tcpSock, buf[:], myID)
		}

		plinf.onGround = update_physic()
		udp_send_playerinfo(udpSock, buf[:size_of(buf)])

		draw_all(myID)
	}
}
