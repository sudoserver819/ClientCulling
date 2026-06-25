--!optimize 2
--[=[
	@class ClientCulling

	Client-side distance-based culling utility with no external dependencies.

	Instances tagged with `Cull` are hidden when they move beyond their configured
	cull distance from the current camera. Instances tagged with `CullShadows`
	can have their `CastShadow` property disabled at distance and restored later.

	Supported cull behavior:
	- `Model` and `BasePart` instances are temporarily parented to an internal
	  `Unrendered` folder.
	- `ParticleEmitter`, `Beam`, `Trail`, `SurfaceGui`, `BillboardGui`, and light
	  instances are disabled through their `Enabled` property.
	- `BasePart` instances tagged with `CullShadows` have `CastShadow` disabled.

	Bounding boxes are refreshed during updates, so moving objects can be culled
	and restored based on their current position.

	@prop Start () -> ()
	@prop AddItem (Instance, number) -> CullableEntry?
	@prop RemoveItem (Instance | CullableEntry) -> ()
	@prop IsItemActivelyCulled (Instance | CullableEntry) -> boolean
	@prop OnItemCulled ((Instance) -> ()) -> () -> ()
	@prop OnItemUnculled ((Instance) -> ()) -> () -> ()
	@prop Destroy () -> ()
]=]

const CollectionService = game:GetService("CollectionService")
const RunService = game:GetService("RunService")

const CULL_TAG = "Cull"
const CULL_SHADOWS_TAG = "CullShadows"

const VALID_CULL_CLASSES: { [string]: boolean } = {
	ParticleEmitter = true,
	Beam = true,
	Trail = true,
	SurfaceGui = true,
	BillboardGui = true,
	PointLight = true,
	SpotLight = true,
	SurfaceLight = true,
	Model = true,
	Part = true,
	MeshPart = true,
	UnionOperation = true,
	WedgePart = true,
	CornerWedgePart = true,
	TrussPart = true,
}

const HAS_ENABLED: { [string]: boolean } = {
	ParticleEmitter = true,
	Beam = true,
	Trail = true,
	SurfaceGui = true,
	BillboardGui = true,
	PointLight = true,
	SurfaceLight = true,
	SpotLight = true,
}

export type CullableEntry = {
	Instance: Instance,
	BoundingBox: { CFrame: CFrame, Size: Vector3 },
	CullDistance: number,
	OriginalParent: Instance?,
	OriginalCastShadow: boolean?,
	OriginalEnabled: boolean?,
	Visible: boolean,
}

type Callback = (Instance) -> ()

local ClientCulling = {}

ClientCulling._items = {} :: { [Instance]: CullableEntry }
ClientCulling._running = false
ClientCulling._defaultCullDistance = 200
ClientCulling._heartbeatConnection = nil :: RBXScriptConnection?
ClientCulling._tagConnections = {} :: { RBXScriptConnection }
ClientCulling._onCulledCallbacks = {} :: { Callback }
ClientCulling._onUnculledCallbacks = {} :: { Callback }

ClientCulling._unrenderedFolder = Instance.new("Folder")
ClientCulling._unrenderedFolder.Name = "Unrendered"
ClientCulling._unrenderedFolder.Parent = script

--[=[
	Starts the culling loop and begins observing `Cull` and `CullShadows` tags.

	This method is idempotent and can safely be called multiple times.

	@return ()
]=]
function ClientCulling.Start()
	if ClientCulling._running then
		return
	end

	ClientCulling._running = true
	ClientCulling._ensureUnrenderedFolder()

	ClientCulling._heartbeatConnection = RunService.Heartbeat:Connect(function()
		if ClientCulling._running then
			ClientCulling._updateCulling()
		end
	end)

	ClientCulling._observeTag(CULL_TAG)
	ClientCulling._observeTag(CULL_SHADOWS_TAG)
end

