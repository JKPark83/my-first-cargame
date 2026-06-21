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
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

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

-- =====================================================================
-- 로딩 오버레이 (경주 진입 / 차고 준비)
--   별도 ScreenGui(높은 DisplayOrder)로 다른 모든 UI 위에 덮어 표시.
--   CanvasGroup의 GroupTransparency로 카드+배경을 한 번에 페이드.
-- =====================================================================
local loadingGui = make("ScreenGui", {
	Name = "LoadingUI",
	ResetOnSpawn = false,
	DisplayOrder = 100,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, playerGui)

local loadingRoot = make("CanvasGroup", {
	Name = "Overlay",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.fromRGB(10, 12, 18),
	BackgroundTransparency = 0,
	GroupTransparency = 0,
	BorderSizePixel = 0,
	Visible = false,
	ZIndex = 1,
}, loadingGui)

local loadingCard = make("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.new(0, 440, 0, 170),
	BackgroundTransparency = 1,
}, loadingRoot)

local loadingTitle = make("TextLabel", {
	Size = UDim2.new(1, 0, 0, 56),
	BackgroundTransparency = 1,
	Text = "🏁 트랙 생성 중...",
	TextColor3 = Color3.fromRGB(245, 246, 250),
	Font = Enum.Font.GothamBold,
	TextScaled = true,
}, loadingCard)

local loadingSub = make("TextLabel", {
	Size = UDim2.new(1, 0, 0, 30),
	Position = UDim2.new(0, 0, 0, 64),
	BackgroundTransparency = 1,
	Text = "잠시만 기다려 주세요",
	TextColor3 = Color3.fromRGB(150, 156, 170),
	Font = Enum.Font.Gotham,
	TextScaled = true,
}, loadingCard)

-- 불확정 진행 바: 좌우로 왕복하는 스윕
local loadingBarBg = make("Frame", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 120),
	Size = UDim2.new(0, 380, 0, 8),
	BackgroundColor3 = Color3.fromRGB(35, 39, 50),
	BorderSizePixel = 0,
	ClipsDescendants = true,
}, loadingCard)
corner(4, loadingBarBg)
local loadingBarFill = make("Frame", {
	Size = UDim2.new(0.32, 0, 1, 0),
	BackgroundColor3 = Color3.fromRGB(90, 170, 255),
	BorderSizePixel = 0,
}, loadingBarBg)
corner(4, loadingBarFill)

local loadingTween: Tween? = nil
local loadingFade: Tween? = nil

local function showLoading(title: string?, subtitle: string?)
	loadingTitle.Text = title or "🏁 트랙 생성 중..."
	loadingSub.Text = subtitle or "잠시만 기다려 주세요"
	if loadingFade then
		loadingFade:Cancel()
		loadingFade = nil
	end
	loadingRoot.GroupTransparency = 0
	loadingRoot.Visible = true
	-- 스윕 시작(중복 방지)
	if not loadingTween then
		loadingBarFill.Position = UDim2.new(0, 0, 0, 0)
		local t = TweenService:Create(
			loadingBarFill,
			TweenInfo.new(0.85, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, true),
			{ Position = UDim2.new(0.68, 0, 0, 0) }
		)
		loadingTween = t
		t:Play()
	end
end

local function hideLoading()
	if not loadingRoot.Visible then
		return
	end
	if loadingTween then
		loadingTween:Cancel()
		loadingTween = nil
	end
	if loadingFade then
		loadingFade:Cancel()
	end
	local fade = TweenService:Create(loadingRoot, TweenInfo.new(0.35, Enum.EasingStyle.Quad), {
		GroupTransparency = 1,
	})
	loadingFade = fade
	fade.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed then
			loadingRoot.Visible = false
		end
	end)
	fade:Play()
end

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
	CellSize = UDim2.new(0, 220, 0, 270),
	CellPadding = UDim2.new(0, 10, 0, 10),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, carList)

-- 차량 카드 UI 보관 (갱신용)
local carCards: { [string]: { update: () -> () } } = {}

-- 서버가 ReplicatedStorage.CarPreviews에 준비한 3D 차량 모델(차고 미리보기용)
local carPreviewsFolder: Instance? = ReplicatedStorage:WaitForChild("CarPreviews", 8)

-- 카드 상단에 차량 3D 미리보기(ViewportFrame)를 만든다 → 어떤 차인지 한눈에 보이게.
local function buildCarViewport(parent: Instance, carId: string)
	local vp = make("ViewportFrame", {
		Size = UDim2.new(1, -12, 0, 96),
		Position = UDim2.new(0, 6, 0, 6),
		BackgroundColor3 = Color3.fromRGB(16, 18, 26),
		Ambient = Color3.fromRGB(175, 177, 185),
		LightColor = Color3.fromRGB(255, 255, 255),
		LightDirection = Vector3.new(-1, -1.4, -0.7),
	}, parent)
	corner(8, vp)

	local src = carPreviewsFolder and carPreviewsFolder:FindFirstChild(carId)
	if not src then
		return -- 미리보기 모델이 아직 없으면 빈 화면만(크래시 방지)
	end
	local model = (src :: Instance):Clone()
	model.Parent = vp

	local cam = Instance.new("Camera")
	cam.Parent = vp
	vp.CurrentCamera = cam

	local cf, size = (model :: Model):GetBoundingBox()
	local center = cf.Position
	local radius = math.max(size.X, size.Y, size.Z)
	-- 전진=-Z. 앞·오른쪽·위에서 내려다보는 3/4 앵글로 차 실루엣이 잘 보이게.
	local dir = Vector3.new(0.75, 0.5, -1).Unit
	local dist = radius * 1.15 + 4
	cam.FieldOfView = 55
	cam.CFrame = CFrame.lookAt(center + dir * dist, center)
end

local function buildCarCard(carDef: any, order: number)
	local tierInfo = GameConfig.Tiers[carDef.tier]
	local card = make("Frame", {
		BackgroundColor3 = Color3.fromRGB(32, 36, 48),
		LayoutOrder = order,
	}, carList)
	corner(10, card)
	make("UIStroke", { Color = tierInfo.color, Thickness = 2, Transparency = 0.2 }, card)

	-- 차량 3D 미리보기(상단)
	buildCarViewport(card, carDef.id)

	make("TextLabel", {
		Size = UDim2.new(1, -12, 0, 24),
		Position = UDim2.new(0, 6, 0, 108),
		BackgroundTransparency = 1,
		Text = carDef.displayName,
		TextColor3 = Color3.fromRGB(255, 255, 255),
		Font = Enum.Font.GothamBold,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, card)

	make("TextLabel", {
		Size = UDim2.new(1, -12, 0, 18),
		Position = UDim2.new(0, 6, 0, 134),
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
		Position = UDim2.new(0, 6, 0, 154),
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
	Size = UDim2.new(0, 540, 0, 588),
	Position = UDim2.new(0.5, -270, 0.5, -294),
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
	name = "박서우차",
}

-- 색상 스와치 행 생성 (휠/네온 프리셋)
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
			Size = UDim2.new(0, 34, 0, 34),
			Position = UDim2.new(0, 104 + (i - 1) * 42, 0, yPos - 2),
			BackgroundColor3 = c,
			Text = "",
		}, customFrame)
		corner(17, sw)
		make("UIStroke", { Color = Color3.fromRGB(255, 255, 255), Thickness = 1, Transparency = 0.6 }, sw)
		sw.Activated:Connect(function()
			(editState :: any)[field] = { math.floor(c.R * 255), math.floor(c.G * 255), math.floor(c.B * 255) }
		end)
	end
end

