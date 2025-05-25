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
deltaDur: time.Duration
prevTick: time.Tick
gsMutex: sync.Mutex
serverEndp: net.Endpoint
sprites: rl.Texture2D
groundTexture: rl.Texture2D
updPlinf: logic.UpdPlayerInfo
plinf: logic.PlayerInfo
playerID: logic.ID
idMutex: sync.Mutex

physicIters := 4
screenWidth := 1280
screenHeight := 920
camera := logic.Camera{{0, 0}, 1.0}
screenPlayerPos := rl.Vector2{
	f32(screenWidth), f32(screenHeight)
} / 2.0 - logic.PLAYER_RECT/2.0
strBuf := strings.Builder{}

tcp_receive_thread :: proc(sock: net.TCP_Socket) {
	buf: [size_of(logic.PacketMapChanges)]u8

	for {
		_, rerr := net.recv_tcp(sock, buf[:])
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
			if sync.guard(&idMutex) {
				playerID = playerIDPacket.playerID
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

			expl_anim_add(expPacket.pos)
		}
	}
}

udp_send_upd_plinf :: proc(sock: net.UDP_Socket, buf: []u8) {
	mem.copy(mem.raw_data(buf[:]), &updPlinf, size_of(updPlinf))
	_, err := net.send_udp(sock, buf[:size_of(updPlinf)], serverEndp)
	if err != nil {
		fmt.eprintf("udp send error: %v\n", err)
		return
	}
}

udp_receive_thread :: proc(sock: net.UDP_Socket) {
	buf: [size_of(logic.Gamestate)]u8
	prevTick = time.tick_now()

	for {
		_, _, err := net.recv_udp(sock, buf[:])
		if err != nil {
			fmt.eprintf("udp receive error: %v\n", err)
			return
		}

		if sync.mutex_guard(&gsMutex) {
			curr := time.tick_now()
			deltaDur = time.tick_diff(prevTick, curr)
			prevTick = curr
			prevGamestate = gamestate
			mem.copy(&gamestate, mem.raw_data(buf[:]), size_of(gamestate))
		}
	}
}

request_player_id :: proc(tcpSock: net.TCP_Socket, buf: []u8) {
	playerIDPacket := logic.PacketPlayerID{type = .PLAYER_ID}
	mem.copy(mem.raw_data(buf[:]), &playerIDPacket, size_of(logic.PacketPlayerID))
	net.send_tcp(tcpSock, buf[:size_of(logic.PacketPlayerID)])
}

draw_hp :: proc(pos: rl.Vector2, hp: f32) {
	strings.builder_reset(&strBuf)
	fmt.sbprint(&strBuf, i32(hp))
	cstr, _ := strings.to_cstring(&strBuf)
	rl.DrawText(cstr, i32(pos.x), i32(pos.y)-14, 16, rl.RED)
}

draw_all :: proc(myID: logic.ID) {
	rl.BeginDrawing()
	rl.ClearBackground(rl.DARKBLUE)

	if sync.mutex_guard(&gsMutex) {
		dt := f32(time.duration_seconds(time.tick_diff(prevTick, time.tick_now())) / time.duration_seconds(deltaDur))

		for i := 0; i < int(gamestate.playersCount); i+=1 {
			plPos := linalg.lerp(prevGamestate.players[i].pos, gamestate.players[i].pos, dt)
			if gamestate.players[i].id == myID {
				camera.pos = plPos - screenPlayerPos
				player_anim(gamestate.players[i], true, {})
				draw_hp(screenPlayerPos, gamestate.players[i].health)
				break
			}
		}

		for i := 0; i < int(gamestate.playersCount); i+=1 {
			if gamestate.players[i].id != myID {
				plPos := linalg.lerp(prevGamestate.players[i].pos, gamestate.players[i].pos, dt)
				plPos -= camera.pos
				player_anim(gamestate.players[i], false, plPos)
				draw_hp(plPos, gamestate.players[i].health)
			}
		}

		for i := 0; i < int(gamestate.rocketsCount); i+=1 {
			rocketPos := gamestate.rockets[i].pos
			if linalg.distance(prevGamestate.rockets[i].pos, gamestate.rockets[i].pos) < logic.ROCKET_RAD*6 {
				rocketPos = linalg.lerp(prevGamestate.rockets[i].pos, gamestate.rockets[i].pos, dt)
			}
			rl.DrawCircleV(rocketPos-camera.pos, logic.ROCKET_RAD, rl.YELLOW)
		}
	}

	if sync.mutex_guard(&mMutex) {
		logic.map_draw(m, camera.pos, groundTexture)
	}

	expl_anim_update()

	rl.EndDrawing()
}

