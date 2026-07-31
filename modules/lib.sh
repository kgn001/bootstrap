#!/usr/bin/bash/env bash
# runs/lib.sh - shared helpers, sourced by each install script

# $dry is exported by ./run, default to 0 if run standalone
dry="${dry:-0}"

# -- Check which pkg manager to use --

log() {
	if [[ $dry == "1" ]]; then
		echo "[DRY_RUN]: $@"
	else
		echo "$@"
	fi
}

execute() {
	log "execute $@"
        if [[ $dry == "1" ]]; then
                return
        fi

	"$@"
}

case "$(uname -s)" in
	Darwin) PM="brew" ;;
	Linux)  PM="apt" ;;
esac
case "$(uname -s)" in
	Darwin) OS_TAG="macos" ;;
	Linux)  OS_TAG="linux" ;;
esac
case "$(uname -m)" in
	arm64|aarch64) ARCH_TAG="arm64" ;;
	x86_64)        ARCH_TAG="x86_64" ;;
esac

LOCAL_BIN="$HOME/.local/bin"

github_latest_tag() {
	curl -fsSL "https://api.github.com/repos/$1/releases/latest" \
		| grep '"tag_name":' | head -1 | cut -d'"' -f4
}

ensure_github_release() {
	local cmd="$1" repo="$2" version_fn="$3" asset_tpl="$4" pinned="${5:-}"

	local want="$pinned"
	if [[ -z $want ]]; then
		want=$(github_latest_tag "$repo")
		[[ -z $want ]] && { log "$cmd: could not query latest release"; return 1; }
	fi

	if command -v "$cmd" >/dev/null 2>&1; then
		local current
		current=$("$version_fn" 2>/dev/null)
		log "$cmd: installed ($current)"
		if [[ $current == *"${want#v}"* ]]; then
			log "$cmd: up to date ($want)"
			return
		fi
		log "$cmd: $current -> $want available"
		confirm "Update $cmd to $want?" || return
	else
		log "$cmd: not installed, will fetch $want"
	fi

	local asset="${asset_tpl//\{os\}/$OS_TAG}"
	asset="${asset//\{arch\}/$ARCH_TAG}"
	asset="${asset//\{tag\}/$want}"

	local url="https://github.com/$repo/releases/download/$want/$asset"
	local temp
	temp=$(mktemp -d) || return 1
	execute mkdir -p "$LOCAL_BIN"
	execute curl -fsSL "$url" -o "$temp/$asset"
	execute tar -xzf "$temp/$asset" -C "$temp" --strip-components=1
	execute cp -r "$temp/bin/." "$LOCAL_BIN/"
	execute rm -rf "$temp"
	log "$cmd: installed $want to $LOCAL_BIN"
}


pkg_installed() { command -v "$1" >/dev/null 2>&1; }

pkg_install() {
	local pkg="$1" version="${2:-}"
	if [[ $PM == "brew" ]]; then
		if [[ -n $version ]]; then
			execute brew install "${pkg}@${version}"
		else
			execute brew install "$pkg"
		fi
	else
		if [[ -n $version ]]; then
			execute sudo apt-get install -y "${pkg}=${version}"
		else
			execute sudo apt-get install -y "$pkg"
		fi
	fi
}

pkg_upgrade() {
	if [[ $PM == "brew" ]]; then
		execute brew upgrade "$1"
	else
		execute sudo apt-get install -y --only-upgrade "$1"
	fi
}

# Latest version available on pkg manager
pkg_latest() {
	if [[ $PM == "brew" ]]; then
		brew info --json=v2 "$1" 2>/dev/null \
			| grep -o '"stable":"[^"]*"' | head -1 | cut -d'"' -f4
	else
		apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2}'
	fi
}

confirm() {
	# auto decline for dry runs
	if [[ $dry == "1" ]]; then
		log "would prompt: $1 [y/N"
		return 1
	fi
	read -r -p "$1 [y/N " reply
	[[ $reply =~ ^[Yy]$ ]]
}

# Each script calls this
ensure() {
	local cmd="$1" pkg="$2" version_cmd="$3" pinned="${4:-}"

	if ! pkg_installed "$cmd"; then
		log "$cmd: not installed"
		pkg_install "$pkg" "$pinned"
		return
	fi

	local current
	current=$("$version_cmd" 2>/dev/null)
	log "$cmd: installed ($current)"

	# Pinned version: never auto-upgrade
	if [[ -n $pinned ]]; then
		if [[ $current != *"pinned"* ]]; then
			log "$cmd: pinned to $pinned but $current is installed"
			confirm "Reinstall $cmd at pinned version $pinned?" && pkg_install "$pkg" "$pinned"
		fi
		return
	fi

	local latest
	latest=$(pkg_latest "$pkg")
	if [[ -n $latest && $current != *"$latest"* ]]; then
		log "$cmd: update available ($current -> $latest)"
		confirm "Upgrade $cmd?" && pkg_upgrade "$pkg"
	else
		log "$cmd: up to date"
	fi
}