-- =====================================================================
-- 차체 자유 색상 선택기: 무지개(색상) 막대 + 밝기 막대 + 실시간 미리보기
--   HSV 모델로 색상(Hue)·밝기(Value)를 자유롭게 조절해 임의 RGB를 만든다.
-- =====================================================================
make("TextLabel", {
	Size = UDim2.new(0, 300, 0, 24),
	Position = UDim2.new(0, 16, 0, 58),
	BackgroundTransparency = 1,
	Text = "차체 색상 🎨 (무지개 + 밝기)",
	TextColor3 = Color3.fromRGB(210, 215, 225),
	Font = Enum.Font.GothamMedium,
	TextScaled = true,
	TextXAlignment = Enum.TextXAlignment.Left,
}, customFrame)

-- 무지개(색상) 막대
local hueBar = make("Frame", {
	Size = UDim2.new(0, 358, 0, 26),
	Position = UDim2.new(0, 16, 0, 88),
	BackgroundColor3 = Color3.fromRGB(255, 255, 255),
	BorderSizePixel = 0,
	Active = true,
}, customFrame)
corner(6, hueBar)
make("UIGradient", {
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0.0, Color3.fromHSV(0.0, 1, 1)),
		ColorSequenceKeypoint.new(0.1667, Color3.fromHSV(0.1667, 1, 1)),
		ColorSequenceKeypoint.new(0.3333, Color3.fromHSV(0.3333, 1, 1)),
		ColorSequenceKeypoint.new(0.5, Color3.fromHSV(0.5, 1, 1)),
		ColorSequenceKeypoint.new(0.6667, Color3.fromHSV(0.6667, 1, 1)),
		ColorSequenceKeypoint.new(0.8333, Color3.fromHSV(0.8333, 1, 1)),
		ColorSequenceKeypoint.new(1.0, Color3.fromHSV(1.0, 1, 1)),
	}),
}, hueBar)
local hueSelector = make("Frame", {
	Size = UDim2.new(0, 4, 1, 6),
	Position = UDim2.new(0, 0, 0, 0),
	AnchorPoint = Vector2.new(0.5, 0),
	BackgroundColor3 = Color3.fromRGB(255, 255, 255),
	BorderSizePixel = 0,
	ZIndex = 3,
}, hueBar)
make("UIStroke", { Color = Color3.fromRGB(20, 20, 20), Thickness = 1.5 }, hueSelector)

-- 밝기 막대 (검정 → 현재 색상)
local valBar = make("Frame", {
	Size = UDim2.new(0, 358, 0, 20),
	Position = UDim2.new(0, 16, 0, 122),
	BackgroundColor3 = Color3.fromRGB(255, 255, 255),
	BorderSizePixel = 0,
	Active = true,
}, customFrame)
corner(6, valBar)
local valGradient = make("UIGradient", {
	Color = ColorSequence.new(Color3.fromRGB(0, 0, 0), Color3.fromHSV(0, 1, 1)),
}, valBar)
local valSelector = make("Frame", {
	Size = UDim2.new(0, 4, 1, 6),
	Position = UDim2.new(1, 0, 0, 0),
	AnchorPoint = Vector2.new(0.5, 0),
	BackgroundColor3 = Color3.fromRGB(255, 255, 255),
	BorderSizePixel = 0,
	ZIndex = 3,
}, valBar)
make("UIStroke", { Color = Color3.fromRGB(20, 20, 20), Thickness = 1.5 }, valSelector)

-- 실시간 미리보기 스와치
local bodyPreview = make("Frame", {
	Size = UDim2.new(0, 128, 0, 56),
	Position = UDim2.new(0, 386, 0, 88),
	BackgroundColor3 = Color3.fromRGB(255, 255, 255),
	BorderSizePixel = 0,
}, customFrame)
corner(10, bodyPreview)
make("UIStroke", { Color = Color3.fromRGB(255, 255, 255), Thickness = 1.5, Transparency = 0.4 }, bodyPreview)
make("TextLabel", {
	Size = UDim2.new(0, 128, 0, 16),
	Position = UDim2.new(0, 386, 0, 146),
	BackgroundTransparency = 1,
	Text = "미리보기",
	TextColor3 = Color3.fromRGB(150, 156, 170),
	Font = Enum.Font.Gotham,
	TextScaled = true,
}, customFrame)

-- 색상 상태 (Hue 0~1, Value 0~1; 채도는 선명하게 1 고정)
local bodyHue = 0
local bodyVal = 1

-- 미리보기/선택자 위치 갱신 (editState.bodyColor는 건드리지 않음 → 불러오기 시 원색 유지)
local function refreshBodyPreview()
	bodyPreview.BackgroundColor3 = color3FromArray(editState.bodyColor, Color3.fromRGB(255, 255, 255))
	hueSelector.Position = UDim2.new(bodyHue, 0, 0, -3)
	valSelector.Position = UDim2.new(bodyVal, 0, 0, -3)
	valGradient.Color = ColorSequence.new(Color3.fromRGB(0, 0, 0), Color3.fromHSV(bodyHue, 1, 1))
end

-- 막대 조작 시: 현재 Hue/Value로 차체 색을 새로 만든다
local function setBodyFromPicker()
	local c = Color3.fromHSV(bodyHue, 1, bodyVal)
	editState.bodyColor = {
		math.floor(c.R * 255 + 0.5),
		math.floor(c.G * 255 + 0.5),
		math.floor(c.B * 255 + 0.5),
	}
	bodyPreview.BackgroundColor3 = c
	hueSelector.Position = UDim2.new(bodyHue, 0, 0, -3)
	valSelector.Position = UDim2.new(bodyVal, 0, 0, -3)
	valGradient.Color = ColorSequence.new(Color3.fromRGB(0, 0, 0), Color3.fromHSV(bodyHue, 1, 1))
end

-- 가로 슬라이더: 막대를 클릭/드래그하면 0~1 비율을 onChange로 전달
local function attachHorizontalSlider(bar: GuiObject, onChange: (number) -> ())
	local dragging = false
	local function update(px: number)
		local rel = (px - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1)
		onChange(math.clamp(rel, 0, 1))
	end
	bar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			update(input.Position.X)
		end
	end)
	bar.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			update(input.Position.X)
		end
	end)
end

attachHorizontalSlider(hueBar, function(t)
	bodyHue = t
	setBodyFromPicker()
end)
attachHorizontalSlider(valBar, function(t)
	bodyVal = t
	setBodyFromPicker()
end)

buildSwatchRow("휠", GameConfig.Customization.wheelColors, 174, "wheelColor")
buildSwatchRow("네온", GameConfig.Customization.neonColors, 218, "neonColor")