--[=[
	Registers an instance for distance-based culling.

	Supported instances include:
	- `Model`
	- `BasePart`
	- `ParticleEmitter`
	- `Beam`
	- `Trail`
	- `SurfaceGui`
	- `BillboardGui`
	- `PointLight`
	- `SpotLight`
	- `SurfaceLight`
	- `Attachment`
	- `Decal`
	- `Texture`

	@param instance Instance -- The instance to cull.
	@param cullDistance number -- Distance in studs beyond which the instance is hidden.
	@return CullableEntry? -- The tracked entry, or nil if no bounding box could be derived.
]=]
function ClientCulling.AddItem(instance: Instance, cullDistance: number): CullableEntry?
	local existing = ClientCulling._items[instance]
	if existing then
		return existing
	end

	if not ClientCulling._isCullable(instance) then
		return nil
	end

	local cframe, size = ClientCulling._deriveBoundingBox(instance)
	if not cframe or not size then
		warn(string.format("[ClientCulling] Failed to derive bounding box for: %s", instance:GetFullName()))
		return nil
	end

	local entry: CullableEntry = {
		Instance = instance,
		BoundingBox = {
			CFrame = cframe,
			Size = size,
		},
		CullDistance = cullDistance,
		OriginalParent = instance.Parent,
		OriginalCastShadow = nil,
		OriginalEnabled = nil,
		Visible = true,
	}

	if HAS_ENABLED[instance.ClassName] then
		entry.OriginalEnabled = (instance :: any).Enabled
	end

	if instance:IsA("BasePart") and CollectionService:HasTag(instance, CULL_SHADOWS_TAG) then
		entry.OriginalCastShadow = instance.CastShadow
	end

	ClientCulling._items[instance] = entry

	return entry
end

--[=[
	Removes an instance from culling tracking and restores its original state.

	@param item Instance | CullableEntry -- The instance or entry returned from `AddItem`.
	@return ()
]=]
function ClientCulling.RemoveItem(item: Instance | CullableEntry)
	local instance = ClientCulling._resolveInstance(item)
	if not instance then
		return
	end

	local entry = ClientCulling._items[instance]
	if not entry then
		return
	end

	ClientCulling._setVisible(entry, true)
	ClientCulling._restoreEntry(entry)
	ClientCulling._items[instance] = nil
end

--[=[
	Checks whether an item should currently be culled from the camera position.

	This refreshes the item's bounding box before checking, so moving objects are
	evaluated based on their current location.

	@param item Instance | CullableEntry -- The instance or entry to check.
	@return boolean -- True if the item is currently outside its cull distance.
]=]
function ClientCulling.IsItemActivelyCulled(item: Instance | CullableEntry): boolean
	local instance = ClientCulling._resolveInstance(item)
	if not instance then
		return false
	end

	local entry = ClientCulling._items[instance]
	if not entry then
		return false
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return false
	end

	if not ClientCulling._refreshBoundingBox(entry) then
		return false
	end

	return ClientCulling._shouldCull(entry, camera.CFrame.Position)
end

--[=[
	Registers a callback fired when an item transitions from visible to culled.

	@param callback (Instance) -> () -- Callback receiving the culled instance.
	@return () -> () -- Disconnect function.
]=]
function ClientCulling.OnItemCulled(callback: Callback): () -> ()
	table.insert(ClientCulling._onCulledCallbacks, callback)

	return function()
		local index = table.find(ClientCulling._onCulledCallbacks, callback)
		if index then
			table.remove(ClientCulling._onCulledCallbacks, index)
		end
	end
end

--[=[
	Registers a callback fired when an item transitions from culled back to visible.

	@param callback (Instance) -> () -- Callback receiving the restored instance.
	@return () -> () -- Disconnect function.
]=]
function ClientCulling.OnItemUnculled(callback: Callback): () -> ()
	table.insert(ClientCulling._onUnculledCallbacks, callback)

	return function()
		local index = table.find(ClientCulling._onUnculledCallbacks, callback)
		if index then
			table.remove(ClientCulling._onUnculledCallbacks, index)
		end
	end
