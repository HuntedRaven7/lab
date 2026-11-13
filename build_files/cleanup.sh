#!/usr/bin/env bash

set -euo pipefail

CLEAN_ROOT="${CLEAN_ROOT:-/}"
REPOS_DIR="${CLEAN_ROOT}/etc/yum.repos.d"

dnf5 config-manager unsetopt keepcache install_weak_deps
dnf5 versionlock clear

disable_repo_file() {
	[[ -f "$1" ]] || return 0
	sed -i -E 's@^[[:space:]]*enabled[[:space:]]*=.*@enabled=0@I' "$1"
}

third_party_repo_files=(
	"${REPOS_DIR}"/_copr:*.repo
	"${REPOS_DIR}"/_copr_*.repo
	"${REPOS_DIR}"/rpmfusion-*.repo
)
for repo_name in fedora-multimedia fedora-cisco-openh264 fedora-coreos-pool; do
	third_party_repo_files+=("${REPOS_DIR}/${repo_name}.repo")
done

if command -v rpm >/dev/null 2>&1; then
	for repo_file in "${REPOS_DIR}"/*.repo; do
		[[ -f "${repo_file}" ]] || continue
		rpm -qf "${repo_file}" >/dev/null 2>&1 && continue
		third_party_repo_files+=("${repo_file}")
	done
fi

declare -A third_party_seen=()
third_party_unique=()
for repo_file in "${third_party_repo_files[@]}"; do
	[[ -n "${third_party_seen["${repo_file}"]:-}" ]] && continue
	third_party_seen["${repo_file}"]=1
	third_party_unique+=("${repo_file}")
done
third_party_repo_files=("${third_party_unique[@]}")

for repo_file in "${third_party_repo_files[@]}"; do
	disable_repo_file "${repo_file}"
done

if ! repo_list="$(dnf5 -q repo list --enabled)"; then
	echo "::error::could not query enabled repositories with dnf5" >&2
	exit 1
fi
live="$(printf '%s\n' "${repo_list}" | awk '
	BEGIN { split("fedora updates fedora-updates fedora-cisco-openh264 fedora-updates-archive updates-archive", ok, " "); for (i in ok) allowed[ok[i]] = 1 }
	NF == 0 { next }
	$1 == "repo" && $2 == "id" { next }
	$1 == "Id" || $1 == "Id:" { next }
	!($1 in allowed) { print $1 }
')"
if [ -n "${live}" ]; then
	echo "::error::third-party repository still enabled: ${live}" >&2
	exit 1
fi


systemctl disable rpm-ostreed-automatic.timer 2>/dev/null || true

rm -rf "${CLEAN_ROOT}/.gitkeep"
find "${CLEAN_ROOT}/var" -mindepth 1 -maxdepth 1 -type d \! -name cache -exec rm -fr {} \;
find "${CLEAN_ROOT}/var/cache" -mindepth 1 -maxdepth 1 -type d \! -name libdnf5 \! -name rpm-ostree -exec rm -fr {} \;

for runtime_dir in tmp boot; do
	mkdir -p "${CLEAN_ROOT:?}/${runtime_dir}"
	find "${CLEAN_ROOT:?}/${runtime_dir}" -mindepth 1 -maxdepth 1 -print0 |
		while IFS= read -r -d '' entry; do
			if mountpoint -q "${entry}" 2>/dev/null; then
				continue
			fi
			rm -rf "${entry}"
		done
done

mkdir -p "${CLEAN_ROOT:?}/run"
find "${CLEAN_ROOT:?}/run" -mindepth 1 -depth -print0 |
	while IFS= read -r -d '' entry; do
		if mountpoint -q "${entry}" 2>/dev/null; then
			continue
		fi
		if [[ -d "${entry}" ]]; then
			rmdir "${entry}" 2>/dev/null || true
			continue
		fi
		rm -f "${entry}"
	done
