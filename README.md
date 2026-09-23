# aws_sso

Three small conveniences on top of `aws sso`:

- **`aws_sso [session]`** — log in to an SSO session, resolving the session
  name from `$AWS_PROFILE` when you don't name one.
- **`aws_sso console [profile]`** — open the AWS console in your browser,
  federated in as that profile, in that profile's region. No copy-pasting from
  the SSO portal.
- **`aws_sso export [profile]`** — put that profile's credentials into your
  **current shell** as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` /
  `AWS_SESSION_TOKEN`, for tools that don't read `~/.aws/config`. With
  `--format process` it prints them as JSON instead, so `credential_process`
  can log you in on demand — see [Logging in on
  demand](#logging-in-on-demand).

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

The installer asks whether to install system-wide; **yes** is the default and
is what you want unless you have a reason not to — see [System-wide
install](#system-wide-install).

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

### System-wide install

```
Install system-wide? [Y/n]
```

**Yes** (the default) puts the script in `/usr/local/bin/aws_sso`, using
`sudo`. **No** puts it in `~/.local/bin/aws_sso` and changes nothing else.
`--system` and `--user` answer it in advance, for scripted runs.

The difference only matters for programs you don't start from a shell. GUI
applications and launchd jobs are launched with launchd's `PATH` —
`/usr/bin:/bin:/usr/sbin:/sbin`, which has neither `~/.local/bin` nor
Homebrew on it — so they cannot run `aws_sso` at all. That is exactly the
situation a `credential_process` line lands in when the program asking for
credentials is a GUI app. So a system-wide install also:

- adds `/usr/local/bin`, Homebrew's `bin`, and the directory `aws` is actually
  in — usually Homebrew's, but the AWS installer package uses `/usr/local/bin`
  and it can be anywhere — to the `PATH` launchd hands out. This is done with
  `launchctl setenv` (applications started from then on) and `sudo launchctl
  config user path` (persistent, read at the next boot); the two are stored
  separately, so both are set to cover either side of a restart;
- adds `/usr/local/bin` to your shell rc file if it isn't already on your
  `PATH` — on macOS `/etc/paths` usually has it, in which case nothing is
  written.

Existing components are kept and only what's missing is appended, so
re-running the installer doesn't grow the value.

Applications already running keep the `PATH` they started with, so quit and
reopen anything that needs `aws_sso` — or log out and back in.

With `--user`, none of that happens: `aws_sso` works from your shell, and a
`credential_process` naming it resolves for anything you start from a shell,
but not for GUI applications.

### What goes where

The script lands in `/usr/local/bin/aws_sso`, or `~/.local/bin/aws_sso` for a
`--user` install. The rest depends on your login shell and whether you use a
framework:

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
    --system         install to /usr/local/bin without asking (needs sudo)
    --user           install to ~/.local/bin without asking
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
           --format env|process   as shell exports (default), or as JSON
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
aws_sso export --format process my-profile   # JSON, for credential_process
```

A first argument that isn't a command is read as an sso-session name, so
`aws_sso corp` and `aws_sso login corp` are the same thing. An argument
starting with `-` is never read as a profile or session name, so
`aws_sso console --no-browser` still uses `$AWS_PROFILE`.

Arguments after the profile are handed to `aws sso login` — but only if the
token actually has to be refreshed. If it's still valid they're ignored.

### Logging in on demand

The three commands above only refresh a token when *they* are what you ran. An
ad-hoc `aws s3 ls`, or anything using an SDK, goes straight to the AWS
libraries and fails with a credential error if the token has expired.

`credential_process` closes that gap: the AWS CLI and every AWS SDK will run a
command of your choosing to fetch credentials, so pointing that at `aws_sso`
means an expired token logs you back in wherever it is noticed.

```ini
[profile corp-admin]           # the SSO profile, exactly as it was
sso_session = corp
sso_account_id = 123456789012
sso_role_name = Admin

[profile admin]                # what you actually use day to day
credential_process = /Users/you/.local/bin/aws_sso export --format process corp-admin
source_profile = corp-admin    # not for credentials; see below
region = us-east-1
```

`export AWS_PROFILE=admin`, and `aws`, `boto3`, Terraform and the rest all log
you in by themselves when the token has gone stale.

If the profile you use is itself role-chained, the same shape applies one
level up — `credential_process` goes on a new profile pointing at the chained
one, which is left exactly as it was:

```ini
[profile corp-sso-admin]       # SSO, unchanged
sso_session = corp
sso_account_id = 123456789012
sso_role_name = Admin

[profile admin-role]           # the role chain, unchanged
source_profile = corp-sso-admin
role_arn = arn:aws:iam::210987654321:role/Admin

[profile admin]
credential_process = /Users/you/.local/bin/aws_sso export --format process admin-role
source_profile = admin-role
```

Four things worth knowing:

