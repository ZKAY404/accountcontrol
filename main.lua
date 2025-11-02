-- Remote-listener & runner (executor/local)
-- Polls http://192.168.1.49:5500/main.lua and runs it safely when updated.
-- Suppresses print/warn/error calls from the remote script and prevents console spam
-- when the server is offline. Uses exponential backoff on failures.

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local URL = "http://192.168.1.49:5500/main.lua"
local POLL_INTERVAL = 5                -- seconds between checks when healthy
local MAX_BACKOFF = 60                 -- max seconds when server is down
local SUPPRESS_OUTPUT = true           -- suppress print/warn/error from remote code

-- internal state
local lastSource = nil
local consecutiveFails = 0
local runningThread = nil

-- create a sandbox env that suppresses print/warn/error but otherwise falls back to _G
local function makeSandbox()
	local env = {
		-- silence output from remote code
		print = function() end,
		warn  = function() end,
		error = function() end,
		-- allow common libs
		math = math,
		string = string,
		table = table,
		task = task,
		pcall = pcall,
		xpcall = xpcall,
		tonumber = tonumber,
		tostring = tostring,
		type = type,
		pairs = pairs,
		ipairs = ipairs,
		next = next,
		select = select,
		-- give access to game (remote code may need it)
		game = game,
		wait = task.wait,
		tick = tick,
		os = { time = os and os.time or nil }, -- minimal os exposure
	}
	-- fallback to globals for anything else
	setmetatable(env, { __index = _G })
	return env
end

-- safely compile source into a function with a sandbox env
local function compileSource(src)
	-- try modern load with env (some runtimes support load(source, name, mode, env))
	local fn, err
	if load then
		-- try load with env first (works in many Lua versions)
		local ok, loaderErr = pcall(function()
			fn, err = load(src, "remote_main", "t", makeSandbox())
		end)
		-- if load with env not supported or failed, fall back to loadstring + setfenv
		if not fn and (loadstring or load) then
			-- loadstring fallback
			local loader = loadstring or load
			local f, e = pcall(function() return loader(src) end)
			if f and e then
				fn = e
				err = nil
				-- attempt to setfenv if available
				local sandbox = makeSandbox()
				if setfenv then
					pcall(setfenv, fn, sandbox)
				elseif _ENV then
					-- if environment can't be set, we will still run but with normal globals
				end
			else
				err = e
			end
		end
	else
		-- very old environment: try loadstring
		if loadstring then
			local ok, e = pcall(function() return loadstring(src) end)
			if ok and e then
				fn = e
				err = nil
				if setfenv then
					pcall(setfenv, fn, makeSandbox())
				end
			else
				err = e
			end
		end
	end
	return fn, err
end

-- run compiled function in protected coroutine so it can't crash main loop
local function safeExecute(fn)
	if not fn then return false, "no function" end
	-- wrap in pcall to catch runtime errors
	local ok, err = pcall(function()
		-- run in coroutine so long-running remote code doesn't block our poll loop
		local coro = coroutine.create(function()
			local success, e = pcall(fn)
			if not success then
				-- swallowing remote error (silent), but you can uncomment the line below to log
				-- warn("Remote script runtime error:", e)
			end
		end)
		-- resume coroutine safely
		pcall(coroutine.resume, coro)
	end)
	return ok, err
end

-- main polling loop
task.spawn(function()
	while true do
		local ok, body = pcall(function()
			-- HttpService:GetAsync may error if HttpEnabled is false or host unreachable
			return HttpService:GetAsync(URL, true)
		end)

		if ok and body and #body > 0 then
			-- reset fail counter
			consecutiveFails = 0

			-- only recompile & run if changed
			if body ~= lastSource then
				lastSource = body

				-- try compile
				local fn, ferr = compileSource(body)
				if not fn then
					-- compilation failed; swallow the error to avoid spam
					-- optionally print once for debugging:
					-- warn("Remote compile error:", ferr)
				else
					-- execute safely (suppressed prints & runtime errors)
					pcall(function()
						safeExecute(fn)
					end)
				end
			end

			-- healthy poll interval
			task.wait(POLL_INTERVAL)
		else
			-- failed to fetch (server down or network). increase backoff and wait.
			consecutiveFails = consecutiveFails + 1
			local backoff = math.min(MAX_BACKOFF, (2 ^ (consecutiveFails - 1)) * (POLL_INTERVAL))
			-- avoid spamming console; only warn first time optionally
			-- warn(("Remote fetch failed (attempt %d), backing off %ds"):format(consecutiveFails, backoff))
			task.wait(backoff)
		end
	end
end)
