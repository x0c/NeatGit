#!/usr/bin/env bash
# NeatGit 的 macOS 直分发发布器。
#
# 默认行为：经 Python start_new_session 可靠脱离当前会话后台执行完整发布，
# 日志写入 build/release-logs/，PID 写入 publish-latest.pid。
# 完整链路：提交快照 → 归档 → Developer ID 导出 → 签名校验 → 公证并装订 App
# → 制作 dmg → 公证并装订 dmg → Gatekeeper 校验 → GitHub Release。
#
# 用法：
#   scripts/publish-release.sh                 # 后台完整发布
#   scripts/publish-release.sh --local-only    # 后台完成本地产物，不推送远端
#   scripts/publish-release.sh --foreground    # 在当前终端运行（仅排障）
#   scripts/publish-release.sh --dry-run       # 只检查前置条件和发布配置
#
# 参考实现：NeatEditor 的 publish-release.sh（同机同证书同公证密钥）。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
readonly APP_NAME="NeatGit"
readonly REPOSITORY="x0c/NeatGit"
readonly DEFAULT_BRANCH="master"
readonly UPDATE_FEED_URL="https://raw.githubusercontent.com/${REPOSITORY}/master/appcast.xml"
readonly UPDATE_DOWNLOAD_PREFIX="https://github.com/${REPOSITORY}/releases/download"
readonly SPARKLE_ACCOUNT="caozc.top"
readonly TEAM_ID="SHZQ3MWP3B"
readonly SIGN_IDENTITY="Developer ID Application"
readonly NOTARY_KEY="${NOTARY_KEY:-${HOME}/Documents/P8 密钥/发布公证密钥/AuthKey_D7YQ9HD7D6_Notarize.p8}"
readonly NOTARY_KEY_ID="${NOTARY_KEY_ID:-D7YQ9HD7D6}"
readonly NOTARY_ISSUER="${NOTARY_ISSUER:-c98fe4b8-d1bf-4b4a-b998-9eb8f3be9fe4}"
readonly BUILD_DIR="${ROOT_DIR}/build/release"
readonly DERIVED_DATA="${BUILD_DIR}/DerivedData.noindex"
readonly ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
readonly EXPORT_DIR="${BUILD_DIR}/export"
readonly APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"
readonly APPCAST_PATH="${ROOT_DIR}/appcast.xml"
readonly NOTARY_TIMEOUT=3600
readonly NOTARY_POLL_INTERVAL=30

local_only=false
foreground=false
dry_run=false
for argument in "$@"; do
  case "${argument}" in
    --local-only) local_only=true ;;
    --foreground) foreground=true ;;
    --dry-run) dry_run=true ;;
    *) printf '未知参数：%s\n' "${argument}" >&2; exit 2 ;;
  esac
done

