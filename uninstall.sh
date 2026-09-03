#!/usr/bin/env bash
# ============================================================================
#  luatools-moon — one-shot uninstaller
# ============================================================================
#  Removes EVERYTHING this stack installs, in a single command:
#
#    curl -fsSL https://raw.githubusercontent.com/swwayps/luatools-moon/main/uninstall.sh | bash
#
#  What it removes (no flags, no prompts):
#    • slsteam-moon          (~/.local/share/SLSsteam, ~/.config/SLSsteam,
#                             wrapper PATH entries, patched .desktop files,
#                             patched /usr/games/steam if any).
#    • Millennium            (~/.config/millennium, ~/.local/share/millennium,
#                             /usr/lib/millennium, /usr/share/millennium).
#    • LuaTools plugin       (any "luatools" dir under known plugin roots).
#    • Old port leftovers    (~/.headcrab, hijacked steam.sh / client.sh /
#                             steam.cfg, etc.)
#    • CloudRedirect         (the cloud-save hook, its data, and the flatpak
#                             companion app, if installed)
#
#  Bilingual (English / Português) based on the system locale.
# ============================================================================

set -uo pipefail

PLUGIN_NAME="luatools"

# ============================================================================
# Pretty output — same palette as install.sh / setup.sh.
# ============================================================================
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
	if command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ]; then
		HAS_256=1
	elif [ "${COLORTERM:-}" = "truecolor" ] || [ "${COLORTERM:-}" = "24bit" ]; then
		HAS_256=1
	else
		HAS_256=0
	fi

	BOLD=$'\033[1m'; NC=$'\033[0m'
	if [ "$HAS_256" = 1 ]; then
		MOON=$'\033[38;5;153m'; NIGHT=$'\033[38;5;75m'; HALO=$'\033[38;5;231m'
		GREEN=$'\033[38;5;114m'; YELLOW=$'\033[38;5;221m'; RED=$'\033[38;5;203m'
	else
		MOON=$'\033[1;34m'; NIGHT=$'\033[0;36m'; HALO=$'\033[1;37m'
		GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'
	fi
else
	BOLD=""; NC=""; MOON=""; NIGHT=""; HALO=""
	GREEN=""; YELLOW=""; RED=""
fi

# ============================================================================
# Localization
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

print_banner() {
	echo ""
	echo -e "${MOON}${BOLD}"
	echo "┌─────────────────────────────────────────────────────────┐"
	printf "│            ${HALO}${BOLD}◯${NC}${MOON}${BOLD}  slsteammoon · LuaTools uninstaller        │\n"
	echo "└─────────────────────────────────────────────────────────┘"
	echo -e "${NC}"
}

print_section() {
	echo ""
	echo -e "${NIGHT}─────────────────────────────────────────────────────────${NC}"
	echo -e "${NIGHT}${BOLD}❯ $1${NC}"
	echo -e "${NIGHT}─────────────────────────────────────────────────────────${NC}"
}

print_complete() {
	echo ""
	echo -e "${GREEN}${BOLD}"
	echo "┌─────────────────────────────────────────────────────────┐"
	echo "│              ✓ Uninstallation Complete!                 │"
	echo "└─────────────────────────────────────────────────────────┘"
	echo -e "${NC}"
	echo ""
	echo -e "  $(L "Removed:" "Removido:")"
	echo -e "    ${GREEN}•${NC} slsteam-moon"
	echo -e "    ${GREEN}•${NC} Lumen"
	echo -e "    ${GREEN}•${NC} Millennium ($(L "if present" "se presente"))"
	echo -e "    ${GREEN}•${NC} LuaTools ($(L "plugin" "plugin"))"
	echo ""
}

# ============================================================================
# Pre-flight
# ============================================================================
check_not_root() {
	if [ "$(id -u)" -eq 0 ]; then
		log_error "$(L "Do not run this uninstaller as root. Run it as your normal user." \
		              "Não rode este desinstalador como root. Rode como seu usuário normal.")"
		exit 1
	fi
}

# Keep the standalone uninstaller's privilege policy aligned with install.sh:
# image-based/atomic systems are user-scoped and must never prompt for sudo.
#
# NixOS is deliberately absent from the list below, same as in install.sh:
# its root is writable (declarative config, not a read-only image), so it
# takes the ordinary sudo_prefix path. It needs no NixOS-specific branch in
# this file the way install.sh does: every /usr-rooted path here (legacy
# /usr/games/steam, /usr/share/applications/steam.desktop, /usr/lib/millennium)
# is guarded on the file existing first, so it degrades to a no-op on NixOS
# the same way it already does on any distro where that path was never
# populated. And Lumen removal is a plain `rm -rf ~/.local/share/Lumen`, so
# it takes install.sh's steam-run-wrapped lumen + lumen.bin split with it
# regardless of how it got installed.
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
is_immutable_distro() {
	local id="" like="" variant=""
	if [ -r "$OS_RELEASE_FILE" ]; then
		id="$(
			# shellcheck disable=SC1090
			. "$OS_RELEASE_FILE" >/dev/null 2>&1
			printf '%s' "${ID:-}"
		)"
		like="$(
			# shellcheck disable=SC1090
			. "$OS_RELEASE_FILE" >/dev/null 2>&1
			printf '%s' "${ID_LIKE:-}"
		)"
		variant="$(
			# shellcheck disable=SC1090
			. "$OS_RELEASE_FILE" >/dev/null 2>&1
			printf '%s' "${VARIANT_ID:-}"
		)"
	fi
	id="${id,,}"; like="${like,,}"; variant="${variant,,}"
	case " $id $like " in
		*" bazzite "*|*" steamos "*|*" steamdeck "*|*" holoiso "*|\
		*" silverblue "*|*" kinoite "*|*" sericea "*|*" onyx "*|\
		*" bluefin "*|*" aurora "*|*" ucore "*) return 0 ;;
	esac
	case "$variant" in silverblue|kinoite|sericea|onyx|*atomic*) return 0 ;; esac
	command -v rpm-ostree >/dev/null 2>&1 && return 0
	command -v steamos-readonly >/dev/null 2>&1 && return 0
	if command -v findmnt >/dev/null 2>&1; then
		case ",$(findmnt -no OPTIONS / 2>/dev/null)," in *,ro,*) return 0 ;; esac
	fi
	return 1
}

# Privilege-escalation prefix for system-wide removals.
sudo_prefix() {
	if is_immutable_distro; then
		echo ""
	elif [ "$(id -u)" -eq 0 ]; then
		echo ""
	elif command -v sudo >/dev/null 2>&1; then
		echo "sudo"
	else
		echo ""
	fi
}

