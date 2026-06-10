#!/usr/bin/env bash
# ============================================================================
#  slsteammoon-ltsteamplugin — one-shot installer
# ============================================================================
#  Installs the full stack in a single command:
#
#    curl -fsSL https://codeberg.org/unplausible/slsteammoon-ltsteamplugin/raw/branch/main/install.sh | bash
#
#  Pipeline:
#    1. Pre-flight checks (not-root, x86_64, internet, NATIVE Steam).
#    2. Runtime dependencies (jq, curl, tar, unzip).
#    3. slsteam-moon   — download latest release, extract, run setup.sh install.
#    4. Lumen          — download latest release into ~/.local/share/Lumen.
#    5. This plugin    — download latest release into ~/.local/share/Lumen/luatools.
#
#  Bilingual (English / Português) based on the system locale.
# ============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# Repositories / release sources
# ----------------------------------------------------------------------------
SLS_REPO="unplausible/slsteam-moon"
SLS_ASSET_PREFIX="slsteam-moon-linux"          # asset is slsteam-moon-linux-<ver>.zip
SLS_TAG="v2.0-lumen"                            # Lumen line: wrapper launches the sidecar

PLUGIN_REPO="unplausible/slsteammoon-ltsteamplugin"
PLUGIN_ASSET="luatools-linux.zip"
PLUGIN_NAME="luatools"                          # plugin.json "name"

LUMEN_REPO="unplausible/lumen"
LUMEN_ASSET="lumen-linux.zip"
LUMEN_DIR="$HOME/.local/share/Lumen"            # binary + lua/ + luatools/

# CloudRedirect (optional) — redirects Steam Cloud for unowned games to the
# user's own Google Drive / OneDrive / local folder. We deploy a PATCHED 32-bit
# hook (cloud_redirect.so) bundled in this repo under cloudredirect/ and load it
# via the Steam wrapper's LD_PRELOAD; the flatpak companion app provides the
# cloud-provider login UI.
#
# Why a bundled build instead of an upstream release asset: no upstream release
# ships both fixes we need. 2.0.4 (the `linux` LD_AUDIT tag) attaches reliably
# but restores saves to a broken "<file>/<sha>" directory layout (games see no
# save). 2.1.5 (`latest`) restores saves correctly but its LD_PRELOAD init
# polls steamclient.so for only 10s and then gives up, so on slower-bootstrap
# distros (Arch/CachyOS) it never attaches. Our build is 2.1.5 with the
# steamclient wait extended to 120s and the CAS-path fix also applied to the
# legacy-migration path. Built for an old-enough glibc to load in the Steam
# runtime. See cloudredirect/README.md. The companion flatpak app is still
# fetched from upstream releases.
PLUGIN_RAW_BASE="https://codeberg.org/${PLUGIN_REPO}/raw/branch/main"
CR_SO_BUNDLED_URL="${PLUGIN_RAW_BASE}/cloudredirect/cloud_redirect.so"
CR_REPO="Selectively11/CloudRedirect"
CR_FLATPAK_APP_ID="org.cloudredirect.CloudRedirect"
CR_DIR="$HOME/.local/share/CloudRedirect"
CR_SO_PATH="$CR_DIR/cloud_redirect.so"
CR_KDE_RUNTIME="org.kde.Platform//6.10"

# ============================================================================
# Pretty output — "moonlit night" palette, matching slsteam-moon's setup.sh.
# Degrades to plain text on dumb / non-TTY terminals.
# ============================================================================
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
	if command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ]; then
		HAS_256=1
	elif [ "${COLORTERM:-}" = "truecolor" ] || [ "${COLORTERM:-}" = "24bit" ]; then
		HAS_256=1
	else
		HAS_256=0
	fi

	BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
	if [ "$HAS_256" = 1 ]; then
		MOON=$'\033[38;5;153m'; NIGHT=$'\033[38;5;75m'; HALO=$'\033[38;5;231m'
		MUTED=$'\033[38;5;110m'; GREEN=$'\033[38;5;114m'; YELLOW=$'\033[38;5;221m'
		RED=$'\033[38;5;203m'
	else
		MOON=$'\033[1;34m'; NIGHT=$'\033[0;36m'; HALO=$'\033[1;37m'
		MUTED=$'\033[0;34m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
		RED=$'\033[0;31m'
	fi
else
	BOLD=""; DIM=""; NC=""
	MOON=""; NIGHT=""; HALO=""; MUTED=""
	GREEN=""; YELLOW=""; RED=""
fi

# ============================================================================
# Localization. L "<english>" "<português>" picks the string for the locale.
# ============================================================================
detect_language() {
	local l="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
	case "$l" in
		pt*|*_BR*|*_PT*) LANG_IS_PT=1 ;;
		*)               LANG_IS_PT=0 ;;
	esac
}

