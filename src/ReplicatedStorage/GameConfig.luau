--!strict
--[[
	GameConfig
	-----------
	게임의 모든 핵심 데이터를 한곳에 모은 설정 모듈입니다.
	차량 목록 / 등급 / 성능 / 가격 / 보상 / 트랙 / 커스터마이징 옵션을
	여기서 관리하면 밸런스 조정이 쉬워집니다.

	이 모듈은 서버와 클라이언트 양쪽에서 require 하여 공유합니다.
]]

local GameConfig = {}

-- =====================================================================
-- 자동차 등급 (Tier)
-- =====================================================================
-- 4등급: 초보(Beginner) / 일반(Normal) / 고급(Advanced) / 전설(Legendary)
export type Tier = "Beginner" | "Normal" | "Advanced" | "Legendary"

GameConfig.Tiers = {
	Beginner = {
		displayName = "초보",
		color = Color3.fromRGB(120, 200, 120), -- 초록
		order = 1,
	},
	Normal = {
		displayName = "일반",
		color = Color3.fromRGB(90, 160, 240), -- 파랑
		order = 2,
	},
	Advanced = {
		displayName = "고급",
		color = Color3.fromRGB(180, 110, 240), -- 보라
		order = 3,
	},
	Legendary = {
		displayName = "전설",
		color = Color3.fromRGB(240, 200, 70), -- 금색
		order = 4,
	},
}

-- =====================================================================
-- 자동차 목록
-- =====================================================================
-- 성능 스탯 (아케이드):
--   topSpeed  : 최고 속도 (studs/sec)
--   accel     : 가속력 (높을수록 빨리 최고속 도달)
--   handling  : 핸들링 (회전 민첩성, 0~1 권장)
--   grip      : 접지력 (코너에서 미끄러짐 저항, 0~1)
--
-- 가격:
--   currency = "Money"  → 게임머니로 구매
--   currency = "Robux"  → 로벅스로 구매 (현재 비활성, 구조만 준비)
--   price    = 0        → 기본 보유(무료)

export type CarStats = {
	topSpeed: number,
	accel: number,
	handling: number,
	grip: number,
}

export type CarDef = {
	id: string,
	displayName: string,
	tier: Tier,
	currency: "Money" | "Robux",
	price: number,
	robuxProductId: number?, -- 로벅스 차량용 DevProduct/GamePass id (출시 전 연결)
	defaultColor: Color3,
	stats: CarStats,
}