# ============================================================================
# Stop Steam (graceful, then SIGTERM, then SIGKILL). Mirrors install.sh.
# ============================================================================
stop_steam() {
	if ! pgrep -x steam >/dev/null 2>&1 \
	   && ! pgrep -f 'steamwebhelper' >/dev/null 2>&1 \
	   && ! pgrep -f '/steam$|/steam ' >/dev/null 2>&1; then
		log_success "$(L "No running Steam process detected" "Nenhum processo da Steam em execução")"
		return 0
	fi

	log_info "$(L "Stopping running Steam" "Parando a Steam em execução")"

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

	pkill -TERM -x steam 2>/dev/null || true
	pkill -TERM -f 'steamwebhelper' 2>/dev/null || true
	pkill -TERM -f '/steam$|/steam ' 2>/dev/null || true
	sleep 2

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

# ============================================================================
# Restore a hijacked ~/.steam/steam/steam.sh (in case the old port left one
# behind, or our own setup mid-state was interrupted). Identical strategy to
# install.sh.
# ============================================================================
restore_steam_sh() {
	local steam_root="$1"
	local sh="$steam_root/steam.sh"

	[ -f "$sh" ] || return 0

	# Genuine Valve steam.sh references bootstrap.tar.xz and does not
	# inject SLSsteam. If it looks clean, leave it alone.
	if grep -q "bootstrap.tar.xz" "$sh" 2>/dev/null \
	   && ! grep -qiE "SLSsteam|client\.sh|headcrab|LD_AUDIT" "$sh" 2>/dev/null; then
		return 0
	fi

	log_step "$(L "Restoring Steam's original steam.sh" \
	             "Restaurando o steam.sh original da Steam")"

	local data_dir
	data_dir="$(readlink -f "$steam_root" 2>/dev/null || echo "$steam_root")"

	mv -f "$sh" "$sh.old-port-bak" 2>/dev/null || rm -f "$sh" 2>/dev/null || true

	local boot="$data_dir/bootstrap.tar.xz"
	if [ -f "$boot" ] && tar xJf "$boot" -C "$data_dir" steam.sh 2>/dev/null; then
		chmod +x "$data_dir/steam.sh" 2>/dev/null || true
		log_success "$(L "Restored steam.sh from bootstrap.tar.xz" \
		             "steam.sh restaurado a partir do bootstrap.tar.xz")"
		return 0
	fi

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

	log_warn "$(L "Removed hijacked steam.sh; Steam will regenerate it on next launch" \
	             "steam.sh sequestrado removido; a Steam vai regenerá-lo no próximo início")"
}

# ============================================================================
# Effective XDG locations, resolved WITHOUT the coverage library.
# ============================================================================
# The library's dc_config_home/dc_desktop_dir are only reachable while
# ~/.local/share/SLSsteam still holds desktop-coverage.lib.sh. This uninstaller
# needs the very same paths on its own, because the desktop shortcut is the one
# patched entry the user actually clicks, and on a localized session it is NOT
# ~/Desktop (pt_BR: "Área de trabalho"). Keep these in sync with the library.
uninstall_config_home() {
	case "${XDG_CONFIG_HOME:-}" in
		/*) printf '%s\n' "$XDG_CONFIG_HOME" ;;
		*) printf '%s\n' "$HOME/.config" ;;
	esac
}

uninstall_data_home() {
	case "${XDG_DATA_HOME:-}" in
		/*) printf '%s\n' "$XDG_DATA_HOME" ;;
		*) printf '%s\n' "$HOME/.local/share" ;;
	esac
}

uninstall_state_home() {
	case "${XDG_STATE_HOME:-}" in
		/*) printf '%s\n' "$XDG_STATE_HOME" ;;
		*) printf '%s\n' "$HOME/.local/state" ;;
	esac
}

# Mirrors dc_desktop_dir: honour XDG_DESKTOP_DIR from user-dirs.dirs without
# sourcing that file. Only literal absolute paths and the standard $HOME
# prefixes are accepted; anything else keeps the ~/Desktop default.
uninstall_desktop_dir() {
	local d="$HOME/Desktop" file line value
	file="$(uninstall_config_home)/user-dirs.dirs"
	[ -f "$file" ] || { printf '%s\n' "$d"; return; }
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			XDG_DESKTOP_DIR=\"*\") value="${line#XDG_DESKTOP_DIR=\"}"; value="${value%\"}" ;;
			*) continue ;;
		esac
		case "$value" in
			'$HOME') d="$HOME" ;;
			'$HOME/'*) d="$HOME/${value#\$HOME/}" ;;
			'${HOME}') d="$HOME" ;;
			'${HOME}/'*) d="$HOME/${value#\$\{HOME\}/}" ;;
			/*) d="$value" ;;
		esac
		break
	done < "$file"
	printf '%s\n' "$d"
}

# A desktop file by extension, matched case-insensitively (an entry may be
# Steam.desktop / STEAM.DESKTOP).
#
# Deliberately NOT a *steam*.desktop name filter. setup.sh and the guardian
# classify by Exec CONTENT, so they also patch Steam's per-game shortcuts —
# "Gang Beasts.desktop", "Mina the Hollower.desktop" — whose Exec is
# `steam steam://rungameid/<id>`. A name-based sweep skipped exactly those and
# left them pointing at the deleted wrapper. Selection is left to
# restore_or_remove_desktop, which acts only on an entry that references our
# tree or that we hold a backup for.
is_desktop_file_name() {
	local name
	name="$(basename -- "$1" | tr '[:upper:]' '[:lower:]')"
	case "$name" in *.desktop) return 0 ;; *) return 1 ;; esac
}

# ============================================================================
# Ask for sudo ONCE, visibly, and only when something outside $HOME really
# needs restoring.
# ============================================================================
# Every privileged call below silences stderr, so an unprimed or denied sudo
# used to degrade the restoration invisibly: no prompt, no warning, and a
# system entry left pointing at the deleted wrapper. Priming up front turns
# that into either a real prompt or an explicit warning.
SLSM_SUDO_PRIMED=0
# Latched once a prime attempt is refused, so "ask once" really means once. Every
# later caller then degrades immediately instead of raising another prompt.
SLSM_SUDO_DENIED=0

: "${SLSM_SYS_APPS:=/usr/share/applications}"
: "${SLSM_SYS_AUTOSTART:=/etc/xdg/autostart}"

# Print every system-layer entry that still references our tree. Selection is by
# CONTENT, matching how they were patched — a *steam*.desktop glob would both
# miss Steam's per-game shortcuts and, being case-sensitive, miss Steam.desktop.
system_patched_desktop_entries() {
	local dir f
	for dir in "$SLSM_SYS_APPS" "$SLSM_SYS_AUTOSTART"; do
		[ -d "$dir" ] || continue
		for f in "$dir"/*; do
			[ -f "$f" ] || continue
			is_desktop_file_name "$f" || continue
			grep -q "SLSsteam" "$f" 2>/dev/null || continue
			printf '%s\n' "$f"
		done
	done
}

system_restore_pending() {
	local f backup_root
	[ -n "$(system_patched_desktop_entries)" ] && return 0
	backup_root="$HOME/.local/share/SLSsteam/system-launcher-backup"
	if [ -d "$backup_root" ]; then
		f="$(find "$backup_root" -type f -name '*.orig' -print -quit 2>/dev/null || true)"
		[ -n "$f" ] && return 0
	fi
	if [ -f /usr/games/steam ] && grep -q "SLSsteam" /usr/games/steam 2>/dev/null; then
		return 0
	fi
	[ -d /usr/lib/millennium ] && return 0
	[ -d /usr/share/millennium ] && return 0
	return 1
}

prime_sudo() {
	[ "$SLSM_SUDO_PRIMED" = 1 ] && return 0
	[ "$SLSM_SUDO_DENIED" = 1 ] && return 1
	# Nothing outside $HOME to restore: never ask, never warn.
	system_restore_pending || return 1
	if is_immutable_distro; then
		log_info "$(L "Immutable system: files outside your home directory are left untouched" \
		             "Sistema imutável: arquivos fora da sua pasta pessoal serão mantidos")"
		return 1
	fi
	if [ "$(id -u)" -eq 0 ]; then
		SLSM_SUDO_PRIMED=1
		return 0
	fi
	if ! command -v sudo >/dev/null 2>&1; then
		log_warn "$(L "sudo is not available: files outside your home directory are left in place" \
		             "sudo indisponível: arquivos fora da sua pasta pessoal serão mantidos")"
		return 1
	fi
	if sudo -n true 2>/dev/null; then
		SLSM_SUDO_PRIMED=1
		return 0
	fi
	log_info "$(L "Files outside your home directory need to be restored — administrator password required" \
	             "Arquivos fora da sua pasta pessoal precisam ser restaurados — senha de administrador necessária")"
	if sudo -v; then
		SLSM_SUDO_PRIMED=1
		log_success "$(L "Administrator access granted" "Acesso de administrador concedido")"
		return 0
	fi
	SLSM_SUDO_DENIED=1
	log_warn "$(L "No administrator access: system-wide files are left in place. Everything in your home directory is still restored." \
	             "Sem acesso de administrador: arquivos do sistema serão mantidos. Tudo na sua pasta pessoal continua sendo restaurado.")"
	return 1
}

# ============================================================================
# Disarm the desktop guardian BEFORE anything is restored.
# ============================================================================
# setup.sh installs three systemd --user units, and the .path unit watches
# exactly the directories a restore writes to:
#
#   PathChanged=<user applications> /usr/share/applications
#               <user autostart> /etc/xdg/autostart <XDG desktop dir>
#
# So restoring an entry TRIGGERS the guardian, whose entire job is to patch
# every Steam entry back to the wrapper. On the way out it also re-creates the
# central backups and re-installs plus re-enables its own units
# (ensure-desktop-coverage.sh --guardian ends in dgu_install_units). Tearing
# the units down AFTER the restore therefore loses a race it cannot win: the
# observed end state was every entry patched again, a resurrected backup tree,
# and both triggers back in default.target.wants/timers.target.wants.
#
# This runs FIRST, and is deliberately self-contained — hardcoded unit names and
# ownership sentinels, no library. The guardian must also be removable when
# ~/.local/share/SLSsteam is already gone or predates the library, otherwise the
# units linger and fail 203/EXEC on every boot forever.
SLSM_GUARDIAN_UNITS="slsteam-desktop-guardian.path
slsteam-desktop-guardian.timer
slsteam-desktop-guardian.service"
SLSM_GUARDIAN_SENTINEL='# X-SLSteamMoon-GuardianUnit=true'
SLSM_AUTOSTART_DROPIN='slsteam-guardian.conf'
SLSM_AUTOSTART_DROPIN_SENTINEL='# X-SLSteamMoon-AutostartDropIn=true'
# Seconds to wait for an in-flight reconciliation pass. Overridable for tests.
: "${SLSM_GUARDIAN_WAIT:=15}"

# Stopping the .path/.timer triggers does not stop the oneshot they already
# started, and that pass may be mid-write. Wait for it to leave the active
# state before we touch a single desktop entry.
wait_guardian_idle() {
	local i state
	command -v systemctl >/dev/null 2>&1 || return 0
	i=0
	while [ "$i" -lt "$SLSM_GUARDIAN_WAIT" ]; do
		state="$(systemctl --user is-active slsteam-desktop-guardian.service 2>/dev/null || true)"
		case "$state" in
			active|activating|reloading|deactivating) ;;
			*) return 0 ;;
		esac
		[ "$i" = 0 ] && log_info "$(L "Waiting for the desktop reconciliation service to finish" \
		                             "Aguardando o serviço de reconciliação de atalhos terminar")"
		sleep 1
		i=$((i + 1))
	done
	log_warn "$(L "The desktop reconciliation service is still running; continuing anyway" \
	             "O serviço de reconciliação de atalhos ainda está rodando; seguindo mesmo assim")"
	return 1
}

disarm_desktop_guardian() {
	local slsdir="$HOME/.local/share/SLSsteam"
	local unit_dir have_systemctl=0 unit path dropin removed=0
	unit_dir="$(uninstall_config_home)/systemd/user"
	command -v systemctl >/dev/null 2>&1 && have_systemctl=1

	# 1. Stop the triggers, then the service, and let an in-flight pass drain.
	if [ "$have_systemctl" = 1 ]; then
		systemctl --user disable --now \
			slsteam-desktop-guardian.path slsteam-desktop-guardian.timer \
			>/dev/null 2>&1 || true
		systemctl --user stop slsteam-desktop-guardian.service >/dev/null 2>&1 || true
		wait_guardian_idle || true
	fi

	# 2. Neutralize the reconciliation entry point. This is the belt to systemd's
	#    braces: with the CLI gone, any trigger we could not reach (a stale unit,
	#    a leftover wrapper invocation) can no longer re-patch a single file.
	#    The coverage LIBRARY stays — dc_restore_all still needs it.
	if [ -e "$slsdir/ensure-desktop-coverage.sh" ]; then
		log_step "$(L "Disabling desktop reconciliation before restoring" \
		             "Desativando a reconciliação de atalhos antes de restaurar")"
		rm -f "$slsdir/ensure-desktop-coverage.sh" 2>/dev/null || true
		removed=1
	fi

	# 3. Drop the generated XDG-autostart drop-ins, then the unit files. Both are
	#    sentinel-guarded, so a same-named foreign unit is always preserved.
	for dropin in "$unit_dir"/app-*@autostart.service.d/"$SLSM_AUTOSTART_DROPIN"; do
		[ -f "$dropin" ] || continue
		grep -qxF "$SLSM_AUTOSTART_DROPIN_SENTINEL" "$dropin" 2>/dev/null || continue
		rm -f -- "$dropin" 2>/dev/null || continue
		rmdir -- "$(dirname -- "$dropin")" 2>/dev/null || true
		removed=1
	done
	while IFS= read -r unit; do
		[ -n "$unit" ] || continue
		path="$unit_dir/$unit"
		# Enablement symlinks: `disable` normally drops them, but it is a no-op
		# when systemd --user is unreachable and it has nothing left to clean up
		# once the unit file is gone. Remove ours explicitly so the next boot does
		# not try to start a unit that no longer exists.
		rm -f -- "$unit_dir/default.target.wants/$unit" \
		         "$unit_dir/timers.target.wants/$unit" 2>/dev/null || true
		[ -f "$path" ] || continue
		if ! grep -qxF "$SLSM_GUARDIAN_SENTINEL" "$path" 2>/dev/null; then
			log_warn "$(L "Preserving a foreign unit that shares our name: $path" \
			             "Preservando unit de terceiros com o nosso nome: $path")"
			continue
		fi
		log_step "$(L "Removing desktop reconciliation unit: $unit" \
		             "Removendo unit de reconciliação de atalhos: $unit")"
		if rm -f -- "$path" 2>/dev/null; then
			removed=1
		else
			log_warn "$(L "Could not remove $path; remove it manually" \
			             "Não foi possível remover $path; remova manualmente")"
		fi
	done <<EOF
$SLSM_GUARDIAN_UNITS
EOF
	if [ "$have_systemctl" = 1 ] && [ "$removed" = 1 ]; then
		systemctl --user daemon-reload >/dev/null 2>&1 || true
		systemctl --user reset-failed slsteam-desktop-guardian.service >/dev/null 2>&1 || true
	fi

	# 4. Hand over to the shipped helpers when they are present, so any guardian
	#    artifact a newer release adds is cleaned up even if this script predates
	#    it. Purely additive: the removals above already stand on their own.
	if [ -f "$slsdir/desktop-guardian-units.lib.sh" ] \
	   && [ -f "$slsdir/desktop-coverage.lib.sh" ]; then
		DC_HOME="$HOME"
		WRAPPER="$slsdir/path/steam"
		# shellcheck source=/dev/null
		. "$slsdir/desktop-guardian-units.lib.sh" >/dev/null 2>&1 || true
		if command -v dgu_remove_autostart_dropins >/dev/null 2>&1; then
			dgu_remove_autostart_dropins >/dev/null 2>&1 || true
		fi
		if command -v dgu_remove_units >/dev/null 2>&1; then
			dgu_remove_units >/dev/null 2>&1 || true
		fi
	fi

	[ "$removed" = 1 ] && log_success "$(L "Desktop reconciliation disarmed" \
	                                      "Reconciliação de atalhos desarmada")"
	return 0
}

# ============================================================================
# Restore a Steam .desktop entry that slsteam-moon's setup.sh patched. Current
# installs mirror originals below ~/.local/share/SLSsteam/backup; the adjacent
# suffixes are migration-only compatibility with older releases.
# ============================================================================
desktop_backup_path() {
	local f="$1"
	printf '%s/%s\n' "$HOME/.local/share/SLSsteam/backup" "${f#/}"
}

SLSM_DESKTOP_TAG='X-SLSteamMoon-Patched=true'
SLSM_DESKTOP_SEED_TAG='X-SLSteamMoon-Seeded=true'

# depatch_desktop_file <file> [sudo] [shortcut]
# Rewrite our wrapper back to the plain `steam` launcher, drop a managed
# LD_AUDIT assignment left by older installs, and strip our tags — in place.
#
# This is what we do when NO backup survives. The user did have this file (we
# patched it where it stood), so keeping it working beats deleting it: deleting
# is what used to make the menu icon vanish, and on the desktop it silently
# threw away a shortcut the user had placed themselves. Returns 1 when the
# result would still reference our tree, so the caller can fall back to
# removing a launcher that cannot be made to work.
depatch_desktop_file() {
	local f="$1" s="${2:-}" kind="${3:-}" wrapper tmp mode=0644
	wrapper="$HOME/.local/share/SLSsteam/path/steam"
	[ -f "$f" ] || return 1
	grep -q "SLSsteam" "$f" 2>/dev/null || return 1
	tmp="$(mktemp)" || return 1
	# Delimiters matter here. The wrapper substitution uses `|` because the path
	# contains `/` but never `|`. The LD_AUDIT strip must NOT use `|`, or its
	# `\|` alternation would be read as an escaped delimiter — a literal pipe —
	# and the expression would silently never match.
	if ! sed -e "s|${wrapper}|steam|g" \
	         -e 's#LD_AUDIT=[^[:space:]]*\(SLSsteam\|library-inject\|libSLS\)[^[:space:]]*[[:space:]]*##g' \
	         -e '/^X-SLSteamMoon-/d' "$f" > "$tmp" 2>/dev/null; then
		rm -f "$tmp"
		return 1
	fi
	# Anything still pointing into our tree means this entry would stay broken
	# once the tree is gone.
	if grep -q "SLSsteam" "$tmp" 2>/dev/null; then
		rm -f "$tmp"
		return 1
	fi
	if [ "$kind" = shortcut ] || [ -x "$f" ]; then
		mode=0755
	fi
	if ! $s cp -- "$tmp" "$f" 2>/dev/null; then
		rm -f "$tmp"
		return 1
	fi
	rm -f "$tmp"
	$s chmod "$mode" "$f" 2>/dev/null || true
	if [ "$mode" = 0755 ] && command -v gio >/dev/null 2>&1; then
		gio set "$f" metadata::trusted true >/dev/null 2>&1 || true
	fi
	return 0
}

# restore_or_remove_desktop <file> [sudo] [shortcut]
# "shortcut" marks an entry in the XDG desktop directory: those must stay
# executable and trusted, or the DE renders the raw filename instead of "Steam".
restore_or_remove_desktop() {
	local f="$1" use_sudo="${2:-}" kind="${3:-}"
	local backup legacy mode=0644
	backup="$(desktop_backup_path "$f")"
	local sudo_cmd=""
	[ "$use_sudo" = "sudo" ] && sudo_cmd="sudo"

	# A symlinked entry is something only a legacy install created. Drop it and
	# put the central original back as an ordinary file (mirrors dc_restore_one).
	# Ownership must be established FIRST: this sweep visits every *.desktop, so
	# an unrelated symlinked entry the user set up themselves must survive.
	if [ -L "$f" ]; then
		local target
		target="$(readlink -f -- "$f" 2>/dev/null || true)"
		case "$target" in
			"$HOME/.local/share/SLSsteam"/*) ;;
			*) [ -f "$backup" ] || return 0 ;;
		esac
		$sudo_cmd rm -f -- "$f" 2>/dev/null || true
	fi
	# A backup with no live file is still work to do: an interrupted earlier run
	# may have removed the entry without ever consuming its backup.
	[ -f "$f" ] || [ -f "$backup" ] || return 0

	# Centralize an old adjacent backup before doing anything to the active file.
	if [ ! -f "$backup" ]; then
		for legacy in "${f}.slssteam-backup" "${f}.slsteam-bak"; do
			[ -f "$legacy" ] || continue
			mkdir -p "$(dirname "$backup")" 2>/dev/null || break
			if [ -n "$sudo_cmd" ]; then
				$sudo_cmd cat -- "$legacy" > "$backup" 2>/dev/null || { rm -f "$backup"; break; }
			else
				cp -- "$legacy" "$backup" 2>/dev/null || { rm -f "$backup"; break; }
			fi
			$sudo_cmd rm -f -- "$legacy" 2>/dev/null || true
			break
		done
	fi

	# An entry WE created (a seeded same-ID shadow or autostart override) must be
	# deleted, not "restored": the user never had such a file, so putting a
	# vanilla copy there would leave an entry behind that was never theirs.
	# Mirrors dc_restore_one.
	if [ -f "$f" ] && grep -qxF "$SLSM_DESKTOP_SEED_TAG" "$f" 2>/dev/null; then
		log_step "$(L "Removing entry created by the installer: $f" \
		             "Removendo entrada criada pelo instalador: $f")"
		$sudo_cmd rm -f -- "$f" 2>/dev/null || true
		rm -f -- "$backup" 2>/dev/null || true
		return 0
	fi

	# Only act on an entry that shows our patch, or one we hold a backup for.
	if [ -f "$f" ] && ! grep -q "SLSsteam" "$f" 2>/dev/null && [ ! -f "$backup" ]; then
		return 0
	fi

	if [ -f "$backup" ]; then
		# Preserve the original file mode class. A shortcut is executable by
		# definition; anything already executable stays executable.
		if [ "$kind" = shortcut ] || [ -x "$f" ]; then
			mode=0755
		fi
		log_step "$(L "Restoring $f from backup" "Restaurando $f a partir do backup")"
		if $sudo_cmd cp --remove-destination -- "$backup" "$f" 2>/dev/null; then
			$sudo_cmd chmod "$mode" "$f" 2>/dev/null || true
			if [ "$mode" = 0755 ] && command -v gio >/dev/null 2>&1; then
				gio set "$f" metadata::trusted true >/dev/null 2>&1 || true
			fi
			rm -f -- "$backup" 2>/dev/null || true
		else
			log_warn "$(L "Could not restore $f from $backup" \
			             "Não foi possível restaurar $f a partir de $backup")"
		fi
	elif [ -f "$f" ]; then
		# No backup: repair the entry in place instead of deleting the user's
		# launcher. Removal is the last resort and requires our ownership tag —
		# the sweep is content-based, so a foreign file that merely mentions
		# SLSsteam must never be deleted on our way out.
		if depatch_desktop_file "$f" "$sudo_cmd" "$kind"; then
			log_step "$(L "Restored $f in place (no backup found)" \
			             "$f restaurado no lugar (sem backup)")"
		elif grep -qxF "$SLSM_DESKTOP_TAG" "$f" 2>/dev/null; then
			log_step "$(L "Removing patched $f (no backup found)" \
			             "Removendo $f modificado (sem backup)")"
			$sudo_cmd rm -- "$f" 2>/dev/null || true
		else
			log_warn "$(L "Not ours and still references our tree; left untouched: $f" \
			             "Não é nosso e ainda referencia nossa pasta; mantido: $f")"
		fi
	fi
}

# ============================================================================
# Restore EVERY user-owned Steam launcher entry, without the coverage library.
# ============================================================================
# Two fixed filenames were never enough. A host can carry steam-native.desktop,
# bazzite-steam.desktop or a capitalized Steam.desktop, and the desktop
# SHORTCUT — the one entry the user actually clicks — was not covered here at
# all. Since dc_restore_all returns early on any system-side failure BEFORE it
# reaches the user layer, that shortcut kept pointing at the deleted wrapper.
# None of this needs privileges: every path is inside $HOME.
restore_user_desktop_entries() {
	local dir f desktop_dir
	desktop_dir="$(uninstall_desktop_dir)"
	for dir in "$(uninstall_data_home)/applications" \
	           "$(uninstall_config_home)/autostart"; do
		[ -d "$dir" ] || continue
		for f in "$dir"/*; do
			[ -f "$f" ] || [ -L "$f" ] || continue
			is_desktop_file_name "$f" || continue
			restore_or_remove_desktop "$f"
		done
	done
	if [ -d "$desktop_dir" ]; then
		for f in "$desktop_dir"/*; do
			[ -f "$f" ] || [ -L "$f" ] || continue
			is_desktop_file_name "$f" || continue
			restore_or_remove_desktop "$f" "" shortcut
		done
	fi
	# Whatever is still in the mirror describes a file we patched but never put
	# back. Consume it now, before the tree is deleted.
	restore_orphaned_desktop_backups
}

# A backup can outlive the file it belongs to (an interrupted run, or a restore
# that never reached that layer). The live-directory sweep above cannot see
# those, because the entry itself is gone — so walk the mirror directly. Only
# paths inside $HOME are handled here; system paths need the privileged pass.
#
# The AUTOSTART layer is deliberately excluded. There, a missing file is a
# meaningful user preference: Steam deletes ~/.config/autostart/steam.desktop
# when "run at startup" is turned off, and recreating it from our backup would
# silently re-enable an autostart the user switched off. Elsewhere a missing
# entry is far more likely to be collateral damage from an interrupted run.
restore_orphaned_desktop_backups() {
	local root="$HOME/.local/share/SLSsteam/backup"
	local bak target desktop_dir autostart_dir mode
	[ -d "$root" ] || return 0
	desktop_dir="$(uninstall_desktop_dir)"
	autostart_dir="$(uninstall_config_home)/autostart"
	while IFS= read -r bak; do
		[ -n "$bak" ] || continue
		target="/${bak#"$root"/}"
		case "$target" in
			"$autostart_dir"/*) continue ;;
			"$HOME"/*) ;;
			*) continue ;;
		esac
		[ -e "$target" ] && continue
		log_step "$(L "Restoring $target from backup" "Restaurando $target a partir do backup")"
		mkdir -p "$(dirname -- "$target")" 2>/dev/null || continue
		cp -- "$bak" "$target" 2>/dev/null || continue
		case "$target" in
			"$desktop_dir"/*) mode=0755 ;;
			*) mode=0644 ;;
		esac
		chmod "$mode" "$target" 2>/dev/null || true
		rm -f -- "$bak" 2>/dev/null || true
	done < <(find "$root" -type f -name '*.desktop' 2>/dev/null)
	return 0
}

# ============================================================================
# Preserve the file mode of the XDG desktop-directory entries.
# ============================================================================
# dc_restore_one restores every entry as 0644, which strips the executable bit a
# desktop shortcut needs: KDE and GNOME render a non-executable .desktop on the
# desktop as its raw filename (and refuse to trust it) instead of as "Steam".
# setup.sh knows this — dc_patch_shortcut chmods 0755 — but the restore path does
# not. Recording the modes BEFORE any restore lets us put them back afterwards,
# and only for files we actually saw, so nothing else is ever touched.
SLSM_SHORTCUT_MODES=""

record_shortcut_modes() {
	local dir f mode
	dir="$(uninstall_desktop_dir)"
	[ -d "$dir" ] || return 0
	for f in "$dir"/*; do
		[ -f "$f" ] || continue
		is_desktop_file_name "$f" || continue
		mode="$(stat -c '%a' "$f" 2>/dev/null)" || continue
		[ -n "$mode" ] || continue
		SLSM_SHORTCUT_MODES="${SLSM_SHORTCUT_MODES}${mode}	${f}
"
	done
}

restore_shortcut_modes() {
	local mode f
	[ -n "$SLSM_SHORTCUT_MODES" ] || return 0
	while IFS="$(printf '\t')" read -r mode f; do
		[ -n "$mode" ] && [ -n "$f" ] || continue
		[ -f "$f" ] || continue
		[ "$(stat -c '%a' "$f" 2>/dev/null)" = "$mode" ] && continue
		log_step "$(L "Restoring the original permissions of $f" \
		             "Restaurando as permissões originais de $f")"
		chmod "$mode" "$f" 2>/dev/null || true
		if [ "$mode" = 755 ] && command -v gio >/dev/null 2>&1; then
			gio set "$f" metadata::trusted true >/dev/null 2>&1 || true
		fi
	done <<EOF
$SLSM_SHORTCUT_MODES
EOF
	return 0
}

# ============================================================================
# Restore the system layer (needs sudo). Attempted regardless of whether the
# coverage helper ran, because dc_restore_all bails on the first system-side
# failure and may have left this untouched.
# ============================================================================
restore_system_desktop_entries() {
	local f
	local -a pending=()
	if is_immutable_distro; then
		return 0
	fi
	# Collect first, so privileges are requested only when there is real work.
	while IFS= read -r f; do
		[ -n "$f" ] && pending+=("$f")
	done < <(system_patched_desktop_entries)
	[ "${#pending[@]}" -gt 0 ] || return 0
	if ! prime_sudo; then
		log_warn "$(L "System-wide Steam entries are still patched and could not be restored" \
		             "Entradas da Steam no sistema seguem modificadas e não puderam ser restauradas")"
		return 1
	fi
	for f in "${pending[@]}"; do
		restore_or_remove_desktop "$f" sudo
	done
	if command -v update-desktop-database >/dev/null 2>&1; then
		sudo update-desktop-database "$SLSM_SYS_APPS" >/dev/null 2>&1 || true
	fi
	return 0
}

# ============================================================================
# Safety net: never leave the user without a working Steam launcher.
# ============================================================================
# The shared coverage restore (dc_restore_all) removes a patched entry when its
# central backup is missing, and any entry it leaves behind still points at our
# wrapper — which we are about to delete. Both cases make the Steam icon vanish
# or stop launching. This heals the end state directly and is self-contained so
# it works even against an older installed coverage lib:
#   (a) any surviving steam.desktop that still runs the wrapper is rewritten back
#       to the plain `steam` launcher and de-tagged (works via system Steam);
#   (b) if NO steam.desktop exists anywhere, a minimal user entry is recreated so
#       the menu/taskbar icon returns.
# Overridable target for tests.
: "${HEAL_SYS_DESKTOP:=/usr/share/applications/steam.desktop}"

heal_steam_launcher() {
	local user_app; user_app="$(uninstall_data_home)/applications/steam.desktop"
	local sys_app="$HEAL_SYS_DESKTOP"
	local sudo_cmd; sudo_cmd="$(sudo_prefix)"
	local dir f desktop_dir

	# (a) De-patch any surviving entry that still references the wrapper, across
	# every user-owned layer — not just the canonical steam.desktop. A host may
	# carry steam-native.desktop or bazzite-steam.desktop, and the desktop
	# shortcut is the entry the user actually clicks.
	for dir in "$(uninstall_data_home)/applications" \
	           "$(uninstall_config_home)/autostart"; do
		[ -d "$dir" ] || continue
		for f in "$dir"/*; do
			[ -f "$f" ] || continue
			is_desktop_file_name "$f" || continue
			depatch_desktop_file "$f" || true
		done
	done
	desktop_dir="$(uninstall_desktop_dir)"
	if [ -d "$desktop_dir" ]; then
		for f in "$desktop_dir"/*; do
			[ -f "$f" ] || continue
			is_desktop_file_name "$f" || continue
			depatch_desktop_file "$f" "" shortcut || true
		done
	fi
	if ! is_immutable_distro && [ -n "$sudo_cmd" ]; then
		depatch_desktop_file "$sys_app" "$sudo_cmd" || true
	fi

	# (b) No working launcher survived: the user entry is missing AND the
	# system entry is either absent or still references our (deleted) wrapper
	# (e.g. sudo was unavailable to heal it). Seed a minimal vanilla user entry
	# so the menu/taskbar always launches the system Steam binary. A same-ID
	# user entry shadows a broken system one, so this fixes KDE even when we
	# could not de-patch /usr/share/applications/steam.desktop.
	local need_seed=0
	if [ ! -f "$user_app" ]; then
		if [ ! -f "$sys_app" ] || grep -q "SLSsteam" "$sys_app" 2>/dev/null; then
			need_seed=1
		fi
	fi
	if [ "$need_seed" = 1 ]; then
		log_step "$(L "No working Steam launcher survived; recreating a minimal one" \
		             "Nenhum lançador da Steam utilizável sobreviveu; recriando um mínimo")"
		mkdir -p "$(dirname "$user_app")" 2>/dev/null || return 0
		cat > "$user_app" <<'EOF'
[Desktop Entry]
Name=Steam
Comment=Application for managing and playing games on Steam
Exec=steam %U
Icon=steam
Terminal=false
Type=Application
Categories=Network;FileTransfer;Game;
MimeType=x-scheme-handler/steam;x-scheme-handler/steamlink;
PrefersNonDefaultGPU=true
EOF
		chmod 0644 "$user_app" 2>/dev/null || true
	fi
}

# ============================================================================
# Restore wrapped system launchers (/usr/bin/steam, /usr/games/steam, …)
# ============================================================================
# setup.sh replaces these package-manager-owned launcher scripts with a thin
# shim that delegates to our wrapper, backing the originals up inside
# ~/.local/share/SLSsteam/system-launcher-backup/. We MUST put them back
# BEFORE deleting that directory — otherwise the shim's fallback
# `exec "$backup"` aims at a file that no longer exists and every Steam launch
# (menu, taskbar, and `/usr/bin/steam` itself) fails. Mirrors
# setup.sh::restore_system_launchers.
SLSM_LAUNCHER_TAG="# slsteam-moon system launcher shim"

# Set when one of our launcher shims had to be left in place (no sudo). The shim
# falls back to `exec "$SLSDIR/system-launcher-backup/<name>.orig"` when the
# wrapper is gone, so that ONE directory has to outlive the uninstall.
SLSM_KEEP_LAUNCHER_BACKUP=0
# Set when a surviving shim has no recoverable original at all. In that case the
# wrapper and helper tree must remain intact; keeping only the backup directory
# would leave the shim pointing at deleted state.
SLSM_KEEP_LAUNCHER_TREE=0

load_launcher_shim_library() {
	local lib="$HOME/.local/share/SLSsteam/launcher-shim.lib.sh"
	[ -f "$lib" ] || return 1
	LS_SLSDIR="$HOME/.local/share/SLSsteam"
	LS_BACKUP_ROOT="$LS_SLSDIR/system-launcher-backup"
	if declare -p SLSM_LAUNCHER_DIRS >/dev/null 2>&1; then
		LS_LAUNCHER_DIRS=("${SLSM_LAUNCHER_DIRS[@]}")
	fi
	# shellcheck source=/dev/null
	. "$lib" >/dev/null 2>&1 || return 1
	return 0
}

is_our_launcher_shim() {
	[ -f "$1" ] && head -3 "$1" 2>/dev/null | grep -q "$SLSM_LAUNCHER_TAG"
}

# Validate a flat backup against the exact reference embedded by both current
# and historical launcher shims. A basename match alone is unsafe because
# /usr/bin/steam and /usr/games/steam share the same name.
uninstall_shim_references_backup() {
	local launcher="$1" backup="$2"
	[ -f "$launcher" ] || return 1
	grep -Fqx -- "SLSM_ORIG=\"$backup\"" "$launcher" 2>/dev/null && return 0
	grep -Fqx -- "exec \"$backup\" \"\$@\"" "$launcher" 2>/dev/null
}

uninstall_flat_backup_is_unambiguous() {
	local backup="$1" references=0 d launcher
	for d in "${SLSM_LAUNCHER_DIRS[@]}"; do
		launcher="$d/steam"
		is_our_launcher_shim "$launcher" || continue
		uninstall_shim_references_backup "$launcher" "$backup" || continue
		references=$((references + 1))
	done
	[ "$references" -eq 1 ]
}

uninstall_launcher_backup_is_usable() {
	[ -f "$1" ] && [ -x "$1" ] && ! is_our_launcher_shim "$1"
}

# Directories setup.sh may have wrapped a launcher in. An array, so no path is
# ever exposed to word splitting or globbing. Overridable for tests.
# `declare -p` probes the name without expanding it, so this stays safe under
# `set -u` (${#arr[@]} on an unset array aborts the script).
if ! declare -p SLSM_LAUNCHER_DIRS >/dev/null 2>&1; then
	SLSM_LAUNCHER_DIRS=(/usr/bin /usr/games /usr/local/bin)
fi

restore_system_launchers() {
	SLSM_KEEP_LAUNCHER_BACKUP=0
	SLSM_KEEP_LAUNCHER_TREE=0
	if is_immutable_distro; then
		local launcher d wrapped=0
		for d in "${SLSM_LAUNCHER_DIRS[@]}"; do
			launcher="$d/steam"
			if is_our_launcher_shim "$launcher"; then
				wrapped=1
				log_warn "Immutable distro has a surviving system launcher shim at $launcher; retaining the complete helper tree"
			fi
		done
		if [ "$wrapped" -eq 1 ]; then
			SLSM_KEEP_LAUNCHER_BACKUP=1
			SLSM_KEEP_LAUNCHER_TREE=1
			return 1
		fi
		return 0
	fi

	local backup_dir="$HOME/.local/share/SLSsteam/system-launcher-backup"
	local backup failed=0 wrapped_count=0 launcher d
	local sudo_cmd=""
	for d in "${SLSM_LAUNCHER_DIRS[@]}"; do
		launcher="$d/steam"
		is_our_launcher_shim "$launcher" && wrapped_count=$((wrapped_count + 1))
	done
	# A missing backup directory is normally a harmless no-op, but it is not
	# harmless when a managed shim is still installed: deleting the wrapper then
	# leaves that package launcher with no recoverable fallback. Detect this state
	# before returning and keep the uninstall retryable.
	if [ ! -d "$backup_dir" ]; then
		if [ "$wrapped_count" -gt 0 ]; then
			SLSM_KEEP_LAUNCHER_BACKUP=1
			SLSM_KEEP_LAUNCHER_TREE=1
			log_warn "System launcher shim remains but its backup directory is missing; retaining the complete uninstall tree"
			return 1
		fi
		return 0
	fi
	if [ "$(id -u)" -eq 0 ]; then
		:
	elif [ "${SLSM_SUDO_PRIMED:-0}" = 1 ]; then
		sudo_cmd="$(sudo_prefix)"
	elif [ "${SLSM_SUDO_DENIED:-0}" != 1 ] && prime_sudo; then
		sudo_cmd="$(sudo_prefix)"
	fi
	# New installations ship the sourceable launcher library. It owns the
	# mirrored backup mapping and keeps /usr/bin/steam and /usr/games/steam
	# independent. The fallback below remains for older installations that did
	# not copy the library into SLSDIR.
	if load_launcher_shim_library; then
		LS_SLSDIR="$HOME/.local/share/SLSsteam"
		LS_BACKUP_ROOT="$backup_dir"
		LS_SUDO="$sudo_cmd"
		if ls_restore_shims; then
			return 0
		fi
		while IFS= read -r launcher; do
			[ -n "$launcher" ] || continue
			backup="$(ls_backup_path "$launcher")"
			if ! uninstall_launcher_backup_is_usable "$backup" || \
			   ! uninstall_shim_references_backup "$launcher" "$backup"; then
				backup="$(ls_legacy_backup_path "$launcher")"
				if ! ls_legacy_backup_is_unambiguous_restore "$backup" || \
				   ! uninstall_shim_references_backup "$launcher" "$backup"; then
					SLSM_KEEP_LAUNCHER_TREE=1
				fi
			fi
			if ! uninstall_launcher_backup_is_usable "$backup" || \
			   ! uninstall_shim_references_backup "$launcher" "$backup"; then
				SLSM_KEEP_LAUNCHER_TREE=1
			fi
			SLSM_KEEP_LAUNCHER_BACKUP=1
			log_info "$(L "$launcher keeps its launcher backup. To finish: sudo cp '$backup' '$launcher'" \
			             "$launcher mantém seu backup. Para concluir: sudo cp '$backup' '$launcher'")"
		done < <(ls_wrapped_paths)
		return 1
	fi

	# Legacy fallback: support both the historical flat steam.orig and the
	# path-mirrored layout even when the shared library is unavailable. A
	# mirrored restore can make a flat backup unambiguous, so retry after every
	# pass that makes progress.
	local pass_progress remaining relative base parent orig_path p candidate_backup
	while :; do
		failed=0
		pass_progress=0
		remaining=0
		wrapped_count=0
		SLSM_KEEP_LAUNCHER_BACKUP=0
		for d in "${SLSM_LAUNCHER_DIRS[@]}"; do
			launcher="$d/steam"
			is_our_launcher_shim "$launcher" && wrapped_count=$((wrapped_count + 1))
		done

		while IFS= read -r -d '' backup; do
			relative="${backup#"$backup_dir"/}"
			base="${relative##*/}"
			base="${base%.orig}"
			parent="${relative%/*}"
			orig_path=""

			# A mirrored backup such as usr/games/steam.orig maps only to a launcher
			# directory ending in usr/games; never let it collide with usr/bin/steam.
			# A flat candidate is accepted only when exactly one surviving shim
			# explicitly references that candidate path.
			if [ "$parent" = "$relative" ] && \
			   ! uninstall_flat_backup_is_unambiguous "$backup"; then
				failed=1
				SLSM_KEEP_LAUNCHER_BACKUP=1
				log_warn "Ambiguous or unassociated flat launcher backup: retaining shims and backup"
				continue
			fi

			if [ "$parent" != "$relative" ]; then
				for d in "${SLSM_LAUNCHER_DIRS[@]}"; do
					case "$d" in
						"$parent"|*/"$parent")
							p="$d/$base"
							is_our_launcher_shim "$p" || continue
							uninstall_launcher_backup_is_usable "$backup" || continue
							uninstall_shim_references_backup "$p" "$backup" || continue
							[ -f "$p" ] && { orig_path="$p"; break; }
							;;
					esac
				done
			else
				# Only the historical flat layout uses basename matching, and the
				# ambiguity guard above allows it only for one surviving shim.
				for d in "${SLSM_LAUNCHER_DIRS[@]}"; do
					p="$d/$base"
					[ -f "$p" ] || continue
					is_our_launcher_shim "$p" || continue
					uninstall_launcher_backup_is_usable "$backup" || continue
					uninstall_shim_references_backup "$p" "$backup" || continue
					orig_path="$p"
					break
				done
			fi
			[ -n "$orig_path" ] || continue
			is_our_launcher_shim "$orig_path" || continue
			# A captured shim is not an original and must never be installed as
			# one, otherwise the wrapper can recurse after uninstall.
			if ! uninstall_launcher_backup_is_usable "$backup"; then
				failed=1
				SLSM_KEEP_LAUNCHER_BACKUP=1
				SLSM_KEEP_LAUNCHER_TREE=1
				log_warn "$(L "Refusing unusable launcher backup $backup" "Recusando backup de lançador inutilizável $backup")"
				continue
			fi

			if [ -n "$sudo_cmd" ]; then
				if $sudo_cmd cp -- "$backup" "$orig_path" 2>/dev/null \
				   && $sudo_cmd chmod 0755 "$orig_path" 2>/dev/null \
				   && ! is_our_launcher_shim "$orig_path"; then
					log_success "$(L "Restored $orig_path" "$orig_path restaurado")"
					pass_progress=1
					continue
				fi
				log_warn "$(L "Could not restore $orig_path (sudo failed)" \
				           "Não foi possível restaurar $orig_path (sudo falhou)")"
			elif [ -w "$orig_path" ] \
			     && cp -- "$backup" "$orig_path" 2>/dev/null \
			     && chmod 0755 "$orig_path" 2>/dev/null \
			     && ! is_our_launcher_shim "$orig_path"; then
				log_success "$(L "Restored $orig_path" "$orig_path restaurado")"
				pass_progress=1
				continue
			else
				log_warn "$(L "Cannot restore $orig_path without administrator access" \
				           "Não é possível restaurar $orig_path sem acesso de administrador")"
			fi

			failed=1
			# The shim survives. Keep its fallback alive so Steam still launches,
			# and hand the user the exact command that finishes the job.
			SLSM_KEEP_LAUNCHER_BACKUP=1
			log_info "$(L "$orig_path keeps working through the retained backup. To finish: sudo cp '$backup' '$orig_path'" \
			             "$orig_path continua funcionando pelo backup mantido. Para concluir: sudo cp '$backup' '$orig_path'")"
		# Enumerate path-mirrored backups first. Flat legacy backups are handled
		# only after their exact surviving shim association is verified, so find
		# order cannot restore one into the wrong launcher.
		done < <(
			find "$backup_dir" -mindepth 2 -type f -name '*.orig' -print0 2>/dev/null
			find "$backup_dir" -maxdepth 1 -type f -name '*.orig' -print0 2>/dev/null
		)

		# Do not declare success merely because every discovered backup was consumed:
		# a launcher shim with no matching backup would otherwise survive while its
		# fallback directory is deleted below.
		for d in "${SLSM_LAUNCHER_DIRS[@]}"; do
			launcher="$d/steam"
			if is_our_launcher_shim "$launcher"; then
				remaining=1
				failed=1
				candidate_backup="$backup_dir/${launcher#/}.orig"
				if ! uninstall_launcher_backup_is_usable "$candidate_backup" || \
				   ! uninstall_shim_references_backup "$launcher" "$candidate_backup"; then
					candidate_backup="$backup_dir/$(basename -- "$launcher").orig"
					if ! uninstall_launcher_backup_is_usable "$candidate_backup" || \
					   ! uninstall_shim_references_backup "$launcher" "$candidate_backup"; then
						SLSM_KEEP_LAUNCHER_TREE=1
					fi
				fi
				SLSM_KEEP_LAUNCHER_BACKUP=1
				log_warn "$(L "System launcher shim remains at $launcher; retaining backups" \
				           "O shim do lançador de sistema continua em $launcher; mantendo backups")"
			fi
		done

		if [ "$remaining" -eq 0 ]; then
			SLSM_KEEP_LAUNCHER_BACKUP=0
			return 0
		fi
		[ "$pass_progress" -eq 1 ] || return 1
	done
}

