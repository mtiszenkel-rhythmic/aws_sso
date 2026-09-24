#!/usr/bin/env bash
# Installer for aws_sso: the script itself, the shell wrapper that lets
# `aws_sso export` set variables in the calling shell, and tab completion.
#
#   ./install.sh              install for your login shell
#   ./install.sh --dry-run    show what would change, touch nothing
#   ./install.sh --help       full usage
#
# Deliberately written for bash 3.2 so it runs on a stock macOS /bin/bash.

set -euo pipefail

SRC_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

USER_BIN_DIR="$HOME/.local/bin"
SYSTEM_BIN_DIR="/usr/local/bin"
BIN_DIR="$USER_BIN_DIR"
ZSH_SITE_FUNCTIONS="$HOME/.local/share/zsh/site-functions"
BASH_COMPLETION_DIR="$HOME/.local/share/bash-completion/completions"

BEGIN_MARK='# >>> aws_sso >>>'
END_MARK='# <<< aws_sso <<<'
FPATH_MARK='# added by the aws_sso installer'
PATH_MARK='# added by the aws_sso installer (PATH)'
COMPLETION_MARK='# added by the aws_sso installer (completion)'

DRY_RUN=0
FORCE=0
ASSUME_YES=0
# -1 until decided: --system / --user, else the prompt in choose_install_dir
SYSTEM_WIDE=-1
# -1 until decided: --hide-plumbing / --show-plumbing, else asked
HIDE_PLUMBING=-1
# `sudo` once we are writing outside $HOME
PRIV=""
TARGET_SHELL=""
TS=$(date +%Y%m%d-%H%M%S)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/aws_sso-install.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# Things worth repeating once the wall of progress output has scrolled past.
NOTES=""

# Destinations declined because they resolved back into this checkout.
REFUSED=0

# ---------------------------------------------------------------- output ---

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$(printf '\033[0m'); C_DIM=$(printf '\033[2m')
  C_BOLD=$(printf '\033[1m'); C_YELLOW=$(printf '\033[33m')
  C_RED=$(printf '\033[31m'); C_GREEN=$(printf '\033[32m')
else
  C_RESET=""; C_DIM=""; C_BOLD=""; C_YELLOW=""; C_RED=""; C_GREEN=""
fi

info() { printf '%s\n' "  $*"; }
step() { printf '%s\n' "${C_BOLD}$*${C_RESET}"; }
skip() { printf '%s\n' "  ${C_DIM}$*${C_RESET}"; }
ok()   { printf '%s\n' "  ${C_GREEN}$*${C_RESET}"; }
warn() { printf '%s\n' "${C_YELLOW}warning:${C_RESET} $*" >&2; }
die()  { printf '%s\n' "${C_RED}error:${C_RESET} $*" >&2; exit 1; }