GameConfig.Cars = {
	-- ───────── 초보 (무료 기본 차) ─────────
	{
		id = "starter_kart",
		displayName = "스타터 카트",
		tier = "Beginner",
		currency = "Money",
		price = 0,
		defaultColor = Color3.fromRGB(200, 200, 200),
		stats = { topSpeed = 120, accel = 30, handling = 0.65, grip = 0.7 },
	},
	{
		id = "city_hatch",
		displayName = "시티 해치백",
		tier = "Beginner",
		currency = "Money",
		price = 0,
		defaultColor = Color3.fromRGB(230, 180, 90),
		stats = { topSpeed = 130, accel = 32, handling = 0.6, grip = 0.72 },
	},

	-- ───────── 일반 (게임머니, 800~1500) ─────────
	{
		id = "street_coupe",
		displayName = "스트리트 쿠페",
		tier = "Normal",
		currency = "Money",
		price = 800,
		defaultColor = Color3.fromRGB(60, 120, 220),
		stats = { topSpeed = 160, accel = 40, handling = 0.68, grip = 0.75 },
	},
	{
		id = "rally_runner",
		displayName = "랠리 러너",
		tier = "Normal",
		currency = "Money",
		price = 1100,
		defaultColor = Color3.fromRGB(220, 90, 60),
		stats = { topSpeed = 155, accel = 46, handling = 0.74, grip = 0.82 },
	},
	{
		id = "muscle_v8",
		displayName = "머슬 V8",
		tier = "Normal",
		currency = "Money",
		price = 1500,
		defaultColor = Color3.fromRGB(40, 40, 50),
		stats = { topSpeed = 185, accel = 38, handling = 0.6, grip = 0.7 },
	},

	-- ───────── 고급 (게임머니, 3000~6000) ─────────
	{
		id = "turbo_gt",
		displayName = "터보 GT",
		tier = "Advanced",
		currency = "Money",
		price = 3000,
		defaultColor = Color3.fromRGB(230, 70, 130),
		stats = { topSpeed = 210, accel = 52, handling = 0.76, grip = 0.82 },
	},
	{
		id = "aero_spec",
		displayName = "에어로 스펙",
		tier = "Advanced",
		currency = "Money",
		price = 4500,
		defaultColor = Color3.fromRGB(50, 200, 180),
		stats = { topSpeed = 225, accel = 55, handling = 0.8, grip = 0.85 },
	},
	{
		id = "phantom_x",
		displayName = "팬텀 X",
		tier = "Advanced",
		currency = "Money",
		price = 6000,
		defaultColor = Color3.fromRGB(140, 60, 220),
		stats = { topSpeed = 240, accel = 58, handling = 0.82, grip = 0.86 },
	},

	-- ───────── 전설 (로벅스 전용, 현재 비활성) ─────────
	{
		id = "hyper_aurora",
		displayName = "하이퍼 오로라",
		tier = "Legendary",
		currency = "Robux",
		price = 499, -- 로벅스 가격 (참고용, 실제 결제는 비활성)
		robuxProductId = nil, -- 출시 전 GamePass/DevProduct id 연결
		defaultColor = Color3.fromRGB(255, 215, 0),
		stats = { topSpeed = 280, accel = 70, handling = 0.9, grip = 0.92 },
	},
	{
		id = "void_reaper",
		displayName = "보이드 리퍼",
		tier = "Legendary",
		currency = "Robux",
		price = 799,
		robuxProductId = nil,
		defaultColor = Color3.fromRGB(20, 20, 30),
		stats = { topSpeed = 300, accel = 75, handling = 0.92, grip = 0.94 },
	},
}

-- 빠른 조회를 위한 id → CarDef 맵
GameConfig.CarsById = {} :: { [string]: CarDef }
for _, car in ipairs(GameConfig.Cars) do
	GameConfig.CarsById[car.id] = car
end

-- =====================================================================
-- 경제 / 보상
-- =====================================================================
GameConfig.Economy = {
	startingMoney = 0, -- 신규 플레이어 시작 머니
	defaultCarId = "starter_kart", -- 모두가 기본 보유하는 차

	-- 순위별 보상 (게임머니)
	-- 1등 100 / 2등 60 / 3등 40 / 그 외 완주 20
	rewardsByPlace = {
		[1] = 100,
		[2] = 60,
		[3] = 40,
	},
	finishReward = 20, -- 4등 이하 완주 보상
}

-- =====================================================================
-- 커스터마이징 옵션
-- =====================================================================
GameConfig.Customization = {
	timeLimit = 30, -- 커스터마이징 제한 시간 (초)

	-- 차체 색상 팔레트
	bodyColors = {
		Color3.fromRGB(230, 60, 60),
		Color3.fromRGB(240, 140, 40),
		Color3.fromRGB(245, 215, 60),
		Color3.fromRGB(90, 210, 110),
		Color3.fromRGB(60, 150, 240),
		Color3.fromRGB(150, 90, 230),
		Color3.fromRGB(245, 245, 245),
		Color3.fromRGB(35, 35, 40),
	},

	-- 휠 색상 / 네온 색상
	wheelColors = {
		Color3.fromRGB(20, 20, 20),
		Color3.fromRGB(200, 200, 210),
		Color3.fromRGB(230, 190, 50),
	},
	neonColors = {
		Color3.fromRGB(0, 0, 0), -- 꺼짐
		Color3.fromRGB(0, 200, 255),
		Color3.fromRGB(255, 0, 150),
		Color3.fromRGB(120, 255, 0),
		Color3.fromRGB(255, 120, 0),
	},

	-- 스티커/데칼 (Roblox 데칼 에셋 id — 출시 전 실제 id로 교체)
	stickers = {
		{ id = "none", displayName = "없음", assetId = 0 },
		{ id = "flame", displayName = "불꽃", assetId = 0 },
		{ id = "star", displayName = "별", assetId = 0 },
		{ id = "lightning", displayName = "번개", assetId = 0 },
	},
}