# ============================================================================
# Step: slsteam-moon
# ============================================================================
uninstall_slsteam_moon() {
	local USER_APPS; USER_APPS="$(uninstall_data_home)/applications"
	local launcher_restore_complete=1

	# FIRST, before a single entry is restored: take the desktop guardian out of
	# the picture. Its .path unit watches the very directories we are about to
	# write to, so restoring while it is armed makes it re-patch everything and
	# re-install its own units. See disarm_desktop_guardian.
	disarm_desktop_guardian

	# Snapshot the desktop-directory modes before any restore touches them.
	record_shortcut_modes

	# Wrapper PATH entry in shell rc files.
	local rc
	for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
		[ -f "$rc" ] || continue
		if grep -q "SLSsteam/path" "$rc" 2>/dev/null; then
			log_step "$(L "Cleaning wrapper PATH entry from $(basename "$rc")" \
			             "Limpando PATH do wrapper em $(basename "$rc")")"
			sed -i '/# SLSsteam: Add wrapper to PATH/d' "$rc" 2>/dev/null || true
			sed -i '\|SLSsteam/path|d' "$rc" 2>/dev/null || true
		fi
	done

	# Prefer the installed coverage helper: it knows every historical layout and
	# restores each patched launcher, shortcut and autostart entry from the
	# central mirrored backup tree.
	local coverage_lib="$HOME/.local/share/SLSsteam/desktop-coverage.lib.sh"
	if [ -f "$coverage_lib" ]; then
		DC_HOME="$HOME"
		DC_BACKUP_ROOT="$HOME/.local/share/SLSsteam/backup"
		DC_TAG="X-SLSteamMoon-Patched=true"
		WRAPPER="$HOME/.local/share/SLSsteam/path/steam"
		# shellcheck source=/dev/null
		. "$coverage_lib"
		DC_SUDO=""
		! is_immutable_distro && command -v sudo >/dev/null 2>&1 && DC_SUDO="sudo"
		dc_restore_all
	fi

	# Backstop, ALWAYS: restore every user-owned entry from its central backup,
	# whether or not the coverage helper ran. dc_restore_all restores the SYSTEM
	# layer first and bails (return 2) on any system-side failure — e.g. sudo
	# unavailable for /usr/share/applications/steam.desktop — BEFORE it ever
	# touches the user layer, which needs no privileges at all. When that happens
	# the backups under ~/.local/share/SLSsteam/backup sit unused until `rm -rf`
	# deletes them: a backup saved and never used, and a desktop shortcut left
	# pointing at the wrapper we are about to delete. This pass closes that gap
	# and is a harmless no-op once an entry is already restored (its backup is
	# gone and the file no longer carries our tag).
	restore_user_desktop_entries
	if command -v update-desktop-database >/dev/null 2>&1; then
		update-desktop-database "$USER_APPS" >/dev/null 2>&1 || true
	fi

	# System-wide entries. Attempted independently of the coverage helper for the
	# same reason: dc_restore_all may have bailed here and skipped everything.
	restore_system_desktop_entries

	# Legacy /usr/games/steam patch from older installs.
	if ! is_immutable_distro && [ -f "/usr/games/steam" ] && grep -q "SLSsteam" "/usr/games/steam" 2>/dev/null; then
		log_step "$(L "Found legacy /usr/games/steam modification" \
		             "Modificação legada em /usr/games/steam encontrada")"
		if [ -f "/usr/games/steam.slsteam-backup" ]; then
			log_info "$(L "Restoring original /usr/games/steam (requires sudo)" \
			             "Restaurando /usr/games/steam original (requer sudo)")"
			sudo cp "/usr/games/steam.slsteam-backup" "/usr/games/steam" 2>/dev/null || true
			sudo rm "/usr/games/steam.slsteam-backup" 2>/dev/null || true
			log_success "$(L "Restored /usr/games/steam" "/usr/games/steam restaurado")"
		else
			log_warn "$(L "Legacy modification found but no backup exists" \
			             "Modificação legada encontrada, mas sem backup")"
		fi
	fi

	# Guarantee a working Steam launcher survives before we delete the wrapper the
	# patched entries reference. Runs whether or not the coverage helper was used.
	heal_steam_launcher

	# Last: put back the file modes the shared restore flattened to 0644.
	restore_shortcut_modes
	if command -v update-desktop-database >/dev/null 2>&1; then
		update-desktop-database "$USER_APPS" >/dev/null 2>&1 || true
	fi
	# KDE resolves menu/taskbar launchers through KSycoca, which update-desktop-
	# database does not refresh; rebuild it so the restored icon reappears at once.
	if command -v kbuildsycoca6 >/dev/null 2>&1; then
		kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
	elif command -v kbuildsycoca5 >/dev/null 2>&1; then
		kbuildsycoca5 --noincremental >/dev/null 2>&1 || true
	fi

	# Restore any wrapped system launchers (/usr/bin/steam, /usr/games/steam,
	# /usr/local/bin/steam) from their backups BEFORE removing the SLSsteam dir.
	# setup.sh installs a shim that falls back to `exec "$backup"`, and that
	# backup lives inside the directory we are about to delete — so restoring
	# first is what keeps `/usr/bin/steam` working afterwards. When restoration
	# is impossible it raises SLSM_KEEP_LAUNCHER_BACKUP, and the removal below
	# spares exactly that directory.
	if restore_system_launchers; then
		launcher_restore_complete=1
	else
		launcher_restore_complete=0
	fi

	# coverage.policy is outside SLSDIR. Forget it only after every system
	# launcher shim has been restored; if a shim survives, retain the policy and
	# backup together so a later retry still describes the live coverage path.
	if [ "$launcher_restore_complete" = 1 ]; then
		if command -v dc_forget_policy >/dev/null 2>&1; then
			dc_forget_policy || true
		else
			rm -f -- "$(uninstall_state_home)/slsteam-moon/coverage.policy" 2>/dev/null || true
		fi
	else
		log_warn "Keeping coverage.policy while a system launcher shim still needs restoration"
	fi

	# Binaries + wrapper. When a launcher shim had to be left behind, everything
	# goes EXCEPT system-launcher-backup: that is the path the surviving shim
	# execs, so removing it would break `steam` on the command line, in the menu
	# and in the taskbar.
	if [ "${SLSM_KEEP_LAUNCHER_TREE:-0}" = 1 ] && [ -d "$HOME/.local/share/SLSsteam" ]; then
		log_warn "$(L "A system launcher has no recoverable backup; retaining the complete ~/.local/share/SLSsteam tree so its shim and fallback remain usable." \
		             "Um lançador do sistema não tem backup recuperável; mantendo toda a árvore ~/.local/share/SLSsteam para preservar o shim e o fallback.")"
	elif [ "$SLSM_KEEP_LAUNCHER_BACKUP" = 1 ] && [ -d "$HOME/.local/share/SLSsteam" ]; then
		log_step "$(L "Removing ~/.local/share/SLSsteam (keeping the system launcher backup)" \
		             "Removendo ~/.local/share/SLSsteam (mantendo o backup do lançador de sistema)")"
		find "$HOME/.local/share/SLSsteam" -mindepth 1 -maxdepth 1 \
			! -name system-launcher-backup -exec rm -rf -- {} + 2>/dev/null || true
		log_warn "$(L "Kept ~/.local/share/SLSsteam/system-launcher-backup so the system Steam launcher keeps working. Remove it after restoring the launcher with the command above." \
		             "~/.local/share/SLSsteam/system-launcher-backup foi mantido para o lançador da Steam continuar funcionando. Remova-o após restaurar o lançador com o comando acima.")"
	elif [ -d "$HOME/.local/share/SLSsteam" ]; then
		log_step "$(L "Removing ~/.local/share/SLSsteam" "Removendo ~/.local/share/SLSsteam")"
		rm -rf "$HOME/.local/share/SLSsteam" 2>/dev/null || true
		# A concurrent writer can recreate a subtree while `rm` is still walking
		# it, which is exactly how a backup/ tree used to survive the uninstall.
		# Retry once, then report the real path instead of claiming success.
		if [ -d "$HOME/.local/share/SLSsteam" ]; then
			sleep 1
			rm -rf "$HOME/.local/share/SLSsteam" 2>/dev/null || true
		fi
		if [ -d "$HOME/.local/share/SLSsteam" ]; then
			log_warn "$(L "Could not fully remove $HOME/.local/share/SLSsteam; remove it manually" \
			             "Não foi possível remover $HOME/.local/share/SLSsteam por completo; remova manualmente")"
		else
			log_success "$(L "Removed ~/.local/share/SLSsteam" "~/.local/share/SLSsteam removido")"
		fi
	fi

	# Guardian bookkeeping: the reconciliation log, the recorded input
	# fingerprints and the boot-health counters written by the wrapper.
	local state_dir; state_dir="$(uninstall_state_home)/slsteam-moon"
	if [ -d "$state_dir" ]; then
		if [ "$launcher_restore_complete" = 1 ] || [ ! -f "$state_dir/coverage.policy" ]; then
			log_step "$(L "Removing $state_dir" "Removendo $state_dir")"
			rm -rf "$state_dir" 2>/dev/null || true
		else
			find "$state_dir" -mindepth 1 -maxdepth 1 \
				! -name coverage.policy -exec rm -rf -- {} + 2>/dev/null || true
			log_warn "$(L "Kept $state_dir/coverage.policy for the launcher restoration retry" \
			           "$state_dir/coverage.policy foi mantido para a nova tentativa de restauração")"
		fi
	fi

	# User config (depot keys, additional apps, scan caches).
	if [ -d "$HOME/.config/SLSsteam" ]; then
		log_step "$(L "Removing ~/.config/SLSsteam (depot keys, config)" \
		             "Removendo ~/.config/SLSsteam (depot keys, config)")"
		rm -rf "$HOME/.config/SLSsteam" 2>/dev/null || true
	fi

	# Log file written by SLSsteam.so.
	rm -f "$HOME/.SLSsteam.log" 2>/dev/null || true

	log_success "$(L "slsteam-moon removed" "slsteam-moon removido")"
}