-- 스티커 선택
make("TextLabel", {
	Size = UDim2.new(0, 90, 0, 30),
	Position = UDim2.new(0, 14, 0, 264),
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
		Position = UDim2.new(0, 110 + (i - 1) * 98, 0, 262),
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

-- 차 이름 입력 (차량 위 이름표, 기본값 "박서우차")
make("TextLabel", {
	Size = UDim2.new(0, 90, 0, 30),
	Position = UDim2.new(0, 14, 0, 314),
	BackgroundTransparency = 1,
	Text = "차 이름",
	TextColor3 = Color3.fromRGB(210, 215, 225),
	Font = Enum.Font.GothamMedium,
	TextScaled = true,
	TextXAlignment = Enum.TextXAlignment.Left,
}, customFrame)
local nameBox = make("TextBox", {
	Size = UDim2.new(0, 280, 0, 34),
	Position = UDim2.new(0, 110, 0, 312),
	BackgroundColor3 = Color3.fromRGB(245, 245, 245),
	Text = "박서우차",
	PlaceholderText = "박서우차",
	TextColor3 = Color3.fromRGB(20, 20, 20),
	Font = Enum.Font.GothamBold,
	TextScaled = true,
	ClearTextOnFocus = false,
}, customFrame)
corner(6, nameBox)
nameBox.FocusLost:Connect(function()
	local cleaned = string.gsub(nameBox.Text, "%c", "")
	cleaned = string.match(cleaned, "^%s*(.-)%s*$") or ""
	if cleaned == "" then
		cleaned = "박서우차"
	end
	nameBox.Text = cleaned
	editState.name = cleaned
end)

-- 번호판 입력
make("TextLabel", {
	Size = UDim2.new(0, 90, 0, 30),
	Position = UDim2.new(0, 14, 0, 358),
	BackgroundTransparency = 1,
	Text = "번호판",
	TextColor3 = Color3.fromRGB(210, 215, 225),
	Font = Enum.Font.GothamMedium,
	TextScaled = true,
	TextXAlignment = Enum.TextXAlignment.Left,
}, customFrame)
local plateBox = make("TextBox", {
	Size = UDim2.new(0, 200, 0, 34),
	Position = UDim2.new(0, 110, 0, 356),
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
		name = editState.name,
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
		editState.name = (type(existing.name) == "string" and existing.name ~= "") and existing.name or "박서우차"
	elseif carDef then
		editState.bodyColor = { math.floor(carDef.defaultColor.R * 255), math.floor(carDef.defaultColor.G * 255), math.floor(carDef.defaultColor.B * 255) }
		editState.wheelColor = { 20, 20, 20 }
		editState.neonColor = { 0, 0, 0 }
		editState.sticker = "none"
		editState.plate = "RACER"
		editState.name = "박서우차"
	end
	plateBox.Text = editState.plate
	nameBox.Text = editState.name

	-- 색상 막대를 현재 차체색 기준으로 초기화 (원색 유지: editState.bodyColor는 변경하지 않음)
	local bc = color3FromArray(editState.bodyColor, Color3.fromRGB(255, 255, 255))
	local h, _, v = bc:ToHSV()
	bodyHue = h
	bodyVal = v
	refreshBodyPreview()

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
	Position = UDim2.new(1, -296, 0, 208),
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
			Text = ("%s   %s%s%s"):format(placeText, r.isBot and "🤖 " or "", r.name, timeText),
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
-- 미니맵 (트랙 외곽선 + 차량 점)
-- =====================================================================
local MINIMAP_SIZE = 220
local minimap = make("Frame", {
	Size = UDim2.new(0, MINIMAP_SIZE, 0, MINIMAP_SIZE),
	Position = UDim2.new(0, 16, 1, -MINIMAP_SIZE - 16),
	BackgroundColor3 = Color3.fromRGB(15, 18, 26),
	BackgroundTransparency = 0.2,
	Visible = false,
}, gui)
corner(10, minimap)
make("UIStroke", { Color = Color3.fromRGB(80, 90, 110), Thickness = 2 }, minimap)

local minimapInner = make("Frame", {
	Size = UDim2.new(1, -16, 1, -16),
	Position = UDim2.new(0, 8, 0, 8),
	BackgroundTransparency = 1,
}, minimap)

-- 월드 좌표 → 미니맵 로컬 비율 변환 상태
local mapBounds: any = nil
local outlineDots: { Frame } = {}
local carDots: { [number]: Frame } = {}

local function worldToMap(x: number, z: number): (number, number)
	if not mapBounds then
		return 0.5, 0.5
	end
	local spanX = math.max(mapBounds.maxX - mapBounds.minX, 1)
	local spanZ = math.max(mapBounds.maxZ - mapBounds.minZ, 1)
	-- 여백 10%
	local u = 0.1 + 0.8 * ((x - mapBounds.minX) / spanX)
	local v = 0.1 + 0.8 * ((z - mapBounds.minZ) / spanZ)
	return u, v
end

local function buildMinimapOutline(path: { any }, bounds: any)
	mapBounds = bounds
	for _, d in ipairs(outlineDots) do
		d:Destroy()
	end
	table.clear(outlineDots)
	for _, p in ipairs(path) do
		local u, v = worldToMap(p.x, p.z)
		local dot = make("Frame", {
			Size = UDim2.new(0, 4, 0, 4),
			Position = UDim2.new(u, -2, v, -2),
			BackgroundColor3 = Color3.fromRGB(90, 100, 120),
			BorderSizePixel = 0,
		}, minimapInner)
		corner(2, dot)
		outlineDots[#outlineDots + 1] = dot
	end
end

local function clearMinimap()
	for _, d in ipairs(outlineDots) do
		d:Destroy()
	end
	table.clear(outlineDots)
	for _, d in pairs(carDots) do
		d:Destroy()
	end
	table.clear(carDots)
	mapBounds = nil
end

local function updateMinimapCars(racers: { any })
	-- 사라진 차량 점 정리
	local present: { [number]: boolean } = {}
	for _, r in ipairs(racers) do
		present[r.userId] = true
		local dot = carDots[r.userId]
		if not dot then
			local isMe = r.userId == player.UserId
			dot = make("Frame", {
				Size = UDim2.new(0, isMe and 12 or 9, 0, isMe and 12 or 9),
				BackgroundColor3 = isMe and Color3.fromRGB(90, 230, 120) or Color3.fromRGB(235, 90, 90),
				BorderSizePixel = 0,
				ZIndex = isMe and 5 or 4,
			}, minimapInner)
			corner(6, dot)
			if isMe then
				make("UIStroke", { Color = Color3.fromRGB(255, 255, 255), Thickness = 1.5 }, dot)
			end
			carDots[r.userId] = dot
		end
		local u, v = worldToMap(r.x, r.z)
		local sz = dot.Size.X.Offset
		dot.Position = UDim2.new(u, -sz / 2, v, -sz / 2)
	end
	for userId, dot in pairs(carDots) do
		if not present[userId] then
			dot:Destroy()
			carDots[userId] = nil
		end
	end
end

-- =====================================================================
-- 실시간 순위 HUD
-- =====================================================================
local rankHud = make("Frame", {
	Size = UDim2.new(0, 248, 0, 270),
	Position = UDim2.new(1, -264, 0, 176),
	BackgroundColor3 = Color3.fromRGB(15, 18, 26),
	BackgroundTransparency = 0.25,
	Visible = false,
}, gui)
corner(10, rankHud)
-- ① 내 순위 (크게) — "내 순위 N / 총원"
local placeLabel = make("TextLabel", {
	Size = UDim2.new(1, 0, 0, 44),
	BackgroundColor3 = Color3.fromRGB(40, 150, 90),
	Text = "내 순위 - / -",
	TextColor3 = Color3.fromRGB(255, 255, 255),
	Font = Enum.Font.GothamBlack,
	TextScaled = true,
}, rankHud)
corner(10, placeLabel)
-- ② 남은 바퀴 + 현재 랩
local lapLabel = make("TextLabel", {
	Size = UDim2.new(1, 0, 0, 32),
	Position = UDim2.new(0, 0, 0, 46),
	BackgroundColor3 = Color3.fromRGB(40, 110, 200),
	Text = "LAP 1/2",
	TextColor3 = Color3.fromRGB(255, 255, 255),
	Font = Enum.Font.GothamBold,
	TextScaled = true,
}, rankHud)
corner(10, lapLabel)
local rankList = make("Frame", {
	Size = UDim2.new(1, -12, 1, -88),
	Position = UDim2.new(0, 6, 0, 84),
	BackgroundTransparency = 1,
}, rankHud)
make("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, rankList)

local function updateRankHud(racers: { any }, totalLaps: number)
	for _, c in ipairs(rankList:GetChildren()) do
		if c:IsA("TextLabel") then
			c:Destroy()
		end
	end
	local totalPlayers = #racers
	for i, r in ipairs(racers) do
		local isMe = r.userId == player.UserId
		if isMe then
			-- 내 순위 (예: "내 순위 2 / 6")
			placeLabel.Text = r.finished and "🏁 완주!" or ("내 순위 %d / %d"):format(i, totalPlayers)
			placeLabel.BackgroundColor3 = r.finished and Color3.fromRGB(210, 160, 30)
				or (i == 1 and Color3.fromRGB(40, 150, 90) or Color3.fromRGB(48, 70, 110))
			-- 남은 바퀴 (현재 r.lap 진행 중, 총 totalLaps 바퀴)
			if r.finished then
				lapLabel.Text = "완주 완료!"
			else
				local remaining = math.max(0, totalLaps - r.lap)
				if remaining <= 0 then
					lapLabel.Text = ("🏁 마지막 바퀴! (LAP %d/%d)"):format(r.lap, totalLaps)
				else
					lapLabel.Text = ("%d바퀴 남음  (LAP %d/%d)"):format(remaining, r.lap, totalLaps)
				end
			end
		end
		make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 24),
			BackgroundColor3 = isMe and Color3.fromRGB(50, 110, 70) or Color3.fromRGB(34, 38, 50),
			BackgroundTransparency = 0.1,
			Text = ("%d. %s%s"):format(i, r.isBot and "🤖" or "", string.sub(r.name, 1, 12)),
			TextColor3 = Color3.fromRGB(240, 245, 255),
			Font = isMe and Enum.Font.GothamBold or Enum.Font.Gotham,
			TextScaled = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = i,
		}, rankList)
	end
end

-- =====================================================================
-- 🏁 포디움(1·2·3등) — 화면 우상단, 현재 상위 3명의 캐릭터(아바타)를 표시
-- =====================================================================
local MEDALS = { "🥇", "🥈", "🥉" }
local thumbCache: { [number]: string } = {}

-- 사람 플레이어의 얼굴 썸네일을 비동기로 요청해 캐시 (봇/음수 id는 제외)
local function requestHeadshot(userId: number)
	if thumbCache[userId] or userId <= 0 then
		return -- 이미 요청/캐시됨(빈 문자열 플레이스홀더 포함) 또는 봇
	end
	thumbCache[userId] = "" -- 중복 요청 방지용 플레이스홀더
	task.spawn(function()
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(
				userId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size150x150
			)
		end)
		if ok and content then
			thumbCache[userId] = content
		end
	end)
end

local podium = make("Frame", {
	Size = UDim2.new(0, 248, 0, 116),
	Position = UDim2.new(1, -264, 0, 8),
	BackgroundColor3 = Color3.fromRGB(15, 18, 26),
	BackgroundTransparency = 0.25,
	Visible = false,
}, gui)
corner(12, podium)
make("TextLabel", {
	Size = UDim2.new(1, 0, 0, 18),
	BackgroundTransparency = 1,
	Text = "🏁 현재 순위 TOP 3",
	TextColor3 = Color3.fromRGB(255, 226, 120),
	Font = Enum.Font.GothamBold,
	TextScaled = true,
}, podium)

local PODIUM_CELL_W = 76
local podiumCells: { any } = {}
for i = 1, 3 do
	local cell = make("Frame", {
		Size = UDim2.new(0, PODIUM_CELL_W, 0, 90),
		Position = UDim2.new(0, 8 + (i - 1) * (PODIUM_CELL_W + 2), 0, 22),
		BackgroundColor3 = Color3.fromRGB(34, 38, 50),
		BackgroundTransparency = 0.2,
	}, podium)
	corner(8, cell)
	make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 18),
		Position = UDim2.new(0, 0, 0, 2),
		BackgroundTransparency = 1,
		Text = MEDALS[i],
		Font = Enum.Font.GothamBold,
		TextScaled = true,
	}, cell)
	local avatar = make("ImageLabel", {
		Size = UDim2.new(0, 46, 0, 46),
		Position = UDim2.new(0.5, -23, 0, 22),
		BackgroundColor3 = Color3.fromRGB(20, 22, 30),
		BackgroundTransparency = 0.2,
		Image = "",
		ScaleType = Enum.ScaleType.Fit,
	}, cell)
	corner(23, avatar)
	local emoji = make("TextLabel", {
		Size = UDim2.new(0, 46, 0, 46),
		Position = UDim2.new(0.5, -23, 0, 22),
		BackgroundTransparency = 1,
		Text = "🤖",
		Font = Enum.Font.GothamBold,
		TextScaled = true,
		Visible = false,
	}, cell)
	local nameL = make("TextLabel", {
		Size = UDim2.new(1, -4, 0, 18),
		Position = UDim2.new(0, 2, 1, -20),
		BackgroundTransparency = 1,
		Text = "-",
		TextColor3 = Color3.fromRGB(240, 245, 255),
		Font = Enum.Font.Gotham,
		TextScaled = true,
	}, cell)
	podiumCells[i] = { cell = cell, avatar = avatar, emoji = emoji, name = nameL }