L() { if [ "${LANG_IS_PT:-0}" = 1 ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

log_info()    { echo -e "${NIGHT}→${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }
log_step()    { echo -e "${MOON}•${NC} $1"; }

fail() { log_error "$1"; exit 1; }

print_banner() {
	echo ""
	echo -e "${MOON}${BOLD}"
	echo "┌─────────────────────────────────────────────────────────┐"
	printf "│            ${HALO}${BOLD}◯${NC}${MOON}${BOLD}  slsteammoon · LuaTools installer          │\n"
	echo "└─────────────────────────────────────────────────────────┘"
	echo -e "${NC}"
}

print_section() {
	echo ""
	echo -e "${NIGHT}─────────────────────────────────────────────────────────${NC}"
	echo -e "${NIGHT}${BOLD}❯ $1${NC}"
	echo -e "${NIGHT}─────────────────────────────────────────────────────────${NC}"
}

# ============================================================================
# Distro detection
# ============================================================================
get_distro_family() {
	if [ -f /etc/os-release ]; then
		. /etc/os-release
		if [ "${ID:-}" = "ubuntu" ] || [ "${ID:-}" = "debian" ] || [[ "${ID_LIKE:-}" =~ (debian|ubuntu) ]]; then
			echo "debian"
		elif [ "${ID:-}" = "fedora" ] || [ "${ID:-}" = "rhel" ] || [ "${ID:-}" = "centos" ] || [[ "${ID_LIKE:-}" =~ (fedora|rhel) ]]; then
			echo "fedora"
		elif [ "${ID:-}" = "arch" ] || [[ "${ID_LIKE:-}" =~ arch ]]; then
			echo "arch"
		elif [[ "${ID:-}" =~ opensuse ]] || [[ "${ID_LIKE:-}" =~ opensuse ]]; then
			echo "opensuse"
		else
			echo "unknown"
		fi
	else
		echo "unknown"
	fi
}

# Privilege-escalation prefix for system package operations.
sudo_prefix() {
	if [ "$(id -u)" -eq 0 ]; then
		echo ""
	elif command -v sudo >/dev/null 2>&1; then
		echo "sudo"
	else
		echo ""
	fi
}

# ============================================================================
# Pre-flight checks
# ============================================================================
check_not_root() {
	if [ "$(id -u)" -eq 0 ]; then
		fail "$(L "Do not run this installer as root. Run it as your normal user." \
		          "Não rode este instalador como root. Rode como seu usuário normal.")"
	fi
}

check_arch() {
	if [ "$(uname -m)" != "x86_64" ]; then
		fail "$(L "Unsupported architecture: $(uname -m). Only x86_64 is supported." \
		          "Arquitetura não suportada: $(uname -m). Apenas x86_64 é suportado.")"
	fi
	log_success "$(L "Architecture x86_64 OK" "Arquitetura x86_64 OK")"
}

check_internet() {
	if ! curl -fsS --head "https://codeberg.org" >/dev/null 2>&1; then
		fail "$(L "No internet connection." "Sem conexão com a internet.")"
	fi
	log_success "$(L "Internet reachable" "Internet acessível")"
}

# How is Steam installed? native / flatpak / snap / none.
detect_steam_type() {
	# A native package-manager install puts the launcher in a system bin dir.
	for c in /usr/bin/steam /usr/games/steam /usr/local/bin/steam /bin/steam; do
		if [ -x "$c" ]; then
			echo "native"
			return
		fi
	done
	if command -v flatpak >/dev/null 2>&1 && flatpak list 2>/dev/null | grep -qi "com.valvesoftware.Steam"; then
		echo "flatpak"
		return
	fi
	if command -v snap >/dev/null 2>&1 && snap list 2>/dev/null | grep -qi "^steam "; then
		echo "snap"
		return
	fi
	echo "none"
}

suggest_native_steam_install() {
	case "$(get_distro_family)" in
		debian)   echo "sudo apt update && sudo apt install steam-installer" ;;
		fedora)   echo "sudo dnf install steam" ;;
		arch)     echo "sudo pacman -S steam" ;;
		opensuse) echo "sudo zypper install steam" ;;
		*)        echo "$(L "see your distro's documentation to install native Steam" \
		                    "consulte a documentação da sua distro para instalar a Steam nativa")" ;;
	esac
}

check_steam_native() {
	local steam_type
	steam_type="$(detect_steam_type)"

	case "$steam_type" in
		native)
			log_success "$(L "Native Steam detected" "Steam nativa detectada")"
			;;
		flatpak|snap)
			echo ""
			log_error "$(L "Steam was installed via ${steam_type^}." \
			              "A Steam foi instalada via ${steam_type^}.")"
			echo ""
			echo -e "  $(L "slsteam-moon only works with NATIVE Steam" \
			               "slsteam-moon só funciona com a Steam NATIVA")"
			echo -e "  $(L "(the one from your package manager)." \
			               "(a do seu gerenciador de pacotes).")"
			echo ""
			echo -e "  $(L "1) Uninstall the ${steam_type^} version:" \
			               "1) Desinstale a versão ${steam_type^}:")"
			if [ "$steam_type" = "flatpak" ]; then
				echo -e "       ${GREEN}flatpak uninstall com.valvesoftware.Steam${NC}"
			else
				echo -e "       ${GREEN}sudo snap remove steam${NC}"
			fi
			echo -e "  $(L "2) Install native Steam:" "2) Instale a Steam nativa:")"
			echo -e "       ${GREEN}$(suggest_native_steam_install)${NC}"
			echo ""
			fail "$(L "Aborted. Please install native Steam and re-run this installer." \
			          "Abortado. Instale a Steam nativa e rode este instalador novamente.")"
			;;
		none|*)
			echo ""
			log_error "$(L "No native Steam installation found." \
			              "Nenhuma instalação nativa da Steam encontrada.")"
			echo ""
			echo -e "  $(L "Install native Steam (from your package manager) first:" \
			               "Instale a Steam nativa (do seu gerenciador de pacotes) primeiro:")"
			echo -e "       ${GREEN}$(suggest_native_steam_install)${NC}"
			echo ""
			fail "$(L "Aborted. Please install native Steam and re-run this installer." \
			          "Abortado. Instale a Steam nativa e rode este instalador novamente.")"
			;;
	esac
}

# ============================================================================
# Runtime dependencies
# ============================================================================
# Map a generic tool name to the package that provides it on each family.
pkg_for() {
	local tool="$1" family="$2"
	case "$tool" in
		jq)
			echo "jq" ;;
		curl)
			echo "curl" ;;
		tar)
			echo "tar" ;;
		unzip)
			echo "unzip" ;;
		notify-send)
			# slsteam-moon shells out to notify-send for in-Steam status
			# popups (download progress, errors). Missing on minimal
			# installs; package name varies per family.
			case "$family" in
				debian)   echo "libnotify-bin" ;;
				fedora)   echo "libnotify" ;;
				arch)     echo "libnotify" ;;
				opensuse) echo "libnotify-tools" ;;
				*)        echo "libnotify" ;;
			esac
			;;
	esac
}

pm_install() {
	local family="$1"; shift
	local sudo_cmd; sudo_cmd="$(sudo_prefix)"
	case "$family" in
		debian)
			$sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
			$sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
			;;
		fedora)
			$sudo_cmd dnf install -y "$@"
			;;
		arch)
			$sudo_cmd pacman -S --noconfirm "$@"
			;;
		opensuse)
			$sudo_cmd zypper install -y "$@"
			;;
		*)
			return 1
			;;
	esac
}

# Ensure the generic CLI tools this installer + the stack need are present.
install_dependencies() {
	local family; family="$(get_distro_family)"

	log_info "$(L "Checking required tools (jq, curl, tar, unzip, notify-send)" \
	             "Verificando ferramentas necessárias (jq, curl, tar, unzip, notify-send)")"

	local missing_pkgs=() tool
	for tool in jq curl tar unzip notify-send; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			missing_pkgs+=("$(pkg_for "$tool" "$family")")
		fi
	done

	if [ "${#missing_pkgs[@]}" -gt 0 ]; then
		log_warn "$(L "Installing missing tools: ${missing_pkgs[*]}" \
		             "Instalando ferramentas ausentes: ${missing_pkgs[*]}")"
		if [ "$family" = "unknown" ]; then
			fail "$(L "Unknown distro — please install manually: ${missing_pkgs[*]}" \
			          "Distro desconhecida — instale manualmente: ${missing_pkgs[*]}")"
		fi
		if ! pm_install "$family" "${missing_pkgs[@]}"; then
			fail "$(L "Failed to install: ${missing_pkgs[*]}. Install them manually and re-run." \
			          "Falha ao instalar: ${missing_pkgs[*]}. Instale manualmente e rode de novo.")"
		fi
	fi
	log_success "$(L "Required tools present" "Ferramentas necessárias presentes")"
}