log_step() { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# 公证可能需要数十分钟；默认先脱离当前会话再执行。子进程会完整串行后续步骤，
# 不依赖 Agent 或终端保持在线。脱离经 scripts/run-detached.py 以 Python
# start_new_session=True 实现（macOS 没有 setsid；裸 nohup 仍挂在调用方
# 会话下，会话一断即被带走）。只打印日志路径与 PID，不打印任何密钥内容。
if [[ "${foreground}" == false && "${dry_run}" == false && "${NEATGIT_RELEASE_CHILD:-}" != "1" ]]; then
  log_dir="${ROOT_DIR}/build/release-logs"
  mkdir -p "${log_dir}"
  log_file="${log_dir}/publish-$(date +%Y%m%d-%H%M%S).log"
  : > "${log_file}"
  pid_file="${log_dir}/publish-latest.pid"
  child_args=(--foreground)
  [[ "${local_only}" == true ]] && child_args+=(--local-only)
  child_pid="$(/usr/bin/python3 "${ROOT_DIR}/scripts/run-detached.py" "${log_file}" "${pid_file}" \
    "${BASH_SOURCE[0]}" "${child_args[@]}")" || die "后台发布启动失败，详见 ${log_file}"
  printf '发布已在后台启动（进程 %s）。日志：%s\n' "${child_pid}" "${log_file}"
  exit 0
fi

assert_signed_for_distribution() {
  local target="$1" label="$2" sign_info entitlements
  sign_info="$(codesign -dv --verbose=2 "${target}" 2>&1)"
  entitlements="$(codesign -d --entitlements - "${target}" 2>/dev/null || true)"
  grep -q "Authority=${SIGN_IDENTITY}" <<<"${sign_info}" \
    || die "${label}不是 Developer ID 签名"
  grep -q 'flags=.*runtime' <<<"${sign_info}" \
    || die "${label}未启用加固运行时"
  grep -q '^Timestamp=' <<<"${sign_info}" \
    || die "${label}签名缺少可信时间戳"
  if grep -q 'get-task-allow' <<<"${entitlements}"; then
    die "${label}包含调试权限，不能提交苹果公证"
  fi
  codesign --verify --deep --strict --verbose=2 "${target}" >/dev/null \
    || die "${label}签名结构校验失败"
}

claim_submission_id() {
  local file_name="$1" started_at="$2" history_json submission_id
  for _ in 1 2 3 4 5; do
    sleep 10
    history_json="$(xcrun notarytool history --key "${NOTARY_KEY}" --key-id "${NOTARY_KEY_ID}" \
      --issuer "${NOTARY_ISSUER}" --output-format json 2>/dev/null)" || continue
    submission_id="$(jq -r --arg name "${file_name}" --arg since "${started_at}" \
      '[.history[]? | select(.name == $name and .createdDate >= $since)] | sort_by(.createdDate) | last | .id // empty' \
      <<<"${history_json}" 2>/dev/null || true)"
    [[ -n "${submission_id}" ]] && { printf '%s\n' "${submission_id}"; return 0; }
  done
  return 1
}

notarize_and_wait() {
  local file="$1" file_name started_at submit_json submission_id status waited=0 info_out failures=0
  file_name="$(basename "${file}")"
  started_at="$(date -u -v-60S +%Y-%m-%dT%H:%M:%SZ)"
  submit_json="$(xcrun notarytool submit "${file}" --key "${NOTARY_KEY}" --key-id "${NOTARY_KEY_ID}" \
    --issuer "${NOTARY_ISSUER}" --output-format json 2>/dev/null)" || submit_json=""
  submission_id="$(jq -r '.id // empty' <<<"${submit_json:-{}}" 2>/dev/null || true)"
  [[ -n "${submission_id}" ]] || submission_id="$(claim_submission_id "${file_name}" "${started_at}")" \
    || die "公证提交未获回执，且无法在苹果侧认领：${file_name}"
  printf '苹果公证提交编号：%s\n' "${submission_id}"

  while (( waited < NOTARY_TIMEOUT )); do
    sleep "${NOTARY_POLL_INTERVAL}"
    waited=$((waited + NOTARY_POLL_INTERVAL))
    info_out="$(xcrun notarytool info "${submission_id}" --key "${NOTARY_KEY}" --key-id "${NOTARY_KEY_ID}" \
      --issuer "${NOTARY_ISSUER}" --output-format json 2>&1)" || true
    status="$(jq -r '.status // empty' <<<"${info_out}" 2>/dev/null || true)"
    if [[ -z "${status}" ]]; then
      failures=$((failures + 1))
      (( failures < 5 )) || die "连续 5 次无法查询公证状态：$(head -1 <<<"${info_out}")"
      continue
    fi
    failures=0
    [[ "${status}" == "In Progress" ]] && continue
    if [[ "${status}" == "Accepted" ]]; then
      printf '苹果公证通过。\n'
      return 0
    fi
    xcrun notarytool log "${submission_id}" --key "${NOTARY_KEY}" --key-id "${NOTARY_KEY_ID}" \
      --issuer "${NOTARY_ISSUER}" 2>/dev/null | head -40 || true
    die "苹果公证被拒：${status}"
  done
  die "公证等待超过 $((NOTARY_TIMEOUT / 60)) 分钟；提交编号为 ${submission_id}"
}

create_dmg() {
  local stage_dir="$1" volume_name="$2" output="$3" macos_major
  macos_major="$(sw_vers -productVersion | cut -d. -f1)"
  rm -f "${output}"
  if (( macos_major >= 26 )); then
    diskutil image create from "${stage_dir}" "${output}" --format UDZO --volumeName "${volume_name}" >/dev/null
  else
    hdiutil create -volname "${volume_name}" -srcfolder "${stage_dir}" -ov -format UDZO "${output}" >/dev/null
  fi
}

# 草稿纪律 helpers（RELEASING.md R4；fixture 演练直接取用此处定义）。
# 已公开的发行页绝不改动；“精确一致”指三件基名的整集字符串比对，
# 近似名与多余文件一律失败；字节比对通过前绝不公开。

release_page_state() {
  # 输出 absent / draft / published 之一；查询失败视为 absent（创建会再报错）。
  local is_draft
  is_draft="$(gh release view "v${version}" --repo "${REPOSITORY}" --json isDraft --jq '.isDraft' 2>/dev/null)" || {
    printf 'absent\n'
    return 0
  }
  if [[ "${is_draft}" == "true" ]]; then
    printf 'draft\n'
  else
    printf 'published\n'
  fi
}

expected_release_assets() {
  # 期望三件基名，排序后逐行输出。
  printf '%s\n' "$(basename "${dmg_path}")" "$(basename "${update_zip_path}")" "SHA256SUMS.txt" | sort
}

actual_release_assets() {
  gh release view "v${version}" --repo "${REPOSITORY}" --json assets --jq '.assets[].name' | sort
}

assert_exact_release_assets() {
  # 整集精确比对：固定字符串、逐行、数量一致；缺件、多余、近似名都失败。
  # 失败时调用方保持草稿，绝不公开。
  local expected actual
  expected="$(expected_release_assets)"
  actual="$(actual_release_assets)" || die "无法读取发行页附件列表（失败页保持草稿）"
  [[ "${actual}" == "${expected}" ]] \
    || die "发行页附件集合与期望三件不一致（失败页保持草稿）"
}

verify_release_download_bytes() {
  # 把发行页三件下载到 disposable 目录，逐件做字节比对（cmp）+ SHA256 比对。
  # 名字一致不代表数据一致；比对通过前绝不公开。
  local verify_dir="$1" name local_file local_hash remote_hash
  mkdir -p "${verify_dir}"
  gh release download "v${version}" --repo "${REPOSITORY}" --dir "${verify_dir}" \
    --pattern "$(basename "${dmg_path}")" \
    --pattern "$(basename "${update_zip_path}")" \
    --pattern "SHA256SUMS.txt" || die "发行页附件下载失败（失败页保持草稿）"
  while IFS= read -r name; do
    local_file="${BUILD_DIR}/${name}"
    [[ -f "${verify_dir}/${name}" ]] || die "下载缺失：${name}（失败页保持草稿）"
    cmp -s "${local_file}" "${verify_dir}/${name}" || die "字节不一致：${name}（失败页保持草稿）"
    local_hash="$(shasum -a 256 "${local_file}" | cut -d' ' -f1)"
    remote_hash="$(shasum -a 256 "${verify_dir}/${name}" | cut -d' ' -f1)"
    [[ "${local_hash}" == "${remote_hash}" ]] || die "校验不一致：${name}（失败页保持草稿）"
  done <<<"$(expected_release_assets)"
}

cd "${ROOT_DIR}"
log_step "检查发布前置条件"
# 凭据只校验存在性与连通性；绝不打印密钥值或密钥文件内容。
identities="$(security find-identity -v -p codesigning)"
grep -q "${SIGN_IDENTITY}" <<<"${identities}" || die "钥匙串中没有 Developer ID Application 证书"
[[ -f "${NOTARY_KEY}" ]] || die "找不到苹果公证密钥"
notary_check="$(xcrun notarytool history --key "${NOTARY_KEY}" --key-id "${NOTARY_KEY_ID}" --issuer "${NOTARY_ISSUER}" 2>&1)" \
  || die "苹果公证凭据不可用：$(head -1 <<<"${notary_check}")"
[[ -f project.yml ]] || die "未找到项目配置"
version="$(sed -n 's/^ *MARKETING_VERSION: //p' project.yml | tr -d ' ')"
build_number="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: //p' project.yml | tr -d ' ')"
[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "展示版本必须是 SemVer"
[[ "${build_number}" =~ ^[1-9][0-9]*$ ]] || die "内部构建号必须是正整数"
readonly version build_number
readonly dmg_path="${BUILD_DIR}/${APP_NAME}-${version}.dmg"
readonly checksum_path="${BUILD_DIR}/SHA256SUMS.txt"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "发布必须在 Git 仓库中运行"
if [[ -f .git/MERGE_HEAD || -d .git/rebase-merge || -d .git/rebase-apply ]]; then
  die "仓库正处于合并或变基中，先解决后再发布"
fi
# 内部构建号是 Sparkle 判定新旧的唯一依据，必须严格大于已发布 appcast 的最大值。
# 依据：https://sparkle-project.org/documentation/publishing/（Internal build numbers）。
# 首版允许空 appcast（视为 0），之后必须严格递增。
appcast_build="$(sed -n 's/.*<sparkle:version>\([0-9][0-9]*\)<\/sparkle:version>.*/\1/p' "${APPCAST_PATH}" 2>/dev/null | sort -n | tail -1)"
if [[ -z "${appcast_build:-}" ]]; then
  appcast_build=0
fi
if [[ "${build_number}" -le "${appcast_build}" ]]; then
  die "内部构建号 ${build_number} 未大于已发布构建号 ${appcast_build}；先递增 CURRENT_PROJECT_VERSION"
fi
# 发行说明的英文正文取自 CHANGELOG；缺条目直接失败，不用签名话术凑数。
changelog_notes="$(awk -v ver="${version}" '/^## / { active = ($2 == ver); next } active { print }' CHANGELOG.md)"
[[ -n "${changelog_notes:-}" ]] || die "CHANGELOG.md 缺少 ${version} 条目，先补变更记录再发布"

if [[ "${local_only}" == false && "${dry_run}" == false ]]; then
  gh repo view "${REPOSITORY}" --json isPrivate,defaultBranchRef --jq '.isPrivate == false and .defaultBranchRef.name == "master"' \
    | grep -q true || die "GitHub 公开仓或默认分支不符合发布基线"
fi

if [[ "${dry_run}" == true ]]; then
  printf '发布配置检查通过：v%s（内部构建号 %s，大于已发布构建号 %s）。\n' "${version}" "${build_number}" "${appcast_build}"
  exit 0
fi

# 单实例互斥：同一工作树禁止并行发版（两实例抢产物目录会签坏密封，公证 Invalid）。
# 父目录只在真实运行时创建；--dry-run 在此前已退出，不落任何目录。
mkdir -p "${BUILD_DIR}"
lock_dir="${BUILD_DIR}/.publish-lock"
if ! mkdir "${lock_dir}" 2>/dev/null; then
  die "另一个发布正在运行（${lock_dir} 已存在）；确认无发布进程后手动删除再跑"
fi
trap 'rm -rf "${lock_dir}"' EXIT

log_step "构建 Monaco 前端并生成工程"
if [[ -f Web/MonacoDiff/package.json ]]; then
  (cd Web/MonacoDiff && npm ci && npm run build) >/dev/null \
    || die "Monaco 前端构建失败"
fi
xcodegen generate >/dev/null
# 提交优先：归档、打标签、落盘全部来自这次提交。工作区改动（含他人未提交
# 源码）一并纳入提交，绝不丢弃、贮藏（stash）、重置或隔离。
git add -A
if ! git diff --cached --quiet; then
  git commit -m "chore: 发布 v${version} 快照（构建号 ${build_number}）" >/dev/null
fi
SOURCE_COMMIT="$(git rev-parse HEAD)"
readonly SOURCE_COMMIT
[[ -z "$(git status --porcelain)" ]] || die "工作区仍有未纳入快照的改动"
printf '发布源提交：%s\n' "${SOURCE_COMMIT}"
# 标签先行校验：已存在的标签必须指向本次源提交，否则在耗时的构建/公证之前停下。
# 标签不可移动；同源重试会命中“已存在且一致”分支继续走。
if git rev-parse "v${version}" >/dev/null 2>&1; then
  [[ "$(git rev-list -n 1 "v${version}")" == "${SOURCE_COMMIT}" ]] \
    || die "标签 v${version} 已存在且指向另一提交（标签不可移动）；先核对远端再处理"
else
  git tag -a "v${version}" "${SOURCE_COMMIT}" -m "v${version}"
fi

log_step "归档 Developer ID 版本"
rm -rf "${ARCHIVE_PATH}" "${EXPORT_DIR}"
xcodebuild -project "${APP_NAME}.xcodeproj" -scheme "${APP_NAME}" -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "${DERIVED_DATA}" -archivePath "${ARCHIVE_PATH}" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO archive

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}" "${lock_dir}"' EXIT
export_options="${work_dir}/ExportOptions.plist"
cat > "${export_options}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>destination</key><string>export</string>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "${ARCHIVE_PATH}" -exportOptionsPlist "${export_options}" \
  -exportPath "${EXPORT_DIR}"
[[ -d "${APP_PATH}" ]] || die "Developer ID 导出产物不存在"
# 来源指纹守卫：构建不得漂移或污染工作区，否则产物与标签对不上源提交。
[[ "$(git rev-parse HEAD)" == "${SOURCE_COMMIT}" ]] || die "构建期间 HEAD 已漂移，停止发布"
[[ -z "$(git status --porcelain)" ]] || die "构建污染了工作区，先检查再发布"
# 构建身份守卫：产物内的展示版本/构建号必须与配置一致，且为 universal 二进制。
# 公证之前校验，错配不进苹果队列。
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true)"
bundle_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true)"
[[ "${bundle_version}" == "${version}" ]] \
  || die "产物展示版本 ${bundle_version:-未知} 与配置 ${version} 不一致"