-- =====================================================================
-- 트랙 / 경주
-- =====================================================================
GameConfig.Race = {
	trackCount = 6, -- 테마 트랙 종류 수 (Themes와 1:1 매핑)
	maxPlayers = 8, -- 한 경주 최대 인원
	minPlayers = 1, -- 경주 시작 최소 인원
	lobbyCountdown = 15, -- 대기열에서 시작까지 카운트다운 (초)
	laps = 2, -- 완주 랩 수 (테마에 lapCount가 없을 때의 폴백 기본값)
	avgSpeed = 120, -- 트랙 길이↔랩타임 환산용 평균 주행속도(studs/sec) 기준값
	targetRaceSeconds = 120, -- 트랙별 랩 수 자동 계산 목표 총 경주 시간 (초)
	raceTimeLimit = 240, -- 경주 제한 시간 (초)
	progressBroadcastInterval = 0.15, -- 실시간 순위/미니맵 갱신 주기 (초)
	entryLoadTime = 1.4, -- 경주 진입 로딩 화면 최소 표시 시간(트랙 생성/순간이동 히치 마스킹, 초)
}

-- =====================================================================
-- 부스트 패드 (재미 요소)
-- =====================================================================
GameConfig.Boost = {
	padsPerTrack = 8, -- 트랙당 부스트 패드 수
	speedMultiplier = 2.0, -- 부스터 패드: 속도 2배
	accelMultiplier = 2.0, -- 부스터 패드: 가속 2배
	duration = 2.0, -- 부스터 지속 시간 (초)
	padColor = Color3.fromRGB(80, 230, 255),
}

-- =====================================================================
-- 장애물 (오일 슬릭 — 밟으면 감속)
-- =====================================================================
GameConfig.Obstacles = {
	oilPerTrack = 6, -- 트랙당 오일 슬릭 수
	slowFactor = 0.55, -- 감속 배수 (속도에 곱함)
	slowDuration = 1.4, -- 감속 지속 시간 (초)
	oilColor = Color3.fromRGB(35, 30, 45),
	conesPerTrack = 10, -- 장식용 라바콘 수 (시각적 장애물)
}

-- =====================================================================
-- 아이템 시스템 (마리오카트식)
--   트랙의 "아이템 박스"를 통과하면 랜덤 아이템을 얻고, 사용 키로 발동한다.
--   효과는 부스트와 동일하게 차량 시트의 어트리뷰트(종료 시각)로 전달된다.
-- =====================================================================
GameConfig.Items = {
	boxesPerTrack = 12, -- 트랙당 아이템 박스 수
	boxRespawnTime = 5, -- 획득 후 박스 재생성 시간 (초)
	boxColor = Color3.fromRGB(255, 225, 70),
	boxSize = 5, -- 아이템 박스 한 변 길이

	-- 획득 풀 (가중치 랜덤). id는 아래 정의 키와 일치해야 함
	pool = {
		{ id = "banana", weight = 3 },
		{ id = "rocket", weight = 2 },
		{ id = "balloon", weight = 2 },
	},

	-- 바나나: 뒤에 떨어뜨려 두고, 밟은 차량을 회전(미끄러짐)시킴
	banana = {
		emoji = "🍌",
		displayName = "바나나",
		spinDuration = 1.6, -- 밟으면 빙글빙글 도는 시간 (초)
		dropBackOffset = 9, -- 차 뒤로 떨어뜨리는 거리 (스터드)
		armDelay = 0.5, -- 투하 직후 본인 면역 시간 (초)
		life = 30, -- 자동 소멸 시간 (초)
		color = Color3.fromRGB(240, 220, 40),
	},

	-- 로켓: 사용 시 잠깐 엄청 빠르게 가속
	rocket = {
		emoji = "🚀",
		displayName = "로켓",
		speedMultiplier = 3.0, -- 속도 배수 (엄청 빠름)
		accelMultiplier = 3.0,
		duration = 2.2, -- 지속 시간 (초)
	},

	-- 물풍선: 앞쪽 가까운 상대에게 던져 3초간 가둠
	balloon = {
		emoji = "💧",
		displayName = "물풍선",
		freezeDuration = 3.0, -- 맞으면 갇히는 시간 (초)
		range = 140, -- 사정거리 (스터드)
		coneDot = 0.5, -- 전방 원뿔 정렬도(0~1, 클수록 정면만)
		color = Color3.fromRGB(90, 190, 255),
	},
}