# ============================================================================
# Step: LuaTools plugin (covers any plugin root Millennium might use)
# ============================================================================
uninstall_luatools_plugin() {
	local roots=(
		"$HOME/.local/share/millennium/plugins"
		"$HOME/.millennium/plugins"
		"$HOME/.steam/steam/millennium/plugins"
		"$HOME/.steam/steam/steamui/millennium/plugins"
		"$HOME/.local/share/Steam/millennium/plugins"
	)
	local root name p removed=0
	for root in "${roots[@]}"; do
		for name in luatools LuaToolsLinux; do
			p="$root/$name"
			[ -d "$p" ] || continue
			log_step "$(L "Removing plugin: $p" "Removendo plugin: $p")"
			rm -rf "$p" 2>/dev/null || true
			removed=1
		done
	done

	# Old standalone luatools data dirs (from prior ports).
	local d
	for d in "$HOME/.local/share/luatools" "$HOME/.config/luatools" "$HOME/.luatools"; do
		if [ -e "$d" ]; then
			log_step "$(L "Removing $d" "Removendo $d")"
			rm -rf "$d" 2>/dev/null || true
			removed=1
		fi
	done

	if [ "$removed" = 1 ]; then
		log_success "$(L "LuaTools plugin removed" "Plugin LuaTools removido")"
	else
		log_success "$(L "No LuaTools plugin found (already absent)" \
		             "Nenhum plugin LuaTools encontrado (já ausente)")"
	fi
}