end

-- 서버가 보낸 ranked racers(1등부터)로 포디움 3칸 갱신
local function updatePodium(racers: { any })
	for i = 1, 3 do
		local c = podiumCells[i]
		local r = racers[i]
		if r then
			local label = string.sub(tostring(r.name or "?"), 1, 8)
			local isMe = r.userId == player.UserId
			c.name.Text = isMe and ("⭐ " .. label) or label
			c.name.TextColor3 = isMe and Color3.fromRGB(120, 255, 160) or Color3.fromRGB(240, 245, 255)
			if r.isBot then
				c.avatar.Visible = false
				c.emoji.Visible = true
			else
				c.emoji.Visible = false
				c.avatar.Visible = true
				local img = thumbCache[r.userId]
				if img and img ~= "" then
					c.avatar.Image = img
				else
					c.avatar.Image = ""
					requestHeadshot(r.userId)
				end
			end
		else
			c.name.Text = "-"
			c.avatar.Visible = true
			c.avatar.Image = ""
			c.emoji.Visible = false
		end
	end
end

-- =====================================================================
-- 부스트 / 감속 표시
-- =====================================================================
local statusIndicator = make("TextLabel", {
	Size = UDim2.new(0, 260, 0, 50),
	Position = UDim2.new(0.5, -130, 1, -90),
	BackgroundTransparency = 1,
	Text = "",
	TextColor3 = Color3.fromRGB(255, 255, 255),
	TextStrokeTransparency = 0.2,
	Font = Enum.Font.GothamBlack,
	TextScaled = true,
	Visible = false,
}, gui)