end

--[=[
	Stops the culling loop, disconnects tag observers, restores all tracked
	instances, clears callbacks, and destroys the internal unrendered folder.

	This method is safe to call multiple times.

	@return ()
]=]
function ClientCulling.Destroy()
	ClientCulling._running = false

	if ClientCulling._heartbeatConnection then
		ClientCulling._heartbeatConnection:Disconnect()
		ClientCulling._heartbeatConnection = nil
	end

	for _, connection in ClientCulling._tagConnections do
		connection:Disconnect()
	end

	table.clear(ClientCulling._tagConnections)

	for _, entry in ClientCulling._items do
		ClientCulling._setVisible(entry, true)
		ClientCulling._restoreEntry(entry)
	end

	table.clear(ClientCulling._items)
	table.clear(ClientCulling._onCulledCallbacks)
	table.clear(ClientCulling._onUnculledCallbacks)

	if ClientCulling._unrenderedFolder then
		ClientCulling._unrenderedFolder:Destroy()
	end
end

function ClientCulling._ensureUnrenderedFolder()
	if ClientCulling._unrenderedFolder and ClientCulling._unrenderedFolder.Parent then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = "Unrendered"
	folder.Parent = script

	ClientCulling._unrenderedFolder = folder
end

function ClientCulling._resolveInstance(item: Instance | CullableEntry): Instance?
	if typeof(item) == "Instance" then
		return item
	end

	return (item :: CullableEntry).Instance
end

function ClientCulling._restoreEntry(entry: CullableEntry)
	local instance = entry.Instance

	if entry.OriginalEnabled ~= nil and HAS_ENABLED[instance.ClassName] then
		(instance :: any).Enabled = entry.OriginalEnabled
	end

	if entry.OriginalCastShadow ~= nil and instance:IsA("BasePart") then
		instance.CastShadow = entry.OriginalCastShadow
	end
end

function ClientCulling._observeTag(tag: string)
	local addedConnection = CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance: Instance)
		local entry = ClientCulling.AddItem(instance, ClientCulling._defaultCullDistance)

		if entry and instance:IsA("BasePart") and CollectionService:HasTag(instance, CULL_SHADOWS_TAG) then
			entry.OriginalCastShadow = instance.CastShadow
		end
	end)

	local removedConnection = CollectionService:GetInstanceRemovedSignal(tag):Connect(function(instance: Instance)
		local entry = ClientCulling._items[instance]
		if not entry then
			return
		end

		if tag == CULL_SHADOWS_TAG and instance:IsA("BasePart") then
			if entry.OriginalCastShadow ~= nil then
				instance.CastShadow = entry.OriginalCastShadow
			end

			entry.OriginalCastShadow = nil
		end

		if
			not CollectionService:HasTag(instance, CULL_TAG)
			and not CollectionService:HasTag(instance, CULL_SHADOWS_TAG)
		then
			ClientCulling.RemoveItem(instance)
		end
	end)

	table.insert(ClientCulling._tagConnections, addedConnection)
	table.insert(ClientCulling._tagConnections, removedConnection)

	for _, instance in CollectionService:GetTagged(tag) do
		local entry = ClientCulling.AddItem(instance, ClientCulling._defaultCullDistance)

		if entry and instance:IsA("BasePart") and CollectionService:HasTag(instance, CULL_SHADOWS_TAG) then
			entry.OriginalCastShadow = instance.CastShadow
		end
	end
end

function ClientCulling._isCullable(instance: Instance): boolean
	return VALID_CULL_CLASSES[instance.ClassName] == true
		or instance:IsA("Model")
		or instance:IsA("BasePart")
		or instance:IsA("Attachment")
		or instance:IsA("Decal")
		or instance:IsA("Texture")