-- =====================================================================
-- 테마 트랙 (사탕/과자/동물/바다/우주/용암 나라)
-- =====================================================================
-- 각 트랙은 고유 테마를 가진다: 도로/난간/부스트/아이템박스 색, 조명 분위기,
-- 테마 장식 소품(props), 그리고 목표 한 바퀴 시간(targetLapSeconds).
-- TrackGenerator가 index로 테마를 1:1 선택해 길이/색/장식/조명을 적용하고,
-- 랩 수는 targetLapSeconds로부터 "총 ~2분" 목표에 맞춰 자동 계산한다.
--   props: TrackGenerator의 PROP_BUILDERS 키. 트랙 가장자리에 번갈아 배치된다.
--   nodeCount: 루프 제어점 수(클수록 굴곡이 많아 모양이 다양해짐).
GameConfig.Themes = {
	-- ───────── 1. 사탕나라 (짧음 ~22초) ─────────
	{
		id = "candy",
		displayName = "사탕나라 🍭",
		emoji = "🍭",
		targetLapSeconds = 22,
		nodeCount = 16,
		road = Color3.fromRGB(255, 150, 185),
		roadMaterial = Enum.Material.SmoothPlastic,
		wall = Color3.fromRGB(235, 110, 165),
		railLeft = Color3.fromRGB(255, 90, 140),
		railRight = Color3.fromRGB(255, 240, 248),
		lane = Color3.fromRGB(255, 255, 255),
		edge = Color3.fromRGB(255, 235, 245),
		boostPad = Color3.fromRGB(255, 220, 60),
		itemBox = Color3.fromRGB(190, 100, 230),
		oil = Color3.fromRGB(150, 70, 110),
		decorA = Color3.fromRGB(135, 206, 250),
		decorB = Color3.fromRGB(255, 150, 120),
		props = { "lollipop", "donut", "cake" },
		lighting = {
			clockTime = 14,
			brightness = 2.4,
			ambient = Color3.fromRGB(120, 95, 110),
			outdoor = Color3.fromRGB(205, 170, 190),
			fog = Color3.fromRGB(255, 225, 240),
			fogStart = 250,
			fogEnd = 2200,
		},
	},
	-- ───────── 2. 과자나라 (짧음 ~25초) ─────────
	{
		id = "snack",
		displayName = "과자나라 🍪",
		emoji = "🍪",
		targetLapSeconds = 25,
		nodeCount = 14,
		road = Color3.fromRGB(120, 80, 45),
		roadMaterial = Enum.Material.Sand,
		wall = Color3.fromRGB(160, 110, 65),
		railLeft = Color3.fromRGB(89, 47, 19),
		railRight = Color3.fromRGB(255, 235, 200),
		lane = Color3.fromRGB(255, 228, 196),
		edge = Color3.fromRGB(255, 240, 215),
		boostPad = Color3.fromRGB(255, 195, 20),
		itemBox = Color3.fromRGB(255, 110, 150),
		oil = Color3.fromRGB(70, 45, 25),
		decorA = Color3.fromRGB(255, 245, 220),
		decorB = Color3.fromRGB(120, 70, 35),
		props = { "cookie", "icecream", "donut" },
		lighting = {
			clockTime = 15,
			brightness = 2.3,
			ambient = Color3.fromRGB(120, 100, 75),
			outdoor = Color3.fromRGB(205, 185, 150),
			fog = Color3.fromRGB(255, 238, 205),
			fogStart = 250,
			fogEnd = 2000,
		},
	},
	-- ───────── 3. 동물나라 (중간 ~28초) ─────────
	{
		id = "animal",
		displayName = "동물나라 🐾",
		emoji = "🐾",
		targetLapSeconds = 28,
		nodeCount = 18,
		road = Color3.fromRGB(170, 140, 95),
		roadMaterial = Enum.Material.Ground,
		wall = Color3.fromRGB(120, 80, 40),
		railLeft = Color3.fromRGB(95, 60, 30),
		railRight = Color3.fromRGB(235, 220, 180),
		lane = Color3.fromRGB(255, 240, 170),
		edge = Color3.fromRGB(240, 235, 210),
		boostPad = Color3.fromRGB(90, 220, 60),
		itemBox = Color3.fromRGB(255, 165, 35),
		oil = Color3.fromRGB(70, 55, 30),
		decorA = Color3.fromRGB(60, 165, 60),
		decorB = Color3.fromRGB(255, 215, 45),
		props = { "tree", "sunflower", "mushroom" },
		lighting = {
			clockTime = 13,
			brightness = 2.8,
			ambient = Color3.fromRGB(120, 140, 110),
			outdoor = Color3.fromRGB(180, 200, 170),
			fog = Color3.fromRGB(210, 235, 200),
			fogStart = 350,
			fogEnd = 3000,
		},
	},
	-- ───────── 4. 바다나라 (긺 ~32초) ─────────
	{
		id = "sea",
		displayName = "바다나라 🐠",
		emoji = "🐠",
		targetLapSeconds = 32,
		nodeCount = 16,
		road = Color3.fromRGB(30, 80, 120),
		roadMaterial = Enum.Material.SmoothPlastic,
		wall = Color3.fromRGB(40, 110, 150),
		railLeft = Color3.fromRGB(255, 110, 75),
		railRight = Color3.fromRGB(150, 235, 255),
		lane = Color3.fromRGB(120, 230, 255),
		edge = Color3.fromRGB(190, 240, 255),
		boostPad = Color3.fromRGB(255, 225, 60),
		itemBox = Color3.fromRGB(190, 235, 255),
		oil = Color3.fromRGB(20, 50, 80),
		decorA = Color3.fromRGB(255, 110, 80),
		decorB = Color3.fromRGB(0, 200, 175),
		props = { "coral", "seaweed", "starfish" },
		lighting = {
			clockTime = 14,
			brightness = 1.7,
			ambient = Color3.fromRGB(20, 55, 95),
			outdoor = Color3.fromRGB(40, 90, 140),
			fog = Color3.fromRGB(15, 80, 150),
			fogStart = 60,
			fogEnd = 750,
		},
	},
	-- ───────── 5. 우주나라 (긺 ~36초) ─────────
	{
		id = "space",
		displayName = "우주나라 🚀",
		emoji = "🚀",
		targetLapSeconds = 36,
		nodeCount = 14,
		road = Color3.fromRGB(28, 26, 55),
		roadMaterial = Enum.Material.Neon,
		wall = Color3.fromRGB(60, 25, 100),
		railLeft = Color3.fromRGB(0, 190, 255),
		railRight = Color3.fromRGB(180, 90, 255),
		lane = Color3.fromRGB(120, 200, 255),
		edge = Color3.fromRGB(150, 170, 255),
		boostPad = Color3.fromRGB(255, 215, 0),
		itemBox = Color3.fromRGB(170, 60, 255),
		oil = Color3.fromRGB(15, 12, 35),
		decorA = Color3.fromRGB(220, 230, 255),
		decorB = Color3.fromRGB(210, 80, 40),
		props = { "rocket", "planet", "star" },
		lighting = {
			clockTime = 0,
			brightness = 1.1,
			ambient = Color3.fromRGB(14, 14, 34),
			outdoor = Color3.fromRGB(22, 22, 48),
			fog = Color3.fromRGB(6, 6, 20),
			fogStart = 200,
			fogEnd = 1800,
		},
	},
	-- ───────── 6. 용암나라 (긺 ~40초) ─────────
	{
		id = "lava",
		displayName = "용암나라 🌋",
		emoji = "🌋",
		targetLapSeconds = 40,
		nodeCount = 20,
		road = Color3.fromRGB(40, 32, 28),
		roadMaterial = Enum.Material.Slate,
		wall = Color3.fromRGB(55, 38, 28),
		railLeft = Color3.fromRGB(255, 90, 0),
		railRight = Color3.fromRGB(255, 170, 40),
		lane = Color3.fromRGB(255, 120, 20),
		edge = Color3.fromRGB(120, 70, 45),
		boostPad = Color3.fromRGB(255, 150, 0),
		itemBox = Color3.fromRGB(255, 205, 0),
		oil = Color3.fromRGB(20, 15, 12),
		decorA = Color3.fromRGB(225, 60, 0),
		decorB = Color3.fromRGB(55, 40, 30),
		props = { "rock", "lavapillar", "volcano" },
		lighting = {
			clockTime = 19,
			brightness = 1.5,
			ambient = Color3.fromRGB(65, 22, 12),
			outdoor = Color3.fromRGB(115, 50, 28),
			fog = Color3.fromRGB(125, 42, 16),
			fogStart = 90,
			fogEnd = 850,
		},
	},
}