# ============================================================================
# Step: Lumen (millennium-less bridge) + its install dir
# ============================================================================
# The sidecar outlives Steam by ~45s and, until it exits, re-runs
# ensure-desktop-coverage.sh --user every 3s (lumen/lua/deskcover.lua). Deleting
# its directory does not stop it, so it has to be killed BEFORE we restore
# anything — otherwise a tick can re-patch the entries we just put back, the same
# way the systemd guardian did. Mirrors install.sh::stop_lumen.
stop_lumen() {
	local lumen_bin="$HOME/.local/share/Lumen/lumen"

	if ! pgrep -f "$lumen_bin" >/dev/null 2>&1; then
		log_success "$(L "No running Lumen process detected" "Nenhum processo do Lumen em execução")"
		return 0
	fi

	log_info "$(L "Stopping running Lumen" "Parando o Lumen em execução")"
	pkill -TERM -f "$lumen_bin" 2>/dev/null || true

	local i
	for i in 1 2 3 4 5; do
		if ! pgrep -f "$lumen_bin" >/dev/null 2>&1; then
			log_success "$(L "Lumen stopped" "Lumen parado")"
			return 0
		fi
		sleep 1
	done

	pkill -KILL -f "$lumen_bin" 2>/dev/null || true
	sleep 1
	log_success "$(L "Lumen stopped" "Lumen parado")"
}

