#!/bin/bash
# Standalone GitHub entry point. Publishing replaces the repository placeholder.
set -euo pipefail
umask 077
export LC_ALL=C

repository='ythzaaa/xmhkmail-deploy'
deployment_directory=
operation=menu
confirmed=false
install_arguments=()
docker_installation_arguments=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    install | update | check | status | start | stop | backup | recovery | recover | cleanup-images | uninstall | menu)
      operation=$1
      shift
      ;;
    --repository)
      repository=${2:?Supply OWNER/REPOSITORY}
      shift 2
      ;;
    --directory)
      deployment_directory=${2:?Supply an absolute deployment directory}
      shift 2
      ;;
    --yes)
      confirmed=true
      shift
      ;;
    --install-docker)
      docker_installation_arguments=(--install-docker)
      shift
      ;;
    --hostname | --acme-email | --public-ip)
      install_arguments+=("$1" "${2:?Missing installation value}")
      shift 2
      ;;
    --help | -h)
      printf 'Usage: bash xmhkmail.sh [install|update|check|status|start|stop|backup|recovery|recover|cleanup-images|uninstall]\n'
      printf 'Options: --repository OWNER/REPOSITORY --directory PATH --yes --install-docker\n'
      printf 'Install asks before installing Docker on a host without it; --install-docker approves that for --yes.\n'
      printf 'Uninstall removes this deployment containers only; all data and keys remain.\n'
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done
if [ "$(id -u)" -ne 0 ]; then
  printf '请使用 root 或 sudo 运行。\n' >&2
  exit 1
fi
for program in curl tar sha256sum realpath flock; do
  if ! command -v "$program" > /dev/null; then
    printf '缺少 %s；请先安装 curl、tar、coreutils 和 util-linux。\n' "$program" >&2
    exit 1
  fi
done
# Without Docker there can be no running deployment; only installation, which
# offers to install Docker after confirmation, can continue.
docker_available=false
if command -v docker > /dev/null; then
  docker_available=true
fi

if [ -z "$deployment_directory" ]; then
  container_ids=
  if [ "$docker_available" = true ]; then
    container_ids=$(docker ps -a --filter label=com.docker.compose.project=xmhkmail \
      --filter label=com.docker.compose.service=app --format '{{.ID}}')
  fi
  if [ "$(printf '%s\n' "$container_ids" | sed '/^$/d' | wc -l)" -gt 1 ]; then
    printf '检测到多个部署，请使用 --directory 指定目录。\n' >&2
    exit 1
  fi
  if [ -n "$container_ids" ]; then
    deployment_directory=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container_ids")
    if [ ! -f "$deployment_directory/.env" ]; then
      printf '现有容器的部署配置目录缺失；禁止重新安装或生成新密钥。请先恢复原配置。\n' >&2
      exit 1
    fi
  elif [ -f /var/lib/xmhkmail/.env ]; then
    deployment_directory=/var/lib/xmhkmail
  elif [ -f "$PWD/.env" ] && [ -f "$PWD/ops/lib/deployment.sh" ]; then
    deployment_directory=$PWD
  else
    deployment_directory=/var/lib/xmhkmail
  fi