main :: proc() {
	if len(os.args) < 3 {
		fmt.println("Usage: [ADDRESS]:[PORT] [HIGH_REF_RATE]")
		fmt.println("  [ADDRESS]:[PORT]    - server address and port to listen on")
		fmt.println("  [HIGH_REF_RATE]     - set to 1 for 144fps, 0 for 60fps")
		fmt.println("                        (default is 0)")
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

	highRefRate := strconv.atoi(os.args[2]) == 1

	explAnims = make([dynamic]ExplosionAnim)
	defer delete(explAnims)

	m = logic.map_alloc()
	defer free(m)

	buf: [2048]u8 
	shootingTimer: f32 = 0

	udpSock, usErr := net.make_unbound_udp_socket(.IP4)
	if usErr != nil {
		fmt.eprintf("make_bound_udp_socket error: %v\n", usErr)
		return
	}
	defer net.close(udpSock)
	net.send_udp(udpSock, buf[:], serverEndp)

	tcpSock, tsErr := net.dial_tcp_from_endpoint(serverEndp)
	if tsErr != nil {
		fmt.eprintf("dial_tcp_from_endpoint error: %v\n", tsErr)
		return
	}
	defer net.close(tcpSock)

	thread.create_and_start_with_poly_data(udpSock, udp_receive_thread)
	thread.create_and_start_with_poly_data(tcpSock, tcp_receive_thread)

	request_player_id(tcpSock, buf[:])

	rl.SetTraceLogLevel(rl.TraceLogLevel.NONE)
	rl.InitWindow(i32(screenWidth), i32(screenHeight), "Rocket dudes")
	defer rl.CloseWindow()
	rl.SetTargetFPS(highRefRate ? 144 : 60)

	sprites = rl.LoadTexture("res/sprites.png")
	defer rl.UnloadTexture(sprites)
	groundTexture = rl.LoadTexture("res/ground.png")
	defer rl.UnloadTexture(groundTexture)
	rl.SetTextureWrap(groundTexture, rl.TextureWrap.REPEAT)

	animWalkR.texture = sprites
	animWalkL.texture = sprites
	animIdleR.texture = sprites	
	animIdleL.texture = sprites
	animJumpR.texture = sprites
	animJumpL.texture = sprites
	animBombExpl.texture = sprites

	for !rl.WindowShouldClose() {
		shootingTimer += rl.GetFrameTime()

		sync.mutex_lock(&idMutex)
		myID := playerID
		sync.mutex_unlock(&idMutex)

		updPlinf = {}
		updPlinf.id = myID
		updPlinf.viewDir = rl.GetMousePosition() -
			(screenPlayerPos + logic.PLAYER_RECT / 2.0)

		if rl.IsKeyDown(rl.KeyboardKey.D) {
			updPlinf.moveDir = 1
		}

		if rl.IsKeyDown(rl.KeyboardKey.A) {
			updPlinf.moveDir = -1
		}

		if rl.IsMouseButtonDown(rl.MouseButton.RIGHT) {
			updPlinf.isDigging = true
		}

		if rl.IsKeyDown(rl.KeyboardKey.SPACE) {
			updPlinf.isJumping = true
		}

		if rl.IsMouseButtonDown(rl.MouseButton.LEFT) {
			updPlinf.isShooting = true
		}

		udp_send_upd_plinf(udpSock, buf[:size_of(buf)])

		draw_all(myID)
	}
}
