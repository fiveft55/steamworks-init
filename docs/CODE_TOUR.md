# Read the code slowly: a beginner's tour

The code has comments beside constants and at the decisions where it matters.
This document explains the structure and recurring syntax so you can change it
without memorizing networking vocabulary. Repeating “create a variable” on every
line would bury the important rules, so this tour explains that once and then
walks through each script and its functions.

## 1. The smallest mental tools

Imagine four jobs:

- **Input:** asks for things. “I want to move left.”
- **Simulation:** checks rules and changes the actual world.
- **Networking:** delivers requests and copies of that world.
- **View/UI:** draws what happened and shows numbers/text.

The host has all four jobs. A remote client has input, networking, view, and a
temporary movement prediction. It does not own health or items.

### Common GDScript lines, word by word

```gdscript
class_name GameRules # Register this script's name so other scripts can use it.
extends RefCounted # Inherit a lightweight object that frees itself when unused.

const SPEED := 6.0 # const = fixed value; SPEED = name; := = infer type from 6.0.
var tick := 0 # var = changeable value; initially integer zero.
var players: Dictionary = {} # Typed dictionary: empty key -> value storage.
var commands: Array = [] # Typed array: ordered list, initially empty.

func example(id: int) -> bool: # Define a function taking an integer, returning bool.
    if not players.has(id): # Ask whether the dictionary lacks this key.
        return false # Stop this call immediately and return the boolean false.
    var player: Dictionary = players[id] # Fetch the dictionary stored under id.
    player.hp -= 25 # Subtract 25 from the stored health; shorthand for hp = hp - 25.
    return true # Tell the caller the operation finished successfully.
```

Indentation groups the lines belonging to a function/if/loop. A `#` comment is
for humans. `##` is a documentation comment. `"wood"` is text; `12` is an integer;
`12.0` is a float; `true/false` are booleans. `null` means no object. `==` compares;
`=` assigns. `and` requires both conditions; `or` accepts either condition.

`:=` only works when Godot can determine the right-hand type. Dynamic calls and
`load(...).instantiate()` sometimes need an explicit type or ordinary `=` instead.

A **Dictionary is reference-like**: `var player = players[id]` points to the same
nested dictionary. Setting `player.hp` changes the authoritative entry too.
`duplicate(true)` makes a deep copy, including nested dictionaries and arrays.
That is why snapshots are copied before they leave the model.

### Vectors and units

`Vector2(x, y)` holds two numbers. Here those numbers mean world **X and Z**.
Godot's `Vector3(x, y, z)` uses Y for height, so drawing turns `Vector2(x, z)` into
`Vector3(x, 0, z)`. The simulation is flat even though the mesh is 3D.

`direction.limit_length(1)` prevents diagonal movement or malicious values from
making movement faster. `distance_to` measures separation. `distance_squared_to`
avoids a square root when comparing against a squared distance. `lerp` blends
between two values. Radians measure angles: PI is half a turn; PI/2 is a quarter.

### Nodes, objects, and signals

- `RefCounted` objects (`GameRules`, `GameSimulation`) contain data/functions.
- `Node` objects (`NetSession`, main) participate in Godot's scene tree.
- `Node3D` (`ArenaView`) can own positions and 3D meshes.
- `CanvasLayer` (`GameHUD`) draws UI above the 3D scene.
- `new()` creates an object. `add_child()` attaches a Node to the live tree.
- `_ready()` runs after a Node enters the tree with its children ready.
- `_physics_process()` runs at the fixed simulation frequency.
- `_process(delta)` runs once per rendered frame; `delta` is elapsed seconds.
- `signal` declares an event. `connect(callback)` subscribes a function.
- `emit(arguments)` notifies subscribers without knowing how they draw/log it.
- `queue_free()` schedules a Node's destruction safely after current work.

## 2. Start with `rules.gd`

This file is the shared rulebook. Both host movement and local prediction call
the same functions. If they used different speed or collision, they would fight
on every snapshot.

| Part | Plain-language explanation |
|---|---|
| Constants at the top | Settings you should edit first: speed, range, damage, capacities, timing |
| `PROTOCOL` | A label saying which message/state format this build expects |
| `RECIPES` | A recipe ID maps to costs and a single item reward |
| `spawn(slot)` | Returns one of four fixed positions; `% 4` wraps an index into 0–3 |
| `cell_key(cell)` | Turns integer grid coordinates into stable text like `"6,7"` |
| `cell_position(key)` | Splits that text back into numeric X/Z coordinates |
| `finite_vector(value)` | Checks both the type and that numbers are neither NaN nor infinity |
| `free_position(pos, walls)` | Answers whether a player circle fits inside the arena and outside every wall |
| `move(pos, direction, walls)` | Takes one fixed movement step, sliding separately on X and Z |

