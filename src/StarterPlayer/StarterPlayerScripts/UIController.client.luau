--!strict
--[[
	UIController (클라이언트)
	--------------------------
	모든 화면 UI를 코드로 생성하고 관리합니다.
	- 상단바: 보유 머니
	- 차고: 차량 목록 / 보유·선택·구매
	- 커스터마이징: 색상·휠·네온·스티커·번호판 (30초 제한 타이머)
	- 대기열: 경주 참가/나가기, 인원·카운트다운 표시
	- 경주 HUD: 시작 카운트다운(3·2·1·GO), 랩 정보, 결과
	- 알림 토스트

	서버와는 ReplicatedStorage.Remotes를 통해 통신합니다.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local GameConfig = require(ReplicatedStorage.GameConfig)
local Remotes = require(ReplicatedStorage.Remotes)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- 로컬 캐시 데이터
local data: any = nil

-- =====================================================================
-- UI 생성 헬퍼
-- =====================================================================
local function make(class: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(class)
	for k, v in pairs(props) do
		(inst :: any)[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function corner(radius: number, parent: Instance)
	make("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

local function color3FromArray(arr: { number }?, fallback: Color3): Color3
	if type(arr) == "table" and #arr >= 3 then
		return Color3.fromRGB(arr[1], arr[2], arr[3])
	end
	return fallback
end

-- =====================================================================
-- 루트 ScreenGui
-- =====================================================================
local gui = make("ScreenGui", {
	Name = "RacingUI",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	IgnoreGuiInset = true,
}, playerGui)

-- ---------------------------------------------------------------------
-- 상단바 (머니)
-- ---------------------------------------------------------------------
local topBar = make("Frame", {
	Size = UDim2.new(0, 220, 0, 48),
	Position = UDim2.new(0, 16, 0, 16),
	BackgroundColor3 = Color3.fromRGB(25, 28, 38),
	BackgroundTransparency = 0.1,
}, gui)
corner(10, topBar)
local moneyLabel = make("TextLabel", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Text = "💰 0",
	TextColor3 = Color3.fromRGB(245, 220, 90),
	Font = Enum.Font.GothamBold,
	TextScaled = true,
	TextXAlignment = Enum.TextXAlignment.Left,
}, topBar)
make("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, moneyLabel)

-- ---------------------------------------------------------------------
-- 우측 버튼 (차고 / 대기열)
-- ---------------------------------------------------------------------
local function actionButton(text: string, color: Color3, yPos: number): TextButton
	local btn = make("TextButton", {
		Size = UDim2.new(0, 180, 0, 52),
		Position = UDim2.new(1, -196, 0, yPos),
		BackgroundColor3 = color,
		Text = text,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		Font = Enum.Font.GothamBold,
		TextScaled = true,
		AutoButtonColor = true,
	}, gui)
	corner(10, btn)
	make("UIPadding", { PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 12) }, btn)
	return btn
end

local garageBtn = actionButton("🚗 차고", Color3.fromRGB(60, 110, 200), 16)
local queueBtn = actionButton("🏁 경주 참가", Color3.fromRGB(70, 180, 90), 80)

-- ---------------------------------------------------------------------
-- 알림 토스트
-- ---------------------------------------------------------------------
local toastHolder = make("Frame", {
	Size = UDim2.new(0, 360, 1, 0),
	Position = UDim2.new(0.5, -180, 0, 80),
	BackgroundTransparency = 1,
}, gui)
make("UIListLayout", {
	Padding = UDim.new(0, 6),
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	VerticalAlignment = Enum.VerticalAlignment.Top,
	SortOrder = Enum.SortOrder.LayoutOrder,
}, toastHolder)

local function showToast(message: string)
	local toast = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 40),
		BackgroundColor3 = Color3.fromRGB(30, 33, 45),
		BackgroundTransparency = 0.05,
		Text = message,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		Font = Enum.Font.GothamMedium,
		TextScaled = true,
	}, toastHolder)
	corner(8, toast)
	make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, toast)
	task.delay(3, function()
		toast:Destroy()
	end)
end

-- =====================================================================
-- 차고 패널
-- =====================================================================
local garageFrame = make("Frame", {
	Size = UDim2.new(0, 720, 0, 460),
	Position = UDim2.new(0.5, -360, 0.5, -230),
	BackgroundColor3 = Color3.fromRGB(22, 25, 34),
	Visible = false,
}, gui)
corner(14, garageFrame)

