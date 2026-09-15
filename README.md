# aws_sso

Three small conveniences on top of `aws sso`:

- **`aws_sso [session]`** — log in to an SSO session, resolving the session
  name from `$AWS_PROFILE` when you don't name one.
- **`aws_sso console [profile]`** — open the AWS console in your browser,
  federated in as that profile. No copy-pasting from the SSO portal.
- **`aws_sso export [profile]`** — put that profile's credentials into your
  **current shell** as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` /
  `AWS_SESSION_TOKEN`, for tools that don't read `~/.aws/config`.

All three refresh an expired SSO token for you instead of failing with
`Error loading SSO Token`, and all three follow `source_profile` chains, so a
role-chained profile resolves to the sso-session it ultimately logs in
through. Tab completion offers your configured profiles and sso-sessions.

## Requirements

- AWS CLI v2 (`aws`), `jq`, `curl`
- zsh or bash
- profiles configured with `sso_session` in `~/.aws/config`

If any of the three commands are missing and Homebrew is installed, the
installer offers to `brew install` them for you. Answer `n` and it just tells
you the command to run later.

## Install

```sh
git clone https://github.com/mtiszenkel-rhythmic/aws_sso.git
cd aws_sso
./install.sh
```

`./install.sh --dry-run` prints exactly what it would write, and diffs of
every rc-file edit, without touching anything. Run it first if you'd rather
look before you leap.

The installer is idempotent — re-run it to upgrade — and backs up any file it
edits as `<file>.aws_sso-<timestamp>.bak`.

If `~/.local/bin` isn't on your `PATH`, the installer says so at the end. Add
it yourself:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Then start a new shell, or `exec zsh` / `exec bash`.

### What goes where

The script always lands in `~/.local/bin/aws_sso`. The rest depends on your
login shell and whether you use a framework:

| Shell | | Wrapper function | Completion |
|---|---|---|---|
| zsh | with oh-my-zsh | `$ZSH_CUSTOM/plugins/aws_sso/aws_sso.plugin.zsh`, plus `aws_sso` in `plugins=( … )` | same plugin directory |
| zsh | without | a managed block in `~/.zshrc` | `~/.local/share/zsh/site-functions/_aws_sso`, added to `fpath` above `compinit` |
| bash | with oh-my-bash | `$OSH_CUSTOM/plugins/aws_sso/aws_sso.plugin.sh`, plus `aws_sso` in `plugins=( … )` | `$OSH_CUSTOM/completions/aws_sso.completion.sh`, plus `aws_sso` in `completions=( … )` |
| bash | without | a managed block in `~/.bashrc` | `~/.local/share/bash-completion/completions/aws_sso`, sourced from that block |

oh-my-zsh and oh-my-bash are found via `$ZSH` / `$OSH`, then via your rc file,
then at their default locations — so a framework installed somewhere unusual
(say `~/.config/oh-my-zsh`) is still picked up. Blocks written into rc files
are delimited by `# >>> aws_sso >>>` / `# <<< aws_sso <<<` and are rewritten,
not duplicated, on the next run.

### Why a shell function?

A subprocess cannot set variables in its parent, so `aws_sso export` alone
could never change your shell's environment. The wrapper function intercepts
just that one subcommand, captures the script's output, and `eval`s it in your
shell. Everything else is passed straight through to the script.

Without the function the script still works; you just have to do that part
yourself:

```sh
eval "$(aws_sso export my-profile)"
```

### Installer options

```
-n, --dry-run        report what would change without changing anything
-s, --shell SHELL    install for zsh or bash instead of the detected login shell
-f, --force          write into a plugin directory even if it is a symlink
-y, --yes            install missing dependencies with Homebrew without asking
-h, --help           usage
```

`--force` exists because a symlinked `$ZSH_CUSTOM/plugins/aws_sso` usually
means you have a working checkout wired up there; the installer refuses to
write through it unless you say so.

Either way, a destination that resolves back inside the checkout is never
written to, `--force` or not. Installing a file onto its own source achieves
nothing, and would leave copies where the repository doesn't keep them --
`_aws_sso` in the root rather than in `completions/`, say. The installer says
which files it skipped and why.

`--yes` skips the Homebrew prompt and installs. The prompt is also skipped
when stdin isn't a terminal, so piping the installer into a shell won't hang;
you get the `brew install` command to run instead.

