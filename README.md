# ClientCulling

ClientCulling is a lightweight client-side distance culling module for Roblox. It hides or disables tagged objects when they are far from the player camera, then restores them when the camera gets close again.

It is useful for improving client performance in maps with lots of particles, lights, beams, trails, UI adornments, props, or shadow-casting parts.

## Features

* Distance-based client culling
* No external dependencies
* Uses Roblox `CollectionService` tags
* Supports moving objects by refreshing bounding boxes
* Restores original parent, enabled state, and shadow state
* Supports callbacks for cull and uncull events
* Safe `Start()` and `Destroy()` lifecycle methods

## Supported Instances

ClientCulling supports:

* `Model`
* `BasePart`
* `ParticleEmitter`
* `Beam`
* `Trail`
* `SurfaceGui`
* `BillboardGui`
* `PointLight`
* `SpotLight`
* `SurfaceLight`
* `Attachment`
* `Decal`
* `Texture`

## Tags

### `Cull`

Objects tagged with `Cull` are hidden when they move beyond the cull distance.

```luau
CollectionService:AddTag(instance, "Cull")
```

### `CullShadows`

Parts tagged with `CullShadows` have `CastShadow` disabled when far away and restored when close.

```luau
CollectionService:AddTag(part, "CullShadows")
```

## Installation

Place `ClientCulling.luau` somewhere accessible to the client, such as:

```text
ReplicatedStorage/
└── Shared/
    └── ClientCulling.luau
```

Then require it from a client script:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientCulling = require(ReplicatedStorage.Shared.ClientCulling)

ClientCulling.Start()
```

Or through wally

```
cull = "sudoserver819/cull@0.1.1"
```

## Basic Usage

```luau
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientCulling = require(ReplicatedStorage.Shared.ClientCulling)

ClientCulling.Start()

CollectionService:AddTag(workspace.SomeModel, "Cull")
```

## Manual Registration

You can also register objects directly:

```luau
local entry = ClientCulling.AddItem(workspace.SomeModel, 250)
```

This culls the object when it is farther than `250` studs from the current camera.

## Removing Items

```luau
ClientCulling.RemoveItem(workspace.SomeModel)
```

Or with the entry returned by `AddItem`:

```luau
ClientCulling.RemoveItem(entry)
```

Removing an item restores its original state.

## Checking Cull State

```luau
local isCulled = ClientCulling.IsItemActivelyCulled(workspace.SomeModel)

if isCulled then
	print("Object is currently culled")
end
```

## Cull Events

```luau
local disconnectCulled = ClientCulling.OnItemCulled(function(instance)
	print(instance.Name, "was culled")
end)

local disconnectUnculled = ClientCulling.OnItemUnculled(function(instance)
	print(instance.Name, "was restored")
end)
```

Disconnect later:

```luau
disconnectCulled()
disconnectUnculled()
```

## API

### `ClientCulling.Start()`

Starts the culling loop and begins watching the `Cull` and `CullShadows` tags.

```luau
ClientCulling.Start()
```

### `ClientCulling.AddItem(instance, cullDistance)`

Registers an instance manually.

```luau
local entry = ClientCulling.AddItem(instance, 200)
```

### `ClientCulling.RemoveItem(item)`

Removes an instance or culling entry and restores its state.

```luau
ClientCulling.RemoveItem(instance)
```

### `ClientCulling.IsItemActivelyCulled(item)`

Returns whether the item is currently outside its cull distance.

```luau
local culled = ClientCulling.IsItemActivelyCulled(instance)
```

### `ClientCulling.OnItemCulled(callback)`

Runs a callback when an item becomes hidden.

```luau
local disconnect = ClientCulling.OnItemCulled(function(instance)
	print("Culled:", instance)
end)
```

### `ClientCulling.OnItemUnculled(callback)`

Runs a callback when an item becomes visible again.

```luau
local disconnect = ClientCulling.OnItemUnculled(function(instance)
	print("Unculled:", instance)
end)
```

### `ClientCulling.Destroy()`

Stops the module, disconnects events, restores tracked instances, and clears callbacks.

```luau
ClientCulling.Destroy()
```

## Behavior

Objects are culled differently depending on their type:

| Type                    | Behavior                                      |
| ----------------------- | --------------------------------------------- |
| `Model` / `BasePart`    | Reparented to an internal `Unrendered` folder |
| Effects / GUIs / Lights | `.Enabled` is set to `false`                  |
| Shadow-only parts       | `CastShadow` is set to `false`                |

When restored, ClientCulling attempts to return the object to its original state.

## Performance Notes

ClientCulling is best used for decorative or non-critical client visuals.

Good targets:

* Particles
* Lights
* Trails
* Beams
* Decorative props
* Distant map details
* Billboard UI
* Surface UI
* Shadow-heavy parts

Avoid using it on:

* Important gameplay objects
* Server-authoritative hitboxes
* Characters
* Objects that must always replicate visually
* Objects whose parent is frequently changed by other systems

## License

MIT