note() { NOTES="$NOTES$1
"; }

# True if there is a controlling terminal to ask questions on.
#
# Deliberately not `[ -t 0 ]`: by the time we run, stdin may have been consumed
# or redirected by whatever invoked us -- a setup script that ran `brew` first,
# or a `curl ... | bash` -- while the terminal itself is still right there. A
# prompt read from an exhausted stdin answers itself with the default, which is
# how this went wrong before.
have_tty() { { : >/dev/tty; } 2>/dev/null; }

# Asks $1 on the terminal; the answer lands in $ANSWER. Returns 1 when nobody
# answered -- no terminal, or the read hit end-of-file -- as opposed to
# answering with an empty line, which returns 0 and means "take the default".
#
# That distinction matters: swallowing EOF and calling it the default is how an
# unanswered question ends up deciding to install system-wide on its own.
ask_tty() {
  ANSWER=""
  have_tty || return 1
  printf '%s' "$1" > /dev/tty
  if ! IFS= read -r ANSWER < /dev/tty; then
    ANSWER=""
    printf '\n' > /dev/tty   # nothing was echoed, so close the prompt line
    return 1
  fi
  return 0
}

# $HOME -> ~ so paths stay readable in the log.
tilde() { case "$1" in "$HOME"/*) printf '~%s\n' "${1#$HOME}" ;; *) printf '%s\n' "$1" ;; esac; }

usage() {
  cat <<USAGE
Usage: ./install.sh [options]

Installs:
  * aws_sso, in $SYSTEM_BIN_DIR (system-wide, the default) or
    $(tilde "$USER_BIN_DIR") (just you)
  * a shell function wrapping it, so 'aws_sso export' can set variables in
    the calling shell
  * tab completion

A system-wide install also puts $SYSTEM_BIN_DIR and Homebrew on the PATH
launchd gives GUI applications, so they can run aws_sso too -- which is what
a credential_process in ~/.aws/config needs. It requires sudo.

Where the function and completion go depends on your login shell and on
whether oh-my-zsh / oh-my-bash is installed; run with --dry-run to see.

Options:
  -n, --dry-run        report what would change without changing anything
      --system         install to $SYSTEM_BIN_DIR without asking (needs sudo)
      --user           install to $(tilde "$USER_BIN_DIR") without asking
      --hide-plumbing  set AWS_SSO_NO_PLUMBING_PROFILES=1 without asking
      --show-plumbing  leave completion listing every profile
  -s, --shell SHELL    install for SHELL (zsh or bash) instead of the
                       detected login shell
  -f, --force          write into a plugin directory even if it is a symlink
  -y, --yes            install missing dependencies with Homebrew without asking
  -h, --help           this message

Existing files are backed up as <file>.aws_sso-<timestamp>.bak before being
edited. Re-running the installer is safe; it updates in place.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    --system) SYSTEM_WIDE=1 ;;
    --user) SYSTEM_WIDE=0 ;;
    --hide-plumbing) HIDE_PLUMBING=1 ;;
    --show-plumbing) HIDE_PLUMBING=0 ;;
    -f|--force) FORCE=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    -s|--shell)
      [ $# -ge 2 ] || die "--shell needs an argument (zsh or bash)"
      TARGET_SHELL=$2; shift
      ;;
    --shell=*) TARGET_SHELL=${1#*=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

case "$TARGET_SHELL" in
  ""|zsh|bash) ;;
  *) die "--shell must be zsh or bash, not '$TARGET_SHELL'" ;;
esac

# ------------------------------------------------------------ file edits ---

_backed_up=" "

backup_file() {
  local f=$1 priv=${2:-}
  case "$_backed_up" in *" $f "*) return 0 ;; esac
  _backed_up="$_backed_up$f "
  [ -f "$f" ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    info "would back up $(tilde "$f")"
    return 0
  fi
  # shellcheck disable=SC2086
  $priv cp -p "$f" "$f.aws_sso-$TS.bak"
  info "backed up   $(tilde "$f") -> $(tilde "$f.aws_sso-$TS.bak")"
}

_made_dirs=" "

ensure_dir() {
  local d=$1 priv=${2:-}
  [ -d "$d" ] && return 0
  case "$_made_dirs" in *" $d "*) return 0 ;; esac
  _made_dirs="$_made_dirs$d "
  if [ "$DRY_RUN" -eq 1 ]; then
    info "would create $(tilde "$d")/"
    return 0
  fi
  # shellcheck disable=SC2086
  $priv mkdir -p "$d"
  info "created     $(tilde "$d")/"
}

# Where $1 ends up once symlinks are followed. Components that do not exist
# yet cannot be symlinks, so resolving the nearest existing ancestor and
# re-appending the rest is enough, and works for a destination we are about
# to create.
resolve_path() {
  local path=$1 rest="" parent
  while :; do
    if [ -d "$path" ]; then
      ( cd -- "$path" 2>/dev/null && printf '%s%s\n' "$(pwd -P)" "$rest" ) && return 0
      break
    fi
    parent=$(dirname -- "$path")
    rest="/$(basename -- "$path")$rest"
    [ "$parent" = "$path" ] && break
    path=$parent
  done
  printf '%s\n' "$1"
}

# True if path $1 is $2 or lies under it.
path_within() {
  case "$1" in
    "$2"|"$2"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Copies a packaged file into place, leaving it alone if it is already
# identical.
install_file() {
  local src=$1 dest=$2 mode=${3:-644} priv=${4:-} real
  # A plugin directory symlinked to this checkout would have us copy the
  # package onto itself, and drop files where the repository does not keep
  # them. Nothing is gained by writing into the source, so don't.
  real=$(resolve_path "$dest")
  if path_within "$real" "$SRC_DIR"; then
    warn "$(tilde "$dest") resolves back into this checkout, as $(tilde "$real")."
    warn "Refusing to install a file onto its own source."
    REFUSED=$((REFUSED + 1))
    return 0
  fi
  ensure_dir "$(dirname "$dest")" "$priv"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    skip "unchanged   $(tilde "$dest")"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    info "would install $(tilde "$dest")${priv:+ (with $priv)}"
    return 0
  fi
  [ -e "$dest" ] && backup_file "$dest" "$priv"
  # shellcheck disable=SC2086
  $priv install -m "$mode" "$src" "$dest"
  ok "installed   $(tilde "$dest")"
}

# Replaces $1 with the staged contents of $2, or reports that nothing
# changed. Returns 0 if the file was (or would be) modified.
replace_file() {
  local file=$1 staged=$2
  if [ -f "$file" ] && cmp -s "$staged" "$file"; then
    return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    info "would edit  $(tilde "$file")"
    if command -v diff >/dev/null 2>&1; then
      diff -u "$file" "$staged" 2>/dev/null | tail -n +3 |
        sed "s/^/    ${C_DIM}|${C_RESET} /" || true
    fi
    return 0
  fi
  backup_file "$file"
  cat "$staged" > "$file"
  ok "edited      $(tilde "$file")"
  return 0
}

touch_rc() {
  local file=$1
  [ -f "$file" ] && return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    info "would create $(tilde "$file")"
    return 0
  fi
  : > "$file"
  ok "created     $(tilde "$file")"
}

# ------------------------------------------------- shell array maintenance --

# Reports whether $file has an uncommented `$name=( ... )` array and whether
# $value is one of its entries: prints present | absent | missing.
array_state() {
  local file=$1 name=$2 value=$3 rc=0
  [ -f "$file" ] || { echo missing; return 0; }
  set +e
  awk -v name="$name" -v value="$value" '
    BEGIN {
      openre = "^[[:blank:]]*" name "=\\("
      wordre = "(^|[^A-Za-z0-9_-])" value "([^A-Za-z0-9_-]|$)"
      state = 0; text = ""
    }
    {
      if (state == 0 && $0 ~ openre) state = 1
      if (state == 1) {
        text = text "\n" $0
        if (index($0, ")") > 0) state = 2
      }
    }
    END {
      if (state == 0) exit 3
      if (text ~ wordre) exit 0
      exit 1
    }
  ' "$file"
  rc=$?
  set -e
  case "$rc" in
    0) echo present ;;
    1) echo absent ;;
    3) echo missing ;;
    *) echo error ;;
  esac
}

# Adds $value to the existing `$name=( ... )` array in $file, handling both
# the one-line and the one-entry-per-line spellings.
array_insert() {
  local file=$1 name=$2 value=$3
  local staged="$TMP_ROOT/array.$$"
  local src=$file; [ -f "$src" ] || src=/dev/null
  awk -v name="$name" -v value="$value" '
    function emit(   i, line, pre, post, p, indent, tmpl) {
      line = buf[n]
      p = 0
      for (i = length(line); i >= 1; i--)
        if (substr(line, i, 1) == ")") { p = i; break }
      pre  = substr(line, 1, p - 1)
      post = substr(line, p)

      for (i = 1; i < n; i++) print buf[i]

      if (pre ~ /[^[:blank:]]/) {
        # entries share the line with the closing paren
        sub(/[[:blank:]]+$/, "", pre)
        if (pre ~ /\($/) print pre value post
        else             print pre " " value post
      } else {
        # the closing paren sits on its own line; match how the entry above
        # it is indented, falling back to two spaces
        indent = ""
        if (n > 1) {
          tmpl = buf[n - 1]
          if (match(tmpl, /^[[:blank:]]+/)) indent = substr(tmpl, 1, RLENGTH)
        }
        if (indent == "") indent = pre "  "
        print indent value
        print line
      }
    }
    BEGIN { openre = "^[[:blank:]]*" name "=\\("; state = 0; n = 0 }
    {
      if (state == 0 && $0 ~ openre) state = 1
      if (state == 1) {
        buf[++n] = $0
        if (index($0, ")") > 0) { emit(); state = 2 }
        next
      }
      print
    }
    END { if (state == 1) for (i = 1; i <= n; i++) print buf[i] }
  ' "$src" > "$staged"
  replace_file "$file" "$staged" || skip "unchanged   $(tilde "$file")"
}

# Creates `$name=($value)` in $file, just above the line matching $anchor so
# it lands before the framework that reads it. Appended if there is no anchor.
array_create() {
  local file=$1 name=$2 value=$3 anchor=$4
  local staged="$TMP_ROOT/array_new.$$"
  local src=$file; [ -f "$src" ] || src=/dev/null
  awk -v name="$name" -v value="$value" -v anchor="$anchor" '
    BEGIN { done = 0 }
    !done && anchor != "" && $0 ~ anchor && $0 !~ /^[[:blank:]]*#/ {
      print name "=(" value ")"
      print ""
      done = 1
    }
    { print }
    END { if (!done) { print ""; print name "=(" value ")" } }
  ' "$src" > "$staged"
  replace_file "$file" "$staged" || skip "unchanged   $(tilde "$file")"
}

# Adds $value to $name=( ... ) in $file, creating the array if need be.
array_add() {
  local file=$1 name=$2 value=$3 anchor=${4:-}
  case "$(array_state "$file" "$name" "$value")" in
    present) skip "already in  $name=( ... ) in $(tilde "$file")" ;;
    absent)  array_insert "$file" "$name" "$value" ;;
    missing) array_create "$file" "$name" "$value" "$anchor" ;;
    *)       warn "could not read $(tilde "$file"); add '$value' to $name=( ... ) yourself" ;;
  esac
}

# ------------------------------------------------- managed rc-file blocks ---

# Writes $content_file into $file between the marker comments, replacing an
# existing block so that re-running the installer upgrades it.
ensure_block() {
  local file=$1 content_file=$2
  local staged="$TMP_ROOT/block.$$"
  local src=$file; [ -f "$src" ] || src=/dev/null

  awk -v begin="$BEGIN_MARK" -v end="$END_MARK" -v content="$content_file" '
    function put_block(   line) {
      print begin
      print "# Managed by the aws_sso installer; edits here are overwritten."
      while ((getline line < content) > 0) print line
      close(content)
      print end
    }
    BEGIN { skipping = 0; seen = 0 }
    $0 == begin { skipping = 1; seen = 1; put_block(); next }
    $0 == end   { skipping = 0; next }
    !skipping { print }
    END { if (!seen) { print ""; put_block() } }
  ' "$src" > "$staged"

  replace_file "$file" "$staged" || skip "unchanged   $(tilde "$file")"
}

# ------------------------------------------------------------- detection ---

login_shell() {
  local shell=""
  if [ "$(uname -s)" = Darwin ] && command -v dscl >/dev/null 2>&1; then
    shell=$(dscl . -read "/Users/$(id -un)" UserShell 2>/dev/null | awk '{print $2}')
  fi
  if [ -z "$shell" ] && command -v getent >/dev/null 2>&1; then
    shell=$(getent passwd "$(id -un)" 2>/dev/null | awk -F: '{print $7}')
  fi
  [ -z "$shell" ] && shell=${SHELL:-}
  printf '%s\n' "${shell##*/}"
}

