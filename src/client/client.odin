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
import "base:runtime"
import rl "vendor:raylib"
import "../logic/"

m: ^logic.Map
mMutex: sync.Mutex
mapChanges: logic.MapChanges
mcMutex: sync.Mutex
gamestate: logic.Gamestate
gsMutex: sync.Mutex
plinf: logic.PlayerInfo
piMutex: sync.Mutex
serverEndp: net.Endpoint

physicIters := 4
screenWidth := 800
screenHeight := 600
camera := logic.Camera{{0, 0}, 1.0}
screenPlayerPos := rl.Vector2{
  f32(screenWidth), f32(screenHeight)
} / 2.0 - logic.PLAYER_RECT/2.0


respawn :: proc() {
  plinf.pos = logic.MAP_POS + 
  {logic.VOX_SIZE*rand.float32(), -200}
  plinf.health = 100
  plinf.vel = {0, 0}
} 

tcp_receive_thread :: proc(sock: net.TCP_Socket) {
  buf: [32*1024]u8

  for {
    _, rerr := net.recv_tcp(sock, buf[:size_of(buf)])
    if rerr != nil {
      fmt.println("TCP receiving error:", fmt.enum_value_to_string(rerr)) 
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

      expVec := plinf.pos - expPacket.pos
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
  }
}

udp_send_playerinfo :: proc(sock: net.UDP_Socket, buf: []u8) {
  if sync.mutex_guard(&piMutex) {
    mem.copy(mem.raw_data(buf[:]), &plinf, size_of(plinf))
  }
  _, err := net.send_udp(sock, buf[:size_of(plinf)], serverEndp)
  if err != nil {
    fmt.println("udp send error:", err)
    return
  }
}

udp_receive_thread :: proc(sock: net.UDP_Socket) {
  buf: [2048]u8
  for {
    _, _, err := net.recv_udp(sock, buf[:])
    if err != nil {
      fmt.println("udp receive error:", err)
      return
    }

    if sync.mutex_guard(&gsMutex) {
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

  m = logic.map_alloc()
  defer free(m)

  buf: [2048]u8 
  plinf.pos = {300, 0}
  plinf.health = 100
  onGround := false
  speed := f32(220)
  strBuf := strings.Builder{}
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
  rl.SetTargetFPS(60)

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

    if sync.mutex_guard(&piMutex) {
      for i := 0; i < physicIters; i+=1 {
        plinf.vel.y += 20 * rl.GetFrameTime() / f32(physicIters)
        plinf.pos += plinf.vel / f32(physicIters)
        if rl.IsKeyDown(rl.KeyboardKey.A) {
          plinf.pos.x -= rl.GetFrameTime() * speed / f32(physicIters)
        }
        if rl.IsKeyDown(rl.KeyboardKey.D) {
          plinf.pos.x += rl.GetFrameTime() * speed / f32(physicIters)
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

    udp_send_playerinfo(udpSock, buf[:size_of(buf)])

    rl.BeginDrawing()
    rl.ClearBackground(rl.BLUE)

    if sync.mutex_guard(&gsMutex) {
      for i := 0; i < int(gamestate.playersCount); i+=1 {
        if gamestate.players[i].id != myID {
          plPos := gamestate.players[i].pos-camera.pos
          rl.DrawRectangleV(plPos, logic.PLAYER_RECT, rl.YELLOW)
          strings.builder_reset(&strBuf)
          fmt.sbprint(&strBuf, i32(gamestate.players[i].health))
          cstr, _ := strings.to_cstring(&strBuf)
          rl.DrawText(cstr, i32(plPos.x), i32(plPos.y), 16, rl.BLACK)
        }
      }

      for i := 0; i < int(gamestate.rocketsCount); i+=1 {
        rl.DrawCircleV(gamestate.rockets[i].pos-camera.pos, logic.ROCKET_RAD, rl.BLACK)
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
    rl.DrawRectangleV(screenPlayerPos, logic.PLAYER_RECT, rl.RED)
    rl.DrawText(cstr, i32(screenPlayerPos.x), i32(screenPlayerPos.y), 16, rl.BLACK)

    rl.EndDrawing()
  }
}