-- =====================================================================
-- AI 봇 (빈 자리 채우기)
-- =====================================================================
-- 실제 플레이어가 maxPlayers보다 적으면 나머지를 AI 봇으로 채워 항상 경주가 성립한다.
-- 봇은 키네매틱(앵커 후 트랙 경로 추종)으로 움직이며 서로/플레이어와 충돌하지 않는다.
-- 난이도 "중간": 사람이 충분히 이길 수 있는 속도 + 약한 고무줄(경기 접전 유지).
GameConfig.Bots = {
	enabled = true,
	difficulty = "medium",
	carId = "city_hatch", -- 봇이 모는 차(외형 전용, 주행은 키네매틱)
	-- 난이도 "중간": 고무줄 기준은 "사람 선두"라 사람이 뒤처지면 봇도 느려져 충분히 이길 수 있다.
	baseSpeed = 78, -- 사람과 진행도가 같을 때의 기본 속도(studs/sec)
	speedVariance = 8, -- 봇별 고정 속도 편차(±)
	rubberbandGain = 3.0, -- 사람 선두와의 진행 차이(체크포인트)당 속도 보정
	rubberbandMin = -16, -- 사람보다 앞설 때 최대 감속(사람이 따라잡게)
	rubberbandMax = 24, -- 사람보다 뒤처질 때 최대 가속(접전 유지)
	minSpeed = 55,
	maxSpeed = 125,
	names = { "번개", "초코", "별이", "토토", "쌩쌩", "구름", "단비", "뭉치", "하트", "코코" },
	bodyColors = {
		{ 255, 95, 95 },
		{ 90, 160, 255 },
		{ 95, 210, 130 },
		{ 255, 200, 60 },
		{ 200, 120, 255 },
		{ 255, 140, 60 },
		{ 120, 220, 220 },
		{ 245, 120, 180 },
	},
}