**The profile carrying `credential_process` has to be a separate one.** Not a
choice `aws_sso` makes — it falls out of how the AWS libraries resolve
credentials. On a profile that also has `sso_session` the line is ignored
outright, the SSO keys win; and a line naming the profile it is set on calls
`aws_sso`, which asks for that profile's credentials, which calls
`credential_process` again. `aws_sso` stops that with an error rather than
recursing, but the fix is a separate profile either way.

**Keep the `source_profile` breadcrumb.** Without a `role_arn` beside it, it
is inert as far as the AWS libraries are concerned — they use
`credential_process` and never look at it. It is how `aws_sso` itself finds
the sso-session when `$AWS_PROFILE` names this profile, so bare `aws_sso`,
`aws_sso login` and `aws_sso console` keep working. Leave it out and they
report `No sso-session given, and none resolved from AWS_PROFILE`.

**Mind how the command is resolved.** The AWS libraries run
`credential_process` without a shell. That means no shell *syntax*:
`~/.local/bin/aws_sso` and `$HOME/...` stay literal and fail with `No such
file or directory: '~/.local/bin/aws_sso'`. Never write either.

A bare `aws_sso` does work — `PATH` is still searched, by the OS rather than
by a shell — but the `PATH` searched belongs to whatever ran `aws`. From your
terminal that is your shell's; GUI applications and launchd jobs carry
launchd's instead. A [system-wide install](#system-wide-install) is what makes
a bare `aws_sso` resolve for those too, which is why it's the default. It also
keeps the config portable: no home directory baked into a file you might share
or copy between machines.

`aws_sso` also looks for the `aws` binary in the usual install locations when
`PATH` lacks it, so a bare `PATH` doesn't just move the failure one step later
to `aws: command not found`.

**A login needs someone to complete it.** Under cron, in CI, or from an app
with no terminal, opening a browser and waiting is an indefinite hang rather
than an error, so `aws_sso` refuses and tells you to run `aws_sso login`
first. `AWS_SSO_LOGIN=1` forces it to try anyway; `AWS_SSO_LOGIN=0` refuses
even at a terminal.

**Concurrent callers only log in once.** `credential_process` runs once per
client, so a parallel `terraform apply` can ask ten times at once. The first
caller takes a lock and logs in; the rest wait for it and use the token it
fetched. The lock lives in `$TMPDIR`, and `AWS_SSO_LOGIN_TIMEOUT` (default
180s) caps the wait.

One cost to weigh: credentials fetched this way are cached only for the life
of the process that asked, so every `aws` command pays for a whole extra `aws`
invocation, and a role-chained profile re-assumes the role each time on top of
that. Worth a `time aws sts get-caller-identity` on your own setup before
committing to it; if it grates on a profile you hammer, keep the plain profile
for interactive use and put `credential_process` on a second one.

### Which region the console opens in

`console` opens the console in the region the AWS CLI would use for that
profile: `$AWS_REGION`, else `$AWS_DEFAULT_REGION`, else the profile's own
`region` in `~/.aws/config`. A named profile does not inherit `[default]`'s
region — the CLI doesn't do that either — so with no region set anywhere the
region is left out of the URL and the console opens wherever that browser was
last, which is what it always used to do.

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
sudo rm -f /usr/local/bin/aws_sso   # system-wide install
rm -f ~/.local/bin/aws_sso          # --user install
```

A system-wide install also touched launchd's `PATH`. To undo that:

```sh
launchctl unsetenv PATH             # the live value
sudo launchctl config user path ""  # the persistent one; takes effect on reboot
```

Leaving them is harmless — they only add `/usr/local/bin` and Homebrew, which
is where most things already are — but `unsetenv` is how you get back to the
stock `/usr/bin:/bin:/usr/sbin:/sbin`.

Then, depending on how you installed:

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

**`aws_sso: command not found`** — the directory it went into isn't on your
`PATH`: `/usr/local/bin` for a system-wide install, `~/.local/bin` for
`--user`. See [Install](#install).

**A GUI app or launchd job can't find `aws_sso`** — it was installed with
`--user`, or the launchd `PATH` hasn't reached it. Re-run `./install.sh
--system`, then quit and reopen the application: processes already running
keep the `PATH` they started with. `launchctl getenv PATH` shows the live
value.

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

**`Recursion: profile 'x' asks aws_sso for the credentials aws_sso is already
fetching for it`** — the `credential_process` line names the profile it is set
on. Point it at the underlying SSO profile instead; see [Logging in on
demand](#logging-in-on-demand).

**`no terminal is attached, so a login could only hang`** — something with no
terminal (cron, CI, an editor running Terraform) hit an expired token. Run
`aws_sso login` in a terminal first, or set `AWS_SSO_LOGIN=1` to let it try
the browser anyway.

**`No sso-session given, and none resolved from AWS_PROFILE`** — the profile
has no `sso_session`, and neither does anything in its `source_profile`
chain. Name the session directly: `aws_sso login corp`.