end

function ClientCulling._isObjectCullable(instance: Instance): boolean
	return instance:IsA("Model") or instance:IsA("BasePart")
end

function ClientCulling._fireCallbacks(callbacks: { Callback }, instance: Instance)
	for _, callback in callbacks do
		task.spawn(callback, instance)
	end
end

function ClientCulling._setVisible(entry: CullableEntry, visible: boolean)
	if entry.Visible == visible then
		return
	end

	local instance = entry.Instance
	local hasEnabled = HAS_ENABLED[instance.ClassName]
	local isObjectCullable = ClientCulling._isObjectCullable(instance)

	if hasEnabled then
		(instance :: any).Enabled = if visible then (entry.OriginalEnabled ~= false) else false
	elseif isObjectCullable then
		if visible then
			if entry.OriginalParent then
				instance.Parent = entry.OriginalParent
			end
		else
			ClientCulling._ensureUnrenderedFolder()
			instance.Parent = ClientCulling._unrenderedFolder
		end
	end

	if entry.OriginalCastShadow ~= nil and instance:IsA("BasePart") then
		instance.CastShadow = if visible then entry.OriginalCastShadow else false
	end

	entry.Visible = visible

	if visible then
		ClientCulling._fireCallbacks(ClientCulling._onUnculledCallbacks, instance)
	else
		ClientCulling._fireCallbacks(ClientCulling._onCulledCallbacks, instance)
	end
end

function ClientCulling._updateCulling()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local cameraPosition = camera.CFrame.Position
	local toRemove: { Instance } = {}

	for instance, entry in ClientCulling._items do
		if not instance.Parent and entry.Visible then
			table.insert(toRemove, instance)
			continue
		end

		if not ClientCulling._refreshBoundingBox(entry) then
			table.insert(toRemove, instance)
			continue
		end

		ClientCulling._setVisible(entry, not ClientCulling._shouldCull(entry, cameraPosition))
	end

	for _, instance in toRemove do
		ClientCulling._items[instance] = nil
	end
end

function ClientCulling._refreshBoundingBox(entry: CullableEntry): boolean
	local cframe, size = ClientCulling._deriveBoundingBox(entry.Instance)
	if not cframe or not size then
		return false
	end

	entry.BoundingBox.CFrame = cframe
	entry.BoundingBox.Size = size

	return true
end

function ClientCulling._shouldCull(entry: CullableEntry, cameraPosition: Vector3): boolean
	local boundingCenter = entry.BoundingBox.CFrame.Position
	local boundingRadius = entry.BoundingBox.Size.Magnitude * 0.5
	local roughDistance = (boundingCenter - cameraPosition).Magnitude

	if roughDistance - boundingRadius > entry.CullDistance then
		return true
	end

	if roughDistance + boundingRadius < entry.CullDistance then
		return false
	end

	local closestPoint =
		ClientCulling._getClosestSurfacePosition(entry.BoundingBox.CFrame, entry.BoundingBox.Size, cameraPosition)

	return (closestPoint - cameraPosition).Magnitude >= entry.CullDistance
end

function ClientCulling._deriveBoundingBox(instance: Instance): (CFrame?, Vector3?)
	if instance:IsA("Model") or instance:IsA("BasePart") then
		return ClientCulling._deriveForPVInstance(instance)
	elseif instance:IsA("SurfaceGui") or instance:IsA("BillboardGui") then
		return ClientCulling._deriveForGui(instance :: any)
	elseif instance:IsA("Beam") or instance:IsA("Trail") then
		return ClientCulling._deriveForBeamLike(instance :: any)
	elseif instance:IsA("PointLight") or instance:IsA("SpotLight") or instance:IsA("SurfaceLight") then
		return ClientCulling._deriveForLight(instance :: any)
	elseif instance:IsA("Attachment") then
		return instance.WorldCFrame, Vector3.new(1, 1, 1)
	elseif instance:IsA("Decal") or instance:IsA("Texture") then
		return ClientCulling._deriveForTextureLike(instance :: any)
	elseif instance:IsA("ParticleEmitter") then
		return ClientCulling._deriveForEmitter(instance :: any)
	end

	return nil, nil
