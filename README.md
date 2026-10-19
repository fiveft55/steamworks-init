# Bean Workshop — Godot + Steam networking laboratory

A readable Godot 4.6 prototype: top-down bean shooter, box guns,
host-authoritative combat, inventory, crafting, and shared grid walls.

**Start here:** [the detailed integration guide](docs/INTEGRATION.md).

```sh
godot --editor --path .        # Open the project, then F5.
godot --path .                 # Run the menu directly.
bash tools/check.sh            # Model tests + real host/client smoke test.
```

- Click **Solo**, or **Host LAN** and share your LAN IP + UDP port `24567`.
- A second copy can join `127.0.0.1` for a same-machine test.
- WASD move; mouse aim; hold left click shoot; E collect nearby drops.
- C crafts 12 rounds; V crafts a wall kit; B places it at the highlighted cell.
- Escape leaves the session. Starting inventory supports every mechanic.
- Steam buttons require **GodotSteam plus the optional socket peer** in the guide.
  Plain Godot runs solo/LAN without Steam installed.

Steam is an integration example, not a certified Steam build. Its legacy peer
dependency has paused maintenance; no native binaries or Steam SDK files are bundled.
LAN has no automatic NAT traversal, Internet lobby service, identity verification,
or encryption. See the guide for production work and validation limits.