# ============================================================================
# Cleanup: remove leftovers from the old LuaToolsLinux / headcrab port
# ============================================================================
# The previous Linux port (Star123451/LuaToolsLinux + ciscosweater/aglairdev
# enter-the-wired + Deadboy666/h3adcr-b) drops files that fight this stack:
#   - an old Millennium plugin dir (with a Python .venv)
#   - a headcrab-patched ~/.steam/steam/steam.sh + client.sh that hijacks
#     Steam's bootstrapper
#   - a steam.cfg with BootStrapperInhibitAll=enable (blocks Steam updates)
#   - ~/.headcrab and a headcrab desktop entry/icon (CloudRedirect is kept —
#     we manage it ourselves for cloud saves, see install_cloudredirect)
#   - an enter-the-wired SLSsteam install at ~/.local/share/SLSsteam
#   - on Arch, a system slssteam / slssteam-git package
#
# This is best-effort: every removal is guarded and never aborts the install.
# The user's depot keys (~/.config/SLSsteam) and ACCELA are left untouched.

# Detect a foreign (headcrab-style) internal steam.sh and put the genuine
# Valve one back. The real steam.sh is a large launcher that references
# bootstrap.tar.xz; the hijacked wrapper is tiny and sources client.sh /
# injects SLSsteam instead. We restore from the data-dir bootstrap.tar.xz
# (what Steam itself re-bootstraps from), then the system bootstrap tarball,
# and as a last resort just remove it so Steam regenerates it on next launch.
restore_steam_sh() {
	local steam_root="$1"
	local sh="$steam_root/steam.sh"

	[ -f "$sh" ] || return 0

	# Genuine Valve steam.sh always mentions bootstrap.tar.xz. If it does and
	# it does not inject SLSsteam, it's already clean — leave it alone.
	if grep -q "bootstrap.tar.xz" "$sh" 2>/dev/null \
	   && ! grep -qiE "SLSsteam|client\.sh|headcrab|LD_AUDIT" "$sh" 2>/dev/null; then
		return 0
	fi

	log_step "$(L "Restoring Steam's original steam.sh (was hijacked by the old port)" \
	             "Restaurando o steam.sh original da Steam (sequestrado pelo port antigo)")"

	# Resolve the data dir steam.sh actually lives in (follow the symlink).
	local data_dir
	data_dir="$(readlink -f "$steam_root" 2>/dev/null || echo "$steam_root")"

	mv -f "$sh" "$sh.old-port-bak" 2>/dev/null || rm -f "$sh" 2>/dev/null || true

	# 1) Steam's own bootstrap copy in the data dir.
	local boot="$data_dir/bootstrap.tar.xz"
	if [ -f "$boot" ] && tar xJf "$boot" -C "$data_dir" steam.sh 2>/dev/null; then
		chmod +x "$data_dir/steam.sh" 2>/dev/null || true
		log_success "$(L "Restored steam.sh from bootstrap.tar.xz" \
		             "steam.sh restaurado a partir do bootstrap.tar.xz")"
		return 0
	fi

	# 2) The system-wide bootstrap tarball shipped by the steam package.
	local sys_boot
	for sys_boot in \
		/usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz \
		/usr/share/steam/bootstraplinux_ubuntu12_32.tar.xz; do
		if [ -f "$sys_boot" ] && tar xJf "$sys_boot" -C "$data_dir" steam.sh 2>/dev/null; then
			chmod +x "$data_dir/steam.sh" 2>/dev/null || true
			log_success "$(L "Restored steam.sh from the system bootstrap" \
			             "steam.sh restaurado a partir do bootstrap do sistema")"
			return 0
		fi
	done

	# 3) Nothing to restore from — leaving it absent makes Steam re-extract a
	#    clean steam.sh from bootstrap.tar.xz on the next launch.
	log_warn "$(L "Removed hijacked steam.sh; Steam will regenerate it on next launch" \
	             "steam.sh sequestrado removido; a Steam vai regenerá-lo no próximo início")"
}

# Stop any running Steam so the cleanup/install can safely modify Steam's
# files (steam.sh, the Millennium plugin dir, config.json). Tries a graceful
# shutdown first, then SIGTERM, then SIGKILL. Mirrors slsteam-moon setup.sh.
stop_steam() {
	if ! pgrep -x steam >/dev/null 2>&1 \
	   && ! pgrep -f 'steamwebhelper' >/dev/null 2>&1 \
	   && ! pgrep -f '/steam$|/steam ' >/dev/null 2>&1; then
		log_success "$(L "No running Steam process detected" "Nenhum processo da Steam em execução")"
		return 0
	fi

	log_info "$(L "Stopping running Steam" "Parando a Steam em execução")"

	# Graceful: ask Steam to shut itself down.
	if command -v steam >/dev/null 2>&1; then
		steam -shutdown >/dev/null 2>&1 || true
	fi

	local i
	for i in 1 2 3 4 5 6 7 8; do
		if ! pgrep -x steam >/dev/null 2>&1 \
		   && ! pgrep -f 'steamwebhelper' >/dev/null 2>&1; then
			log_success "$(L "Steam stopped" "Steam parada")"
			return 0
		fi
		sleep 1
	done

	# Escalate to SIGTERM.
	pkill -TERM -x steam 2>/dev/null || true
	pkill -TERM -f 'steamwebhelper' 2>/dev/null || true
	pkill -TERM -f '/steam$|/steam ' 2>/dev/null || true
	sleep 2

	# Last resort: SIGKILL.
	if pgrep -x steam >/dev/null 2>&1 \
	   || pgrep -f 'steamwebhelper' >/dev/null 2>&1 \
	   || pgrep -f '/steam$|/steam ' >/dev/null 2>&1; then
		log_warn "$(L "Steam still running — forcing it to stop" "Steam ainda rodando — forçando o encerramento")"
		pkill -KILL -x steam 2>/dev/null || true
		pkill -KILL -f 'steamwebhelper' 2>/dev/null || true
		pkill -KILL -f '/steam$|/steam ' 2>/dev/null || true
		sleep 1
	fi

	log_success "$(L "Steam stopped" "Steam parada")"
}

