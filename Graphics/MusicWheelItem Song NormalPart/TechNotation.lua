-- Song wheel tech analysis

local player = ...
local pn = ToEnumShortString(player)


-- The body of SetCommand. Returns a label for the exit taken; SetCommand uses it as the
-- profiler section name so each path is timed separately.
local function RunSet(self, params)
	-- stored for RefreshCommand
	if params and params.Song then
		self.LatestSetSong = params.Song
	end

	-- Section headers, sort entries etc. carry no Song, and the engine hides the whole
	-- Song NormalPart for them, so there is nothing to compute or lay out.
	if not params or not params.Song then
		return "exit_nil_song"
	end

	-- song of _this_ actor (every song on the music wheel)
	local song = params.Song

	if not GAMESTATE:IsHumanPlayer(pn) then
		self:visible(false)
		return "exit_not_human"
	end

	-- Resolve what the player currently has selected. On a group header the current
	-- steps are nil; fall back to the preferred difficulty and the style's steps type,
	-- which is what the engine's grade display does, so the notation stays visible there.
	local currentSteps = GAMESTATE:GetCurrentSteps(player)
	local currentDifficulty, currentStepsType
	if currentSteps == nil then
		currentDifficulty = GAMESTATE:GetPreferredDifficulty(player)
		currentStepsType = GAMESTATE:GetCurrentStyle():GetStepsType()
	else
		currentDifficulty = currentSteps:GetDifficulty()
		currentStepsType = currentSteps:GetStepsType()
	end
	local currentSong = GAMESTATE:GetCurrentSong()

	-- Cache hit: the text and layout on screen are already correct for this song at this
	-- difficulty. Layout inputs (joined players, modes) only change on join/unjoin/profile
	-- switch, and RefreshCommand clears this cache for those, so they always reach the full path.
	if self.Song == song and self.Difficulty == currentDifficulty then
		-- The current song can have several charts at the same difficulty (edits); make sure
		-- the one we formatted is still the one selected.
		if song ~= currentSong or self.Steps == currentSteps then
			return "exit_cache_hit"
		end
	end

	-- Full path. Anything that returns below leaves nothing on screen.
	self:visible(false)
	self.Song = nil
	self.Difficulty = nil
	self.Steps = nil

	-- TODO: is there a better way of laying this out?
	local t = SLProf.Begin()
	local x_offset = 10
	local anyMusicWheelScoreYes = PlayerMusicWheelScore(PLAYER_1) == PlayerMusicWheelScore_Yes or PlayerMusicWheelScore(PLAYER_2) == PlayerMusicWheelScore_Yes
	local itlScoreOnRight = not SLMusicWheelScoreEnabled() and IsItlSong(song, player)
	-- If ITL and MusicWheelScore disabled in theme, there's a score displayed on the right side
	-- If MusicWheelScore is Yes, there's a score displayed on the right side (regardless of ITL)
	-- If MusicWheelScore is ReplaceGrade, there's no score displayed on the right side (regardless of ITL)
	if itlScoreOnRight or anyMusicWheelScoreYes then
		-- We have ITL_EXscore or Score on the rightmost side
		x_offset = 60
	end
	self:x(_screen.w / (WideScale(2.15, 2.14)) - x_offset)

	-- visual vertical position depending on if 1 / 2 players are playing
	if GAMESTATE:GetNumSidesJoined() == 2 then
		if player == PLAYER_1 then
			self:y(-6)
		else
			self:y(6)
		end
	else
		self:y(0)
	end
	SLProf.End("Tech.Layout", t)

	-- Like grades, show tech that matches the currently selected difficulty.
	local stepsToCheck = nil
	if song == currentSong and currentSteps then
		stepsToCheck = currentSteps
	else
		t = SLProf.Begin()
		local steps = SongUtil.GetPlayableSteps(song)
		SLProf.End("Tech.GetPlayableSteps", t)
		if #steps == 1 then
			-- If there's only a single difficulty, don't try to match the difficulty. Just show the only one.
			stepsToCheck = steps[1]
		else
			-- Matches the engine behaviour on which Grade is displayed: first chart of the
			-- current steps type at the current difficulty.
			for v in ivalues(steps) do
				if v:GetStepsType() == currentStepsType and v:GetDifficulty() == currentDifficulty then
					stepsToCheck = v
					break
				end
			end
		end
	end

	if stepsToCheck == nil then
		return "exit_nil_steps"
	end

	--- @type string
	local preferred_tech_style = ThemePrefs.Get("MusicWheelTechNotation")
	t = SLProf.Begin()
	local text = SLTechNotation_Format(stepsToCheck, pn, preferred_tech_style)
	SLProf.End("Tech.Format", t)

	t = SLProf.Begin()
	self:settext(text)
	self:visible(true)
	SLProf.End("Tech.settext", t)

	self.Song = song
	self.Difficulty = currentDifficulty
	self.Steps = stepsToCheck
	return "full"
end

-- TODO: 2 actors, one for each player. Could this be one actor that draws both players?
local af = Def.BitmapText {
	Font = "Common Normal",
	Text = "",
	InitCommand = function(self)
		-- TODO: is this a good position? wide screen should have space to make the music wheel wider
		-- position on right side of the song title, left of ITL EX
		-- fits the maximum 6 techs
		self:visible(false)
		self:horizalign(right)
		self:zoom(0.6)
		if DarkUI() then self:diffuse(0, 0, 0, 1) end
	end,

	PlayerJoinedMessageCommand = function(self) self:queuecommand("Refresh") end,
	PlayerUnjoinedMessageCommand = function(self) self:queuecommand("Refresh") end,
	PlayerProfileSetMessageCommand = function(self) self:queuecommand("Refresh") end,

	RefreshCommand = function(self)
		self.Song = nil
		self:visible(false)
		if self.LatestSetSong then
			self:playcommand("Set", { Song = self.LatestSetSong })
		end
	end,

	-- Set is called by MusicWheelItem::HandleMessage. There are a bunch of messages that can trigger it.
	SetCommand = function(self, params)
		local t = SLProf.Begin()
		local outcome = RunSet(self, params)
		SLProf.End("Tech." .. outcome, t)
	end,
}

return af