[[ "${bundle_build}" == "${build_number}" ]] \
  || die "产物构建号 ${bundle_build:-未知} 与配置 ${build_number} 不一致"
lipo -info "${APP_PATH}/Contents/MacOS/${APP_NAME}" | grep -q -e 'arm64' \
  || die "产物不是 universal 二进制"
lipo -info "${APP_PATH}/Contents/MacOS/${APP_NAME}" | grep -q -e 'x86_64' \
  || die "产物不是 universal 二进制"
readonly sparkle_bin_dir="${DERIVED_DATA}/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "${sparkle_bin_dir}/generate_appcast" ]] || die "找不到 Sparkle 的 generate_appcast 工具"

sparkle_public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true)"
[[ -n "${sparkle_public_key}" ]] || die "应用缺少 Sparkle 更新公钥"
[[ "$("${sparkle_bin_dir}/generate_keys" --account "${SPARKLE_ACCOUNT}" -p 2>/dev/null)" == "${sparkle_public_key}" ]] \
  || die "钥匙串中的 Sparkle 更新签名密钥缺失或与应用公钥不匹配"

log_step "校验签名与加固运行时"
assert_signed_for_distribution "${APP_PATH}" "NeatGit"
sparkle_version_dir="${APP_PATH}/Contents/Frameworks/Sparkle.framework/Versions/B"
for nested in "${sparkle_version_dir}/XPCServices/Downloader.xpc" \
              "${sparkle_version_dir}/XPCServices/Installer.xpc" \
              "${sparkle_version_dir}/Updater.app" \
              "${sparkle_version_dir}/Autoupdate"; do
  assert_signed_for_distribution "${nested}" "${nested##*/}"
