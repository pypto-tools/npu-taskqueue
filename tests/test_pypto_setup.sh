#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/home/.config" "$TEST_ROOT/ptoas root" \
    "$TEST_ROOT/cann" "$TEST_ROOT/gcc/bin" "$TEST_ROOT/models"
touch "$TEST_ROOT/clang format"
clean_env=(env -u PTOAS_ROOT -u ASCEND_HOME_PATH -u GCC15_ROOT \
    -u CLANG_FORMAT -u MODELS_ROOT)

config="$TEST_ROOT/explicit.conf"
cat > "$config" <<EOF
PTOAS_ROOT="$TEST_ROOT/ptoas root"
ASCEND_HOME_PATH="$TEST_ROOT/cann"
GCC15_ROOT="$TEST_ROOT/gcc"
CLANG_FORMAT="$TEST_ROOT/clang format"
MODELS_ROOT="$TEST_ROOT/models"
EOF

export_output="$("${clean_env[@]}" HOME="$TEST_ROOT/home" PYPTO_ENV_CONF="$config" \
    "$REPO_DIR/pypto-setup.sh" --export)"
(
    PATH=/usr/bin
    eval "$export_output"
    [[ "$PTOAS_ROOT" == "$TEST_ROOT/ptoas root" ]]
    [[ "$ASCEND_HOME_PATH" == "$TEST_ROOT/cann" ]]
    [[ "$GCC15_ROOT" == "$TEST_ROOT/gcc" ]]
    [[ "$CLANG_FORMAT" == "$TEST_ROOT/clang format" ]]
    [[ "$MODELS_ROOT" == "$TEST_ROOT/models" ]]
    [[ "$PATH" == "$TEST_ROOT/ptoas root:$TEST_ROOT/gcc/bin:/usr/bin" ]]
)

# Existing exported values have higher priority than assignments in the file.
override_output="$("${clean_env[@]}" PTOAS_ROOT="$TEST_ROOT/environment ptoas" \
    HOME="$TEST_ROOT/home" PYPTO_ENV_CONF="$config" \
    "$REPO_DIR/pypto-setup.sh" --export)"
grep -Fq "PTOAS_ROOT=$TEST_ROOT/environment\\ ptoas" <<< "$override_output"

show_output="$("${clean_env[@]}" NO_COLOR=1 HOME="$TEST_ROOT/home" PYPTO_ENV_CONF="$config" \
    "$REPO_DIR/pypto-setup.sh")"
grep -Fq "config: $config" <<< "$show_output"
grep -Fq 'PTOAS_ROOT         [OK]' <<< "$show_output"

# An optional GCC is unset by default and must not add /bin to PATH.
no_gcc_config="$TEST_ROOT/no-gcc.conf"
cat > "$no_gcc_config" <<EOF
PTOAS_ROOT="$TEST_ROOT/ptoas root"
ASCEND_HOME_PATH="$TEST_ROOT/cann"
GCC15_ROOT=
CLANG_FORMAT="$TEST_ROOT/clang format"
MODELS_ROOT="$TEST_ROOT/models"
EOF
no_gcc_output="$("${clean_env[@]}" HOME="$TEST_ROOT/home" PYPTO_ENV_CONF="$no_gcc_config" \
    "$REPO_DIR/pypto-setup.sh" --export)"
(
    PATH=/usr/bin
    eval "$no_gcc_output"
    [[ -z "$GCC15_ROOT" ]]
    [[ "$PATH" == "$TEST_ROOT/ptoas root:/usr/bin" ]]
)

if "$REPO_DIR/pypto-setup.sh" --unknown >/dev/null 2>&1; then
    echo 'error: unknown pypto-setup option was accepted' >&2
    exit 1
fi
"$REPO_DIR/pypto-setup.sh" --help | grep -Fq 'eval "$(pypto-setup --export)"'

echo 'pypto-setup tests passed'
