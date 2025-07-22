# Rocket dudes
Multiplayer game written in Odin
![image](https://github.com/user-attachments/assets/a1b6fdbb-1a62-447b-b394-a6f3f5857959)


Implemented features:
 - map sync for newly connected players
 - destructible map
 - realtime map sync
 - rockets shooting
 - animations

Unimplemented features:
 - random map generation
 - weapons system

## Quick start
```
odin build ./src/server
odin build ./src/client
./server 56780 &
./client 127.0.0.1:56780 1
```