fi
if [[ "$deployment_directory" != /* ]] || [[ "$deployment_directory" == *[[:space:],:]* ]] \
  || [ "$deployment_directory" = / ] || [ "$deployment_directory" = /root ] \
  || [ "$deployment_directory" = /var ] || [ "$deployment_directory" = /var/lib ]; then
  printf '请指定独立的绝对部署目录，不能使用系统目录或用户主目录。\n' >&2
  exit 1
fi
if [ -L "$deployment_directory" ]; then
  printf '拒绝使用链接部署目录。\n' >&2
  exit 1
fi
if [ -d "$deployment_directory" ]; then
  if [ "$(realpath -e -- "$deployment_directory")" != "$deployment_directory" ] \
    || [ "$(stat -c '%u' -- "$deployment_directory")" != 0 ]; then
    printf '部署目录必须是 root 所有的规范路径。\n' >&2
    exit 1
  fi
fi

read_terminal() {
  if [ -t 0 ]; then
    read -r -p "$1" "$2"
  elif (: < /dev/tty) 2> /dev/null; then
    read -r -p "$1" "$2" < /dev/tty
  else
    printf '交互操作需要终端；自动化请指定操作并加 --yes。\n' >&2
    return 1
  fi
}

run_interactive_script() {
  if [ "$confirmed" = true ] || [ -t 0 ]; then
    bash "$@"
  elif (: < /dev/tty) 2> /dev/null; then
    bash "$@" < /dev/tty
  else
    printf '交互操作需要终端；自动化请加 --yes。\n' >&2
    return 1
  fi
}

if [ "$operation" = menu ]; then
  printf '\nxmhkmail\n1) 安装\n2) 更新\n3) 状态\n4) 启动\n5) 停止\n6) 备份\n7) 准备恢复包下载\n8) 恢复中断更新\n9) 卸载（保留数据）\n10) 检查更新\n11) 清理旧镜像（保留当前和上一版）\n0) 退出\n'
  read_terminal '选择：' selection
  case "$selection" in
    1) operation=install ;;
    2) operation=update ;;
    3) operation=status ;;
    4) operation=start ;;
    5) operation=stop ;;
    6) operation=backup ;;
    7) operation=recovery ;;
    8) operation=recover ;;
    9) operation=uninstall ;;
    10) operation=check ;;
    11) operation=cleanup-images ;;
    0) exit 0 ;;
    *)
      printf '无效选择。\n' >&2
      exit 1
      ;;
  esac
fi
if [ "$docker_available" != true ] && [ "$operation" != install ]; then
  printf '未检测到 Docker；只能执行安装，安装时会询问是否安装 Docker。\n' >&2
  exit 1
fi

confirmation_arguments=()
if [ "$confirmed" = true ]; then
  confirmation_arguments=(--yes)
fi

require_existing_deployment() {
  if [ ! -f "$deployment_directory/.env" ] || [ -L "$deployment_directory/.env" ] \
    || [ ! -f "$deployment_directory/ops/lib/deployment.sh" ]; then
    printf '未找到完整部署配置：%s。不会生成替代密钥。\n' "$deployment_directory" >&2
    exit 1
  fi
}

confirm_action() {
  if [ "$confirmed" = true ]; then
    return
  fi
  local answer
  read_terminal "$1 [y/N] " answer
  if [ "$answer" != y ] && [ "$answer" != Y ]; then
    printf '已取消。\n'
    exit 0
  fi
}

download_file() {
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 180 --retry 3 --max-filesize 10485760 --output "$2" "$1"
}

fetch_package() {
  if [[ ! "$repository" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    printf 'GitHub 发布仓库尚未配置，请使用 --repository OWNER/REPOSITORY。\n' >&2
    exit 1
  fi
  mkdir -p -- "$deployment_directory"
  if [ "$(realpath -e -- "$deployment_directory")" != "$deployment_directory" ]; then
    printf '部署目录通过父级链接跳出了预期路径。\n' >&2
    exit 1
  fi
  for relative_directory in .local .local/packages; do
    if [ -L "$deployment_directory/$relative_directory" ]; then
      printf '拒绝链接维护目录。\n' >&2
      exit 1
    fi
    mkdir -p -- "$deployment_directory/$relative_directory"
    chmod 0700 -- "$deployment_directory/$relative_directory"
  done
  package_stage=$(mktemp -d "$deployment_directory/.local/packages/download-XXXXXXXX")
  download_file "https://raw.githubusercontent.com/$repository/main/channel.env" "$package_stage/channel.env"
  declare -A channel=()
  local channel_line field_name field_value
  while IFS= read -r channel_line || [ -n "$channel_line" ]; do
    channel_line=${channel_line%$'\r'}
    field_name=${channel_line%%=*}
    field_value=${channel_line#*=}
    case "$field_name" in
      FORMAT | VERSION | REVISION | SHA256 | CONTRACT) ;;
      *)
        printf '无效 GitHub 发布索引字段。\n' >&2
        exit 1
        ;;
    esac
    if [ -n "${channel[$field_name]+present}" ]; then
      printf '重复 GitHub 发布索引字段。\n' >&2
      exit 1
    fi
    channel[$field_name]=$field_value
  done < "$package_stage/channel.env"
  if [ "${channel[FORMAT]:-}" != 1 ] || [ "${channel[CONTRACT]:-}" != 1 ] \
    || [[ ! "${channel[VERSION]:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9][a-z0-9.-]*)?$ ]] \
    || [[ ! "${channel[REVISION]:-}" =~ ^r[1-9][0-9]*$ ]] \
    || [[ ! "${channel[SHA256]:-}" =~ ^[a-f0-9]{64}$ ]]; then
    printf 'GitHub 发布索引无效或部署契约不兼容；未替换任何文件。\n' >&2
    exit 1
  fi
  package_version=${channel[VERSION]}
  package_revision=${channel[REVISION]}
  local filename="xmhkmail-deploy-$package_version-$package_revision.tar.gz"
  download_file "https://github.com/$repository/releases/download/$package_version-$package_revision/$filename" "$package_stage/package.tar.gz"
  printf '%s  %s\n' "${channel[SHA256]}" "$package_stage/package.tar.gz" | sha256sum --check --status
  tar -tzf "$package_stage/package.tar.gz" > "$package_stage/contents.txt"
  tar -tvzf "$package_stage/package.tar.gz" > "$package_stage/types.txt"
  # No links, devices, directories or traversal; package builder emits regular allowlisted files only.
  if grep -v '^-' "$package_stage/types.txt" > /dev/null; then
    printf '部署包包含链接或特殊文件，拒绝解压。\n' >&2
    exit 1
  fi
  if ! awk '{total += $3} END {exit (total > 16777216)}' "$package_stage/types.txt"; then
    printf '部署包解压大小超过限制，拒绝解压。\n' >&2
    exit 1
  fi
  package_files=(
    compose.yaml compose.restore.yaml README.md
    releases/default-release.txt "releases/$package_version.env"
    ops/install.sh ops/update.sh ops/setup.sh ops/stack.sh
    ops/backup.sh ops/restore.sh ops/release.sh ops/package.sh ops/schema-fingerprint.sh
    ops/bootstrap.sh ops/recovery.sh
    ops/Caddyfile ops/app/start.sh ops/mail/install-packages.sh ops/mail/policy-rc.d
    ops/postgres/create-roles.sql ops/postgres/entrypoint.sh ops/postgres/roles.sh
    ops/lib/deployment.sh ops/lib/host.sh ops/lib/install-prompts.sh
    ops/lib/publishing.sh ops/lib/releases.sh ops/lib/setup-input.sh
    docs/first-deployment.md docs/updates.md docs/backups.md docs/github-deployment.md docs/recovery-download.md
    docs/rc3-release-preparation.md docs/rc3-release-results.md docs/rc3-script-r2-results.md
    docs/rc3-script-r3-results.md
  )
  printf 'xmhkmail/%s\n' "${package_files[@]}" | sort > "$package_stage/expected.txt"
  sort "$package_stage/contents.txt" > "$package_stage/actual.txt"
  if ! cmp -s "$package_stage/expected.txt" "$package_stage/actual.txt"; then
    printf '部署包文件不在精确白名单中；未解压、未替换配置。\n' >&2
    exit 1
  fi
  mkdir -- "$package_stage/extracted"
  tar -xzf "$package_stage/package.tar.gz" --no-same-owner --no-same-permissions --directory="$package_stage/extracted"
  package_workspace="$package_stage/extracted/xmhkmail"
  source "$package_workspace/ops/lib/releases.sh"
  local package_manifest
  package_manifest=$(release_default_file "$package_workspace")
  release_read "$package_manifest"
  if [ "${release_values[VERSION]}" != "$package_version" ] || [ "${release_values[DEPLOYMENT_CONTRACT]}" != 1 ]; then
    printf '部署包与发布索引不匹配。\n' >&2
    exit 1
  fi
}

configuration_templates_match() {
  local installed_template=$1
  local supplied_template=$2
  if cmp -s "$installed_template" "$supplied_template"; then
    return 0
  fi
  # A previous verified Windows-built package shipped CRLF templates. Ignore
  # only the CR at line endings, not comments, whitespace or configuration.
  cmp -s <(sed 's/\r$//' "$installed_template") <(sed 's/\r$//' "$supplied_template")
}

refresh_public_files() (
  if [ -f "$deployment_directory/.env" ]; then
    source "$deployment_directory/ops/lib/deployment.sh"
    deployment_initialize
    deployment_lock
    deployment_check_ownership
    deployment_check_busy_containers
  fi
  local relative_file target_file parent_directory
  # Validate every target before the first replacement. Private state is never on this list.
  for relative_file in "${package_files[@]}"; do
    target_file="$deployment_directory/$relative_file"
    parent_directory=${target_file%/*}
    if [ -L "$target_file" ] || [ -L "$parent_directory" ] \
      || [ "$(realpath -m -- "$target_file")" != "$target_file" ]; then
      printf '拒绝替换链接或越界文件：%s\n' "$relative_file" >&2
      exit 1
    fi
    case "$relative_file" in
      compose.yaml | compose.restore.yaml | ops/Caddyfile | ops/postgres/*)
        if [ -e "$target_file" ] && ! configuration_templates_match "$target_file" "$package_workspace/$relative_file"; then
          printf '配置模板 %s 已修改；不会覆盖自定义配置，请先核对差异。\n' "$relative_file" >&2
          printf '待核对文件：%s\n已验证的新模板：%s\n' "$target_file" "$package_workspace/$relative_file" >&2
          exit 1
        fi
        ;;
    esac
    # Release history is immutable. An existing same-name manifest must match.
    if [[ "$relative_file" == releases/*.env ]] && [ -e "$target_file" ] \
      && ! cmp -s "$target_file" "$package_workspace/$relative_file"; then
      printf '现有发行清单内容不同，拒绝覆盖历史。\n' >&2
      exit 1
    fi
  done
  mkdir -- "$package_stage/previous-public-files"
  for relative_file in "${package_files[@]}"; do
    target_file="$deployment_directory/$relative_file"
    if [ -f "$target_file" ]; then
      mkdir -p -- "$package_stage/previous-public-files/$(dirname -- "$relative_file")"
      cp -p -- "$target_file" "$package_stage/previous-public-files/$relative_file"
    fi
    mkdir -p -- "${target_file%/*}"
    temporary_target=$(mktemp "${target_file%/*}/.xmhkmail-file-XXXXXXXX")
    install -m 0644 -- "$package_workspace/$relative_file" "$temporary_target"
    mv -T -- "$temporary_target" "$target_file"
  done
  printf '公共脚本已刷新：%s-%s。私有配置、密钥、备份与数据卷未替换。\n' "$package_version" "$package_revision"
)

case "$operation" in
  install | update | check)
    if [ "$operation" != install ]; then
      require_existing_deployment
    fi
    if [ "$operation" = install ]; then
      confirm_action "将在 $deployment_directory 安装，已有配置只复用。继续？"
    fi
    fetch_package
    if [ "$operation" = check ]; then
      bash "$deployment_directory/ops/update.sh" check "$package_workspace/releases/$package_version.env"
      printf 'GitHub 版本：%s-%s；只检查，未替换公共文件。\n' "$package_version" "$package_revision"
      exit 0
    fi
    refresh_public_files
    case "$operation" in
      install)
        if [ -f "$deployment_directory/.env" ]; then
          run_interactive_script "$deployment_directory/ops/install.sh" --resume \
            "${docker_installation_arguments[@]}" "${confirmation_arguments[@]}"
        else
          run_interactive_script "$deployment_directory/ops/install.sh" "${install_arguments[@]}" \
            "${docker_installation_arguments[@]}" "${confirmation_arguments[@]}"
        fi
        ;;
      update) run_interactive_script "$deployment_directory/ops/update.sh" apply "${confirmation_arguments[@]}" ;;
      check) bash "$deployment_directory/ops/update.sh" check ;;
    esac
    ;;
  status | start | stop | backup | recovery | recover | cleanup-images)
    require_existing_deployment
    case "$operation" in
      status) bash "$deployment_directory/ops/update.sh" status ;;
      start) bash "$deployment_directory/ops/stack.sh" up ;;
      stop)
        confirm_action '将停止邮件和网页服务。继续？'
        bash "$deployment_directory/ops/stack.sh" stop
        ;;
      backup)
        confirm_action '将执行离线加密备份，邮件和网页暂时停止。继续？'
        bash "$deployment_directory/ops/backup.sh" run
        ;;
      recovery) bash "$deployment_directory/ops/recovery.sh" prepare ;;
      recover) run_interactive_script "$deployment_directory/ops/update.sh" recover "${confirmation_arguments[@]}" ;;
      cleanup-images)
        run_interactive_script "$deployment_directory/ops/update.sh" cleanup-images "${confirmation_arguments[@]}"
        ;;
    esac
    ;;
  uninstall)
    require_existing_deployment
    confirm_action '卸载本项目容器，保留所有数据、密钥和备份。继续？'
    source "$deployment_directory/ops/lib/deployment.sh"
    deployment_initialize
    deployment_lock
    deployment_check_ownership
    deployment_check_busy_containers
    if docker container inspect "${deployment_project_name}-recovery-export" > /dev/null 2>&1; then
      printf '临时恢复包正在服务；请先确认保存或等待过期后卸载。\n' >&2
      exit 1
    fi
    deployment_compose down
    printf '本项目容器已卸载；数据卷、配置、密钥、备份和镜像全部保留。\n'
    printf '重新启动：bash xmhkmail.sh start --directory %s\n' "$deployment_directory"
    ;;
esac
