local multipoint = require "multipoint"
--- made by navet

local config = {
	fov = 30.0,
	key = E_ButtonCode.KEY_LSHIFT,
	aim_sentry = true,
	aim_dispenser = true,
	aim_teleporter = true,
	max_distance = 3000,
	min_accuracy = 2,
	max_accuracy = 12,
	min_confidence = 40, --- %
}

--local SimulatePlayer = require("playersim")
local GetProjectileInfo = require("projectile_info")
local SimulatePlayer = require("playersim")
local SimulateProj = require("projectilesim")

local utils = {}
utils.math = require("utils.math")
utils.weapon = require("utils.weapon_utils")

---@class State
---@field target Entity?
---@field angle EulerAngles?
---@field path Vector3[]?
---@field storedpath {path: Vector3[]?, projpath: Vector3[]?, projtimetable: number[]?, timetable: number[]?}
---@field charge number
---@field charges boolean
---@field silent boolean
---@field secondaryfire boolean
----@field accuracy number?
local state = {
	target = nil,
	angle = nil,
	path = nil,
	storedpath = {path = nil, projpath = nil, projtimetable = nil, timetable = nil},
	charge = 0,
	charges = false,
	silent = true,
	secondaryfire = false
}

local noSilentTbl = {
	[E_WeaponBaseID.TF_WEAPON_CLEAVER] = true,
	[E_WeaponBaseID.TF_WEAPON_BAT_WOOD] = true,
	[E_WeaponBaseID.TF_WEAPON_BAT_GIFTWRAP] = true,
	[E_WeaponBaseID.TF_WEAPON_LUNCHBOX] = true,
	[E_WeaponBaseID.TF_WEAPON_JAR] = true,
	[E_WeaponBaseID.TF_WEAPON_JAR_MILK] = true,
	[E_WeaponBaseID.TF_WEAPON_JAR_GAS] = true,
	[E_WeaponBaseID.TF_WEAPON_FLAME_BALL] = true,
}

local doSecondaryFiretbl = {
	[E_WeaponBaseID.TF_WEAPON_BAT_GIFTWRAP] = true,
	[E_WeaponBaseID.TF_WEAPON_LUNCHBOX] = true,
	[E_WeaponBaseID.TF_WEAPON_BAT_WOOD] = true,
}

local font = draw.CreateFont("Arial", 12, 0)

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

