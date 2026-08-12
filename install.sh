#!/usr/bin/env bash
# ============================================================================
#  luatools-moon — Millennium branch redirector
# ============================================================================
#
#  The Millennium line is no longer maintained. Keep this entry point alive so
#  old install commands explain the migration and continue with the supported
#  Lumen installer from the main branch.
# ============================================================================

set -uo pipefail

MAIN_INSTALL_URL="https://raw.githubusercontent.com/swwayps/luatools-moon/main/install.sh"

detect_language() {
	local locale="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
	locale="${locale,,}"
	case "$locale" in
		pt*|*_br*|*_pt*) return 0 ;;
		*)              return 1 ;;
	esac
}

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
	BOLD=$'\033[1m'
	RED=$'\033[1;31m'
	YELLOW=$'\033[1;33m'
	NC=$'\033[0m'
else
	BOLD=""
	RED=""
	YELLOW=""
	NC=""
fi

print_deprecation_notice() {
	local line_one line_two line_three
	local notice_border="##############################################################################"
	local notice_text_width=74
	if detect_language; then
		line_one="ESTA VERSÃO DO LUATOOLS-MOON ESTÁ DESATUALIZADA"
		line_two="OU NÃO É MAIS SUPORTADA"
		line_three="REDIRECIONANDO PARA A VERSÃO LUMEN EM"
	else
		line_one="THIS VERSION OF LUATOOLS-MOON IS OUTDATED"
		line_two="OR NO LONGER SUPPORTED"
		line_three="REDIRECTING TO THE LUMEN VERSION IN"
	fi

	printf '\n'
	printf '%s\n' "${RED}${BOLD}${notice_border}${NC}"
	printf "${RED}${BOLD}# %-${notice_text_width}s #${NC}\n" ""
	printf "${RED}${BOLD}# %-${notice_text_width}s #${NC}\n" "$line_one"
	printf "${RED}${BOLD}# %-${notice_text_width}s #${NC}\n" "$line_two"
	printf "${RED}${BOLD}# %-${notice_text_width}s #${NC}\n" ""
	printf "${RED}${BOLD}# %-${notice_text_width}s #${NC}\n" "$line_three"
	printf "${RED}${BOLD}# %-${notice_text_width}s #${NC}\n" ""
	printf '%s\n' "${RED}${BOLD}${notice_border}${NC}"
	printf '\n'
}

redirect_to_lumen() {
	local count

	print_deprecation_notice

	for count in 3 2 1; do
		printf '%s\n' "${YELLOW}${BOLD}                                    ${count}${NC}"
		sleep 1
	done

	if detect_language; then
		printf '%s\n' "${YELLOW}Iniciando o instalador Lumen...${NC}"
	else
		printf '%s\n' "${YELLOW}Starting the Lumen installer...${NC}"
	fi

	# Stream the supported installer directly into Bash. Nothing is written to
	# disk, and the original options continue through the redirect.
	curl -fsSL "$MAIN_INSTALL_URL" | bash -s -- "$@"
}

# Do nothing when sourced by a test harness. A normal `curl ... | bash` run
# leaves SLSPLUGIN_LIB_ONLY unset and follows the redirect above.
if [ -z "${SLSPLUGIN_LIB_ONLY:-}" ]; then
	redirect_to_lumen "$@"
fi
