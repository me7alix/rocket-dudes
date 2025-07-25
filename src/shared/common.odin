package shared

import "core:net"
import "core:time"
import rl "vendor:raylib"

ID :: u16
MAX_PLAYERS :: 4
MAX_ROCKETS :: 16
PLAYER_RECT :: rl.Vector2{30, 50}
PLAYER_SPEED :: 230
PLAYER_JUMP_FORCE :: 10
PLAYER_DIGGING_SPEED :: 0.2
PLAYER_SHOOTING_SPEED :: 0.7

ROCKET_RAD :: 7
ROCKET_EXP_RAD :: 50
ROCKET_EXP_FORCE :: 17
ROCKET_EXP_DAMAGE :: 55
ROCKET_SPEED :: 700

PacketType :: enum {
	EXPLOSION,
	ROCKET_LAUNCH,
	MAP_CHANGE,
	HANDSHAKE,
}

PacketPlayerID :: struct {
	type: PacketType,
	playerID: u16,
}

PacketMapChange :: struct {
	type: PacketType,
	mapChange: MapChange,
}

PacketHandshake :: struct {
	type: PacketType,
	playerID: ID,
	mapChanges: MapChanges,
}

PacketExplosion :: struct {
	type: PacketType,
	id: ID,
	pos: rl.Vector2,
	rad: f32,
}

Camera :: struct {
	pos: rl.Vector2,
	scale: f32,
}

Player :: struct {
	tcpSock: net.TCP_Socket,
	udpEndp: net.Endpoint,
	playerInfo: PlayerInfo,
	shootingTimer: f32,
	diggingTimer: f32,
}

PlayerInfo :: struct {
	id: u16,
	health: f32,
	pos: rl.Vector2,
	vel: rl.Vector2,
	moveDir: i8,
	lastMoveDir: i8,
	onGround: bool,
}

UpdPlayerInfo :: struct {
	id: u16,
	moveDir: i8,
	viewDir: rl.Vector2,
	isJumping: bool,
	isShooting: bool,
	isDigging: bool,
}

Rocket :: struct {
	id: ID,
	pos: rl.Vector2,
	dir: rl.Vector2,
}

Gamestate :: struct {
	playersCount: u8,
	players: [MAX_PLAYERS]PlayerInfo, 
	rocketsCount: u8,
	rockets: [MAX_ROCKETS]Rocket,
}

gamestate_set_players_info :: proc(
	gs: ^Gamestate,
	players: map[ID]Player
) {
	gs.playersCount = u8(len(players))
	i := 0
	for _, player in players {
		gs.players[i] = player.playerInfo
		i += 1
	}
}

gamestate_set_rockets :: proc(
	gs: ^Gamestate,
	rockets: [dynamic]Rocket
) {
	gs.rocketsCount = u8(len(rockets))
	for rocket, ind in rockets {
		gs.rockets[ind] = rocket 
	}
}
