# shellcheck shell=bash
# bash completion for aws_sso.
#
# The zsh completion (_aws_sso) is the reference implementation; this offers
# the same candidates using bash's completion API. Kept to bash 3.2 syntax
# so it also works with the /bin/bash that ships with macOS.

# Prints the names of [<kind> <name>] sections in the AWS config file, one
# per line. `profile` additionally reports the bare [default] section.
_aws_sso_comp_sections() {
  local kind=$1
  local config=${AWS_CONFIG_FILE:-$HOME/.aws/config}

  [ -r "$config" ] || return 1

  awk -v kind="$kind" '
    match($0, /^[[:blank:]]*\[[^]]*\]/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^[[:blank:]]*\[[[:blank:]]*/, "", s)
      sub(/[[:blank:]]*\][[:blank:]]*$/, "", s)

      if (kind == "profile" && s == "default") { print "default"; next }

      if (substr(s, 1, length(kind)) != kind) next
      rest = substr(s, length(kind) + 1)
      if (rest !~ /^[[:blank:]]+[^[:blank:]]/) next
      sub(/^[[:blank:]]+/, "", rest)
      sub(/[[:blank:]]+$/, "", rest)
      print rest
    }
  ' "$config"
}

# Profile names that appear as another profile's source_profile. These are the
# intermediate SSO profiles in a role-chain; the chained profile is what you
# actually use, so they are filtered out of profile completion.
_aws_sso_comp_source_profiles() {
  local config=${AWS_CONFIG_FILE:-$HOME/.aws/config}

  [ -r "$config" ] || return 1

  awk '
    /^[[:blank:]]*source_profile[[:blank:]]*=/ {
      sub(/^[^=]*=[[:blank:]]*/, "")
      sub(/[[:blank:]].*$/, "")
      if (length($0)) print
    }
  ' "$config"
}

_aws_sso_comp_profiles() {
  local profiles sourced profile

  profiles=$(_aws_sso_comp_sections profile) || return 1

  if [ "${AWS_SSO_NO_SOURCE_PROFILES:-}" = 1 ]; then
    sourced=$(_aws_sso_comp_source_profiles)
    for profile in $sourced; do
      profiles=$(printf '%s\n' "$profiles" | grep -Fxv -- "$profile") || true
    done
  fi

  printf '%s\n' "$profiles"
}

_aws_sso_completion() {
  local cur cmd

  COMPREPLY=()
  cur=${COMP_WORDS[COMP_CWORD]}
  cmd=${COMP_WORDS[1]:-}

  local candidates=''

  if [ "$COMP_CWORD" -eq 1 ]; then
    # A leading '-' rules out the long spellings, so offer the short ones
    # on their own rather than mixing the two forms.
    case $cur in
      -*) candidates='-c -e -h -l' ;;
      *)  candidates='console export help login' ;;
    esac
  else
    # Flags passed through to `aws sso login`. --sso-session is added only for
    # console/export, whose argument is a profile, so overriding the session
    # logged in through is a real choice. For login the session is already the
    # argument -- as it is in the default case below, a bare sso-session name.
    local opts='--no-browser --use-device-code'

    case $cmd in
      help|-h)
        return 0
        ;;
      login|-l)
        [ "$COMP_CWORD" -eq 2 ] &&
          candidates=$(_aws_sso_comp_sections sso-session)
        ;;
      console|-c|export|-e)
        opts="$opts --sso-session"
        [ "$COMP_CWORD" -eq 2 ] &&
          candidates=$(_aws_sso_comp_profiles)
        ;;
    esac
    # Only once a leading '-' has ruled out the profile and sso-session names.
    # Offering them unconditionally pads every listing with three flags that
    # nobody was reaching for.
    case $cur in
      -*) candidates="$candidates $opts" ;;
    esac
  fi

  # word splitting is the point here; mapfile would need bash 4
  # shellcheck disable=SC2207
  COMPREPLY=( $(compgen -W "$candidates" -- "$cur") )
  return 0
}

complete -F _aws_sso_completion aws_sso
