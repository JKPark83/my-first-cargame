# 게임플레이 폴리싱 — 차량 · 트랙 · 경주 UI · 엔진 사운드

> 작성일: 2026-06-20
> 범위: 실제 플레이 피드백 4건 반영 (차량 외형 / 트랙 자연스러움 / 경주 중 버튼 노출 / 엔진 사운드)

플레이 테스트에서 나온 4가지 문제를 수정했습니다. 아래는 각 문제의 원인과 해결,
변경된 파일, 그리고 직접 값을 조정하는 방법입니다.

---

## 1. 차량이 "차"답게 보이도록 (CarSpawner)

**문제** — 차량이 단순한 박스 + 바퀴처럼 보였고, 특히 바퀴 방향이 어색했다.

**원인** — `buildWheels`에서 원통(Cylinder) 바퀴에 `CFrame.Angles(0, 0, math.rad(90))`를
적용해 바퀴 축이 수직으로 서 있었다. (Roblox Cylinder는 로컬 X축으로 뻗으므로,
회전을 빼야 원형 면이 좌우(±X)를 향하는 정상적인 바퀴가 된다.)

**해결** — `src/ServerScriptService/CarSpawner.luau`
- 바퀴: 회전 제거 → 타이어(Cylinder) + 림 허브캡을 차체 좌우에 배치.
- VehicleSeat(하부 바디) 위에 장식 파트를 **용접(WeldConstraint)** 으로 부착:
  - 후드(앞) · 트렁크 데크(뒤) · 앞/뒤 범퍼
  - 운전석 뒤 캐빈 / 롤후프, 기울인 앞유리(Glass)
  - 스포일러 + 지지대, 사이드 도어 패널
  - 헤드라이트(앞, 따뜻한 흰 Neon) · 테일라이트(뒤, 빨강 Neon)
- 모든 장식 파트는 `CanCollide=false`, `Massless=true`로 두어 주행 물리에 영향을 주지 않음.
- 전진 방향(LookVector = -Z) 기준으로 헤드라이트는 앞(-Z), 스포일러/테일라이트/번호판은 뒤(+Z).
- 기존 커스터마이징(차체 색 · 휠 색 · 네온 · 번호판 · 스티커)은 그대로 동작.

---

## 2. 트랙을 더 자연스럽게 (TrackGenerator)

**문제** — 트랙 곡선이 들쭉날쭉하고, 번쩍이는 네온 투명 벽이 부자연스러웠다.

**해결** — `src/ServerScriptService/TrackGenerator.luau`
- 노드 반경 지터를 좁혀(`0.82 ~ 1.16`) 급격한 굴곡을 줄임.
- Catmull-Rom 스플라인 샘플을 세그먼트당 14로 늘려 곡선을 매끄럽게.
- 네온 투명 벽 → **솔리드 가드레일**(SmoothPlastic) + 좌/우 색상 레일 캡(빨강/흰색).
- 노면에 차선 마킹 추가: 중앙 노란 점선 + 양쪽 흰색 가장자리 라인.
- 마킹/레일 캡은 `CanCollide=false`(주행 방해 없음), 가드레일은 충돌 ON으로 코스 이탈 방지.

> **호환성 주의** — `TrackInfo` 반환 구조(체크포인트 · 스폰 CFrame · 부스트패드 · 오일 ·
> 미니맵 경로 · bounds)는 변경하지 않았습니다. `RaceManager`가 의존하므로 그대로 유지.

---

## 3. 경주 중 라운지 버튼 숨김 (UIController)

**문제** — 경주에 참가한 뒤에도 차고 / 경주참가 / 순위표 버튼이 계속 보였다.

**원인** — `RaceStateChanged` 핸들러가 패널만 닫고 라운지 버튼 자체는 숨기지 않았다.

**해결** — `src/StarterPlayer/StarterPlayerScripts/UIController.client.luau`
- `setLobbyButtonsVisible(visible)` 헬퍼 추가 — 차고/경주참가/순위표 버튼을 한 번에 토글.
- `state == "Racing"` → 라운지 버튼·패널 모두 숨김.
- 그 외(Idle 등) → 버튼 복원 + 대기열/미니맵/순위 HUD 초기화.

---

## 4. 엔진 사운드 (CarSpawner + CarController + GameConfig)

**문제** — 차량이 움직여도 엔진 소리가 나지 않았다.

**해결**
- `src/ServerScriptService/CarSpawner.luau` — 각 차량 시트에 3D 위치 루프 사운드(`Engine`) 부착.
- `src/StarterPlayer/StarterPlayerScripts/CarController.client.luau` — 속도에 비례해
  `PlaybackSpeed`(피치)와 `Volume`을 부드럽게 변조 → RPM 느낌. 부스트 시 피치 가산.
- `src/ReplicatedStorage/GameConfig.luau` — `GameConfig.Audio` 설정 블록.

**견고성(중요)** — 오디오 에셋은 모더레이션/삭제로 로드 실패할 수 있어, 단일 ID 대신
**후보 ID 목록**을 사용합니다. 오디오 로드는 클라이언트에서 일어나므로,
`CarController`가 차 탑승 시 후보를 순회하며 **실제로 로드되는 첫 ID를 자동 선택**합니다.
하나가 죽어도 다른 후보로 소리가 나도록 했습니다.

```lua
-- GameConfig.luau
GameConfig.Audio = {
    engineSoundIds = { 7127584758, 1204868302, 133313356, 634151277 }, -- 우선순위 순
    idleVolume = 0.35,        maxVolume = 0.9,
    idlePlaybackSpeed = 0.7,  maxPlaybackSpeed = 2.1,
    boostPitchBonus = 0.25,
    rollOffMinDistance = 12,  rollOffMaxDistance = 240,
}
```

소리가 마음에 안 들거나 안 나면, 동작하는 엔진 루프 에셋 ID를 `engineSoundIds` **맨 앞**에 추가하세요.

---

## 빌드 / 실행

```bash
# 프로젝트 루트에서 place 파일 빌드
rojo build -o game.rbxlx
# Roblox Studio로 열기 (macOS)
open game.rbxlx
```

> Studio가 이미 같은 파일을 열어둔 상태면 새 빌드가 자동 반영되지 않습니다.
> 현재 place를 닫고(`Cmd+W`) `game.rbxlx`를 다시 여세요.

## 테스트 체크리스트 (편집 화면이 아니라 Play 모드에서)

1. **Play(F5)** 로 실행
2. **경주 참가** → 카운트다운 후 차량 스폰 + 트랙 생성
3. **WASD** 주행 → 엔진 소리(속도↑ 시 피치/볼륨↑), 차량 외형, 매끄러운 트랙 확인
4. 경주 시작 시 **차고/경주참가/순위표 버튼이 사라지는지** 확인