uninstall_lumen() {
	stop_lumen
	if [ -d "$HOME/.local/share/Lumen" ]; then
		log_step "$(L "Removing ~/.local/share/Lumen" "Removendo ~/.local/share/Lumen")"
		rm -rf "$HOME/.local/share/Lumen" 2>/dev/null || true
	fi
	# CEF remote-debugging flag we created for Lumen (harmless, but tidy up).
	rm -f "$HOME/.steam/steam/.cef-enable-remote-debugging" \
	      "$HOME/.steam/debian-installation/.cef-enable-remote-debugging" 2>/dev/null || true
	log_success "$(L "Lumen removed" "Lumen removido")"
}

# ============================================================================
# Step: Millennium (per upstream uninstall docs)
# ============================================================================
uninstall_millennium() {
	local sudo_cmd; sudo_cmd="$(sudo_prefix)"
	local xdg_config="${XDG_CONFIG_HOME:-$HOME/.config}/millennium"
	local xdg_data="${XDG_DATA_HOME:-$HOME/.local/share}/millennium"
	local steam_root="$HOME/.steam/steam"

	# --- Symlinks Millennium drops into Steam's runtime dirs --------------
	# On install, Millennium replaces libXtst.so.6 in ~/.steam/steam/
	# ubuntu12_{32,64}/ with symlinks pointing to its own bootstrap libs
	# under /usr/lib/millennium. If we leave those in place after removing
	# /usr/lib/millennium, Steam will try to dlopen a dangling symlink and
	# may fail or behave oddly. Remove them; Steam re-extracts the genuine
	# libXtst.so.6 from bootstrap.tar.xz on the next launch.
	local link
	for link in \
		"$steam_root/ubuntu12_32/libXtst.so.6" \
		"$steam_root/ubuntu12_64/libXtst.so.6" \
		"$steam_root/ubuntu12_64/libmillennium_hhx64.so"; do
		if [ -L "$link" ]; then
			# Only remove if it actually points to Millennium.
			local target
			target="$(readlink "$link" 2>/dev/null || true)"
			case "$target" in
				*/millennium/*|*libmillennium*)
					log_step "$(L "Removing Millennium symlink: $link" \
					             "Removendo symlink do Millennium: $link")"
					rm -f "$link" 2>/dev/null || true
					;;
			esac
		fi
	done

	# --- User-side dirs (themes, plugins, config.json) --------------------
	for d in "$xdg_config" "$xdg_data"; do
		if [ -d "$d" ]; then
			log_step "$(L "Removing $d" "Removendo $d")"
			rm -rf "$d" 2>/dev/null || true
		fi
	done

	# --- System-side dirs (Millennium's loader) ---------------------------
	local sys_dirs=(/usr/lib/millennium /usr/share/millennium)
	local need_sudo=0
	for d in "${sys_dirs[@]}"; do
		if [ -d "$d" ]; then need_sudo=1; break; fi
	done

	if [ "$need_sudo" = 1 ]; then
		if [ -z "$sudo_cmd" ] && [ "$(id -u)" -ne 0 ]; then
			log_warn "$(L "sudo not available; system-wide Millennium files left in place: ${sys_dirs[*]}" \
			             "sudo indisponível; arquivos do Millennium do sistema mantidos: ${sys_dirs[*]}")"
		else
			log_info "$(L "Removing system-wide Millennium (requires sudo)" \
			             "Removendo Millennium do sistema (requer sudo)")"
			for d in "${sys_dirs[@]}"; do
				if [ -d "$d" ]; then
					log_step "$(L "Removing $d" "Removendo $d")"
					$sudo_cmd rm -rf "$d" 2>/dev/null || true
				fi
			done
		fi
	fi

	log_success "$(L "Millennium removed" "Millennium removido")"
	log_info "$(L "Steam will re-extract libXtst.so.6 from its own bootstrap on next launch." \
	             "A Steam vai reextrair libXtst.so.6 do próprio bootstrap no próximo início.")"
}

# ============================================================================
# Step: Game Mode (gamescope session) launcher hook
# ============================================================================
# Remove the sessions.d/steam override the installer drops in Game Mode, but
# ONLY when it is ours (sentinel-guarded) so we never delete a user's own
# session config. Distro-agnostic: checks both known config base names. A
# complete no-op on hosts that never had the hook.
remove_gamemode_hook() {
	local base hook removed=0
	for base in gamescope-session-plus gamescope-session; do
		hook="${XDG_CONFIG_HOME:-$HOME/.config}/$base/sessions.d/steam"
		if [ -f "$hook" ] && grep -qF "managed-by: slsteammoon" "$hook" 2>/dev/null; then
			log_step "$(L "Removing Game Mode launcher hook: $hook" \
			             "Removendo hook do Game Mode: $hook")"
			rm -f "$hook" 2>/dev/null || true
			removed=1
			# Restore a foreign backup we may have stashed on install.
			local bak
			bak="$(ls -1t "$hook".bak.* 2>/dev/null | head -n1)"
			if [ -n "$bak" ] && [ -f "$bak" ]; then
				log_step "$(L "Restoring previous $hook from $bak" \
				             "Restaurando $hook a partir de $bak")"
				mv -- "$bak" "$hook" 2>/dev/null || true
			fi
		fi
	done
	[ "$removed" = 1 ] && log_success "$(L "Game Mode hook removed" "Hook do Game Mode removido")"

	# SteamOS systemd drop-in (steam-launcher.service.d/slsteammoon.conf).
	# Sentinel-guarded so we never touch a foreign drop-in.
	local dropin="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/steam-launcher.service.d/slsteammoon.conf"
	if [ -f "$dropin" ] && grep -qF "managed-by: slsteammoon" "$dropin" 2>/dev/null; then
		log_step "$(L "Removing SteamOS Game Mode drop-in: $dropin" \
		             "Removendo drop-in do Game Mode (SteamOS): $dropin")"
		rm -f "$dropin" 2>/dev/null || true
		# Drop the now-empty override dir (rmdir is a no-op if other files remain).
		rmdir "$(dirname "$dropin")" 2>/dev/null || true
		systemctl --user daemon-reload >/dev/null 2>&1 || true
		log_success "$(L "SteamOS Game Mode drop-in removed" "Drop-in do Game Mode (SteamOS) removido")"
	fi
	return 0
}

# ============================================================================
# Step: old-port leftovers (headcrab + friends)
# ============================================================================
cleanup_old_port_leftovers() {
	local steam_root="$HOME/.steam/steam"

	restore_steam_sh "$steam_root"

	if [ -f "$steam_root/client.sh" ]; then
		log_step "$(L "Removing leftover client.sh" "Removendo client.sh residual")"
		rm -f "$steam_root/client.sh" 2>/dev/null || true
	fi

	if [ -f "$steam_root/steam.cfg" ] && grep -qi "BootStrapperInhibitAll" "$steam_root/steam.cfg" 2>/dev/null; then
		log_step "$(L "Removing update-blocking steam.cfg" "Removendo steam.cfg que bloqueia updates")"
		rm -f "$steam_root/steam.cfg" 2>/dev/null || true
	fi

	local d
	for d in "$HOME/.headcrab"; do
		if [ -e "$d" ]; then
			log_step "$(L "Removing $d" "Removendo $d")"
			rm -rf "$d" 2>/dev/null || true
		fi
	done
	rm -f "$HOME/.local/share/applications/headcrab.desktop" 2>/dev/null || true
	rm -f "$HOME/.local/share/icons/hicolor/48x48/apps/headcrab.png" 2>/dev/null || true

	# CloudRedirect: we install this as part of our stack (cloud saves), so
	# remove it on uninstall. Drop the hook + data dir and, if present, the
	# flatpak companion app. The user's cloud provider data (on their Drive)
	# is untouched.
	if [ -e "$HOME/.local/share/CloudRedirect" ]; then
		log_step "$(L "Removing CloudRedirect (~/.local/share/CloudRedirect)" \
		             "Removendo CloudRedirect (~/.local/share/CloudRedirect)")"
		rm -rf "$HOME/.local/share/CloudRedirect" 2>/dev/null || true
	fi
	rm -rf "$HOME/.config/CloudRedirect" 2>/dev/null || true
	if command -v flatpak >/dev/null 2>&1 \
	   && flatpak list 2>/dev/null | grep -q "org.cloudredirect.CloudRedirect"; then
		log_step "$(L "Removing the CloudRedirect app" "Removendo o app CloudRedirect")"
		flatpak uninstall --user -y org.cloudredirect.CloudRedirect >/dev/null 2>&1 || true
	fi

	# Arch: system slssteam package conflicts with the local install.
	if ! is_immutable_distro && command -v pacman >/dev/null 2>&1; then
		local pkgs
		pkgs="$(pacman -Qq 2>/dev/null | grep -E '^slssteam(-git)?$' || true)"
		if [ -n "$pkgs" ]; then
			local sudo_cmd; sudo_cmd="$(sudo_prefix)"
			log_step "$(L "Removing conflicting system package(s): $pkgs" \
			             "Removendo pacote(s) de sistema conflitante(s): $pkgs")"
			# shellcheck disable=SC2086
			$sudo_cmd pacman -Rns --noconfirm $pkgs >/dev/null 2>&1 \
				|| log_warn "$(L "Could not remove $pkgs; remove it manually." \
				                 "Não foi possível remover $pkgs; remova manualmente.")"
		fi
	fi
}

# ============================================================================
# Entry point
# ============================================================================
main() {
	detect_language
	print_banner

	print_section "$(L "Pre-flight" "Verificações iniciais")"
	check_not_root
	log_success "$(L "Running as user $(whoami)" "Rodando como usuário $(whoami)")"
	# Ask once, up front, and only when something outside $HOME really needs
	# restoring. Every privileged call below silences stderr, so without this an
	# unavailable sudo degraded the restoration with no prompt and no warning.
	prime_sudo || true

	print_section "$(L "Stopping Steam" "Parando a Steam")"
	stop_steam
	# The Lumen sidecar re-runs the desktop reconciliation CLI every few seconds
	# and outlives Steam, so it has to go before anything is restored.
	stop_lumen

	print_section "$(L "Removing LuaTools plugin" "Removendo plugin LuaTools")"
	uninstall_luatools_plugin

	print_section "$(L "Removing Lumen" "Removendo Lumen")"
	uninstall_lumen    
	
	if [ -z "${OPT_KEEP_MILLENNIUM:-}" ]; then
	print_section "$(L "Removing Millennium" "Removendo Millennium")"
	uninstall_millennium
    fi	

	print_section "$(L "Removing slsteam-moon" "Removendo slsteam-moon")"
	uninstall_slsteam_moon

	print_section "$(L "Removing Game Mode launcher hook" "Removendo hook do Game Mode")"
	remove_gamemode_hook

	print_section "$(L "Cleaning up leftover files" "Limpando arquivos residuais")"
	cleanup_old_port_leftovers

	print_complete
}

# Run the uninstaller unless sourced for unit tests (SLSPLUGIN_LIB_ONLY=1).
# Plain `curl ... | bash` leaves SLSPLUGIN_LIB_ONLY unset, so main still runs.
if [ -z "${SLSPLUGIN_LIB_ONLY:-}" ]; then
	main "$@"
fi
