# Shell wrapper around the aws_sso script, for zsh.
#
# `export` / `-e` has to affect the calling shell, and a subprocess cannot
# set variables in its parent, so for that one command run the script with
# its stdout captured and eval what it prints. Everything else is handed
# straight through to the script on $PATH.
aws_sso() {
  case "${1:-}" in
    -e|export)
      local creds
      # captured separately so a failure propagates: `eval "$(...)"` would
      # report on the text eval ran, not on the command that produced it
      creds=$(command aws_sso "$@") || return $?
      eval "$creds"
      ;;
    *) command aws_sso "$@" ;;
  esac
}