# Reads an uncommented `NAME=value` (with or without `export`) out of an rc
# file and expands it, so that a framework installed somewhere other than the
# default is still found. Command substitution is refused rather than run.
rc_var() {
  local file=$1 name=$2 line value
  [ -f "$file" ] || return 1
  line=$(grep -E "^[[:blank:]]*(export[[:blank:]]+)?$name=" "$file" 2>/dev/null | tail -n 1) || return 1
  [ -n "$line" ] || return 1
  value=${line#*=}
  value=${value%%#*}
  case "$value" in *'$('*|*'`'*) return 1 ;; esac
  eval "printf '%s\n' $value" 2>/dev/null || return 1
}

# ----------------------------------------------------------- the script ----

# Picks between $SYSTEM_BIN_DIR and $USER_BIN_DIR, and sets BIN_DIR and PRIV.
#
# System-wide is the default because it is the only one GUI applications can
# use. They are started with launchd's PATH, which has neither ~/.local/bin nor
# Homebrew on it, so a credential_process naming a bare `aws_sso` resolves only
# for programs started from a shell.
# What to install when the question went unanswered. sudo is the deciding
# factor: if it would stop for a password there is nobody to type it, so a
# system-wide install would hang exactly where the prompt just did.
choose_install_dir_unattended() {
  if sudo -n true 2>/dev/null; then
    SYSTEM_WIDE=1
    info "nothing answered that; installing system-wide, since sudo needs no password here"
  else
    SYSTEM_WIDE=0
    note "Installed for your user only: nothing answered the system-wide
    question, and sudo would have stopped for a password. Pass --system or
    --user to choose without being asked."
  fi
}

choose_install_dir() {

  if [ "$SYSTEM_WIDE" -lt 0 ]; then
    if [ "$ASSUME_YES" -eq 1 ]; then
      SYSTEM_WIDE=1
    elif have_tty; then
      step "install location"
      info "Installing to $SYSTEM_BIN_DIR lets GUI applications run aws_sso, which"
      info "is what a credential_process in ~/.aws/config needs -- they are started"
      info "with launchd's PATH, and $(tilde "$USER_BIN_DIR") is not on it."
      info "This needs sudo. Answering no installs to $(tilde "$USER_BIN_DIR") instead."
      if ask_tty "  Install system-wide? [Y/n] "; then
        case "$ANSWER" in
          [nN]|[nN][oO]) SYSTEM_WIDE=0 ;;
          *) SYSTEM_WIDE=1 ;;
        esac
      else
        choose_install_dir_unattended
      fi
    else
      choose_install_dir_unattended
    fi
  fi

  if [ "$SYSTEM_WIDE" -eq 1 ]; then
    BIN_DIR=$SYSTEM_BIN_DIR
    PRIV=sudo
  else
    BIN_DIR=$USER_BIN_DIR
    PRIV=""
  fi
}