cleanup_previous_install() {
	local steam_root="$HOME/.steam/steam"

	# --- Old Millennium plugin directories --------------------------------
	# The previous port and this plugin both install under a dir named
	# "luatools" (the old "LuaToolsLinux" name is also possible). We only
	# remove the OLD port here — detected by its Python backend
	# (backend/main.py / a .venv). Our own plugin (Lua backend, has
	# backend/platform.lua) is left in place so install_plugin can update it
	# while preserving the user's settings. The "LuaToolsLinux" name is
	# always the old port, so it's removed unconditionally.
	local roots=(
		"$HOME/.local/share/millennium/plugins"
		"$HOME/.millennium/plugins"
		"$HOME/.steam/steam/millennium/plugins"
		"$HOME/.steam/steam/steamui/millennium/plugins"
		"$HOME/.local/share/Steam/millennium/plugins"
	)
	local root name p
	for root in "${roots[@]}"; do
		for name in luatools LuaToolsLinux; do
			p="$root/$name"
			[ -d "$p" ] || continue
			# Keep our own Lua-backend plugin (updated later in place).
			if [ "$name" = "luatools" ] \
			   && [ ! -f "$p/backend/main.py" ] && [ ! -d "$p/.venv" ] \
			   && [ -f "$p/backend/platform.lua" ]; then
				continue
			fi
			log_step "$(L "Removing old plugin: $p" "Removendo plugin antigo: $p")"
			rm -rf "$p" 2>/dev/null || true
		done
	done

	# --- Old luatools data/config dirs ------------------------------------
	local d
	for d in "$HOME/.local/share/luatools" "$HOME/.config/luatools" "$HOME/.luatools"; do
		if [ -e "$d" ]; then
			log_step "$(L "Removing old data dir: $d" "Removendo dir de dados antigo: $d")"
			rm -rf "$d" 2>/dev/null || true
		fi
	done

	# --- headcrab: hijacked internal steam.sh + client.sh -----------------
	# The old port replaces Steam's own ~/.steam/steam/steam.sh with a tiny
	# wrapper that sources client.sh and injects SLSsteam via LD_AUDIT. When
	# we remove client.sh that wrapper sources a missing file and Steam dies
	# silently on launch. The genuine Valve steam.sh is a large script that
	# always references bootstrap.tar.xz; the hijacked one does not. Detect a
	# foreign steam.sh and restore the real one (Steam also re-extracts it
	# from bootstrap.tar.xz when it's absent, so deletion is the safe
	# fallback).
	restore_steam_sh "$steam_root"

	if [ -f "$steam_root/client.sh" ]; then
		log_step "$(L "Removing leftover client.sh" "Removendo client.sh residual")"
		rm -f "$steam_root/client.sh" 2>/dev/null || true
	fi

	# --- headcrab: steam.cfg that inhibits the bootstrapper ---------------
	if [ -f "$steam_root/steam.cfg" ] && grep -qi "BootStrapperInhibitAll" "$steam_root/steam.cfg" 2>/dev/null; then
		log_step "$(L "Removing update-blocking steam.cfg" "Removendo steam.cfg que bloqueia updates")"
		rm -f "$steam_root/steam.cfg" 2>/dev/null || true
	fi

	# --- headcrab support files -------------------------------------------
	# NOTE: ~/.local/share/CloudRedirect is intentionally PRESERVED. We now
	# manage CloudRedirect ourselves (see install_cloudredirect) to provide
	# Steam Cloud saves for unowned games; it does not conflict with our stack
	# the way the steam.sh hijack / client.sh / BootStrapperInhibitAll do
	# (those are still removed above). Only the headcrab desktop entry/icon and
	# ~/.headcrab are cleaned up here.
	for d in "$HOME/.headcrab"; do
		if [ -e "$d" ]; then
			log_step "$(L "Removing $d" "Removendo $d")"
			rm -rf "$d" 2>/dev/null || true
		fi
	done
	rm -f "$HOME/.local/share/applications/headcrab.desktop" 2>/dev/null || true
	rm -f "$HOME/.local/share/icons/hicolor/48x48/apps/headcrab.png" 2>/dev/null || true

	# --- Old enter-the-wired SLSsteam install -----------------------------
	# Our slsteam-moon setup.sh reinstalls a fresh copy; this only removes
	# the binaries/wrapper, not the user's config at ~/.config/SLSsteam.
	if [ -d "$HOME/.local/share/SLSsteam" ]; then
		log_step "$(L "Removing old SLSsteam install (~/.local/share/SLSsteam)" \
		             "Removendo instalação antiga do SLSsteam (~/.local/share/SLSsteam)")"
		rm -rf "$HOME/.local/share/SLSsteam" 2>/dev/null || true
	fi

	# --- Arch: system slssteam package conflicts with the local install ---
	if [ "$(get_distro_family)" = "arch" ] && command -v pacman >/dev/null 2>&1; then
		local pkgs
		pkgs="$(pacman -Qq 2>/dev/null | grep -E '^slssteam(-git)?$' || true)"
		if [ -n "$pkgs" ]; then
			local sudo_cmd; sudo_cmd="$(sudo_prefix)"
			log_step "$(L "Removing conflicting system package(s): $pkgs" \
			             "Removendo pacote(s) de sistema conflitante(s): $pkgs")"
			# shellcheck disable=SC2086
			$sudo_cmd pacman -Rns --noconfirm $pkgs >/dev/null 2>&1 || \
				log_warn "$(L "Could not remove $pkgs; remove it manually if install fails." \
				             "Não foi possível remover $pkgs; remova manualmente se a instalação falhar.")"
		fi
	fi

	# --- Millennium framework ---------------------------------------------
	# Lumen replaces Millennium. Crucially, Millennium forces the Steam
	# webhelper onto --remote-debugging-pipe, which keeps the CEF port 8080
	# CLOSED — and Lumen attaches via that port. So a pre-existing Millennium
	# install would BLOCK Lumen. Remove the whole framework here (not just the
	# old plugin dir handled above) so 8080 is free for Lumen.
	remove_millennium_framework

	log_success "$(L "Previous installation cleaned up" "Instalação anterior limpa")"
}

