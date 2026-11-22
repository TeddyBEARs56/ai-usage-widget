# AI 사용량 (Windows)

Windows 1.4.3 은 오른쪽 클릭 메뉴를 정리했다(위는 세션·남은 한도 요약, 아래는 보기·모양·알림·설정 묶음). 1.4.2 는 맥 판과 맞춰 「Claude 보이기」·「ChatGPT 보이기」, 세션 칸을 포함한 칸 순서 6가지, 맥처럼 그린 사용 추이 창(크기 고정)을 더했다. 1.4.1 은 작업 표시줄 간단 모드·세션·칸 접기, 1.4.0 은 한도 알림·사용 추이·모양 설정·새 아이콘. 맥판과 같은 창을 Windows 에서 띄운다. 다른 창 위에 늘 떠 있고, 눌러도 쓰던 프로그램의 초점을 뺏지 않는다. 작업 표시줄 단추로 켜고 끈다. 무엇을 보여 주고 값을 어디서 가져오는지는 [맨 위 README](../README.md).

## 처음 쓰기

1. 저장소 **Releases** 에서 `AIUsage.exe` 를 받는다(파일 하나, .NET 설치 필요 없음).
2. 더블클릭한다. 「Windows의 PC 보호」가 뜨면 **추가 정보 → 실행**(서명하지 않은 개인 프로그램이라 뜬다).
3. 「이 PC에 설치할까요?」 → **예**. `%LOCALAPPDATA%\Programs\AIUsage` 에 들어가고 시작 메뉴에 「AI 사용량」이 생긴다. 작업 표시줄 단추를 오른쪽 클릭 → **작업 표시줄에 고정**.
4. Claude Code 를 쓰는 PC 면 설치 뒤 「상태 표시줄 연결」을 묻는다 → **예**.