# Whether completion should leave out plumbing profiles -- the ones that exist
# only to be reached through another -- by exporting
# AWS_SSO_NO_PLUMBING_PROFILES=1.
#
# Unanswered means yes here, unlike the install location: this writes one line
# to a shell rc file that the installer is editing anyway, nothing can hang on
# it, and removing the line undoes it completely.
choose_hide_plumbing() {
  [ "$HIDE_PLUMBING" -ge 0 ] && return 0

  if [ "$ASSUME_YES" -eq 1 ]; then
    HIDE_PLUMBING=1
    return 0
  fi

  if ! have_tty; then
    HIDE_PLUMBING=1
    return 0
  fi

  step "completion"
  info "Some profiles exist only to be reached through another: those named as"
  info "a source_profile, and those named by a credential_process line."
  info "Completion can leave both out and offer only the profiles you would"
  info "actually set AWS_PROFILE to."
  if ask_tty "  Hide them from completion? [Y/n] "; then
    case "$ANSWER" in
      [nN]|[nN][oO]) HIDE_PLUMBING=0 ;;
      *) HIDE_PLUMBING=1 ;;
    esac
  else
    HIDE_PLUMBING=1
    info "nothing answered that; taking the default and hiding them"
  fi

  [ "$HIDE_PLUMBING" -eq 0 ] && note "Completion will keep listing every profile. To hide just one kind, put
    either of these in your shell rc file yourself:
        export AWS_SSO_NO_SOURCE_PROFILES=1      # only ones used as a source_profile
        export AWS_SSO_NO_CRED_PROC_PROFILES=1   # only ones named by a credential_process
    AWS_SSO_NO_PLUMBING_PROFILES=1 is the two together, which is what this
    installer offers."

  return 0
}

