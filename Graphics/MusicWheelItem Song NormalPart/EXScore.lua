-- Display best EX from stored highscores
local player = ...

local function CalculateExScoreFromHighscoreAndSteps(hs, steps, pn)
   	-- white fa count is stored in score 🤯
    -- https://discord.com/channels/292111865658474496/958039182327029840/1156796786061606972
	local score = hs:GetScore()
	local ex_counts = {
        W0 = hs:GetTapNoteScore(ToEnumShortString("TNS_W1")) - score,
		W1 = score,
		W2 = hs:GetTapNoteScore(ToEnumShortString("TNS_W2")),
		W3 = hs:GetTapNoteScore(ToEnumShortString("TNS_W3")),
		W4 = hs:GetTapNoteScore(ToEnumShortString("TNS_W4")),
		W5 = hs:GetTapNoteScore(ToEnumShortString("TNS_W5")),
		Miss = hs:GetTapNoteScore(ToEnumShortString("TNS_Miss")),
		Held = hs:GetHoldNoteScore(ToEnumShortString("HNS_Held")),
		LetGo = hs:GetHoldNoteScore(ToEnumShortString("HNS_LetGo")),
		HitMine = hs:GetTapNoteScore(ToEnumShortString("TNS_HitMine"))
	}

    local use_actual_w0_weight = true
    local po_NoMines = false -- can't determine from highscore?
	return CalculateExScoreNoGlobalState(steps, pn, po_NoMines, ex_counts, use_actual_w0_weight)
end

-- Based on GetLamp
-- Colors in SL.JudgementColors["FA+"]:
-- 1: blue    (FFC)
-- 2: white   (normal)
-- 3: gold    (FEC)
-- 4: green   (FC)
-- 5: purple  (FBFC)
-- 6: red     (fail)
-- Still called AwardMap since it's mostly based on the awards...
local AwardMap = {
	["StageAward_FullComboW1"] = 1,
	["StageAward_FullComboW2"] = 3,
	["StageAward_SingleDigitW2"] = 3,
	["StageAward_OneW2"] = 3,
	["StageAward_FullComboW3"] = 4,
	["StageAward_SingleDigitW3"] = 4,
	["StageAward_OneW3"] = 4,
	["StageAward_100PercentW3"] = 4,
	-- The StageAwards below technically doesn't exist, but we create them on the
	-- fly below.
	["StageAward_FullComboW0"] = 5,
    ["normal"] = 2,
    ["fail"] = 6
}

-- Based on GetLamp
local function EXColorForHighScore(score)
	local award = score:GetStageAward()
    local grade = score:GetGrade()

    -- quint
	if grade == "Grade_Tier01" then
		if score:GetPercentDP() == 1.0 and score:GetScore() < score:GetTapNoteScore("TapNoteScore_W1") and score:GetScore() == 0 then
			award = "StageAward_FullComboW0"
		end
	end

    if grade == "Grade_Failed" then
        award = "fail"
    end

    if award == nil then
        award = "normal"
    end

    local aw_res = AwardMap[award]
	return SL.JudgmentColors["FA+"][aw_res]
end

-- Add EX scores to the song wheel as well.
-- It will be centered to the item if only one player is enabled, and stacked otherwise.
return Def.BitmapText{
    Font="Wendy/_wendy monospace numbers",
    Text="",
    InitCommand=function(self)
        self:visible(false)
        self:zoom(0.2)
        self:x(32)
    end,
    PlayerJoinedMessageCommand=function(self)
        self:visible(GAMESTATE:IsPlayerEnabled(player))
    end,
    PlayerUnjoinedMessageCommand=function(self)
        self:visible(GAMESTATE:IsPlayerEnabled(player))
    end,
    SetCommand=function(self, params)
        -- Only display EX score if a profile is found for an enabled player.
        self:visible(false):settext("")
        if not GAMESTATE:IsPlayerEnabled(player) or not PROFILEMAN:IsPersistentProfile(player) then
            return
        end

        if GAMESTATE:GetNumSidesJoined() == 2 then
            if player == PLAYER_1 then
                self:y(-11)
            else
                self:y(4)
            end
        else
            self:y(-4)
        end

        local pn = ToEnumShortString(player)
        if params.Song ~= nil then
            local song = params.Song
            local steps = SongUtil.GetPlayableSteps(song)

            local currentSteps = GAMESTATE:GetCurrentSteps(player)
            if currentSteps == nil then
                -- SM("currentSteps nil")
                return
            end

            local currentDifficulty = currentSteps:GetDifficulty()

            -- Like grades, show tech that matches the currently selected difficulty.
            local stepsToCheck = nil
            if #steps == 1 then
                -- If there's only a single difficulty, don't try to match the difficulty. Just show the only one.
                stepsToCheck = steps[1]
            else
                -- TODO: Match the engine (or theme?) behaviour on which difficulty will be autoselected from this chart
                for k, v in ipairs(steps) do
                    if v:GetDifficulty() == currentDifficulty then
                        stepsToCheck = v
                    end
                end
            end

            if stepsToCheck == nil then
                return
            end

            local highscores = PROFILEMAN:GetProfile(pn):GetHighScoreList(song, stepsToCheck):GetHighScores()

            local best_ex = nil
            local hs_for_best_ex = nil
			for hs in ivalues(highscores) do
				local ex = CalculateExScoreFromHighscoreAndSteps(hs, stepsToCheck, pn)
				if ex ~= nil and best_ex == nil then
					best_ex = ex
                    hs_for_best_ex = hs
				elseif ex ~= nil and ex > best_ex then
					best_ex = ex
                    hs_for_best_ex = hs
				end
			end

			if best_ex ~= nil then
				self:settext(("%05.2f"):format(best_ex))
                self:diffuse(EXColorForHighScore(hs_for_best_ex))
				self:visible(true)
			end
        end
    end,
}