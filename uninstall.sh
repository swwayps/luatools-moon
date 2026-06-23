#!/usr/bin/env bash
# ============================================================================
#  luatools-moon — one-shot uninstaller
# ============================================================================
#  Removes EVERYTHING this stack installs, in a single command:
#
#    curl -fsSL https://codeberg.org/unplausible/luatools-moon/raw/branch/main/uninstall.sh | bash
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
	echo -e "    ${GREEN}•${NC} Millennium"
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

# Privilege-escalation prefix for system-wide removals.
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
# Restore a Steam .desktop entry that slsteam-moon's setup.sh patched.
# The setup.sh stores its backup as <desktop>.slsteam-bak.
# ============================================================================
restore_or_remove_desktop() {
	local f="$1" use_sudo="${2:-}"
	local backup="${f}.slsteam-bak"
	local sudo_cmd=""
	[ "$use_sudo" = "sudo" ] && sudo_cmd="sudo"

	[ -f "$f" ] || return 0
	# Only act if the file shows our patch (Exec= mentions SLSsteam) or
	# a backup exists alongside it.
	if ! grep -q "SLSsteam" "$f" 2>/dev/null && [ ! -f "$backup" ]; then
		return 0
	fi

	if [ -f "$backup" ]; then
		log_step "$(L "Restoring $f from backup" "Restaurando $f a partir do backup")"
		$sudo_cmd cp -- "$backup" "$f" 2>/dev/null || true
		$sudo_cmd rm -- "$backup" 2>/dev/null || true
	else
		log_step "$(L "Removing patched $f (no backup found)" \
		             "Removendo $f modificado (sem backup)")"
		$sudo_cmd rm -- "$f" 2>/dev/null || true
	fi
}

# ============================================================================
# Step: slsteam-moon
# ============================================================================
uninstall_slsteam_moon() {
	local USER_APPS="$HOME/.local/share/applications"
	local USER_DESKTOP="$USER_APPS/steam.desktop"
	local SYS_DESKTOP="/usr/share/applications/steam.desktop"

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

	# User-local .desktop.
	restore_or_remove_desktop "$USER_DESKTOP"
	if command -v update-desktop-database >/dev/null 2>&1; then
		update-desktop-database "$USER_APPS" >/dev/null 2>&1 || true
	fi

	# Autostart override (SteamOS/Bazzite desktop auto-launch). Only ours.
	local autostart="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/steam.desktop"
	if [ -f "$autostart" ] && grep -qE 'X-SLSteamMoon-Patched=true|SLSsteam/path' "$autostart" 2>/dev/null; then
		if [ -f "$autostart.slssteam-backup" ]; then
			log_step "$(L "Restoring Steam autostart from backup" \
			             "Restaurando autostart da Steam a partir do backup")"
			mv -- "$autostart.slssteam-backup" "$autostart" 2>/dev/null || true
		else
			log_step "$(L "Removing Steam autostart override" \
			             "Removendo override de autostart da Steam")"
			rm -f "$autostart" 2>/dev/null || true
		fi
	fi

	# System-wide .desktop (only if we actually patched it).
	if [ -f "$SYS_DESKTOP" ] && grep -q "SLSsteam" "$SYS_DESKTOP" 2>/dev/null; then
		if command -v sudo >/dev/null 2>&1; then
			log_info "$(L "Restoring system .desktop (requires sudo)" \
			             "Restaurando .desktop do sistema (requer sudo)")"
			restore_or_remove_desktop "$SYS_DESKTOP" sudo
			if command -v update-desktop-database >/dev/null 2>&1; then
				sudo update-desktop-database "/usr/share/applications" >/dev/null 2>&1 || true
			fi
		else
			log_warn "$(L "sudo not available; cannot restore $SYS_DESKTOP automatically" \
			             "sudo indisponível; não foi possível restaurar $SYS_DESKTOP automaticamente")"
		fi
	fi

	# Legacy /usr/games/steam patch from older installs.
	if [ -f "/usr/games/steam" ] && grep -q "SLSsteam" "/usr/games/steam" 2>/dev/null; then
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

	# Binaries + wrapper.
	if [ -d "$HOME/.local/share/SLSsteam" ]; then
		log_step "$(L "Removing ~/.local/share/SLSsteam" "Removendo ~/.local/share/SLSsteam")"
		rm -rf "$HOME/.local/share/SLSsteam" 2>/dev/null || true
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
	if command -v pacman >/dev/null 2>&1; then
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

	print_section "$(L "Stopping Steam" "Parando a Steam")"
	stop_steam

	print_section "$(L "Removing LuaTools plugin" "Removendo plugin LuaTools")"
	uninstall_luatools_plugin

	print_section "$(L "Removing Millennium" "Removendo Millennium")"
	uninstall_millennium

	print_section "$(L "Removing slsteam-moon" "Removendo slsteam-moon")"
	uninstall_slsteam_moon

	print_section "$(L "Removing Game Mode launcher hook" "Removendo hook do Game Mode")"
	remove_gamemode_hook

	print_section "$(L "Cleaning up leftover files" "Limpando arquivos residuais")"
	cleanup_old_port_leftovers

	print_complete
}

main "$@"