# Remove an officially-installed Millennium framework (steambrew.app). Mirrors
# uninstall.sh::uninstall_millennium. Millennium and Lumen are mutually
# exclusive over Steam's single CEF DevTools endpoint, so Lumen requires
# Millennium to be gone.
remove_millennium_framework() {
	local sudo_cmd; sudo_cmd="$(sudo_prefix)"
	local xdg_config="${XDG_CONFIG_HOME:-$HOME/.config}/millennium"
	local xdg_data="${XDG_DATA_HOME:-$HOME/.local/share}/millennium"
	local steam_root="$HOME/.steam/steam"

	# Anything to do? (user dirs or system dirs present, or injected symlinks)
	if [ ! -d "$xdg_config" ] && [ ! -d "$xdg_data" ] \
	   && [ ! -d /usr/lib/millennium ] && [ ! -d /usr/share/millennium ] \
	   && [ ! -L "$steam_root/ubuntu12_64/libmillennium_hhx64.so" ]; then
		return 0
	fi

	log_step "$(L "Removing existing Millennium (replaced by Lumen)" \
	             "Removendo Millennium existente (substituído pelo Lumen)")"

	# Symlinks Millennium drops into Steam's runtime dirs (point at its libs).
	local link target
	for link in \
		"$steam_root/ubuntu12_32/libXtst.so.6" \
		"$steam_root/ubuntu12_64/libXtst.so.6" \
		"$steam_root/ubuntu12_64/libmillennium_hhx64.so"; do
		if [ -L "$link" ]; then
			target="$(readlink "$link" 2>/dev/null || true)"
			case "$target" in
				*/millennium/*|*libmillennium*)
					rm -f "$link" 2>/dev/null || true ;;
			esac
		fi
	done

	# User-side dirs (themes, plugins, config.json).
	rm -rf "$xdg_config" "$xdg_data" 2>/dev/null || true

	# Millennium also drops a dir inside Steam's own install (themes, etc.).
	rm -rf "$steam_root/millennium" 2>/dev/null || true

	# System-side dirs (Millennium's loader). Needs sudo.
	if [ -d /usr/lib/millennium ] || [ -d /usr/share/millennium ]; then
		if [ -n "$sudo_cmd" ] || [ "$(id -u)" -eq 0 ]; then
			$sudo_cmd rm -rf /usr/lib/millennium /usr/share/millennium 2>/dev/null || true
		else
			log_warn "$(L "sudo unavailable; remove /usr/lib/millennium manually so Lumen can attach" \
			             "sudo indisponível; remova /usr/lib/millennium manualmente para o Lumen funcionar")"
		fi
	fi

	log_success "$(L "Millennium removed (Steam re-extracts libXtst.so.6 on next launch)" \
	             "Millennium removido (a Steam reextrai libXtst.so.6 no próximo início)")"
}

# ============================================================================
# Release helpers (Codeberg / Forgejo + GitHub)
# ============================================================================
# Echo the browser_download_url of the first asset whose name matches the glob
# $2 in the latest release of repo $1. Optional $3 selects the forge:
# "codeberg" (default) or "github". Codeberg's Forgejo API mirrors GitHub's
# release JSON shape (.tag_name, .assets[].browser_download_url), so the same
# jq query works for both. Empty string if not found.
latest_release_asset_url() {
	local repo="$1" asset_glob="$2" forge="${3:-codeberg}" api meta
	case "$forge" in
		github) api="https://api.github.com/repos/${repo}/releases/latest" ;;
		*)      api="https://codeberg.org/api/v1/repos/${repo}/releases/latest" ;;
	esac
	meta="$(curl -fsSL -H 'Accept: application/json' "$api" 2>/dev/null)" || return 1
	printf '%s' "$meta" | jq -r --arg glob "$asset_glob" \
		'.assets[] | select(.name | test($glob)) | .browser_download_url' 2>/dev/null | head -n1
}

# Like latest_release_asset_url but scans ALL releases (newest first) for the
# first asset matching the glob. Needed when the latest release does not carry
# the asset we want — e.g. CloudRedirect's most recent tag ships no flatpak, so
# the newest flatpak lives in an older release under a versioned filename.
any_release_asset_url() {
	local repo="$1" asset_glob="$2" forge="${3:-codeberg}" api meta
	case "$forge" in
		github) api="https://api.github.com/repos/${repo}/releases?per_page=50" ;;
		*)      api="https://codeberg.org/api/v1/repos/${repo}/releases?limit=50" ;;
	esac
	meta="$(curl -fsSL -H 'Accept: application/json' "$api" 2>/dev/null)" || return 1
	printf '%s' "$meta" | jq -r --arg glob "$asset_glob" \
		'[.[].assets[]? | select(.name | test($glob)) | .browser_download_url][0] // empty' \
		2>/dev/null | head -n1
}

# Echo the browser_download_url of the first asset matching glob $3 in the
# release tagged $2 of repo $1 (forge $4, default codeberg). Used to pin an
# install to a SPECIFIC release tag instead of "latest" — the main (Millennium)
# and lumen-beta (Lumen) branches each pin their own slsteam-moon release, so a
# new release on the other line never changes what this branch installs.
release_asset_url_by_tag() {
	local repo="$1" tag="$2" asset_glob="$3" forge="${4:-codeberg}" api meta
	case "$forge" in
		github) api="https://api.github.com/repos/${repo}/releases/tags/${tag}" ;;
		*)      api="https://codeberg.org/api/v1/repos/${repo}/releases/tags/${tag}" ;;
	esac
	meta="$(curl -fsSL -H 'Accept: application/json' "$api" 2>/dev/null)" || return 1
	printf '%s' "$meta" | jq -r --arg glob "$asset_glob" \
		'.assets[] | select(.name | test($glob)) | .browser_download_url' 2>/dev/null | head -n1
}

# Extract a zip into a destination dir, preferring unzip, falling back to python.
extract_zip() {
	local archive="$1" dest="$2"
	mkdir -p "$dest"
	if command -v unzip >/dev/null 2>&1; then
		unzip -qo "$archive" -d "$dest"
		return $?
	fi
	if command -v python3 >/dev/null 2>&1; then
		python3 - "$archive" "$dest" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "r") as zf:
    zf.extractall(sys.argv[2])
PY
		return $?
	fi
	return 1
}

# ============================================================================
# Step: slsteam-moon (the release already bundles setup.sh + bin/ + tools/).
# We just download, extract, and run setup.sh install — which also kills Steam.
# ============================================================================
install_slsteam_moon() {
	local url tmp zip extract_root setup

	log_info "$(L "Resolving slsteam-moon release ${SLS_TAG}" \
	             "Buscando a release ${SLS_TAG} do slsteam-moon")"
	url="$(release_asset_url_by_tag "$SLS_REPO" "$SLS_TAG" "^${SLS_ASSET_PREFIX}.*\\.zip$")"
	[ -n "$url" ] || fail "$(L "Could not find the slsteam-moon ${SLS_TAG} release asset." \
	                          "Não foi possível encontrar o asset da release ${SLS_TAG} do slsteam-moon.")"

	tmp="$(mktemp -d)"; trap 'rm -rf "${tmp:-}"' RETURN
	zip="$tmp/slsteam-moon.zip"

	log_info "$(L "Downloading slsteam-moon" "Baixando slsteam-moon")"
	curl -fL "$url" -o "$zip" || fail "$(L "Download failed" "Falha no download")"

	log_info "$(L "Extracting" "Extraindo")"
	extract_zip "$zip" "$tmp/extracted" || fail "$(L "Extraction failed" "Falha na extração")"

	# The archive contains a single top-level slsteam-moon-<ver>/ directory.
	setup="$(find "$tmp/extracted" -maxdepth 2 -name setup.sh -type f | head -n1)"
	[ -n "$setup" ] || fail "$(L "setup.sh not found in the release archive." \
	                            "setup.sh não encontrado no pacote da release.")"
	extract_root="$(dirname "$setup")"

	chmod +x "$setup" 2>/dev/null || true
	log_info "$(L "Running slsteam-moon setup (this will stop Steam)" \
	             "Rodando o setup do slsteam-moon (isto vai parar a Steam)")"

	# setup.sh resolves its own paths relative to the extracted dir.
	( cd "$extract_root" && bash "$setup" install ) \
		|| fail "$(L "slsteam-moon setup failed" "Falha no setup do slsteam-moon")"

	log_success "$(L "slsteam-moon installed" "slsteam-moon instalado")"
}

# ============================================================================
# Step: Lumen (millennium-less LuaTools bridge)
# ============================================================================
# Downloads the lumen release (static binary + lua/) and extracts it to
# ~/.local/share/Lumen. The Steam wrapper (slsteam-moon setup.sh) launches it
# as a sidecar; it injects the LuaTools frontend via CDP and hosts the backend.
install_lumen() {
	local url tmp zip dest
	dest="$LUMEN_DIR"
	log_info "$(L "Resolving latest Lumen release" "Buscando a última release do Lumen")"
	url="$(latest_release_asset_url "$LUMEN_REPO" "^${LUMEN_ASSET}$")"
	[ -n "$url" ] || fail "$(L "Could not find the Lumen release asset." \
	                          "Não foi possível encontrar o asset da release do Lumen.")"
	tmp="$(mktemp -d)"; trap 'rm -rf "${tmp:-}"' RETURN
	zip="$tmp/$LUMEN_ASSET"
	log_info "$(L "Downloading Lumen" "Baixando o Lumen")"
	curl -fL "$url" -o "$zip" || fail "$(L "Download failed" "Falha no download")"
	mkdir -p "$dest"
	extract_zip "$zip" "$dest" || fail "$(L "Extraction failed" "Falha na extração")"
	chmod +x "$dest/lumen" 2>/dev/null || true
	if ! file "$dest/lumen" 2>/dev/null | grep -q "ELF 64-bit"; then
		fail "$(L "Lumen binary is not a valid ELF executable" \
		         "O binário do Lumen não é um ELF válido")"
	fi
	log_success "$(L "Lumen installed" "Lumen instalado")"
}

# ============================================================================
# Step: LuaTools plugin (this repo)
# ============================================================================
install_plugin() {
	local url tmp zip dest

	log_info "$(L "Resolving latest LuaTools plugin release" \
	             "Buscando a última release do plugin LuaTools")"
	url="$(latest_release_asset_url "$PLUGIN_REPO" "^${PLUGIN_ASSET}$")"
	[ -n "$url" ] || fail "$(L "Could not find the plugin release asset." \
	                          "Não foi possível encontrar o asset da release do plugin.")"

	tmp="$(mktemp -d)"; trap 'rm -rf "${tmp:-}"' RETURN
	zip="$tmp/$PLUGIN_ASSET"

	log_info "$(L "Downloading plugin" "Baixando o plugin")"
	curl -fL "$url" -o "$zip" || fail "$(L "Download failed" "Falha no download")"

	# Lumen hosts the plugin under ~/.local/share/Lumen/luatools (the wrapper
	# points LUMEN_BACKEND_DIR at .../luatools/backend, and the injector reads
	# .../luatools/public for the frontend assets).
	dest="$LUMEN_DIR/luatools"

	# Preserve the user's plugin data across reinstalls/updates. The plugin
	# stores its settings (language, theme, API keys, ...) and the donated
	# appid list inside its own backend/data dir, which we are about to
	# replace. Stash them and restore after extracting the new version.
	local data_bak=""
	if [ -d "$dest/backend/data" ]; then
		data_bak="$(mktemp -d)"
		cp -a "$dest/backend/data/." "$data_bak/" 2>/dev/null || true
	fi

	# The zip contains the plugin contents (plugin.json, backend/, public/).
	# Replace any prior install.
	rm -rf "$dest"
	log_info "$(L "Installing plugin to $dest" "Instalando o plugin em $dest")"
	extract_zip "$zip" "$tmp/extracted" || fail "$(L "Extraction failed" "Falha na extração")"

	local inner
	inner="$(find "$tmp/extracted" -maxdepth 2 -name plugin.json -type f | head -n1)"
	[ -n "$inner" ] || fail "$(L "plugin.json not found in the plugin archive." \
	                            "plugin.json não encontrado no pacote do plugin.")"
	# Copy the CONTENTS of the dir holding plugin.json into dest, so this
	# works whether the zip puts files at the root or nests them in a dir.
	mkdir -p "$dest"
	cp -a "$(dirname "$inner")/." "$dest/"

	# Restore the user's preserved data over the freshly extracted defaults.
	if [ -n "$data_bak" ]; then
		mkdir -p "$dest/backend/data"
		cp -a "$data_bak/." "$dest/backend/data/" 2>/dev/null || true
		rm -rf "$data_bak"
		log_success "$(L "Plugin updated (settings preserved)" \
		             "Plugin atualizado (configurações preservadas)")"
	else
		log_success "$(L "Plugin installed" "Plugin instalado")"
	fi
}

# ============================================================================
# Step: CloudRedirect (optional) — Steam Cloud saves for unowned games
# ============================================================================
# CloudRedirect (https://github.com/Selectively11/CloudRedirect) redirects
# Steam Cloud reads/writes for unowned (lua) games to the user's own cloud
# provider. Two pieces:
#   1. cloud_redirect.so — the 32-bit hook loaded into Steam. We always install
#      our PATCHED build bundled in this repo under cloudredirect/ (CloudRedirect
#      2.1.5 with the steamclient.so wait extended to 120s and the CAS save-path
#      fix; see cloudredirect/README.md). The Steam wrapper injects it via
#      LD_PRELOAD when present (NOT LD_AUDIT — 2.1.x corrupts the client heap if
#      loaded as an auditor).
#   2. The flatpak companion app — the cloud-provider login UI (Google Drive /
#      OneDrive). We install it ONLY if the user already has flatpak; we never
#      install flatpak itself (too invasive). Without it the .so still loads but
#      there is nowhere to sync to, so we just tell the user how to finish.
#
# We also flip SLSsteam's DisableCloud to "no" so the cloud RPCs reach
# CloudRedirect instead of being suppressed for AddedApps.

# Track, for the final notice, whether the login app got installed.
CR_FLATPAK_INSTALLED=0

# Deploy the bundled, patched 32-bit cloud_redirect.so (2.1.5 + 120s
# steamclient wait + CAS-path fix) into ~/.local/share/CloudRedirect.
install_cloudredirect_so() {
	local tmp so

	tmp="$(mktemp -d)"; trap 'rm -rf "${tmp:-}"' RETURN
	so="$tmp/cloud_redirect.so"

	log_info "$(L "Downloading cloud_redirect.so" "Baixando cloud_redirect.so")"
	if ! curl -fL "$CR_SO_BUNDLED_URL" -o "$so"; then
		log_warn "$(L "Download of cloud_redirect.so failed; skipping cloud saves." \
		             "Falha ao baixar cloud_redirect.so; pulando cloud saves.")"
		return 1
	fi

	# The Steam client is 32-bit, so the hook must be a 32-bit ELF or it will be
	# silently ignored by the loader. Verify before deploying.
	if command -v file >/dev/null 2>&1; then
		if ! file -b "$so" | grep -q "ELF 32-bit"; then
			log_warn "$(L "Downloaded cloud_redirect.so is not 32-bit; skipping cloud saves." \
			             "cloud_redirect.so baixado não é 32-bit; pulando cloud saves.")"
			return 1
		fi
	fi

	mkdir -p "$CR_DIR"
	install -m 755 "$so" "$CR_SO_PATH" 2>/dev/null || {
		cp -f "$so" "$CR_SO_PATH" && chmod 755 "$CR_SO_PATH"
	}
	log_success "$(L "cloud_redirect.so installed to $CR_SO_PATH" \
	             "cloud_redirect.so instalado em $CR_SO_PATH")"
	return 0
}

# Make sure cloud saves are enabled in the SLSsteam config so cloud RPCs reach
# CloudRedirect. Fresh installs already get DisableCloud: no from slsteam-moon's
# default config (created on Steam's first launch), so this only needs to act
# when an OLDER config already exists on disk with DisableCloud: yes (upgrade
# from a build that defaulted to yes). If the config doesn't exist yet, the
# default handles it — nothing to do.
enable_cloud_in_slsteam_config() {
	local cfg="$HOME/.config/SLSsteam/config.yaml"
	[ -f "$cfg" ] || return 0

	if grep -qE "^DisableCloud:[[:space:]]*no\b" "$cfg"; then
		return 0
	fi

	if grep -qE "^DisableCloud:" "$cfg"; then
		sed -i "s/^DisableCloud:.*/DisableCloud: no/" "$cfg"
	else
		printf '\nDisableCloud: no\n' >> "$cfg"
	fi
	log_success "$(L "Enabled cloud saves in existing SLSsteam config (DisableCloud: no)" \
	             "Cloud saves ativado na config existente do SLSsteam (DisableCloud: no)")"
}

