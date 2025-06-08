package server

import "core:fmt"
import "core:net"
import "core:thread"
import "core:time"
import "core:sync"
import "core:os"
import "core:mem"
import "core:strconv"
import rl "vendor:raylib"
import "../shared/"

m: ^shared.Map
mMutex: sync.Mutex
tsMutex: sync.Mutex
idCnt: shared.ID
gamestate: shared.Gamestate
mapChanges: shared.MapChanges
mcMutex: sync.Mutex
rockets: [dynamic]shared.Rocket
rsMutex: sync.Mutex
players: map[shared.ID]shared.Player
psMutex: sync.Mutex

udp_send_thread :: proc(sock: net.UDP_Socket) {
	buf: [size_of(shared.Gamestate)]u8
	emptyEndp := net.Endpoint{}

	for {
		sync.mutex_lock(&psMutex)
		sync.mutex_lock(&rsMutex)

		rockets_udpate_thread()
		shared.gamestate_set_rockets(&gamestate, rockets)

		players_update_thread()
		shared.gamestate_set_players_info(&gamestate, players)

		mem.copy(mem.raw_data(buf[:]), &gamestate, size_of(gamestate))

		for id, player in players {
			if player.udpEndp == emptyEndp {
				continue
			}
			_, serr := net.send_udp(sock, buf[:size_of(gamestate)], player.udpEndp)
			if serr != nil {
				fmt.printf("udp send error: %v\n", serr)
			}
		}

		sync.mutex_unlock(&psMutex)
		sync.mutex_unlock(&rsMutex)

		time.sleep(time.Millisecond * 15)
	}
}

udp_receive_thread :: proc(sock: net.UDP_Socket) {
	buf: [1024]u8

	for {
		_, peer, rerr := net.recv_udp(sock, buf[:])
		if rerr != nil {
			fmt.printf("receive playerinfo error: %v\n", rerr)
			continue
		}

		change := shared.UpdPlayerInfo{}
		mem.copy(&change, mem.raw_data(buf[:]), size_of(change))

		if sync.mutex_guard(&psMutex) {
			ok := change.id in players
			if ok {
				pl := &players[change.id]
				pl.udpEndp = peer
				pl.playerInfo.moveDir = change.moveDir
				if change.isJumping && pl.playerInfo.onGround {
					pl.playerInfo.onGround = false
					pl.playerInfo.vel.y -= shared.PLAYER_JUMP_FORCE
				}
				if change.isDigging && pl.diggingTimer > shared.PLAYER_DIGGING_SPEED {
					pl.diggingTimer = 0
					packet := shared.PacketMapChange{
						type = .MAP_CHANGE,
						mapChange = {
							pos = pl.playerInfo.pos + shared.PLAYER_RECT / 2.0 + 
							rl.Vector2Normalize(change.viewDir) * 20,
							rad = 35,
						},
					}
					if sync.mutex_guard(&mcMutex) {
						shared.map_accept_change(m, packet.mapChange)
					}
					mem.copy(mem.raw_data(buf[:]), &packet, size_of(packet))
					for _, player in players {
						if sync.mutex_guard(&tsMutex) {
							net.send_tcp(player.tcpSock, buf[:size_of(packet)])
						}
					}
				}
				if change.isShooting && pl.shootingTimer > shared.PLAYER_SHOOTING_SPEED {
					pl.shootingTimer = 0
					rocket := shared.Rocket{
						id = change.id,
						pos = pl.playerInfo.pos + shared.PLAYER_RECT / 2.0,
						dir = rl.Vector2Normalize(change.viewDir),
					}
					if sync.mutex_guard(&rsMutex) {
						append(&rockets, rocket)
					}
				}
			}
		}
	}
}

