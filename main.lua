local multipoint = require "multipoint"
--- made by navet

local config = {
	fov = 30.0,
	key = E_ButtonCode.KEY_LSHIFT,
	aim_sentry = true,
	aim_dispenser = true,
	aim_teleporter = true,
	max_distance = 3000,
	min_accuracy = 5,
	max_accuracy = 15,
	path_time = 2.0,
}

--local SimulatePlayer = require("playersim")
local GetProjectileInfo = require("projectile_info")
local SimulatePlayer = require("sim")

local utils = {}
utils.math = require("utils.math")
utils.weapon = require("utils.weapon_utils")

local env = physics.CreateEnvironment()
env:SetAirDensity(2.0)
env:SetGravity(Vector3(0, 0, -800))
env:SetSimulationTimestep(globals.TickInterval())

local projectiles = {}

---@class State
---@field target Entity?
---@field angle EulerAngles?
---@field path Vector3[]?
---@field storedpath {removetime: number, path: Vector3[]?, projpath: Vector3[]?}
---@field charge number
---@field charges boolean
----@field accuracy number?
local state = {
	target = nil,
	angle = nil,
	path = nil,
	--accuracy = nil, --- ()
	storedpath = {removetime = 0.0, path = nil, projpath = nil},
	charge = 0,
	charges = false,
}