# Exports AWS_SSO_NO_PLUMBING_PROFILES=1 from the shell rc file, which is where
# the completion reads it from.
ensure_no_plumbing_profiles() {
  local file=$1
  local staged="$TMP_ROOT/noplumb.$$"
  local src=$file

  if [ -f "$file" ] && grep -Eq '^[^#]*AWS_SSO_NO_PLUMBING_PROFILES=' "$file"; then
    skip "already set  AWS_SSO_NO_PLUMBING_PROFILES in $(tilde "$file")"
    return 0
  fi

  [ -f "$src" ] || src=/dev/null
  { cat "$src"
    printf '\n%s\nexport AWS_SSO_NO_PLUMBING_PROFILES=1\n' "$COMPLETION_MARK"
  } > "$staged"
  replace_file "$file" "$staged" || skip "unchanged   $(tilde "$file")"
}

install_script() {
  step "aws_sso script"
  install_file "$SRC_DIR/bin/aws_sso" "$BIN_DIR/aws_sso" 755 "$PRIV"
  # $BIN_DIR is put on PATH by install_zsh / install_bash, which know which
  # startup file to write to.
}

# The Homebrew formula that provides a given command, where the two differ.
brew_formula() {
  case "$1" in
    aws) printf '%s\n' awscli ;;
    *)   printf '%s\n' "$1" ;;
  esac
}

# Homebrew is not necessarily on PATH — a fresh Apple-silicon install is not,
# until the user's rc file runs `brew shellenv`.
find_brew() {
  local candidate
  if command -v brew >/dev/null 2>&1; then
    command -v brew
    return 0
  fi
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew \
                   "${HOMEBREW_PREFIX:-}/bin/brew" \
                   /home/linuxbrew/.linuxbrew/bin/brew; do
    case "$candidate" in /bin/brew) continue ;; esac
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

check_dependencies() {
  local missing="" formulae="" tool brew brew_show reply

  for tool in aws jq curl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing="$missing $tool"
      formulae="$formulae $(brew_formula "$tool")"
    fi
  done
  [ -n "$missing" ] || return 0

  step "dependencies"
  info "aws_sso needs these, which are not installed:$missing"

  brew=$(find_brew) || brew=""
  # what to print: plain `brew` if it is on PATH, the full path if it is not
  brew_show=$brew
  command -v brew >/dev/null 2>&1 && brew_show=brew

  if [ -z "$brew" ]; then
    note "Install aws_sso's missing dependencies:$missing"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    info "would offer to run: $brew_show install$formulae"
    return 0
  fi

  if [ "$ASSUME_YES" -eq 0 ]; then
    if ! ask_tty "  Install with Homebrew now ($brew_show install$formulae)? [y/N] "; then
      note "Install them with:
    $brew_show install$formulae"
      return 0
    fi
    reply=$ANSWER
    case "$reply" in
      [yY]|[yY][eE][sS]) ;;
      *)
        note "Install them later with:
    $brew_show install$formulae"
        return 0
        ;;
    esac
  fi

  # shellcheck disable=SC2086
  if ! "$brew" install $formulae; then
    warn "'$brew_show install$formulae' failed."
    note "Install the missing dependencies before using aws_sso:$missing"
    return 0
  fi

  hash -r 2>/dev/null || true

  local still=""
  for tool in $missing; do
    command -v "$tool" >/dev/null 2>&1 || still="$still $tool"
  done
  if [ -n "$still" ]; then
    note "Installed, but still not on your PATH:$still
    Check that Homebrew's bin directory comes before the system one."
  else
    ok "installed  $missing"
  fi
  return 0
}

# Adds each ':'-separated entry of $2 to the PATH-like value $1, skipping any
# already there, and prints the result. Appending blindly would make the value
# grow every time the installer runs.
path_append() {
  local value=$1 additions=$2 rest entry
  rest=$additions
  while [ -n "$rest" ]; do
    entry=${rest%%:*}
    case "$rest" in *:*) rest=${rest#*:} ;; *) rest="" ;; esac
    [ -n "$entry" ] || continue
    case ":$value:" in
      *":$entry:"*) ;;
      *) if [ -n "$value" ]; then value="$value:$entry"; else value=$entry; fi ;;
    esac
  done
  printf '%s\n' "$value"
}