make("TextLabel", {
	Size = UDim2.new(1, 0, 0, 50),
	BackgroundTransparency = 1,
	Text = "🚗 차고 — 차량 선택 / 구매",
	TextColor3 = Color3.fromRGB(255, 255, 255),
	Font = Enum.Font.GothamBold,
	TextScaled = true,
}, garageFrame)

local garageClose = make("TextButton", {
	Size = UDim2.new(0, 40, 0, 40),
	Position = UDim2.new(1, -48, 0, 8),
	BackgroundColor3 = Color3.fromRGB(200, 70, 70),
	Text = "✕",
	TextColor3 = Color3.fromRGB(255, 255, 255),
	Font = Enum.Font.GothamBold,
	TextScaled = true,
}, garageFrame)
corner(8, garageClose)

local carList = make("ScrollingFrame", {
	Size = UDim2.new(1, -24, 1, -70),
	Position = UDim2.new(0, 12, 0, 58),
	BackgroundTransparency = 1,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 6,
}, garageFrame)
local listLayout = make("UIGridLayout", {
	CellSize = UDim2.new(0, 220, 0, 180),
	CellPadding = UDim2.new(0, 10, 0, 10),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, carList)

-- 차량 카드 UI 보관 (갱신용)
local carCards: { [string]: { update: () -> () } } = {}

local function buildCarCard(carDef: any, order: number)
	local tierInfo = GameConfig.Tiers[carDef.tier]
	local card = make("Frame", {
		BackgroundColor3 = Color3.fromRGB(32, 36, 48),
		LayoutOrder = order,
	}, carList)
	corner(10, card)
	make("UIStroke", { Color = tierInfo.color, Thickness = 2, Transparency = 0.2 }, card)

	make("TextLabel", {
		Size = UDim2.new(1, -12, 0, 24),
		Position = UDim2.new(0, 6, 0, 6),
		BackgroundTransparency = 1,
		Text = carDef.displayName,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		Font = Enum.Font.GothamBold,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, card)

	make("TextLabel", {
		Size = UDim2.new(1, -12, 0, 18),
		Position = UDim2.new(0, 6, 0, 32),
		BackgroundTransparency = 1,
		Text = "[" .. tierInfo.displayName .. "]",
		TextColor3 = tierInfo.color,
		Font = Enum.Font.GothamMedium,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, card)

	-- 스탯 표시
	local stats = carDef.stats
	make("TextLabel", {
		Size = UDim2.new(1, -12, 0, 54),
		Position = UDim2.new(0, 6, 0, 52),
		BackgroundTransparency = 1,
		Text = ("최고속 %d\n가속 %d\n핸들링 %.0f%%"):format(stats.topSpeed, stats.accel, stats.handling * 100),
		TextColor3 = Color3.fromRGB(200, 205, 215),
		Font = Enum.Font.Gotham,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, card)

	-- 액션 버튼 (보유/선택/구매)
	local actionBtn = make("TextButton", {
		Size = UDim2.new(1, -12, 0, 40),
		Position = UDim2.new(0, 6, 1, -46),
		BackgroundColor3 = Color3.fromRGB(70, 120, 200),
		Text = "...",
		TextColor3 = Color3.fromRGB(255, 255, 255),
		Font = Enum.Font.GothamBold,
		TextScaled = true,
	}, card)
	corner(8, actionBtn)
	make("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, actionBtn)

	local function update()
		if not data then
			return
		end
		local owned = data.ownedCars[carDef.id] == true
		local selected = data.selectedCar == carDef.id
		if selected then
			actionBtn.Text = "✓ 선택됨"
			actionBtn.BackgroundColor3 = Color3.fromRGB(70, 180, 90)
		elseif owned then
			actionBtn.Text = "선택하기"
			actionBtn.BackgroundColor3 = Color3.fromRGB(70, 120, 200)
		elseif carDef.currency == "Robux" then
			actionBtn.Text = "🔒 로벅스 전용"
			actionBtn.BackgroundColor3 = Color3.fromRGB(120, 90, 60)
		else
			actionBtn.Text = "💰 " .. tostring(carDef.price) .. " 구매"
			actionBtn.BackgroundColor3 = Color3.fromRGB(200, 150, 60)
		end
	end

	actionBtn.Activated:Connect(function()
		if not data then
			return
		end
		local owned = data.ownedCars[carDef.id] == true
		if owned then
			Remotes.Event("RequestSelectCar"):FireServer(carDef.id)
		elseif carDef.currency == "Robux" then
			showToast("이 차량은 로벅스 전용입니다. (현재 준비 중)")
		else
			Remotes.Event("RequestBuyCar"):FireServer(carDef.id)
		end
	end)

	carCards[carDef.id] = { update = update }
	update()
end

-- 등급 순으로 정렬해 카드 생성
do
	local sorted = table.clone(GameConfig.Cars)
	table.sort(sorted, function(a, b)
		local ao = GameConfig.Tiers[a.tier].order
		local bo = GameConfig.Tiers[b.tier].order
		if ao ~= bo then
			return ao < bo
		end
		return a.price < b.price
	end)
	for i, carDef in ipairs(sorted) do
		buildCarCard(carDef, i)
	end
end

-- 차고 안 "꾸미기" 버튼
local customizeOpenBtn = make("TextButton", {
	Size = UDim2.new(0, 160, 0, 40),
	Position = UDim2.new(0, 12, 1, -2),
	AnchorPoint = Vector2.new(0, 1),
	BackgroundColor3 = Color3.fromRGB(150, 90, 210),
	Text = "🎨 선택차 꾸미기",
	TextColor3 = Color3.fromRGB(255, 255, 255),
	Font = Enum.Font.GothamBold,
	TextScaled = true,
	Visible = false,
}, garageFrame)
corner(8, customizeOpenBtn)
make("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, customizeOpenBtn)

-- =====================================================================
-- 커스터마이징 패널 (30초 타이머)
-- =====================================================================
local customFrame = make("Frame", {
	Size = UDim2.new(0, 520, 0, 440),
	Position = UDim2.new(0.5, -260, 0.5, -220),
	BackgroundColor3 = Color3.fromRGB(22, 25, 34),
	Visible = false,
}, gui)
corner(14, customFrame)

make("TextLabel", {
	Size = UDim2.new(1, -120, 0, 44),
	Position = UDim2.new(0, 12, 0, 8),
	BackgroundTransparency = 1,
	Text = "🎨 커스터마이징",
	TextColor3 = Color3.fromRGB(255, 255, 255),
	Font = Enum.Font.GothamBold,
	TextScaled = true,
	TextXAlignment = Enum.TextXAlignment.Left,
}, customFrame)

local customTimerLabel = make("TextLabel", {
	Size = UDim2.new(0, 90, 0, 40),
	Position = UDim2.new(1, -102, 0, 10),
	BackgroundColor3 = Color3.fromRGB(200, 70, 70),
	Text = "30",
	TextColor3 = Color3.fromRGB(255, 255, 255),
	Font = Enum.Font.GothamBold,
	TextScaled = true,
}, customFrame)
corner(8, customTimerLabel)

-- 현재 편집 중인 커스텀 상태
local editState = {
	bodyColor = { 255, 255, 255 },
	wheelColor = { 20, 20, 20 },
	neonColor = { 0, 0, 0 },
	sticker = "none",
	plate = "RACER",
}

-- 색상 스와치 행 생성
local function buildSwatchRow(title: string, palette: { Color3 }, yPos: number, field: string)
	make("TextLabel", {
		Size = UDim2.new(0, 90, 0, 30),
		Position = UDim2.new(0, 14, 0, yPos),
		BackgroundTransparency = 1,
		Text = title,
		TextColor3 = Color3.fromRGB(210, 215, 225),
		Font = Enum.Font.GothamMedium,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, customFrame)

	for i, c in ipairs(palette) do
		local sw = make("TextButton", {
			Size = UDim2.new(0, 36, 0, 36),
			Position = UDim2.new(0, 110 + (i - 1) * 44, 0, yPos - 2),
			BackgroundColor3 = c,
			Text = "",
		}, customFrame)
		corner(18, sw)
		make("UIStroke", { Color = Color3.fromRGB(255, 255, 255), Thickness = 1, Transparency = 0.6 }, sw)
		sw.Activated:Connect(function()
			(editState :: any)[field] = { math.floor(c.R * 255), math.floor(c.G * 255), math.floor(c.B * 255) }
		end)
	end
end

buildSwatchRow("차체", GameConfig.Customization.bodyColors, 70, "bodyColor")
buildSwatchRow("휠", GameConfig.Customization.wheelColors, 120, "wheelColor")
buildSwatchRow("네온", GameConfig.Customization.neonColors, 170, "neonColor")

-- 스티커 선택
make("TextLabel", {
	Size = UDim2.new(0, 90, 0, 30),
	Position = UDim2.new(0, 14, 0, 220),
	BackgroundTransparency = 1,
	Text = "스티커",
	TextColor3 = Color3.fromRGB(210, 215, 225),
	Font = Enum.Font.GothamMedium,
	TextScaled = true,
	TextXAlignment = Enum.TextXAlignment.Left,
}, customFrame)
for i, s in ipairs(GameConfig.Customization.stickers) do
	local btn = make("TextButton", {
		Size = UDim2.new(0, 90, 0, 34),
		Position = UDim2.new(0, 110 + (i - 1) * 98, 0, 218),
		BackgroundColor3 = Color3.fromRGB(45, 50, 65),
		Text = s.displayName,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		Font = Enum.Font.Gotham,
		TextScaled = true,
	}, customFrame)
	corner(6, btn)
	make("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6) }, btn)
	btn.Activated:Connect(function()
		editState.sticker = s.id
	end)
end

-- 번호판 입력
make("TextLabel", {
	Size = UDim2.new(0, 90, 0, 30),
	Position = UDim2.new(0, 14, 0, 270),
	BackgroundTransparency = 1,
	Text = "번호판",
	TextColor3 = Color3.fromRGB(210, 215, 225),
	Font = Enum.Font.GothamMedium,
	TextScaled = true,
	TextXAlignment = Enum.TextXAlignment.Left,
}, customFrame)
local plateBox = make("TextBox", {
	Size = UDim2.new(0, 200, 0, 34),
	Position = UDim2.new(0, 110, 0, 268),
	BackgroundColor3 = Color3.fromRGB(245, 245, 245),
	Text = "RACER",
	PlaceholderText = "최대 8자",
	TextColor3 = Color3.fromRGB(20, 20, 20),
	Font = Enum.Font.GothamBold,
	TextScaled = true,
	ClearTextOnFocus = false,
}, customFrame)
corner(6, plateBox)
plateBox.FocusLost:Connect(function()
	local cleaned = string.gsub(plateBox.Text, "[^%w%s]", "")
	cleaned = string.sub(cleaned, 1, 8)
	plateBox.Text = cleaned
	editState.plate = cleaned ~= "" and cleaned or "RACER"
end)

-- 저장/닫기 버튼
local saveBtn = make("TextButton", {
	Size = UDim2.new(0, 200, 0, 44),
	Position = UDim2.new(0.5, -210, 1, -56),
	BackgroundColor3 = Color3.fromRGB(70, 180, 90),
	Text = "💾 저장",
	TextColor3 = Color3.fromRGB(255, 255, 255),
	Font = Enum.Font.GothamBold,
	TextScaled = true,
}, customFrame)
corner(8, saveBtn)
local customCloseBtn = make("TextButton", {
	Size = UDim2.new(0, 200, 0, 44),
	Position = UDim2.new(0.5, 10, 1, -56),
	BackgroundColor3 = Color3.fromRGB(90, 95, 110),
	Text = "닫기",
	TextColor3 = Color3.fromRGB(255, 255, 255),
	Font = Enum.Font.GothamBold,
	TextScaled = true,
}, customFrame)
corner(8, customCloseBtn)

-- 커스터마이징 타이머 상태
local customTimerThread: thread? = nil

local function sendCustomization()
	Remotes.Event("RequestSaveCustomization"):FireServer({
		bodyColor = editState.bodyColor,
		wheelColor = editState.wheelColor,
		neonColor = editState.neonColor,
		sticker = editState.sticker,
		plate = editState.plate,
	})
end

local function closeCustomize(save: boolean)
	if customTimerThread then
		task.cancel(customTimerThread)
		customTimerThread = nil
	end
	if save then
		sendCustomization()
	end
	customFrame.Visible = false
end

local function openCustomize()
	if not data then
		return
	end
	-- 현재 선택 차량의 기존 커스텀 불러오기
	local carId = data.selectedCar
	local existing = data.customizations[carId]
	local carDef = GameConfig.CarsById[carId]
	if existing then
		editState.bodyColor = existing.bodyColor or editState.bodyColor
		editState.wheelColor = existing.wheelColor or editState.wheelColor
		editState.neonColor = existing.neonColor or editState.neonColor
		editState.sticker = existing.sticker or "none"
		editState.plate = existing.plate or "RACER"
	elseif carDef then
		editState.bodyColor = { math.floor(carDef.defaultColor.R * 255), math.floor(carDef.defaultColor.G * 255), math.floor(carDef.defaultColor.B * 255) }
		editState.wheelColor = { 20, 20, 20 }
		editState.neonColor = { 0, 0, 0 }
		editState.sticker = "none"
		editState.plate = "RACER"
	end
	plateBox.Text = editState.plate

	garageFrame.Visible = false
	customFrame.Visible = true

	-- 30초 카운트다운 → 자동 저장 후 닫힘
	if customTimerThread then
		task.cancel(customTimerThread)
	end
	customTimerThread = task.spawn(function()
		local remaining = GameConfig.Customization.timeLimit
		while remaining > 0 and customFrame.Visible do
			customTimerLabel.Text = tostring(remaining)
			task.wait(1)
			remaining -= 1
		end
		if customFrame.Visible then
			showToast("커스터마이징 시간 종료 — 자동 저장")
			closeCustomize(true)
		end
	end)
end

customizeOpenBtn.Activated:Connect(openCustomize)
saveBtn.Activated:Connect(function()
	closeCustomize(true)
end)
customCloseBtn.Activated:Connect(function()
	closeCustomize(false)
end)

-- =====================================================================
-- 대기열 상태 표시
-- =====================================================================
local queueStatus = make("TextLabel", {
	Size = UDim2.new(0, 280, 0, 40),
	Position = UDim2.new(1, -296, 0, 140),
	BackgroundColor3 = Color3.fromRGB(25, 28, 38),
	BackgroundTransparency = 0.15,
	Text = "",
	TextColor3 = Color3.fromRGB(255, 255, 255),
	Font = Enum.Font.GothamMedium,
	TextScaled = true,
	Visible = false,
}, gui)
corner(8, queueStatus)
make("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, queueStatus)

local inQueue = false

-- =====================================================================
-- 경주 HUD (시작 카운트다운 / 랩 / 결과)
-- =====================================================================
local bigText = make("TextLabel", {
	Size = UDim2.new(0, 400, 0, 200),
	Position = UDim2.new(0.5, -200, 0.4, -100),
	BackgroundTransparency = 1,
	Text = "",
	TextColor3 = Color3.fromRGB(255, 255, 255),
	TextStrokeTransparency = 0.3,
	Font = Enum.Font.GothamBlack,
	TextScaled = true,
	Visible = false,
}, gui)

local function flashBig(text: string)
	bigText.Text = text
	bigText.Visible = true
	bigText.TextTransparency = 0
	bigText.Size = UDim2.new(0, 300, 0, 150)
	bigText.Position = UDim2.new(0.5, -150, 0.4, -75)
	TweenService:Create(bigText, TweenInfo.new(0.6), {
		Size = UDim2.new(0, 460, 0, 230),
		Position = UDim2.new(0.5, -230, 0.4, -115),
	}):Play()
	task.delay(0.9, function()
		if bigText.Text == text then
			bigText.Visible = false
		end
	end)
end

-- 결과 화면
local resultFrame = make("Frame", {
	Size = UDim2.new(0, 420, 0, 400),
	Position = UDim2.new(0.5, -210, 0.5, -200),
	BackgroundColor3 = Color3.fromRGB(22, 25, 34),
	Visible = false,
}, gui)
corner(14, resultFrame)
make("TextLabel", {
	Size = UDim2.new(1, 0, 0, 50),
	BackgroundTransparency = 1,
	Text = "🏆 경주 결과",
	TextColor3 = Color3.fromRGB(245, 220, 90),
	Font = Enum.Font.GothamBold,
	TextScaled = true,
}, resultFrame)
local resultList = make("ScrollingFrame", {
	Size = UDim2.new(1, -24, 1, -64),
	Position = UDim2.new(0, 12, 0, 56),
	BackgroundTransparency = 1,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 5,
}, resultFrame)
make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, resultList)

local function showResults(results: { any })
	for _, child in ipairs(resultList:GetChildren()) do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	for i, r in ipairs(results) do
		local placeText = r.place and (tostring(r.place) .. "등") or "미완주"
		local timeText = r.time and (" · %.1f초"):format(r.time) or ""
		make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 40),
			BackgroundColor3 = Color3.fromRGB(34, 38, 50),
			Text = ("%s   %s%s"):format(placeText, r.name, timeText),
			TextColor3 = i <= 3 and Color3.fromRGB(245, 220, 90) or Color3.fromRGB(220, 225, 235),
			Font = Enum.Font.GothamMedium,
			TextScaled = true,
			LayoutOrder = r.place or 999,
		}, resultList)
	end
	resultFrame.Visible = true
	task.delay(5, function()
		resultFrame.Visible = false
	end)
end

-- =====================================================================
-- 버튼/이벤트 연결
-- =====================================================================
garageBtn.Activated:Connect(function()
	garageFrame.Visible = not garageFrame.Visible
	customizeOpenBtn.Visible = garageFrame.Visible
	if garageFrame.Visible then
		customFrame.Visible = false
	end
end)
garageClose.Activated:Connect(function()
	garageFrame.Visible = false
	customizeOpenBtn.Visible = false
end)

local function setQueueButton(joined: boolean)
	inQueue = joined
	if joined then
		queueBtn.Text = "❌ 대기열 나가기"
		queueBtn.BackgroundColor3 = Color3.fromRGB(200, 90, 70)
	else
		queueBtn.Text = "🏁 경주 참가"
		queueBtn.BackgroundColor3 = Color3.fromRGB(70, 180, 90)
	end
end

queueBtn.Activated:Connect(function()
	if inQueue then
		Remotes.Event("RequestLeaveQueue"):FireServer()
		setQueueButton(false)
	else
		Remotes.Event("RequestJoinQueue"):FireServer()
		setQueueButton(true)
	end
end)

-- =====================================================================
-- 데이터/상태 수신
-- =====================================================================
local function refreshUI()
	if not data then
		return
	end
	moneyLabel.Text = "💰 " .. tostring(data.money)
	for _, card in pairs(carCards) do
		card.update()
	end
end

Remotes.Event("PlayerDataUpdated").OnClientEvent:Connect(function(newData)
	data = newData
	refreshUI()
end)

Remotes.Event("Notify").OnClientEvent:Connect(function(message)
	showToast(message)
end)

Remotes.Event("QueueStateChanged").OnClientEvent:Connect(function(info)
	if info.state == "Countdown" and info.countdown then
		queueStatus.Visible = true
		queueStatus.Text = ("⏱ 시작까지 %d초 (%d/%d)"):format(info.countdown, info.count, info.max)
	elseif info.count and info.count > 0 then
		queueStatus.Visible = true
		queueStatus.Text = ("🏁 대기 중 %d/%d명"):format(info.count, info.max)
	else
		queueStatus.Visible = false
	end
end)

-- 경주 상태 변화: 경주 시작 시 대기열 상태/패널 정리
Remotes.Event("RaceStateChanged").OnClientEvent:Connect(function(info)
	if info.state == "Racing" then
		inQueue = false
		queueBtn.Text = "🏁 경주 중"
		queueBtn.BackgroundColor3 = Color3.fromRGB(120, 120, 130)
		queueBtn.AutoButtonColor = false
		garageFrame.Visible = false
		customFrame.Visible = false
		customizeOpenBtn.Visible = false
	else
		queueBtn.AutoButtonColor = true
		setQueueButton(false)
		queueStatus.Visible = false
	end
end)

Remotes.Event("RaceCountdown").OnClientEvent:Connect(function(info)
	if info.value and info.value > 0 then
		flashBig(tostring(info.value))
	else
		flashBig("GO!")
	end
end)

Remotes.Event("RaceFinished").OnClientEvent:Connect(function(info)
	if info.results then
		showResults(info.results)
	end
end)

-- =====================================================================
-- 초기 데이터 요청
-- =====================================================================
task.spawn(function()
	local ok, result = pcall(function()
		return Remotes.Function("GetPlayerData"):InvokeServer()
	end)
	if ok and result then
		data = result
		refreshUI()
	end
end)

print("[Client] 자동차 경주 게임 UI 초기화 완료 🏎️")