---@param localPos Vector3
---@param className string
---@param enemyTeam integer
---@param outTable table
local function ProcessClass(localPos, className, enemyTeam, outTable)
	local isPlayer = false

	for _, entity in pairs (entities.FindByClass(className)) do
		isPlayer = entity:IsPlayer()
		if (isPlayer == true and entity:IsAlive()
		or (isPlayer == false and entity:GetHealth() > 0))
		and not entity:IsDormant()
		and entity:GetTeamNumber() == enemyTeam
		and not entity:InCond(E_TFCOND.TFCond_Cloaked)
		and (localPos - entity:GetAbsOrigin()):Length() <= config.max_distance then
			--print(string.format("Is alive: %s, Health: %d", entity:IsAlive(), entity:GetHealth()))
			outTable[#outTable+1] = entity
		end
	end
end

---@param tbl Vector3[]
local function DrawPath(tbl)
	if #tbl >= 2 then
		local prev = client.WorldToScreen(tbl[1])
		if prev then
			draw.Color(255, 255, 255, 255)
			for i = 2, #tbl do
				local curr = client.WorldToScreen(tbl[i])
				if curr and prev then
					draw.Line(prev[1], prev[2], curr[1], curr[2])
					prev = curr
				else
					break
				end
			end
		end
	end
end

---@return PhysicsObject
local function GetPhysicsProjectile(info)
	local modelName = info.m_sModelName
	if projectiles[modelName] then
		return projectiles[modelName]
	end

	local solid, collision = physics.ParseModelByName(info.m_sModelName)
	if solid == nil or collision == nil then
		error("Solid/collision is nil! Model name: " .. info.m_sModelName)
		return {}
	end

	local projectile = env:CreatePolyObject(collision, solid:GetSurfacePropName(), solid:GetObjectParameters())
	projectiles[modelName] = projectile

	return projectiles[modelName]
end

--- source: https://developer.mozilla.org/en-US/docs/Games/Techniques/3D_collision_detection
---@param currentPos Vector3
---@param vecTargetPredictedPos Vector3
---@param weaponInfo WeaponInfo
---@param vecTargetMaxs Vector3
---@param vecTargetMins Vector3
local function IsIntersectingBB(currentPos, vecTargetPredictedPos, weaponInfo, vecTargetMaxs, vecTargetMins)
    local vecProjMins = weaponInfo.m_vecMins + currentPos
    local vecProjMaxs = weaponInfo.m_vecMaxs + currentPos

    local targetMins = vecTargetMins + vecTargetPredictedPos
    local targetMaxs = vecTargetMaxs + vecTargetPredictedPos

    -- check overlap on X, Y, and Z
    if vecProjMaxs.x < targetMins.x or vecProjMins.x > targetMaxs.x then return false end
    if vecProjMaxs.y < targetMins.y or vecProjMins.y > targetMaxs.y then return false end
    if vecProjMaxs.z < targetMins.z or vecProjMins.z > targetMaxs.z then return false end

    return true -- all axis overlap
end

---@param target Entity
---@param targetPredictedPos Vector3
---@param startPos Vector3
---@param angle EulerAngles
---@param info WeaponInfo
---@param time_seconds number
---@param localTeam integer
---@param charge number
---@return Vector3[], boolean?
local function SimulateProjectile(target, targetPredictedPos, startPos, angle, info, localTeam, time_seconds, charge)
	local projectile = GetPhysicsProjectile(info)
	if projectile == nil then
		return {}
	end

	projectile:Wake()

	local angForward = angle:Forward()

	local timeEnd = env:GetSimulationTime() + time_seconds
	local tickInterval = globals.TickInterval() * 3.0

	local velocityVector = info:GetVelocity(charge)
	local startVelocity = (angForward * velocityVector:Length2D()) + (Vector3(0, 0, velocityVector.z))
	projectile:SetPosition(startPos, angle:Forward(), true)
	projectile:SetVelocity(startVelocity, info:GetAngularVelocity(charge))

	local mins, maxs = info.m_vecMins, info.m_vecMaxs
	local path = {}
	local hit = false

	while env:GetSimulationTime() < timeEnd do
		local vStart = projectile:GetPosition()
		env:Simulate(tickInterval)
		local vEnd = projectile:GetPosition()

		local trace = engine.TraceHull(vStart, vEnd, mins, maxs, info.m_iTraceMask, function (ent, contentsMask)
			if ent:GetIndex() == target:GetIndex() then
				return true
			end

			if ent:GetTeamNumber() ~= localTeam and info.m_bStopOnHittingEnemy then
				return true
			end

			if ent:GetTeamNumber() == localTeam and env:GetSimulationTime() > info.m_flCollideWithTeammatesDelay then
				return true
			end

			return false
		end)

		if IsIntersectingBB(vEnd, targetPredictedPos, info, target:GetMaxs(), target:GetMins()) then
			hit = true
			break
		end

		if not trace or trace.fraction < 1.0 then
			break
		end

		path[#path+1] = Vector3(vEnd:Unpack())
	end

	projectile:Sleep()
	return path, hit
end

---@param target Entity
---@param targetPredictedPos Vector3
---@param startPos Vector3
---@param angle EulerAngles
---@param info WeaponInfo
---@param time_seconds number
---@param localTeam integer
---@return Vector3[], boolean?
local function SimulatePseudoProjectile(target, targetPredictedPos, startPos, angle, info, localTeam, time_seconds, charge)
	local angForward = angle:Forward()
	local tickInterval = globals.TickInterval() * 3.0

	local velocityVector = info:GetVelocity(charge)
	local startVelocity = (angForward * velocityVector:Length2D()) + Vector3(0, 0, velocityVector.z)

	local mins, maxs = info.m_vecMins, info.m_vecMaxs
	local path = {}
	local hit = false
	local time = 0.0

	-- Get gravity from info
	local _, sv_gravity = client.GetConVar("sv_gravity")
	local gravity = sv_gravity * info:GetGravity(charge)

	local currentPos = startPos
	local currentVel = startVelocity

	while time < time_seconds do
		local vStart = currentPos

		-- Apply gravity to velocity
		currentVel = currentVel + Vector3(0, 0, -gravity * tickInterval)

		local vEnd = currentPos + currentVel * tickInterval

		local trace = engine.TraceHull(vStart, vEnd, mins, maxs, info.m_iTraceMask or MASK_SHOT_HULL, function (ent, contentsMask)
			-- Ignore invalid entities
			if not ent or ent:GetIndex() == 0 then
				return false
			end

			-- Check if we hit our target
			if ent:GetIndex() == target:GetIndex() then
				hit = true
				return true
			end

			-- Check enemy collision
			if ent:GetTeamNumber() ~= localTeam and info.m_bStopOnHittingEnemy then
				return true
			end

			-- Check teammate collision after delay
			if ent:GetTeamNumber() == localTeam and time > info.m_flCollideWithTeammatesDelay then
				return true
			end

			return false
		end)

		-- Add current position to path before checking collision
		path[#path+1] = Vector3(vEnd:Unpack())

		if IsIntersectingBB(vEnd, targetPredictedPos, info, target:GetMaxs(), target:GetMins()) then
			hit = true
			break
		end

		if not trace or trace.fraction < 1.0 then
			break
		end

		currentPos = vEnd
		time = time + tickInterval
	end

	return path, hit
end

local function OnDraw()
	--- Reset our state table
	state.angle = nil
	state.path = nil
	state.target = nil
	state.charge = 0
	state.charges = false

	local netchannel = clientstate.GetNetChannel()

	if netchannel == nil then
		return
	end

	if clientstate.GetClientSignonState() <= E_SignonState.SIGNONSTATE_SPAWN then
		return
	end

	if globals.CurTime() >= state.storedpath.removetime then
		state.storedpath.path = nil
		state.storedpath.projpath = nil
	end

	--- TODO: Use a polygon instead!
	local storedpath = state.storedpath.path
	if storedpath then
		DrawPath(storedpath)
	end

	local storedprojpath = state.storedpath.projpath
	if storedprojpath then
		DrawPath(storedprojpath)
	end

	if input.IsButtonDown(config.key) == false then
		return
	end

	if utils.weapon.CanShoot() == false then
		return
	end

	local plocal = entities.GetLocalPlayer()
	if plocal == nil then
		return
	end

	local weapon = plocal:GetPropEntity("m_hActiveWeapon")
	if weapon == nil then
		return
	end

	local info = GetProjectileInfo(weapon:GetPropInt("m_iItemDefinitionIndex"))
	if info == nil then
		return
	end

	local enemyTeam = plocal:GetTeamNumber() == 2 and 3 or 2
	local localPos = plocal:GetAbsOrigin()

	---@type Entity[]
	local entitylist = {}
	ProcessClass(localPos, "CTFPlayer", enemyTeam, entitylist)

	if config.aim_sentry then
		ProcessClass(localPos, "CObjectSentrygun", enemyTeam, entitylist)
	end

	if config.aim_dispenser then
		ProcessClass(localPos, "CObjectDispenser", enemyTeam, entitylist)
	end

	if config.aim_teleporter then
		ProcessClass(localPos, "CObjectTeleporter", enemyTeam, entitylist)
	end

	if #entitylist == 0 then
		return
	end

	local eyePos = localPos + plocal:GetPropVector("localdata", "m_vecViewOffset[0]")
	local viewangle = engine.GetViewAngles()

	local angle, bestFov, bestEnt = nil, config.fov, nil
	for _, entity in ipairs(entitylist) do
		local center = entity:GetAbsOrigin() + (entity:GetMins() + entity:GetMaxs()) * 0.5
		angle = utils.math.PositionAngles(eyePos, center)
		if angle then
			local fov = utils.math.AngleFov(viewangle, angle)
			if fov < bestFov then
				bestFov = fov
				bestEnt = entity
			end
		end
	end

	if bestEnt == nil then
		return
	end

	local charge = info.m_bCharges and weapon:GetCurrentCharge() or 0.0 --weapon:GetChargeBeginTime() or 0.0
	local speed = info:GetVelocity(charge):Length2D()

	local distance = (localPos - bestEnt:GetAbsOrigin() + (bestEnt:GetMins() + bestEnt:GetMaxs()) * 0.5):Length()
	local time = (distance/speed) + (netchannel:GetLatency(E_Flows.FLOW_INCOMING) + netchannel:GetLatency(E_Flows.FLOW_OUTGOING))

	--local minAccuracy, maxAccuracy = config.min_accuracy, config.max_accuracy
	--local maxDistance = config.max_distance
	--local accuracy = minAccuracy + (maxAccuracy - minAccuracy) * (math.min(distance/maxDistance, 1.0)^1.5)
	local path, lastPos = SimulatePlayer(bestEnt, time)

	local _, sv_gravity = client.GetConVar("sv_gravity")
	local gravity = sv_gravity * 0.5 * info:GetGravity(charge)

	local _, multipointPos = multipoint.Run(bestEnt, weapon, info, eyePos, lastPos)
	if multipointPos then
		lastPos = multipointPos
	end

	angle = utils.math.SolveBallisticArc(eyePos, lastPos, speed, gravity)
	if angle == nil then
		return
	end

	local firePos = info:GetFirePosition(plocal, eyePos, angle, weapon:IsViewModelFlipped())
	local projpath = {}
	local hit = nil

	local translatedAngle = utils.math.SolveBallisticArc(firePos, lastPos, speed, gravity)
	if translatedAngle then
		if info.m_sModelName and info.m_sModelName ~= "" then
			projpath, hit = SimulateProjectile(bestEnt, lastPos, firePos, translatedAngle, info, plocal:GetTeamNumber(), time, charge)
		else
			projpath, hit = SimulatePseudoProjectile(bestEnt, lastPos, firePos, translatedAngle, info, plocal:GetTeamNumber(), time, charge)
		end
	end

	if not hit then
		return
	end

	state.target = bestEnt
	state.path = path
	state.angle = angle
	state.storedpath.path = path
	state.storedpath.projpath = projpath
	state.storedpath.removetime = globals.CurTime() + config.path_time
	state.charge = charge
	state.charges = info.m_bCharges
end

---@param cmd UserCmd
local function OnCreateMove(cmd)
	if utils.weapon.CanShoot() == false then
		return
	end

	if input.IsButtonDown(config.key) == false then
		return
	end

	if not state.angle then
		return
	end

	if state.charge > 1.0 then
		state.charge = 0
	end

	if state.charges and state.charge < 0.1 then
		cmd.buttons = cmd.buttons | IN_ATTACK
		return
	end

	if state.charges then
		cmd.buttons = cmd.buttons & ~IN_ATTACK
	else
		cmd.buttons = cmd.buttons | IN_ATTACK
	end

	cmd.sendpacket = false
	cmd.viewangles = Vector3(state.angle:Unpack())
end

local function OnUnload()
	for _, obj in pairs (projectiles) do
		env:DestroyObject(obj)
	end

	physics.DestroyEnvironment(env)
end

callbacks.Register("Draw", OnDraw)
callbacks.Register("CreateMove", OnCreateMove)
callbacks.Register("Unload", OnUnload)