## Usage

```
aws_sso [command | sso-session] [args...]

  console, -c [profile]  open the AWS console as PROFILE (default: $AWS_PROFILE)
  export,  -e [profile]  export PROFILE's credentials into this shell
  login,   -l [session]  log in to SESSION (default: resolved from $AWS_PROFILE)
  help,    -h            usage
```

```sh
aws_sso                          # log in; session resolved from $AWS_PROFILE
aws_sso corp                     # log in to sso-session 'corp'
aws_sso corp --no-browser        # extra args go to `aws sso login`
aws_sso console my-profile       # open the console as 'my-profile'
aws_sso -c my-profile --no-browser
aws_sso export my-profile        # credentials into this shell
```

A first argument that isn't a command is read as an sso-session name, so
`aws_sso corp` and `aws_sso login corp` are the same thing. An argument
starting with `-` is never read as a profile or session name, so
`aws_sso console --no-browser` still uses `$AWS_PROFILE`.

Arguments after the profile are handed to `aws sso login` — but only if the
token actually has to be refreshed. If it's still valid they're ignored.

### Choosing a browser

URLs are opened with `$BROWSER` if set, otherwise `open`, `xdg-open` or
`wslview`. The opener is called with the URL as its only argument, and gets
the sso-session name in `AWS_SSO_SESSION` in its environment — so a custom
`$BROWSER` script can route each session to its own browser profile or
container. Ordinary browsers ignore the variable.

### Completion

Profile completion lists every profile in `~/.aws/config` (or
`$AWS_CONFIG_FILE`). If you use role chaining, the intermediate SSO profiles
are noise; set

```sh
export AWS_SSO_NO_SOURCE_PROFILES=1
```

to hide any profile that appears as another profile's `source_profile`.

## Using it without the installer

Everything is plain files:

```
bin/aws_sso                          the script; put it anywhere on $PATH
aws_sso.plugin.zsh                   wrapper function, zsh
aws_sso.plugin.sh                    wrapper function, bash
completions/_aws_sso                 completion, zsh
completions/aws_sso.completion.sh    completion, bash
```

The script also works when sourced, which defines `aws_sso_login`,
`aws_sso_console` and `aws_sso_export` without shadowing the `aws_sso`
command:

```sh
. /path/to/aws_sso
```

## Uninstalling

```sh
rm -f ~/.local/bin/aws_sso
```

then, depending on how you installed:

```sh
# oh-my-zsh / oh-my-bash
rm -rf "${ZSH_CUSTOM:-$ZSH/custom}/plugins/aws_sso"
rm -f  "$OSH_CUSTOM/completions/aws_sso.completion.sh"
rm -rf "$OSH_CUSTOM/plugins/aws_sso"
# and drop aws_sso from plugins=( … ) / completions=( … ) in your rc file

# without a framework
rm -f ~/.local/share/zsh/site-functions/_aws_sso
rm -f ~/.local/share/bash-completion/completions/aws_sso
# and delete the `# >>> aws_sso >>>` … `# <<< aws_sso <<<` block from your rc file
```

## Troubleshooting

**`aws_sso: command not found`** — `~/.local/bin` isn't on your `PATH`; see
[Install](#install).

**Homebrew installed a dependency but it's still not found** — something
earlier on your `PATH` is shadowing Homebrew's `bin` directory, or `brew
shellenv` never ran. `brew --prefix` tells you where it should be.

**`export` doesn't change my environment** — the wrapper function isn't
loaded. Check with `type aws_sso`: it should report a function, not a file.
If it reports a file, start a new shell; if it still does, the rc-file edit
didn't take (`./install.sh --dry-run` will show what's missing).

**Completion doesn't fire** — in zsh, confirm the completion is registered
with `echo $_comps[aws_sso]`. Without oh-my-zsh, `compinit` only sees
directories that were on `fpath` *before* it ran, which is why the installer
inserts the `fpath` line above your existing `compinit`. If you have a
`~/.zcompdump` cache, delete it and start a new shell.

**`No sso-session given, and none resolved from AWS_PROFILE`** — the profile
has no `sso_session`, and neither does anything in its `source_profile`
chain. Name the session directly: `aws_sso login corp`.