tcp_client_thread :: proc(clientSock: net.TCP_Socket, clientEndp: net.Endpoint) {
	buf: [size_of(shared.PacketMapChanges)]u8
	playerID: shared.ID
	defer net.close(clientSock)

	for {
		n, rerr := net.recv_tcp(clientSock, buf[:len(buf)])
		if rerr != nil {
			fmt.printf("tcp receive error: %v\n", rerr) 
			return
		}

		if n <= 0 {
			if sync.mutex_guard(&psMutex) {
				delete_key(&players, playerID)
			}
			break
		}

		type := shared.PacketType{}
		mem.copy(&type, mem.raw_data(buf[:]), size_of(shared.PacketType))

		#partial switch type {
		case .MAP_CHANGE:
			change := shared.PacketMapChange{}
			change.type = .MAP_CHANGE
			mem.copy(&change, mem.raw_data(buf[:]), size_of(change))

			if sync.mutex_guard(&mMutex) {
				shared.map_accept_change(m, change.mapChange)
			}

			if sync.mutex_guard(&mcMutex) {
				mapChanges.changes[mapChanges.count] = change.mapChange
				mapChanges.count += 1
			}

			if sync.mutex_guard(&psMutex) {
				if sync.mutex_guard(&tsMutex) {
					for _, player in players {
						net.send_tcp(player.tcpSock, buf[:size_of(change)])
						time.sleep(time.Microsecond * 250)
					}
				}
			}

		case .PLAYER_ID:
			if sync.mutex_guard(&psMutex) {
				players[idCnt] = shared.Player{
					tcpSock = clientSock,
					playerInfo = shared.PlayerInfo{
						id = idCnt,
						pos = {200, 100},
						health = 100,
					},	
				}
			}

			packet := shared.PacketPlayerID {
				type = .PLAYER_ID,
				playerID = idCnt,
			}

			playerID = idCnt
			idCnt += 1

			mem.copy(mem.raw_data(buf[:]), &packet, size_of(packet))
			if sync.mutex_guard(&tsMutex) {
				net.send_tcp(clientSock, buf[:size_of(packet)])
			}

			time.sleep(time.Millisecond * 10)
			mapChangesPacket := shared.PacketMapChanges{}

			if sync.mutex_guard(&mcMutex) {
				mapChangesPacket = {
					type = .MAP_CHANGES,
					mapChanges = mapChanges,
				}
			}

			mem.copy(mem.raw_data(buf[:]), &mapChangesPacket, size_of(mapChangesPacket))
			if sync.mutex_guard(&tsMutex) {
				net.send_tcp(clientSock, buf[:size_of(mapChanges)])
			}

		case .ROCKET_LAUNCH:
			packet := shared.PacketLaunchRocket{}
			mem.copy(&packet, mem.raw_data(buf[:]), size_of(packet))
			if sync.mutex_guard(&rsMutex) {
				append(&rockets, packet.rocket)
			}
		}
	}
}

tcp_thread :: proc(tcp_listener: net.TCP_Socket) {
	for {
		clientSock, clientEndp, acceptErr := net.accept_tcp(tcp_listener)
		if acceptErr != net.Accept_Error.None {
			fmt.printf("TCP accept error: %v\n", acceptErr)
			continue
		}

		net.set_option(clientSock, net.Socket_Option.TCP_Nodelay, true)
		net.set_blocking(clientSock, true)

		thread.create_and_start_with_poly_data2(clientSock, clientEndp, tcp_client_thread)
	}
}

main :: proc() {
	serverEndp := net.Endpoint{net.IP4_Any, 0}

	if len(os.args) < 2 {
		fmt.println("Usage: [PORT]")
		return
	} else {
		val, ok := strconv.parse_int(os.args[1])
		if !ok {
			fmt.eprintln("invalid data")
			return
		} else {
			serverEndp.port = val
		}
	}

	m = shared.map_alloc()
	defer free(m)

	players = make(map[shared.ID]shared.Player)
	defer delete(players)

	udpSock, userr := net.make_bound_udp_socket(serverEndp.address, serverEndp.port);
	if userr != nil {
		fmt.println("Failed to bind UDP socket:", userr)
		return
	}
	defer net.close(udpSock)

	tcpSock, tserr := net.listen_tcp(serverEndp)
	if tserr != nil {
		fmt.println("Failed to create TCP socket:", tserr)
		return
	}
	defer net.close(tcpSock)

	thread.create_and_start_with_poly_data(tcpSock, tcp_thread)
	thread.create_and_start_with_poly_data(udpSock, udp_receive_thread)
	thread.create_and_start_with_poly_data(udpSock, udp_send_thread)

	for {
		time.sleep(time.Second)
	}
}