---@param entity Entity The target entity
---@param projpath Vector3[]? The predicted projectile path
---@param hit boolean? Whether projectile simulation hit the target
---@param distance number Distance to target
---@param speed number Projectile speed
---@param gravity number Gravity modifier
---@param time number Prediction time
---@return number score Hitchance score from 0-100%
local function CalculateHitchance(entity, projpath, hit, distance, speed, gravity, time)
    local score = 100.0

    local maxDistance = config.max_distance or 3000
    local distanceFactor = math.min(distance / maxDistance, 1.0)
    score = score - (distanceFactor * 40)

    --- prediction time penalty (longer predictions = less accurate)
    if time > 2.0 then
        score = score - ((time - 2.0) * 15)
    elseif time > 1.0 then
        score = score - ((time - 1.0) * 10)
    end

    --- projectile simulation penalties
    if projpath then
        --- if hit something, penalize the shit out of it
        if not hit then
            score = score - 100
        end

        --- penalty for very long projectile paths (more chance for error)
        if #projpath > 50 then
            score = score - 10
        elseif #projpath > 100 then
            score = score - 20
        end
    else
        --- i dont remember if i ever return nil for projpath
		--- but fuck it we ball
        score = score - 100
    end

    --- gravity penalty (high arc = less accurate (kill me))
    if gravity > 0 then
		--- using 400 or 800 gravity is such a pain
		--- i dont remember anymore why i chose 400 here
		--- but its working fine as far as i know
		--- unless im using 800 graviy
		--- then this is probably giving a shit ton of score
		--- but im so confused and sleep deprived that i dont care
        local gravityFactor = math.min(gravity/400, 1.0)
        score = score - (gravityFactor * 15)
    end

    --- targed speed penalty
	--- more speed = less confiident we are
    local velocity = entity:EstimateAbsVelocity() or Vector3()
    if velocity then
        local speed2d = velocity:Length2D()
        if speed2d > 300 then
            score = score - 15
        elseif speed2d > 200 then
            score = score - 10
        elseif speed2d > 100 then
            score = score - 5
        end
    end

    --- target class bonus/penalty
    if entity:IsPlayer() then
        local class = entity:GetPropInt("m_iClass")
        --- scouts are harder to hit
        if class == E_Character.TF2_Scout then -- Scout
            score = score - 10
        end

        --- classes easier to hit
        if class == E_Character.TF2_Heavy or class == E_Character.TF2_Sniper then -- Heavy or Sniper
            score = score + 5
        end

        --- penalize air targets
		--- i wrote this shit at 3 am, wtf is this?
        if entity:InCond(E_TFCOND.TFCond_BlastJumping) then
            score = score - 15
        end
    else
        --- buildings dont have feet (at least the ones i know)
        score = score + 15
    end

    --- projectile speed penalty (slow projectiles are harder to hit)
    if speed < 1000 then
        score = score - 10
    elseif speed < 1500 then
        score = score - 5
    end

    --- clamp this
    return math.max(0, math.min(100, score))
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

	draw.Color(255, 255, 255 ,255)
	draw.SetFont(font)
	draw.TextShadow(10, 10, string.format("Confidence: %f", state.confidence or 0))

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

	local charge = info.m_bCharges and weapon:GetCurrentCharge() or 0.0
	local speed = info:GetVelocity(charge):Length2D()
	local _, sv_gravity = client.GetConVar("sv_gravity")
	local gravity = sv_gravity * 0.5 * info:GetGravity(charge)
	local weaponID = weapon:GetWeaponID()

	-- Predict all entities and find the best one
	local bestFov = config.fov
	local bestEnt = nil
	local bestAngle = nil
	local bestPath = nil
	local bestTimeTable = nil
	local bestProjPath = nil
	local bestProjTimeTable = nil
	local bestConfidence = config.min_confidence

	local minAccuracy, maxAccuracy = config.min_accuracy, config.max_accuracy
	local maxDistance = config.max_distance

	for _, entity in ipairs(entitylist) do
		local distance = (localPos - entity:GetAbsOrigin() + (entity:GetMins() + entity:GetMaxs()) * 0.5):Length()
		local time = (distance/speed) + (netchannel:GetLatency(E_Flows.FLOW_INCOMING) + netchannel:GetLatency(E_Flows.FLOW_OUTGOING))
		local lazyness = minAccuracy + (maxAccuracy - minAccuracy) * (math.min(distance/maxDistance, 1.0)^1.5)

		local path, lastPos, timetable = SimulatePlayer(entity, time, lazyness)

		local _, multipointPos = multipoint.Run(entity, weapon, info, eyePos, lastPos)
		if multipointPos then
			lastPos = multipointPos
		end

		local angle = utils.math.SolveBallisticArc(eyePos, lastPos, speed, gravity)
		if angle then

			-- Check visibility
			local firePos = info:GetFirePosition(plocal, eyePos, angle, weapon:IsViewModelFlipped())
			local translatedAngle = utils.math.SolveBallisticArc(firePos, lastPos, speed, gravity)

			if translatedAngle then
				local projpath, hit, projtimetable = SimulateProj(entity, lastPos, firePos, translatedAngle, info, plocal:GetTeamNumber(), time, charge)

				--- only choose him if the projecile's trajectory wasn't obstructed (hitted? man english is hard :sob:)
				if hit then
					local fov = utils.math.AngleFov(viewangle, angle)
					if fov < bestFov then
						local confidence = CalculateHitchance(entity, projpath, hit, distance, speed, gravity, time)
						if confidence > bestConfidence then
							bestFov = fov
							bestEnt = entity
							bestAngle = angle
							bestPath = path
							bestTimeTable = timetable
							bestProjPath = projpath
							bestProjTimeTable = projtimetable
							bestConfidence = confidence
						end
					end
				end
			end
		end
	end

	if bestEnt == nil then
		return
	end

	local secondaryFire = doSecondaryFiretbl[weaponID]
	local noSilent = noSilentTbl[weaponID]

	state.target = bestEnt
	state.path = bestPath
	state.angle = bestAngle
	state.storedpath.path = bestPath
	state.storedpath.projpath = bestProjPath
	state.storedpath.timetable = bestTimeTable
	state.storedpath.projtimetable = bestProjTimeTable
	state.charge = charge
	state.charges = info.m_bCharges
	state.secondaryfire = secondaryFire
	state.silent = not noSilent --- janky ahh stuff
	state.confidence = bestConfidence
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
		if state.secondaryfire then
			cmd.buttons = cmd.buttons | IN_ATTACK2
		else
			cmd.buttons = cmd.buttons | IN_ATTACK
		end
	end

	if state.silent then
		cmd.sendpacket = false
	end

	cmd.viewangles = Vector3(state.angle:Unpack())
end

callbacks.Register("Draw", OnDraw)
callbacks.Register("CreateMove", OnCreateMove)