done

log_step "提交应用本体公证并装订票据"
notary_zip="${BUILD_DIR}/${APP_NAME}-${version}-notarize.zip"
rm -f "${notary_zip}"
ditto -c -k --keepParent "${APP_PATH}" "${notary_zip}"
notarize_and_wait "${notary_zip}"
xcrun stapler staple "${APP_PATH}" >/dev/null

log_step "生成 Sparkle 签名更新包与更新清单"
update_zip_path="${BUILD_DIR}/${APP_NAME}-${version}.zip"
appcast_dir="${work_dir}/appcast"
release_notes_file="${appcast_dir}/${APP_NAME}-${version}.md"
mkdir -p "${appcast_dir}"
rm -f "${update_zip_path}"
# 更新包用 Sparkle 文档指定的打法（--sequesterRsrc --keepParent，保留符号链接）。
# 依据：https://sparkle-project.org/documentation/publishing/
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${update_zip_path}"
ditto "${update_zip_path}" "${appcast_dir}/$(basename "${update_zip_path}")"
printf '# NeatGit %s\n\n%s\n' "${version}" "${changelog_notes}" > "${release_notes_file}"
[[ -f "${APPCAST_PATH}" ]] && ditto "${APPCAST_PATH}" "${appcast_dir}/appcast.xml"
"${sparkle_bin_dir}/generate_appcast" \
  --account "${SPARKLE_ACCOUNT}" \
  --download-url-prefix "${UPDATE_DOWNLOAD_PREFIX}/v${version}/" \
  --embed-release-notes \
  --link "https://github.com/${REPOSITORY}" \
  --versions "${build_number}" \
  --maximum-versions 10 \
  -o "${appcast_dir}/appcast.xml" \
  "${appcast_dir}" >/dev/null || die "生成 Sparkle 更新清单失败"
