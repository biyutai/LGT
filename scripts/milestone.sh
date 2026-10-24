#!/usr/bin/env bash
# 打里程碑：给当前提交打 tag 并推送，在 GitHub 上建 Release，可附带比特流等文件
#
# 用法（在 Git Bash 里）：
#   scripts/milestone.sh v0.1-baseline "官方 lab_ex5 原样上板通过" path/to/xxx.bit
#   scripts/milestone.sh v0.2-por "合并 ex4 上电复位与 SD 超时"          # 不附文件也可以
#
# tag 名只用英文、数字、点和横线；说明可以写中文。
# .bit 不进 git（见 .gitignore），挂在 Release 上即可随时下载回滚。
set -euo pipefail

usage() {
    echo "用法：scripts/milestone.sh <tag> \"说明\" [附件 ...]" >&2
    echo "  例：scripts/milestone.sh v0.1-baseline \"官方 lab_ex5 原样上板通过\" td_project/HDMI1.4b_Transmitter_v1.0_Runs/best_result/HDMI1.4b_Transmitter_v1.0.bit" >&2
    exit 1
}

(( $# >= 2 )) || usage
tag="$1"
notes="$2"
shift 2

[[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "tag 名只能含英文、数字、点、横线、下划线：$tag" >&2; exit 1; }

# 附件路径在切换目录前转成绝对路径，这样在仓库任意子目录运行都不会找错文件
files=()
for f in "$@"; do
    [[ -f "$f" ]] || { echo "找不到附件：$f" >&2; exit 1; }
    files+=("$(realpath "$f")")
done

cd "$(git rev-parse --show-toplevel)"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "工作区还有未提交的改动，先运行 scripts/save.sh 保存后再打里程碑。" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "tag 已存在：$tag（换一个名字）" >&2
    exit 1
fi

# 先确保当前提交已在远端（新分支没有上游时自动建立跟踪）
if git rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
    git push -q
else
    git push -q -u origin HEAD
fi
git tag -a "$tag" -m "$notes"
git push -q origin "$tag"
echo "== 已推送 tag $tag → $(git log --oneline -1)"

gh release create "$tag" --title "$tag" --notes "$notes" "${files[@]}"
