local fb = __foxBot_1

local function AddFBHook(type, func, order)
	if not func
		return
	end

	order = $ or 0
	func = {
		func = func,
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

function fb.AddAIHook(func, order)
	AddFBHook("ai", func, order)
end

function fb.AddGlobHook(func, order)
	AddFBHook("glob", func, order)
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
	if server
		CONS_Printf(server, #player .. " " .. player.cmd.forwardmove)
	end
end, 1)

fb.AddAIHook(function(player)
	player.cmd.forwardmove = P_RandomRange(-50, 50)
end)

fb.AddAIHook(function(player)
	if server
		CONS_Printf(server, #player .. " " .. player.cmd.forwardmove)
	end
end, -1)

fb.AddGlobHook(function(player)
	player.cmd.sidemove = P_RandomRange(-50, 50)
end)

addHook("PlayerSpawn", function(player)
	player.ai = {}
	if #player == 0
		player.ai.cmd_time = 1
	end
end)
