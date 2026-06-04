#!/usr/bin/env bash
# ============================================================================
#  slsteammoon-ltsteamplugin — one-shot installer
# ============================================================================
#  Installs the full stack in a single command:
#
#    curl -fsSL https://raw.githubusercontent.com/nwrafael/slsteammoon-ltsteamplugin/main/install.sh | bash
#
#  Pipeline:
#    1. Pre-flight checks (not-root, x86_64, internet, NATIVE Steam).
#    2. Runtime dependencies (jq, curl, tar, unzip, libssl-dev:i386 on Debian).
#    3. slsteam-moon   — download latest release, extract, run setup.sh install.
#    4. Millennium     — curl https://steambrew.app/install.sh | bash.
#    5. This plugin    — download latest release into Millennium's plugins dir
#                        and pre-enable it in config.json.
#
#  Bilingual (English / Português) based on the system locale.
# ============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# Repositories / release sources
# ----------------------------------------------------------------------------
SLS_REPO="nwrafael/slsteam-moon"
SLS_ASSET_PREFIX="slsteam-moon-linux"          # asset is slsteam-moon-linux-<ver>.zip

PLUGIN_REPO="nwrafael/slsteammoon-ltsteamplugin"
PLUGIN_ASSET="luatools-linux.zip"
PLUGIN_NAME="luatools"                          # plugin.json "name"

MILLENNIUM_INSTALL_URL="https://steambrew.app/install.sh"

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
	if ! curl -fsS --head "https://github.com" >/dev/null 2>&1; then
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
			echo -e "  $(L "Millennium and slsteam-moon only work with NATIVE Steam" \
			               "Millennium e slsteam-moon só funcionam com a Steam NATIVA")"
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

# Ensure the generic CLI tools Millennium + this installer need are present.
install_dependencies() {
	local family; family="$(get_distro_family)"

	log_info "$(L "Checking required tools (jq, curl, tar, unzip)" \
	             "Verificando ferramentas necessárias (jq, curl, tar, unzip)")"

	local missing_pkgs=() tool
	for tool in jq curl tar unzip; do
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

	# Debian-based: Millennium needs the 32-bit OpenSSL dev libs.
	if [ "$family" = "debian" ]; then
		install_libssl_i386
	fi
}

# Millennium's installer aborts on Debian-based distros without
# libssl-dev:i386, asking the user to add the i386 architecture first.
# We do it for them.
install_libssl_i386() {
	local sudo_cmd; sudo_cmd="$(sudo_prefix)"

	if dpkg -s libssl-dev:i386 2>/dev/null | grep -q '^Status:.*installed'; then
		log_success "$(L "libssl-dev:i386 already installed" "libssl-dev:i386 já instalado")"
		return 0
	fi

	log_info "$(L "Installing libssl-dev:i386 (required by Millennium)" \
	             "Instalando libssl-dev:i386 (exigido pelo Millennium)")"

	# Enable the i386 architecture so the :i386 package is resolvable.
	if ! dpkg --print-foreign-architectures 2>/dev/null | grep -qx i386; then
		$sudo_cmd dpkg --add-architecture i386 || \
			fail "$(L "Failed to add i386 architecture (dpkg --add-architecture i386)" \
			          "Falha ao adicionar a arquitetura i386 (dpkg --add-architecture i386)")"
	fi

	$sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
	if ! $sudo_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y libssl-dev:i386; then
		fail "$(L "Failed to install libssl-dev:i386. Install it manually and re-run." \
		          "Falha ao instalar libssl-dev:i386. Instale manualmente e rode de novo.")"
	fi
	log_success "$(L "libssl-dev:i386 installed" "libssl-dev:i386 instalado")"
}

# ============================================================================
# GitHub release helpers
# ============================================================================
# Echo the browser_download_url of the first asset whose name matches the glob
# $2 in the latest release of repo $1. Empty string if not found.
latest_release_asset_url() {
	local repo="$1" asset_glob="$2" meta
	meta="$(curl -fsSL -H 'Accept: application/vnd.github.v3+json' \
	             "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null)" || return 1
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

	log_info "$(L "Resolving latest slsteam-moon release" \
	             "Buscando a última release do slsteam-moon")"
	url="$(latest_release_asset_url "$SLS_REPO" "^${SLS_ASSET_PREFIX}.*\\.zip$")"
	[ -n "$url" ] || fail "$(L "Could not find a slsteam-moon release asset." \
	                          "Não foi possível encontrar o asset da release do slsteam-moon.")"

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
# Step: Millennium (Steam client modding framework)
# ============================================================================
install_millennium() {
	log_info "$(L "Installing Millennium from steambrew.app" \
	             "Instalando Millennium via steambrew.app")"

	# --yes makes the official installer non-interactive (no prompt over a pipe).
	if ! curl -fsSL "$MILLENNIUM_INSTALL_URL" | bash -s -- --yes; then
		fail "$(L "Millennium installation failed." "Falha na instalação do Millennium.")"
	fi
	log_success "$(L "Millennium installed" "Millennium instalado")"
}