xmllint --noout "${appcast_dir}/appcast.xml" || die "Sparkle 更新清单不是合法 XML"
grep -q 'sparkle:edSignature=' "${appcast_dir}/appcast.xml" \
  || die "Sparkle 更新清单缺少 EdDSA 签名"

log_step "制作 dmg 并公证"
stage_dir="${work_dir}/dmg"
mkdir -p "${stage_dir}"
ditto "${APP_PATH}" "${stage_dir}/${APP_NAME}.app"
ln -s /Applications "${stage_dir}/Applications"
create_dmg "${stage_dir}" "${APP_NAME} ${version}" "${dmg_path}" || die "dmg 制作失败"
notarize_and_wait "${dmg_path}"
xcrun stapler staple "${dmg_path}" >/dev/null

log_step "验证陌生用户安装链路"
gatekeeper_result="$(spctl -a -vvv -t install "${APP_PATH}" 2>&1 || true)"
grep -q accepted <<<"${gatekeeper_result}" || die "Gatekeeper 校验未通过：$(head -3 <<<"${gatekeeper_result}")"
xcrun stapler validate "${dmg_path}" >/dev/null || die "dmg 票据校验失败"
rm -f "${checksum_path}"
(cd "${BUILD_DIR}" && shasum -a 256 "$(basename "${dmg_path}")" "$(basename "${update_zip_path}")" > "$(basename "${checksum_path}")")