-- =====================================================================
-- 리더보드 (최고 기록)
-- =====================================================================
GameConfig.Leaderboard = {
	topCount = 10, -- 글로벌 순위표 표시 인원
	cacheSeconds = 60, -- 글로벌 순위 캐시 갱신 주기 (초)
}

-- =====================================================================
-- 오디오 (엔진 사운드 등)
-- =====================================================================
-- engineSoundIds: 루프되는 자동차 엔진 사운드 후보 목록(우선순위 순, 숫자 id).
--   서버가 각 차량에 3D 위치 사운드로 부착하고, 클라이언트가 속도에 따라
--   재생속도(피치)/볼륨을 조절해 RPM 느낌을 냅니다.
--   특정 에셋이 모더레이션/삭제로 로드 실패할 수 있으므로, 클라이언트가
--   목록을 순회하며 "실제로 로드되는 첫 id"를 자동 선택합니다.
--   소리가 안 나면 여기에 동작하는 엔진 루프 에셋 id를 맨 앞에 추가하세요.
GameConfig.Audio = {
	engineSoundIds = { 7127584758, 1204868302, 133313356, 634151277 }, -- 엔진 루프 후보(우선순위 순)
	idleVolume = 0.35, -- 정지/공회전 볼륨
	maxVolume = 0.9, -- 최고속 볼륨
	idlePlaybackSpeed = 0.7, -- 공회전 피치
	maxPlaybackSpeed = 2.1, -- 최고속 피치
	boostPitchBonus = 0.25, -- 부스트 시 추가 피치
	rollOffMinDistance = 12, -- 이 거리 안에서는 최대 볼륨
	rollOffMaxDistance = 240, -- 이 거리 밖에서는 안 들림
}

