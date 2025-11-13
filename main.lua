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
local SimulateProj = require("projectilesim")

local utils = {}
utils.math = require("utils.math")
utils.weapon = require("utils.weapon_utils")

---@class State
---@field target Entity?
---@field angle EulerAngles?
---@field path Vector3[]?
---@field storedpath {removetime: number, path: Vector3[]?, projpath: Vector3[]?, projtimetable: number[]?, timetable: number[]?}
---@field charge number
---@field charges boolean
----@field accuracy number?
local state = {
	target = nil,
	angle = nil,
	path = nil,
	--accuracy = nil, --- ()
	storedpath = {removetime = 0.0, path = nil, projpath = nil, projtimetable = nil, timetable = nil},
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

local function CleanTimeTable(pathtbl, timetbl)
	if not pathtbl or not timetbl or #pathtbl ~= #timetbl or #pathtbl < 2 then
		return nil, nil
	end

	local curtime = globals.CurTime()
	local newpath = {}
	local newtime = {}

	for i = 1, #timetbl do
		if timetbl[i] >= curtime then
			newpath[#newpath+1] = pathtbl[i]
			newtime[#newtime+1] = timetbl[i]
		end
	end

	-- Return nil if we filtered everything out
	if #newpath == 0 then
		return nil, nil
	end

	return newpath, newtime
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

	if state.storedpath.path and state.storedpath.timetable then
		local cleanedpath, cleanedtime = CleanTimeTable(state.storedpath.path, state.storedpath.timetable)
		state.storedpath.path = cleanedpath
		state.storedpath.timetable = cleanedtime
	end

	if state.storedpath.projpath and state.storedpath.projtimetable then
		local cleanedprojpath, cleanedprojtime = CleanTimeTable(state.storedpath.projpath, state.storedpath.projtimetable)
		state.storedpath.projpath = cleanedprojpath
		state.storedpath.projtimetable = cleanedprojtime
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
	local path, lastPos, timetable = SimulatePlayer(bestEnt, time)

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
	local projtimetable = {}

	local translatedAngle = utils.math.SolveBallisticArc(firePos, lastPos, speed, gravity)
	if translatedAngle then
		projpath, hit, projtimetable = SimulateProj(bestEnt, lastPos, firePos, translatedAngle, info, plocal:GetTeamNumber(), time, charge)
		if not hit then
			return
		end
	end

	state.target = bestEnt
	state.path = path
	state.angle = angle
	state.storedpath.path = path
	state.storedpath.projpath = projpath
	state.storedpath.timetable = timetable
	state.storedpath.projtimetable = projtimetable
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

	if state.charges and state.charge < 0.05 then
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

callbacks.Register("Draw", OnDraw)
callbacks.Register("CreateMove", OnCreateMove)