if [[ "${local_only}" == true ]]; then
  printf '本地发布产物已验证：%s（更新包：%s，校验：%s）\n' "${dmg_path}" "${update_zip_path}" "${checksum_path}"
  exit 0
fi

log_step "打标签并发布 GitHub Release"
# 标签已在构建前创建并校验（见上文）；此处只推送。构建产物来自 SOURCE_COMMIT。
git push origin "${DEFAULT_BRANCH}"
if ! git push origin "v${version}"; then
  sleep 10
  git push origin "v${version}" || die "标签推送失败（两次尝试）"
fi

# 草稿纪律（RELEASING.md R4）：先查询发行页状态再决定动作，查询先于一切上传。
# 已公开页绝不改动——只有整集精确一致且下载字节一致时才走只读复用，
# 否则停下。缺页则建草稿；草稿页复用后上传。任何失败都死在公开之前，
# 失败页保持草稿。
page_state="$(release_page_state)"
if [[ "${page_state}" == "published" ]]; then
  assert_exact_release_assets
  verify_release_download_bytes "${work_dir}/verify-published"
  printf '发行页 v%s 已公开且三件字节一致，不做任何改动，直接进入更新清单。\n' "${version}"
else
  # 发行说明中英双语、英文在前，用真实换行。正文取自 CHANGELOG 当版条目。
  notes_file="${work_dir}/release-notes.md"
  {
    printf 'NeatGit %s\n\n' "${version}"
    printf '%s\n' "${changelog_notes}"
    cat <<'EOF'

---

NeatGit（简体中文）

本版本已用 Developer ID 签名、经苹果公证并装订票据，断网也可通过 Gatekeeper 校验。
下载下方 DMG，把 NeatGit.app 拖入 Applications，再执行 open -a NeatGit 启动。
应用内 Sparkle 更新带 EdDSA 签名，安装前验签。完整变更见上方中英文说明。
EOF
  } > "${notes_file}"
  if [[ "${page_state}" == "absent" ]]; then
    gh release create "v${version}" --repo "${REPOSITORY}" --title "v${version}" --draft --notes-file "${notes_file}" \
      || die "草稿发行页创建失败（未产生公开 Latest）"
  else
    printf '复用已存在的草稿 v%s。\n' "${version}"
  fi
  # 逐个上传签名文件并回读。单条命令只传一个文件：多文件同传曾回报成功却只留下一个。
  gh release upload "v${version}" "${dmg_path}" --repo "${REPOSITORY}" --clobber \
    || die "签名 dmg 上传失败（失败页保持草稿）"
  gh release view "v${version}" --repo "${REPOSITORY}" --json assets --jq '.assets[].name'
  gh release upload "v${version}" "${update_zip_path}" --repo "${REPOSITORY}" --clobber \
    || die "签名更新包上传失败（失败页保持草稿）"
  gh release view "v${version}" --repo "${REPOSITORY}" --json assets --jq '.assets[].name'
  gh release upload "v${version}" "${checksum_path}" --repo "${REPOSITORY}" --clobber \
    || die "校验文件上传失败（失败页保持草稿）"
  assert_exact_release_assets
  verify_release_download_bytes "${work_dir}/verify-draft"
  # 下载字节一致后才公开；之前任何失败都已退出，失败页保持草稿，失败路径永不公开。
  gh release edit "v${version}" --repo "${REPOSITORY}" --draft=false || die "草稿转公开失败"
  gh release view "v${version}" --repo "${REPOSITORY}" --json isDraft --jq '.isDraft' | grep -q false \
    || die "发行页仍是草稿"
