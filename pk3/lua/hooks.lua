local fb = __foxBot_1

local function AddBotHook(type, name, func, order)
	if not (name and func)
		print("\x85-- ERROR: foxBot AddHook name or func nil! --")
		return
	end

	order = $ or 0
	func = {
		name = name,
		func = $,
		order = order
	}

	type = "_" .. $
	local f = fb[type]
	if not f
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

function fb.AddAIHook(name, func, order)
	AddBotHook("ai", name, func, order)
end

function fb.AddGlobHook(name, func, order)
	AddBotHook("glob", name, func, order)
end

local function ExecuteFBHook(type, player)
	local f = fb["_" .. type]
	while f and not f.func(player)
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

fb.AddAIHook("post", function(player)
	CONS_Printf(player.ai.leader, #player .. " " .. player.cmd.forwardmove)
end, 1)

fb.AddAIHook("asdf", function(player)
	player.cmd.forwardmove = P_RandomRange(-50, 50)
end)

fb.AddAIHook("pre", function(player)
	CONS_Printf(player.ai.leader, #player .. " " .. player.cmd.forwardmove)
end, -1)

fb.AddGlobHook("asdf", function(player)
	player.cmd.sidemove = P_RandomRange(-50, 50)
end)

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