**새 버전은 알아서 바뀐다(1.1.0 부터)**: 켠 뒤 1분, 그 뒤 6시간마다 Releases 에 더 높은 Windows 판(`windows-v<버전>`)이 있으면 받아서 바꾸고 다시 띄운다(창이 1~2초 사라졌다 같은 자리에). 설치 폴더에서 켰을 때만 바꾸고, 받은 파일은 SHA-256 과 exe 파일 버전을 확인한다. 바로 확인: 창 오른쪽 클릭 → 「업데이트 확인 (지금 <버전>)」. 끄기: 레지스트리 `HKCU\Software\AIUsage` 에 DWORD `AutoUpdate`=0. 기록: `%USERPROFILE%\.cache\ai-usage\update.log`. 자세한 것은 [맨 위 README](../README.md#자동-업데이트).

1.0.0 을 쓰고 있으면 한 번만 손으로: Releases 에서 새 `AIUsage.exe` 를 받아 실행 → 「설치된 것을 바꿀까요?」 예(먼저 켜져 있는 것은 끈다).

## 켜고 끄기

- **켜기**: 시작 메뉴나 작업 표시줄의 「AI 사용량」
- **끄기**: 작업 표시줄 단추 오른쪽 클릭 → 창 닫기, 또는 창 오른쪽 클릭 → 종료
- **Windows 를 켤 때 자동으로**: 창 오른쪽 클릭 → 「설정」 → 「Windows 시작할 때 자동으로 열기」
- **보일 칸 고르기(1.4.2 부터)**: 창 오른쪽 클릭 → 「보기」 → 「세션」·「Claude」·「ChatGPT」(1.4.2 는 메뉴 맨 위의 「○○ 보이기」). 체크를 끄면 그 칸이 빠지고 창 높이가 줄어든다. 고른 것은 기억하고(레지스트리 `ShowClaude`·`ShowCodex`·`ShowSessions`), Claude·ChatGPT 를 둘 다 끌 수는 없다. 숨긴 칸은 알리지 않고 작업 표시줄 게이지에서도 빠지며, ChatGPT 칸을 끄면 5분마다 codex 를, Claude 칸을 끄면 `claude /usage` 를 띄우지 않는다.
- **칸 순서**: 창 오른쪽 클릭 → 「보기」 → 「칸 순서」. 맨 위에 「지금: 세션 → Claude → ChatGPT」, 그 아래 「○○ 위로」를 누르면 그 칸이 한 칸 올라간다(맨 위 칸은 흐리게, 1.4.3 부터. 1.4.2 는 여섯 가지 순서를 나열, 맥 판과 같은 여섯 가지). 처음엔 「세션 → Claude → ChatGPT」. 고른 순서는 기억한다(레지스트리 `HKCU\Software\AIUsage` 의 `Order`, 예: `sessions,claude,codex`). 1.4.1 이하에서 고른 「ChatGPT → Claude」 등은 세션을 맨 위에 둔 채 이어진다.
- 창을 오른쪽 클릭해 「모양」에서 표시 방식을 고르고, 떠 있는 창이면 배경 투명도·창 크기·글자 크기(각각 한 단계 더 열어 고르고, 지금 값이 오른쪽에 보인다), 작업 표시줄이면 작게·크게를 고른다. 지금 모드에 쓰는 것만 보인다. 선택은 다음 실행에도 유지된다.
- **작업 표시줄에 붙이기**: 창 오른쪽 클릭 → 「모양」 → 「표시 방식」 → 「작업 표시줄 (간단 모드)」. 아래 [작업 표시줄 간단 모드](#작업-표시줄-간단-모드).
- **칸 접기**: 세션·Claude·ChatGPT 칸의 머리줄을 누르면 접히고 다시 누르면 펴진다(오른쪽 끝 ▲/▼, 다음 실행에도 기억 — `FoldSessions`·`FoldClaude`·`FoldCodex`). 「보기」 → 「모두 접기」·「모두 펼치기」로 한 번에. 접은 세션은 머리줄에 「입력 1 · 진행 1 · 완료 2」(0개는 빼고 입력 필요는 주황)만, 접은 Claude·ChatGPT 는 주간 게이지와 남은 % 한 줄만 보인다.

언어: 창 오른쪽 클릭 → 「설정」 → 「언어 (Language)」(처음엔 Windows 표시 언어). 자세한 것은 [맨 위 README](../README.md#언어).

창은 끌어서 옮기고(위치 기억), 오른쪽 두 번 클릭하면 작업 표시줄 간단 모드로 바뀐다(오른쪽 한 번이면 메뉴 — 두 번째 클릭을 기다리느라 0.5초쯤 뒤에 열린다. 새로고침은 메뉴의 「지금 새로고침」). 오른쪽 클릭 메뉴(1.4.3 부터)는 폭을 넓히지 않게 요약만 보인다: 맨 위 「세션」은 이름(길면 「…」)과 상태 — 누르면 그 대화가 열리고, 마우스를 올리면 전체 이름·폴더. 「남은 한도」는 회사마다 한 줄(「Claude 5시간 97% · 주간 15%」, 오른쪽에 확인 시각), 초기화 시각·값의 출처·`/usage`·Codex 서버 확인 시각과 오류는 「자세히」에. 그 아래 지금 새로고침, 사용 추이, 「보기」(보일 칸·모델별 한도·칸 순서·모두 접기/펼치기), 「모양」, 「알림」(한도 알림·모델별 한도도 알림), 「설정」(자동 실행·상태 표시줄 연결·언어·위치 초기화·업데이트 확인), 종료.

## 한도 알림과 사용 추이

창을 오른쪽 클릭해 「알림」 → 「한도 알림」을 켜거나 끈다. 기본값은 켜짐이다. 5시간·주간 등 각 한도에서 처음 10% 이하로 남으면 한 번 알린다. 초기화 시각을 알면 그 시각부터 60분 이내에 확인한 초기화도 한 번 알린다. 초기화 시각을 모르면 첫 알림의 관측 시각에서 창 길이가 지난 뒤 새 관측부터 남은 한도를 다시 판단한다.

1.4.0 부터 「모델별 한도 보이기 (Fable 등)」(1.4.3 부터 「보기」 → 「모델별 한도 (Fable 등)」)는 처음에 켜져 있어 작은 창과 메뉴 상세에 모델별 주간 한도가 표시된다. 「모델별 한도도 알림」은 처음에 꺼져 있다. 「한도 알림」이 켜져 있으면 모델 줄을 숨긴 상태에서도 모델별 알림을 받을 수 있다. 사용 추이와 35일 기록에는 전체 주간 한도만 들어간다.

「사용 추이…」를 열면 현재 계정의 주간 한도를 볼 수 있다. 「이번 주」는 지금까지의 사용률과 예상 소진 시각을, 「지난 4주」는 하루에 쓴 비율을 보여 준다. 흐린 막대는 대략적인 값이며 ↺는 초기화된 날이다. 주간 기록은 `%USERPROFILE%\.cache\ai-usage\history.jsonl`에 35일간 보관한다. 창은 1.4.2 부터 맥 판처럼 어두운 제목 줄(—·✕, ✕ 에 올리면 빨강)과 둥근 모서리로 그리고, 크기는 고정이다(제목 줄을 끌어 옮기고 Esc 로 닫는다).

## 값이 뜨려면

| 값 | 필요한 것 |
|---|---|
| ChatGPT | Codex CLI 로그인. `codex` 를 PATH, npm(`%APPDATA%\npm`), `~\.codex\packages\standalone` 에서 찾는다 |
| Claude | `claude /usage`: Claude Code(또는 Claude 데스크톱 앱이 품은 claude.exe)에게 5분마다, 그리고 Claude Code 가 응답할 때마다 묻는다(모델을 부르지 않음, 자세한 것은 [값의 출처](../README.md#값의-출처두-판-공통)). 그 밖에 Claude Code + 상태 표시줄 연결(메뉴). `~\.claude\settings.json` 의 `statusLine` 을 `AIUsageStatus.exe --statusline` 으로 바꾼다(원래 파일은 `settings.json.bak-날짜`). 연결이 가리키는 `AIUsageStatus.exe` 가 없으면 켤 때 묻지 않고 다시 건다. 또는 Claude 데스크톱 앱의 `plan-usage-history.json` — 요즘 판(Microsoft Store 판 포함)은 `%LOCALAPPDATA%\Claude-Data\claude_<id>\`, 옛 판은 `%APPDATA%\Claude\`(`Claude-Data`·`Claude`·`Claude-3p` 를 `%LOCALAPPDATA%`·`%APPDATA%` 밑에서 모두 찾아 가장 새 기록을 쓴다). 앱을 쓰는 동안 받은 값만, 초기화 시각 없이. 기록이 1시간 넘게 멈췄고 Claude 값도 오래됐으면 오른쪽 클릭 메뉴에 「…Claude 아이콘을 오른쪽 클릭하면 그 뒤 하루 동안 다시 받습니다」가 뜬다(데스크톱 앱은 트레이 아이콘을 오른쪽 클릭한 뒤 24시간 동안만 사용량을 계속 받고, 그 밖에는 앱을 켤 때 한 번만 받는다. 왼쪽 클릭은 창만 연다). 어느 파일을 읽는지는 `AIUsageStatus.exe --print` 로 본다 |

Windows 에는 jq 가 없어서 상태 표시줄은 같이 들어 있는 작은 콘솔 프로그램 `AIUsageStatus.exe` 가 맡는다(창 프로그램으로 하면 실행될 때마다 마우스 커서가 「로딩 중」으로 깜빡인다). 상태 표시줄 모양은 맥과 같은 3줄(저장소·모델·한도)이고 브랜치 표시는 없다.

값만 확인: `%LOCALAPPDATA%\Programs\AIUsage\AIUsageStatus.exe --print`(세션 목록만은 `--sessions`)

## 세션

떠 있는 창에 이 PC 에서 켜 둔 Claude Code·Codex 세션(채팅)을 한 줄씩 보여 준다(3초마다, 맥 판 [세션 목록](../mac/README.md#세션-목록)과 같은 규칙). 처음엔 맨 위, 「칸 순서」로 자리를 바꿀 수 있다(1.4.2 부터). 세션이 없거나 오른쪽 클릭 → 「세션 보이기」를 끄면 칸이 없어진다(`ShowSessions`=0). 이름 앞 점은 도구(주황 Claude, 초록 Codex).

| 표시 | 뜻 | 어떻게 아나 |
|---|---|---|
| 주황 ! 입력 필요 | 권한 묻기 등에서 내 답을 기다림(Claude 만) | `~\.claude\sessions\<pid>.json` 의 `status: waiting` |
| 파랑 ◌ 작업 중 N분 | 답을 만드는 중(고리가 돈다) | Claude `busy`·`shell`, Codex 기록 마지막이 `task_started` |
| 초록 ✓ 작업 완료 N분 전 | 답을 마치고 다음 지시를 기다림 | Claude `idle`, Codex 기록 마지막이 `task_complete` 또는 `turn_aborted`(메뉴에 「(중단됨)」) |

- 순서: 입력 필요 → 작업 중 → 작업 완료, 같은 상태는 최근에 바뀐 것부터. 8개가 넘으면 「외 N개」. 오른쪽 클릭 메뉴에 세션마다 상태와 폴더가 나온다.
- Claude: 터미널 CLI 와 데스크톱 앱 Code 탭 세션 모두(`kind: interactive` 만 — 이 앱이 띄우는 `claude -p "/usage"` 는 빠진다). 이름은 직접 붙인 이름(데스크톱 앱 사이드바 제목·`/rename`), 없으면 Claude 가 붙인 제목, 그것도 없으면 폴더. pid 가 꺼졌거나 다른 프로세스가 다시 쓴 파일(`procStart` 로 가린다)은 건너뛴다. 세션을 닫을 때까지 보인다.
- Codex: 맥 판은 그 기록 파일을 연 codex 프로세스로 도중에 꺼졌는지 보지만, Windows 는 다른 프로세스가 연 파일을 알기 어렵고 Codex 데스크톱 앱이 codex.exe 를 늘 띄워 두므로, 작업 중 표시가 남았는데 기록이 20분 넘게 안 바뀌었거나 codex 가 없으면 중단으로 본다. 이름은 Codex 데스크톱 앱이 붙인 대화 제목(`~.codexsession_index.jsonl` 의 `thread_name`), 없으면(CLI) 작업 폴더. 데스크톱 앱은 대화를 처음 만든 날짜 폴더(예: `sessions6`)에 계속 이어 쓰므로 날짜 폴더가 아니라 최근에 바뀐 기록을 본다. 끝난 작업은 30분 뒤 빠지고, Codex 가 스스로 띄운 하위 작업(검토 등)과 제목 없는 CLI 작업의 같은 폴더 앞 기록은 빠진다.
- 작업 표시줄 간단 모드에서는 게이지를 한 번 누르면 바로 위로 세션 패널이 올라온다. 바깥을 누르거나 Esc, 게이지를 다시 누르면 닫힌다. 입력이 필요한 세션이 있으면 게이지 맨 앞에 주황 「!」가 붙는다.
- 세션 줄을 누르면(손가락 커서) 그 대화를 연다: Claude 데스크톱 앱 Code 탭 세션은 `claude://claude.ai/epitaxy/<hostSessionId>`, Codex 데스크톱 앱 대화는 `codex://threads/<대화 id>` 링크로 그 앱의 그 대화를, 터미널에서 연 세션은 그 프로세스를 띄운 터미널 창을 앞으로 가져온다(Windows Terminal 은 어느 탭인지까지는 못 고른다).
- claude.ai 웹·ChatGPT 앱 안의 대화는 이 PC 에 상태 파일이 없어 보이지 않는다. Claude 쪽 파일은 공식 문서에 없는 형식이라 Claude Code 업데이트로 바뀔 수 있다(모르는 값은 회색 「알 수 없음」).

## 맥판과 다른 점

- 가상 데스크톱을 바꾸면 따라오지 않는다. 작업 보기(⊞+Tab)에서 창을 오른쪽 클릭 → 「모든 데스크톱에 이 창 표시」.
- 배경 투명도를 높이면 창 뒤가 흐림 효과 없이 비친다. 설정을 바꾼 뒤 창이 보이지 않으면 앱을 종료하고 레지스트리 `HKCU\Software\AIUsage`의 `petBackgroundLevel` 값을 지운 뒤 다시 실행한다.

## 작업 표시줄 간단 모드

「표시 방식」을 「작업 표시줄 (간단 모드)」로 고르면 떠 있는 창은 숨고, 작업 표시줄의 알림 영역(^·시계) 바로 왼쪽에 한도마다 동그란 게이지가 가로 한 줄로 붙는다(레지스트리 `HKCU\Software\AIUsage` 의 `DisplayMode`=1, 떠 있는 창은 0).

- 테두리 길이가 남은 비율, 가운데 숫자가 남은 %. 색은 떠 있는 창과 같은 기준(50% 이상 초록, 20% 이상 노랑, 그 아래 빨강). 순서와 모델별 한도(Fable 등)는 「칸 순서」·「모델별 한도 보이기」를 따른다.
- 마우스를 올리면 「Claude · 주간 26% 남음 · 초기화 …」 풍선이 뜬다. 한 번 클릭하면 [세션](#세션) 패널이 열리고 다시 누르면 닫힌다. 오른쪽 클릭하면 떠 있는 창과 같은 메뉴, 오른쪽 두 번 클릭하면 떠 있는 창으로 돌아간다.
- 크기는 「모양」 → 「작업 표시줄 크기」에서 「크게」(원 지름이 작업 표시줄 높이에서 위아래 3픽셀씩 뺀 만큼, 기본)와 「작게」(그 75%) 중에서 고른다(`TaskbarSize`=100·75). 떠 있는 창의 「창 크기」·「글자 크기」와는 따로다. 작업 표시줄이 밝은 모드면 글자·테두리를 어둡게 그린다.
- Windows 11 에는 작업 표시줄에 창을 넣는 공식 방법(DeskBand)이 없어서 작업 표시줄 창(`Shell_TrayWnd`)의 자식 창으로 붙인다. 그래서 작업 표시줄과 함께 숨고(자동 숨김·전체 화면) 함께 움직인다. 1초마다 알림 영역 폭이 바뀌었는지 보고 자리를 다시 잡고, 탐색기가 다시 켜지면 새 작업 표시줄에 다시 붙는다.
- 주 화면의 작업 표시줄에만 붙는다. 붙일 수 없으면(작업 표시줄을 못 찾음, 앱 아이콘과 알림 영역 사이에 자리가 없음, 세로 작업 표시줄, 그리지 못함) 3초 뒤 떠 있는 창을 대신 보이고 메뉴 맨 위에 이유를 쓴다. 붙음·못 붙임이 바뀔 때마다 `~/.cache/ai-usage/taskbar.log` 에 한 줄.
- 투명한 자식 창은 Windows 8 이상 기능이라 `AIUsage/app.manifest` 에 Windows 10·11 지원(`supportedOS`)을 적어 두었다.

## 파일

| 파일 | 내용 |
|---|---|
| `Shared/Usage.cs` | 값 읽기·상태 표시줄 처리(맥판과 같은 규칙, 맥에서도 돌려 볼 수 있음) |
| `Shared/Sessions.cs` | 세션(Claude Code·Codex 채팅) 상태 읽기 |
| `AIUsage/` | 창 프로그램(WinForms). `MainForm.cs` 화면, `TaskbarGauge.cs` 작업 표시줄 간단 모드, `SessionPopup.cs` 세션 줄·패널, `Setup.cs` 설치·자동 실행·연결, `Updater.cs` 자동 업데이트 |
| `AIUsageStatus/` | 상태 표시줄 콘솔 프로그램. 창 프로그램 안에 들어가 있다가 설치할 때 꺼내진다 |
| `build.sh` | 맥에서 빌드 → `dist/AIUsage.exe` |
| `build.ps1` · `release.ps1` | Windows 에서 빌드 · 새 판 올리기(`build.sh`·`release.sh windows` 와 같은 일) |
| `AIUsage/AIUsage.ico` | 아이콘(`icon/make-icons.sh` 로 만든다) |

## 다시 만들기(맥)

```bash
brew install dotnet   # 처음 한 번
zsh windows/build.sh
```

공통 코드를 맥에서 돌려 보기: `dotnet run --project windows/AIUsageStatus -- --print`

`AIUsageStatus --trend-json --now <ISO 시각>`으로 현재 계정의 주간·28일 계산을 출력한다. 임시 `AIUSAGE_HOME`에서 `AIUsageStatus --record-once`는 로컬 값으로 추가한 주간 기록 줄 수를 출력한다. `AIUsageStatus --test-alerts 입력.json`을 실행하면 실제 알림 없이 재시작과 초기화를 시험할 수 있다. [공통 시험 입력 예시](../mac/README.md#추이와-알림-시험)

임시 `AIUSAGE_HOME`에서 `AIUsageStatus --alerts-once --now <ISO 시각> --limit-alerts 1 --model-alerts 0`을 실행하면 로컬 원천을 한 번 읽고 실제로 보낼 후보를 JSON 배열로 출력한다. 두 옵션은 각각 0 또는 1이며 기본값은 전체 켬·모델 끔이다. 같은 홈을 다시 쓰면 저장된 알림 상태에서 이어진다. 외부 CLI 호출이나 풍선 전송은 없다.

저장소 루트에서 `python3 windows/tests/model_limits.py <AIUsageStatus 실행 파일 또는 DLL 경로>`로 모델별 알림과 기록 분리 시험을 실행한다. 시험마다 임시 홈을 만들고 종료 후 지운다.

`history.jsonl` v1의 `source`는 Claude 상태 표시줄 `claude-session`, 데스크톱 기록 `claude-desktop`, 직접 조회 `claude-usage`, Codex 기록 `codex-rollout`, Codex 서버 `codex-server` 중 하나다. 모델별 값은 `usage-command.json`과 변경 로그 `claude-usage.log`에서 확인할 수 있다.

## 다시 만들기·올리기(Windows)

```powershell
winget install Microsoft.DotNet.SDK.10   # 처음 한 번
powershell -ExecutionPolicy Bypass -File windows\build.ps1
```

새 판 올리기는 [자동 업데이트](../README.md#자동-업데이트) 규칙 그대로다(두 csproj 의 `<Version>` 을 올려 커밋·push 한 뒤). `gh`(GitHub CLI)가 필요하다: `winget install GitHub.cli` → `gh auth login`.

```powershell
powershell -ExecutionPolicy Bypass -File windows\release.ps1 "바뀐 점"
```

## 지우기

1. 창 오른쪽 클릭 → 자동 실행 끄기 → 종료.
2. `%LOCALAPPDATA%\Programs\AIUsage` 폴더(받아 둔 새 판 `update\` 포함), 시작 메뉴 `AI 사용량` 바로 가기, `%USERPROFILE%\.cache\ai-usage` 를 지운다.
3. Claude Code 를 연결했으면 `~\.claude\settings.json` 을 `.bak-날짜` 파일로 되돌린다.
4. (선택) 레지스트리 `HKCU\Software\AIUsage`.
