--// Local listener auto executor
local mainURL = "http://127.0.0.1:5500/main.lua"
local listenURL = "http://127.0.0.1:5500/listen.lua"
local hasRun = false

while true do
	task.wait(0.1) -- repeat frequently to "listen"

	local ok, listenData = pcall(function()
		return game:HttpGet(listenURL)
	end)

	if not ok then
		warn("[Listener] Could not reach listen.lua:", listenData)
		continue
	end

	-- If listen.lua contains "r", trigger main.lua ONCE
	if listenData == "r" and not hasRun then
		hasRun = true
		print("[Listener] Detected 'r' → Running main.lua once")

		local ok2, mainCode = pcall(function()
			return game:HttpGet(mainURL)
		end)

		if ok2 and mainCode ~= "" then
			local success, err = pcall(function()
				loadstring(mainCode)()
			end)
			if not success then
				warn("[Listener] Error running main.lua:", err)
			end
		else
			warn("[Listener] main.lua is empty or failed to load.")
		end
	end

	-- Reset flag when listen.lua becomes empty again
	if listenData == "" and hasRun then
		print("[Listener] listen.lua cleared → Ready for next trigger")
		hasRun = false
	end
end