fi
ditto "${appcast_dir}/appcast.xml" "${APPCAST_PATH}"
git add "${APPCAST_PATH}"
if ! git diff --cached --quiet; then
  git commit -m "chore: 发布 v${version} 更新清单" >/dev/null
  git push origin "${DEFAULT_BRANCH}"
fi
asset_url="https://github.com/${REPOSITORY}/releases/download/v${version}/$(basename "${dmg_path}")"
update_url="${UPDATE_DOWNLOAD_PREFIX}/v${version}/$(basename "${update_zip_path}")"
curl -fsSL --range 0-0 "${asset_url}" -o /dev/null || die "公开安装包无法匿名下载"
curl -fsSL --range 0-0 "${update_url}" -o /dev/null || die "Sparkle 更新包无法匿名下载"
# raw CDN 有滞后：仓内已是新构建号而 CDN 仍是旧条目时只等不回滚（见 RELEASING.md R6）。
appcast_ok=false
for appcast_try in 1 2 3 4 5 6; do
  if curl -fsSL "${UPDATE_FEED_URL}" -o "${work_dir}/published-appcast.xml" \
    && xmllint --noout "${work_dir}/published-appcast.xml" \
    && grep -q "<sparkle:version>${build_number}</sparkle:version>" "${work_dir}/published-appcast.xml"; then
    appcast_ok=true
    break
  fi
  sleep 30
done
[[ "${appcast_ok}" == true ]] || die "公开更新清单在 3 分钟内仍无当前内部构建号 ${build_number}（只重跑终检，禁止重签重公证）"
printf '发布完成：%s（自动更新：%s）\n' "${asset_url}" "${UPDATE_FEED_URL}"