### Read movement line by line

```gdscript
var step := direction.limit_length(1.0) * SPEED * DT # Direction × m/s × seconds = metres.
var next := Vector2(pos.x + step.x, pos.y) # Try the X part without changing Z.
if free_position(next, walls): # Does the player's circle fit at this candidate?
    pos.x = next.x # Keep the X move only when collision permits it.
next = Vector2(pos.x, pos.y + step.y) # Now try Z using whichever X survived.
if free_position(next, walls): # Repeat the same wall/bounds test for the Z move.
    pos.y = next.y # Keep the Z move only when legal.
return pos # Return the new position; blocked axes retained their old coordinate.
```

This is a deliberately small kinematic model. It does not use `CharacterBody3D`,
gravity, pushing players, or Godot physics rollback. At the configured speed a
step is 0.1 metres, small relative to the one-metre wall grid. Much higher speed
would need swept collision/substeps to avoid crossing walls between checks.

## 3. Next read `simulation.gd`

This is the actual game. It is independent of Godot nodes and Steam. Tests can
create it, send commands, and inspect results without drawing a window.

### Data at the top

`tick` is a server-owned count of fixed steps. `players` maps Godot peer IDs to
state. `walls` maps grid cells to hit points. `drops` maps integer IDs to resource
piles. `events` holds just this step's cosmetic shots.

`_init()` creates eight finite piles. `% 4` finds a column; dividing by four and
flooring finds a row. The initial coordinates form two rows in the arena.

`add_player(id)` does nothing for an existing ID. For a new ID it creates a
separated spawn, health, inventory, sequence acknowledgement, cooldown, and score.
`remove_player(id)` erases the entry; the next full state tells every view to
remove that bean.

### `step(commands)`

1. Increment the authoritative clock by one.
2. Clear last step's cosmetic events.
3. Loop through admitted players.
4. Skip a player with no command; do not repeat old movement forever.
5. Move using `GameRules.move`, apply the validated aim, and record the sequence ACK.
6. If fire was requested, call `shoot(id)`.

This method assumes its caller already validated command types. Only NetSession
and tests call it. Do not expose it directly as an unrestricted RPC.

### `shoot(id)`

The guard at the top exits when ammo is empty or cooldown has not elapsed. A
legal attempt records its tick and spends one round even if the ray misses.

`cos(aim), sin(aim)` turns an angle into a unit direction. `closest` begins at the
maximum range. Each wall intersection can shorten it. Then each player circle
can shorten it again if nearer than that wall. This chooses the nearest object,
not every object along the ray.

For a player, `offset.dot(direction)` measures distance along the aim direction.
The remaining squared component measures sideways distance. If that sideways
distance is greater than the target radius, the ray misses. Otherwise the square
root calculates the circle entry point. The nearest positive hit wins.

Damage is applied once. At zero health a kill is credited and the target respawns.
Wall damage removes a wall at zero HP. Finally, an event records the shot's
origin/endpoint for a short visual tracer. No view applies that damage again.

`ray_box()` uses the slab algorithm: each axis defines an interval in which the
ray is inside the box. Intersect the intervals; an empty interval means no hit.
Near-zero direction components are handled separately to avoid division by zero.

`safe_spawn()` looks for a free protected spawn. The origin is the protected
fallback. Player-to-player overlap is allowed in this prototype.

### `action(id, kind, payload)`

This function is the only inventory/build transaction entry point. It first
checks the player exists, then uses `match` to choose a known operation.

- **Craft:** validate recipe name; check every cost; deduct every cost; grant reward.
- **Collect:** validate drop ID and range; grant its materials; erase the drop.
- **Build:** require Vector2i; validate location, range, kit, capacity, occupancy,
  and spawn protection; create the wall; spend the kit.

Every failing branch returns before changing inventory. Success returns a short
human-readable message. There is no client-supplied quantity or resource price.

`snapshot()` returns a deep-copy dictionary. Without the copy, a later simulation
step could accidentally change a snapshot the renderer is still interpolating.

## 4. Read `session.gd`: the network referee's desk

### Lifecycle

`_ready()` creates the optional Steam adapter and connects Godot multiplayer
signals to small methods. Merely creating this Node does not require Steam.

`solo()`, `host_lan()`, `join_lan()`, `host_steam()`, and `join_steam()` are route
entry points. Each leaves the previous session first. ENet socket creation
returns an error code immediately, while connection/admission are asynchronous.

`_start_host()` creates the authoritative model, adds peer 1, initializes its
queue, marks local admission, and publishes an initial state. Solo uses an
`OfflineMultiplayerPeer`, so the same model can run without remote sockets.

