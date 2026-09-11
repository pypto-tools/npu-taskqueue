#!/usr/bin/env bash
# Show or export paths to shared pypto development components.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: pypto-setup [--export]

Show configured shared pypto component paths and whether they exist.

  --export     Print shell export statements for use with:
                 eval "$(pypto-setup --export)"
  -h, --help   Show this help

Configuration precedence (highest first): existing environment variables,
$PYPTO_ENV_CONF, ~/.config/pypto-env.conf, the installed pto-task config,
legacy /etc/pypto-env.conf, and built-in defaults.
EOF
}

mode=show
case "${1:-}" in
    --export) mode=export ;;
    -h|--help) usage; exit 0 ;;
    "") ;;
    *)
        printf 'error: unknown option: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
esac
[[ $# -le 1 ]] || {
    echo 'error: pypto-setup accepts only one option' >&2
    usage >&2
    exit 2
}

script_path="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || true)"
[[ -n "$script_path" ]] || script_path="${BASH_SOURCE[0]}"
script_dir="$(cd "$(dirname "$script_path")" && pwd)"

# A process can only see exported values from its parent. Preserve every
# non-empty value across config loading so the documented environment-first
# precedence does not depend on how an administrator wrote the config file.
variables=(PTOAS_ROOT ASCEND_HOME_PATH GCC15_ROOT CLANG_FORMAT MODELS_ROOT)
declare -A environment_values=()
for variable in "${variables[@]}"; do
    [[ -n "${!variable:-}" ]] || continue
    environment_values["$variable"]="${!variable}"
done

config_used=""
config_candidates=(
    "${PYPTO_ENV_CONF:-}"
    "${HOME:+$HOME/.config/pypto-env.conf}"
    "$script_dir/../config/pypto-env.conf"
    "/etc/pypto-env.conf"
    "$script_dir/config/pypto-env.conf"
)
for config in "${config_candidates[@]}"; do
    [[ -n "$config" && -f "$config" ]] || continue
    # pypto-env.conf is shell assignment syntax, matching taskqueue.conf.
    # shellcheck disable=SC1090
    source "$config"
    config_used="$config"
    break
done

for variable in "${!environment_values[@]}"; do
    printf -v "$variable" '%s' "${environment_values[$variable]}"
done

# Portable host defaults. Optional GCC is deliberately left unset: a shared
# compiler is not part of every pto-task deployment.
PTOAS_ROOT="${PTOAS_ROOT:-/usr/local/bin/ptoas-bin}"
ASCEND_HOME_PATH="${ASCEND_HOME_PATH:-/usr/local/Ascend/cann}"
GCC15_ROOT="${GCC15_ROOT:-}"
CLANG_FORMAT="${CLANG_FORMAT:-/usr/local/bin/clang-format}"
MODELS_ROOT="${MODELS_ROOT:-/data/models}"

if [[ "$mode" == export ]]; then
    for variable in "${variables[@]}"; do
        printf 'export %s=%q\n' "$variable" "${!variable}"
    done

    path_prefix="$PTOAS_ROOT"
    [[ -z "$GCC15_ROOT" ]] || path_prefix+="${path_prefix:+:}$GCC15_ROOT/bin"
    [[ -z "$path_prefix" ]] || printf 'export PATH=%q"${PATH}"\n' "$path_prefix:"
    exit 0
fi

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    green=$'\033[32m'; red=$'\033[31m'; dim=$'\033[2m'; reset=$'\033[0m'
else
    green=""; red=""; dim=""; reset=""
fi

print_path() {
    local name="$1" path="$2" description="$3" mark shown
    if [[ -z "$path" ]]; then
        mark="${dim}[not set]${reset}"
        shown='(set it in the environment or ~/.config/pypto-env.conf)'
    elif [[ -e "$path" ]]; then
        mark="${green}[OK]${reset}"
        shown="$path"
    else
        mark="${red}[missing]${reset}"
        shown="$path"
    fi
    printf '  %-18s %-10b %s\n' "$name" "$mark" "$shown"
    [[ -z "$description" ]] || printf '  %-18s %b%s%b\n' '' "$dim" "$description" "$reset"
}

echo '=== Shared pypto component paths ==='
if [[ -n "$config_used" ]]; then
    printf '  %b(config: %s; exported environment variables take precedence)%b\n' \
        "$dim" "$config_used" "$reset"
fi
echo
print_path PTOAS_ROOT "$PTOAS_ROOT" 'PTO bytecode assembler/optimizer'
print_path ASCEND_HOME_PATH "$ASCEND_HOME_PATH" 'CANN / Ascend toolkit'
print_path GCC15_ROOT "$GCC15_ROOT" 'optional shared GCC 15 toolchain'
print_path CLANG_FORMAT "$CLANG_FORMAT" 'shared C/C++ formatter'
print_path MODELS_ROOT "$MODELS_ROOT" 'shared model and weight directory'

echo
echo 'Load these variables into the current shell:'
echo '  eval "$(pypto-setup --export)"'
