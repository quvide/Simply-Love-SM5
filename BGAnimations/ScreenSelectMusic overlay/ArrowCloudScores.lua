-- Lifecycle and refresh hook for ArrowCloudScores (Scripts/SL-Helpers-ArrowCloud.lua).
--
-- The requests themselves are made by every music wheel item for the chart it
-- displays (Graphics/MusicWheelItem Song NormalPart/Score.lua), so the charts in
-- view are fetched as soon as the wheel shows them. This actor only:
--   * cancels outstanding requests when leaving the screen, and
--   * on ChartParsed, once the wheel has rested on a chart, refreshes that
--     chart even if a row exists and checks that the theme's Lua hash agrees
--     with the engine hash the cache is keyed by.

return Def.Actor{
	OffCommand = function(self)
		ArrowCloudScores.CancelAll()
	end,
	CancelCommand = function(self)
		ArrowCloudScores.CancelAll()
	end,

	ChartParsedMessageCommand = function(self)
		if GAMESTATE:IsCourseMode() then return end
		local song = GAMESTATE:GetCurrentSong()
		if song == nil then return end

		for player in ivalues(GAMESTATE:GetHumanPlayers()) do
			local steps = GAMESTATE:GetCurrentSteps(player)
			if steps ~= nil then
				-- The GrooveStats pane and score submission still use the theme's Lua
				-- parser hash. Both must agree for cache rows to be found; report if not.
				local pn = ToEnumShortString(player)
				local engine_hash = steps:GetGrooveStatsHash()
				local lua_hash = SL[pn].Streams.Hash
				if lua_hash ~= nil and lua_hash ~= "" and engine_hash ~= nil and engine_hash ~= "" and lua_hash ~= engine_hash then
					lua.Warn("ArrowCloudScores: hash mismatch for " .. song:GetMainTitle() .. " " .. pn .. ": engine=" .. engine_hash .. " theme=" .. lua_hash)
				end
				ArrowCloudScores.Request(player, steps, song, true)
			end
		end
	end,
}