`leave()` closes peer/lobby and empties queues, models, sequence tables, rate
budgets, and cached state. Its `ended` signal asks the UI/view/input layer to
clear their own state too. `_fail(text)` is cleanup plus a diagnostic.

### Admission

`_peer_connected(id)` gives a new remote connection five seconds to say hello.
It does not yet grant a player or inventory. `_connected()` runs on the client
and sends `_hello` to peer 1.

`_hello(protocol)` runs on the host, obtains the sender from Godot, checks the
waiting table, protocol and capacity, and checks Steam lobby membership when
applicable. It adds the player and sends `_welcome(full_state)` reliably.
`_welcome` marks the remote client admitted and feeds state to `_accept_state`.

`_peer_disconnected(id)` erases that player's authoritative state and auxiliary
queues/budgets. `server_disconnected` ends the client session. The session also
has a snapshot silence timeout so a dead connection does not freeze forever.

### A complete RPC annotation, word by word

```gdscript
@rpc("any_peer", "call_remote", "unreliable", 0) # Who, local behavior, delivery, channel.
func _inputs(batch: Array) -> void: # Only a bounded batch of input intentions.
    if authority != null: # Only a process owning a server model may ingest it.
        _ingest(multiplayer.get_remote_sender_id(), batch) # Derive sender from socket.
```

- `any_peer`: Godot is allowed to deliver a remote call from any connected peer.
- `call_remote`: sending this RPC does not automatically run its body locally.
- `unreliable`: newer data can replace lost data; delivery is not guaranteed.
- `0`: the transfer channel shared by both supported transport families.
- `rpc_id(1, ...)`: send to the authoritative server, not all clients.
- `rpc(...)`: host broadcasts the snapshot/event to connected peers.
- `authority`: when used on snapshot/welcome, only node authority can invoke it.

### Input validation and queueing

`submit_inputs()` routes local input directly into the host queue or sends it to
peer 1. `_inputs()` is the remote boundary; `_ingest()` is the shared validator.

The validation order is deliberate: check the admitted sender and budget before
looping the batch; cap entries; check dictionary shape and field types; reject
non-finite numbers; reject old/huge sequences and full queues; normalize movement
and angle; store only the sanitized fields. A client never sends their position.

`_allow()` stores a counter for one message family in one wall-clock second.
Changing seconds resets the counter. This keeps legitimate work bounded at the
game layer, but cannot prevent native packet flood/deserialization costs.

### Actions and duplicate prevention

`request_action()` allocates an action sequence. Host-local requests call
`_apply_action` directly; clients call `_action` on server 1.
`_apply_action()` validates sender/budget/sequence, records the accepted ID,
calls `authority.action`, sends the result only to its requester, and publishes
updated state. `_action_result` emits a UI signal; it cannot mutate inventory.

### The server's fixed step

`_physics_process()` first handles timeouts. On a client it only monitors the
connection; the client never advances a host model. On a host it removes expired
pending joins and departed Steam members, then takes the smallest sequence from
each nonempty input queue. Exactly one command per player reaches the model.
It forwards cosmetic shots and publishes every third tick.

`_publish()` snapshots the authority, measures Variant bytes, emits locally, and
broadcasts if remote peers exist. `_snapshot()` receives host state.
`_accept_state()` rejects stale ticks and records receipt time before notifying
the view. `_shot()` only forwards a cosmetic event.

## 5. Read `steam_lobbies.gd`: the optional native boundary

The file uses `Engine.has_singleton`, `Engine.get_singleton`,
`ClassDB.class_exists`, and `ClassDB.instantiate` instead of directly referencing
`Steam` or `SteamMultiplayerPeer` types at parse time. That is what lets the
project load in stock Godot without those native symbols.

| Function | What it does |
|---|---|
| `_process()` | Pumps callbacks once per frame and checks lobby request deadline |
| `initialize()` | Detects both addons, initializes SDK once, connects three signals |
| `host_lobby()` | Requests a friends-only room with capacity four |
| `join_lobby(text)` | Validates integer text, requests asynchronous join |
| `invite_friends()` | Opens Steam overlay invite dialog for an active lobby |
| `_on_created()` | Saves lobby/protocol/original host metadata; opens host socket |
| `_on_joined()` | Validates response/protocol/original owner; opens client socket |
| `_open_peer()` | Checks socket-peer interface, calls host/client creation, emits peer_ready |
| `is_lobby_peer()` | Maps Godot peer ID to transport Steam ID and checks current lobby members |
| `_on_join_requested()` | Handles a running-game invitation without replacing another Steam room |
| `leave()` | Leaves the room and clears request/room flags, keeping SDK initialized |