-- 로컬 차량의 부스트/감속 어트리뷰트를 폴링해 표시
RunService.RenderStepped:Connect(function()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if not seat or not seat:IsA("VehicleSeat") then
		statusIndicator.Visible = false
		return
	end
	local now = workspace:GetServerTimeNow()
	local boostEnd    = seat:GetAttribute("BoostEndTime")    :: number?
	local slowEnd     = seat:GetAttribute("SlowEndTime")     :: number?
	local rocketEnd   = seat:GetAttribute("RocketEndTime")   :: number?
	local spinEnd     = seat:GetAttribute("SpinEndTime")     :: number?
	local freezeEnd   = seat:GetAttribute("FreezeEndTime")   :: number?
	local shieldEnd   = seat:GetAttribute("ShieldEndTime")   :: number? -- [계약 C] 방어막
	local boostItemEnd = seat:GetAttribute("BoostItemEndTime") :: number? -- [계약 C] 버섯 대시
	if freezeEnd and now < freezeEnd then
		statusIndicator.Visible = true
		statusIndicator.Text = "💧 갇힘!"
		statusIndicator.TextColor3 = Color3.fromRGB(90, 190, 255)
	elseif spinEnd and now < spinEnd then
		statusIndicator.Visible = true
		statusIndicator.Text = "🍌 빙글빙글!"
		statusIndicator.TextColor3 = Color3.fromRGB(255, 230, 70)
	elseif rocketEnd and now < rocketEnd then
		statusIndicator.Visible = true
		statusIndicator.Text = "🚀 로켓!"
		statusIndicator.TextColor3 = Color3.fromRGB(255, 120, 90)
	elseif boostItemEnd and now < boostItemEnd then
		-- [계약 C] 버섯 대시 효과 중
		statusIndicator.Visible = true
		statusIndicator.Text = "🍄 대시!"
		statusIndicator.TextColor3 = Color3.fromRGB(255, 160, 50)
	elseif shieldEnd and now < shieldEnd then
		-- [계약 C] 방어막 활성 중 (부스트패드보다 우선 표시)
		statusIndicator.Visible = true
		statusIndicator.Text = "🛡️ 방어막!"
		statusIndicator.TextColor3 = Color3.fromRGB(120, 200, 255)
	elseif boostEnd and now < boostEnd then
		statusIndicator.Visible = true
		statusIndicator.Text = "🚀 부스트!"
		statusIndicator.TextColor3 = Color3.fromRGB(90, 230, 255)
	elseif slowEnd and now < slowEnd then
		statusIndicator.Visible = true
		statusIndicator.Text = "🛢️ 미끄러짐!"
		statusIndicator.TextColor3 = Color3.fromRGB(255, 180, 60)
	else
		statusIndicator.Visible = false
	end
end)

-- =====================================================================
-- 아이템 슬롯 HUD (박스 획득 → [Q]/버튼으로 사용, 최대 2칸 FIFO)
--   슬롯1 = 다음에 사용할 아이템([Q]/버튼), 슬롯2 = 예비 아이템
-- =====================================================================
local ITEM_INFO: { [string]: { emoji: string, name: string, color: Color3 } } = {
	banana   = { emoji = "🍌", name = "바나나",  color = Color3.fromRGB(255, 230, 70) },
	rocket   = { emoji = "🚀", name = "로켓",    color = Color3.fromRGB(255, 120, 90) },
	balloon  = { emoji = "💧", name = "물풍선",  color = Color3.fromRGB(90, 190, 255) },
	-- [계약 C] 신규 아이템 4종 UI 정보
	mushroom  = { emoji = "🍄", name = "대시",    color = Color3.fromRGB(255, 160, 50)  },
	slick     = { emoji = "🛢️", name = "기름통",  color = Color3.fromRGB(100, 120, 140) },
	shield    = { emoji = "🛡️", name = "방어막",  color = Color3.fromRGB(120, 200, 255) },
	lightning = { emoji = "⚡", name = "번개",    color = Color3.fromRGB(255, 230, 90)  },
}
-- FIFO 인벤토리: 서버가 보내는 배열을 그대로 유지 (최대 2개)
local currentItems: { string } = {}

-- 두 슬롯 + 사용 버튼을 담는 컨테이너 (우하단)
local itemContainer = make("Frame", {
	Size = UDim2.new(0, 280, 0, 144),
	Position = UDim2.new(1, -296, 1, -160),
	BackgroundTransparency = 1,
	Visible = false,
}, gui)

-- 슬롯 1개 생성 헬퍼 (xPos = 컨테이너 기준 좌측 오프셋). 라벨/테두리 핸들 반환.
local function makeItemSlot(xPos: number)
	local slot = make("Frame", {
		Size = UDim2.new(0, 130, 0, 106),
		Position = UDim2.new(0, xPos, 0, 0),
		BackgroundColor3 = Color3.fromRGB(20, 24, 34),
		BackgroundTransparency = 0.1,
	}, itemContainer)
	corner(14, slot)
	local stroke = make("UIStroke", { Color = Color3.fromRGB(120, 130, 150), Thickness = 3 }, slot)
	local emojiLbl = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 60),
		Position = UDim2.new(0, 0, 0, 6),
		BackgroundTransparency = 1,
		Text = "—",
		TextScaled = true,
		Font = Enum.Font.GothamBold,
		TextTransparency = 0.65,
	}, slot)
	local nameLbl = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 18),
		Position = UDim2.new(0, 0, 0, 66),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = Color3.fromRGB(240, 245, 255),
		Font = Enum.Font.GothamBold,
		TextScaled = true,
		TextTransparency = 1,
	}, slot)
	return slot, emojiLbl, nameLbl, stroke
end

-- 슬롯1(앞: [Q]로 사용) + 슬롯2(예비, 12px 간격)
local slot1Frame, slot1Emoji, slot1Name, slot1Stroke = makeItemSlot(0)
local slot2Frame, slot2Emoji, slot2Name, slot2Stroke = makeItemSlot(142)
-- 슬롯1 좌상단 "[Q]" 힌트
make("TextLabel", {
	Size = UDim2.new(0, 36, 0, 16),
	Position = UDim2.new(0, 6, 1, -22),
	BackgroundTransparency = 1,
	Text = "[Q]",
	TextColor3 = Color3.fromRGB(190, 200, 220),
	Font = Enum.Font.GothamBold,
	TextScaled = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTransparency = 0.25,
}, slot1Frame)

-- 사용 버튼: 컨테이너 하단 전체 너비 (Q키와 동일 — 슬롯1 아이템 소모)
local itemUseBtn = make("TextButton", {
	Size = UDim2.new(0, 280, 0, 30),
	Position = UDim2.new(0, 0, 1, -32),
	BackgroundColor3 = Color3.fromRGB(70, 170, 90),
	Text = "사용 [Q]",
	TextColor3 = Color3.fromRGB(255, 255, 255),
	Font = Enum.Font.GothamBold,
	TextScaled = true,
	AutoButtonColor = true,
}, itemContainer)
corner(8, itemUseBtn)

-- 슬롯 1개 시각 갱신: 아이템 있으면 lit, 없으면 dimmed
local function applySlotVisual(frame: any, emojiLbl: any, nameLbl: any, stroke: any, itemId: string?)
	local info = itemId and ITEM_INFO[itemId]
	if info then
		frame.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
		frame.BackgroundTransparency = 0.1
		stroke.Color = info.color
		stroke.Thickness = 3
		emojiLbl.Text = info.emoji
		emojiLbl.TextTransparency = 0
		nameLbl.Text = info.name
		nameLbl.TextTransparency = 0
	else
		-- 빈 슬롯: 어둡게
		frame.BackgroundColor3 = Color3.fromRGB(15, 17, 24)
		frame.BackgroundTransparency = 0.5
		stroke.Color = Color3.fromRGB(70, 78, 95)
		stroke.Thickness = 2
		emojiLbl.Text = "—"
		emojiLbl.TextTransparency = 0.65
		nameLbl.Text = ""
		nameLbl.TextTransparency = 1
	end
end

local function refreshItemSlots()
	local item1: string? = if #currentItems >= 1 then currentItems[1] else nil
	local item2: string? = if #currentItems >= 2 then currentItems[2] else nil
	-- 아이템이 하나라도 있을 때만 컨테이너 표시(두 번째 슬롯은 비어 있으면 dimmed)
	itemContainer.Visible = item1 ~= nil or item2 ~= nil
	applySlotVisual(slot1Frame, slot1Emoji, slot1Name, slot1Stroke, item1)
	applySlotVisual(slot2Frame, slot2Emoji, slot2Name, slot2Stroke, item2)
