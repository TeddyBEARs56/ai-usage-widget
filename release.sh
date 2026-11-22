#!/bin/zsh
# 새 판을 GitHub Releases 에 올린다 — 깔려 있는 앱(맥 1.4·Windows 1.1.0 부터)이 6시간 안에 알아서 받아 바꾼다.
#   zsh release.sh mac ["바뀐 점"]        mac/Info.plist 의 버전 → 태그 mac-v<버전>, 파일 AIUsage-mac-<버전>.zip
#   zsh release.sh windows ["바뀐 점"]    windows/*/*.csproj 의 <Version> → 태그 windows-v<버전>, 파일 AIUsage.exe
# 먼저 버전을 올려 커밋·push 한다(맥: CFBundleShortVersionString·CFBundleVersion, Windows: 두 csproj 의 <Version>).
# 앱은 태그의 버전이 지금보다 높을 때만 바꾸므로, 버전을 안 올리면 올려도 아무도 안 바뀐다.
# 올린 뒤 README.md 「받기」 표의 버전·링크를 새 판으로 고쳐 커밋·push 한다.
set -euo pipefail

root=${0:A:h}
repo=TeddyBEARs56/ai-usage-widget
target=${1:-}
notes=${2:-}
cd "$root"
export PATH=/opt/homebrew/bin:$PATH

case $target in
  mac)
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' mac/Info.plist)
    install_note="처음 설치: 아래 zip 을 받아 풀고 「읽어 주세요 (Read me).txt」대로(터미널에 zsh + 설치.sh 끌어다 놓기). 맥 1.4 이상이 깔려 있으면 앱이 알아서 바꾼다.
First install: unzip and follow “읽어 주세요 (Read me).txt”. Installed apps (Mac 1.4+) update themselves." ;;
  windows)
    version=$(sed -nE 's:.*<Version>([0-9.]+)</Version>.*:\1:p' windows/AIUsage/AIUsage.csproj)
    status_version=$(sed -nE 's:.*<Version>([0-9.]+)</Version>.*:\1:p' windows/AIUsageStatus/AIUsageStatus.csproj)
    [[ $version == "$status_version" ]] || { print -u2 "두 csproj 의 <Version> 이 다릅니다($version / $status_version)."; exit 1; }
    install_note="처음 설치: 아래 AIUsage.exe 를 받아 실행 → 「이 PC에 설치할까요?」 예. Windows 1.1.0 이상이 설치돼 있으면 앱이 알아서 바꾼다." ;;
  *)
    print -u2 "사용법: zsh release.sh mac|windows [\"바뀐 점\"]"
    exit 2 ;;
esac
tag=$target-v$version

# 올린 판과 저장소 소스가 어긋나지 않게: 커밋 안 한 변경이 없고, main 이 GitHub 과 같아야 한다
[[ $(git branch --show-current) == main ]] || { print -u2 "main 에서 하세요."; exit 1; }
[[ -z $(git status --porcelain) ]] || { print -u2 "커밋하지 않은 변경이 있습니다."; exit 1; }
git fetch -q origin
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { print -u2 "main 을 먼저 push 하세요(HEAD 와 origin/main 이 다름)."; exit 1; }

# 같은 버전이 이미 있거나, 올라온 것보다 낮으면 멈춘다
existing=$(gh release list -R $repo --limit 100 --json tagName -q '.[].tagName' | grep "^$target-v" || true)
if print -r -- "$existing" | grep -qx "$tag"; then
  print -u2 "$tag 는 이미 올라가 있습니다. 버전을 올리고 다시 하세요."
  exit 1
fi
highest=$(print -r -- "$existing" | sed "s/^$target-v//" | grep -E '^[0-9.]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 || true)
if [[ -n $highest && $(printf '%s\n%s\n' "$highest" "$version" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1) != "$version" ]]; then
  print -u2 "올라온 $target 최신이 $highest 입니다. 그보다 높은 버전으로 올리세요(지금 $version)."
  exit 1
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
case $target in
  mac)
    asset="$stage/AIUsage-mac-$version.zip"
    zsh mac/package.sh "$asset"
    title="AI 사용량 맥 $version" ;;
  windows)
    zsh windows/build.sh
    asset="$stage/AIUsage.exe"
    cp windows/dist/AIUsage.exe "$asset"
    title="AI 사용량 Windows $version" ;;
esac

body="${notes:+$notes

}$install_note"
gh release create "$tag" "$asset" -R $repo --target "$(git rev-parse HEAD)" --title "$title" --notes "$body"
print "올림: $tag — $(gh release view "$tag" -R $repo --json assets -q '.assets[] | "\(.name) \(.size)바이트 \(.digest // "digest 없음")"')"

# README 「받기」 표: 그 판 줄(링크에 releases/download/<target>-v 가 든 줄)의 버전 칸과 링크를 새 판으로
url="https://github.com/$repo/releases/download/$tag/${asset:t}"
# GitHub Actions(mac-release.yml)에서 올릴 때는 README 커밋을 하지 않는다 — 그 커밋은 사람이 자기 이름으로 한다
if [[ -n ${AIUSAGE_SKIP_README:-} ]]; then
  print "README 받기 링크는 고치지 않음(AIUSAGE_SKIP_README) — 받기 링크: $url"
  exit 0
fi
VERSION=$version URL=$url NAME=${asset:t} TARGET=$target perl -pi -e '
  if (m{releases/download/$ENV{TARGET}-v}) {
    s{^(\|[^|]*\|) [0-9.]+ \|}{$1 $ENV{VERSION} |};
    s{\[[^\]]+\]\(https://github\.com/[^)]*/releases/download/$ENV{TARGET}-v[^)]*\)}{[$ENV{NAME}]($ENV{URL})};
  }' README.md
if ! git diff --quiet README.md; then
  git commit -q -m "README 받기 링크: $tag" README.md
  git push -q origin main
  print "README 받기 링크를 $tag 로 고쳐 push 함"
fi