# Repair the CAS-corrupt save layout left by older CloudRedirect builds
# (<= 2.0.4). Those builds wrote a save's bytes into a directory named after the
# file ("<file>/<sha40>") instead of the file itself. Steam then sees a
# directory where it expects a save and reports "Steam Cloud Error / Unable to
# sync", and the game can't read the save. Convert each such directory back into
# the regular file. Scans the CloudRedirect local storage and the Proton
# compatdata prefixes. Idempotent and conservative: only acts on a directory
# whose name looks like a save and that holds exactly one 40-hex-named file.
repair_cas_save_layout() {
	local roots=(
		"$HOME/.config/CloudRedirect/storage"
		"$HOME/.steam/steam/steamapps/compatdata"
		"$HOME/.steam/debian-installation/steamapps/compatdata"
	)
	local repaired=0 root dir base leaf tmp
	for root in "${roots[@]}"; do
		[ -d "$root" ] || continue
		while IFS= read -r -d '' dir; do
			base="$(basename "$dir")"
			case "$base" in
				*.es3|*.jpg|*.sav|*.save|*.dat|*.bin|*.json|*.xml) ;;
				*) continue ;;
			esac
			# Must hold exactly one regular file...
			local files=()
			while IFS= read -r -d '' f; do files+=("$f"); done \
				< <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null)
			[ "${#files[@]}" -eq 1 ] || continue
			leaf="$(basename "${files[0]}")"
			# ...named like a 40-char SHA-1 (the CAS leaf).
			case "$leaf" in
				*[!0-9a-f]*) continue ;;
			esac
			[ "${#leaf}" -eq 40 ] || continue

			tmp="$(mktemp "$(dirname "$dir")/.casrepair.XXXXXX")" || continue
			if cp -p "${files[0]}" "$tmp" && rm -rf "$dir" && mv "$tmp" "$dir"; then
				repaired=$((repaired+1))
			else
				rm -f "$tmp" 2>/dev/null
			fi
		done < <(find "$root" -type d -print0 2>/dev/null)
	done
	if [ "$repaired" -gt 0 ]; then
		log_success "$(L "Repaired $repaired cloud-save file(s) from a legacy storage layout" \
		             "Reparado(s) $repaired arquivo(s) de cloud-save de um layout de armazenamento antigo")"
	fi
}

