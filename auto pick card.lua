getgenv().FocusWave = 20 -- Priority limit wave
getgenv().PriorityCards = { -- Priority tags when wave = FocusWave
    "+ New Path"
    "+ Range I",
    "+ Attack I",
    "+ Gain 2 Random Effects Tier 1",
    "- Cooldown II",
    "+ Range II",
    "+ Attack II",
    "- Cooldown II",
    "+ Gain 2 Random Effects Tier 2",
    "- Cooldown III",
    "+ Range III",
    "+ Attack III",
    "+ Gain 2 Random Effects Tier 3",
    "+ New Path"
}
getgenv().Cards = { -- All cards after FocusWave wave ends
    "+ New Path"
    "+ Explosive Deaths I",
    "+ Explosive Deaths II",
    "+ Explosive Deaths III",
    "+ Gain 2 Random Curses Tier 3",
    "+ Gain 2 Random Curses Tier 2",
    "+ Gain 2 Random Curses Tier 1",
    "+ Enemy Regen I",
    "+ Enemy Regen II",
    "+ Enemy Regen III",
    "+ Enemy Health I",
    "+ Enemy Health II",
    "+ Enemy Health III",
    "+ Boss Damage I",
    "+ Boss Damage II",
    "+ Boss Damage III",
    "+ Range I",
    "- Cooldown I",
    "+ Attack I",
    "+ Gain 2 Random Effects Tier 1",
    "- Cooldown II",
    "+ Range II",
    "+ Attack II",
    "+ Gain 2 Random Effects Tier 2",
    "- Cooldown III",
    "+ Range III",
    "+ Attack III",
    "+ Gain 2 Random Effects Tier 3",
    "+ New Path"

}
-- Priority from bottom to top in all items
repeat task.wait() until game:IsLoaded()
local player = game:GetService("Players").LocalPlayer
local playergui = player:WaitForChild("PlayerGui")
local roguelikeselect = playergui:WaitForChild("RoguelikeSelect")
roguelikeselect.Enabled = true
roguelikeselect.Enabled = false
local waveValue = game:GetService("Workspace"):WaitForChild("_wave_num")
local wavenumber
waveValue:GetPropertyChangedSignal("Value"):Connect(function()
    wavenumber = waveValue.Value
end)
repeat task.wait() until wavenumber and wavenumber >= 1
local positiontable = {}
local newoptions = {}
local args = {}
playergui:FindFirstChild("RoguelikeSelect"):GetPropertyChangedSignal("Enabled"):Connect(function()
    wait()
    local optionframe = playergui.RoguelikeSelect.Main.Main.Items:WaitForChild("OptionFrame")
    optionframe.Active = true
    optionframe.Active = false
    wait(1)
    local options = playergui:WaitForChild("RoguelikeSelect").Main.Main.Items:GetChildren()
    positiontable = {}
    for i, v in pairs(options) do
        if v.Name == "OptionFrame" and v:IsA("Frame") and v:FindFirstChild("bg") then
            table.insert(positiontable, v.AbsolutePosition.X)
        end
    end
    table.sort(positiontable)
    newoptions = {}
    for i, v in pairs(options) do
        if v.Name == "OptionFrame" and v:IsA("Frame") and v:FindFirstChild("bg") and v.AbsolutePosition.X == positiontable[1] then
            table.insert(newoptions, v.bg.Main.Title.TextLabel)
        end
        if newoptions[1] ~= nil then
            if v.Name == "OptionFrame" and v:IsA("Frame") and v:FindFirstChild("bg") and v.AbsolutePosition.X == positiontable[2] then
                table.insert(newoptions, v.bg.Main.Title.TextLabel)
            end
        end
        if newoptions[2] ~= nil then
            if v.Name == "OptionFrame" and v:IsA("Frame") and v:FindFirstChild("bg") and v.AbsolutePosition.X == positiontable[3] then
                table.insert(newoptions, v.bg.Main.Title.TextLabel)
            end
        end
    end
    -- Ưu tiên thẻ trong PriorityCardsFocusWave nếu wave <= FocusWave
    local priorityList = wavenumber <= getgenv().FocusWave and getgenv().PriorityCardsFocusWave or getgenv().Cards
    for i = 1, #priorityList, 1 do
        if newoptions[1].Text == priorityList[i] then
            args = {[1] = "1"}
        elseif newoptions[2].Text == priorityList[i] then
            args = {[1] = "3"}
        elseif newoptions[3].Text == priorityList[i] then
            args = {[1] = "2"}
        end
    end
    wait(0.5)
    game:GetService("ReplicatedStorage").endpoints.client_to_server.select_roguelike_option:InvokeServer(unpack(args))
end)
playergui.RoguelikeSelect.Enabled = true
playergui.RoguelikeSelect.Enabled = false