# Puts $SYSTEM_BIN_DIR and Homebrew on the PATH launchd hands to GUI
# applications, so a credential_process naming a bare `aws_sso` resolves for
# them too -- otherwise they get /usr/bin:/bin:/usr/sbin:/sbin and nothing else.
#
# Both spellings are set on purpose: `setenv` applies to applications launched
# between now and the next reboot, `config user path` is the persistent one and
# only takes effect after one. Together they cover both sides of that restart.
configure_launchd_path() {
  [ "$(uname -s)" = Darwin ] || return 0
  command -v launchctl >/dev/null 2>&1 || return 0

  step "launchd PATH (what GUI applications get)"

  local current wanted new brew brew_prefix aws_dir
  current=$(launchctl getenv PATH 2>/dev/null) || current=""

  # $SYSTEM_BIN_DIR is where aws_sso itself goes. The rest is for the `aws` it
  # shells out to, which a GUI application has to be able to find as well.
  wanted=$SYSTEM_BIN_DIR

  brew=$(find_brew) || brew=""
  if [ -n "$brew" ]; then
    brew_prefix=$("$brew" --prefix 2>/dev/null) || brew_prefix=""
    [ -n "$brew_prefix" ] && wanted="$wanted:$brew_prefix/bin"
  fi

  # Then wherever aws actually is, which is not necessarily either of those:
  # the AWS installer package uses /usr/local/bin, and people relocate things.
  # Homebrew's bin is still added above whether or not aws sits in it, since
  # that is where jq and curl come from.
  aws_dir=$(find_aws_dir) || aws_dir=""
  if [ -n "$aws_dir" ]; then
    case ":$wanted:" in
      *":$aws_dir:"*) ;;
      *)
        wanted="$wanted:$aws_dir"
        info "aws lives in $aws_dir, outside the directories above; adding it"
        ;;
    esac
  fi

  if [ "$wanted" = "$SYSTEM_BIN_DIR" ]; then
    note "Neither Homebrew nor the aws CLI was found, so only $SYSTEM_BIN_DIR
    was added to the PATH GUI applications get. Install the AWS CLI, then
    re-run this installer so its directory is added too."
  fi

  # With nothing set, launchd hands out the compiled-in default; start from
  # that rather than from an empty value, or GUI apps lose /usr/bin.
  if [ -z "$current" ]; then
    new=$(path_append "/usr/bin:/bin:/usr/sbin:/sbin" "$wanted")
  else
    new=$(path_append "$current" "$wanted")
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$new" = "$current" ]; then
      skip "unchanged   launchctl PATH is already $new"
    else
      info "would run   launchctl setenv PATH $new"
    fi
    info "would run   sudo launchctl config user path $new"
    return 0
  fi

  if [ "$new" = "$current" ]; then
    skip "unchanged   launchctl PATH"
  elif launchctl setenv PATH "$new"; then
    ok "set         launchctl PATH (applications started from now on)"
  else
    warn "launchctl setenv PATH failed; GUI applications may not find aws_sso."
  fi

  # Persistent, and read at boot -- so it is worth writing even when the live
  # value already matches, since the two are stored separately.
  if sudo launchctl config user path "$new" >/dev/null 2>&1; then
    ok "set         launchd user path (persists; applies after a reboot)"
  else
    warn "sudo launchctl config user path failed; the PATH above will be lost on reboot."
  fi

  note "Applications that were already running keep the PATH they started with.
    Quit and reopen anything that needs aws_sso (or log out and back in)."
}