# Install the flatpak companion app from the release bundle. Only called when
# flatpak is present. Best-effort: failure just means the user finishes setup
# manually (the .so is already in place).
install_cloudredirect_flatpak() {
	local url tmp bundle

	# Already installed? Nothing to do.
	if flatpak list 2>/dev/null | grep -q "$CR_FLATPAK_APP_ID"; then
		log_success "$(L "CloudRedirect app already installed" "App CloudRedirect já instalado")"
		CR_FLATPAK_INSTALLED=1
		return 0
	fi

	log_info "$(L "Resolving CloudRedirect companion app (flatpak)" \
	             "Buscando o app companheiro do CloudRedirect (flatpak)")"
	# The newest CloudRedirect tag may ship no flatpak (e.g. 2.1.7), and recent
	# ones name it cloudredirect-<ver>.flatpak rather than cloudredirect.flatpak.
	# Scan all releases for the first matching bundle, excluding .sha256 sidecars.
	url="$(any_release_asset_url "$CR_REPO" "^cloudredirect.*\\.flatpak$" github)"
	if [ -z "$url" ]; then
		log_warn "$(L "Could not find the CloudRedirect flatpak bundle; skipping the login app." \
		             "Não foi possível encontrar o bundle flatpak do CloudRedirect; pulando o app de login.")"
		return 1
	fi

	tmp="$(mktemp -d)"; trap 'rm -rf "${tmp:-}"' RETURN
	bundle="$tmp/$(basename "$url")"

	log_info "$(L "Downloading CloudRedirect app" "Baixando o app CloudRedirect")"
	if ! curl -fL "$url" -o "$bundle"; then
		log_warn "$(L "Download of the CloudRedirect app failed; you can install it later." \
		             "Falha ao baixar o app CloudRedirect; você pode instalá-lo depois.")"
		return 1
	fi

	# The bundle needs the KDE runtime. It is not bundled, so make sure flathub
	# is available as a user remote and pull the runtime first.
	flatpak remote-add --user --if-not-exists flathub \
		https://flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 || true

	# Let flatpak print its own download/install progress (the KDE runtime is
	# ~400 MB) instead of hiding it — otherwise the installer looks frozen for
	# minutes. stderr carries the progress bar; keep it on the terminal.
	log_info "$(L "Installing KDE runtime (required by the app, ~400 MB)" \
	             "Instalando o runtime KDE (exigido pelo app, ~400 MB)")"
	flatpak install --user -y flathub "$CR_KDE_RUNTIME" || true

	log_info "$(L "Installing the CloudRedirect app" "Instalando o app CloudRedirect")"
	if flatpak install --user -y --bundle "$bundle"; then
		log_success "$(L "CloudRedirect app installed" "App CloudRedirect instalado")"
		CR_FLATPAK_INSTALLED=1
		return 0
	fi

	log_warn "$(L "Could not install the CloudRedirect app automatically; you can install it later." \
	             "Não foi possível instalar o app CloudRedirect automaticamente; você pode instalá-lo depois.")"
	return 1
}