-- =====================================================================
-- 배경음악 (BGM) — 라운지 / 레이스
-- =====================================================================
-- 엔진 사운드와 동일한 "후보 id 목록" 방식: 클라이언트(MusicController)가 목록을 순회하며
-- "실제로 로드되는 첫 id"를 골라 루프 재생한다. 경주 시작/종료에 맞춰 곡을 전환한다.
-- ⚠️ Roblox 오디오 권한 정책상 임의 id가 안 나올 수 있다. 소리가 안 들리면:
--    Studio → 도구상자(Toolbox) → 오디오 → "racing"/"electronic"/"chiptune" 검색
--    → 마음에 드는 곡을 게임에 넣고(자동으로 사용 권한 부여됨) id를 복사해 아래 맨 앞에 추가.
GameConfig.Music = {
	enabled = true,
	volume = 0.28, -- BGM 볼륨(엔진음/효과음을 덮지 않게 적당히)
	fadeTime = 0.8, -- 곡 전환 시 페이드(초)
	loungeIds = { 1837879082, 1838457617, 1840221870 }, -- 라운지(대기) 음악 후보
	raceIds = { 1841647093, 1836965181, 1842160928 }, -- 레이스(주행) 음악 후보(빠른 템포)
}

-- =====================================================================
-- 속도감 연출 (SpeedFX) — 클라이언트
-- =====================================================================
-- 가속/고속/부스트 시 화면을 "뒤틀어" 속도감을 극대화한다(전부 클라 후처리/카메라, 에셋 불필요).
--  • FOV 워프: 빠를수록·가속할수록 시야가 넓어져 빨려들어가는 느낌
--  • 모션블러(BlurEffect): 공간이 흐려지는 워프감
--  • 카메라 흔들림: 고속/부스트일수록 강하게
--  • 화면 가장자리 비네팅: 터널을 통과하는 느낌
--  • 부스트 순간: FOV 펀치 + 색보정 플래시 + whoosh 효과음 + 엔진 굉음
GameConfig.SpeedFX = {
	enabled = true,
	baseFov = 70, -- 기본 시야각(Roblox 기본값)
	maxFovAdd = 18, -- 최고속에서 추가되는 FOV(70→88)
	accelFovAdd = 9, -- "가속 중"일 때 추가되는 FOV(공간 뒤틀림 강조)
	boostFovPunch = 12, -- 부스트 순간 FOV 펀치(최대 ~100)
	blurMax = 10, -- 최고속 모션블러 크기
	blurBoostExtra = 12, -- 부스트 시 추가 모션블러
	shakeMax = 0.22, -- 최고속 카메라 흔들림(studs)
	shakeBoostExtra = 0.45, -- 부스트 시 추가 흔들림
	vignetteMax = 0.42, -- 최고속 비네팅 진하기(0~1)
	vignetteBoostExtra = 0.18, -- 부스트 시 추가 비네팅
	smooth = 8, -- 효과 추종 속도(클수록 즉각적)
	-- 부스트 whoosh 효과음 후보(엔진음과 동일하게 "로드되는 첫 id" 선택, 없으면 무음).
	-- 소리가 약하면 도구상자 → 오디오에서 "whoosh"/"swoosh"/"boost" 찾아 맨 앞에 추가.
	whooshIds = { 9116367462, 5801257793, 9125640571 },
}

-- =====================================================================
-- 로비 / 장식 (LoungeBuilder)
-- =====================================================================
-- 모든 좌표는 LOUNGE_ORIGIN(0,0,3000) 기준 상대 오프셋입니다.
-- 장식이 많아 Studio 반복 테스트가 무거우면 showDecorations=false로 끄세요.
GameConfig.Lobby = {
	showDecorations = true, -- 장식 일괄 on/off (false면 기존 최소 구성으로 경량화)
	carSelectPadOffset = Vector3.new(-35, 1.5, 35), -- 차량 선택 패드 위치
	queuePadOffset = Vector3.new(35, 1.5, 35), -- 경주 참가 패드 위치 (기존 (40,1.5,0) 대체)
	grandstandSteps = 4, -- 관중석 계단 수 (벽 침범 방지: far edge < 78 유지)
	showcaseCarId = "turbo_gt", -- 차량 선택 패드 위에 띄울 전시 차량 id
}

return GameConfig
