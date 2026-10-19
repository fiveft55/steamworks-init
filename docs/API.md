# Session API and network message reference

This is a callable **GDScript API**, not an HTTP API. Use it inside a Godot game.
The concrete implementation is `scripts/net/session.gd`. The shipped example in
`main.gd` is a complete consumer, including prediction and UI.

## Create a session

```gdscript
extends Node # Your existing game root can own the networking component.

var session: NetSession # This stores a reference; it does not create a session yet.

func _ready() -> void: # Godot calls this once after this node enters the scene.
    session = NetSession.new() # Create the reusable networking node.
    session.name = "Session" # Keep this name AND parent path identical on all peers.
    add_child(session) # Attach it so Godot's multiplayer API and callbacks work.
    session.state_received.connect(_on_state) # Subscribe before creating a host.
    session.action_completed.connect(_on_action) # Transaction result for this player.
    session.status_changed.connect(print) # Human-readable connection diagnostics.
    session.solo() # Run locally; replace this with ONE of the alternatives below.

func _on_state(state: Dictionary) -> void: # Receives an immutable-by-convention view.
    var id := session.local_id # Your Godot peer ID; host is 1.
    if not state.players.has(id): # Admission/state might not contain you yet.
        return # Never access a missing dictionary key.
    var player: Dictionary = state.players[id] # The host's latest state for you.
    print("Health: ", player.hp, " ammo: ", player.inventory.ammo) # Display, don't mutate.

func _on_action(text: String) -> void: # Server reports success or a rule failure.
    print(text) # Replace with your UI toast or transaction feedback.
```

Replace `session.solo()` with one of:

```gdscript
session.host_lan() # Bind UDP 24567; return value is an Error (OK means socket opened).
session.join_lan("192.168.1.20") # Asynchronous; OK is NOT completed admission.
session.host_steam() # Asynchronous friends-only lobby + socket creation.
session.join_steam("109775240123456789") # Example shape only, NOT a real room.
```

These are alternatives, not a sequence of calls: each route switch leaves the
previous session. `active` means a transport exists; `admitted` means you have
received the welcome or are the local host. Gate gameplay input on `admitted`.

## Public operations

| Method | Result | Use |
|---|---|---|
| `solo()` | void | Reset previous session; create local authoritative model |
| `host_lan(port = 24567)` | Error | Open UDP server and start authority |
| `join_lan(address, port = 24567)` | Error | Begin ENet connection; wait for admission |
| `host_steam()` | void | Initialize optional SDK, create lobby, open socket |
| `join_steam(id_text)` | void | Initialize SDK, join lobby, connect to original owner |
| `submit_inputs(recent_commands)` | void | Send up to three numbered input dictionaries |
| `request_action(kind, payload)` | void | Allocate next action ID and send/execute a request |
| `leave()` | void | Close transport, leave lobby, clear model/queues/state, emit ended |
| `steam_lobbies.invite_friends()` | void | Open current lobby's invite overlay |

Do not call underscore-prefixed methods from ordinary gameplay code. Tests call
some of them deliberately to exercise malformed/repeated messages. None is a
substitute for a public trusted server interface.

## Public signals

| Signal | Arguments | Meaning |
|---|---|---|
| `state_received` | `Dictionary state` | New authoritative full state accepted locally |
| `status_changed` | `String text` | Connection/startup/Steam diagnostics |
| `action_completed` | `String text` | Result of this player's accepted action request |
| `shot_received` | `Dictionary event` | Cosmetic confirmed shot tracer; not durable state |
| `ended` | none | Session reset; clear visuals, prediction history, and match UI |

Rate-limited or duplicate actions can be silently rejected. The sample has no
request-result map or pending transaction spinner. If you add one, return the
request ID and a machine-readable result code, cache results for duplicate IDs,
and define timeout/reconnect behavior. Reliable transport delivery alone is not
a promise every application request succeeds.

## Public state

| Field | Meaning |
|---|---|
| `local_id: int` | Godot peer ID for this process's player |
| `active: bool` | A local/remote transport session is active |
| `admitted: bool` | Local host started or remote welcome was received |
| `latest: Dictionary` | Most recent authoritative full world state |
| `sampled_bytes: int` | Variant serialization length of last snapshot; excludes framing/transport |
| `authority: GameSimulation` | Host-only model; null on remote clients |

