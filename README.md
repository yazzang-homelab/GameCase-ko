# GameCase 한글판

> IPA와 데이터 팩을 가져오고, 열면 바로 플레이합니다.

[Tiaoge-tou/GameCase](https://github.com/Tiaoge-tou/GameCase)의 화면 문구를 모두 한국어로 옮긴 포크입니다.

GameCase는 [nxnative](https://github.com/seedds/nxnative)로 만든 이식 게임을 한 앱 안에 모아 두고 실행하는 iPhone·iPad용 게임 보관함입니다. [LiveContainer](https://github.com/LiveContainer/LiveContainer)를 바탕으로 만들어졌고, 탈옥 없이 사이드로드로 설치합니다.

**게임은 들어 있지 않습니다.** 게임 IPA와 데이터 팩(`romfs.img`)은 본인이 가진 게임에서 직접 만들어 준비해야 합니다.

## 원본과 다른 점

현재 기준은 원본 **1.0.17**입니다.

| 항목 | 원본 | 한글판 |
|---|---|---|
| 한국어 문구 | 637개 중 299개. 나머지는 한국어 기기에서 중국어로 나옵니다 | 637개 전부 |
| 게임 중 상단 퀵바의 돌아가기 버튼 | Library | 보관함 |
| 게임 안 키보드 | 등록해 둔 키보드가 하나만 보여 한/영 전환 키가 나오지 않습니다 | 시스템에 등록한 키보드를 그대로 씁니다 ([확인 상태](#확인한-것과-확인하지-못한-것)) |

그 밖의 동작은 원본과 같습니다. 바꾼 내용은 [커밋 기록](https://github.com/yazzang-homelab/GameCase-ko/compare/v1.0.17...ko)에서 한 줄씩 볼 수 있습니다.

## 받기

[Releases](https://github.com/yazzang-homelab/GameCase-ko/releases)에서 `GameCase-ko.ipa`를 받습니다. 서명되지 않은 파일이므로 그대로는 설치되지 않습니다.

## 설치

1. **개발 인증서(Development Certificate)로 서명해 설치합니다.**
   - 무료 Apple ID: [SideStore](https://sidestore.io)나 [AltStore](https://altstore.io)로 설치하면 개발 인증서로 서명됩니다.
   - 유료 개발자 계정: 본인 팀의 개발 인증서와 프로비저닝 프로파일로 서명합니다.
   - 시중에서 파는 배포 인증서(Distribution)나 기업 인증서(Enterprise)로 서명하면 앱이 "개발 인증서로 서명되지 않았습니다"라고 알리고 게임이 실행되지 않습니다.
2. GameCase의 **설정**에서 앱을 서명한 것과 **같은 팀**의 인증서를 가져옵니다. 이렇게 하면 JIT 없이 게임을 실행할 수 있습니다. 팀이 다르면 가져오기가 거부됩니다.
3. 게임 IPA와 그 게임의 데이터 팩(`romfs.img`)을 가져옵니다.
4. 커버를 눌러 실행합니다.

iOS·iPadOS 15.0 이상이 필요합니다.

### 원본을 이미 쓰고 있는 경우

번들 ID는 원본과 같은 `com.tiaoge.gamecase`입니다. 지금 쓰는 것과 같은 번들 ID, 같은 인증서로 서명해 덮어 설치하면 가져온 게임과 데이터 팩, 세이브가 그대로 남습니다.

### 알아 둘 점

- **서명 식별자는 인증서의 App ID와 맞아야 합니다.** 맞지 않으면 파일 선택 창이 반응하지 않거나 데이터 팩을 고를 수 없고, 인증서 가져오기가 실패합니다.
- **데이터 팩을 직접 넣을 수도 있습니다.** 파일 앱에서 `GameCase → Data → Application → <게임 이름> → Documents` 폴더에 `romfs.img`를 넣습니다. 게임 폴더 바로 아래가 아니라 그 안의 `Documents`입니다.
- **한 번에 한 게임만 실행됩니다.** 게임 중 화면 위쪽의 퀵바에서 **보관함**을 누르면 게임이 끝나고 보관함으로 돌아갑니다.

원본의 기능 소개와 SideStore 내장판 안내는 [원본 README(중국어)](README.zh-Hans.md)에 있습니다.

## 한글화 범위

**한국어로 나오는 것**

- GameCase의 모든 화면: 보관함, 게임 설정, 데이터 팩·커버·모드·치트 가져오기, 클라우드 세이브, 컨트롤러, 인증서, 앱 설정, 알림 창
- 게임 중 퀵바의 **보관함** 버튼

**한국어가 아닌 것**

- 게임 자체의 화면. 게임 언어는 각 게임이 정합니다.
- SideStore 내장판(`GameCase+SideStore.ipa`)의 SideStore 화면. 원본 빌드가 이 화면에 중국어만 넣기 때문에 이 저장소에서는 SideStore 내장판을 내지 않습니다.
- iOS **설정** 앱에 나오는 GameCase 항목(영어)
- 개발자용 로그(중국어·영어)

**문체**

새로 옮긴 338개는 하십시오체로 통일했습니다. 원본에 이미 있던 299개는 손대지 않았으므로 "~해주세요" 같은 말투가 섞여 있습니다.

## 확인한 것과 확인하지 못한 것

확인 기기는 iPad Pro 11(M2), iPadOS 26.5입니다.

| 항목 | 상태 |
|---|---|
| 한국어 문구 637개가 모두 있고 형식 지정자(`%@`, `%lld` 등)가 영어 원문과 일치 | 빌드할 때마다 자동 검사 |
| 설치, 게임 가져오기, 게임 실행 | 확인 |
| 게임 안에서 한/영 전환 | **확인하지 못했습니다.** 원인은 소스 분석으로 짚었습니다. 게임이 뜬 뒤에는 시스템 전역 설정까지 게임 폴더 쪽으로 돌려져, 게임에서는 등록된 키보드 목록이 비어 보입니다. 전역 설정만 시스템에서 읽도록 한 줄을 고쳤지만, 실제 입력창에서 전환 키가 나오는지는 아직 보지 못했습니다 |

키보드 수정이 문제를 일으키면 [이 커밋](https://github.com/yazzang-homelab/GameCase-ko/commits/ko/LiveContainer/Tweaks/NSUserDefaults.m) 하나만 되돌리면 됩니다. 전역 설정에는 기기 언어도 들어 있으므로, 게임이 기기 언어를 따라 표시 언어를 고르는 경우 원본과 다른 언어로 뜰 수 있습니다.

## 직접 빌드

macOS와 Xcode 26.2가 필요합니다.

```sh
git clone --recursive https://github.com/yazzang-homelab/GameCase-ko.git
cd GameCase-ko
python3 tools/ko/ko.py check
xcodebuild archive -archivePath archive -scheme LiveContainer -project LiveContainer.xcodeproj \
  -sdk iphoneos -arch arm64 -configuration Release
mv archive.xcarchive/Products/Applications Payload
rm -r Payload/LiveContainer.app/Frameworks/SideStoreSupport.framework
zip -qr GameCase-ko.ipa Payload
```

Mac이 없으면 이 저장소를 포크한 뒤 Actions의 **Korean build**를 실행하면 같은 IPA가 만들어집니다.

## 번역 고치기

- 이 포크가 추가한 번역은 `tools/ko/ko.json`에 있습니다. 고친 뒤 `python3 tools/ko/ko.py sync`로 문자열 카탈로그(`Resources/Localizable.xcstrings`)에 반영합니다.
- 원본에 이미 있던 번역은 `Resources/Localizable.xcstrings`의 `ko` 항목을 직접 고칩니다.
- `python3 tools/ko/ko.py check`가 통과해야 빌드됩니다. 한국어가 빠진 키, 영어 원문과 형식 지정자가 다른 문구, 한자가 남은 문구가 있으면 실패합니다.

어색한 번역이나 중국어가 남은 화면을 발견하면 [이슈](https://github.com/yazzang-homelab/GameCase-ko/issues)에 화면 이름과 함께 알려 주십시오.

## 원본 새 버전 따라가기

| 브랜치 | 내용 |
|---|---|
| `ko` (기본) | 원본 정식 릴리스 + 한글화 |
| `main` | 원본 `main` 그대로 |

```sh
git remote add upstream https://github.com/Tiaoge-tou/GameCase.git
git fetch upstream --tags
git merge v1.0.18                # 새 정식 릴리스 태그
python3 tools/ko/ko.py check     # 새로 생긴 문구를 영어 원문과 함께 나열합니다
# tools/ko/ko.json에 번역을 추가한 뒤
python3 tools/ko/ko.py sync && python3 tools/ko/ko.py check
```

`README.md`가 충돌하면 한글판을 남기고, 원본의 변경은 `README.zh-Hans.md`에 반영합니다.

## 출처와 라이선스

- **[GameCase](https://github.com/Tiaoge-tou/GameCase)** — 이 포크의 원본.
- **[LiveContainer](https://github.com/LiveContainer/LiveContainer)** — GameCase의 바탕. 원작자 Duy Tran([khanhduytran0](https://github.com/khanhduytran0)), 주 관리자 [hugeBlack](https://github.com/hugeBlack)과 기여자들. LiveContainer의 README는 [docs/livecontainer-readme.md](docs/livecontainer-readme.md)에 있습니다.
- **[nxnative](https://github.com/seedds/nxnative)**([seedds](https://github.com/seedds)) — GameCase에서 실행하는 이식 게임 IPA를 만드는 도구.
- **[NX2Apple](https://github.com/LNPANDY/NX2Apple)**([LNPANDY](https://github.com/LNPANDY)) — 보관함 화면과 컨트롤러 페이지의 원형.

원본과 같은 **GNU AGPL v3.0**으로 배포합니다([LICENSE](LICENSE)). 이 포크를 다시 고쳐 배포할 때도 AGPL-3.0으로 소스를 공개하고 위 출처를 남겨야 합니다.

## 고지

- GameCase에는 게임 콘텐츠가 들어 있지 않습니다. 게임 IPA와 데이터 팩은 사용자가 직접 준비하며, 출처가 적법해야 합니다.
- 각 게임의 저작권은 해당 제작사에 있습니다. 이 저장소는 위 원작자·팀이나 게임 제작사와 관계가 없습니다.
- 원본 프로젝트의 공식 번역이 아닙니다. 한글판에서 생긴 문제는 원본이 아니라 [이 저장소의 이슈](https://github.com/yazzang-homelab/GameCase-ko/issues)에 알려 주십시오.