install_cloudredirect() {
	# The .so is the core piece — always install it (and enable cloud in the
	# SLSsteam config) regardless of flatpak.
	if ! install_cloudredirect_so; then
		# No hook → no cloud saves; nothing else to do.
		return 0
	fi

	enable_cloud_in_slsteam_config

	# Heal any saves left in the legacy CAS-corrupt directory layout so Steam
	# stops reporting "Steam Cloud Error" for them.
	repair_cas_save_layout

	# The login UI is a flatpak. Only install it if the user already has
	# flatpak — we never install flatpak itself.
	if command -v flatpak >/dev/null 2>&1; then
		install_cloudredirect_flatpak
	else
		log_warn "$(L "flatpak not found — installing the cloud hook only." \
		             "flatpak não encontrado — instalando apenas o hook de cloud.")"
	fi
}

# ============================================================================
# Completion notice
# ============================================================================
print_complete() {
	echo ""
	echo -e "${GREEN}${BOLD}"
	echo "┌─────────────────────────────────────────────────────────┐"
	echo "│              ✓ Installation Complete!                   │"
	echo "└─────────────────────────────────────────────────────────┘"
	echo -e "${NC}"
	echo ""
	echo -e "  $(L "Everything is installed:" "Tudo instalado:")"
	echo -e "    ${GREEN}•${NC} slsteam-moon"
	echo -e "    ${GREEN}•${NC} Lumen"
	echo -e "    ${GREEN}•${NC} LuaTools ($(L "plugin" "plugin"))"
	if [ -f "$CR_SO_PATH" ]; then
		echo -e "    ${GREEN}•${NC} CloudRedirect ($(L "cloud saves" "cloud saves"))"
	fi
	echo ""

	# Cloud-save guidance: the .so is installed but the user still needs the
	# login app + a provider sign-in before saves actually sync.
	if [ -f "$CR_SO_PATH" ]; then
		if [ "$CR_FLATPAK_INSTALLED" = 1 ]; then
			echo -e "  ${MOON}$(L "Cloud saves:" "Cloud saves:")${NC}"
			echo -e "    $(L "Open the CloudRedirect app and sign in to a provider" \
			               "Abra o app CloudRedirect e faça login em um provedor")"
			echo -e "    $(L "(Google Drive / OneDrive), then restart Steam." \
			               "(Google Drive / OneDrive), depois reinicie a Steam.")"
			echo ""
		else
			echo -e "  ${YELLOW}$(L "Cloud saves (optional):" "Cloud saves (opcional):")${NC}"
			echo -e "    $(L "The cloud hook is installed, but you need the login app to sync." \
			               "O hook de cloud está instalado, mas você precisa do app de login para sincronizar.")"
			echo -e "    $(L "1) Install flatpak (from your package manager)." \
			               "1) Instale o flatpak (pelo seu gerenciador de pacotes).")"
			echo -e "    $(L "2) Re-run this installer, or install the CloudRedirect flatpak yourself." \
			               "2) Rode este instalador de novo, ou instale o flatpak do CloudRedirect manualmente.")"
			echo -e "    $(L "3) Open the app, sign in to a provider, then restart Steam." \
			               "3) Abra o app, faça login em um provedor, depois reinicie a Steam.")"
			echo ""
		fi
	fi

	echo -e "  $(L "Start Steam to begin using LuaTools." \
	               "Inicie a Steam para começar a usar o LuaTools.")"
	echo ""
}

# ============================================================================
# Entry point
# ============================================================================
main() {
	detect_language
	print_banner

	print_section "$(L "Pre-flight checks" "Verificações iniciais")"
	check_not_root
	check_arch
	check_internet
	check_steam_native

	print_section "$(L "Stopping Steam" "Parando a Steam")"
	stop_steam

	print_section "$(L "Cleaning up previous installation" "Limpando instalação anterior")"
	cleanup_previous_install

	print_section "$(L "Dependencies" "Dependências")"
	install_dependencies

	print_section "$(L "Installing slsteam-moon" "Instalando slsteam-moon")"
	install_slsteam_moon

	print_section "$(L "Installing Lumen" "Instalando Lumen")"
	install_lumen

	print_section "$(L "Installing LuaTools plugin" "Instalando o plugin LuaTools")"
	install_plugin

	print_section "$(L "Setting up cloud saves (CloudRedirect)" "Configurando cloud saves (CloudRedirect)")"
	install_cloudredirect

	print_complete
}

main "$@"
