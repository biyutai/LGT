#!/usr/bin/env bash
# 一键保存：git add -A → commit → push
#
# 用法（在 Git Bash 里，仓库内任意目录均可）：
#   scripts/save.sh "功能：HDMI 彩条输出 [上板通过]"
#   scripts/save.sh -n "功能：xxx [未验证]"     # 只提交，不推送
#
# 提交信息格式见 09_Git提交流程.md
set -euo pipefail

usage() {
    echo "用法：scripts/save.sh [-n] \"类型：做了什么 [验证状态]\"" >&2
    echo "  -n  只提交，不推送到 GitHub" >&2
    exit 1
}

push=1
if [[ "${1:-}" == "-n" ]]; then
    push=0
    shift
fi
msg="${1:-}"
[[ -n "$msg" ]] || usage

cd "$(git rev-parse --show-toplevel)"

git add -A
if git diff --cached --quiet; then
    echo "没有需要提交的改动。"
    exit 0
fi

# GitHub 单文件超过 100MB 会拒收、超过 50MB 会警告 —— 提交前先拦住
limit=$((50 * 1024 * 1024))
big=()
while IFS= read -r -d '' f; do
    [[ -f "$f" ]] || continue
    if (( $(stat -c %s "$f") > limit )); then
        big+=("$f")
    fi
done < <(git diff --cached --name-only --diff-filter=AM -z)

if (( ${#big[@]} > 0 )); then
    git reset -q
    echo "以下文件超过 50MB，不能进 git（视频放网盘，比特流用 scripts/milestone.sh 挂到 Release）：" >&2
    printf '  %s\n' "${big[@]}" >&2
    echo "已取消暂存，什么都没有提交。把它们加进 .gitignore 后再运行。" >&2
    exit 1
fi

echo "== 本次提交的文件"
git -c core.quotepath=false status --short
git commit -q -m "$msg"
echo "== 已提交"
git log --oneline -1

if (( push )); then
    # 新分支还没有上游时，自动建立跟踪
    if git rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
        git push -q
    else
        git push -q -u origin HEAD
    fi
    echo "== 已推送到 $(git remote get-url origin)"
else
    echo "== 未推送（-n）。之后运行 git push 即可同步到 GitHub"
fi