`busy`, `hosting`, `lobby_id`, and `deadline` are intentionally small lifecycle
state. `NetSession._on_steam_peer()` also refuses to replace an active LAN/solo
session. Native callbacks are asynchronous: successful create/join does not mean
Godot game admission is complete. See the integration guide for overlapping
request limitations and the required two-account acceptance test.

## 6. Read `main.gd`: connecting jobs without mixing them

`_ready()` creates the view, HUD and Session. It names Session consistently,
connects signals, binds menu buttons, optionally initializes Steam invite handling,
and parses Steam's cold-launch `+connect_lobby` argument.

`_state_received()` is the reconciliation point. It resets `predicted` to the
host position, removes acknowledged inputs, replays unacknowledged movement, and
updates view/HUD. It never modifies the host's health or inventory dictionary.

`_physics_process()` reads controls, creates a sequence-numbered input, keeps the
newest three, predicts movement on a remote client, and submits. A host reads its
own 60Hz authoritative position directly. Aim and speculative muzzle feedback
update immediately. Pending input has a hard bound so a broken connection cannot
allocate replay history forever.

`_unhandled_key_input()` maps craft/build/collect/invite/leave keys to public
session operations. It ignores key-repeat echoes so holding C does not generate
hundreds of reliable craft requests.

`collect_nearest()` picks a nearby drop as a convenience. This client-side choice
is not proof of permission: the host rechecks it. `_ended()` resets input and
view/UI state. `_notification()` leaves the lobby/transport during normal close.

## 7. Read `arena_view.gd`: draw, don't decide

`_ready()` creates a floor grid, border, lighting, orthographic camera, and cursor.
`add_box()` is a helper for box meshes and materials. It applies transparency
only for a color with alpha below one.

`make_bean()` makes a capsule body, three gun boxes and a floating nameplate.
The local bean is mint; others get deterministic colors. The gun points along
local +X, matching the mathematical aim direction.

`accept_state()` stores bounded history, removes departed beans, creates new ones,
updates health labels, and syncs wall/drop meshes. `_sync_props()` creates only
missing props and removes only vanished ones; it does not rebuild the whole
floor or all walls every frame.

`aim_position()` casts a camera ray onto Y=0 using line/plane math.
`build_cell()` rounds that world X/Z point to an integer grid cell. The cursor
shows the selected cell, not guaranteed build permission; authority may reject it.

`_process()` locates snapshots before/after the render tick, interpolates remote
beans, displays the owner from prediction, positions the cursor, and expires
flash meshes. Snapshot data is not mutated during rendering. `rotation.y = -aim`
converts the 2D angle convention to Godot's 3D Y-axis rotation convention.

`show_shot()` draws a thin box between the confirmed origin and endpoint for
70ms. `show_muzzle()` flashes a box at the local gun tip for 45ms without claiming
a hit. `clear()` frees dynamic meshes/history and hides the cursor on leave.

## 8. Read `hud.gd`: one editable UI surface

`_ready()` builds the menu and labels. `make_label()` centralizes readable font
size, shadow, and mouse pass-through. `button()` centralizes button height and
callback wiring. The menu emits signals instead of calling model mutations.

`show_status()` displays/logs connection or action feedback. `show_state()` hides
the menu after local player state exists and displays the host's numbers.
`reset()` restores the menu after a session ends. You can move this to authored
Control scenes later; the signal API is the boundary to preserve.

## 9. Tests are examples of safe changes

`model_test.gd` creates small worlds and asks explicit yes/no questions. It counts
checks and exits nonzero on failure; it does not rely on assertions disabled in
some builds. It also exercises actual Session ingress and action deduplication.

`scene_test.gd` loads the real main scene, runs solo craft/build, creates a second
bean, exercises interpolation/effects, and verifies leave resets view/menu. It
runs headlessly: this checks scene behavior, not a human's visual judgement.

`network_peer.gd` runs as host/client in separate processes with identical RPC
paths. `network_smoke.py` starts both, captures logs, checks success markers AND
exit codes, and cleans up only its own children. The client deliberately repeats
a craft action ID to prove it cannot obtain items twice.

`tools/check.sh` makes temporary writable cache directories, imports the project,
runs startup/model/scene checks, then the real ENet smoke test. It inspects logs
for script/runtime errors because an apparently successful process exit is not
enough evidence that Godot executed the intended code.

When you change a rule, update the existing test explaining that behavior. For
example, if ammo crafting should cost 2 metal, change `RECIPES`, update the model
cost expectation and network test inventory expectation, then run the checks.
Do not “fix” a failing test by skipping the behavior it was meant to demonstrate.