Treat `latest` and received snapshots as read-only. Editing a dictionary reference
can corrupt local rendering/replay assumptions. It does not grant remote server
authority. Call `duplicate(true)` if you need a mutable local copy.

## Input command schema

```gdscript
var command := { # Exactly four keys are accepted by the host's ingress validator.
    "seq": 1, # int; strictly increasing per player/session, starting at 1.
    "move": Vector2(1.0, 0.0), # X and Z movement; length normalized on the host.
    "aim": 0.0, # float radians; 0 points +X, PI/2 points +Z, wrapped by host.
    "fire": false, # bool; request firing this tick, not confirmation of a hit.
}
session.submit_inputs([command]) # Real game sends newest command + previous two.
```

This is Godot Variant serialization: `Vector2`, `Vector2i`, and dictionaries are
native values, not JSON. `aim` must be a float (`0.0`, not `0`), `seq` an integer,
and `fire` a boolean. Movement and angle must be finite. The host discards old
or already-ACKed sequence numbers, numbers more than 256 beyond its ACK, unknown
players, batches over three entries, and invalid field types. It clamps movement
length to one and queue storage to 12 commands per admitted player.

You must generate one command per fixed simulation tick, not every render frame.
Keep a monotonic sequence even when standing still. Use the sample's bounded
pending queue and replay if you want client prediction; `submit_inputs` alone
does not automatically predict an arbitrary character controller.

### Minimal input loop, without client prediction

```gdscript
var sequence := 0 # Reset this on session.ended, like main.gd does.
var recent: Array = [] # Three overlapping inputs tolerate occasional datagram loss.

func _physics_process(_delta: float) -> void: # Project physics rate is 60 Hz.
    if not session.admitted: # Wait for the server to create your player.
        return # Do not submit stale input during connection.
    sequence += 1 # Each simulation step gets a unique monotonic number.
    var direction := Vector2.RIGHT # Replace with your normalized control input.
    var command := {"seq": sequence, "move": direction, "aim": 0.0, "fire": false}
    recent.append(command) # Remember the current command.
    if recent.size() > 3: # Bound resend work and packet size.
        recent.pop_front() # Forget the oldest redundant command.
    session.submit_inputs(recent) # Host derives player identity from RPC sender.
```

This minimal loop deliberately omits presentation and prediction. For the actual
responsive loop, use `main.gd`: predict with `GameRules.move`, prune pending input
through `player.ack`, reset to authoritative position, then replay the remainder.

## Action schema

```gdscript
session.request_action("craft", "ammo") # Host pays wood + metal, grants 12 rounds.
session.request_action("craft", "wall") # Host pays 3 wood, grants a wall kit.
session.request_action("collect", 1) # Stable drop ID; host checks range and existence.
session.request_action("build", Vector2i(6, 7)) # Integer grid X,Z; host checks all rules.
```

| Kind | Payload type | Authoritative preconditions |
|---|---|---|
| `craft` | String recipe ID | Known recipe; enough of every cost item |
| `collect` | int drop ID | Drop exists; authoritative distance <= 2.2m |
| `build` | Vector2i cell | Inside build bounds; <=3m away; no existing wall; under wall cap; kit available; no nearby players/protected spawn zones |

Request IDs are generated by `request_action`, independently of input sequence
numbers. They reset only on a new session. IDs must be newer than the last
accepted one and no more than 100 ahead. Repeating an ID cannot repeat a mutation.
Unknown action/recipe/type produces a rule failure rather than client-controlled
inventory. Action bodies are not a general arbitrary dictionary update API.

## Full snapshot schema

