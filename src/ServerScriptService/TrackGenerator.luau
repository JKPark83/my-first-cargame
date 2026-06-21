--!strict
--[[
	TrackGenerator
	---------------
	코드로 트랙을 절차적으로 생성합니다.
	- 시드(seed) 기반으로 매번 동일하게 재현되는 닫힌 루프 테마 트랙 6종
	  (사탕/과자/동물/바다/우주/용암 나라 — GameConfig.Themes와 1:1 매핑)
	- 도로 세그먼트 / 체크포인트 / 출발 스폰 / 결승선을 배치
	- 테마별 팔레트(도로·난간·부스트·아이템박스 색), 장식 소품, 조명 분위기 적용
	- 트랙 길이는 테마의 targetLapSeconds(한 바퀴 목표 시간)로부터 계산하고,
	  랩 수는 "총 ~2분" 목표(GameConfig.Race.targetRaceSeconds)에 맞춰 자동 산출
	- 경주 시작 시 RaceManager가 index로 하나를 골라 build() 호출

	트랙은 평면(아케이드)으로 생성되며, 체크포인트를 순서대로 통과하면
	랩이 인정됩니다(결승선 = 1번 체크포인트).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage.GameConfig)

local TrackGenerator = {}

local ROAD_WIDTH = 48
local ROAD_THICKNESS = 2
local WALL_HEIGHT = 5 -- 가드레일(충돌 벽) 높이
local RAIL_HEIGHT = 0.6 -- 벽 위 색 레일 두께
local SAMPLES_PER_SEGMENT = 20 -- 노드 사이 보간 샘플 수 (높을수록 매끄러움)
local CHECKPOINT_EVERY = 1 -- 모든 경로 노드를 체크포인트로 사용
local DEFAULT_NODE_COUNT = 16 -- 테마에 nodeCount가 없을 때 기본 제어점 수
local DECOR_SPACING = 130 -- 장식 소품 간격(스터드) — 트랙 길이에 비례해 개수 산정

-- 팔레트 타입(테마에서 추출한 색/재질 묶음)
type Palette = {
	road: Color3,
	roadMaterial: Enum.Material,
	wall: Color3,
	railLeft: Color3,
	railRight: Color3,
	lane: Color3,
	edge: Color3,
}

-- 테마가 없을 때 사용할 기본 팔레트(기존 회색 도로 룩)
local DEFAULT_PALETTE: Palette = {
	road = Color3.fromRGB(48, 49, 56),
	roadMaterial = Enum.Material.Asphalt,
	wall = Color3.fromRGB(70, 73, 84),
	railLeft = Color3.fromRGB(225, 80, 80),
	railRight = Color3.fromRGB(235, 235, 240),
	lane = Color3.fromRGB(240, 215, 90),
	edge = Color3.fromRGB(225, 228, 235),
}

export type ThemeLighting = {
	clockTime: number,
	brightness: number,
	ambient: Color3,
	outdoor: Color3,
	fog: Color3,
	fogStart: number,
	fogEnd: number,
}

export type TrackInfo = {
	index: number,
	displayName: string,
	themeId: string,
	lapCount: number, -- 이 트랙에서 완주에 필요한 랩 수(자동 계산)
	lighting: ThemeLighting?, -- 테마 조명(없으면 기본 유지)
	model: Model,
	startCFrame: CFrame,
	spawnCFrames: { CFrame },
	checkpoints: { BasePart }, -- 순서대로 통과해야 하는 체크포인트
	checkpointCount: number,
	minimapPath: { Vector3 }, -- 미니맵 외곽선용 다운샘플 경로
	bounds: { minX: number, maxX: number, minZ: number, maxZ: number },
	boostPads: { BasePart }, -- 부스트 패드
	oilSlicks: { BasePart }, -- 오일 슬릭(감속)
	itemBoxes: { BasePart }, -- 아이템 박스(통과 시 랜덤 아이템)
}

-- 시드 기반 의사난수 생성기 (재현 가능)
local function makeRandom(seed: number): Random
	return Random.new(seed)
end

-- 한 바퀴 목표 시간(t초)에 맞춰 랩 수 산출.
--   긴 트랙(>=30초): 2~3바퀴, 짧은 트랙(<30초): 4~7바퀴.
--   총 경주 시간이 targetRaceSeconds(기본 120초≈2분)에 가깝도록 반올림 후 클램프.
local function lapsForLapTime(t: number): number
	local target = GameConfig.Race.targetRaceSeconds or 120
	local raw = math.floor(target / t + 0.5)
	if t >= 30 then
		return math.clamp(raw, 2, 3)
	end
	return math.clamp(raw, 4, 7)
end

-- 루프를 구성하는 평면상의 노드(위치) 목록 생성
--   nodeCount: 제어점 수(클수록 굴곡이 많아 모양 다양), baseRadius: 기본 반경
local function generateNodes(rng: Random, nodeCount: number, baseRadius: number): { Vector3 }
	local nodes: { Vector3 } = {}
	for i = 1, nodeCount do
		local angle = (i - 1) / nodeCount * math.pi * 2
		-- 반경에 완만한 노이즈를 주어 트랙마다 모양이 달라지되, 너무 들쭉날쭉하지 않게 함
		local radiusJitter = rng:NextNumber(0.82, 1.16)
		local radius = baseRadius * radiusJitter
		-- 살짝 타원으로 변형(자연스러운 곡선)
		local x = math.cos(angle) * radius
		local z = math.sin(angle) * radius * rng:NextNumber(0.92, 1.08)
		nodes[i] = Vector3.new(x, 0, z)
	end
	return nodes
end

-- Catmull-Rom 스플라인으로 노드 사이를 부드럽게 보간
local function catmullRom(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: number): Vector3
	local t2 = t * t
	local t3 = t2 * t
	return 0.5
		* (
			(2 * p1)
			+ (-p0 + p2) * t
			+ (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
			+ (-p0 + 3 * p1 - 3 * p2 + p3) * t3
		)
end

-- 노드를 보간해 촘촘한 경로 점 목록 생성
local function buildPath(nodes: { Vector3 }, samplesPerSegment: number): { Vector3 }
	local path: { Vector3 } = {}
	local n = #nodes
	for i = 1, n do
		local p0 = nodes[(i - 2) % n + 1]
		local p1 = nodes[(i - 1) % n + 1]
		local p2 = nodes[i % n + 1]
		local p3 = nodes[(i + 1) % n + 1]
		for s = 0, samplesPerSegment - 1 do
			local t = s / samplesPerSegment
			path[#path + 1] = catmullRom(p0, p1, p2, p3, t)
		end
	end
	return path
end

-- 얇은 시각용 파트(충돌 없음) — 도로 마킹/레일
local function makeStripe(look: CFrame, offset: CFrame, size: Vector3, color: Color3, parent: Instance)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.Material = Enum.Material.SmoothPlastic
	p.Color = color
	p.Size = size
	p.CFrame = look * offset
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
end

local function makeRoadSegment(a: Vector3, b: Vector3, parent: Instance, index: number, pal: Palette): ()
	local mid = (a + b) / 2
	local dir = b - a
	local length = dir.Magnitude
	if length < 0.05 then
		return
	end
	local look = CFrame.lookAt(mid, b)
	local segLen = length + 2 -- 세그먼트끼리 살짝 겹쳐 틈 제거

	-- 도로 바닥
	local road = Instance.new("Part")
	road.Anchored = true
	road.Material = pal.roadMaterial
	road.Color = pal.road
	road.Size = Vector3.new(ROAD_WIDTH, ROAD_THICKNESS, segLen)
	road.CFrame = look * CFrame.new(0, -ROAD_THICKNESS / 2, 0)
	road.TopSurface = Enum.SurfaceType.Smooth
	road.BottomSurface = Enum.SurfaceType.Smooth
	road.Parent = parent

	-- 양쪽 솔리드 가드레일(충돌) + 색 레일 캡
	for _, side in ipairs({ -1, 1 }) do
		local wall = Instance.new("Part")
		wall.Anchored = true
		wall.Material = Enum.Material.SmoothPlastic
		wall.Color = pal.wall
		wall.Size = Vector3.new(1.4, WALL_HEIGHT, segLen)
		wall.CFrame = look * CFrame.new(side * (ROAD_WIDTH / 2), WALL_HEIGHT / 2, 0)
		wall.TopSurface = Enum.SurfaceType.Smooth
		wall.BottomSurface = Enum.SurfaceType.Smooth
		wall.Parent = parent
		-- 레일 캡(색): 왼쪽/오른쪽 다른 색으로 방향감
		makeStripe(
			look,
			CFrame.new(side * (ROAD_WIDTH / 2), WALL_HEIGHT + RAIL_HEIGHT / 2, 0),
			Vector3.new(1.7, RAIL_HEIGHT, segLen),
			side == -1 and pal.railLeft or pal.railRight,
			parent
		)
	end

	-- 가장자리 라인 (도로면 살짝 위)
	for _, side in ipairs({ -1, 1 }) do
		makeStripe(
			look,
			CFrame.new(side * (ROAD_WIDTH / 2 - 2), 0.06, 0),
			Vector3.new(0.7, 0.12, segLen),
			pal.edge,
			parent
		)
	end

	-- 중앙 차선(점선) — 한 칸 걸러 하나
	if index % 2 == 0 then
		makeStripe(look, CFrame.new(0, 0.06, 0), Vector3.new(0.8, 0.12, segLen * 0.6), pal.lane, parent)
	end
end

-- 경로 위 한 지점의 진행 방향 CFrame (i번째 점에서 다음 점을 바라봄)
local function pathCFrameAt(path: { Vector3 }, i: number): CFrame
	local a = path[i]
	local b = path[(i % #path) + 1]
	return CFrame.lookAt(a, b)
end

-- 부스트 패드 생성 (테마 색 적용)
local function makeBoostPad(cf: CFrame, parent: Instance, color: Color3): BasePart
	local pad = Instance.new("Part")
	pad.Name = "BoostPad"
	pad.Anchored = true
	pad.CanCollide = false
	pad.Material = Enum.Material.Neon
	pad.Color = color
	pad.Size = Vector3.new(14, 0.4, 10)
	pad.CFrame = cf * CFrame.new(0, 0.3, 0)
	pad.Transparency = 0.15
	pad.Parent = parent

	-- 화살표 표시(SurfaceGui 텍스트)
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Top
	sg.Parent = pad
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = 1
	lbl.Text = "▲▲▲"
	lbl.TextColor3 = Color3.fromRGB(255, 255, 255)
	lbl.Font = Enum.Font.GothamBold
	lbl.TextScaled = true
	lbl.Rotation = 90
	lbl.Parent = sg
	return pad
end

-- 오일 슬릭(감속) 생성 (테마 색 적용)
local function makeOilSlick(cf: CFrame, parent: Instance, color: Color3): BasePart
	local oil = Instance.new("Part")
	oil.Name = "OilSlick"
	oil.Shape = Enum.PartType.Cylinder
	oil.Anchored = true
	oil.CanCollide = false
	oil.Material = Enum.Material.Glass
	oil.Color = color
	oil.Size = Vector3.new(0.3, 11, 11)
	oil.CFrame = cf * CFrame.new(0, 0.2, 0) * CFrame.Angles(0, 0, math.rad(90))
	oil.Transparency = 0.25
	oil.Reflectance = 0.4
	oil.Parent = parent
	return oil
end

-- 아이템 박스 생성 (통과하면 랜덤 아이템 획득, 테마 색 적용)
local function makeItemBox(cf: CFrame, parent: Instance, color: Color3): BasePart
	local size = GameConfig.Items.boxSize
	local box = Instance.new("Part")
	box.Name = "ItemBox"
	box.Anchored = true
	box.CanCollide = false
	box.Material = Enum.Material.Neon
	box.Color = color
	box.Size = Vector3.new(size, size, size)
	box.CFrame = cf * CFrame.new(0, size / 2 + 1.5, 0)
	box.Transparency = 0.2
	box:SetAttribute("Active", true) -- 획득 후 비활성화/재생성 토글
	box.Parent = parent

	-- 물음표 표시 (모든 방향에서 보이도록 BillboardGui 사용)
	local bg = Instance.new("BillboardGui")
	bg.Name = "Mark"
	bg.Size = UDim2.fromOffset(60, 60)
	bg.AlwaysOnTop = false
	bg.Adornee = box
	bg.Parent = box
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = 1
	lbl.Text = "?"
	lbl.TextColor3 = Color3.fromRGB(255, 255, 255)
	lbl.TextStrokeTransparency = 0.3
	lbl.Font = Enum.Font.GothamBlack
	lbl.TextScaled = true
	lbl.Parent = bg
	return box
end

-- =====================================================================
-- 테마 장식 소품(props) — Block/Ball/Cylinder 기본 도형으로 조립
-- =====================================================================
-- 모든 소품은 Anchored=true, CanCollide=false (가드레일 바깥 장식이라 주행 방해 없음).

-- 공통 파트 생성 헬퍼
local function mkPart(
	parent: Instance,
	shape: Enum.PartType,
	size: Vector3,
	color: Color3,
	material: Enum.Material,
	cf: CFrame,
	transparency: number?
): BasePart
	local p = Instance.new("Part")
	p.Shape = shape
	p.Anchored = true
	p.CanCollide = false
	p.Size = size
	p.Color = color
	p.Material = material
	p.CFrame = cf
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if transparency then
		p.Transparency = transparency
	end
	p.Parent = parent
	return p
end

-- 구체(중심 = centerCf)
local function ball(parent: Instance, d: number, color: Color3, material: Enum.Material, centerCf: CFrame): BasePart
	return mkPart(parent, Enum.PartType.Ball, Vector3.new(d, d, d), color, material, centerCf)
end

-- 직육면체(중심 = centerCf)
local function box(parent: Instance, sx: number, sy: number, sz: number, color: Color3, material: Enum.Material, centerCf: CFrame): BasePart
	return mkPart(parent, Enum.PartType.Block, Vector3.new(sx, sy, sz), color, material, centerCf)
end

-- 수직 원기둥: baseCf(바닥)에서 위로 height만큼 서있음 (지름 diameter)
local function vcyl(parent: Instance, height: number, diameter: number, color: Color3, material: Enum.Material, baseCf: CFrame): BasePart
	return mkPart(
		parent,
		Enum.PartType.Cylinder,
		Vector3.new(height, diameter, diameter),
		color,
		material,
		baseCf * CFrame.new(0, height / 2, 0) * CFrame.Angles(0, 0, math.rad(90))
	)
end

-- 납작 원반(수평): 중심 = centerCf, 지름 diameter, 두께 thickness
local function disc(parent: Instance, diameter: number, thickness: number, color: Color3, material: Enum.Material, centerCf: CFrame): BasePart
	return mkPart(
		parent,
		Enum.PartType.Cylinder,
		Vector3.new(thickness, diameter, diameter),
		color,
		material,
		centerCf * CFrame.Angles(0, 0, math.rad(90))
	)
end

local SP = Enum.Material.SmoothPlastic
local NEON = Enum.Material.Neon

-- 각 빌더: (cf, parent, theme) → 도로변 지면(cf)에 소품 1개 조립
type PropBuilder = (CFrame, Instance, any) -> ()

local PROP_BUILDERS: { [string]: PropBuilder } = {
	-- ───── 사탕나라 ─────
	lollipop = function(cf, parent, _)
		vcyl(parent, 9, 1.2, Color3.fromRGB(245, 245, 245), SP, cf) -- 흰 막대
		ball(parent, 5, Color3.fromRGB(225, 55, 90), SP, cf * CFrame.new(0, 11, 0)) -- 사탕 머리
		ball(parent, 2.4, Color3.fromRGB(255, 255, 255), SP, cf * CFrame.new(0, 11, 1.6)) -- 줄무늬 점
	end,
	donut = function(cf, parent, _)
		disc(parent, 8, 2.2, Color3.fromRGB(120, 75, 40), SP, cf * CFrame.new(0, 1.2, 0)) -- 도넛 빵
		disc(parent, 7, 0.8, Color3.fromRGB(255, 150, 190), SP, cf * CFrame.new(0, 2.5, 0)) -- 분홍 글레이즈
		box(parent, 0.5, 0.5, 1.4, Color3.fromRGB(120, 220, 255), SP, cf * CFrame.new(1.5, 3, 0)) -- 스프링클
		box(parent, 0.5, 0.5, 1.4, Color3.fromRGB(255, 240, 120), SP, cf * CFrame.new(-1.2, 3, 1)) -- 스프링클
	end,
	cake = function(cf, parent, _)
		disc(parent, 10, 4, Color3.fromRGB(255, 170, 195), SP, cf * CFrame.new(0, 2, 0)) -- 1층
		disc(parent, 8, 3.4, Color3.fromRGB(170, 245, 215), SP, cf * CFrame.new(0, 5.4, 0)) -- 2층
		disc(parent, 6, 3, Color3.fromRGB(255, 250, 170), SP, cf * CFrame.new(0, 8.4, 0)) -- 3층
		vcyl(parent, 3, 0.6, Color3.fromRGB(255, 255, 255), SP, cf * CFrame.new(0, 9.9, 0)) -- 초
		ball(parent, 1.4, Color3.fromRGB(255, 150, 0), NEON, cf * CFrame.new(0, 13.4, 0)) -- 불꽃
	end,
	-- ───── 과자나라 ─────
	cookie = function(cf, parent, _)
		disc(parent, 10, 1.6, Color3.fromRGB(180, 120, 65), SP, cf * CFrame.new(0, 0.8, 0)) -- 쿠키
		ball(parent, 1.6, Color3.fromRGB(70, 45, 25), SP, cf * CFrame.new(2, 1.7, 1)) -- 초코칩
		ball(parent, 1.6, Color3.fromRGB(70, 45, 25), SP, cf * CFrame.new(-1.5, 1.7, -1.5)) -- 초코칩
		ball(parent, 1.6, Color3.fromRGB(70, 45, 25), SP, cf * CFrame.new(0.5, 1.7, -2.5)) -- 초코칩
	end,
	icecream = function(cf, parent, _)
		vcyl(parent, 5, 3, Color3.fromRGB(210, 170, 120), SP, cf) -- 콘
		ball(parent, 3.6, Color3.fromRGB(255, 250, 240), SP, cf * CFrame.new(0, 6.6, 0)) -- 바닐라 스쿱
		ball(parent, 2.8, Color3.fromRGB(255, 135, 135), SP, cf * CFrame.new(0, 9.1, 0)) -- 딸기 스쿱
	end,
	-- ───── 동물나라 ─────
	tree = function(cf, parent, _)
		vcyl(parent, 6, 2, Color3.fromRGB(120, 80, 40), SP, cf) -- 줄기
		ball(parent, 7, Color3.fromRGB(60, 165, 60), SP, cf * CFrame.new(0, 8.5, 0)) -- 잎
		ball(parent, 4.5, Color3.fromRGB(75, 185, 75), SP, cf * CFrame.new(2, 7, 1)) -- 잎 덩어리
	end,
	sunflower = function(cf, parent, _)
		vcyl(parent, 5, 0.8, Color3.fromRGB(60, 150, 40), SP, cf) -- 줄기
		ball(parent, 3.8, Color3.fromRGB(255, 210, 30), NEON, cf * CFrame.new(0, 6.4, 0)) -- 꽃잎
		ball(parent, 1.8, Color3.fromRGB(110, 65, 25), SP, cf * CFrame.new(0, 6.4, 1.2)) -- 꽃 중심
	end,
	mushroom = function(cf, parent, _)
		vcyl(parent, 3, 2.4, Color3.fromRGB(238, 235, 220), SP, cf) -- 기둥
		ball(parent, 5, Color3.fromRGB(220, 55, 45), SP, cf * CFrame.new(0, 4, 0)) -- 빨간 갓
		ball(parent, 1, Color3.fromRGB(255, 255, 255), SP, cf * CFrame.new(1.5, 5, 0.6)) -- 흰 점
		ball(parent, 1, Color3.fromRGB(255, 255, 255), SP, cf * CFrame.new(-1.2, 5, -0.8)) -- 흰 점
	end,
	-- ───── 바다나라 ─────
	coral = function(cf, parent, _)
		vcyl(parent, 6, 1.4, Color3.fromRGB(255, 110, 90), NEON, cf * CFrame.new(-1.6, 0, 0) * CFrame.Angles(0, 0, math.rad(16)))
		vcyl(parent, 5, 1.2, Color3.fromRGB(255, 130, 100), NEON, cf)
		vcyl(parent, 6.5, 1.4, Color3.fromRGB(255, 90, 120), NEON, cf * CFrame.new(1.6, 0, 0) * CFrame.Angles(0, 0, math.rad(-16)))
		ball(parent, 1.8, Color3.fromRGB(255, 200, 120), NEON, cf * CFrame.new(0, 5.5, 0))
	end,
	seaweed = function(cf, parent, _)
		vcyl(parent, 9, 1, Color3.fromRGB(0, 175, 90), SP, cf * CFrame.new(-1, 0, 0) * CFrame.Angles(0, 0, math.rad(10)))
		vcyl(parent, 8, 1, Color3.fromRGB(20, 195, 110), SP, cf)
		vcyl(parent, 9.5, 1, Color3.fromRGB(0, 165, 80), SP, cf * CFrame.new(1, 0, 0) * CFrame.Angles(0, 0, math.rad(-10)))
	end,
	starfish = function(cf, parent, _)
		ball(parent, 2.6, Color3.fromRGB(255, 130, 40), SP, cf * CFrame.new(0, 0.8, 0)) -- 중심
		for i = 0, 4 do
			box(parent, 1.6, 0.8, 4, Color3.fromRGB(255, 150, 55), SP, cf * CFrame.new(0, 0.7, 0) * CFrame.Angles(0, math.rad(i * 72), 0) * CFrame.new(0, 0, 2.2)) -- 팔 5개
		end
	end,
	-- ───── 우주나라 ─────
	rocket = function(cf, parent, _)
		vcyl(parent, 12, 4, Color3.fromRGB(245, 245, 245), SP, cf) -- 몸체
		ball(parent, 4.2, Color3.fromRGB(220, 40, 40), SP, cf * CFrame.new(0, 13, 0)) -- 노즈콘
		ball(parent, 3, Color3.fromRGB(255, 130, 0), NEON, cf * CFrame.new(0, -0.2, 0)) -- 화염
		box(parent, 1, 3, 2, Color3.fromRGB(200, 60, 60), SP, cf * CFrame.new(2.4, 1.6, 0)) -- 핀
		box(parent, 1, 3, 2, Color3.fromRGB(200, 60, 60), SP, cf * CFrame.new(-2.4, 1.6, 0)) -- 핀
	end,
	planet = function(cf, parent, _)
		ball(parent, 12, Color3.fromRGB(70, 105, 220), SP, cf * CFrame.new(0, 9, 0)) -- 행성
		disc(parent, 20, 0.8, Color3.fromRGB(255, 200, 0), NEON, cf * CFrame.new(0, 9, 0)) -- 고리
	end,
	star = function(cf, parent, _)
		vcyl(parent, 8, 0.5, Color3.fromRGB(40, 40, 70), SP, cf) -- 가느다란 받침
		ball(parent, 2.4, Color3.fromRGB(255, 255, 220), NEON, cf * CFrame.new(0, 9, 0)) -- 별빛
	end,
	-- ───── 용암나라 ─────
	rock = function(cf, parent, _)
		ball(parent, 8, Color3.fromRGB(45, 35, 30), SP, cf * CFrame.new(0, 3.5, 0)) -- 큰 바위
		ball(parent, 5, Color3.fromRGB(55, 42, 35), SP, cf * CFrame.new(2.5, 6, 1)) -- 작은 바위
		ball(parent, 1.4, Color3.fromRGB(255, 90, 0), NEON, cf * CFrame.new(-1.5, 4, 2)) -- 용암 틈
	end,
	lavapillar = function(cf, parent, _)
		vcyl(parent, 10, 3, Color3.fromRGB(48, 32, 22), SP, cf) -- 검은 기둥
		ball(parent, 4, Color3.fromRGB(255, 85, 0), NEON, cf * CFrame.new(0, 11, 0)) -- 용암 덩어리
		box(parent, 3.2, 0.6, 3.2, Color3.fromRGB(255, 120, 0), NEON, cf * CFrame.new(0, 5, 0)) -- 흘러내린 용암
	end,
	volcano = function(cf, parent, _)
		vcyl(parent, 5, 12, Color3.fromRGB(52, 38, 28), SP, cf) -- 넓은 밑단
		vcyl(parent, 7, 6, Color3.fromRGB(52, 38, 28), SP, cf * CFrame.new(0, 5, 0)) -- 위로 좁아지는 봉우리
		ball(parent, 4.5, Color3.fromRGB(255, 70, 0), NEON, cf * CFrame.new(0, 12, 0)) -- 분화구 용암
	end,
	-- ───── 기본(폴백) ─────
	cone = function(cf, parent, _)
		vcyl(parent, 4, 2, Color3.fromRGB(245, 140, 30), SP, cf) -- 라바콘
		box(parent, 3, 0.4, 3, Color3.fromRGB(245, 140, 30), SP, cf * CFrame.new(0, 0.2, 0)) -- 받침
	end,
}

-- =====================================================================
-- 공개 API
-- =====================================================================

-- 트랙 메타 정보(미생성). index로 테마를 1:1 선택.
function TrackGenerator.getTrackMeta(index: number)
	local themes = GameConfig.Themes
	local theme = nil
	if themes and #themes > 0 then
		theme = themes[((index - 1) % #themes) + 1]
	end
	return {
		index = index,
		seed = 1000 + index * 7919, -- 트랙별 고정 시드 (소수 곱)
		theme = theme,
		displayName = theme and theme.displayName or ("트랙 #%d"):format(index),
	}
end

-- 트랙을 실제로 생성하여 Workspace에 배치하고 정보를 반환
function TrackGenerator.build(index: number, parent: Instance?): TrackInfo
	local meta = TrackGenerator.getTrackMeta(index)
	local rng = makeRandom(meta.seed)
	local theme = meta.theme

	-- 테마 → 팔레트/길이/장식/조명 해석 (테마 없으면 기본값)
	local pal: Palette = theme
			and {
				road = theme.road,
				roadMaterial = theme.roadMaterial or Enum.Material.Asphalt,
				wall = theme.wall,
				railLeft = theme.railLeft,
				railRight = theme.railRight,
				lane = theme.lane,
				edge = theme.edge,
			}
		or DEFAULT_PALETTE
	local boostColor: Color3 = (theme and theme.boostPad) or GameConfig.Boost.padColor
	local oilColor: Color3 = (theme and theme.oil) or GameConfig.Obstacles.oilColor
	local itemColor: Color3 = (theme and theme.itemBox) or GameConfig.Items.boxColor
	local props: { string } = (theme and theme.props) or { "cone" }

	local nodeCount = (theme and theme.nodeCount) or DEFAULT_NODE_COUNT
	local avgSpeed = GameConfig.Race.avgSpeed or 120
	local targetLapSeconds = (theme and theme.targetLapSeconds) or 24
	-- 한 바퀴 목표 시간 × 평균 속도 = 트랙 둘레 → 반경
	local baseRadius = (avgSpeed * targetLapSeconds) / (2 * math.pi)
	local lapCount = lapsForLapTime(targetLapSeconds)

	local model = Instance.new("Model")
	model.Name = ("Track_%d"):format(index)

	local nodes = generateNodes(rng, nodeCount, baseRadius)
	local path = buildPath(nodes, SAMPLES_PER_SEGMENT)

	-- 도로 생성
	for i = 1, #path do
		local a = path[i]
		local b = path[(i % #path) + 1]
		makeRoadSegment(a, b, model, i, pal)
	end

	-- 커브 이음새(틈) 메우기
	-- 직선 박스 세그먼트는 커브에서 끝면이 각을 이뤄 바깥 모서리에 삼각형 틈이 생긴다.
	-- 각 꼭짓점에 진행 방향 평균(바이섹터)으로 정렬한 도로/레일 캡을 덧대 매끄럽게 잇는다.
	-- 캡은 살짝 띄워 z-fighting을 피하고, 도로 캡은 CanCollide=false(주행 범프 방지)로 둔다.
	do
		local np = #path
		for i = 1, np do
			local prev = path[(i - 2) % np + 1]
			local cur = path[i]
			local nxt = path[i % np + 1]
			local dIn = cur - prev
			local dOut = nxt - cur
			if dIn.Magnitude < 0.05 or dOut.Magnitude < 0.05 then
				continue
			end
			local uIn, uOut = dIn.Unit, dOut.Unit
			-- 거의 직선인 이음새는 캡이 불필요 → 건너뛰어 파트 수 절약
			if uIn:Dot(uOut) > 0.99985 then
				continue
			end
			local bis = uIn + uOut
			if bis.Magnitude < 1e-3 then
				continue
			end
			local look = CFrame.lookAt(cur, cur + bis.Unit)
			local capLen = 4

			-- 도로 바닥 캡 (양쪽 벽 아래로 살짝 파묻히게 폭을 키움, 0.04 띄워 z-fighting 방지)
			local cap = Instance.new("Part")
			cap.Anchored = true
			cap.CanCollide = false
			cap.Material = pal.roadMaterial
			cap.Color = pal.road
			cap.Size = Vector3.new(ROAD_WIDTH + 1.2, ROAD_THICKNESS, capLen)
			cap.CFrame = look * CFrame.new(0, -ROAD_THICKNESS / 2 + 0.04, 0)
			cap.TopSurface = Enum.SurfaceType.Smooth
			cap.BottomSurface = Enum.SurfaceType.Smooth
			cap.Parent = model

			-- 레일 캡(좌/우 색) — 색 레일 라인을 끊김 없이 연결
			for _, side in ipairs({ -1, 1 }) do
				makeStripe(
					look,
					CFrame.new(side * (ROAD_WIDTH / 2), WALL_HEIGHT + RAIL_HEIGHT / 2 + 0.03, 0),
					Vector3.new(1.7, RAIL_HEIGHT, capLen),
					side == -1 and pal.railLeft or pal.railRight,
					model
				)
			end
		end
	end

	-- 체크포인트 생성 (경로 노드 위치 기반, 순서대로)
	local checkpoints: { BasePart } = {}
	local cpFolder = Instance.new("Folder")
	cpFolder.Name = "Checkpoints"
	cpFolder.Parent = model

	for i = 1, #nodes, CHECKPOINT_EVERY do
		local pos = nodes[i]
		local nextPos = nodes[i % #nodes + 1]
		local look = CFrame.lookAt(pos, nextPos)

		local cp = Instance.new("Part")
		cp.Name = ("Checkpoint_%d"):format(#checkpoints + 1)
		cp.Anchored = true
		cp.CanCollide = false
		cp.Transparency = 1
		cp.Size = Vector3.new(ROAD_WIDTH, WALL_HEIGHT * 2, 4)
		cp.CFrame = look * CFrame.new(0, WALL_HEIGHT, 0)
		cp:SetAttribute("Order", #checkpoints + 1)
		cp.Parent = cpFolder
		checkpoints[#checkpoints + 1] = cp
	end

	-- 결승선(1번 체크포인트) 시각 표시
	local startNode = nodes[1]
	local secondNode = nodes[2]
	local startLook = CFrame.lookAt(startNode, secondNode)

	local finishLine = Instance.new("Part")
	finishLine.Name = "FinishLine"
	finishLine.Anchored = true
	finishLine.CanCollide = false
	finishLine.Material = Enum.Material.SmoothPlastic
	finishLine.Color = Color3.fromRGB(245, 245, 245)
	finishLine.Size = Vector3.new(ROAD_WIDTH, 0.3, 6)
	finishLine.CFrame = startLook * CFrame.new(0, 0.2, 0)
	finishLine.Parent = model

	-- 출발 스폰 위치들 (결승선 뒤쪽, 그리드 배치)
	local spawnCFrames: { CFrame } = {}
	local rows = math.ceil(GameConfig.Race.maxPlayers / 2)
	local idx = 0
	for row = 0, rows - 1 do
		for col = -1, 1, 2 do
			idx += 1
			if idx > GameConfig.Race.maxPlayers then
				break
			end
			local offset = CFrame.new(col * (ROAD_WIDTH / 4), 4, 10 + row * 12)
			spawnCFrames[idx] = startLook * offset
		end
	end

	-- ───────── 부스트 패드 / 오일 슬릭 / 아이템 박스 배치 ─────────
	local boostPads: { BasePart } = {}
	local oilSlicks: { BasePart } = {}
	local itemFolder = Instance.new("Folder")
	itemFolder.Name = "TrackItems"
	itemFolder.Parent = model

	-- 출발선 주변(앞부분)은 비워두기 위해 일부 구간 제외
	local startGap = math.floor(#path * 0.06)
	local usable = #path - startGap * 2

	-- 부스트 패드: 도로 중앙에 균등 배치
	for i = 1, GameConfig.Boost.padsPerTrack do
		local pIdx = startGap + math.floor(usable * (i - 0.5) / GameConfig.Boost.padsPerTrack) + 1
		pIdx = ((pIdx - 1) % #path) + 1
		local cf = pathCFrameAt(path, pIdx)
		boostPads[i] = makeBoostPad(cf, itemFolder, boostColor)
	end

	-- 오일 슬릭: 좌우로 살짝 비껴 배치(피할 수 있게)
	for i = 1, GameConfig.Obstacles.oilPerTrack do
		local pIdx = startGap + math.floor(usable * (i - 0.5) / GameConfig.Obstacles.oilPerTrack) + 1
		pIdx = ((pIdx + 4 - 1) % #path) + 1 -- 부스트와 겹치지 않게 오프셋
		local side = (i % 2 == 0) and 1 or -1
		local cf = pathCFrameAt(path, pIdx) * CFrame.new(side * (ROAD_WIDTH / 4), 0, 0)
		oilSlicks[i] = makeOilSlick(cf, itemFolder, oilColor)
	end

	-- 아이템 박스: 도로 폭 방향으로 좌/중/우 번갈아 배치(주워 먹는 재미)
	local itemBoxes: { BasePart } = {}
	for i = 1, GameConfig.Items.boxesPerTrack do
		local pIdx = startGap + math.floor(usable * (i - 0.5) / GameConfig.Items.boxesPerTrack) + 1
		pIdx = ((pIdx + 2 - 1) % #path) + 1 -- 부스트/오일과 다른 위치로 오프셋
		local lane = ((i % 3) - 1) -- -1, 0, 1 순환
		local cf = pathCFrameAt(path, pIdx) * CFrame.new(lane * (ROAD_WIDTH / 4), 0, 0)
		itemBoxes[i] = makeItemBox(cf, itemFolder, itemColor)
	end

	-- ───────── 테마 장식 소품 배치 (가드레일 바깥) ─────────
	local decorFolder = Instance.new("Folder")
	decorFolder.Name = "Decorations"
	decorFolder.Parent = model

	local approxLen = 2 * math.pi * baseRadius
	local decorCount = math.clamp(math.floor(approxLen / DECOR_SPACING), 16, 36)
	for i = 1, decorCount do
		local pIdx = math.floor(#path * (i - 0.5) / decorCount) + 1
		pIdx = ((pIdx - 1) % #path) + 1
		local side = (i % 2 == 0) and 1 or -1
		-- 가드레일(ROAD_WIDTH/2)에서 7스터드 바깥
		local cf = pathCFrameAt(path, pIdx) * CFrame.new(side * (ROAD_WIDTH / 2 + 7), 0, 0)
		local key = props[((i - 1) % #props) + 1]
		local builder = PROP_BUILDERS[key] or PROP_BUILDERS.cone
		builder(cf, decorFolder, theme)
	end

	-- ───────── 미니맵용 외곽선 & 바운드 ─────────
	local minimapPath: { Vector3 } = {}
	for i = 1, #path, 2 do -- 다운샘플
		minimapPath[#minimapPath + 1] = path[i]
	end
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	for _, p in ipairs(path) do
		minX = math.min(minX, p.X)
		maxX = math.max(maxX, p.X)
		minZ = math.min(minZ, p.Z)
		maxZ = math.max(maxZ, p.Z)
	end

	model.Parent = parent or workspace

	return {
		index = index,
		displayName = meta.displayName,
		themeId = (theme and theme.id) or "default",
		lapCount = lapCount,
		lighting = theme and theme.lighting or nil,
		model = model,
		startCFrame = startLook,
		spawnCFrames = spawnCFrames,
		checkpoints = checkpoints,
		checkpointCount = #checkpoints,
		minimapPath = minimapPath,
		bounds = { minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ },
		boostPads = boostPads,
		oilSlicks = oilSlicks,
		itemBoxes = itemBoxes,
	}
end

return TrackGenerator