# ============================================================================
# Step: LuaTools plugin (this repo)
# ============================================================================
# Resolve where Millennium reads plugins from, creating the default if needed.
plugin_install_root() {
	local dir
	for dir in \
		"$HOME/.local/share/millennium/plugins" \
		"$HOME/.millennium/plugins" \
		"$HOME/.steam/steam/millennium/plugins" \
		"$HOME/.local/share/Steam/millennium/plugins"; do
		if [ -d "$dir" ]; then
			echo "$dir"
			return
		fi
	done
	echo "$HOME/.local/share/millennium/plugins"
}

install_plugin() {
	local url tmp zip root dest

	log_info "$(L "Resolving latest LuaTools plugin release" \
	             "Buscando a última release do plugin LuaTools")"
	url="$(latest_release_asset_url "$PLUGIN_REPO" "^${PLUGIN_ASSET}$")"
	[ -n "$url" ] || fail "$(L "Could not find the plugin release asset." \
	                          "Não foi possível encontrar o asset da release do plugin.")"

	tmp="$(mktemp -d)"; trap 'rm -rf "${tmp:-}"' RETURN
	zip="$tmp/$PLUGIN_ASSET"

	log_info "$(L "Downloading plugin" "Baixando o plugin")"
	curl -fL "$url" -o "$zip" || fail "$(L "Download failed" "Falha no download")"

	root="$(plugin_install_root)"
	mkdir -p "$root"
	dest="$root/$PLUGIN_NAME"

	# The zip contains a top-level luatools/ dir. Replace any prior install.
	rm -rf "$dest"
	log_info "$(L "Installing plugin to $dest" "Instalando o plugin em $dest")"
	extract_zip "$zip" "$tmp/extracted" || fail "$(L "Extraction failed" "Falha na extração")"

	local inner
	inner="$(find "$tmp/extracted" -maxdepth 2 -name plugin.json -type f | head -n1)"
	[ -n "$inner" ] || fail "$(L "plugin.json not found in the plugin archive." \
	                            "plugin.json não encontrado no pacote do plugin.")"
	cp -r "$(dirname "$inner")" "$dest"

	log_success "$(L "Plugin installed" "Plugin instalado")"

	enable_plugin_in_config
}

# Pre-activate the plugin in Millennium's config.json so the user doesn't have
# to enable it by hand after first launch.
enable_plugin_in_config() {
	local config_dir="$HOME/.config/millennium"
	local config_file="$config_dir/config.json"

	log_info "$(L "Enabling plugin in Millennium config" \
	             "Ativando o plugin na config do Millennium")"
	mkdir -p "$config_dir"

	if [ ! -f "$config_file" ]; then
		cat > "$config_file" <<EOF
{
  "general": {
    "injectCSS": true,
    "injectJavascript": true
  },
  "plugins": {
    "enabledPlugins": [
      "$PLUGIN_NAME"
    ]
  }
}
EOF
		log_success "$(L "Created config.json with plugin enabled" \
		             "config.json criado com o plugin ativado")"
		return 0
	fi

	# Merge into the existing config with jq (guaranteed present by now).
	local tmp_cfg
	tmp_cfg="$(mktemp)"
	if jq --arg p "$PLUGIN_NAME" '
		.plugins //= {} |
		.plugins.enabledPlugins //= [] |
		.plugins.enabledPlugins = (.plugins.enabledPlugins + [$p] | unique)
	' "$config_file" > "$tmp_cfg" 2>/dev/null; then
		mv "$tmp_cfg" "$config_file"
		log_success "$(L "Plugin enabled in existing config.json" \
		             "Plugin ativado no config.json existente")"
	else
		rm -f "$tmp_cfg"
		log_warn "$(L "Could not edit config.json automatically; enable '$PLUGIN_NAME' in Millennium settings." \
		             "Não foi possível editar o config.json; ative '$PLUGIN_NAME' nas configurações do Millennium.")"
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
	echo -e "    ${GREEN}•${NC} Millennium"
	echo -e "    ${GREEN}•${NC} LuaTools ($(L "plugin" "plugin"))"
	echo ""
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

	print_section "$(L "Dependencies" "Dependências")"
	install_dependencies

	print_section "$(L "Installing slsteam-moon" "Instalando slsteam-moon")"
	install_slsteam_moon

	print_section "$(L "Installing Millennium" "Instalando Millennium")"
	install_millennium

	print_section "$(L "Installing LuaTools plugin" "Instalando o plugin LuaTools")"
	install_plugin

	print_complete
}

main "$@"
