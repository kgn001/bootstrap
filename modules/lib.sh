#!/usr/bin/env bash
# modules/lib.sh - helper functions sourced by each module

# --------------------------------------------------
# Dry run functions
# --------------------------------------------------
# $dry is exported by ./setup, default to 0 if run standalone
dry="${dry:-0}"

log() {
	if [[ $dry == "1" ]]; then
		echo "[DRY_RUN]: $@"
	else
		echo "$@"
	fi
}

execute() {
	log "  execute $@"
        if [[ $dry == "1" ]]; then
                return
        fi

	"$@"
}

confirm() {
	# auto decline for dry runs
	if [[ $dry == "1" ]]; then
		log "$1 [y/N] - automatic No"
		return 1
	fi
	read -r -p "$1 [y/N] " reply
	[[ $reply =~ ^[Yy]$ ]]
}

# --------------------------------------------------
# System detection
# --------------------------------------------------

case "$(uname -s)" in
	Darwin) 
		PM="brew"
		OS_TAG="macos"
		;;
	Linux)  
		PM="apt"
		OS_TAG="linux"
		;;
	*)
		echo "lib.sh: unsupported OS: $(uname -s)" >&2
		return 1
		;;
esac

case "$(uname -m)" in
	arm64|aarch64) ARCH_TAG="arm64" ;;
	x86_64)        ARCH_TAG="x86_64" ;;
	*)
		echo "lib.sh: unsupported architecture: $(uname -m)" >&2
		return 1
		;;
esac

LOCAL_PREFIX="$HOME/.local"
LOCAL_BIN="$LOCAL_PREFIX/bin"

# --------------------------------------------------
# Package manager functions
# --------------------------------------------------


pkg_installed() { command -v "$1" >/dev/null 2>&1; }

pkg_install() {
	if [[ $PM == "brew" ]]; then
		execute brew install "$1"
	else
		execute sudo apt-get install -y "$1"
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
	local version
	if [[ $PM == "brew" ]]; then
		version=$(brew info --json=v2 "$1" 2>/dev/null \
			| tr -d ' \t\n' \
			| grep -o '"stable":"[^"]*"' \
			| head -1 | cut -d'"' -f4)
	else
		version=$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2}')
	fi
	version="${version#*:}"
	version="${version%%-*}"
	printf '%s' "$version"
}

# default version check if a custom version function is not passed in
tool_version() {
	"$1" --version 2>&1 | head -1
}

# --------------------------------------------------
# GitHub install functions
# --------------------------------------------------

github_latest_tag() {
	curl -fsSL "https://api.github.com/repos/$1/releases/latest" \
		| grep '"tag_name":' | head -1 | cut -d'"' -f4
}

ensure_github_release() {
	local cmd="$1" repo="$2" version_fn="$3" asset_tpl="$4" pinned="${5:-}"

	local want="$pinned"
	if [[ -n $want ]]; then
		log " $cmd: pinned to $want"
	else
		want=$(github_latest_tag "$repo")
		[[ -z $want ]] && { log " $cmd: could not query latest release"; return 1; }
	fi

	if command -v "$cmd" >/dev/null 2>&1; then
		local current
		current=$("$version_fn" 2>/dev/null)
		if [[ $current == *"${want#v}"* ]]; then
			if [[ -n $pinned ]]; then
				local newest
				newest=$(github_latest_tag "$repo")
				if [[ -n $newest && $newest != "$want" ]]; then
					log " $cmd: currently at version $want ($newest available - edit module to update)"
					return
				fi
			fi
			log " $cmd: up to date ($current)"
			return
		fi
		log " $cmd: $current -> $want available"
		confirm "Update $cmd to $want?" || return
	else
		log " $cmd: not installed, will fetch $want"
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

	execute cp -R "$temp/bin" "$temp/lib" "$temp/share" "$LOCAL_PREFIX/" 2>/dev/null
	rm -rf "$temp"
	log " $cmd: installed $want to $LOCAL_PREFIX"
}

# --------------------------------------------------
# Main
# --------------------------------------------------

ensure() {
	local cmd="$1" pkg="${2:-$1}" version_fn="${3:-}"

	if ! pkg_installed "$cmd"; then
		log " $cmd: not installed"
		pkg_install "$pkg"
		return
	fi

	local current
	if [[ -n $version_fn ]]; then
		current=$("$version_fn" 2>/dev/null)
	else
		current=$(tool_version "$cmd" 2>/dev/null)
	fi

	local latest
	latest=$(pkg_latest "$pkg")
	if [[ -z $latest ]]; then
		log " $cmd: $current already installed, but $PM has no candidate for '$pkg'"
	elif [[ $current != *"$latest"* ]]; then
		log " $cmd: update available ($current -> $latest)"
		confirm "  upgrade $cmd?" && pkg_upgrade "$pkg"
	else
		log " $cmd: up to date ($current)"
	fi
}