end

-- [Q] / 버튼: 슬롯1(FIFO 맨 앞) 아이템 사용 요청
local function tryUseItem()
	if #currentItems > 0 then
		Remotes.Event("RequestUseItem"):FireServer()
	end
end

itemUseBtn.Activated:Connect(tryUseItem)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.Q then
		tryUseItem()
	end
end)

-- 보유 아이템 변경 수신: 서버가 현재 인벤토리 배열 전체를 보냄
-- 예: {} (없음) / {"banana"} (1개) / {"banana","rocket"} (2개)
Remotes.Event("ItemUpdated").OnClientEvent:Connect(function(items)
	if type(items) == "table" then
		currentItems = items
	else
		currentItems = {}
	end
	refreshItemSlots()
end)

-- 아이템 발동 연출 훅(현재는 statusIndicator + 서버 스폰 파트로 처리)
Remotes.Event("ItemEffect").OnClientEvent:Connect(function(_info) end)

-- =====================================================================
-- 리더보드 패널
-- =====================================================================
local leaderboardBtn = actionButton("🏆 순위표", Color3.fromRGB(200, 160, 60), 144)

local lbFrame = make("Frame", {
	Size = UDim2.new(0, 460, 0, 440),
	Position = UDim2.new(0.5, -230, 0.5, -220),
	BackgroundColor3 = Color3.fromRGB(22, 25, 34),
	Visible = false,
}, gui)
corner(14, lbFrame)
make("TextLabel", {
	Size = UDim2.new(1, 0, 0, 50),
	BackgroundTransparency = 1,
	Text = "🏆 글로벌 최고 기록",
	TextColor3 = Color3.fromRGB(245, 220, 90),
	Font = Enum.Font.GothamBold,
	TextScaled = true,
}, lbFrame)
local lbClose = make("TextButton", {
	Size = UDim2.new(0, 40, 0, 40),
	Position = UDim2.new(1, -48, 0, 8),
	BackgroundColor3 = Color3.fromRGB(200, 70, 70),
	Text = "✕",
	TextColor3 = Color3.fromRGB(255, 255, 255),
	Font = Enum.Font.GothamBold,
	TextScaled = true,
}, lbFrame)
corner(8, lbClose)
local lbPersonal = make("TextLabel", {
	Size = UDim2.new(1, -24, 0, 34),
	Position = UDim2.new(0, 12, 0, 54),
	BackgroundColor3 = Color3.fromRGB(40, 70, 50),
	Text = "내 최고 기록: 없음",
	TextColor3 = Color3.fromRGB(230, 245, 235),
	Font = Enum.Font.GothamMedium,
	TextScaled = true,
}, lbFrame)
corner(8, lbPersonal)
local lbList = make("ScrollingFrame", {
	Size = UDim2.new(1, -24, 1, -100),
	Position = UDim2.new(0, 12, 0, 94),
	BackgroundTransparency = 1,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 5,
}, lbFrame)
make("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }, lbList)

local function renderLeaderboard(top: { any }, personalBest: number)
	lbPersonal.Text = personalBest > 0 and ("내 최고 기록: %.2f초"):format(personalBest) or "내 최고 기록: 없음"
	for _, c in ipairs(lbList:GetChildren()) do
		if c:IsA("TextLabel") then
			c:Destroy()
		end
	end
	if #top == 0 then
		make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 40),
			BackgroundTransparency = 1,
			Text = "아직 기록이 없습니다.",
			TextColor3 = Color3.fromRGB(200, 205, 215),
			Font = Enum.Font.Gotham,
			TextScaled = true,
		}, lbList)
		return
	end
	for _, e in ipairs(top) do
		local medal = e.rank == 1 and "🥇" or (e.rank == 2 and "🥈" or (e.rank == 3 and "🥉" or (tostring(e.rank) .. ".")))
		make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 38),
			BackgroundColor3 = e.rank <= 3 and Color3.fromRGB(50, 46, 30) or Color3.fromRGB(34, 38, 50),
			Text = ("%s  %s   %.2f초"):format(medal, string.sub(e.name, 1, 14), e.time),
			TextColor3 = e.rank <= 3 and Color3.fromRGB(245, 220, 90) or Color3.fromRGB(225, 230, 240),
			Font = Enum.Font.GothamMedium,
			TextScaled = true,
			LayoutOrder = e.rank,
		}, lbList)
	end
end

local cachedLeaderboard: { any } = {}
local function openLeaderboard()
	lbFrame.Visible = true
	-- 최신 데이터 요청
	task.spawn(function()
		local ok, result = pcall(function()
			return Remotes.Function("GetLeaderboard"):InvokeServer()
		end)
		if ok and result then
			cachedLeaderboard = result.top or {}
			renderLeaderboard(result.top or {}, result.personalBest or 0)
		else
			renderLeaderboard(cachedLeaderboard, data and data.stats and data.stats.bestTime or 0)
		end
	end)
end

leaderboardBtn.Activated:Connect(function()
	if lbFrame.Visible then
		lbFrame.Visible = false
	else
		openLeaderboard()
	end
end)
lbClose.Activated:Connect(function()
	lbFrame.Visible = false
end)

-- =====================================================================
-- 버튼/이벤트 연결
-- =====================================================================
-- 차고 열기: 데이터가 준비될 때까지 로딩 화면을 띄운 뒤 공개
local function revealGarage()
	garageFrame.Visible = true
	customizeOpenBtn.Visible = true
	customFrame.Visible = false
end

local function closeGarage()
	garageFrame.Visible = false
	customizeOpenBtn.Visible = false
	customFrame.Visible = false
end

-- 발판으로 연 차고를 "발판에서 벗어나면 자동으로 닫기" 위한 감시.
-- (차고 버튼으로 연 경우엔 감시하지 않아 멀리서도 계속 볼 수 있다.)
local garageProximityToken = 0
local function watchPadProximity()
	local lounge = workspace:FindFirstChild("Lounge")
	local pad = lounge and lounge:FindFirstChild("CarSelectPad")
	if not pad then
		return
	end
	garageProximityToken += 1
	local myToken = garageProximityToken
	task.spawn(function()
		while garageFrame.Visible and myToken == garageProximityToken do
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp then
				local d = (hrp :: BasePart).Position - (pad :: BasePart).Position
				-- 발판은 20x20. 수평거리 18studs 넘게 벗어나면 닫는다(점프/높이는 무시).
				if Vector2.new(d.X, d.Z).Magnitude > 18 then
					closeGarage()
					break
				end
			end
			task.wait(0.25)
		end
	end)
end

local function openGarageWithLoading(fromPad: boolean?)
	if garageFrame.Visible then
		return -- 이미 열려 있으면 무시
	end
	-- 차고를 먼저 확실히 연다(데이터 유무와 무관) → 그 위에 짧은 로딩 연출을 덮었다가 사라지게.
	-- 카드 내용은 데이터 도착 시 PlayerDataUpdated → refreshUI 로 채워진다.
	revealGarage()
	showLoading("🚗 차고지 준비 중...", "차량 정보를 불러오고 있어요")
	task.delay(0.5, hideLoading)
	if fromPad then
		watchPadProximity() -- 발판으로 열었을 때만: 발판에서 벗어나면 자동 닫힘
	end
end