# Makes sure the directory aws_sso went into is on the PATH of interactive
# shells, by adding a line to $1. Nothing is written when it is already there
# -- on macOS /usr/local/bin is in /etc/paths, so a system-wide install usually
# needs no line at all.
#
# Appended rather than prepended, deliberately. aws_sso should not be anywhere
# else, and if a copy is, it was put there on purpose and ought to keep
# winning. Appending also means this line cannot quietly shadow a tool the
# shell already resolves somewhere else.
# The directory holding the aws CLI: from PATH when it is there, otherwise the
# usual install locations -- the same list aws_sso itself searches at runtime,
# so the two agree about where aws might be. Prints nothing if it is nowhere.
find_aws_dir() {
  local bin dir
  bin=$(command -v aws 2>/dev/null) || bin=""
  case "$bin" in
    /*)
      dirname "$bin"
      return 0
      ;;
  esac
  for dir in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" /opt/local/bin; do
    if [ -x "$dir/aws" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  return 1
}

# True if an uncommented PATH= line in $1 already mentions directory $2, in any
# of the spellings people write for a path under their home directory. $3 is
# the part after $HOME, empty when the directory is not under it.
path_line_mentions() {
  local file=$1 dir=$2 rest=$3
  local lines
  lines=$(grep -v '^[[:blank:]]*#' "$file" | grep -F 'PATH=') || return 1

  if [ -n "$rest" ]; then
    printf '%s\n' "$lines" |
      grep -qF -e "$dir" -e "\$HOME$rest" -e "\${HOME}$rest" -e "~$rest"
  else
    printf '%s\n' "$lines" | grep -qF -e "$dir"
  fi
}

ensure_bin_on_path() {
  local file=$1 dir=$2
  local staged="$TMP_ROOT/binpath.$$"
  local src=$file
  # a path under $HOME is written as $HOME/... so a synced rc file still works
  local written=$dir rest=""
  case "$dir" in
    "$HOME"/*)
      rest=${dir#"$HOME"}
      written="\$HOME$rest"
      ;;
  esac

  case ":${PATH}:" in
    *":$dir:"*)
      skip "already on  PATH: $dir"
      return 0
      ;;
  esac

  # Any spelling counts as already done, so a re-run adds nothing and neither
  # does a line the user wrote by hand: the expanded path, and for a directory
  # under $HOME also $HOME/..., ${HOME}/... and ~/..., all of which are common.
  if [ -f "$file" ] && path_line_mentions "$file" "$dir" "$rest"; then
    skip "already in  $(tilde "$file")"
    return 0
  fi

  [ -f "$src" ] || src=/dev/null
  { cat "$src"
    # $PATH and $HOME stay literal on purpose: the rc file expands them
    # shellcheck disable=SC2016
    printf '\n%s\nexport PATH="$PATH:%s"\n' "$PATH_MARK" "$written"
  } > "$staged"
  replace_file "$file" "$staged" || skip "unchanged   $(tilde "$file")"
}

# ------------------------------------------------------------------ zsh ----

install_zsh() {
  local zshrc="$HOME/.zshrc"
  local omz zsh_custom aws_dir

  touch_rc "$zshrc"

  omz=$(zsh_home "$zshrc") || omz=""

  if [ -n "$omz" ]; then
    step "zsh (oh-my-zsh at $(tilde "$omz"))"
    zsh_custom=${ZSH_CUSTOM:-}
    [ -n "$zsh_custom" ] || zsh_custom=$(rc_var "$zshrc" ZSH_CUSTOM) || zsh_custom=""
    [ -n "$zsh_custom" ] || zsh_custom="$omz/custom"

    local plugin_dir="$zsh_custom/plugins/aws_sso"
    if [ -L "$plugin_dir" ] && [ "$FORCE" -eq 0 ]; then
      warn "$(tilde "$plugin_dir") is a symlink to $(readlink "$plugin_dir")."
      warn "Leaving it alone so an existing checkout is not overwritten; use --force to write through it."
    else
      install_file "$SRC_DIR/aws_sso.plugin.zsh" "$plugin_dir/aws_sso.plugin.zsh"
      install_file "$SRC_DIR/completions/_aws_sso" "$plugin_dir/_aws_sso"
    fi

    array_add "$zshrc" plugins aws_sso 'source .*oh-my-zsh\.sh'
  else
    step "zsh (no oh-my-zsh)"
    ensure_dir "$ZSH_SITE_FUNCTIONS"
    install_file "$SRC_DIR/completions/_aws_sso" "$ZSH_SITE_FUNCTIONS/_aws_sso"
    zsh_ensure_fpath "$zshrc"
    ensure_block "$zshrc" "$SRC_DIR/aws_sso.plugin.zsh"
  fi

  ensure_bin_on_path "$zshrc" "$BIN_DIR"
  # aws_sso shells out to aws, so a shell that cannot find aws cannot use it
  if aws_dir=$(find_aws_dir); then
    ensure_bin_on_path "$zshrc" "$aws_dir"
  fi
  [ "$HIDE_PLUMBING" -eq 1 ] && ensure_no_plumbing_profiles "$zshrc"

  note "Start a new zsh, or run: exec zsh"
}

# Locates an oh-my-zsh installation, preferring what ~/.zshrc actually points
# at over the default location.
zsh_home() {
  local zshrc=$1 candidate

  if [ -n "${ZSH:-}" ] && [ -f "$ZSH/oh-my-zsh.sh" ]; then
    printf '%s\n' "$ZSH"
    return 0
  fi
  candidate=$(rc_var "$zshrc" ZSH) || candidate=""
  if [ -n "$candidate" ] && [ -f "$candidate/oh-my-zsh.sh" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]; then
    printf '%s\n' "$HOME/.oh-my-zsh"
    return 0
  fi
  return 1
}

# Puts the site-functions directory on fpath above any compinit, since
# compinit only sees directories that were on fpath when it ran.
zsh_ensure_fpath() {
  local file=$1
  local staged="$TMP_ROOT/fpath.$$"
  local src=$file; [ -f "$src" ] || src=/dev/null

  if grep -Eq '^[^#]*fpath.*\.local/share/zsh/site-functions' "$src"; then
    skip "already on  fpath in $(tilde "$file")"
    return 0
  fi

  awk -v mark="$FPATH_MARK" '
    BEGIN { done = 0 }
    !done && $0 ~ /compinit/ && $0 !~ /^[[:blank:]]*#/ {
      print mark
      print "fpath=(\"$HOME/.local/share/zsh/site-functions\" $fpath)"
      print ""
      done = 1
    }
    { print }
    END {
      if (!done) {
        print ""
        print mark
        print "fpath=(\"$HOME/.local/share/zsh/site-functions\" $fpath)"
        print "autoload -Uz compinit"
        print "compinit"
      }
    }
  ' "$src" > "$staged"

  replace_file "$file" "$staged" || skip "unchanged   $(tilde "$file")"
}

# ----------------------------------------------------------------- bash ----

install_bash() {
  local bashrc="$HOME/.bashrc"
  local osh osh_custom aws_dir
  # PATH, exports and -- without a framework -- the wrapper function all go in
  # the login file; see bash_login_rc.
  local bash_profile
  bash_profile=$(bash_login_rc)

  osh=$(bash_home "$bashrc") || osh=""

  if [ -n "$osh" ]; then
    step "bash (oh-my-bash at $(tilde "$osh"))"
    # oh-my-bash loads the wrapper from ~/.bashrc through its plugin list,
    # which is its business; only the exports below are ours to place.
    touch_rc "$bashrc"
    osh_custom=$(bash_custom "$bashrc" "$osh")

    local plugin_dir="$osh_custom/plugins/aws_sso"
    if [ -L "$plugin_dir" ] && [ "$FORCE" -eq 0 ]; then
      warn "$(tilde "$plugin_dir") is a symlink to $(readlink "$plugin_dir")."
      warn "Leaving it alone so an existing checkout is not overwritten; use --force to write through it."
    else
      install_file "$SRC_DIR/aws_sso.plugin.sh" "$plugin_dir/aws_sso.plugin.sh"
    fi
    install_file "$SRC_DIR/completions/aws_sso.completion.sh" \
                 "$osh_custom/completions/aws_sso.completion.sh"

    array_add "$bashrc" plugins aws_sso 'source .*oh-my-bash\.sh'
    array_add "$bashrc" completions aws_sso 'source .*oh-my-bash\.sh'
  else
    step "bash (no oh-my-bash)"
    install_file "$SRC_DIR/completions/aws_sso.completion.sh" \
                 "$BASH_COMPLETION_DIR/aws_sso"

    local block="$TMP_ROOT/bash_block"
    cat "$SRC_DIR/aws_sso.plugin.sh" > "$block"
    cat >> "$block" <<'BLOCK'

if [ -r "$HOME/.local/share/bash-completion/completions/aws_sso" ]; then
  . "$HOME/.local/share/bash-completion/completions/aws_sso"
fi
BLOCK
    # Not ~/.bashrc: a login shell does not read it, and on macOS every new
    # Terminal window is a login shell, so the wrapper would never be defined.
    ensure_block "$bash_profile" "$block"
  fi

  ensure_bin_on_path "$bash_profile" "$BIN_DIR"
  # aws_sso shells out to aws, so a shell that cannot find aws cannot use it
  if aws_dir=$(find_aws_dir); then
    ensure_bin_on_path "$bash_profile" "$aws_dir"
  fi
  [ "$HIDE_PLUMBING" -eq 1 ] && ensure_no_plumbing_profiles "$bash_profile"

  note "Start a new bash, or run: exec bash -l"
}

# The file bash reads for a *login* shell: the first of ~/.bash_profile,
# ~/.bash_login and ~/.profile that exists, or ~/.bash_profile when none does.
#
# PATH and exported variables belong there rather than in ~/.bashrc, which a
# login shell does not read -- and on macOS every new Terminal window is a
# login shell. Following bash's own precedence matters: creating
# ~/.bash_profile where the login file is really ~/.profile would stop that one
# from being read at all.
bash_login_rc() {
  local candidate
  for candidate in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf '%s\n' "$HOME/.bash_profile"
}

bash_home() {
  local bashrc=$1 candidate

  if [ -n "${OSH:-}" ] && [ -f "$OSH/oh-my-bash.sh" ]; then
    printf '%s\n' "$OSH"
    return 0
  fi
  candidate=$(rc_var "$bashrc" OSH) || candidate=""
  if [ -n "$candidate" ] && [ -f "$candidate/oh-my-bash.sh" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ -f "$HOME/.oh-my-bash/oh-my-bash.sh" ]; then
    printf '%s\n' "$HOME/.oh-my-bash"
    return 0
  fi
  return 1
}

# Mirrors how oh-my-bash itself resolves OSH_CUSTOM.
bash_custom() {
  local bashrc=$1 osh=$2 candidate

  candidate=${OSH_CUSTOM:-}
  [ -n "$candidate" ] || candidate=$(rc_var "$bashrc" OSH_CUSTOM) || candidate=""
  if [ -n "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ -d "$osh/custom" ] && [ -O "$osh/custom" ]; then
    printf '%s\n' "$osh/custom"
  else
    printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/oh-my-bash/custom"
  fi
}

# ------------------------------------------------------------------ main ---

main() {
  local shell=$TARGET_SHELL

  [ -f "$SRC_DIR/bin/aws_sso" ] || die "$SRC_DIR does not look like the aws_sso package (no bin/aws_sso)"

  if [ -z "$shell" ]; then
    shell=$(login_shell)
    info "login shell: ${shell:-unknown}"
  else
    info "installing for: $shell (--shell)"
  fi

  [ "$DRY_RUN" -eq 1 ] && step "dry run: nothing will be written"

  choose_install_dir
  choose_hide_plumbing
  install_script

  case "$shell" in
    zsh)  install_zsh ;;
    bash) install_bash ;;
    *)
      warn "unrecognized login shell '${shell:-unknown}'; installed the script only."
      note "Only zsh and bash integration is packaged. For another shell, put
    $(tilde "$BIN_DIR") on your PATH, wrap the script yourself so that
    'export' reaches your shell:
        eval \"\$(aws_sso export PROFILE)\"
    and see completions/ for the completion definitions."
      ;;
  esac

  [ "$SYSTEM_WIDE" -eq 1 ] && configure_launchd_path

  check_dependencies

  if [ "$REFUSED" -gt 0 ]; then
    note "Some files were not installed because their destination resolves
    into $(tilde "$SRC_DIR"). If a plugin directory is symlinked to this
    checkout, remove the symlink and re-run, so real copies are installed."
  fi

  if [ -n "$NOTES" ]; then
    printf '\n%s\n' "${C_BOLD}Next${C_RESET}"
    printf '%s' "$NOTES" | sed 's/^/  /'
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '\n%s\n' "${C_BOLD}Dry run complete; nothing was written.${C_RESET}"
  else
    printf '\n%s\n' "${C_GREEN}${C_BOLD}Done.${C_RESET}"
  fi
}

main