end

function ClientCulling._deriveForPVInstance(instance: Instance): (CFrame?, Vector3?)
	if instance:IsA("Model") then
		local cframe, size = instance:GetBoundingBox()

		if size.Magnitude >= 0.01 then
			return cframe, size
		end

		local primaryPart = instance.PrimaryPart
		if primaryPart then
			return primaryPart.CFrame, primaryPart.Size
		end

		local firstPart = instance:FindFirstChildWhichIsA("BasePart", true)
		if firstPart then
			return firstPart.CFrame, firstPart.Size
		end

		return nil, nil
	elseif instance:IsA("BasePart") then
		return instance.CFrame, instance.Size
	end

	return nil, nil
end

function ClientCulling._deriveForGui(instance: any): (CFrame?, Vector3?)
	local adornee = instance.Adornee or instance.Parent

	if adornee and (adornee:IsA("BasePart") or adornee:IsA("Model")) then
		return ClientCulling._deriveForPVInstance(adornee)
	end

	return nil, nil
end

function ClientCulling._deriveForBeamLike(instance: any): (CFrame?, Vector3?)
	local attachment0 = instance.Attachment0
	local attachment1 = instance.Attachment1

	if not attachment0 or not attachment1 then
		return nil, nil
	end

	local position0 = attachment0.WorldPosition
	local position1 = attachment1.WorldPosition
	local center = (position0 + position1) * 0.5
	local delta = position1 - position0
	local length = delta.Magnitude
	local width0 = instance.Width0
	local width1 = instance.Width1
	local thickness = math.max(width0 or 1, width1 or 1, 1)

	if length < 0.001 then
		return CFrame.new(center), Vector3.new(thickness, thickness, thickness)
	end

	return CFrame.lookAt(center, center + delta.Unit), Vector3.new(thickness, thickness, length)
end

function ClientCulling._deriveForLight(instance: any): (CFrame?, Vector3?)
	local parent = instance.Parent

	if parent then
		if parent:IsA("Attachment") then
			return parent.WorldCFrame, Vector3.new(1, 1, 1)
		elseif parent:IsA("BasePart") or parent:IsA("Model") then
			return ClientCulling._deriveForPVInstance(parent)
		end
	end

	return nil, nil
end

function ClientCulling._deriveForTextureLike(instance: any): (CFrame?, Vector3?)
	local parent = instance.Parent

	if parent and parent:IsA("BasePart") then
		return ClientCulling._deriveForPVInstance(parent)
	end

	return nil, nil
end

function ClientCulling._deriveForEmitter(instance: any): (CFrame?, Vector3?)
	local parent = instance.Parent

	if parent then
		if parent:IsA("BasePart") or parent:IsA("Model") then
			return ClientCulling._deriveForPVInstance(parent)
		elseif parent:IsA("Attachment") then
			return parent.WorldCFrame, Vector3.new(1, 1, 1)
		end
	end

	return nil, nil
end

function ClientCulling._getClosestSurfacePosition(boxCFrame: CFrame, boxSize: Vector3, point: Vector3): Vector3
	local localPoint = boxCFrame:PointToObjectSpace(point)
	local halfSize = boxSize * 0.5

	local clampedLocal = Vector3.new(
		math.clamp(localPoint.X, -halfSize.X, halfSize.X),
		math.clamp(localPoint.Y, -halfSize.Y, halfSize.Y),
		math.clamp(localPoint.Z, -halfSize.Z, halfSize.Z)
	)

	return boxCFrame:PointToWorldSpace(clampedLocal)
end

return ClientCulling
