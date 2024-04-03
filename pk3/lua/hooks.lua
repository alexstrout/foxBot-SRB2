local fb = __foxBot_1

local function AddFBHook(type, func, name, order)
	if not (func and name)
		print("\x85-- ERROR: foxBot AddHook func or name nil! --")
		return
	end

	order = $ or 0
	func = {
		func = func,
		name = string.upper(name),
		order = order
	}

	type = "_" .. $
	local f = fb[type]
	if f == nil
		fb[type] = func
	elseif f.order > order
		func.nextfunc = f
		fb[type] = func
	else
		while f.nextfunc
		and f.nextfunc.order <= order
			f = f.nextfunc
		end
		func.nextfunc = f.nextfunc
		f.nextfunc = func
	end
end

function fb.AddAIHook(func, name, order)
	AddFBHook("ai", func, name, order)
end

function fb.AddGlobHook(func, name, order)
	AddFBHook("glob", func, name, order)
end

local function ExecuteFBHook(type, player)
	local f = fb["_" .. type]
	while f
		f.func(player)
		f = f.nextfunc
	end
end

addHook("PreThinkFrame", function()
	for player in players.iterate
		if player.ai
			ExecuteFBHook("glob", player)
			if not player.ai.cmd_time
				ExecuteFBHook("ai", player)
			end
		end
	end
end)

fb.AddAIHook(function(player)
	CONS_Printf(player.ai.leader, #player .. " " .. player.cmd.forwardmove)
end, "post", 1)

fb.AddAIHook(function(player)
	player.cmd.forwardmove = P_RandomRange(-50, 50)
end, "asdf")

fb.AddAIHook(function(player)
	CONS_Printf(player.ai.leader, #player .. " " .. player.cmd.forwardmove)
end, "pre", -1)

fb.AddGlobHook(function(player)
	player.cmd.sidemove = P_RandomRange(-50, 50)
end, "asdf")

COM_AddCommand("DEBUG_LISTHOOKS", function(player)
	local function PrintHooks(player, type)
		CONS_Printf(player, "-- Hooks: " .. type .. " --")
		local f = fb["_" .. type]
		while f
			CONS_Printf(player, tostring(f.func) .. " " .. f.order .. " " .. f.name)
			f = f.nextfunc
		end
	end
	PrintHooks(player, "glob")
	PrintHooks(player, "ai")
end, 0)