```gdscript
{ # Values shown are illustrative, not a serialized golden fixture.
    "tick": 120, # Server tick, not wall-clock time or a client timestamp.
    "players": {
        1: { # Godot peer ID, not Steam account ID.
            "pos": Vector2(-4.0, 0.0), # Authoritative X,Z position.
            "aim": 0.0, # Radians in the same convention as the input.
            "hp": 100, # Server health.
            "inventory": {"wood": 12, "metal": 6, "ammo": 24, "wall": 1},
            "ack": 118, # Last command processed for this player.
            "last_shot": 100, # Authoritative cooldown clock in ticks.
            "kills": 0, # Server-owned score.
        },
    },
    "walls": {"6,7": 100}, # Integer grid coordinate key -> hit points.
    "drops": {
        1: {"pos": Vector2(-8.0, -7.0), "wood": 4, "metal": 2},
    },
}
```

Players/walls/drops missing from a new full state have been removed. Do not merge
old entities into it as if it were a delta. The sample sends inventories to all
peers for simplicity; production may need per-recipient private state or hidden
information. The client trusts a server snapshot by design; a compromised host
can send false or malformed state. Host-authoritative does not mean host-proof.

## Cosmetic shot schema

```gdscript
{ # Damage has already been resolved by the host when this event is sent.
    "owner": 1, # Shooter's Godot peer ID.
    "from": Vector2(-4, 0), # Authoritative origin, in X,Z.
    "to": Vector2(3.6, 0), # Ray endpoint at nearest collision/range.
    "hit": 2, # Hit player's Godot ID; 0 for wall/no player.
}
```

Render this as a short tracer. Do not apply damage again upon receipt. Missing
or duplicated cosmetic events must not change inventory, health, or world state.
The speculative owner muzzle flash uses separate presentation-only code.

## Actual RPC surface

All these methods live at the same NodePath on every peer. In the shipped scene
that path is `/root/BeanWorkshop/Session`. The test harness deliberately uses
`/root/Harness/Session` on both test processes. RPC names, annotations, return
types, and node paths must match across builds. A protocol string cannot make
two incompatible Godot RPC tables compatible; distribute matching builds.

| RPC | Allowed caller | Transfer | Payload / behavior |
|---|---|---|---|
| `_hello` | Any connected peer | Reliable | Protocol string; host admits/rejects sender |
| `_welcome` | Authority | Reliable | Initial full snapshot; client starts input |
| `_inputs` | Any peer | Unreliable | Max-three input batch; host gates by admitted sender |
| `_action` | Any peer | Reliable | Request sequence, kind, typed payload |
| `_action_result` | Authority | Reliable | Human-readable result for requester |
| `_snapshot` | Authority | Unreliable | Complete state; ignore equal/older server ticks |
| `_shot` | Authority | Unreliable | Cosmetic event only |

`any_peer` means “Godot may deliver this RPC,” not “trust this caller.” The first
host-side checks use `multiplayer.get_remote_sender_id()` and the admitted player
table. `authority` means the default node authority, peer 1; the project does not
transfer the Session node's multiplayer authority to clients.

## Replace the optional Steam peer

Keep this interface between `SteamLobbies` and `NetSession`:

```gdscript
signal peer_ready(peer: MultiplayerPeer, hosting: bool) # Session adopts the transport.
```

Your adapter must initialize its SDK, establish an appropriate host/client peer,
handle callbacks and cleanup, and emit the signal after creating a valid peer.
It must preserve authority peer ID 1 and support the RPC delivery modes used here.
If its connection signal timing differs, adapt the `_connected()` handshake rather
than marking a client admitted before a welcome. Replace identity-to-membership
lookup using the new peer's trusted transport identity API. If there is no
trustworthy mapping, fail admission rather than accepting a client-claimed ID.

The inspected socket peer calls are:

```gdscript
var peer: MultiplayerPeer = ClassDB.instantiate("SteamMultiplayerPeer")
var error: int = peer.call("create_host", 0) # Host; Steam virtual port.
# On a DIFFERENT machine/instance, use the following instead:
# var error: int = peer.call("create_client", owner_steam_id, 0)
if error == OK: # A created socket still requires client connection + hello.
    multiplayer.multiplayer_peer = peer # Makes Godot RPCs use Steam's transport.
```

Do not paste this alongside an existing active Session peer; use the adapter's
owned lifecycle. This snippet explains the native boundary, while
`steam_lobbies.gd` supplies the actual callbacks, metadata, timeout, and errors.