garageBtn.Activated:Connect(function()
	if garageFrame.Visible then
		closeGarage()
	else
		openGarageWithLoading() -- 버튼으로 열면 자동닫힘 없음(멀리서도 사용 가능)
	end
end)
garageClose.Activated:Connect(function()
	closeGarage()
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

-- 라운지 버튼(차고/경주참가/순위표) 일괄 표시 토글
local function setLobbyButtonsVisible(visible: boolean)
	garageBtn.Visible = visible
	queueBtn.Visible = visible
	leaderboardBtn.Visible = visible
end

-- 경주 상태 변화: 경주 시작 시 대기열 상태/패널/버튼 정리
-- [계약 F] 시상대 hideCeremony 포워드 선언
--   실제 구현은 RaceFinished 이후 Ceremony 섹션에서 대입됨.
--   RaceStateChanged 클로저가 이 변수를 upvalue로 캡처하므로
--   나중에 대입한 값을 자동으로 참조한다.
local hideCeremony: () -> () = function() end

Remotes.Event("RaceStateChanged").OnClientEvent:Connect(function(info)
	if info.state == "Racing" then
		inQueue = false
		-- 경주 중에는 라운지 버튼과 모든 패널을 숨긴다
		setLobbyButtonsVisible(false)
		garageFrame.Visible = false
		customFrame.Visible = false
		customizeOpenBtn.Visible = false
		lbFrame.Visible = false
		queueStatus.Visible = false
		-- 새 경주 시작: 아이템 슬롯 초기화
		currentItems = {}
		refreshItemSlots()
	else
		-- 라운지 복귀: 버튼 복원 + HUD 정리
		setLobbyButtonsVisible(true)
		queueBtn.AutoButtonColor = true
		setQueueButton(false)
		queueStatus.Visible = false
		minimap.Visible = false
		rankHud.Visible = false
		podium.Visible = false
		statusIndicator.Visible = false
		currentItems = {}
		refreshItemSlots()
		clearMinimap()
		hideCeremony() -- [계약 F] Idle 복귀 시 시상대 Ceremony UI 숨김
	end
end)

-- 경주 진입 로딩 화면 ON/OFF (서버가 트랙 생성/순간이동 히치를 가리기 위해 제어)
local raceLoadSeq = 0
Remotes.Event("RaceLoading").OnClientEvent:Connect(function(active)
	raceLoadSeq += 1
	if active then
		local seq = raceLoadSeq
		showLoading("🏁 트랙 생성 중...", "출발 준비를 하고 있어요")
		-- 안전 타임아웃: 해제 신호 유실 대비(8초 후 강제 해제)
		task.delay(8, function()
			if seq == raceLoadSeq and loadingRoot.Visible then
				hideLoading()
			end
		end)
	else
		hideLoading()
	end
end)

-- 경주 시작 시 미니맵 외곽선 구성
Remotes.Event("RaceSetup").OnClientEvent:Connect(function(info)
	if info.path and info.bounds then
		buildMinimapOutline(info.path, info.bounds)
		minimap.Visible = true
		rankHud.Visible = true
		podium.Visible = true
		-- 출발 전 HUD 초기 표시(첫 RaceProgress 도착 전까지)
		local totalLaps = info.laps or 2
		placeLabel.Text = "곧 출발!"
		placeLabel.BackgroundColor3 = Color3.fromRGB(48, 70, 110)
		lapLabel.Text = ("총 %d바퀴"):format(totalLaps)
	end
end)

-- 실시간 순위/미니맵 갱신
Remotes.Event("RaceProgress").OnClientEvent:Connect(function(info)
	if info.racers then
		updateMinimapCars(info.racers)
		updateRankHud(info.racers, info.laps or 2)
		updatePodium(info.racers)
	end
end)

-- =====================================================================
-- [계약 E] 카운트다운 비프/출발 사운드
--   MusicController의 loadFirstPlayable 패턴을 인라인 복사.
--   런타임에 첫 로드 성공 id를 사용; 모두 실패하면 무음.
-- =====================================================================
local beepSound = Instance.new("Sound")
beepSound.Volume = 0.8
beepSound.Parent = workspace

local goSound = Instance.new("Sound")
goSound.Volume = 0.9
goSound.Parent = workspace

local function loadFirstPlayable(sound: Sound, ids: { number })
	for _, id in ipairs(ids) do
		sound.SoundId = "rbxassetid://" .. tostring(id)
		if not sound.IsLoaded then
			local loaded = false
			local conn = sound.Loaded:Connect(function()
				loaded = true
			end)
			local waited = 0
			while not loaded and waited < 30 do
				task.wait(0.1)
				waited += 1
			end
			conn:Disconnect()
		end
		if sound.IsLoaded then
			return -- 로드 성공, 이 id 사용
		end
	end
	-- 모두 실패: 무음 유지
end

task.spawn(function()
	loadFirstPlayable(beepSound, (GameConfig.Audio and GameConfig.Audio.countdownBeepIds) or {})
end)
task.spawn(function()
	loadFirstPlayable(goSound, (GameConfig.Audio and GameConfig.Audio.countdownGoIds) or {})
end)

Remotes.Event("RaceCountdown").OnClientEvent:Connect(function(info)
	raceLoadSeq += 1 -- 진행 중 로딩 타임아웃 무효화
	hideLoading() -- 안전망: 카운트다운 시작 시 로딩이 남아있으면 해제
	if info.value and info.value > 0 then
		flashBig(tostring(info.value))
		-- [계약 E] 비프음 재생 (경주 참가 중일 때: 미니맵 표시 = 참가 중)
		if minimap.Visible then
			pcall(function() beepSound:Play() end)
		end
	else
		flashBig("GO!")
		-- [계약 E] 출발 사운드 재생
		if minimap.Visible then
			pcall(function() goSound:Play() end)
		end
	end
end)

Remotes.Event("RaceFinished").OnClientEvent:Connect(function(info)
	if info.results then
		showResults(info.results)
	end
end)

-- =====================================================================
-- [계약 F] 시상대 Ceremony UI
--   PodiumStart{results, top3} 수신 → 3단 시상대 + 🥇🥈🥉 + 이름 + 축하문구
--   TweenService 줌인, 색종이 이모지 연출, 내 순위 강조색(120,255,160).
--   RaceStateChanged{state="Idle"} 수신 시 hideCeremony()로 숨김.
-- =====================================================================
local ceremonyGui = make("ScreenGui", {
	Name = "CeremonyUI",
	ResetOnSpawn = false,
	DisplayOrder = 60,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, playerGui)

-- 포워드 선언한 hideCeremony 변수에 실제 구현 대입
-- (RaceStateChanged 클로저가 이미 이 변수를 upvalue로 캡처하고 있으므로
--  이후 이벤트 발화 시 실제 함수가 호출된다)
hideCeremony = function()
	for _, c in ipairs(ceremonyGui:GetChildren()) do
		c:Destroy()
	end
end

local CEREMONY_MEDALS      = { "🥇", "🥈", "🥉" }
local CEREMONY_BLOCK_COLORS = {
	[1] = Color3.fromRGB(215, 175, 40),  -- 1등: 금
	[2] = Color3.fromRGB(160, 175, 190), -- 2등: 은
	[3] = Color3.fromRGB(180, 120, 70),  -- 3등: 동
}
local CEREMONY_CONGRATS = {
	[1] = "축하합니다! 🎉",
	[2] = "잘하셨습니다! 👍",
	[3] = "훌륭해요! 🌟",
}
local CONFETTI_LIST = { "🎉", "🎊", "✨", "⭐", "🌟", "🎈", "🎆", "🎇" }

local function showCeremony(info: any)
	hideCeremony() -- 기존 Ceremony UI 정리

	local results: { any } = (type(info) == "table" and info.results) or {}
	local top3: { any }   = (type(info) == "table" and info.top3)    or {}

	-- 반투명 배경 오버레이
	make("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(5, 8, 20),
		BackgroundTransparency = 0.35,
		ZIndex = 1,
	}, ceremonyGui)

	-- 색종이(이모지) 장식 — 화면 상단에 흩뿌림
	local CONFETTI_COUNT = 14
	for i = 1, CONFETTI_COUNT do
		local emoji = CONFETTI_LIST[((i - 1) % #CONFETTI_LIST) + 1]
		make("TextLabel", {
			Size = UDim2.new(0, 38, 0, 38),
			Position = UDim2.new((i - 1) / CONFETTI_COUNT, math.random(-8, 8), 0, math.random(4, 52)),
			BackgroundTransparency = 1,
			Text = emoji,
			TextScaled = true,
			Font = Enum.Font.GothamBold,
			ZIndex = 2,
		}, ceremonyGui)
	end

	-- 중앙 시상대 카드
	--   시작: 60% 크기(ClipsDescendants로 잘림) → TweenService로 줌인
	local CARD_W, CARD_H = 520, 410
	local card = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0, math.floor(CARD_W * 0.6), 0, math.floor(CARD_H * 0.6)),
		BackgroundColor3 = Color3.fromRGB(16, 20, 32),
		BackgroundTransparency = 0,
		ZIndex = 3,
		ClipsDescendants = true,
	}, ceremonyGui)
	corner(18, card)
	make("UIStroke", { Color = Color3.fromRGB(245, 220, 90), Thickness = 3 }, card)

	-- 타이틀
	make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 54),
		Position = UDim2.new(0, 0, 0, 6),
		BackgroundTransparency = 1,
		Text = "🏆 경주 시상식! 🏆",
		TextColor3 = Color3.fromRGB(245, 220, 90),
		Font = Enum.Font.GothamBlack,
		TextScaled = true,
		ZIndex = 4,
	}, card)

	-- 1등 축하 문구
	local winner = top3[1]
	local winnerIsMe = winner and (winner.userId == player.UserId)
	local congratsText = (winnerIsMe and "🎉 " or "") .. CEREMONY_CONGRATS[1]
		.. "  " .. (winner and string.sub(tostring(winner.name or "?"), 1, 12) or "")
	make("TextLabel", {
		Size = UDim2.new(1, -20, 0, 32),
		Position = UDim2.new(0, 10, 0, 63),
		BackgroundTransparency = 1,
		Text = congratsText,
		TextColor3 = winnerIsMe and Color3.fromRGB(120, 255, 160) or Color3.fromRGB(255, 245, 180),
		Font = Enum.Font.GothamBold,
		TextScaled = true,
		ZIndex = 4,
	}, card)

	-- 3단 시상대 계단
	--   화면 배치: 2등(좌·중) / 1등(중앙·높음) / 3등(우·낮음)
	local SCREEN_ORDER = { 2, 1, 3 }
	local BLOCK_H = { [1] = 148, [2] = 106, [3] = 74 } -- 등수별 블록 픽셀 높이
	local BLOCK_W = 140
	local GAP = 14
	local PODIUM_BOTTOM_Y = CARD_H - 14  -- 블록 하단 Y(카드 기준)
	-- 열 X 시작 위치: [1]=좌(2등), [2]=중(1등), [3]=우(3등)
	local COL_XS = {
		GAP,
		GAP + BLOCK_W + GAP,
		GAP + (BLOCK_W + GAP) * 2,
	}

	for col = 1, 3 do
		local place = SCREEN_ORDER[col]
		local r = top3[place]
		local isMe = r and (r.userId == player.UserId)
		local bh = BLOCK_H[place]
		local by = PODIUM_BOTTOM_Y - bh  -- 블록 상단 Y(카드 기준)

		-- 시상대 블록
		local block = make("Frame", {
			Size = UDim2.new(0, BLOCK_W, 0, bh),
			Position = UDim2.new(0, COL_XS[col], 0, by),
			BackgroundColor3 = CEREMONY_BLOCK_COLORS[place],
			ZIndex = 4,
		}, card)
		corner(8, block)
		make("UIStroke", {
			Color = isMe and Color3.fromRGB(120, 255, 160) or Color3.fromRGB(255, 255, 255),
			Thickness = isMe and 2.5 or 1,
			Transparency = 0.3,
		}, block)

		-- 메달 이모지 (블록 바로 위, card 기준 절대 위치)
		make("TextLabel", {
			Size = UDim2.new(0, BLOCK_W, 0, 44),
			Position = UDim2.new(0, COL_XS[col], 0, by - 46),
			BackgroundTransparency = 1,
			Text = CEREMONY_MEDALS[place],
			TextScaled = true,
			Font = Enum.Font.GothamBold,
			ZIndex = 4,
		}, card)

		-- 이름 (블록 내부 상단)
		make("TextLabel", {
			Size = UDim2.new(0, BLOCK_W - 8, 0, 28),
			Position = UDim2.new(0, 4, 0, 6),
			BackgroundTransparency = 1,
			Text = r and string.sub(tostring(r.name or "?"), 1, 10) or "-",
			TextColor3 = isMe and Color3.fromRGB(120, 255, 160) or Color3.fromRGB(245, 250, 255),
			Font = Enum.Font.GothamBold,
			TextScaled = true,
			ZIndex = 5,
		}, block)

		-- 등수 텍스트 (이름 아래)
		make("TextLabel", {
			Size = UDim2.new(0, BLOCK_W - 8, 0, 22),
			Position = UDim2.new(0, 4, 0, 36),
			BackgroundTransparency = 1,
			Text = tostring(place) .. "등",
			TextColor3 = Color3.fromRGB(240, 245, 255),
			Font = Enum.Font.GothamMedium,
			TextScaled = true,
			ZIndex = 5,
		}, block)
	end

	-- 내 순위 (top3 밖이면 카드 하단에 별도 강조 표시)
	local myPlace: number? = nil
	for _, r in ipairs(results) do
		if r.userId == player.UserId then
			myPlace = r.place
			break
		end
	end
	if myPlace and myPlace > 3 then
		make("TextLabel", {
			Size = UDim2.new(1, -20, 0, 26),
			Position = UDim2.new(0, 10, 1, -32),
			BackgroundTransparency = 1,
			Text = ("⭐ 내 순위: %d등"):format(myPlace),
			TextColor3 = Color3.fromRGB(120, 255, 160),
			Font = Enum.Font.GothamBold,
			TextScaled = true,
			ZIndex = 4,
		}, card)
	end

	-- TweenService 줌인 (Back Easing = 살짝 튀어나오는 경쾌한 느낌)
	TweenService:Create(
		card,
		TweenInfo.new(0.55, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = UDim2.new(0, CARD_W, 0, CARD_H) }
	):Play()
end

-- [계약 F] PodiumStart 이벤트 핸들러
Remotes.Event("PodiumStart").OnClientEvent:Connect(function(info)
	showCeremony(info)
end)

-- 글로벌 순위 갱신 수신 (패널이 열려있으면 반영)
Remotes.Event("LeaderboardUpdated").OnClientEvent:Connect(function(top)
	cachedLeaderboard = top or {}
	if lbFrame.Visible then
		renderLeaderboard(top or {}, data and data.stats and data.stats.bestTime or 0)
	end
end)

-- 차량 선택 패드 진입 → 서버 신호로 차고 UI 열기. 발판으로 열었으므로 발판에서
-- 벗어나면 자동으로 닫히도록 fromPad=true 로 연다.
Remotes.Event("OpenGarageUI").OnClientEvent:Connect(function()
	openGarageWithLoading(true)
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
