#!/usr/bin/env bash
# secret-bash-guard.sh — PreToolUse hook for Bash. Denies a command that would print a secret into context: a reader
# given a secret-bearing file, a dump of the environment or of a secret-named variable, a secret fetch that does not go
# into the vault ($CLAUDE_SECRET_DIR), a copy out of a secret path, or a shell given a command string this hook cannot
# see into. bash-guard.sh denies every compound form except a pipeline, so this hook tokenises the command
# (shell_words) and screens every word of every stage. A recursive reader that prints file contents is screened by
# listing its directory (the directory probe in _lib.sh). Hooks run in parallel; deny wins. A script may still use a
# secret by path: write it with the Write tool, so it holds only paths, and run it. The fetch pre-check runs first, on
# the raw command: under load the tokenised pass could approach the 5 s hook timeout, which would fail open on a
# command this check alone can deny at once.
set -uo pipefail
# Match and count bytes, whatever the session's locale: in a multibyte locale glibc's regex engine takes many times
# longer on the fetch forms, past the hook timeout on a CI runner.
export LC_ALL=C
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/_lib.sh"
source "$DIR/secret-patterns.sh"
hook_backstop ask "secret-bash-guard failed to evaluate; approve manually."
trap 'hook_ask "secret-bash-guard failed to evaluate; approve manually."' ERR
hook_read_input

if [[ "${CLAUDE_ALLOW_SECRET_READ:-0}" == "1" ]]; then
    hook_pass
fi

cmd=$(hook_field '.tool_input.command')
if [[ -z "$cmd" ]]; then
    hook_pass
fi

VAULT_HINT="a secret a script needs belongs in \$CLAUDE_SECRET_DIR, passed to the script by path"
FETCH_MSG="SECRET-FETCH BLOCK: this command emits a live secret to stdout (→ context). Fetch it into the vault"
FETCH_MSG+=" instead, as the whole command with one redirection of stdout: '... > \$CLAUDE_SECRET_DIR/<name>'. Then"
FETCH_MSG+=" have a script read that file. A registry password may instead be piped straight into"
FETCH_MSG+=" '... login --password-stdin'."
FETCH_MSG+=" If the phrase is only a search pattern, write it to a file in \$CLAUDE_TEMP_DIR and search with"
FETCH_MSG+=" 'grep -f <file>'."
HEREDOC_MSG="COMMIT-HEREDOC BLOCK: this commit message heredoc cannot be screened safely (the words before -m hold"
HEREDOC_MSG+=" quotes or shell syntax, the message holds a backquote or \$' or has a stray closing parenthesis, or"
HEREDOC_MSG+=" text follows a message that leaves a quote or ( open). Put the message in a file and use"
HEREDOC_MSG+=" 'git commit -F <file>'."
S_MSG="SECRET-ENV BLOCK: 'env -S' builds a new command line that is not screened and may print every"
S_MSG+=" variable, secret-bearing ones included, into context. Use the 'env VAR=value command' prefix"
S_MSG+=" form instead."
ENV_NONE_MSG="SECRET-ENV BLOCK: 'env' with no command prints every variable, secret-bearing ones included, into"
ENV_NONE_MSG+=" context. Use the 'env VAR=value command' prefix form, or reference a specific non-secret variable."
# _ci <literal>: set CI_RE to an ERE matching <literal> in any letter case.
_ci() {
    local s="$1" ch p i
    CI_RE=""
    for (( i = 0; i < ${#s}; i++ )); do
        ch="${s:i:1}"
        p="${_ASCII_LOWER%%"$ch"*}"
        if (( ${#p} == 26 )); then
            p="${_ASCII_UPPER%%"$ch"*}"
        fi
        if (( ${#p} < 26 )); then
            CI_RE+="[${_ASCII_UPPER:${#p}:1}${_ASCII_LOWER:${#p}:1}]"
        else
            CI_RE+="$ch"
        fi
    done
}

# A secret-named variable: one whose name holds a word below, or any ${!…} indirection. secret_var_glob is a cheap
# necessary condition for secret_var_re (bash compiles a regex on every [[ =~ ]]), derived from the same words.
# secret_name_ci matches the words in any case, for a name a command reads as written (launchctl getenv).
secret_name_re=""
secret_name_ci=""
secret_var_glob='*${!*'
for n in SECRET TOKEN PASSWORD PASSWD CREDENTIAL PRIVATE_KEY API_KEY ACCESS_KEY; do
    secret_name_re+="${secret_name_re:+|}$n"
    _ci "$n"
    secret_name_ci+="${secret_name_ci:+|}$CI_RE"
    secret_var_glob+="|*$n*"
done
secret_name_re="($secret_name_re)"
secret_name_ci="($secret_name_ci)"
secret_var_re='\$\{?[A-Za-z_]*'"${secret_name_re}"'|\$\{!'
secret_var_glob="@($secret_var_glob)"

# 1. Secret fetches, matched on the raw command with the commit-message heredoc removed (a message may name a fetch),
# and, when it holds a quote or backslash, on a copy with those removed too, and on a copy with every quoted or
# escaped |, ; and & masked as well: none of them changes what runs. kubectl get prints secrets when a resource that is
# or lists secrets and -o come in either order; [^|;&]* keeps the match inside one pipeline stage. oc (OpenShift's
# kubectl) takes the same forms, matched in lower case only: a two-letter name in any case is too common a fragment.
kube_get='(kubectl|oc)[[:space:]]([^|;&]*[[:space:]])?get[[:space:]]([^|;&]*[[:space:]])?'
kube_res='([^[:space:]|;&]*,)?[Ss][Ee][Cc][Rr][Ee][Tt][Ss]?([.,/][^[:space:]|;&]*)?'
kube_out='(-o|--output|--template)[^[:space:]]*'
kube_mid='[[:space:]]([^|;&]*[[:space:]])?'
# aws takes its global options between the service and the operation; [^|;&]* keeps them inside one pipeline stage.
# configure, a word of ordinary prose, allows only option-shaped words there: any run of options, each with at most one
# value.
aws_gap='[[:space:]]([^|;&]*[[:space:]])?'
aws_opts='([[:space:]]+-[^[:space:]|;&]*([[:space:]]+[^-[:space:]|;&][^[:space:]|;&]*)?)*[[:space:]]+'
# An npm config key naming a credential (_authToken, _auth, password).
npm_key='[^[:space:]|;&]*([Aa][Uu][Tt][Hh]|[Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])[^[:space:]|;&]*'
# terraform's words stay on one line (a newline ends the command). output prints a named output unredacted: its one
# name, among option words (-state takes a value) and redirections with their targets, ends the command.
tf_gap='[[:blank:]]([^|;&'$'\n'']*[[:blank:]])?'
tf_skip='([[:blank:]]+(--?state[[:blank:]]+[^-[:space:]|;&<>][^[:space:]|;&<>]*|-[^[:space:]|;&<>]*'
tf_skip+='|&?[0-9]*[<>][<>&|]*[[:blank:]]*[^[:space:]|;&<>]+))*'
# aws-vault exec's words before --, which starts the command it runs.
av_word='[[:blank:]]+(-|[^-[:space:]|;&][^[:space:]|;&]*|-[^-[:space:]|;&][^[:space:]|;&]*|--[^[:space:]|;&]+)'
hk_sep='(:|[[:space:]]+)'
# A case-insensitive file system runs TERRAFORM as terraform, so these tools' names match in any case; their
# subcommands do not. OpenTofu's tofu takes terraform's forms, and honours TF_CLI_ARGS as terraform does.
_ci ansible-vault
ci_ansible="$CI_RE"
_ci terraform
ci_tf="$CI_RE"
_ci tofu
ci_tf="(${ci_tf}|${CI_RE})"
_ci npm
ci_npm="[Pp]?$CI_RE"
_ci doppler
ci_doppler="$CI_RE"
_ci heroku
ci_heroku="$CI_RE"
_ci launchctl
ci_launchctl="$CI_RE"
_ci aws-vault
ci_av="$CI_RE"
fetch_forms=(
    "secretsmanager${aws_gap}(batch-)?get-secret-value"
    "ssm${aws_gap}get-parameters?(-by-path)?[[:space:]](.*[[:space:]])?--with-decryption"
    "ecr(-public)?${aws_gap}get-login-password"
    "ecr${aws_gap}get-authorization-token"
    "sts${aws_gap}(assume-role(-with-saml|-with-web-identity)?|get-session-token|get-federation-token)"
    "sso${aws_gap}get-role-credentials"
    "codeartifact${aws_gap}get-authorization-token"
    "eks${aws_gap}get-token"
    "rds${aws_gap}generate-db-auth-token"
    "iam${aws_gap}create-access-key"
    "kms${aws_gap}decrypt"
    "configure${aws_opts}get[[:space:]]+[^[:space:]]*(secret|token|key)[^[:space:]]*"
    "configure${aws_opts}export-credentials"
    'security[[:space:]]+find-(generic|internet)-password[[:space:]](.*[[:space:]])?-[[:alpha:]]*[wg][[:alpha:]]*'
    'security[[:space:]]+dump-keychain[[:space:]](.*[[:space:]])?-[[:alpha:]]*d[[:alpha:]]*'
    "${kube_get}${kube_res}${kube_mid}${kube_out}"
    "${kube_get}${kube_out}${kube_mid}${kube_res}"
    '(kubectl|oc)[[:space:]](.*[[:space:]])?config[[:space:]]+view[[:space:]](.*[[:space:]])?--raw'
    '(kubectl|oc)[[:space:]](.*[[:space:]])?create[[:space:]]+token'
    # oc whoami -t and sa get-token or new-token print a token; oc extract is walked (the k walk), as --to may name
    # the vault.
    'oc[[:space:]]([^|;&]*[[:space:]])?whoami[[:space:]]([^|;&]*[[:space:]])?(-t|--show-token)'
    'oc[[:space:]]([^|;&]*[[:space:]])?(sa|serviceaccounts)[[:space:]]+(get|new)-token'
    'gcloud[[:space:]](.*[[:space:]])?auth[[:space:]]+(application-default[[:space:]]+)?print-(access|identity)-token'
    'gcloud[[:space:]](.*[[:space:]])?secrets[[:space:]]+versions[[:space:]]+access'
    'az[[:space:]](.*[[:space:]])?account[[:space:]]+get-access-token'
    'az[[:space:]](.*[[:space:]])?keyvault[[:space:]]+secret[[:space:]]+show'
    'git[[:space:]](.*[[:space:]])?credential[[:space:]]+fill'
    'docker-credential-[[:alnum:]_.-]+[[:space:]]+get'
    'sops[[:space:]](.*[[:space:]])?(-d|--decrypt)'
    'strongbox[[:space:]](.*[[:space:]])?-decrypt'
    # gpg decrypts with -d, a short-option bundle holding d (-qd, -dq) or a --decrypt… long form, after only
    # option-shaped words. age is walked only (see the d walk): an ordinary word, so --name age -d cannot be told from
    # age -d by text.
    "gpg${aws_opts}(-[A-Za-z]*d[A-Za-z]*|--decrypt[A-Za-z-]*)"
)
fetch_re=""
for f in "${fetch_forms[@]}"; do
    fetch_re+="${fetch_re:+|}$f"
done
fetch_re="(^|[^[:alnum:]_.-])(${fetch_re})([^[:alnum:]_.-]|$)"
# gh's fetches are found by its word walk (a), which also sees them behind runners no list could name. This text form
# only marks the phrase inside a quoted word (gh_soft): data to grep or a search, a fetch once something in the command
# runs a string (strun).
gh_re='(^|[^[:alnum:]_.-])gh[[:space:]]+auth[[:space:]]+(token|git-credential'
gh_re+='|status[[:space:]](.*[[:space:]])?(-t|--show-token))([^[:alnum:]_.-]|$)'
# The other tools' forms are matched only on a text that names one of them (tools_re): bash's regex engine takes time
# in proportion to the pattern's size for every character, so one pattern of them all would slow every command.
tools_re="(${ci_ansible}|${ci_tf}|${ci_npm}|${ci_doppler}|${ci_heroku}|${ci_launchctl}|${ci_av})"
fetch_nl_re="(${ci_tf}|${ci_av})"
fetch_forms2=(
    "${ci_ansible}${aws_gap}view"
    "${ci_tf}${tf_gap}output${tf_gap}--?(raw|json)(=true)?"
    "${ci_tf}${tf_gap}show${tf_gap}--?json(=true)?"
    "${ci_tf}${tf_gap}state[[:blank:]]+pull"
    "${ci_npm}${aws_gap}get${aws_gap}${npm_key}"
    # doppler's upload and delete print every secret left.
    "${ci_doppler}${aws_gap}secrets${aws_gap}(get|download|substitute|upload|delete)"
    "${ci_heroku}${aws_gap}(config${hk_sep}(get|edit)|auth${hk_sep}token|(pg|redis)${hk_sep}credentials)"
    "${ci_launchctl}[[:space:]]+getenv[[:space:]]+[^[:space:]|;&]*(${secret_name_ci}|\\\$)[^[:space:]|;&]*"
    "${ci_launchctl}[[:space:]]+export"
    "${ci_av}${aws_gap}export"
    # exec -j (a short bundle too) prints the credentials as JSON; -s and --*-server serve them on a local endpoint.
    "${ci_av}${aws_gap}exec(${av_word})*[[:blank:]]+(--json(=true)?|-[A-Za-z]*[js][A-Za-z]*|--(ec2-|ecs-)?server)"
    "${ci_av}${aws_gap}login[[:space:]]([^|;&]*[[:space:]])?(-s|--stdout)"
)
fetch2_re=""
for f in "${fetch_forms2[@]}"; do
    fetch2_re+="${fetch2_re:+|}$f"
done
fetch2_re="(^|[^[:alnum:]_.-])(${fetch2_re})([^[:alnum:]_.-]|$)"
# Forms that print every secret when only options follow them end at the stage's end, a redirection, a newline or a
# comment, so they carry their own end and no trailing boundary. aws-vault exec with no command runs a shell; its
# options there are any but --, which starts the command. A terraform output name ends its command the same way, so
# prose that names the command is not one.
eos_opts='([[:space:]]+-[^[:space:]|;&<>]*([[:space:]]+[^-[:space:]|;&<>][^[:space:]|;&<>]*)?)*'
eos_end='[[:blank:]]*($|[|;&<>#)]|'$'\n''|[0-9]+[<>])'
av_opts='([[:space:]]+(-[^-[:space:]|;&<>][^[:space:]|;&<>]*|--[^[:space:]|;&<>]+)'
av_opts+='([[:space:]]+[^-[:space:]|;&<>][^[:space:]|;&<>]*)?)*'
fetch_eos_re="(^|[^[:alnum:]_.-])(${ci_doppler}${eos_opts}[[:space:]]+secrets${eos_opts}${eos_end}"
fetch_eos_re+="|${ci_heroku}[[:space:]]+config${eos_opts}${eos_end}"
fetch_eos_re+="|${ci_av}${av_opts}[[:space:]]+exec${av_opts}([[:space:]]+[^-[:space:]|;&<>][^[:space:]|;&<>]*)?"
fetch_eos_re+="${av_opts}([[:space:]]+--)?${eos_end}"
fetch_eos_re+="|${ci_tf}${tf_gap}output${tf_skip}[[:blank:]]+[A-Za-z_\$][^[:space:]|;&<>]*${tf_skip}${eos_end})"
# TF_CLI_ARGS and TF_CLI_ARGS_<command> add flags or an output name to a terraform output or show, so with one named
# in the command, or set in the environment, every output or show is a fetch.
tf_any_re="(^|[^[:alnum:]_.-])${ci_tf}${tf_gap}(output|show)([^[:alnum:]_.-]|$)"
tf_env=0
if [[ -n "${TF_CLI_ARGS:-}${TF_CLI_ARGS_output:-}${TF_CLI_ARGS_show:-}" ]]; then
    tf_env=1
fi
ansible_decrypt_re="(^|[^[:alnum:]_.-])${ci_ansible}[[:space:]]([^|;&]*[[:space:]])?(decrypt|edit)([^[:alnum:]_.-]|$)"
ANSIBLE_MSG="SECRET-FETCH BLOCK: 'ansible-vault decrypt' and 'edit' write the decrypted file in place, to --output or"
ANSIBLE_MSG+=" to an editor the environment chooses, where it can be read into context. Use"
ANSIBLE_MSG+=" 'ansible-vault view <file> > \$CLAUDE_SECRET_DIR/<name>' instead."

# _fetch_match <text>: deny an ansible-vault decrypt or edit in <text>; else 0 if <text> holds a secret fetch form.
_fetch_match() {
    if ! [[ "$1" =~ $tools_re ]]; then
        [[ "$1" =~ $fetch_re ]]
        return
    fi
    if [[ "$1" =~ $ansible_decrypt_re ]]; then
        hook_deny "$ANSIBLE_MSG"
    fi
    [[ "$1" =~ $fetch_re || "$1" =~ $fetch2_re || "$1" =~ $fetch_eos_re ]] \
        || { [[ "$1" =~ $tf_any_re ]] && { (( tf_env )) || [[ "$1" == *TF_CLI_ARGS* ]]; }; }
}

# _fetch_marked <text>: 0 if <text> names the vault or a --password-stdin login.
_fetch_marked() {
    [[ "$1" == *CLAUDE_SECRET_DIR* || "$1" == *-vault/secrets/* || "$1" == *--password-stdin* ]]
}

# _fetch_open: 0 while the pre-check may still allow the command: no form has matched, or the command, as written or
# joined, names the vault or a --password-stdin login.
_fetch_open() {
    (( ! fetch_hit )) || _fetch_marked "$fetch_checked" || _fetch_marked "$fetch_joined"
}

# _fetch_copies <text>: while the command may still pass, match <text>'s copy with its quotes and backslashes removed
# (FC_D) and, when it holds a separator, its masked copy (FC_M), setting fetch_hit on a match.
_fetch_copies() {
    FC_D=""
    FC_M=""
    if [[ "$1" == *[\"\'\\]* ]] && _fetch_open; then
        FC_D=$(printf '%s' "$1" | LC_ALL=C tr -d "\"'\\\\") || FC_D=""
        if _fetch_match "$FC_D"; then
            fetch_hit=1
        fi
        if [[ "$1" == *[\|\;\&]* ]] && _fetch_open; then
            FC_M=$(printf '%s' "$1" | LC_ALL=C awk -v q="'" "$_FETCH_MASK_AWK") || FC_M=""
            if _fetch_match "$FC_M"; then
                fetch_hit=1
            fi
        fi
    fi
}

# _fetch_nl_copy <text> <text with its quotes and backslashes removed, or empty>: match <text>'s copy with every newline
# made a space, with its own dequoted and masked copies. Only the terraform, tofu and aws-vault forms keep their gaps
# off a newline (every other form's gap crosses one, so <text> matched it already), so a text naming none of them, as
# written or dequoted, is left.
_fetch_nl_copy() {
    if ! [[ "$1" =~ $fetch_nl_re || "$2" =~ $fetch_nl_re ]]; then
        return 0
    fi
    fetch_nlsp=$(printf '%s' "$1" | LC_ALL=C tr '\n' ' ') || fetch_hit=1
    if _fetch_match "$fetch_nlsp"; then
        fetch_hit=1
    fi
    _fetch_copies "$fetch_nlsp"
}

# The pre-check's third text: the command with its quotes and backslashes removed, as in the second, and each |, ; and
# & that is quoted or escaped replaced by a space. Such a separator is no stage boundary, so a form's [^|;&] gaps may
# cross it. '…' and $'…' run to their close ($'…' with its backslash escapes), "…" honours \ before $ ` " \ and newline,
# and a backslash outside quotes escapes the next character.
_FETCH_MASK_AWK='
function out(c) {
    if (c == "|" || c == ";" || c == "&") c = " "
    printf "%s", c
}
{ s = (NR == 1) ? $0 : s "\n" $0 }
END {
    n = length(s); st = "N"
    if (split(s, ch, "") != n) for (i = 1; i <= n; i++) ch[i] = substr(s, i, 1)
    for (i = 1; i <= n; i++) {
        c = ch[i]
        if (st == "N") {
            if (c == "\\") { i++; out(ch[i]) }
            else if (c == q) st = "S"
            else if (c == "\"") st = "D"
            else if (c == "$" && ch[i + 1] == q) { printf "%s", c; i++; st = "A" }
            else printf "%s", c
            continue
        }
        if (c == "\\" && st == "A") { i++; out(ch[i]); continue }
        if (c == "\\" && st == "D") {
            d = ch[i + 1]
            if (d == "$" || d == "`" || d == "\"" || d == "\\" || d == "\n") { i++; out(d) }
            continue
        }
        if ((st == "S" || st == "A") && c == q) st = "N"
        else if (st == "D" && c == "\"") st = "N"
        else out(c)
    }
}'
fetch_hit=0
fetch_dequoted=""
fetch_checked=$(strip_commit_heredoc "$cmd")
# A commit-message heredoc the strip left whole (the words before -m are not plain, or the message would end the
# substitution early under bash 3.2) is denied here, as bash-guard denies it: tokenising its quotes could desync.
if [[ "$fetch_checked" == "$cmd" && "$cmd" == *$'-m "$(cat <<\'EOF\'\n'* ]]; then
    hook_deny "$HEREDOC_MSG"
fi
fetch_checked=$(strip_text_heredoc "$fetch_checked")
fetch_masked=""
# The forms match the command as written and with every backslash-newline removed, as bash removes it before it splits
# words; a comment does not continue across one, so the joined copy alone would hide a form after it (inside '…' it
# is literal, so there the join only widens a match).
fetch_joined="$fetch_checked"
if [[ "$fetch_checked" == *\\$'\n'* ]]; then
    fetch_joined=$(printf '%s' "$fetch_checked" | LC_ALL=C awk '{ if (sub(/\\$/, "")) printf "%s", $0; else print }') \
        || fetch_joined="$fetch_checked"
fi
if _fetch_match "$fetch_checked"; then
    fetch_hit=1
fi
if [[ "$fetch_joined" != "$fetch_checked" ]] && _fetch_match "$fetch_joined"; then
    fetch_hit=1
fi
# A copy is matched while the command may still pass, so an ansible-vault decrypt it alone shows is denied too.
_fetch_copies "$fetch_checked"
fetch_dequoted="$FC_D"
fetch_masked="$FC_M"
fetch_jdequoted=""
fetch_jmasked=""
if [[ "$fetch_joined" != "$fetch_checked" ]]; then
    _fetch_copies "$fetch_joined"
    fetch_jdequoted="$FC_D"
    fetch_jmasked="$FC_M"
fi
# A form's gaps stop at a newline, but a newline inside quotes is part of a word, so a form the quote's lines would
# split (terraform 'a<NL>b' output -raw x) is matched on a copy with every newline made a space. A hit there reaches
# the one-line deny below; prose that spans a newline is denied too, the safe side.
if [[ "$fetch_checked" == *$'\n'* ]]; then
    _fetch_nl_copy "$fetch_checked" "$fetch_dequoted"
    if [[ "$fetch_joined" != "$fetch_checked" ]]; then
        _fetch_nl_copy "$fetch_joined" "$fetch_jdequoted"
    fi
fi
gh_soft=0
strun=0
for fetch_text in "$fetch_checked" "$fetch_dequoted" "$fetch_masked" "$fetch_joined" "$fetch_jdequoted" \
        "$fetch_jmasked"; do
    if [[ "$fetch_text" == *auth* && "$fetch_text" =~ $gh_re ]]; then
        gh_soft=1
        break
    fi
done
if (( fetch_hit )); then
    # An allowed fetch is one line: a marker in a comment, or a line the tokeniser joins and bash does not, must not
    # exempt one.
    if [[ "$fetch_checked" == *$'\n'* ]]; then
        hook_deny "$FETCH_MSG"
    fi
    # No allowed shape is possible without the vault or a --password-stdin login, so deny without tokenising.
    fetch_marked=0
    for fetch_text in "$fetch_checked" "$fetch_dequoted" "$fetch_masked" "$fetch_joined" "$fetch_jdequoted" \
            "$fetch_jmasked"; do
        if _fetch_marked "$fetch_text"; then
            fetch_marked=1
        fi
    done
    if (( ! fetch_marked )); then
        hook_deny "$FETCH_MSG"
    fi
fi

# The timing tests cover commands up to SHELL_SCAN_MAX_CHARS, the bound bash-guard denies beyond. Deny a longer
# command here too, so this hook never screens an input its timing was not measured on and does not rely on another
# hook's deny to stay inside its timeout.
if (( ${#cmd} > SHELL_SCAN_MAX_CHARS )); then
    msg="SECRET-SCAN BLOCK: a command over ${SHELL_SCAN_MAX_CHARS} bytes is not screened. Put long content in a"
    msg+=" file."
    hook_deny "$msg"
fi

# The elements (words, redirections and separators) the main loop screens before it denies the command. An element
# that leaves the fast paths costs up to about 0.1 ms on bash 3.2 behind a stack of walks, so this bounds the screening
# time whatever the command holds; micro-optimising cannot bound every shape. A plain word with no walk running and a
# | that ends a stage with nothing to check take the fast paths and do not count: their cost is small and linear.
SECRET_SCAN_WORD_BUDGET=6000
WORDS_MSG="SECRET-SCAN BLOCK: this command has more words to screen than the hook can check in time (over"
WORDS_MSG+=" ${SECRET_SCAN_WORD_BUDGET} options, paths or wrapped words). Split it into smaller commands, or put long"
WORDS_MSG+=" content in a file."
scan_words=0

# Word classes, looked up per word as _nm_<name> (any position) and _cp_<name> (command position) by indirect
# expansion: under bash 3.2 a case over these names costs about seven times as much per word. Any position: R reader,
# J jq, W awk, G git, H shell, K interpreter, C copier (Ct: one taking -t DIR), D environment dump, P printer, T tee,
# X xargs, Q parallel, N watch, O ps, U su/script/flock, S security, L a registry login or compose command (and
# docker-compose and podman-compose), a gh, B another command that may run a string it is given. Command position: A wrapper (every later word is at command position too, and
# aws-vault is one), E env, e export, s set, v eval, Z a single-word fetch tool, f find (-exec starts a wrapper),
# c cd, pushd, popd and zsh's chdir, k kubectl and oc, d gpg and age, h source and the .
# builtin (a shell reading a script), b { or repeat (a zsh group or loop: denied), M ssh (a wrapper whose later words a
# remote shell parses again).
# Every name also goes into plain_names, so shell_words never marks it plain, as do the words the fetch shapes read in
# the first stage and, in a command with a pipe, ls and fd, which may print names for xargs (_np_start).
word_classes=(
    'nm R cat less more head tail xxd hexdump strings od nl tac bat grep egrep fgrep rg sed yq base64 base32 sort'
    'nm R uniq cut paste diff cmp comm join fold rev tr column pr fmt expand unexpand iconv look dd openssl tar zip'
    'nm R gzip bzip2 xz zstd zcat ggrep ugrep ug'
    'nm J jq'
    'nm W awk gawk mawk nawk'
    'nm G git'
    'nm H sh bash zsh dash ksh'
    'nm K python python3 perl ruby node php pypy bun deno lua luajit rscript osascript'
    'nm Ct cp mv ln install'
    'nm C rsync scp ditto'
    'nm D printenv declare typeset'
    'nm P echo printf print'
    'nm T tee'
    'nm X xargs'
    'nm Q parallel'
    'nm N watch'
    'nm O ps'
    'nm U su script flock'
    'nm S security'
    'nm L docker podman helm oras skopeo buildah nerdctl'
    'nm a gh'
    'nm B sudo doas trap make gmake npx npm pnpm yarn bunx expect tclsh pwsh powershell busybox tmux screen fish'
    'nm B tcsh csh gsed'
    'cp A sudo doas nice nohup time timeout command builtin exec noglob nocorrect xargs stdbuf ionice caffeinate'
    'cp A chronic flock unbuffer setsid direnv parallel taskset chrt script'
    'cp b repeat'
    'cp E env'
    'cp e export'
    'cp s set'
    'cp v eval'
    'cp Z op vault bw rbw'
    'cp f find'
    'cp c cd pushd popd chdir'
    'cp k kubectl oc'
    'cp d gpg age'
    'cp h source'
    'cp M ssh slogin'
)
VER_NAME_RE='^([a-z]+)[0-9][0-9.]*$'
plain_names='! . { -- --debug --v --log-http --verbosity debug docker-compose podman-compose aws-vault doppler heroku'
# A dashed git-<subcommand> whose options run a shell command starts the I walk (_git_cmd_start).
plain_names+=' git-rebase git-difftool git-filter-branch git-bisect git-submodule git-fetch git-pull git-ls-remote'
plain_names+=' git-fetch-pack git-clone git-push git-send-pack git-archive git-grep git-send-email'
# The name-producer check (_np_start) reads a pipeline's earlier stages; with no | there are none.
np_on=0
if [[ "$cmd" == *'|'* ]]; then
    np_on=1
    plain_names+=' ls fd'
fi
for line in "${word_classes[@]}"; do
    # shellcheck disable=SC2086  # split the table line into words; it holds no glob characters
    set -- $line
    tbl="$1"
    cls="$2"
    shift 2
    for n in "$@"; do
        printf -v "_${tbl}_$n" '%s' "$cls"
        plain_names+=" $n"
    done
done

# Tokenise the command with the commit-message heredoc removed, as bash-guard screens it: the body is inert text, and
# a quote in it would otherwise desync the quote tracking (hiding a later stage, or denying a balanced message).
shell_words "$fetch_checked" "$plain_names" "$SECRET_PATH_FRAGMENT_RE"
if (( ! SW_OK )); then
    msg="SECRET-SCAN BLOCK: this command could not be tokenised (it holds a \\x1e or \\x1f character, or the"
    msg+=" tokeniser failed), so it is not screened. Put unusual content in a file."
    hook_deny "$msg"
fi

# _secret_variant <word>: 0 if a form inside <word> names a secret path: the value after its first = (--opt=V, NAME=V,
# if=V), the word minus its first two characters when it is -xV, or the text after its first : (REV:path, host:path);
# or, when its last component is a glob, the word or one of those forms matches a secret name (after a :, a ( group
# counts as a glob: a remote shell may expand it). An --exclude= or
# --exclude-dir= value names files to skip, not to read. A form with an empty value is skipped, and the glob test runs
# only on a form that holds a glob character: a word of many short separators would otherwise pay both for nothing.
_secret_variant() {
    local w="$1" v
    if [[ "$w" == --exclude=* || "$w" == --exclude-dir=* ]]; then
        return 1
    fi
    if [[ "$w" == *=* ]]; then
        v="${w#*=}"
        if [[ -n "$v" ]] && { path_is_secret "$v" || { [[ "$v" == *[\*\?\[]* ]] && path_glob_is_secret "$v"; }; }; then
            return 0
        fi
    fi
    if [[ "$w" == -[!-]?* ]]; then
        v="${w:2}"
        if [[ -n "$v" ]] && { path_is_secret "$v" || { [[ "$v" == *[\*\?\[]* ]] && path_glob_is_secret "$v"; }; }; then
            return 0
        fi
    fi
    if [[ "$w" == *:* ]]; then
        v="${w#*:}"
        if [[ -n "$v" ]] && { path_is_secret "$v" \
                || { [[ "$v" == *[\*\?\[\(]* ]] && path_glob_is_secret "$v" remote; }; }; then
            return 0
        fi
        # A word of two or more colons may put the path after the last (git's :0:path index stage), or after the first
        # ]: (a bracketed IPv6 host, [::1]:path or user@[fe80::1]:path, whose path may hold a colon): test both.
        if [[ "$v" == *:* ]]; then
            v="${w%:*}"
            v="${w:${#v}+1}"
            if [[ -n "$v" ]] && { path_is_secret "$v" \
                    || { [[ "$v" == *[\*\?\[\(]* ]] && path_glob_is_secret "$v" remote; }; }; then
                return 0
            fi
            if [[ "$w" == *]:* ]]; then
                v="${w#*]:}"
                if [[ -n "$v" ]] && { path_is_secret "$v" \
                        || { [[ "$v" == *[\*\?\[\(]* ]] && path_glob_is_secret "$v" remote; }; }; then
                    return 0
                fi
            fi
        fi
    fi
    [[ "$w" == *[\*\?\[]* ]] && path_glob_is_secret "$w"
}

# _git_ps_word <word>: screen a word after git's subcommand that starts with :, which git resolves itself (a pathspec,
# or an index path) and never hands to a remote shell. GPW is 0 when it names no secret, 1 when it does, or empty to
# leave it to the generic tests. A literal exclude pathspec only drops files (0); long-form magic (:(top)x) is tested on
# the path after it, without the host:path reading of its ( group as a glob. A word whose magic is not plain, or whose
# path holds whitespace, shell syntax or a backslash, is left: some git options run a word as a shell command (rebase
# -x ':!;cat .env'), and git reads a backslash in a pathspec as an escape (.en\v matches .env).
_git_ps_word() {
    local m p
    GPW=""
    if [[ "$1" == ':('* ]]; then
        m="${1#':('}"
        if [[ "$m" != *')'* ]]; then
            return 0
        fi
        p="${m#*)}"
        m="${m%%)*}"
        if [[ "$m" == *[!A-Za-z0-9,:=_.-]* ]]; then
            return 0
        fi
    else
        p="${1#:}"
        p="${p#"${p%%[!/!^]*}"}"
    fi
    if [[ "$p" == *[[:space:]\;\&\|\<\>\(\)\`\$\{\}\\\'\"]* ]]; then
        return 0
    fi
    if _rr_ps_exclude "$1" "${wmk//[!b]/}"; then
        GPW=0
    elif [[ "$1" == ':('* && -n "$p" ]]; then
        GPW=0
        # shellcheck disable=SC2053  # the alternations are intentional patterns
        if [[ "/$p" == $_SECRET_PATH_ANY && "/$p" != $_SECRET_ALLOW_ANY ]] \
                || { [[ "$p" == *[=:\*\?\[]* || "$p" == -[!-]?* ]] && _secret_variant "$p"; }; then
            GPW=1
        fi
    fi
}

# _braces_are_replacements <word>: 0 if every {…} in <word> holds only digits and # % . / +, with no .. beside a digit,
# as parallel's replacement strings do ({}, {.}, {/.}, {#}, {1}, {+..}), else 1: a perl replacement string ({=…=}) or
# a brace expansion ({a,b}, {1..3}) is not. A brace left open, or a word over 256 characters, is not either (fail
# closed).
_braces_are_replacements() {
    local i n=${#1} in=0 ch c=""
    if (( n > 256 )); then
        return 1
    fi
    for (( i = 0; i < n; i++ )); do
        ch="${1:i:1}"
        if (( in )); then
            if [[ "$ch" == '}' ]]; then
                if [[ "$c" == *[0-9]..* || "$c" == *..[0-9]* ]]; then
                    return 1
                fi
                in=0
            elif [[ "$ch" != [0-9#%./+] ]]; then
                return 1
            else
                c+="$ch"
            fi
        elif [[ "$ch" == '{' ]]; then
            in=1
            c=""
        fi
    done
    (( ! in ))
}

# _names_input <path> [fd]: 0 if <path> may name this command's own input or a special file (so an ssh option value,
# or the program a shell or interpreter is given, is not a file of its own), wherever it is resolved from: a .. segment,
# a dev, proc or fd segment anywhere (/tmp/../dev/stdin, dev/stdin from /, fd/0 from /dev), or a last segment of stdin,
# stdout or stderr (fail closed: the working directory is unknown here), in any case (the root volume may fold it).
# Given fd, where a file is expected (a program, a config), an all-digit last segment counts too (0 from /dev/fd).
_names_input() {
    local re='(^|/)(\.\.|dev|proc|fd)(/|$)|(^|/)std(in|out|err)$' rc=1
    if [[ "${2:-}" == fd ]]; then
        re+='|(^|/)[0-9]+$'
    fi
    shopt -s nocasematch
    if [[ "$1" =~ $re ]]; then rc=0; fi
    shopt -u nocasematch
    return $rc
}


# _deny_group <form>: deny a zsh grouping or loop at command position.
_deny_group() {
    local msg="GROUP BLOCK: '$1' at command position is a zsh grouping or loop this hook cannot screen, and grouping is"
    msg+=" not allowed here. Write the commands to a script in \$CLAUDE_TEMP_DIR with the Write tool and run it with"
    msg+=" 'bash <file>' instead."
    hook_deny "$msg"
}

# _deny_reader <form>: deny a reader of a secret-bearing file.
_deny_reader() {
    local msg="SECRET-PATH BLOCK: '$1' would print a secret-bearing file into context. Have a script write only the"
    msg+=" non-secret parts to \$CLAUDE_TEMP_DIR instead; ${VAULT_HINT}."
    hook_deny "$msg"
}

# _deny_copier <source>: deny a copy out of a secret path.
_deny_copier() {
    local msg="SECRET-PATH BLOCK: copying '$1' would put a secret-bearing file where it can be read into context."
    msg+=" Have a script consume it in place instead; ${VAULT_HINT}."
    hook_deny "$msg"
}

SSH_REMEDY="Write the commands to a file in \$CLAUDE_TEMP_DIR with the Write tool and run"
SSH_REMEDY+=" 'ssh <host> bash -s < <file>' with the file's literal path (not \$CLAUDE_TEMP_DIR) instead."

# _deny_shell <form> [<remedy>]: deny a shell or command runner given a command string; <remedy> replaces the default
# remedy sentence.
_deny_shell() {
    local msg="SHELL-STRING BLOCK: '$1' runs a command string this hook cannot screen. "
    if [[ -n "${2:-}" ]]; then
        msg+="$2"
    else
        msg+="Write the commands to a script in \$CLAUDE_TEMP_DIR with the Write tool and run it with 'bash <file>'"
        msg+=" instead."
    fi
    hook_deny "$msg"
}

# _deny_fed <form> [<remedy>]: _deny_shell for a shell fed by a pipe or redirection; a here-document in the stage adds
# the heredoc note, except when <remedy> is the ssh one, whose command takes a file and no here-document.
_deny_fed() {
    if (( shd )) && [[ -z "${2:-}" ]]; then
        # shellcheck disable=SC2034  # read by hook_deny
        HOOK_DENY_NOTE="$HEREDOC_DENY_NOTE"
    fi
    _deny_shell "$@"
}

# _plain_word <s>: 0 if <s> is one plain word (a program or path) with no whitespace or shell syntax.
_plain_word() {
    [[ -n "$1" && "$1" != *[!A-Za-z0-9_./~+@%,:=-]* ]]
}

# _git_cmd_value <form> <value>: deny a value run as a shell command (by git, ssh or a pager reader) unless it is empty
# (which turns the command off) or one plain word, which names a program or script as the shell-string remedy does;
# deny that word too when it names an environment dump (env, printenv, export, set, declare), which needs no argument,
# or a shell or interpreter (a versioned name too: python3.12), which runs the script its stdin holds.
_git_cmd_value() {
    local b c
    if [[ -z "$2" ]]; then
        return 0
    fi
    if ! _plain_word "$2"; then
        _deny_shell "$1"
    fi
    b="${2##*/}"
    if (( ${#b} <= 16 )) && [[ "$b" == *[ABCDEFGHIJKLMNOPQRSTUVWXYZ]* ]]; then
        ascii_lower "$b"
        b="$ASCII_LOWER"
    fi
    if [[ "$b" == [a-z]*[0-9.] && "$b" =~ $VER_NAME_RE ]]; then
        b="${BASH_REMATCH[1]}"
    fi
    case "$b" in
        fish|tcsh|csh|tclsh|expect|pwsh|powershell|busybox) _deny_shell "$1 $2" ;;
    esac
    if [[ "$b" != *[!a-z0-9]* ]]; then
        c="_nm_$b"
        c="${!c:-}"
        if [[ "$c" == [HK] ]]; then
            _deny_shell "$1 $2"
        fi
        if [[ "$c" != D ]]; then
            c="_cp_$b"
            c="${!c:-}"
        fi
        if [[ "$c" == [DEes] ]]; then
            _deny_env "$1 $2"
        fi
    fi
}

# _cmd_var_word <word>: a variable git, ssh or a pager reader runs as a shell command passes only as one plain word.
# A GIT_ one is screened wherever it is set, as only git reads it; PAGER, EDITOR, VISUAL and SSH_ASKPASS, common as
# data, only where they are assigned: before the command word, after env (anywhere in the stage, as an unknown wrapper
# may run it: gev), export or declare, or in a wrapper's words (sudo takes assignments). A GIT_CONFIG_KEY_n alias or
# help.autocorrect is denied, as the hook cannot pair the key with its value. git's ext remote helper runs its address
# as a command: it is denied in any word of a git stage (an address, a setting holding one, a url.<base>.insteadOf key
# naming one) and in a GIT_CONFIG_ setting.
_cmd_var_word() {
    local w="$1" v
    if [[ "$w" == */[Ee][Nn][Vv] ]]; then
        gev=1
    fi
    if [[ "$w" == *=* && ( "${w%%=*}" == *[\$\`\\\{\*\?\[]* || "$wmk" == *n* ) ]]; then
        rr_gitps=1
    fi
    if [[ "$w" == [A-Z]*=* ]]; then
        v="${w%%=*}"
        v="${v%+}"
        if [[ "$v" == GIT_* ]] || (( ! cs || gev )) || [[ "$act" == *[ED]* || "$sf" == *A* ]]; then
            case "$v" in
                GIT_PAGER|PAGER|GIT_EDITOR|EDITOR|VISUAL|GIT_SEQUENCE_EDITOR|GIT_SSH_COMMAND|GIT_SSH|GIT_ASKPASS|\
                SSH_ASKPASS|GIT_EXTERNAL_DIFF|GIT_PROXY_COMMAND|GIT_CONFIG_VALUE_[0-9]*)
                    _git_cmd_value "$v" "${w#*=}" ;;
                GIT_CONFIG_KEY_[0-9]*)
                    if [[ "${w#*=}" == [Aa][Ll][Ii][Aa][Ss].* ]]; then
                        _deny_shell "$v alias"
                    fi
                    _git_cfg_key "$v" "${w#*=}" "${w#*=}" ;;
                GIT_CONFIG_PARAMETERS)
                    _deny_shell GIT_CONFIG_PARAMETERS ;;
                GIT_*PATHSPECS)
                    rr_gitps=1 ;;
            esac
        fi
    fi
    if { (( sgp )) || [[ "$act" == *[GI]* || "$w" == GIT_CONFIG_* ]]; } && [[ "$w" == *[Ee][Xx][Tt]::* ]]; then
        _deny_shell "git ext:: address"
    fi
}

# _git_cfg_key <form> <key> <setting>: deny a help.autocorrect setting (key, or key=value) that runs a mistyped
# subcommand as the one git guesses, whose options no walk reads; with no value, -c sets the key true.
_git_cfg_key() {
    local k="$2" v=true
    if [[ "$3" == *=* ]]; then
        v="${3#*=}"
    fi
    if [[ "$k" != [Hh][Ee][Ll][Pp].[Aa][Uu][Tt][Oo][Cc][Oo][Rr][Rr][Ee][Cc][Tt] ]]; then
        return 0
    fi
    case "$v" in
        ''|0|[Nn][Ee][Vv][Ee][Rr]|[Ss][Hh][Oo][Ww]|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff]) ;;
        *) _deny_shell "$1 $k" ;;
    esac
}

# _git_cmd_start <subcommand>: start the I walk (_git_cmd_word) when the git subcommand, folded to lower case as a
# case-insensitive file system runs it, has options that run a shell command.
_git_cmd_start() {
    gis="$1"
    if (( ${#gis} <= 64 )) && [[ "$gis" == *[ABCDEFGHIJKLMNOPQRSTUVWXYZ]* ]]; then
        ascii_lower "$gis"
        gis="$ASCII_LOWER"
    fi
    case "$gis" in
        rebase|difftool|filter-branch|bisect|submodule|fetch|pull|ls-remote|fetch-pack|clone|push|send-pack|\
        archive|grep|send-email)
            if [[ "$act" != *I* ]]; then act+=I; fi
            giv=""
            gie=0
            gib=0 ;;
    esac
}

# _git_cmd_word <word>: the I walk, over the words after a git subcommand with options that run a shell command (gis).
# giv holds the form whose value is the next word (- for a value that runs nothing), gie marks a --, and gib marks
# bisect's run or submodule's foreach read: the next operand starts the command they run (sf A), which foreach first
# hands the shell as a string. Long options match by any prefix, as git and Getopt::Long take an abbreviation; a short
# bundle stops at the first letter that takes a value.
_git_cmd_word() {
    local w="$1" lo c rest cl="" clo="" cx="" sc="" so="" sv="" sg=""
    if [[ -n "$giv" ]]; then
        if [[ "$giv" != - ]]; then
            _git_cmd_value "$giv" "$w"
        fi
        giv=""
        return 0
    fi
    case "$gis" in
        bisect|submodule)
            if (( gib )); then
                if [[ "$gis" == submodule ]]; then
                    if [[ "$w" == -* ]]; then
                        return 0
                    fi
                    _git_cmd_value "git submodule foreach" "$w"
                fi
                if [[ "$sf" != *A* ]]; then sf+=A; fi
                act="${act//I/}"
            elif [[ "$gis$w" == bisectrun || "$gis$w" == submoduleforeach ]]; then
                gib=1
            elif [[ "$gis" == bisect || "$w" != -* ]]; then
                act="${act//I/}"
            fi
            return 0 ;;
    esac
    # Getopt::Long, send-email's parser, also reads a long option behind + or a single dash.
    if [[ "$gis" == send-email ]]; then
        case "$w" in
            +?*) w="--${w#+}" ;;
            -[!-]?*) w="-$w" ;;
        esac
    fi
    if (( gie )) || [[ "$w" != -?* ]]; then
        return 0
    fi
    if [[ "$w" == -- ]]; then
        gie=1
        return 0
    fi
    case "$gis" in
        rebase) cl="exec"; sc=x; sv=sX; sg=SrC ;;
        difftool) cl=extcmd; sc=x ;;
        filter-branch)
            cl="setup env-filter tree-filter index-filter parent-filter msg-filter commit-filter tag-name-filter" ;;
        fetch|pull) cl=upload-pack ;;
        ls-remote|fetch-pack) cl="upload-pack exec" ;;
        clone) cl="upload-pack config"; sc=uc ;;
        push|send-pack) cl="receive-pack exec" ;;
        archive) cl="exec" ;;
        grep) clo=open-files-in-pager; so=O; sv=efABCm ;;
        send-email) cl="sendmail-cmd to-cmd cc-cmd header-cmd"; cx=" to cc " ;;
    esac
    if [[ "$w" == --* ]]; then
        lo="${w#--}"
        lo="${lo%%=*}"
        if (( ${#lo} <= 64 )) && [[ "$lo" == *[ABCDEFGHIJKLMNOPQRSTUVWXYZ]* ]]; then
            ascii_lower "$lo"
            lo="$ASCII_LOWER"
        fi
        if [[ "$cx" == *" $lo "* ]]; then
            return 0
        fi
        for c in $cl $clo; do
            if [[ "$c" == "$lo"* ]]; then
                if [[ "$w" == *=* ]]; then
                    _git_cmd_value "git $gis --$c" "${w#*=}"
                elif [[ "$c" != "$clo" ]]; then
                    giv="git $gis --$c"
                fi
                return 0
            fi
        done
        return 0
    fi
    rest="${w#-}"
    while [[ -n "$rest" ]]; do
        c="${rest:0:1}"
        rest="${rest:1}"
        if [[ "$sc" == *"$c"* ]]; then
            if [[ -n "$rest" ]]; then
                _git_cmd_value "git $gis -$c" "$rest"
            else
                giv="git $gis -$c"
            fi
            return 0
        elif [[ "$so" == *"$c"* ]]; then
            if [[ -n "$rest" ]]; then
                _git_cmd_value "git $gis -$c" "$rest"
            fi
            return 0
        elif [[ "$sv" == *"$c"* ]]; then
            if [[ -z "$rest" ]]; then
                giv=-
            fi
            return 0
        elif [[ "$sg" == *"$c"* ]]; then
            return 0
        fi
    done
    return 0
}

# _deny_env <form>: deny a command that prints the environment.
_deny_env() {
    hook_deny "SECRET-ENV BLOCK: '$1' prints the environment, secret-bearing variables included, into context."
}

# _pcwd: set PCWD, once, to the payload's cwd, or the hook's own working directory when the payload has none.
_pcwd() {
    if [[ -z "$PCWD" ]]; then
        PCWD=$(hook_field '.cwd')
        PCWD="${PCWD:-$PWD}"
    fi
}

# _deny_probe <form> <hits>: deny a recursive reader whose root holds a secret file.
_deny_probe() {
    local msg="SECRET-PROBE BLOCK: '$1' prints the contents of files under a directory that holds secret-bearing files"
    msg+=" ($2). Search a narrower directory, leave them out with --include or --exclude, or list names only (-l);"
    msg+=" ${VAULT_HINT}."
    hook_deny "$msg"
}

# _deny_wide <form> <root>: deny a recursive reader rooted at or above $HOME or the vault.
_deny_wide() {
    local msg="SECRET-PROBE BLOCK: '$1' reads every file under '$2', which is at or above \$HOME or the secret vault"
    msg+=" (~/.aws, ~/.ssh and the vault sit below it). Search a narrower directory."
    hook_deny "$msg"
}

# _hold_probe <form> <why>: hold an ask for a recursive reader whose root could not be checked.
_hold_probe() {
    local msg="SECRET-PROBE ASK: '$1' prints file contents under a directory the hook could not check ($2). Approve"
    msg+=" it only if no secret-bearing file is under that directory."
    hook_hold_ask "$msg"
}

# _hold_wild: hold an ask for a command with more wildcard operands than the hook expands.
_hold_wild() {
    local msg="SECRET-SCAN ASK: this command has more wildcard operands than the hook expands (64). Approve it only"
    msg+=" if none can match a secret-bearing file."
    hook_hold_ask "$msg"
}

# _rr_has_glob <word>: 0 if the shell expands <word> as a pattern: it holds * ? [ or a {…,…} or {…..…} brace.
_rr_has_glob() {
    [[ "$1" == *[\*\?\[]* || "$1" == *'{'*','*'}'* || "$1" == *'{'*'..'*'}'* ]]
}

# _rr_glob_dir <word>: set RR_GLOB_DIR to the directory part of <word> before its first component holding a pattern
# character: . when that is its first component, / when it is the first of an absolute word.
_rr_glob_dir() {
    local pre="${1%%[\*\?\[\{]*}"
    if [[ "$pre" == */* ]]; then
        pre="${pre%/*}"
        RR_GLOB_DIR="${pre:-/}"
    else
        RR_GLOB_DIR=.
    fi
}

# _rr_hold <form> <why>: hold an ask for a probe walk; in a names-only walk, queue it for the reader after xargs.
_rr_hold() {
    if (( RR_LIST )); then
        pipe_find+="a0"$'\x1f'"$1"$'\x1f'"$2"$'\x1e'
    else
        _hold_probe "$1" "$2"
    fi
}

# _rr_dir <form> <kind> <abs> [<include> <exclude> <exclude-dir>]: probe the directory <abs>, denying it when it is at
# or above $HOME or the vault; in a names-only walk, queue it for the reader after xargs.
_rr_dir() {
    if (( RR_LIST )); then
        if [[ "$2" == findL ]]; then
            pipe_find+="r1"$'\x1f'"$1"$'\x1f'"$3"$'\x1e'
        else
            pipe_find+="r0"$'\x1f'"$1"$'\x1f'"$3"$'\x1e'
        fi
        return 0
    fi
    if probe_root_too_wide "$3"; then
        _deny_wide "$1" "$3"
    fi
    # An rg root waits for _rr_rg_roots to learn whether .gitignore ignores it.
    if (( RR_RGCOL )) && [[ "$2" == git ]]; then
        rrgl+="$3"$'\x1e'
        return 0
    fi
    if ! probe_add "$2" "$3" "$1" "${4:-}" "${5:-}" "${6:-}"; then
        _hold_probe "$1" "it searches more than $PROBE_MAX_ROOTS directories"
    fi
}

# _rr_root <form> <kind> <operand> [<include> <exclude> <exclude-dir>]: resolve a reader's operand against the payload's
# cwd and probe it when it is a directory. A pattern operand has each directory it matches probed; it stands for the
# directory before its first pattern component instead for ** and braces (whose matches bash cannot list), a git
# pathspec (which matches at any depth), a recursive reader's wildcard-only operand (RR_DEEP), or more than 64 matches.
# A secret path is denied as a reader; a root naming a variable, or resolved after the command changes directory, holds
# an ask. The directory standing for a pattern's matches is listed following links: each match, a link included, is an
# operand the reader is given. Returns 0 when the operand names an existing path or was held, else 1.
_rr_root() {
    local o="$3" m c sub=0 k="$2" grc
    if (( ${#o} > 4096 )); then
        return 1
    fi
    _pcwd
    if (( ! RR_LIT )) && _rr_has_glob "$o"; then
        _rr_glob_dir "$o"
        c="${o##*/}"
        if [[ "$o" != *'**'* && "$o" != *'{'* && "$1" != git* && "$o" != *'$'* && "$o" != '~'[!/]* ]] \
                && { (( ! ecd )) || [[ "$o" == /* ]]; }; then
            sub=1
        fi
        # A recursive reader's wildcard-only operand (grep -r KEY *) stands for its whole directory.
        if (( sub && RR_DEEP )) && [[ -n "$c" && "$c" != *[!\*\?]* ]] && ! _rr_has_glob "${o%"$c"}"; then
            sub=0
        fi
        if (( sub )); then
            if (( _wild_n >= 64 )); then
                _hold_wild
                return 0
            fi
            _wild_n=$(( _wild_n + 1 ))
            # shellcheck disable=SC2088  # a literal ~ prefix is matched here, then expanded by hand
            case "$o" in
                /*) m="$o" ;;
                '~/'*) glob_quote "$HOME"; m="$GLOB_QUOTED/${o:2}" ;;
                *) glob_quote "$PCWD"; m="$GLOB_QUOTED/$o" ;;
            esac
            grc=0
            glob_dirs "$m/" || grc=$?
            if (( grc == 3 )); then
                _rr_hold "$1" "its pattern '$3' could not be expanded in the time the hook has"
                return 0
            fi
            m="$GLOB_DIRS"
            if [[ -z "$m" ]] || _rr_glob_dirs "$1" "$2" "$m" "${4:-}" "${5:-}" "${6:-}"; then
                return 0
            fi
        fi
        o="$RR_GLOB_DIR"
        if [[ "$k" == find ]]; then
            k=findL
        fi
    fi
    if (( ecd )) && [[ "$o" != /* && "$o" != '~'* ]]; then
        _rr_hold "$1" "the command changes its directory first"
        return 0
    fi
    if ! norm_path "$o" "$PCWD"; then
        _rr_hold "$1" "its root '$3' names a variable or another user's home"
        return 0
    fi
    if (( ! RR_LIST )); then
        name_fold "$NORM_PATH"
        if path_is_secret "$NAME_FOLD"; then
            _deny_reader "$1 $3"
        fi
    fi
    if [[ ! -d "$NORM_PATH" ]]; then
        if [[ -e "$NORM_PATH" ]]; then
            return 0
        fi
        return 1
    fi
    _rr_dir "$1" "$k" "$NORM_PATH" "${4:-}" "${5:-}" "${6:-}"
    return 0
}

# _rr_glob_dirs <form> <kind> <list> [<include> <exclude> <exclude-dir>]: probe each directory in <list> (compgen's
# newline-separated matches of a pattern ending in /). Returns 1, so the caller probes the directory before the pattern
# instead, when there are more than 64 or a line names no directory (a name holding a newline).
_rr_glob_dirs() {
    local rest="$3" d n=0
    while [[ -n "$rest" ]]; do
        d="${rest%%$'\n'*}"
        if [[ "$rest" == *$'\n'* ]]; then rest="${rest#*$'\n'}"; else rest=""; fi
        n=$(( n + 1 ))
        if (( n > 64 )) || ! norm_path "$d" / literal || [[ ! -d "$NORM_PATH" ]]; then
            return 1
        fi
    done
    rest="$3"
    while [[ -n "$rest" ]]; do
        d="${rest%%$'\n'*}"
        if [[ "$rest" == *$'\n'* ]]; then rest="${rest#*$'\n'}"; else rest=""; fi
        norm_path "$d" / literal || :
        if (( ! RR_LIST )); then
            name_fold "$NORM_PATH"
            if path_is_secret "$NAME_FOLD"; then
                _deny_reader "$1 $NORM_PATH"
            fi
        fi
        _rr_dir "$1" "$2" "$NORM_PATH" "${4:-}" "${5:-}" "${6:-}"
    done
    return 0
}

# _rr_cand <form> <kind> <word> [<include>]: probe a word that may be a root under one reading of the command (an option
# value one implementation takes and another does not, the pattern after such a value, a find expression word bfs may
# take for a root): only a literal path naming an existing directory.
_rr_cand() {
    if (( ${#3} > 4096 )) || [[ "$3" == *'$'* ]] || _rr_has_glob "$3"; then
        return 0
    fi
    if (( ecd )) && [[ "$3" != /* && "$3" != '~'* ]]; then
        return 0
    fi
    _pcwd
    if norm_path "$3" "$PCWD" && [[ -d "$NORM_PATH" ]]; then
        _rr_dir "$1" "$2" "$NORM_PATH" "${4:-}"
    fi
    return 0
}

# _rr_xrep <operand>: 0 if, after xargs or parallel, <operand> holds the replacement string (xrep), which the input
# fills in (after parallel, any brace). RR_XDIR is then the literal directory before the component holding it, empty
# when that is the first component (the working directory's probe covers it), or ! when the filled-in operand may
# reach past that directory: the component holds more than the string ({}. filled with . is ..), a .. segment, the
# string or a brace follows it, or the input may hold a .. segment (pdd) and lands under another directory.
_rr_xrep() {
    local p r c
    if [[ -z "$xrep" || "$sf" != *X* ]]; then
        return 1
    fi
    # Finding the string in the operand costs their lengths' product: past 4096 characters either way, it asks.
    if (( ${#1} > 4096 || ${#xrep} > 4096 )); then
        RR_XDIR='!'
        return 0
    fi
    if [[ "$1" != *"$xrep"* ]]; then
        if (( xbr )) && [[ "$1" == *'{'* ]]; then
            RR_XDIR='!'
            return 0
        fi
        return 1
    fi
    p="${1%%"$xrep"*}"
    r="${1:${#p}+${#xrep}}"
    RR_XDIR=""
    c="$p"
    if [[ "$p" == */* ]]; then
        RR_XDIR="${p%/*}"
        RR_XDIR="${RR_XDIR:-/}"
        c="${p##*/}"
    fi
    if [[ -n "$c" || "$r" == [!/]* || "$r" == *"$xrep"* || "/$r/" == */../* ]] \
            || { (( xbr )) && [[ "$1" == *'{'*'{'* ]]; } || { [[ -n "$RR_XDIR" ]] && (( pdd )); }; then
        RR_XDIR='!'
    fi
    return 0
}

# The walks ask git at most RR_GIT_MAX times per run (a command can hold thousands of stages, and each call costs
# milliseconds); past that they answer as if git said the widest thing. rr_gcache holds each directory's submodule
# answer, rr_rgkey and rr_rgok the last ignore answer.
RR_GIT_MAX=32
rr_gitn=0
rr_gcache=$'\x1e'
rr_rgkey=""
rr_rgok=""

# _rr_subrec <dir>: 0 if git grep in <dir> also searches submodules (submodule.recurse is set), or git cannot be asked.
_rr_subrec() {
    local a
    case "$rr_gcache" in
        *$'\x1e'"$1"$'\x1f'1$'\x1e'*) return 0 ;;
        *$'\x1e'"$1"$'\x1f'0$'\x1e'*) return 1 ;;
    esac
    if (( rr_gitn >= RR_GIT_MAX )); then
        return 0
    fi
    rr_gitn=$(( rr_gitn + 1 ))
    a=$(git -C "$1" config --type=bool --get submodule.recurse 2>/dev/null) || a=""
    if [[ "$a" == true ]]; then
        rr_gcache+="$1"$'\x1f'1$'\x1e'
        return 0
    fi
    rr_gcache+="$1"$'\x1f'0$'\x1e'
    return 1
}

# _rr_rg_roots <form>: probe the rg roots collected in rrgl. rg searches a root it is named even when .gitignore ignores
# it, so only a root one git check-ignore call reports as not ignored is listed by git; the others, or all when git
# cannot answer (no repository, a root outside it, a name it quotes), are listed in full.
_rr_rg_roots() {
    local rest r out="" st=0 line ok=$'\x1e' rs=$'\x1e' nl=$'\n'
    if [[ "$rrgl" == "$rr_rgkey" ]]; then
        ok="$rr_rgok"
    elif (( rr_gitn < RR_GIT_MAX )) && [[ "$rrgl" != *$'\n'* ]]; then
        rr_gitn=$(( rr_gitn + 1 ))
        r="${rrgl%"$rs"}"
        out=$(git -C "${rrgl%%"$rs"*}" check-ignore -v -n --stdin <<<"${r//"$rs"/$nl}" 2>/dev/null) || st=$?
        if (( st == 0 || st == 1 )); then
            while [[ -n "$out" ]]; do
                line="${out%%$'\n'*}"
                if [[ "$out" == *$'\n'* ]]; then out="${out#*$'\n'}"; else out=""; fi
                if [[ "$line" == ::$'\t'* ]]; then
                    ok+="${line#*$'\t'}"$'\x1e'
                fi
            done
        fi
        rr_rgkey="$rrgl"
        rr_rgok="$ok"
    fi
    rest="$rrgl"
    while [[ -n "$rest" ]]; do
        r="${rest%%$'\x1e'*}"
        rest="${rest#*$'\x1e'}"
        if [[ "$ok" == *$'\x1e'"$r"$'\x1e'* ]]; then
            _rr_dir "$1" git "$r"
        else
            _rr_dir "$1" find "$r"
        fi
    done
}

# _many_slashes <word>: 0 if <word> holds more than 256 slashes. It is split once on / (bash 3.2's pattern substitution
# is quadratic in the word's length).
_many_slashes() {
    local nf=0 IFS=/
    local -a f=()
    if [[ "$-" == *f* ]]; then
        nf=1
    fi
    set -f
    # shellcheck disable=SC2206  # split on / with pathname expansion off
    f=($1)
    if (( ! nf )); then
        set +f
    fi
    (( ${#f[@]} > 257 ))
}

# _xd_word <word>: record in wout the directory <word> names outside the payload's cwd (for a glob, the literal
# directory before its pattern), or the word itself when the hook cannot resolve it (it names a variable or another
# user's home, so its probe holds an ask), for a recursive reader after xargs. A word of more than 256 slashes, a
# pattern that may match .., or a pattern followed by a .. segment, is not resolved either, and holds an ask. At most
# 64 per stage; past that, one ! entry holds an ask.
# bash before 5.2 matches .. with any component that starts with . and holds a pattern character (.*, .?, ..*):
# "/$w" =~ $DOT_PAT_RE tests every component of a word.
DOT_PAT_RE='/\.[^/]*[][*?]'
_xd_word() {
    local w="$1" r
    if (( wxn >= 64 )); then
        if [[ "$wout" != '!'* ]]; then
            wout="!0"$'\x1f'"$1"$'\x1f\x1e'"$wout"
        fi
        return 0
    fi
    if _many_slashes "$w"; then
        wxn=$(( wxn + 1 ))
        wout+="a0"$'\x1f'echo$'\x1f'"an earlier stage names a path of more than 256 slashes"$'\x1e'
        return 0
    fi
    # A match of .. climbs out of the directory.
    if [[ "/$w" =~ $DOT_PAT_RE ]]; then
        wxn=$(( wxn + 1 ))
        wout+="a0"$'\x1f'echo$'\x1f'"an earlier stage names a pattern that may match .."$'\x1e'
        return 0
    fi
    _pcwd
    if [[ -z "$PCWDN" ]]; then
        if norm_path "$PCWD" / literal; then PCWDN="$NORM_PATH"; else PCWDN="$PCWD"; fi
    fi
    if _rr_has_glob "$w"; then
        # A .. after the first pattern component climbs out of the directory the pattern stands for (*/../..).
        r="${w%%[\*\?\[\{]*}"
        r="${w:${#r}}"
        if [[ "/$r/" == */../* ]]; then
            wxn=$(( wxn + 1 ))
            wout+="a0"$'\x1f'echo$'\x1f'"an earlier stage names a pattern followed by .."$'\x1e'
            return 0
        fi
        _rr_glob_dir "$w"
        w="$RR_GLOB_DIR"
    fi
    if ! norm_path "$w" "$PCWD"; then
        wxn=$(( wxn + 1 ))
        wout+="r0"$'\x1f'"$1"$'\x1f'"$1"$'\x1e'
        return 0
    fi
    if [[ -d "$NORM_PATH" && "$NORM_PATH" != "$PCWDN" && "$NORM_PATH" != "$PCWDN"/* ]] \
            && [[ "$wout" != *$'\x1f'"$NORM_PATH"$'\x1e'* ]]; then
        wxn=$(( wxn + 1 ))
        wout+="r0"$'\x1f'"$1"$'\x1f'"$NORM_PATH"$'\x1e'
    fi
    return 0
}

# _rr_exists <path>: 0 if <path> names an existing path, or cannot be resolved here because the command changes
# directory first.
_rr_exists() {
    _pcwd
    if (( ecd )) && [[ "$1" != /* && "$1" != '~'* ]]; then
        return 0
    fi
    norm_path "$1" "$PCWD" && [[ -e "$NORM_PATH" ]]
}

# Long options that take a value, space-separated with a space at each end. grep: every grep the hook may meet (GNU,
# BSD, and ugrep, the Bash tool's grep), and the subset GNU and BSD grep also take abbreviated (ugrep takes none); rg,
# which takes none abbreviated; git grep, which does.
_RR_GREP_VAL=' after-context before-context binary-files context devices directories exclude exclude-dir exclude-from'
_RR_GREP_VAL+=' file include include-dir include-from label max-count regexp group-separator colors colours delay'
_RR_GREP_VAL+=' depth encoding exclude-fs filter filter-magic-label format from glob iglob include-fs jobs range'
_RR_GREP_VAL+=' min-line max-line file-magic min-count max-files max-size min-size neg-regexp file-extension replace'
_RR_GREP_VAL+=' context-separator file-type zmax and andnot not '
_RR_GREP_ABBR=' after-context before-context binary-files context devices directories exclude exclude-dir exclude-from'
_RR_GREP_ABBR+=' file include include-dir label max-count regexp group-separator '
_RR_RG_VAL=' regexp file pre pre-glob dfa-size-limit encoding engine max-count regex-size-limit threads glob iglob'
_RR_RG_VAL+=' ignore-file max-depth maxdepth max-filesize type type-not type-add type-clear after-context'
_RR_RG_VAL+=' before-context color colors context context-separator field-context-separator field-match-separator'
_RR_RG_VAL+=' hostname-bin hyperlink-format max-columns path-separator replace sort sortr generate '
_RR_GIT_VAL=' max-depth context before-context after-context threads max-count '
# The value options whose value names a file or a program, so it is no pattern.
_RR_FILE_VAL=' file exclude-from include-from from filter ignore-file pre hostname-bin '
# The flags (options taking no value) of each tool; a bare long option in neither table may take the next word as its
# value, so it voids the pattern roles.
_RR_GREP_FLAGS=' extended-regexp fixed-strings basic-regexp perl-regexp ignore-case no-ignore-case invert-match'
_RR_GREP_FLAGS+=' word-regexp line-regexp count color colour files-with-matches files-without-match only-matching quiet'
_RR_GREP_FLAGS+=' silent no-messages byte-offset with-filename no-filename line-number line-buffered null null-data'
_RR_GREP_FLAGS+=' text initial-tab recursive dereference-recursive binary version help '
_RR_RG_FLAGS=' hidden no-ignore no-ignore-vcs no-ignore-dot no-ignore-parent no-ignore-global no-ignore-files'
_RR_RG_FLAGS+=' no-ignore-exclude follow ignore-case smart-case case-sensitive fixed-strings word-regexp line-regexp'
_RR_RG_FLAGS+=' line-number no-line-number count count-matches files files-with-matches files-without-match json'
_RR_RG_FLAGS+=' vimgrep heading no-heading multiline multiline-dotall pcre2 invert-match only-matching quiet'
_RR_RG_FLAGS+=' with-filename no-filename column no-column trim stats sort-files unrestricted no-messages null'
_RR_RG_FLAGS+=' null-data text binary search-zip crlf byte-offset passthru pretty no-config one-file-system version'
_RR_RG_FLAGS+=' help type-list pcre2-version '
_RR_GIT_FLAGS=' line-number ignore-case word-regexp invert-match count name-only files-with-matches'
_RR_GIT_FLAGS+=' files-without-match full-name extended-regexp fixed-strings perl-regexp basic-regexp cached untracked'
_RR_GIT_FLAGS+=' no-index recurse-submodules heading break show-function function-context all-match quiet column'
_RR_GIT_FLAGS+=' only-matching null no-color color text textconv no-textconv exclude-standard no-exclude-standard and'
_RR_GIT_FLAGS+=' or not '

# _rr_start <reader>: begin the probe walk of a grep, egrep, fgrep, ggrep, ugrep, ug, rg, git grep, git diff or diff.
# The first reader of a stage owns its walk: a later reader-named word is an operand of it. A reader inside find -exec
# is walked too (its own operands are roots besides find's); its walk ends with the -exec.
_rr_start() {
    if [[ "$act" == *r* ]]; then
        return 0
    fi
    act+=r
    rrex=0
    if [[ "$act" == *g* ]]; then
        rrex=1
        if (( fxd )); then
            rrex=2
        fi
    fi
    rrO=0
    rrd="$1"
    rrn="$1"
    case "$1" in
        egrep|fgrep|ggrep|ugrep|ug) rrn="grep" ;;
    esac
    rrec=0
    rrl=0
    rrnm=0
    rrf=0
    rrw=0
    rre=0
    rrv=""
    rrdd=0
    rrsep=0
    rrsup=0
    rrmv=0
    rrops=""
    rron=0
    rrmn=0
    rrinc=""
    rrexc=""
    rrxd=""
    rrxo=0
    rrvi=0
    rrve=0
    rrvx=0
    rrnoi=0
    rrunt=0
    rrnoex=0
    rrsub=0
    rrnx=0
    rrfl=0
    rrask=""
    rrcd=""
    rrvf=0
    rrunk=$rrasg
    rrdyn=0
    # Roles (P, F) are given only when the tool is the stage's first command word: a wrapper's option value can look
    # like the command.
    case "$rrn" in
        grep|rg) rrown=$cw1 ;;
        'git grep') rrown=$gown ;;
        *) rrown=0 ;;
    esac
    case "$rrn" in
        rg)
            rrec=1
            if (( rr_rgenv )); then
                rrw=1
                rrf=1
                rrmv=1
            fi ;;
        'git grep'|'git diff')
            rrec=1
            rrcd="$gcd" ;;
        grep)
            # ug reads a config file, and GREP_OPTIONS adds options the walk cannot see.
            if (( rr_grepenv )) || [[ "$1" == ug ]]; then
                rrec=1
                rrf=1
                rrmv=1
                rrvi=1
                rrve=1
                rrvx=1
            fi ;;
    esac
}

# _rr_op <tag> <word>: record a positional word of the walked reader (tag w), or a word that is an option's value under
# one reading only (tag m). Positional words after git's -- are tagged W. Each entry is the tag, the word's glob marker
# (rrg, 1 when its glob characters are all quoted, 2 when a brace expanded to it) and the word. At most 65 positional
# and 64 m words are kept; the counts go on.
_rr_op() {
    local t="$1"
    if [[ "$t" == m ]]; then
        rrmn=$(( rrmn + 1 ))
        if (( rrmn > 64 )); then
            return 0
        fi
    else
        rron=$(( rron + 1 ))
        if (( rron > 65 )); then
            return 0
        fi
        if (( rrsep )); then
            t=W
        fi
    fi
    rrops+="$t$rrg$2"$'\x1e'
}

# _rr_inc <glob>, _rr_exc <glob>, _rr_xdir <glob>: record an --include, --exclude or --exclude-dir value. GNU and BSD
# grep let the last matching --include or --exclude win (GNU also searches a file neither matches when an --exclude
# came first), and BSD grep matches an --include against the whole path; so an --include after an --exclude drops the
# excludes before it and every include, and only a plain glob narrows (an --include only as *name or name). A glob that
# cannot narrow voids its kind: ugrep reads a ! in one as including the file again.
_rr_inc() {
    if (( rrxo )); then
        rrvi=1
        rrexc=""
        rrxo=0
    fi
    if probe_glob_plain "$1" && [[ "${1#\*}" != *[\*\?]* ]]; then
        rrinc+="$1"$'\x1f'
    else
        rrvi=1
    fi
}
_rr_exc() {
    rrxo=1
    if probe_glob_plain "$1"; then
        rrexc+="$1"$'\x1f'
    else
        rrve=1
    fi
}
_rr_xdir() {
    if probe_glob_plain "$1"; then
        rrxd+="$1"$'\x1f'
    else
        rrvx=1
    fi
}

# _rr_short <word>: read a short-option bundle of the walked reader: its recursive, names-only, follow and widening
# letters, then the first letter that takes a value (the rest of the bundle, or the next word when the bundle ends). A
# letter one grep reads as taking a value and another as a flag (amb, oamb) leaves both readings open: later letters
# still recurse or follow but no longer list names only, and a value it may take is an m word.
_rr_short() {
    local b="${1#-}" c vals="" amb="" oamb="" opt="" rec="" names="" follow="" wide="" a=0 noval=0
    case "$rrn" in
        grep) vals=ABCDdefmgKNt; amb=JMOX; oamb=Z; opt=Q; rec=rR123456789; names=lLcqV; follow=RS ;;
        rg) vals=ABCEMTdefgjmrt; names=lcqVh; follow=L; wide=u ;;
        'git grep') vals=ABCefm; opt=O; names=lLcq ;;
        # diff's value letters end the bundle, but their values stay operands to probe.
        diff) vals=xXIFLSDCUW; rec=r; names=q; noval=1 ;;
        *) return 0 ;;
    esac
    while [[ -n "$b" ]]; do
        c="${b:0:1}"
        b="${b:1}"
        if [[ "$rec" == *"$c"* ]]; then rrec=1; fi
        if [[ "$follow" == *"$c"* ]]; then rrf=1; fi
        if [[ "$wide" == *"$c"* ]]; then rrw=1; fi
        if [[ "$names" == *"$c"* ]] && (( ! a && ! rrsup )); then
            rrl=1
            # -l and -L print file names only (rrnm), which a later stage may take as paths.
            if [[ "$rrn" == grep && "$c" == [lL] ]] || [[ "$rrn" == rg && "$c" == l ]]; then rrnm=1; fi
        fi
        # ugrep's -g -O -t -M add file globs, extensions, types and magic to the includes.
        if [[ "$rrn" == grep && "$c" == [gOtM] ]]; then rrvi=1; fi
        if [[ "$vals" == *"$c"* ]]; then
            if (( noval )); then
                return 0
            fi
            if [[ "$c" == d && "$rrn" == grep && "$b" == recurse ]]; then rrec=1; fi
            if (( a )); then
                if [[ "$c" == e || "$c" == f ]]; then rrmv=1; fi
                if [[ -z "$b" ]]; then rrv=m; fi
            else
                if [[ "$c" == e || "$c" == f ]]; then rre=1; fi
                if [[ -z "$b" ]]; then
                    if [[ "$c" == d && "$rrn" == grep ]]; then
                        rrv=d
                    else
                        rrv=v
                        if [[ "$c" == f ]]; then rrvf=1; fi
                    fi
                elif [[ "$c" != f ]]; then
                    RR_ROLE=P
                fi
            fi
            return 0
        fi
        if [[ "$amb" == *"$c"* ]]; then
            if [[ -z "$b" ]]; then
                rrv=m
                return 0
            fi
            a=1
        elif [[ "$oamb" == *"$c"* ]]; then
            a=1
        elif [[ "$opt" == *"$c"* ]]; then
            # git grep -O shows each matching file whole in a pager, whatever else it lists.
            if [[ "$rrn" == 'git grep' ]]; then rrO=1; fi
            return 0
        fi
    done
}

# _rr_long <word>: read a long option of the walked reader. A grep or git grep option widens the walk when the word is
# any abbreviation of it, narrows it only when spelled out, and takes a value when the word names or abbreviates one
# that does (an abbreviation, or an option one grep gives an optional value, leaves an m word). An option this does not
# list is a flag.
_rr_long() {
    local n="${1%%=*}" v="" eq=0 k rvt="" rft="" rfv=0
    if [[ "$1" == *=* ]]; then
        v="${1#*=}"
        eq=1
    fi
    k="${n#--}"
    if [[ "$_RR_FILE_VAL" == *" $k "* ]]; then
        rfv=1
    fi
    case "$rrn" in
        grep) rvt="$_RR_GREP_VAL"; rft="$_RR_GREP_FLAGS" ;;
        rg) rvt="$_RR_RG_VAL"; rft="$_RR_RG_FLAGS" ;;
        'git grep') rvt="$_RR_GIT_VAL"; rft="$_RR_GIT_FLAGS" ;;
    esac
    # An = form names its value: a pattern or a setting unless the option takes a file or a program. A bare option in
    # neither table may take the next word as its value.
    if [[ -n "$rvt" ]]; then
        if (( eq )); then
            if [[ "$rvt" == *" $k "* ]] && (( ! rfv )); then
                RR_ROLE=P
            fi
        elif [[ "$rvt" != *" $k "* && "$rft" != *" $k "* ]]; then
            rrunk=1
        fi
    fi
    case "$rrn" in
        grep)
            if [[ --recursive == "$n"* || --dereference-recursive == "$n"* || "$n" == --index || "$n" == --depth ]]
            then
                rrec=1
            fi
            if [[ --dereference-recursive == "$n"* || "$n" == --dereference-files ]]; then rrf=1; fi
            if (( ${#k} > 1 )) && [[ --directories == "$n"* ]]; then
                if (( ! eq )); then
                    rrv=d
                elif [[ "$v" == recurse ]]; then
                    rrec=1
                fi
                return 0
            fi
            case "$n" in
                --files-with-matches|--files-without-match|--count|--quiet|--silent|--version|--help)
                    if (( ! rrsup )); then
                        rrl=1
                        if [[ "$n" == --files-with* ]]; then rrnm=1; fi
                    fi
                    return 0 ;;
                --binary) return 0 ;;
                --include) if (( eq )); then _rr_inc "$v"; else rrv=i; fi; return 0 ;;
                --exclude) if (( eq )); then _rr_exc "$v"; else rrv=x; fi; return 0 ;;
                --exclude-dir) if (( eq )); then _rr_xdir "$v"; else rrv=X; fi; return 0 ;;
                --include-dir) rrvx=1 ;;
                --exclude-from) rrxo=1; rrve=1 ;;
                --include-from|--glob|--iglob|--file-extension|--file-type|--file-magic) rrvi=1 ;;
                --glob-ignore-case) rrvi=1; return 0 ;;
                --from) rrask="it searches the files a list names" ;;
                --and|--andnot|--not) rrmv=1 ;;
                --regexp|--file) rre=1 ;;
                *)
                    if [[ --include == "$n"* || --include-dir == "$n"* || --include-from == "$n"* ]]; then rrvi=1; fi
                    if [[ --include-dir == "$n"* || --exclude-dir == "$n"* ]]; then rrvx=1; fi
                    if [[ --exclude == "$n"* || --exclude-from == "$n"* ]]; then
                        rrxo=1
                        rrve=1
                    fi
                    if [[ --regexp == "$n"* || --file == "$n"* ]]; then rrmv=1; fi ;;
            esac
            if (( eq )); then
                return 0
            fi
            if [[ "$_RR_GREP_VAL" == *" $k "* ]]; then
                if [[ "$k" == context || "$k" == group-separator ]]; then
                    rrv=m
                else
                    rrv=v
                    rrvf=$rfv
                fi
            elif [[ "$_RR_GREP_ABBR" == *" $k"* ]]; then
                rrv=m
            fi ;;
        rg)
            case "$n" in
                --files|--files-with-matches|--files-without-match|--count|--count-matches|--quiet|--version|--help|\
                --type-list|--pcre2-version|--generate)
                    if (( ! rrsup )); then rrl=1; fi
                    if [[ "$n" == --files* ]] && (( ! rrsup )); then rrnm=1; fi
                    # rg --files lists the files under its operands: it takes no pattern.
                    if [[ "$n" == --files ]]; then rrfl=1; fi ;;
                # --hidden needs no widening: git's listing already holds the hidden files .gitignore leaves.
                --no-ignore*|--unrestricted) rrw=1 ;;
                --follow) rrf=1 ;;
                --regexp|--file) rre=1 ;;
            esac
            if (( ! eq )) && [[ "$_RR_RG_VAL" == *" $k "* ]]; then
                rrv=v
                rrvf=$rfv
            fi ;;
        'git grep')
            if [[ --no-index == "$n"* ]]; then rrnoi=1; fi
            if [[ --untracked == "$n"* ]]; then rrunt=1; fi
            if [[ --no-exclude-standard == "$n"* ]]; then rrnoex=1; fi
            if [[ --recurse-submodules == "$n"* ]]; then rrsub=1; fi
            if [[ --open-files-in-pager == "$n"* ]]; then rrO=1; fi
            case "$n" in
                --files-with-matches|--name-only|--files-without-match|--count|--quiet)
                    if (( ! rrsup )); then rrl=1; fi ;;
            esac
            if (( ! eq )); then
                if [[ "$_RR_GIT_VAL" == *" $k "* ]]; then
                    rrv=v
                    rrvf=$rfv
                elif [[ "$_RR_GIT_VAL" == *" $k"* ]]; then
                    rrv=m
                fi
            fi ;;
        diff)
            if [[ "$n" == --brief ]] && (( ! rrsup )); then rrl=1; fi
            if [[ --recursive == "$n"* ]]; then rrec=1; fi
            # --from-file= and --to-file= name a file or directory every operand is compared with.
            if (( eq )); then
                _rr_op m "$v"
            fi ;;
        'git diff')
            if [[ --no-index == "$n"* ]]; then rrnx=1; fi ;;
    esac
}

# _rr_word <word>: feed the next word of the walked reader's stage to the probe walk.
_rr_word() {
    local p="$rrv" pf="$rrvf"
    RR_ROLE=""
    if [[ -n "$p" ]]; then
        rrv=""
        rrvf=0
        case "$p" in
            v)
                if (( ! pf )); then RR_ROLE=P; fi
                return 0 ;;
            d) RR_ROLE=P; if [[ "$1" == recurse ]]; then rrec=1; fi; return 0 ;;
            i) RR_ROLE=P; _rr_inc "$1"; return 0 ;;
            x) RR_ROLE=P; _rr_exc "$1"; return 0 ;;
            X) RR_ROLE=P; _rr_xdir "$1"; return 0 ;;
            m)
                if [[ "$1" == recurse ]]; then rrec=1; fi
                rrmv=1
                if (( rrdd )) || [[ "$1" != -?* ]]; then
                    _rr_op m "$1"
                    return 0
                fi
                # Under the reading where the last option took no value, this word is an option of its own.
                rrsup=1 ;;
        esac
    fi
    if (( ! rrdd )); then
        # A $'...' escape stays as written in the word (\x2d for -): a leading numeric one may be an option, and one
        # inside an option word may be a bundled letter such as f. Other escapes decode to no letter.
        case "$1" in
            \\[xuU0-7]*|-*\\[xuU0-7]*) rrunk=1 ;;
        esac
    fi
    # An option word git grep reads after the shell assembles it (--recurse-sub${X}modules) may name any option.
    if (( ! rrdd )) && [[ "$rrn" == 'git grep' && "$1" == -* && ( "$1" == *[\$\`\\\{\*\?\[]* || "$wmk" == *b* ) ]]; then
        rrdyn=1
    fi
    if (( ! rrdd )) && [[ "$1" == -- ]]; then
        rrdd=1
        rrsep=1
    elif (( ! rrdd )) && [[ "$rrn" == git* && "$1" == --end-of-options ]]; then
        rrdd=1
    elif (( ! rrdd )) && [[ "$1" == --?* ]]; then
        _rr_long "$1"
    elif (( ! rrdd )) && [[ "$1" == -?* ]]; then
        _rr_short "$1"
    elif [[ "$rrn" == 'git grep' && ( "$1" == '(' || "$1" == ')' ) ]]; then
        :
    else
        # The first positional is the pattern, unless an option gives one (settled in _rr_settle); git grep's pathspecs
        # after -- are not.
        if (( rron == 0 )) && { [[ "$rrn" != 'git grep' ]] || (( ! rrsep )); }; then
            RR_ROLE=F
        fi
        _rr_op w "$1"
    fi
    rrsup=0
}

# _rr_settle: end the probe walk (_rr_settle_walk), then restore the globals the walk's probes read.
_rr_settle() {
    _rr_settle_walk
    # An ambiguous option or an unknown one may have taken a word as its value, so no word of the walk is a pattern; an
    # option that gave the pattern, or rg --files, leaves the first positional a file.
    if (( rrown )); then
        if (( rrmv || rrunk )); then
            _p_void
        elif (( spf && (rre || rrfl) )); then
            _snx "$spfw"
            spf=0
        fi
    fi
    RR_LIST=0
    RR_RGCOL=0
    RR_DEEP=1
}

# _rr_stdin_ok: 0 if the stage's stdin is something rg reads: a pipe, a here-document or here-string, or a regular
# file outside /dev (rg takes a character device such as /dev/null for no input, and searches its directory instead).
_rr_stdin_ok() {
    if (( rgr )); then
        if (( rgk == 2 )); then
            return 0
        fi
        _pcwd
        if (( rgk == 1 )) && norm_path "$rgt" "$PCWD" && [[ -f "$NORM_PATH" && "$NORM_PATH" != /dev/* ]]; then
            return 0
        fi
        return 1
    fi
    if (( si > 0 )); then
        return 0
    fi
    return 1
}

# _rr_ps_exclude <pathspec>: 0 if <pathspec> carries git's exclude magic (! or ^ in the short form :!x, :/^x; the word
# exclude in the long form :(exclude)x), which only drops files from what the command's other pathspecs read. A word
# holding $, a backquote or a brace fails: the shell may split it into more pathspecs or expand it into other magic. A
# glob keeps the literal magic before it in every match, so it may stay.
_rr_ps_exclude() {
    local m
    if [[ "$1" == *[\$\`\{]* || "${2:-}" == [2b] ]]; then
        return 1
    fi
    if [[ "$1" == ':('* ]]; then
        m="${1#':('}"
        if [[ "$m" != *')'* ]]; then
            return 1
        fi
        m="${m%%')'*}"
        [[ ",$m," == *',exclude,'* ]]
        return
    fi
    m="${1#:}"
    m="${m%%[!/!^]*}"
    [[ "$m" == *'!'* || "$m" == *'^'* ]]
}

# _rr_cat <dir> <object>: set RR_CAT to the type git cat-file -t prints for <object> in <dir> (blob, tree or commit), or
# to absent when git says its path is not in the revision (the only failure read as an answer), else to empty. One call
# within the walks' git budget; none once it is spent.
_rr_cat() {
    local st=0
    RR_CAT=""
    if (( rr_gitn >= RR_GIT_MAX )); then
        return 0
    fi
    rr_gitn=$(( rr_gitn + 1 ))
    RR_CAT=$(git -C "$1" cat-file -t "$2" 2>&1) || st=$?
    if (( st != 0 )); then
        case "$RR_CAT" in
            "fatal: path '"*"' does not exist in '"*"'" \
                | "fatal: path '"*"' exists on disk, but not in '"*"'") RR_CAT=absent ;;
            *) RR_CAT="" ;;
        esac
    fi
}

# _rr_rev_ok <rev>: 0 if git grep's operand <rev>, read as a revision, confines the search to what the hook can screen:
# <rev> peels to a commit (git cat-file, run in git -C's directory or the payload's cwd, within the walks' git budget)
# and holds no $, :, backslash, pattern or leading -. With -- each pathspec after it is literal (no $ or backslash,
# which the shell or git reads on, nor an absolute or ~ one) or a pattern standing for the directory before its first
# pattern component (none climbing out with ..), names no secret, and names a blob or a tree of the commit, or nothing
# in it (an ASCII name, as git precomposes any other before it matches). A tree is probed from the revision (the rev
# probe kind lists it with git ls-tree), not from the work tree. An exclude pathspec is skipped, as it only drops
# files; the whole tree is listed when the root is named, or no other pathspec is left. Without --, the one operand
# is the revision and the whole tree is listed. Other : magic, a tree-ish operand (rev:path) and a tree or unknown
# revision fail. A git -c core setting, a GIT_CONFIG assignment or a pathspec setting (rr_gitps: spelled out, or in a
# git option or variable name the shell may assemble, which holds a $, backquote, backslash, brace or pattern
# character, or a variable written under a computed name) fails it too, as the hook's own git call cannot carry them,
# and so does an earlier cd or an env -C, after which git runs somewhere the cat-file call does not. So does an option
# word the shell assembles or expands (rrunk, rrdyn), which could be --recurse-submodules or any other. That flag fails
# every tree and every absent path (a gitlink hides what lies under it), as git searches the submodules at their
# recorded commits; so does submodule.recurse, asked of the repository (_rr_subrec fails closed). A pathspec that
# equals or lies under a tree path in a different case also fails (_rr_case_clear), since a setting that folds case
# would match it.
_rr_rev_ok() {
    local rest="$rrops" o t dir p np=0 whole=0 n cl="" s us=$'\x1f' sub="$rrsub"
    if (( gcore || rr_gitcfg || rr_gitps || cdc || ecd || rrunk || rrdyn )); then
        return 1
    fi
    if [[ "$1" == *[\$:\\]* || "$1" == -* ]] || _rr_has_glob "$1"; then
        return 1
    fi
    _cd_text
    if [[ "$CDT" == *PATHSPECS* || "$CDT" == *-pathspecs* ]]; then
        return 1
    fi
    _cd_dyn
    if (( cddyn )); then
        return 1
    fi
    if (( ! rrsep )); then
        n=$rron
        if (( ! rre )); then
            n=$(( n - 1 ))
        fi
        if (( n != 1 || rrmv || rrmn )); then
            return 1
        fi
        whole=1
    fi
    _pcwd
    if ! norm_path "${rrcd:-.}" "$PCWD"; then
        return 1
    fi
    dir="$NORM_PATH"
    _rr_cat "$dir" "$1^{commit}"
    if [[ "$RR_CAT" != commit ]]; then
        return 1
    fi
    if (( ! sub )) && _rr_subrec "$dir"; then
        sub=1
    fi
    while (( rrsep )) && [[ -n "$rest" ]]; do
        o="${rest%%$'\x1e'*}"
        rest="${rest#*$'\x1e'}"
        t="${o:0:1}"
        # The glob marker is skipped: a pathspec is git's own pattern, quoted or not.
        g="${o:1:1}"
        o="${o:2}"
        if [[ "$t" != W ]]; then
            continue
        fi
        if [[ "$o" == :* ]]; then
            if _rr_ps_exclude "$o" "$g"; then
                continue
            fi
            return 1
        fi
        if [[ "$o" == *[\$\\]* || "$o" == [/~]* ]]; then
            return 1
        fi
        np=$(( np + 1 ))
        p="$o"
        if _rr_has_glob "$o"; then
            if [[ "/$o/" == */../* ]]; then
                return 1
            fi
            _rr_glob_dir "$o"
            p="$RR_GLOB_DIR"
            if [[ "$p" == . ]]; then
                whole=1
                continue
            fi
        fi
        name_fold "$p"
        if path_is_secret "$NAME_FOLD"; then
            return 1
        fi
        if (( whole )); then
            continue
        fi
        s="$p"
        while [[ "$s" == */ ]]; do
            s="${s%/}"
        done
        s="${s#./}"
        if [[ -n "$s" && "$s" != . ]]; then
            if [[ "/$s/" == *//* || "/$s/" == */./* || "/$s/" == */../* || "$s" == *[!\ -~]* ]]; then
                return 1
            fi
            cl+="$s$us"
        fi
        _rr_cat "$dir" "$1^{commit}:./$p"
        case "$RR_CAT" in
            blob) ;;
            tree)
                if (( sub )) || ! norm_path "$p" "$dir"; then
                    return 1
                fi
                _rr_dir "$form" "rev"$'\x1d'"$dir"$'\x1d'"$1"$'\x1d'"$p" "$NORM_PATH" ;;
            absent)
                # git precomposes a non-ASCII pathspec (core.precomposeunicode), so its spelling here may differ.
                if (( sub )) || [[ "$p" == *[!\ -~]* ]]; then
                    return 1
                fi ;;
            *) return 1 ;;
        esac
    done
    if (( np == 0 )); then
        whole=1
    fi
    if (( whole )); then
        if (( sub )); then
            return 1
        fi
        _rr_dir "$form" "rev"$'\x1d'"$dir"$'\x1d'"$1"$'\x1d' "$dir"
    elif [[ -n "$cl" ]] && ! _rr_case_clear "$dir" "$1" "$cl"; then
        return 1
    fi
    return 0
}

# _rr_case_clear <dir> <rev> <pathspecs>: 0 if no path of <rev>'s tree (listed from <dir>, one budgeted git call, at
# most 50000 paths) equals or lies under a pathspec of the \x1f-separated list in a different case. A pathspec setting
# that folds case (GIT_ICASE_PATHSPECS, however it is spelled) would match those paths, which the exact lookups of
# _rr_rev_ok did not see (a sibling Docs/ beside a pathspec docs, whatever the exact lookup found). A path holding a
# newline, any failure, or a spent budget reads as a clash.
_rr_case_clear() {
    local out st=0
    if (( rr_gitn >= RR_GIT_MAX )); then
        return 1
    fi
    rr_gitn=$(( rr_gitn + 1 ))
    out=$(git -C "$1" ls-tree --full-tree -r --name-only -z "$2^{commit}:./" 2>/dev/null \
        | LC_ALL=C tr '\0' '\036' | LC_ALL=C awk -v ps="$3" -v cap=50000 '
        BEGIN {
            RS = sprintf("%c", 30)
            n = split(ps, S, sprintf("%c", 31))
            for (i = 1; i <= n; i++) L[i] = tolower(S[i])
        }
        {
            if (++c > cap || index($0, "\n")) { print "cap"; bad = 1; exit }
            lp = tolower($0)
            for (i = 1; i <= n; i++) {
                if (L[i] == "") continue
                if ((lp == L[i] || index(lp, L[i] "/") == 1) && !($0 == S[i] || index($0, S[i] "/") == 1)) {
                    print "clash"; bad = 1; exit
                }
            }
        }
        END { if (!bad) print "ok" }') || st=$?
    [[ "$out" == ok && "$st" == 0 ]]
}

# _rr_settle_walk: a reader that prints contents has each operand probed (the first is its pattern unless -e or -f gave
# one; diff and git diff --no-index have none, and probe every operand); a recursive one with no operand naming an
# existing path probes its working directory (git -C's, for git), except an rg whose stdin it reads. A reader after
# xargs takes more words from its input, so neither shortcut applies there. Inside find -exec, a {} operand is find's
# and, under -execdir, a relative root holds an ask. A names-only reader queues its roots for a reader after xargs and
# marks the stage (srl). A git grep operand that is no path may be a revision, which holds an ask unless _rr_rev_ok
# lists what the search reads from it; a pathspec with magic may reach past the root and holds one too. After
# xargs or parallel, a recursive reader's operand holding the replacement string
# has the directory before it probed, following links (xk), as grep -r follows a link it is given.
_rr_settle_walk() {
    local rest="$rrops" o ro t g first=1 any=0 kind=find form="$rrd" inc="" exc="" xd="" pslot=1 n deep="$rrec" xk
    local rrrv=0
    act="${act//r/}"
    case "$rrn" in
        grep)
            if (( rrec )); then form+=" -r"; fi
            if (( rrf )); then kind=findL; fi
            if (( ! rrvi )); then inc="$rrinc"; fi
            if (( ! rrve )); then exc="$rrexc"; fi
            if (( ! rrvx )); then xd="$rrxd"; fi ;;
        rg)
            if (( rrf )); then kind=findL; elif (( ! rrw )); then kind=git; fi
            if (( rrfl )); then pslot=0; fi ;;
        'git grep')
            if (( rrO )); then
                rrl=0
            fi
            if (( rrnoi || rrnoex || gcore || rr_gitcfg )); then
                kind="find"
            elif (( rrunt || rrsub )); then
                kind=git
            else
                kind=tracked
            fi ;;
        diff)
            pslot=0
            rrec=0
            kind=findL ;;
        'git diff')
            if (( ! rrnx )); then
                return 0
            fi
            form='git diff --no-index'
            pslot=0
            rrec=0
            deep=1
            kind=findL ;;
    esac
    RR_DEEP=$deep
    if (( rrl )); then
        RR_LIST=1
        srl=1
        if (( rrnm )); then
            snm=1
        fi
    fi
    if [[ -n "$rrask" ]]; then
        _rr_hold "$form" "$rrask"
    fi
    if [[ "$rrn" == 'git grep' ]] && (( gwt || rr_gitenv )); then
        _rr_hold "$form" "it names another git directory or work tree"
        return 0
    fi
    # With no pattern from an operand, -e or -f (or a default the walk cannot see), every reader exits with an error.
    if (( pslot && ! rre && ! rrmv && rron == 0 )) && [[ "$sf" != *X* ]]; then
        return 0
    fi
    n=$rron
    if (( pslot && ! rre && n > 0 )); then
        n=$(( n - 1 ))
    fi
    if (( n > 64 || rrmn > 64 )); then
        _rr_hold "$form" "it names more than 64 operands"
        return 0
    fi
    if [[ "$kind" == tracked ]]; then
        _pcwd
        if norm_path "${rrcd:-.}" "$PCWD" && [[ -d "$NORM_PATH" ]] && _rr_subrec "$NORM_PATH"; then
            kind=git
        fi
    fi
    if [[ "$kind" == git && "$rrn" == rg ]] && (( ! RR_LIST )); then
        RR_RGCOL=1
        rrgl=""
    fi
    xk="$kind"
    if [[ "$sf" == *X* && "$kind" == find ]]; then
        xk=findL
    fi
    while [[ -n "$rest" ]]; do
        o="${rest%%$'\x1e'*}"
        rest="${rest#*$'\x1e'}"
        t="${o:0:1}"
        g="${o:1:1}"
        o="${o:2}"
        ro="$o"
        # find's {}, or a path under it with no .. segment, stays inside find's roots; another word built on {} may not.
        if (( rrex )) && [[ "$o" == *'{}'* ]]; then
            if [[ "$o" != '{}' ]] && [[ "$o" != '{}/'* || "/$o/" == */../* ]]; then
                _rr_hold "$form" "'$o' is built on each file find names and may reach past find's roots"
            fi
            any=1
            continue
        fi
        if [[ "$rrn" == git* && -n "$rrcd" && "$o" != /* && "$o" != '~'* && "$o" != :* ]]; then
            o="$rrcd/$o"
        fi
        if [[ "$t" == m ]]; then
            if (( deep )) && _rr_xrep "$o"; then
                if [[ "$RR_XDIR" == '!' ]]; then
                    _rr_hold "$form" "'$o' is filled in from its input and may reach past the directory it names"
                elif [[ -n "$RR_XDIR" ]]; then
                    _rr_cand "$form" "$xk" "$RR_XDIR"
                fi
                continue
            fi
            _rr_cand "$form" "$kind" "$o"
            continue
        fi
        if (( pslot && first && ! rre )); then
            first=0
            if (( rrmv )); then
                _rr_cand "$form" "$kind" "$o"
            fi
            continue
        fi
        first=0
        if (( deep )) && _rr_xrep "$o"; then
            any=1
            if [[ "$RR_XDIR" == '!' ]]; then
                _rr_hold "$form" "'$o' is filled in from its input and may reach past the directory it names"
            elif [[ -n "$RR_XDIR" ]]; then
                _rr_root "$form" "$xk" "$RR_XDIR" "$inc" "$exc" "$xd" || :
            fi
            continue
        fi
        if (( rrex == 2 )) && [[ "$o" != /* && "$o" != '~'* ]]; then
            _rr_hold "$form" "find -execdir resolves '$o' in each found file's directory"
            any=1
            continue
        fi
        if [[ "$rrn" == 'git grep' ]]; then
            # An exclude pathspec only drops files: what the other operands (or the working directory) name is probed.
            if [[ "$o" == :* ]]; then
                if ! _rr_ps_exclude "$o" "$g"; then
                    _rr_hold "$form" "the pathspec '$o' holds magic the hook does not resolve"
                    any=1
                fi
                continue
            fi
            # Once a revision is searched, the pathspecs name its files, which _rr_rev_ok probed, not the work tree's.
            if [[ "$t" == W ]] && (( rrrv )); then
                any=1
                continue
            fi
            # Before --, git reads every operand as a revision, a work-tree path's name included; without it, a word
            # naming no path may be one.
            if [[ "$t" == w ]] && (( ! rrnoi && ! rrunt )) && { (( rrsep )) || { [[ "$o" != *'$'* ]] \
                    && ! _rr_has_glob "$o" && ! _rr_exists "$o"; }; }; then
                # A word a brace built is never cleared as a revision; with no --, it is also read as a path.
                if [[ "$g" != 2 ]] && _rr_rev_ok "$ro"; then
                    rrrv=1
                else
                    _rr_hold "$form" "'$o' may name a revision, whose files the hook cannot list"
                fi
                if [[ "$g" != 2 ]] || (( rrsep )); then
                    any=1
                    continue
                fi
            fi
        fi
        # A marked operand is a literal name, unless the stage re-parses its words or runs a shell from awk or sed.
        if [[ "$g" == 1 ]] && (( ! srp && ! sgv )); then
            RR_LIT=1
        fi
        if _rr_root "$form" "$kind" "$o" "$inc" "$exc" "$xd"; then
            any=1
        fi
        RR_LIT=0
    done
    if (( RR_RGCOL )); then
        RR_RGCOL=0
        if [[ -n "$rrgl" ]]; then
            _rr_rg_roots "$form"
        fi
    fi
    # After xargs or parallel a recursive reader takes operands from its input, which the hook cannot see: its working
    # directory is probed whatever operands it shows, and so is each directory an earlier stage named outside it, each
    # following links. That covers its input only when every earlier stage prints names the hook models (_np_end); an
    # argument file or an input redirection is a list the hook cannot see either.
    if [[ "$sf" == *X* ]] && (( deep && ! rrl && rrex != 2 )); then
        if [[ "$xk" == findL ]]; then
            sxk=findL
        fi
        _rr_root "$form" "$xk" "${rrcd:-.}" "$inc" "$exc" "$xd" || :
        if [[ -n "$pipe_xd" ]]; then
            _find_roots "$pipe_xd" "$rrd" xargs "$sxk"
        fi
        if (( xaf )); then
            _hold_probe "$form" "xargs or parallel reads its arguments from a file"
        elif (( rgr )); then
            _hold_probe "$form" "xargs or parallel reads its arguments from an input redirection"
        elif (( pnu )); then
            _hold_probe "$form" "an earlier stage prints the paths it reads, which the hook cannot see"
        fi
        if (( xqr )); then
            _hold_probe "$form" "parallel sets its own replacement strings"
        fi
        return 0
    fi
    # Under -execdir the working directory is each found file's, inside find's roots.
    if (( any || ! rrec || rrex == 2 )); then
        return 0
    fi
    if [[ "$rrn" == rg && "$sf" != *X* ]] && _rr_stdin_ok; then
        return 0
    fi
    _rr_root "$form" "$kind" "${rrcd:-.}" "$inc" "$exc" "$xd" || :
}

# _find_root_add <word>: record a find root.
_find_root_add() {
    if (( fron < 65 )); then
        fro+="$1"$'\x1e'
    fi
    fron=$(( fron + 1 ))
}

# _find_name_word <word>: follow a find expression for the -name narrowing. It narrows only while every word is -name
# or -iname with a plain glob (at most 16), -type f or d, -maxdepth or -mindepth N, -print, -print0, or an -exec
# family action (whose command words the g walk takes), so the find lists only names a glob matches. fnv marks a value
# due (1 -name, 2 -iname, 3 -type, 4 -maxdepth, 5 -mindepth); fnr collects the globs (an -iname one folded) and fng
# each glob G as include globs G, G/* and */G/* (a matching directory keeps all below it, which a reader given it may
# read); fmd marks a -mindepth of 1 or more (the last one counts), and fnx an expression it cannot model.
_find_name_word() {
    local v="$fnv" g
    fnv=0
    case "$v" in
        1|2)
            fnn=$(( fnn + 1 ))
            if (( fnn > 16 || ${#1} > 256 )) || ! probe_glob_plain "$1"; then
                fnx=1
                return 0
            fi
            g="$1"
            if (( v == 2 )); then
                _glob_fold "$1"
                g="$_GLOB_FOLD"
            fi
            fnr+="${fnr:+$'\x1f'}$g"
            fng+="${fng:+$'\x1f'}$g"$'\x1f'"$g/*"$'\x1f'"*/$g/*"
            return 0 ;;
        3)
            if [[ "$1" != f && "$1" != d ]]; then fnx=1; fi
            return 0 ;;
        4|5)
            if [[ -z "$1" || "$1" == *[!0-9]* ]]; then
                fnx=1
            elif (( v == 5 )); then
                fmd=0
                if [[ "$1" == *[1-9]* ]]; then fmd=1; fi
            fi
            return 0 ;;
    esac
    case "$1" in
        -name) fnv=1 ;;
        -iname) fnv=2 ;;
        -type) fnv=3 ;;
        -maxdepth) fnv=4 ;;
        -mindepth) fnv=5 ;;
        -print|-print0|-exec|-execdir|-ok|-okdir|';'|'+') ;;
        *) fnx=1 ;;
    esac
    return 0
}

# _find_root_inc <root>: set FRI to the include field the root <root> carries: none when the expression does not narrow,
# or when, with no -mindepth of 1 or more, a -name glob matches the root's own name (find tests a starting point too,
# and hands it over whole); else \x1f and the include globs.
_find_root_inc() {
    local b="$1" rest g
    FRI=""
    if (( fnx || fnv )) || [[ -z "$fng" ]]; then
        return 0
    fi
    if (( ! fmd )); then
        while [[ "$b" == ?*/ ]]; do b="${b%/}"; done
        if [[ "$b" == */?* ]]; then b="${b##*/}"; fi
        rest="$fnr"
        while [[ -n "$rest" ]]; do
            g="${rest%%$'\x1f'*}"
            if [[ "$rest" == *$'\x1f'* ]]; then rest="${rest#*$'\x1f'}"; else rest=""; fi
            # shellcheck disable=SC2053  # the glob is a pattern
            if [[ "$b" == $g ]]; then
                return 0
            fi
        done
    fi
    FRI=$'\x1f'"$fng"
}

# _find_collect: set FIND_ENTRIES to this stage's find roots (. when it named none) and the later words bfs may take
# for a root, as _find_roots reads them, or a single ! entry when it named more than 64 roots. A root and a candidate
# carry the -name narrowing's include globs (_find_root_inc) as a last field, when the expression allows it.
_find_collect() {
    local rest="$fro" r
    FIND_ENTRIES=""
    if (( fron > 64 )); then
        FIND_ENTRIES="!0"$'\x1f'find$'\x1f\x1e'
        return 0
    fi
    if (( fco )); then
        FIND_ENTRIES+="!0"$'\x1f'find$'\x1f\x1e'
    fi
    if (( ffz )); then
        FIND_ENTRIES+="a0"$'\x1f'find$'\x1f'"it reads its starting points from a file"$'\x1e'
    fi
    if (( fron == 0 )); then
        _find_root_inc .
        FIND_ENTRIES+="r$fL"$'\x1f'find$'\x1f.'"$FRI"$'\x1e'
    fi
    while [[ -n "$rest" ]]; do
        r="${rest%%$'\x1e'*}"
        rest="${rest#*$'\x1e'}"
        _find_root_inc "$r"
        FIND_ENTRIES+="r$fL"$'\x1f'find$'\x1f'"$r$FRI"$'\x1e'
    done
    rest="$fca"
    while [[ -n "$rest" ]]; do
        r="${rest%%$'\x1e'*}"
        rest="${rest#*$'\x1e'}"
        _find_root_inc "$r"
        FIND_ENTRIES+="c$fL"$'\x1f'find$'\x1f'"$r$FRI"$'\x1e'
    done
}

# _find_roots <entries> <reader> <how>: probe each root in <entries>, entries of <tag><follow>\x1f<lister>\x1f<root>,
# optionally followed by \x1f and the root's include globs, each ending in \x1e. The tag is r (a root), c (a word that
# may be a root), a (hold an ask; the root field is the reason) or ! (too many roots). <how> names the reader in a
# decision: exec (find -exec), own (<reader> itself, reading a directory glob of its stage), or xargs (<lister> | xargs
# <reader>). <kind> findL follows links in every root: a grep -r after xargs follows a link it is given, and each entry
# listed under a root may be one.
_find_roots() {
    local rest="$1" e t k l r form inc
    while [[ -n "$rest" ]]; do
        e="${rest%%$'\x1e'*}"
        rest="${rest#*$'\x1e'}"
        t="${e:0:1}"
        k="find"
        if [[ "${e:1:1}" == 1 || "${4:-}" == findL ]]; then
            k=findL
        fi
        e="${e:3}"
        l="${e%%$'\x1f'*}"
        r="${e#*$'\x1f'}"
        inc=""
        if [[ "$t" == [rc] && "$r" == *$'\x1f'* ]]; then
            inc="${r#*$'\x1f'}"
            r="${r%%$'\x1f'*}"
        fi
        case "$3" in
            exec) form="find -exec" ;;
            own) form="$2" ;;
            *) form="$l | xargs $2" ;;
        esac
        case "$t" in
            '!') _hold_probe "$form" "it names more than 64 roots" ;;
            a) _hold_probe "$form" "$r" ;;
            c) _rr_cand "$form" "$k" "$r" "$inc" ;;
            *) _rr_root "$form" "$k" "$r" "$inc" || : ;;
        esac
    done
}

# _wild_word <word>: 0 if <word>, expanded against the payload's cwd, matches a secret path: a word whose last component
# is wildcard-only (*, ?*), expanded in its directory, or one with a pattern in a directory part (*/x, */*), expanded
# whole. At most 64 distinct patterns are expanded per run; past that, or past PROBE_MAX_ENTRIES matches, or for a
# directory part at or above $HOME or the vault, an ask is held. zsh's ** and braces, which bash does not expand as zsh
# does, queue the directory before them in wpend instead, for the stage end to probe when the stage reads. Every other
# such word records the directory it expands in (wpip) for a reader after xargs.
_wild_word() {
    local w="$1" d c pat msg wrc=0 rest wd dg=0
    if [[ "$w" == */* ]]; then
        d="${w%/*}"
        c="${w:${#d}+1}"
        d="${d:-/}"
    else
        d=.
        c="$w"
    fi
    if _rr_has_glob "$d"; then
        dg=1
        if [[ "$d" == *'**'* || "$d" == *'{'* ]]; then
            _rr_glob_dir "$w"
            if [[ "$wpend" != *$'\x1f'"$RR_GLOB_DIR"$'\x1e'* ]]; then
                if (( wgn >= 64 )); then
                    wgo=1
                else
                    wgn=$(( wgn + 1 ))
                    wpend+="r1"$'\x1f'"$w"$'\x1f'"$RR_GLOB_DIR"$'\x1e'
                fi
            fi
            return 1
        fi
    elif [[ -z "$c" || "$c" == *[!\*\?]* ]]; then
        return 1
    fi
    # The directory the word expands in (. for a bare wildcard), kept in wpip for a reader after xargs.
    if (( dg )); then
        _rr_glob_dir "$w"
        wd="$RR_GLOB_DIR"
    else
        wd="$d"
    fi
    if [[ "$wpip" != *$'\x1f'"$wd"$'\x1e'* ]]; then
        if (( wpq < 64 )); then
            wpq=$(( wpq + 1 ))
            wpip+="r1"$'\x1f'"$w"$'\x1f'"$wd"$'\x1e'
        elif [[ "$wpip" != '!'* ]]; then
            wpip="!0"$'\x1f'glob$'\x1f\x1e'"$wpip"
        fi
    fi
    if (( _wild_n >= 64 )); then
        _hold_wild
        return 1
    fi
    _pcwd
    if (( ecd )) && [[ "$d" != /* && "$d" != '~'* ]]; then
        msg="SECRET-SCAN ASK: '$w' is expanded after the command changes its directory, which the hook does not"
        msg+=" follow. Approve it only if it matches no secret-bearing file."
        hook_hold_ask "$msg"
        return 1
    fi
    if (( dg )); then
        _rr_glob_dir "$w"
        if [[ "$w" == *'$'* ]] || ! norm_path "$RR_GLOB_DIR" "$PCWD" || [[ ! -d "$NORM_PATH" ]]; then
            return 1
        fi
        if probe_root_too_wide "$NORM_PATH"; then
            msg="SECRET-SCAN ASK: '$w' expands across '$NORM_PATH', at or above \$HOME or the secret vault, which the"
            msg+=" hook does not expand. Approve it only if it matches no secret-bearing file."
            hook_hold_ask "$msg"
            return 1
        fi
        # The part of the word after the directory before its first pattern component.
        if [[ "$w" == "$RR_GLOB_DIR"/* ]]; then
            rest="${w:${#RR_GLOB_DIR}+1}"
        elif [[ "$RR_GLOB_DIR" == / ]]; then
            rest="${w#/}"
        else
            rest="$w"
        fi
        glob_quote "$NORM_PATH"
        pat="${GLOB_QUOTED%/}/$rest"
    else
        # A plain one-component name that is no directory under a clean cwd needs no normalising to be refused.
        if [[ "$d" != *[!A-Za-z0-9_-]* && "/$PCWD/" != */./* && "/$PCWD/" != */../* && ! -d "$PCWD/$d" ]]; then
            return 1
        fi
        if ! norm_path "$d" "$PCWD" || [[ ! -d "$NORM_PATH" ]]; then
            return 1
        fi
        glob_quote "$NORM_PATH"
        pat="$GLOB_QUOTED/$c"
    fi
    if [[ "$_wild_hits" == *$'\x1e'"$pat"$'\x1e'* ]]; then
        return 0
    fi
    if [[ "$_wild_seen" == *$'\x1e'"$pat"$'\x1e'* ]]; then
        return 1
    fi
    _wild_n=$(( _wild_n + 1 ))
    _wild_seen+="$pat"$'\x1e'
    wild_holds_secret "$pat" || wrc=$?
    if (( wrc == 0 )); then
        _wild_hits+="$pat"$'\x1e'
        return 0
    fi
    if (( wrc == 2 )); then
        msg="SECRET-SCAN ASK: '$w' expands to more entries than the hook checks ($PROBE_MAX_ENTRIES). Approve it"
        msg+=" only if none is a secret-bearing file."
        hook_hold_ask "$msg"
    elif (( wrc == 3 )); then
        msg="SECRET-SCAN ASK: '$w' could not be expanded in the time the hook has. Approve it only if it matches no"
        msg+=" secret-bearing file."
        hook_hold_ask "$msg"
    fi
    return 1
}

# _deny_cd <form>: deny a cd into a secret-bearing directory.
_deny_cd() {
    local msg="SECRET-PATH BLOCK: 'cd $1' enters a secret-bearing directory, where a later relative path names a"
    msg+=" secret file that no check sees. Stay outside it and pass full paths to a script; ${VAULT_HINT}."
    hook_deny "$msg"
}

# _hold_cd <form> <why>: hold an ask for a cd whose target the hook could not check.
_hold_cd() {
    local msg="SECRET-PATH ASK: 'cd $1' enters a directory the hook could not check ($2). Approve it only if that"
    msg+=" directory holds no secret-bearing file."
    hook_hold_ask "$msg"
}

# _cd_tree <abs> <form>: deny the cd <form> when the absolute path <abs> is a secret directory, or one of its ancestors
# holds a secret directly (from ~/.aws/sso, ../credentials is bare; below ~/.config, which only holds gh/hosts.yml
# deeper, is not denied). The paths tested cost time linear in their length, so past CD_TREE_BUDGET characters in a
# run the rest hold an ask.
_cd_tree() {
    local a="$1" near=""
    while [[ "$a" == /?* ]]; do
        cdtb=$(( cdtb + ${#a} ))
        if (( cdtb > CD_TREE_BUDGET )); then
            _hold_cd "$2" "the command's cd paths are longer than the hook checks"
            return 0
        fi
        if dir_is_secret "$a" $near; then
            _deny_cd "$2"
        fi
        near=near
        a="${a%/*}"
    done
}

# _cd_abs <abs> <form>: deny the cd <form> when the absolute path <abs>, or the directory it names with its links
# resolved, is in a secret directory.
_cd_abs() {
    local phys
    _cd_tree "$1" "$2"
    if [[ -d "$1" ]]; then
        phys=$(cd -P -- "$1" 2>/dev/null && pwd -P) || phys=""
        if [[ -n "$phys" && "$phys" != "$1" ]]; then
            _cd_tree "$phys" "$2"
        fi
    fi
}

# _cd_sid: set CDSID, once, to the payload's session id when it is plain (letters, digits and -), else to empty.
_cd_sid() {
    if (( ! cdsf )); then
        cdsf=1
        CDSID=$(hook_field '.session_id')
        if [[ ! "$CDSID" =~ ^[A-Za-z0-9-]+$ ]]; then
            CDSID=""
        fi
    fi
}

# _cd_text: set CDT, once, to the command with its quotes and backslashes removed (cdtf marks it set).
_cd_text() {
    if (( cdtf )); then
        return 0
    fi
    cdtf=1
    CDT="$cmd"
    if [[ "$cmd" == *[\"\'\\]* ]]; then
        CDT=$(printf '%s' "$cmd" | LC_ALL=C tr -d "\"'\\\\") || CDT="$cmd"
    fi
}

# _cd_cdpath: set cdp, once, to 1 when the command assigns, exports or declares CDPATH or zsh's cdpath, read with its
# quotes and backslashes removed, else to 0.
_cd_cdpath() {
    local set_re='(^|[[:space:]])(CDPATH|cdpath)\+?='
    local decl_re='(^|[[:space:]])(export|typeset|declare|local|readonly)[[:space:]]([^|;&]*[[:space:]])?'
    decl_re+='(CDPATH|cdpath)([[:space:]|;&]|$)'
    if (( cdp >= 0 )); then
        return 0
    fi
    cdp=0
    _cd_text
    if [[ "$CDT" =~ $set_re || "$CDT" =~ $decl_re ]]; then
        cdp=1
    fi
}

# _cd_dyn: set cddyn, once, to 1 when the command may write a variable whose name the hook cannot read: a builtin
# that writes one (read, printf -v, declare and its kin, mapfile, getopts) given a name operand holding a $, a nameref,
# or a ${( (zsh flags, (P) included) or ${! (indirection) expansion; else to 0.
_cd_dyn() {
    local b='(^|[^A-Za-z0-9_])(read|printf|declare|typeset|local|export|readonly|mapfile|readarray|getopts)'
    local op_re="$b"'[[:space:]]([^|;&]*[[:space:]])?[^[:space:]=|;&]*\$'
    local nr_re='(^|[^A-Za-z0-9_])(declare|typeset|local)[[:space:]]([^|;&]*[[:space:]])?-[A-Za-z]*n'
    local ex_re='\$\{[(!]'
    if (( cddyn >= 0 )); then
        return 0
    fi
    cddyn=0
    _cd_text
    if [[ "$CDT" =~ $op_re || "$CDT" =~ $nr_re || "$CDT" =~ $ex_re ]]; then
        cddyn=1
    fi
}

# _cd_names <name>: 0 if the command, read with its quotes and backslashes removed, may change the variable <name>: it
# names it other than as $<name>, ${<name>} or ${<name>/…} (an assignment, export, declaration, read, printf -v,
# nameref, or an assigning ${<name>:=…}), or it writes a variable by a computed name (_cd_dyn).
_cd_names() {
    local re="(^|[^A-Za-z0-9_\${])$1([^A-Za-z0-9_]|$)" re2='\$\{'"$1"'([^}/]|$)'
    _cd_text
    _cd_dyn
    if (( cddyn )) || [[ "$CDT" =~ $re || "$CDT" =~ $re2 ]]; then
        return 0
    fi
    return 1
}

# _cd_vars <word>: set CDW to <word> with a leading $PWD written as the payload's cwd, and a leading $CLAUDE_TEMP_DIR as
# the session's temp directory (/tmp/claude-<session id>) when the session id is plain; any other word is kept, as is
# each of these when the command may have changed it: after a sequence separator (cdsq), $PWD after an earlier cd,
# pushd or popd, or either named by the command (_cd_names). A word kept with its $ does not resolve, so the cd asks.
_cd_vars() {
    local n=0
    CDW="$1"
    case "$1" in
        '$PWD'|'$PWD/'*) n=4 ;;
        '${PWD}'|'${PWD}/'*) n=6 ;;
        '$CLAUDE_TEMP_DIR'|'$CLAUDE_TEMP_DIR/'*) n=16 ;;
        '${CLAUDE_TEMP_DIR}'|'${CLAUDE_TEMP_DIR}/'*) n=18 ;;
    esac
    if (( n == 0 || cdsq )); then
        return 0
    fi
    if (( n <= 6 )); then
        if (( cdc > 1 )) || _cd_names PWD; then
            return 0
        fi
        _pcwd
        CDW="$PCWD${1:n}"
        return 0
    fi
    if _cd_names CLAUDE_TEMP_DIR; then
        return 0
    fi
    _cd_sid
    if [[ -n "$CDSID" ]]; then
        CDW="/tmp/claude-$CDSID${1:n}"
    fi
}

# _cd_check <word>: deny a cd to <word> that enters a secret directory: as written, resolved against the payload's cwd
# or a CDPATH entry, or with its links resolved (before its .. segments too: cd -P, or zsh's CHASE_DOTS). Hold an ask
# when the hook cannot resolve it: a pattern, a variable (but $HOME, $PWD and the session's $CLAUDE_TEMP_DIR) or ~user,
# ~ or $HOME after a sequence separator or when the command names HOME, CDPATH set by the command, or a relative word
# after an earlier cd (which the hook does not follow).
_cd_check() {
    local w="$1" why="" rel=0 hw rest e x phys
    if dir_is_secret "$w"; then
        _deny_cd "$w"
    fi
    _pcwd
    _cd_vars "$w"
    hw=0
    # shellcheck disable=SC2088  # a literal ~ prefix is matched here
    case "$w" in
        '~'|'~/'*|'$HOME'|'$HOME/'*|'${HOME}'|'${HOME}/'*) hw=1 ;;
    esac
    if _rr_has_glob "$w"; then
        why="it is a pattern"
    elif (( hw )) && { (( cdsq )) || _cd_names HOME; }; then
        why="the command may set HOME"
    elif ! norm_path "$CDW" "$PCWD"; then
        why="it names a variable or another user's home"
    else
        _cd_abs "$NORM_PATH" "$w"
        if [[ "$CDW" == ..* || "$CDW" == */..* ]]; then
            # shellcheck disable=SC2088  # a literal ~ prefix is matched here, then expanded by hand
            case "$CDW" in
                '~'|'$HOME'|'${HOME}') x="$HOME" ;;
                '~/'*) x="$HOME/${CDW:2}" ;;
                '$HOME/'*) x="$HOME/${CDW:6}" ;;
                '${HOME}/'*) x="$HOME/${CDW:8}" ;;
                *) x="$CDW" ;;
            esac
            phys=$(cd -P -- "$PCWD" 2>/dev/null && CDPATH='' cd -P -- "$x" 2>/dev/null && pwd -P) || phys=""
            if [[ -n "$phys" ]]; then
                _cd_tree "$phys" "$w"
            fi
        fi
        if [[ "$w" != /* && "$w" != '~'* && "$w" != '$'* ]]; then
            rel=1
        fi
        if (( rel && cdc > 1 )); then
            why="it is relative to the directory an earlier cd entered"
        elif (( rel )) && [[ "$w" != . && "$w" != .. && "$w" != ./* && "$w" != ../* ]]; then
            _cd_cdpath
            if (( cdp )); then
                why="the command sets CDPATH"
            elif [[ -n "${CDPATH:-}" ]]; then
                rest="$CDPATH:"
                while [[ -n "$rest" ]]; do
                    e="${rest%%:*}"
                    rest="${rest#*:}"
                    if norm_path "${e:-.}/$w" "$PCWD"; then
                        _cd_abs "$NORM_PATH" "$w"
                    else
                        why="a CDPATH entry names a variable or another user's home"
                    fi
                done
            fi
        fi
    fi
    if [[ -n "$why" ]]; then
        _hold_cd "$w" "$why"
    fi
}

# _cd_count: count a cd; 0 while at most CD_MAX have run, else 1, holding one ask for those past it (left unchecked).
_cd_count() {
    cdc=$(( cdc + 1 ))
    if (( cdc <= CD_MAX )); then
        return 0
    fi
    if (( cdc == CD_MAX + 1 )); then
        _hold_cd "..." "the command runs more than $CD_MAX cd commands"
    fi
    return 1
}

# _cd_word <word>: feed the next word of a cd or pushd to its walk. Options and a -- come first (an unknown option,
# which zsh reads as a directory, is a target); the first other word is the target (- and a +N or -N stack entry name
# directories already entered); a second is zsh's cd OLD NEW, which enters the cwd with OLD replaced by NEW.
_cd_word() {
    local w="$1" pre
    if (( cdn == 0 && ! cdd )); then
        if [[ "$w" == -- ]]; then
            cdd=1
            return 0
        fi
        if [[ "$w" == -[LPeqsn@]* && "$w" != -*[!LPeqsn@]* ]]; then
            return 0
        fi
    fi
    cdn=$(( cdn + 1 ))
    if (( cdn == 1 )); then
        cdo="$w"
        if [[ "$w" == - ]]; then
            # bash's cd - reads $OLDPWD, a temporary prefix assignment included.
            if (( cdsq )) || _cd_names OLDPWD; then
                _hold_cd - "the command may set OLDPWD"
            fi
        elif ! [[ "$w" == [-+][0-9]* && "${w:1}" != *[!0-9]* ]]; then
            _cd_check "$w"
        fi
        return 0
    fi
    act="${act//c/}"
    if [[ "$cdo$w" == *[\$\*\?\[\{~]* || "$wmk" == *b* ]]; then
        _hold_cd "$cdo $w" "it substitutes into the cwd a word the hook cannot resolve"
        return 0
    fi
    _pcwd
    if [[ -n "$cdo" && "$PCWD" == *"$cdo"* ]]; then
        pre="${PCWD%%"$cdo"*}"
        _cd_abs "$pre$w${PCWD:${#pre}+${#cdo}}" "$cdo $w"
    fi
}

# _in_vault <path>: 0 if <path> is under the vault: $CLAUDE_SECRET_DIR/…, ${CLAUDE_SECRET_DIR}/…, or the literal
# /tmp/claude-<id>-vault/secrets/… with no / in the session segment, and no .. component.
_in_vault() {
    local vm
    if [[ "$1" == '$CLAUDE_SECRET_DIR/'?* || "$1" == '${CLAUDE_SECRET_DIR}/'?* ]]; then
        :
    elif [[ "$1" == /tmp/claude-*-vault/secrets/?* ]]; then
        vm="${1#/tmp/claude-}"
        vm="${vm%%-vault/secrets/*}"
        if [[ "$vm" == */* ]]; then
            return 1
        fi
    else
        return 1
    fi
    [[ "/$1/" != */../* ]]
}

# The variables that move a registry login's credential file or directory (docker, podman and its kin, helm).
lg_vars=(DOCKER_CONFIG REGISTRY_AUTH_FILE HELM_REGISTRY_CONFIG HELM_CONFIG_HOME XDG_RUNTIME_DIR XDG_CONFIG_HOME)
lg_names=" ${lg_vars[*]} "

# _lg_auth <location>: note a registry credential file or directory outside the vault (sf L, lga). A vault path built
# on $CLAUDE_SECRET_DIR is outside when the command may reassign it: an assignment before it in the same command
# expands into a later one.
_lg_auth() {
    if [[ "$sf" == *L* ]]; then
        return 0
    fi
    if _in_vault "$1" && { [[ "$1" != '$'* ]] || ! _cd_names CLAUDE_SECRET_DIR; }; then
        return 0
    fi
    lga="$1"
    sf+=L
}

# _lg_env: note a registry login after a sequence separator, when the command names a variable of lg_vars: an
# earlier command may have exported it outside the vault.
_lg_env() {
    local v
    for v in "${lg_vars[@]}"; do
        if _cd_names "$v"; then
            lga="\$$v"
            sf+=L
            return 0
        fi
    done
}

# _dc_option <word>: classify a compose option for the config check: names-only (dcn), permitted with them (--format,
# --dry-run, and the file, project, profile and display globals), the two no-value flags (dci, dce), a value printer
# (dcb, which also counts as other; a short bundle holding o is -o) or any other option (dcx).
_dc_option() {
    case "$1" in
        -q|--quiet|--services|--images|--volumes|--networks|--profiles|--models|--hash|--hash=*) dcn=1 ;;
        --format|--format=*|--dry-run|-f|-f?*|--file|--file=*|-p|-p?*|--project-name|--project-name=*) ;;
        --project-directory|--project-directory=*|--profile|--profile=*|--ansi|--ansi=*|--progress|--progress=*) ;;
        --no-interpolate) dci=1 ;;
        --no-env-resolution) dce=1 ;;
        --environment|--variables|-o|-o?*|--output|--output=*|-[!-]*o*) dcb=1; dcx=1 ;;
        *) dcx=1 ;;
    esac
}

# _dc_word <word>: feed a word after compose (dcm 1) or its config (dcm 2) to the config check. Before the subcommand,
# the values of the valued globals are skipped (dcsk), and the word after an unknown option may be its value (dcu); the
# first other word is the subcommand: config or convert (dcm 2), or any other (dcm 3, no check).
_dc_word() {
    if (( dcsk )); then
        dcsk=0
        return 0
    fi
    if [[ "$1" == -?* ]]; then
        _dc_option "$1"
        if (( dcm == 1 )); then
            case "$1" in
                -f|--file|-p|--project-name|--project-directory|--env-file|--profile|--ansi|--progress|--parallel)
                    dcsk=1 ;;
                --*=*|-f?*|-p?*|--dry-run|--compatibility|--all-resources|--verbose) ;;
                *) dcu=1 ;;
            esac
        fi
        return 0
    fi
    if (( dcm == 1 )); then
        case "$1" in
            config|convert) dcm=2 ;;
            *) if (( dcu )); then dcu=0; else dcm=3; fi ;;
        esac
    fi
}

# _ds_word <word>: feed a word after docker stack (dsk 1) to the stack config check, which fails closed: a -c or
# --compose-file value is skipped (dsv), a config word anywhere later makes it dsk 2 (denied in every form), and a
# compose or exec word is what docker would have seen had a global option's value been read as stack.
_ds_word() {
    if (( dsk == 1 )); then
        if (( dsv )); then
            dsv=0
            return 0
        fi
        case "$1" in
            -c|--compose-file) dsv=1 ;;
            -*) ;;
            config) dsk=2 ;;
            compose) dcm=1 ;;
            exec) _run_wrap "$lgt" ;;
        esac
    fi
    return 0
}

# _run_y <h|d|l>: start the y walk over a runner's later words: h heroku run's or local:run's (named in ryt), which a
# shell parses as one string (ryh); d doppler run's options up to -- (ryd: --command, and the mount options, rym a
# --mount value due, rmf a format or template, rmv a mount into the vault); l heroku local's (ryl: --start-cmd).
_run_y() {
    if [[ "$act" != *y* ]]; then
        act+=y
        ryh=0
        ryd=0
        ryl=0
        rym=0
        rmf=0
        rmv=0
    fi
    case "$1" in
        h) ryh=1 ;;
        d) ryd=1 ;;
        l) ryl=1 ;;
    esac
}

# _run_wrap <runner>: a runner's subcommand was seen: every later word of the stage is at command position.
_run_wrap() {
    act="${act//u/}"
    if [[ "$sf" != *A* ]]; then
        sf+=A
    fi
    case "$1" in
        heroku)
            _run_y h
            ryt="heroku run" ;;
        heroku-local)
            _run_y h
            ryt="heroku local:run" ;;
        doppler) _run_y d ;;
    esac
}

# _k_inline <option>: 0 if <option> gives the interpreter being walked (ipn) inline code: a bundle holding any of
# e E p n c r m (php's also B or R), node's or bun's --eval or --print, deno repl's --eval or --eval-file, or php's
# --run or --process-begin, -code or -end.
_k_inline() {
    case "$1" in
        --*)
            case "$ipn:${1%%=*}" in
                node:--eval|node:--print|bun:--eval|bun:--print|php:--run|php:--process-begin|php:--process-code|\
                php:--process-end)
                    return 0 ;;
                deno:--eval|deno:--eval-file)
                    if [[ "$ksub" == repl ]]; then
                        return 0
                    fi ;;
            esac ;;
        *[eEpncrm]*) return 0 ;;
        *[BR]*)
            if [[ "$ipn" == php ]]; then
                return 0
            fi ;;
    esac
    return 1
}

# _k_valopt <bundle>: set kpv when the option bundle <bundle> of the interpreter being walked (ipn) ends in a letter
# that takes the next word as its value: python -W -X, perl -I -M -x, ruby -I -C, node -C, php -d -S -t -z, lua -l,
# luajit -l -j, osascript -l -s. A letter before the end takes the rest of the bundle. perl's -M and -x take only an
# attached value, so reading the next word as theirs fails closed: that word is then never the program.
_k_valopt() {
    local b="${1#-}" kvl=""
    case "$ipn" in
        python|python3|pypy) kvl=WX ;;
        perl) kvl=IMx ;;
        ruby) kvl=IC ;;
        node) kvl=C ;;
        php) kvl=dStz ;;
        lua) kvl=l ;;
        luajit) kvl=lj ;;
        osascript) kvl='ls' ;;
    esac
    # Two glob tests, not a walk over the letters: a bundle may be 64 KiB long.
    if [[ -n "$kvl" && "$b" == *["$kvl"] && "${b%?}" != *["$kvl"]* ]]; then
        kpv=1
    fi
    return 0
}

# _k_code <word>: <word> starts the walked interpreter's inline code: its program walk becomes the inline-code walk
# (L), and after xargs, which adds its input to the code's arguments, the stage is a reader (Y).
_k_code() {
    if [[ -n "$kvf" ]]; then
        _deny_reader "$ipw $kvf ... $1"
    fi
    act="${act//K/}L"
    if [[ "$sf" == *X* && "$sf" != *Y* ]]; then
        if [[ "$sf" != *R* ]]; then rdn="$ipw"; fi
        sf+=Y
    fi
}

# _k_sub <word> <value>: read <word>, the first of bun's or deno's words that is no option, as their subcommand (ksub):
# bun exec runs a shell command string and deno eval inline code; deno task and repl are kept for their --eval. A word
# that may be an option's value (<value> 1) is read the same way, but kept only when it names one of these.
_k_sub() {
    case "$ipn:$1" in
        bun:exec) _deny_shell "bun exec" ;;
        deno:eval) _k_code "$1" ;;
        deno:task|deno:repl) ;;
        *)
            if (( $2 )); then
                return 0
            fi ;;
    esac
    ksub="$1"
    return 0
}

# _k_vault_value <option>: 0 if <option> is node's --env-file= or --env-file-if-exists= naming a file under the vault
# that the command does not move: a data file node loads, not code it runs, so pointing node at it is the vault's use.
_k_vault_value() {
    local v
    case "$ipn:${1%%=*}" in
        node:--env-file|node:--env-file-if-exists) ;;
        *) return 1 ;;
    esac
    if [[ "$1" != *=* ]]; then
        return 1
    fi
    v="${1#*=}"
    if ! _in_vault "$v"; then
        return 1
    fi
    if [[ "$v" == '$'* ]] && _cd_names CLAUDE_SECRET_DIR; then
        return 1
    fi
    return 0
}

# _k_env_sourced: 0 if the command, read with its quotes and backslashes removed, runs source or . at a command position
# (after builtin or command too), or set -a or set -o allexport: each may export variables the hook cannot see.
_k_env_sourced() {
    local cp='(^|[;&|(]|'$'\n'')[[:space:]]*((builtin|command)[[:space:]]+)?'
    local src_re="${cp}(source|\\.)([[:space:]]|$)"
    local set_re2="${cp}set[[:space:]]([^|;&]*[[:space:]])?(-[A-Za-z]*a[A-Za-z]*|-o[[:space:]]*allexport)"
    _cd_text
    [[ "$CDT" =~ $src_re || "$CDT" =~ $set_re2 ]]
}

# _deny_mount <form>: deny a doppler run that mounts the project's secrets in a file outside the vault.
_deny_mount() {
    local msg="SECRET-PATH BLOCK: '$1' writes the project's secrets to a file that is not known to be in the vault,"
    msg+=" where they can be read into context. Mount them into the vault ('--mount \$CLAUDE_SECRET_DIR/<name>')."
    hook_deny "$msg"
}

# _ry_mount <path>: note a doppler --mount into the vault (rmv); deny one anywhere else. A vault path built on
# $CLAUDE_SECRET_DIR is outside when the command may reassign it.
_ry_mount() {
    if _in_vault "$1" && { [[ "$1" != '$'* ]] || ! _cd_names CLAUDE_SECRET_DIR; }; then
        rmv=1
        return 0
    fi
    _deny_mount "doppler run --mount $1"
}

# _k_extract_to <dir>: note whether an oc extract --to names the vault (kxt): the last --to wins. A vault path built on
# $CLAUDE_SECRET_DIR is outside when the command may reassign it.
_k_extract_to() {
    kxt=0
    if _in_vault "$1" && { [[ "$1" != '$'* ]] || ! _cd_names CLAUDE_SECRET_DIR; }; then
        kxt=1
    fi
    return 0
}

# _dump_check: deny the pending printenv/declare/typeset/export (dk) if it would print the environment or a
# secret-named variable. dn counts name operands, da marks a NAME=value operand (it sets rather than prints), dp marks
# -p, dm marks zsh typeset -m, and db holds the first operand that is secret-named or holds $ or a glob character.
_dump_check() {
    local msg
    if [[ -n "$db" ]]; then
        msg="SECRET-ENV BLOCK: '$dk $db' could print a secret-bearing variable into context. Name a specific"
        msg+=" non-secret variable."
        hook_deny "$msg"
    fi
    msg="SECRET-ENV BLOCK: '$dk' with no variable name, -p, -m or a pattern can dump secret-bearing variables"
    msg+=" into context. Name a specific non-secret variable."
    case "$dk" in
        printenv) if (( dn == 0 )); then hook_deny "$msg"; fi ;;
        export) if (( dp || dn == 0 )); then hook_deny "$msg"; fi ;;
        *) if (( dm )) || { (( dn == 0 )) && { (( ! da )) || (( dp )); }; }; then hook_deny "$msg"; fi ;;
    esac
}

# _dump_start <kind>: begin collecting the operands of an environment dump, settling any one already pending.
_dump_start() {
    if [[ "$act" == *D* ]]; then
        _dump_check
    else
        act+=D
    fi
    dk="$1"
    dn=0
    da=0
    dp=0
    dm=0
    db=""
}

# _xargs_opt <word>: read a word of xargs's options (xo 1, or 2 after --): the replacement string of -I, -J, -i or
# --replace (xrep), an argument file (xaf), a word that is an option's value (xov). The first other word is the
# command: one holding the replacement string is named by the input, may be a shell, and is denied.
_xargs_opt() {
    local b c n
    if [[ -n "$xov" ]]; then
        if [[ "$xov" == I ]]; then
            xrep="$1"
        fi
        xov=""
        return 0
    fi
    if (( xo == 1 )); then
        case "$1" in
            --)
                xo=2
                return 0 ;;
            --?*)
                n="${1%%=*}"
                if (( ${#n} > 2 )) && [[ --replace == "$n"* ]]; then
                    if [[ "$1" == *=?* ]]; then xrep="${1#*=}"; else xrep='{}'; fi
                elif (( ${#n} > 2 )) && [[ --arg-file == "$n"* ]]; then
                    xaf=1
                    if [[ "$1" != *=* ]]; then xov=v; fi
                elif [[ "$1" != *=* && " delimiter max-args max-procs max-chars process-slot-var " == *" ${n#--}"* ]]
                then
                    xov=v
                fi
                return 0 ;;
            -?*)
                # The first letter that takes a value takes the rest of the bundle, or the next word.
                b="${1#-}"
                n="${b%%[IJiadELnPRSsel]*}"
                if [[ "$n" == "$b" ]]; then
                    return 0
                fi
                c="${b:${#n}:1}"
                b="${b:${#n}+1}"
                case "$c" in
                    I|J) if [[ -n "$b" ]]; then xrep="$b"; else xov=I; fi ;;
                    i) if [[ -n "$b" ]]; then xrep="$b"; else xrep='{}'; fi ;;
                    e|l) ;;
                    *)
                        if [[ "$c" == a ]]; then xaf=1; fi
                        if [[ -z "$b" ]]; then xov=v; fi ;;
                esac
                return 0 ;;
        esac
    fi
    xo=0
    if [[ -z "$xrep" ]]; then
        return 0
    fi
    if (( ${#1} > 4096 || ${#xrep} > 4096 )); then
        n="SECRET-SCAN ASK: xargs's replacement string or command is too long for the hook to tell whether its input"
        n+=" names the command. Approve it only if the command it runs is the one written."
        hook_hold_ask "$n"
    elif [[ "$1" == *"$xrep"* ]]; then
        _deny_shell "xargs running the command its input names ('$1')"
    fi
}

# Long options of sort, uniq, head and tail that take the next word as their value.
_NP_VAL=' key field-separator output buffer-size temporary-directory parallel batch-size compress-program'
_NP_VAL+=' random-source sort skip-fields skip-chars check-chars lines bytes pid sleep-interval max-unchanged-stats '
# fd's long options that may carry an =value and only filter what it lists; any other =value may change where it lists
# or what it prints. The long options a names-only grep or rg may take, spelled out: any other (--label, a colour, a
# path separator, an abbreviation) may change the names printed.
_NP_FD_VAL=' --extension --type --exclude --max-depth --min-depth --exact-depth --max-results --threads --size'
_NP_FD_VAL+=' --changed-within --changed-before --owner --ignore-file '
_NP_GREP_LONG=' --files-with-matches --files-without-match --recursive --dereference-recursive --ignore-case'
_NP_GREP_LONG+=' --no-ignore-case --invert-match --word-regexp --line-regexp --fixed-strings --extended-regexp'
_NP_GREP_LONG+=' --basic-regexp --perl-regexp --regexp --file --include --exclude --exclude-dir --no-messages --text'
_NP_GREP_LONG+=' --max-count --binary-files --devices --directories --null '
_NP_RG_LONG=' --files --files-with-matches --files-without-match --hidden --no-ignore --no-ignore-vcs --no-ignore-dot'
_NP_RG_LONG+=' --no-ignore-global --no-ignore-parent --no-ignore-exclude --no-ignore-files --follow --glob --iglob'
_NP_RG_LONG+=' --type --type-not --max-depth --ignore-case --smart-case --case-sensitive --fixed-strings --word-regexp'
_NP_RG_LONG+=' --line-regexp --regexp --file --invert-match --multiline --null --no-messages --max-count --sort --sortr'
_NP_RG_LONG+=' --threads --max-filesize --one-file-system --binary --text '

# _np_start: classify the stage's command word. snp marks a stage whose output names only paths the hook models: its
# own words, or a listing of them (echo, printf of %s, ls, find, fd, git ls-files, git diff --name-only, a names-only
# grep or rg), or a filter that only reorders or drops such lines (sort, uniq, head, tail, a plain grep); npk names the
# walk (_np_word) that checks its later words. echo needs no walk: the main loop clears snp for a word holding an
# escape or a brace expansion, which can print a name no word shows (zsh's echo reads \x2e as .), in any such stage.
_np_start() {
    snp=0
    npk=""
    if (( ! np_on )); then
        return 0
    fi
    case "$nm" in
        echo)
            snp=1
            npk='echo' ;;
        printf|ls|fd|find|git|sort|uniq|head|tail|grep|egrep|fgrep|rg)
            snp=1
            npk="$nm"
            npv=0
            npa=0
            npe=0
            npdd=0
            npf=0
            npx=0
            npl=0
            npn=0
            npg=""
            if [[ "$act" != *n* ]]; then act+=n; fi ;;
    esac
}

# _np_word <word>: check a later word of a stage _np_start marked. A word that makes the stage print anything but such
# names, or read a list (a file operand of a filter), clears snp; a grep option outside the filter's few sets npx.
_np_word() {
    local w="$1" b p v
    if (( ! snp )); then
        return 0
    fi
    if (( npv )); then
        npv=0
        return 0
    fi
    case "$npk" in
        printf)
            if (( npf )); then
                return 0
            fi
            if [[ "$w" == -- ]] && (( ! npdd )); then
                npdd=1
                return 0
            fi
            npf=1
            if [[ "$w" == -* || "$w" == *%[!s]* || "$w" == *% ]]; then snp=0; fi ;;
        ls)
            # A long format prints link targets, and -a or -f lists ..
            if (( ! npdd )) && [[ "$w" == -?* ]]; then
                if [[ "$w" == -- ]]; then
                    npdd=1
                elif [[ "$w" == --* || "$w" == *[afglno]* ]]; then
                    snp=0
                fi
            fi ;;
        fd)
            if (( ! npdd )); then
                case "$w" in
                    --) npdd=1 ;;
                    --exec*|--list-details|--format*) snp=0 ;;
                    # The root fd lists, and prints paths under: the separate-word form reaches _xd_word as a word.
                    --search-path=*|--base-directory=*)
                        v="${w#*=}"
                        if (( ${#v} > 4096 )); then
                            snp=0
                        else
                            _xd_word "$v"
                            if [[ "$v" == ..* || "$v" == */..* || "$v" == *'$'* || "/$v" =~ $DOT_PAT_RE ]]; then
                                wdd=1
                            fi
                        fi ;;
                    --*=*)
                        if [[ "$_NP_FD_VAL" != *" ${w%%=*} "* ]]; then snp=0; fi ;;
                    --*) ;;
                    -*) if [[ "$w" == *[xXl]* ]]; then snp=0; fi ;;
                esac
            fi ;;
        find)
            case "$w" in
                -exec*|-ok*|-printf|-fprint*|-ls|-fls|-files0-from) snp=0 ;;
            esac ;;
        git)
            # A pathspec with magic (:/ lists from the top of the work tree, as ../ paths).
            if [[ "$w" == :* ]]; then
                snp=0
            elif [[ "$w" == --name-only ]]; then
                npn=1
            fi ;;
        sort|uniq|head|tail)
            if (( npdd )) || [[ "$w" != -* ]]; then
                snp=0
                return 0
            fi
            case "$w" in
                -) ;;
                --) npdd=1 ;;
                --files0-from*) snp=0 ;;
                --*)
                    if [[ "$w" != *=* && "$_NP_VAL" == *" ${w#--} "* ]]; then npv=1; fi ;;
                *)
                    case "$npk" in
                        sort) v=koStT ;;
                        uniq) v=fsw ;;
                        head) v=nc ;;
                        *) v=ncbs ;;
                    esac
                    b="${w#-}"
                    p="${b%%[$v]*}"
                    if (( ${#p} + 1 == ${#b} )); then npv=1; fi ;;
            esac ;;
        grep|egrep|fgrep)
            if (( npdd )) || [[ "$w" != -?* ]]; then
                npa=$(( npa + 1 ))
                return 0
            fi
            if [[ "$w" == --?* && "$_NP_GREP_LONG" != *" ${w%%=*} "* ]]; then npl=1; fi
            case "$w" in
                --) npdd=1 ;;
                --regexp) npe=1; npv=1 ;;
                --regexp=*) npe=1 ;;
                --invert-match|--fixed-strings|--extended-regexp|--basic-regexp|--ignore-case|--word-regexp|\
                --line-regexp) ;;
                --*) npx=1 ;;
                *)
                    b="${w#-}"
                    p="${b%%[!vFEGiwx]*}"
                    if [[ "$p" != "$b" ]]; then
                        if [[ "${b:${#p}:1}" == e ]]; then
                            npe=1
                            if (( ${#p} + 1 == ${#b} )); then npv=1; fi
                        else
                            npx=1
                        fi
                    fi ;;
            esac ;;
        rg)
            if (( ! npdd )); then
                if [[ "$w" == -- ]]; then
                    npdd=1
                elif [[ "$w" == --?* && "$_NP_RG_LONG" != *" ${w%%=*} "* ]]; then
                    npl=1
                fi
            fi ;;
    esac
}

# _np_end: end the stage's check. A stage that is not a name producer (or one fed by an input redirection, which reads
# a list) marks the pipeline (pnu): a recursive reader after xargs in a later stage then asks. A grep is a producer
# when it lists names only with no long option outside _NP_GREP_LONG (npl), or filters with no file operand; rg when it
# lists names only with none outside _NP_RG_LONG; git for ls-files, or diff with --name-only.
_np_end() {
    if (( snp && rgr )); then
        snp=0
    fi
    if (( snp )); then
        case "$npk" in
            grep|egrep|fgrep)
                if (( snm )); then
                    if (( npl )); then snp=0; fi
                elif (( npx || npa + npe > 1 )); then
                    snp=0
                fi ;;
            rg)
                if (( ! snm || npl )); then snp=0; fi ;;
            git)
                if [[ "$npg" != ls-files ]] && { [[ "$npg" != diff ]] || (( ! npn )); }; then snp=0; fi ;;
        esac
    fi
    if (( ! snp )); then
        pnu=1
    fi
}

# Per-stage state. sf holds one letter per fact the stage-end checks read (R reader, S secret word, I secret input
# redirection, T tee or xargs, X xargs or parallel, Y a reader after xargs, P a printer, V a secret-named variable,
# F fed by an input redirection, A every word at command position, s a set at command position, L a registry credential
# location outside the vault (lga), Q a copier after xargs or parallel); act holds one letter per word walk still
# running (E env options, G git subcommand, I its options that run a command (_git_cmd_word), H shell program, K
# interpreter program, L interpreter inline code, C copier operands, D dump operands, O ps bundle, o ps options, J
# jq, W awk, U su/script/flock, N watch/parallel, Z a
# single-word fetch tool's subcommand, x an xargs -a value, f find up to its -exec, r a recursive reader's probe walk, c
# cd's operands, l a registry login or compose (lgt the command; lgl a login word, lgv a location value due; dcm 1 after
# compose, 2 after its config and 3 after another subcommand, with the facts of _dc_option and _dc_word), u a runner up
# to its subcommand (run_t), y the words after heroku run, doppler run or heroku local (_run_y), g find's executed
# command, d gpg or age, whose decrypt flag (dcf) makes the stage a fetch, k kubectl or oc (kt oc), whose get, secret
# resource and output flag (kg, ks, ko), or oc's extract (kx) with no --to into the vault (kxt; kxv a --to value due),
# make the stage a fetch). Each letter is added at most once, so neither string grows with the command. A value beside
# a letter is read only while the letter is set, so a stage resets in a few assignments.
sf=""
act=""
# The interpreter walk (K): kpv marks an option value due next, kvf holds a vault env file option held for the stage
# end, kon marks another option (kvw: this one is the vault env file), kfst marks the interpreter as the stage's first
# word, and kvp holds a vault env file whose script was seen, for the stage end's check that nothing feeds the stage;
# ksub holds bun's or deno's subcommand once _k_sub has read it.
kpv=0
kvf=""
ksub=""
kon=0
kfst=0
kvw=0
kvp=""
nw=0
nr=0
cs=0
si=0
nsep=0
pipe_sec=""
swf_stage=-1
ghs=0
ghp=0
GW_ACTIVE=0
# sgp marks a stage whose git subcommand has been read: its later words starting with : are git's (_git_ps_word); gev
# marks a stage with an env word, whose later assignment-shaped words may set a variable.
sgp=0
gev=0
GPW=""
pwrap=0
# Fetch facts: fd1 counts the stage's stdout redirections and fd1v marks the last one as a vault file; dbg marks a
# debug or verbose flag, sgs a security command and sgf a -g bundle after it (all in the first stage); lgst walks the
# second stage for a registry login, setting lgok, and lgpw marks --password-stdin there.
fd1=0
fd1v=0
dbg=0
sgs=0
sgf=0
lgst=0
lgok=0
lgpw=0
s1_fd1=0
s1_vault=0
s2_login=0
pw=""
# Directory-probe facts: PCWD caches the payload's cwd; RR_LIST marks a names-only walk settling, RR_RGCOL an rg walk
# collecting its roots in rrgl, and RR_DEEP a recursive reader's operands (a wildcard-only one stands for its
# directory); pipe_find holds the roots a pipeline's earlier stages list (a find, a names-only reader, a ** or brace
# glob); ffs marks a find in this stage and fxr a reader in its -exec; gcd is git -C's directory and gwp the word
# before, gwt marks a --git-dir or --work-tree and gcore a -c core or submodule setting, gal holds the -c aliases
# (name=value, space-separated) and gis, giv, gie and gib the I walk's facts (_git_cmd_word); the _wild_ strings hold
# the patterns expanded so far and those that matched a secret; wpend holds this stage's ** and brace globs (wgn of
# them, wgo past 64); ecd marks a stage that changes directory first (env -C).
PCWD=""
RR_LIST=0
RR_RGCOL=0
RR_DEEP=1
rrgl=""
pipe_find=""
ffs=0
fxr=0
gcd=""
gwp=""
gwt=0
gcore=0
gal=""
gis=""
giv=""
gie=0
gib=0
_wild_seen=$'\x1e'
_wild_hits=$'\x1e'
_wild_n=0
wpend=""
wgn=0
wgo=0
ecd=0
# Per stage too: nrd counts its reader words, srl marks a names-only walk, fxd a find -execdir or -okdir; rgr marks a
# stdin redirection, of kind rgk, from rgt; wpip holds the wildcard words' directories (wpq of them) a stage that does
# not read leaves to a reader after xargs.
nrd=0
srl=0
fxd=0
wpip=""
wpq=0
# wout holds the directories this stage's words name outside the cwd (wxn of them), which a stage that does not read
# adds to pipe_xd (pxn entries, at most 64, then a ! entry) for a recursive reader after xargs; PCWDN is the cwd
# normalised.
wout=""
wxn=0
pipe_xd=""
pxn=0
PCWDN=""
rgr=0
rgk=0
rgt=""
# The name-producer check (_np_start): snp, npk and the np walk's facts, snm a names-only grep or rg walk; pnu marks a
# pipeline whose earlier stage is no name producer. xargs's options (_xargs_opt): xo, xov, xrep, xaf; xqr marks a
# parallel that sets its own replacement strings; sxk is the kind the stage's reader after xargs lists roots with.
snp=0
npk=""
npv=0
npa=0
npe=0
npdd=0
npf=0
npx=0
npl=0
npn=0
npg=""
snm=0
pnu=0
xo=0
xov=""
xrep=""
xbr=0
xaf=0
xqr=0
sxk=""
RR_XDIR=""
# wdd marks a stage word that may name or match .., pdd an earlier stage of the pipeline holding one.
wdd=0
pdd=0
# A grep or rg default set in the environment or in the command (BSD grep reads GREP_OPTIONS, rg its config file), or
# a git directory, work tree or config set the same way, changes what the reader searches: the walks then assume the
# widest reading.
rr_grepenv=0
if [[ -n "${GREP_OPTIONS:-}" || "$cmd" == *GREP_OPTIONS* ]]; then
    rr_grepenv=1
fi
rr_rgenv=0
if [[ -n "${RIPGREP_CONFIG_PATH:-}" || "$cmd" == *RIPGREP_CONFIG_PATH* ]]; then
    rr_rgenv=1
fi
rr_gitenv=0
if [[ "$cmd" == *GIT_DIR* || "$cmd" == *GIT_WORK_TREE* ]]; then
    rr_gitenv=1
fi
rr_gitcfg=0
if [[ "$cmd" == *GIT_CONFIG* ]]; then
    rr_gitcfg=1
fi
# A pathspec setting (GIT_ICASE_PATHSPECS and kin, or a git --icase-pathspecs option) changes which names a pathspec
# matches, so one absent from a revision by its spelling may still read a file.
rr_gitps=0
if [[ "$cmd" == *PATHSPECS* || "$cmd" == *-pathspecs* || -n "${GIT_ICASE_PATHSPECS+x}" \
        || -n "${GIT_GLOB_PATHSPECS+x}" || -n "${GIT_NOGLOB_PATHSPECS+x}" || -n "${GIT_LITERAL_PATHSPECS+x}" ]]; then
    rr_gitps=1
fi
# The cd walk (_cd_word): cdd marks a --, cdn counts operands and cdo holds the first; cdc counts the cd commands so far
# (each costs a few pattern tests and a fork, so past CD_MAX the rest hold an ask unchecked), and cdtb the characters
# of the paths whose ancestors _cd_tree has tested (at most CD_TREE_BUDGET); cdp marks a command that sets CDPATH, or
# zsh's cdpath, which can send a relative cd anywhere (-1 until _cd_cdpath first looks); CDSID is the payload's
# session id once _cd_sid has read it (cdsf); CDT is the dequoted command once _cd_text has made it (cdtf); cddyn marks
# a write by a computed name (-1 until _cd_dyn first looks); cdk names the walked command (cd, pushd or popd).
CD_MAX=8
CD_TREE_BUDGET=262144
cdtb=0
cdd=0
cdn=0
cdo=""
cdk=""
cdtf=0
CDT=""
cddyn=-1
# cdsq marks a sequence separator (; && || & or a newline) seen so far: a command before it may have changed $PWD,
# $HOME, $OLDPWD or $CLAUDE_TEMP_DIR in ways no check models (zsh's print -v or vared, let, exec {NAME}>…). A pipe's
# stages are subshells, so | does not count.
cdsq=0
cdc=0
cdp=-1
cdsf=0
CDSID=""
# Quoted words: mk is the marker shell_words puts before a word (g: its glob characters are all quoted or escaped, d:
# its $ are), wmk the current word's. A marked glob is a literal name, unless the stage re-parses its words (srp: a
# shell, watch, parallel, su, a runner, an interpreter, eval, ssh) or runs an awk or sed program (ssa a or s) that can
# run a shell (sgv); so the first 64 marked glob words (wmq, wmqn of them) wait for the stage end, where such a stage
# expands them after all. The first marked secret-shaped $ word (vmq) is text too, unless the stage re-parses it, runs
# awk or sed, or ends at a pipe (spipe), whose next stage may expand it; vsa marks a V that came from awk or sed. rrg
# is the glob marker the rr walk records with each operand, and RR_LIT has _rr_root read its operand as a literal name.
# The sed walk (_sed_word): ssw marks a pending -e value, ssdd a --, and the first ssl operands (ssn so far) may be the
# program. The -e values join, newline between, into ssp (sse counts them, -f scripts included); with none, each of
# those operands waits in sso, and _sed_settle runs _sed_runs_shell on them at the stage end. The scan costs time in
# step with the program text, so the text collected over the whole command (sbud bytes) is held to SED_BUDGET_MAX.
_SED_NL=$'\n'
SED_WHY=""
SED_BUDGET_MAX=8192
sbud=0
mk=""
wmk=""
spipe=0
rrg=0
RR_LIT=0
# Operand roles: cw1 marks a word that is its stage's first command word (after assignments), wrole the role a walk
# gives the current word (P a pattern or an option's value, F the first positional, which is a pattern unless an option
# gave one, x a word that is neither but starts no command), wsx a word whose S came from a git pathspec or a wildcard,
# never P. A stage counts the S sources that are not P (snx, rdx the first), the P ones (spn), and whether an F one
# stands (spf, spfw the word); ngr counts a git reader subcommand no class lookup counts; gown and ghown mark git and gh
# as the first command word. The rr walk: rrown owns roles (the tool is the first command word), rrvf marks a pending
# value naming a file or a program, rrunk an option the tables do not know, which may take the next word as its value,
# and RR_ROLE the role _rr_word gives the word. rrasg marks a leading assignment, whose variable may change how the tool
# reads its options (GREP_OPTIONS, POSIXLY_CORRECT); a word the shell may expand or split sets rrunk too.
cw1=0
wrole=""
wsx=0
RR_ROLE=""
rrown=0
rrvf=0
rrunk=0
rrdyn=0
# The jq walk: jqown jq is the first command word and owns roles, jqq the roles of the next option values (P a value,
# S a file), jqf -f was seen, jqa --args or --jsonargs was seen, jqn the operands so far, jqdd -- was seen, jqunk an
# option the walk does not know; jqfs a -f option and jqbad an operand that is not a plain path were seen, in any jq
# stage.
jqown=0
jqq=""
jqf=0
jqa=0
jqn=0
jqdd=0
jqunk=0
jqfs=0
jqbad=0
JQ_NORM=""
# The git log, show and diff walk (act t): gtq the role of the next option value (P text, S a file), gtdd -- was seen,
# gtunk an option the walk does not know, gts the subcommand. For a diff that owns its roles, gdf defers the reader
# decision to the stage end: gdn an option that makes the output names only (--stat, --name-only) was seen, gdp one that
# may print contents, or that the walk does not know.
gtq=""
gtdd=0
gtunk=0
gts=""
gdf=0
gdn=0
gdp=0
# Long options of git log, show and diff that take no separate value.
_GT_FLAGS=' patch stat numstat shortstat name-only name-status summary dirstat no-patch oneline graph all decorate'
_GT_FLAGS+=' no-decorate no-merges merges first-parent reverse follow cached staged merge-base abbrev-commit'
_GT_FLAGS+=' no-abbrev-commit pretty color no-color no-renames relative quiet exit-code no-ext-diff no-textconv'
_GT_FLAGS+=' ignore-all-space ignore-space-change find-renames find-copies pickaxe-all pickaxe-regex'
_GT_FLAGS+=' regexp-ignore-case all-match invert-grep extended-regexp fixed-strings perl-regexp basic-regexp source'
_GT_FLAGS+=' full-diff word-diff raw full-index binary patch-with-stat patch-with-raw minimal histogram patience text'
_GT_FLAGS+=' date-order author-date-order topo-order left-right boundary cherry-pick cherry-mark cherry not branches'
_GT_FLAGS+=' tags remotes '

# _wild_check <word>: 0 if <word> is a wildcard the shell expands, where the command runs, into a secret name. A
# wildcard-only last component (cat *, cat ~/.aws/*) is expanded where the command will run, and a pattern in a
# directory part (cat */*) queues its directory for the stage end. The test that the word ends in a wildcard or holds
# a pattern before a / keeps the function call off the glob-heavy hot path (cat a1* a2* …).
_wild_check() {
    local wc
    if (( ${#1} > 4096 )) || [[ "$1" != *[\*\?] && "$1" != *[\*\?\[\{]*/* ]]; then
        return 1
    fi
    # With 64 patterns expanded, wpip already marked unknown and an ask held, _wild_word changes nothing for a word with
    # no pattern before its last /, so it is not called.
    if (( _wild_n >= 64 && wpq >= 64 )) && [[ "$wpip" == '!'* && -n "${_HOOK_HELD_ASK:-}" \
            && "$1" != *[\*\?\[\{]*/* ]]; then
        return 1
    fi
    if [[ "$1" == */* ]]; then
        wc="${1%/*}"
        wc="${1:${#wc}+1}"
    else
        wc="$1"
    fi
    [[ "$1" == *[\*\?\[\{]*/* || "$wc" != *[!\*\?]* ]] && _wild_word "$1"
}

# _awk_word <word>: set sgv when a word of an awk stage may make its program run a shell: system, getline, a | or an @
# (gawk's @include, @load and indirect calls) in any word (a program given as an operand, by -e or by --source), or an
# option that loads code the hook cannot see (-f, -E, -i, -l, -D, mawk's -W, and the long options starting with those
# letters).
_awk_word() {
    if [[ "$1" == *system* || "$1" == *getline* || "$1" == *'|'* || "$1" == *@* || "$1" == --[defil]* \
            || ( "$1" == -[!-]* && "${1%%[Fv]*}" == *[fEilDW]* ) ]]; then
        sgv=1
    fi
}

# The sed scanner reads a program by byte index (the hook runs under LC_ALL=C, so ${P:i:1} costs the same at any index,
# where slicing off the rest at each step is quadratic) and shares the caller's P (program), i (index), L (length),
# d (delimiter) and aw (bracket reading).
# _sed_blanks: past spaces and tabs.
_sed_blanks() {
    while (( i < L )); do
        case "${P:i:1}" in
            ' '|$'\t') i=$(( i + 1 )) ;;
            *) return 0 ;;
        esac
    done
    return 0
}

# _sed_digits: past decimal digits.
_sed_digits() {
    while (( i < L )); do
        case "${P:i:1}" in
            [0-9]) i=$(( i + 1 )) ;;
            *) return 0 ;;
        esac
    done
    return 0
}

# _sed_eol: past the next newline, or to the end.
_sed_eol() {
    while (( i < L )); do
        i=$(( i + 1 ))
        if [[ "${P:i-1:1}" == "$_SED_NL" ]]; then
            return 0
        fi
    done
    return 0
}

# _sed_label: past a label: anything but white space, ; and }.
_sed_label() {
    while (( i < L )); do
        case "${P:i:1}" in
            [[:space:]]|';'|'}') return 0 ;;
            *) i=$(( i + 1 )) ;;
        esac
    done
    return 0
}

# _sed_eoc: 0 at the end of a sed command: past blanks, the end of the program or one of ; } # newline.
_sed_eoc() {
    _sed_blanks
    if (( i >= L )); then
        return 0
    fi
    case "${P:i:1}" in
        ';'|'}'|'#'|"$_SED_NL") return 0 ;;
    esac
    return 1
}

# _sed_skip_delim <regex>: past the closing delimiter d of the text at i, honouring \ escapes; with <regex> 1 and aw 1,
# a [...] bracket expression may hold d. Returns 1 if the text is unterminated.
_sed_skip_delim() {
    local c k
    while (( i < L )); do
        c="${P:i:1}"
        i=$(( i + 1 ))
        if [[ "$c" == "$d" ]]; then
            return 0
        elif [[ "$c" == '\' ]]; then
            i=$(( i + 1 ))
        elif [[ "$c" == '[' && "$1" == 1 && "$aw" == 1 ]]; then
            k=$i
            if [[ "${P:k:1}" == '^' ]]; then k=$(( k + 1 )); fi
            if [[ "${P:k:1}" == ']' ]]; then k=$(( k + 1 )); fi
            while :; do
                if (( k >= L )); then
                    return 1
                fi
                c="${P:k:1}"
                k=$(( k + 1 ))
                if [[ "$c" == ']' ]]; then
                    break
                fi
                if [[ "$c" == '[' ]]; then
                    case "${P:k:1}" in
                        ':'|'.'|'=')
                            c="${P:k:1}"
                            k=$(( k + 1 ))
                            while :; do
                                if (( k + 1 >= L )); then
                                    return 1
                                fi
                                if [[ "${P:k:1}" == "$c" && "${P:k+1:1}" == ']' ]]; then
                                    k=$(( k + 2 ))
                                    break
                                fi
                                k=$(( k + 1 ))
                            done ;;
                    esac
                fi
            done
            i=$k
        fi
    done
    return 1
}

# _sed_addr: past one sed address at i (d too): 0 if one was there, 1 if none, 2 if it is malformed.
_sed_addr() {
    local c="${P:i:1}"
    case "$c" in
        [0-9])
            _sed_digits
            if [[ "${P:i:1}" == '~' ]]; then
                i=$(( i + 1 ))
                _sed_digits
            fi ;;
        '$')
            i=$(( i + 1 )) ;;
        /|'\')
            if [[ "$c" == / ]]; then
                d=/
                i=$(( i + 1 ))
            else
                d="${P:i+1:1}"
                i=$(( i + 2 ))
            fi
            if [[ -z "$d" || "$d" == "$_SED_NL" || "$d" == '\' ]] || ! _sed_skip_delim 1; then
                return 2
            fi
            while [[ "${P:i:1}" == [IM] ]]; do
                i=$(( i + 1 ))
            done ;;
        *)
            return 1 ;;
    esac
    return 0
}

# _sed_parse <program> <aw>: walk the sed program's commands, reading a [...] bracket in a regex as one when <aw> is 1
# (POSIX, BSD sed) and not when 0 (GNU sed ends a regex at the first delimiter). Returns 0 for a program with no e
# command and no s///e flag, 1 on finding one, 2 if the program cannot be parsed, 3 on an r or R command whose file name
# (to the end of its line) is a secret path, 4 on one whose name holds a backslash, which the hook cannot screen (the
# name is cut at it for the secret test). Either bracket reading returning 1, 3 or 4 decides; 2 only when both do.
_sed_parse() {
    local P="$1" aw="$2" L=${#1} i=0 c d a j
    while :; do
        while (( i < L )); do
            case "${P:i:1}" in
                [[:space:]]|';'|'{'|'}') i=$(( i + 1 )) ;;
                *) break ;;
            esac
        done
        if (( i >= L )); then
            return 0
        fi
        if _sed_addr; then a=0; else a=$?; fi
        if (( a == 2 )); then
            return 2
        fi
        if (( a == 0 )); then
            _sed_blanks
            if [[ "${P:i:1}" == ',' ]]; then
                i=$(( i + 1 ))
                _sed_blanks
                case "${P:i:1}" in
                    '+'|'~')
                        i=$(( i + 1 ))
                        _sed_digits ;;
                    *)
                        if ! _sed_addr; then
                            return 2
                        fi ;;
                esac
            fi
        fi
        while (( i < L )); do
            case "${P:i:1}" in
                [[:space:]]|'!') i=$(( i + 1 )) ;;
                *) break ;;
            esac
        done
        c="${P:i:1}"
        i=$(( i + 1 ))
        case "$c" in
            '{'|'}') ;;
            [=dDgGhHnNpPxzF])
                if ! _sed_eoc; then
                    return 2
                fi ;;
            [qQl])
                _sed_blanks
                _sed_digits
                if ! _sed_eoc; then
                    return 2
                fi ;;
            s|y)
                d="${P:i:1}"
                i=$(( i + 1 ))
                if [[ -z "$d" || "$d" == "$_SED_NL" || "$d" == '\' ]]; then
                    return 2
                fi
                if [[ "$c" == s ]]; then
                    if ! _sed_skip_delim 1 || ! _sed_skip_delim 0; then
                        return 2
                    fi
                    while (( i < L )); do
                        case "${P:i:1}" in
                            [0-9gpiImM]) i=$(( i + 1 )) ;;
                            *) break ;;
                        esac
                    done
                    case "${P:i:1}" in
                        e) return 1 ;;
                        w)
                            _sed_eol
                            continue ;;
                    esac
                else
                    if ! _sed_skip_delim 0 || ! _sed_skip_delim 0; then
                        return 2
                    fi
                fi
                if ! _sed_eoc; then
                    return 2
                fi ;;
            [aic])
                while (( i < L )); do
                    j="${P:i:1}"
                    if [[ "$j" == "$_SED_NL" ]]; then
                        i=$(( i + 1 ))
                        break
                    elif [[ "$j" == '\' ]]; then
                        i=$(( i + 2 ))
                    else
                        i=$(( i + 1 ))
                    fi
                done ;;
            [rR])
                _sed_blanks
                j=$i
                _sed_eol
                d="${P:j:i-j}"
                d="${d%"$_SED_NL"}"
                name_fold "${d%%\\*}"
                if path_is_secret "$NAME_FOLD"; then
                    return 3
                fi
                if [[ "$d" == *\\* ]]; then
                    return 4
                fi ;;
            [wW]|'#')
                _sed_eol ;;
            ':')
                _sed_blanks
                j=$i
                _sed_label
                if (( i == j )); then
                    return 2
                fi ;;
            [btTv])
                _sed_blanks
                _sed_label ;;
            e)
                return 1 ;;
            *)
                return 2 ;;
        esac
    done
}

# _sed_runs_shell <program>: 0 if the sed program may run a shell (an e command, an s///e flag), reads a secret file (an
# r or R command) or cannot be parsed, with SED_WHY e, read or parse; 1 for a program that parses with none of them,
# which is when one bracket reading succeeds and neither finds an e or a secret read. A program with no [ reads the
# same both ways.
_sed_runs_shell() {
    local a=0 b=0
    SED_WHY=""
    if (( ${#1} > SED_BUDGET_MAX )); then
        SED_WHY=parse
        return 0
    fi
    _sed_parse "$1" 0 || a=$?
    if [[ "$1" == *'['* ]]; then
        _sed_parse "$1" 1 || b=$?
    else
        b=$a
    fi
    if (( a == 1 || b == 1 )); then
        SED_WHY=e
        return 0
    fi
    if (( a == 3 || b == 3 )); then
        SED_WHY="read"
        return 0
    fi
    if (( a == 4 || b == 4 )); then
        SED_WHY=parse
        return 0
    fi
    if (( a == 2 && b == 2 )); then
        SED_WHY=parse
        return 0
    fi
    return 1
}

# _sed_budget <text>: count <text> against the command's sed program budget; deny when it is spent.
_sed_budget() {
    sbud=$(( sbud + ${#1} + 1 ))
    # A $'…' escape stays as written (\n, \x2e), so the program the shell passes is not the text parsed here.
    if (( sbud > SED_BUDGET_MAX )) || [[ "$wmk" == *a* && "$1" == *\\* ]]; then
        sgv=1
        _deny_shell "a sed program the guard cannot parse"
    fi
}

# _sed_expr <text>: take an -e value of the sed stage as one of its programs, joined to the others by a newline.
_sed_expr() {
    if (( sse )); then
        ssp+="$_SED_NL"
    fi
    sse=$(( sse + 1 ))
    _sed_budget "$1"
    ssp+="$1"
}

# _sed_settle: at the end of a sed stage, deny a program that may run a shell or that the hook cannot parse. The
# programs are the -e values joined; with none, the operands that may be the program (sso). When an option of unknown
# arity (ssunk) leaves the program's place open, every one is screened; otherwise only the first must parse, as the
# others are files or BSD's program (BSD sed has no e). BSD's -i value (ssix), when it is empty or a bare suffix, is no
# program, and when it is empty (BSD's -i '') the operand after it is. An e command or a secret r reading is denied in
# any operand.
_sed_settle() {
    local why="" i=0 n=${#sso[@]} p
    if [[ "$ssa" != s ]]; then
        return 0
    fi
    if (( sse )); then
        if _sed_runs_shell "$ssp"; then why="$SED_WHY"; fi
    else
        while (( i < n )); do
            p="${sso[i]}"
            if _sed_runs_shell "$p"; then
                if [[ "$SED_WHY" == e || "$SED_WHY" == read ]]; then
                    why="$SED_WHY"
                    break
                elif (( i == ssix )) && [[ "$p" != *[!A-Za-z0-9._~+@%-]* ]]; then
                    :
                elif (( ssunk || i == 0 )) || { (( ssix >= 0 && i == ssix + 1 )) && [[ -z "${sso[ssix]}" ]]; }; then
                    why="$SED_WHY"
                    break
                fi
            fi
            i=$(( i + 1 ))
        done
    fi
    if [[ -n "$why" ]]; then
        sgv=1
        if [[ "$why" == e ]]; then
            _deny_shell "sed with an e command"
        fi
        if [[ "$why" == read ]]; then
            _deny_reader "sed with an r or R command on a secret file"
        fi
        _deny_shell "a sed program the guard cannot parse"
    fi
}

# _script_file_check <file>: deny a sed or awk script file that is standard input or a descriptor (-, /dev, /proc, a ..
# segment), or whose name a $ or backquote builds: the hook cannot see the program such a file holds. A name under
# $CLAUDE_TEMP_DIR is the remedy the denies give, so only what follows that prefix is tested. The name must also be
# literal: a backslash (an escape that stays as written) or an unquoted glob or brace (the marker g says they are all
# quoted) is expanded by the shell into a name the hook never saw.
_script_file_check() {
    local sfile="$1"
    case "$1" in
        '$CLAUDE_TEMP_DIR/'*|'${CLAUDE_TEMP_DIR}/'*) sfile="${1#*/}" ;;
    esac
    if [[ "$1" == - || "$sfile" == *[\$\`\\]* ]] || [[ "$sfile" == *[\*\?\[\{]* && "$wmk" != *g* ]] \
            || _names_input "$sfile" fd; then
        _deny_shell "sed or awk -f with the program on standard input or a descriptor" \
            "Write the program to a plain file with the Write tool and pass that file to -f."
    fi
}

# _awk_file_opt <value> <kind>: take the value of an awk option that names a script file: the joined text <value>, or
# the next word when it is empty (awfv). <kind> W is mawk's -W: only exec, e and file (any prefix) take a file, as
# "-W exec FILE" or "-Wexec=FILE".
_awk_file_opt() {
    local v="$1"
    if [[ "$2" == W ]]; then
        case "$v" in
            e*|f*|E*|F*) ;;
            *) return 0 ;;
        esac
        if [[ "$v" == *=* ]]; then
            v="${v#*=}"
        else
            v=""
        fi
    fi
    if [[ -n "$v" ]]; then
        _script_file_check "$v"
    else
        awfv=1
    fi
}

# _awk_file_word <word>: walk a word of an awk stage for its script file, which _script_file_check screens: -f and -E
# (alone or anywhere in a short bundle, the value joined or the next word), the long --file and --exec in any prefix
# gawk accepts, with = or the next word, and mawk's -W exec or file. F, v, e, i, l and D take the rest of the bundle.
_awk_file_word() {
    local b c
    if (( awfv )); then
        awfv=0
        _script_file_check "$1"
        return 0
    fi
    if (( awfw )); then
        awfw=0
        _awk_file_opt "$1" W
        return 0
    fi
    case "$1" in
        --*)
            case "${1%%=*}" in
                --f|--fi|--fil|--file|--e|--ex|--exe|--exec|--i|--in|--inc|--incl|--inclu|--includ|--include\
                |--l|--lo|--loa|--load)
                    if [[ "$1" == *=* ]]; then _script_file_check "${1#*=}"; else awfv=1; fi ;;
            esac ;;
        -?*)
            b="${1:1}"
            while [[ -n "$b" ]]; do
                c="${b:0:1}"
                b="${b:1}"
                case "$c" in
                    f|E) _awk_file_opt "$b" f; return 0 ;;
                    i|l)
                        # gawk's -i and -l take the rest of the bundle as their value, but the rest is walked as
                        # letters too (-il FILE), so a script file named in the next word is not missed.
                        _awk_file_opt "$b" f
                        if [[ -z "$b" ]]; then return 0; fi ;;
                    W)
                        if [[ -n "$b" ]]; then _awk_file_opt "$b" W; else awfw=1; fi
                        return 0 ;;
                    F|v|e|D) return 0 ;;
                esac
            done ;;
    esac
}

# _sed_word <word>: walk a word of a sed stage. The program is an -e or --expression value (joined or the next word),
# or one of the first ssl operands; -f or --file loads a script the hook cannot see. A letter that may take the next
# word as its value (BSD's -i and -I, GNU's -l, any unknown one) lets one more operand be the program.
_sed_word() {
    local b c iv=$ssiv unk=0
    ssiv=0
    if (( ssvs || ssfv )); then
        if (( ssvs )); then
            ssvs=0
            # A value that looks like an option is walked as one: -l -f - would otherwise hide the -f.
            if [[ "$1" != -* ]]; then
                return 0
            fi
        fi
        if (( ssfv )); then
            ssfv=0
            _script_file_check "$1"
            return 0
        fi
    fi
    if (( ssw )); then
        ssw=0
        _sed_expr "$1"
        return 0
    fi
    if (( ! ssdd )); then
        case "$1" in
            --) ssdd=1; return 0 ;;
            --e*=*) _sed_expr "${1#*=}"; return 0 ;;
            --e*) ssw=1; return 0 ;;
            --fi*=*) sse=$(( sse + 1 )); sgv=1; _script_file_check "${1#*=}"; return 0 ;;
            --fi*) sse=$(( sse + 1 )); sgv=1; ssfv=1; return 0 ;;
            --f*) sgv=1; return 0 ;;
            --*=*) return 0 ;;
            --l*) ssvs=1; return 0 ;;
            --[qsdpnzubrhvi]*) return 0 ;;
            --*) ssl=$(( ssl + 1 )); ssunk=$(( ssunk + 1 )); return 0 ;;
            -?*)
                b="${1:1}"
                while [[ -n "$b" ]]; do
                    c="${b:0:1}"
                    b="${b:1}"
                    case "$c" in
                        [nrEsuza]) ;;
                        e)
                            if [[ -n "$b" ]]; then _sed_expr "$b"; else ssw=1; fi
                            return 0 ;;
                        f)
                            sse=$(( sse + 1 ))
                            sgv=1
                            if [[ -n "$b" ]]; then _script_file_check "$b"; else ssfv=1; fi
                            return 0 ;;
                        l)
                            if [[ -z "$b" ]]; then ssvs=1; fi
                            return 0 ;;
                        i|I)
                            if [[ -z "$b" ]]; then ssl=$(( ssl + 1 )); ssiv=1; fi
                            return 0 ;;
                        *)
                            # The rest of the bundle is still walked: -Xf - holds an -f.
                            if (( ! unk )); then
                                unk=1
                                ssl=$(( ssl + 1 ))
                                ssunk=$(( ssunk + 1 ))
                            fi ;;
                    esac
                done
                return 0 ;;
        esac
    fi
    if (( ssn < ssl )); then
        ssn=$(( ssn + 1 ))
        _sed_budget "$1"
        if (( iv )); then
            ssix=${#sso[@]}
        fi
        sso+=("$1")
    fi
}

# _sed_rename <word>: a further sed name <word> at command position (a wrapper's option value may have come first)
# starts the command's own operands: drop <word> if it was taken as an operand (after a check for an e command: a
# word ending in /sed is a sed name by its basename), screen what was read, then walk afresh. sgv and the other awk and
# sed facts already decided stay.
_sed_rename() {
    local n=${#sso[@]}
    if (( n > 0 )) && [[ "${sso[$(( n - 1 ))]}" == "$1" ]]; then
        if _sed_runs_shell "$1" && [[ "$SED_WHY" == e || "$SED_WHY" == read ]]; then
            sgv=1
            if [[ "$SED_WHY" == read ]]; then
                _deny_reader "sed with an r or R command on a secret file"
            fi
            _deny_shell "sed with an e command"
        fi
        unset "sso[$(( n - 1 ))]"
        ssn=$(( ssn - 1 ))
    fi
    _sed_settle
    sse=0
    ssp=""
    sso=()
    ssix=-1
    ssiv=0
    ssvs=0
    ssfv=0
    ssunk=0
    ssn=0
    ssl=1
    ssw=0
    ssdd=0
}

# _mk_settle: in a stage that re-parses its words or runs a shell from awk or sed, expand the marked glob words after
# all.
_mk_settle() {
    local rest="$wmq" w
    if (( ! srp && ! sgv )); then
        return 0
    fi
    while [[ -n "$rest" ]]; do
        w="${rest%%$'\x1e'*}"
        rest="${rest#*$'\x1e'}"
        if _wild_check "$w"; then
            if [[ "$sf" != *S* ]]; then rds="$w"; sf+=S; fi
            _snx "$w"
        fi
    done
}

# _snx <word>: count an S source that is not a P word; rdx names the first.
_snx() {
    snx=$(( snx + 1 ))
    if [[ -z "$rdx" ]]; then
        rdx="$1"
    fi
}

# _w_expands: 0 when the current word holds a glob, a brace, a $ or a backquote the shell may expand or split, that no
# marker says is quoted.
_w_expands() {
    [[ "$w" == *\`* || "$wmk" == *b* ]] || [[ "$w" == *[\*\?\[\{]* && "$wmk" != *g* ]] \
        || [[ "$w" == *\$* && "$wmk" != *d* ]]
}

# _asm_hold <text> <what>: hold an ask for the current word when <text>, the part of it that names a tool or a git
# option or subcommand, is one the shell may assemble: a numeric escape kept as written (\x \u \U \0-\7 of a $'...'
# body; other backslashes assemble nothing), or a $, backquote, glob or brace with a comma or a x..y sequence in it that
# no marker says is quoted ({} and {+..} stand for themselves). Plain quotes are decoded, so none survives into a name.
# The tool's screens run on its literal name, so an assembled one skips them.
_asm_hold() {
    local msg
    if [[ "$1" == *\\[xuU0-7]* || "$wmk" == *n* ]] || { [[ "$wmk" == *b* && "$1" == "$w" ]]; } \
            || { [[ "$1" == *[\$\`\*\?\[]* || "$1" == *\{*,*\}* || "$1" == *\{?*..?*\}* ]] && _w_expands; }; then
        msg="SECRET-SCAN ASK: $2 '$w' may be assembled by the shell, so the hook cannot tell which tool or git"
        msg+=" subcommand runs."
        if [[ "$2" == a\ word\ of* ]]; then msg+=" (An --opt=value value is not held.)"; fi
        msg+=" Approve it only if that reads no secret file."
        hook_hold_ask "$msg"
    fi
}

# _p_void: the stage's P and F roles are void, so each of their S sources counts as one that is not P.
_p_void() {
    if (( spn + spf > 0 )) && [[ -z "$rdx" ]]; then
        rdx="$rds"
    fi
    snx=$(( snx + spn + spf ))
    spn=0
    spf=0
}

# _p_clear: 0 when R and S do not deny: every S source is a P or F word and the stage has exactly one reader.
_p_clear() {
    (( snx == 0 && spn + spf > 0 && nrd + ngr == 1 ))
}

# _jq_mod_check <word>: deny a word of a jq stage that loads a module by a name the hook cannot read, whatever wraps the
# jq and wherever the walk thinks the word stands.
_jq_mod_check() {
    local w="$1" msg bad=0
    if [[ "$w" == *modulemeta* ]]; then
        bad=1
    elif [[ "$w" == *import* || "$w" == *include* ]]; then
        # An escape, a search path in the import's metadata, or a live $ hides the module's name.
        if [[ "$w" == *\\* || "$w" == *search* ]] || [[ "$w" == *\$* && "$wmk" != *d* ]]; then
            bad=1
        fi
    fi
    if (( bad )); then
        msg="SECRET-PATH BLOCK: this jq filter loads a module by a name the hook cannot read (modulemeta, or an"
        msg+=" import or include path written with an escape, a search path or a variable), so it may read a secret"
        msg+=" file. Name the module in a plain import literal, or read the file with a plain reader."
        hook_deny "$msg"
    fi
    # With -f the program is a file the hook cannot see read: every operand of the stage, in either order, must be a
    # plain path.
    if [[ "$w" == --from-file ]] || [[ "$w" == -[!-]* && "$w" == *f* ]]; then
        jqfs=1
    elif [[ "$w" != -* || "$w" == - ]]; then
        # Only a word that is not obviously a plain path needs the full test.
        if [[ "$w" == *[!A-Za-z0-9._/+-]* || "$w" == - || "$w" == *..* || "$w" == *//* || "$w" == */./* \
            || "$w" == /[DdPp]* ]] && ! _jq_path_ok "$w"; then
            jqbad=1
        fi
    fi
    if (( jqfs && jqbad )); then
        msg="SECRET-PATH BLOCK: this jq has -f and an operand that may be its program on standard input or a"
        msg+=" descriptor, where the hook cannot see it (a path outside [A-Za-z0-9._/+-], -, /dev, /proc or one"
        msg+=" through ..). Write the program to a plain file and pass that file to -f."
        hook_deny "$msg"
    fi
}

# _jq_path_ok <word>: 0 when the word is a plain path (only [A-Za-z0-9._/+-]) that is not -, under /dev or /proc (any
# case), or through a .. segment once repeated slashes, /./ segments and a leading ./ are removed.
_jq_path_ok() {
    local re='^[A-Za-z0-9._/+-]+$'
    if [[ ! "$1" =~ $re ]]; then
        return 1
    fi
    _jq_norm "$1"
    case "$JQ_NORM" in
        -|..|../*|*/../*|*/..|/[Dd][Ee][Vv]|/[Dd][Ee][Vv]/*|/[Pp][Rr][Oo][Cc]|/[Pp][Rr][Oo][Cc]/*) return 1 ;;
    esac
    return 0
}

# _jq_norm <path>: set JQ_NORM to the path with repeated slashes collapsed, /./ segments and a leading ./ removed.
_jq_norm() {
    local n="$1" sl=/
    while [[ "$n" == *//* ]]; do
        n="${n//\/\//$sl}"
    done
    while [[ "$n" == */./* ]]; do
        n="${n//\/.\//$sl}"
    done
    while [[ "$n" == ./* ]]; do
        n="${n#./}"
    done
    JQ_NORM="$n"
}

# _jq_word <word>: give a word of a jq that is its stage's first command word its role in wrole: an --arg name or value
# P, the filter F (unless it names a module to import or include), anything else (an input, a program or a --rawfile
# file, a word after --args) a file.
_jq_word() {
    local w="$1" known c i n
    wrole=""
    if [[ -z "$jqq" ]] && (( ! jqdd )); then
        # A $'...' escape stays as written in the word (\x2d for -): a leading numeric one may be an option, and one
        # inside an option word may be a letter such as f. Other escapes decode to no letter.
        case "$w" in
            \\[xuU0-7]*|-*\\[xuU0-7]*) jqunk=1 ;;
        esac
    fi
    if (( jqa )); then
        if [[ "$w" == --from-file ]] || [[ "$w" == -[!-]* && "$w" == *f* ]]; then
            jqf=1
        fi
        return 0
    fi
    if [[ -n "$jqq" ]]; then
        if [[ "$jqq" == P* ]]; then
            wrole=P
        fi
        jqq="${jqq:1}"
        return 0
    fi
    if (( jqdd )) || [[ "$w" != -* || "$w" == - ]]; then
        if (( jqn == 0 )) && [[ "$w" != *import* && "$w" != *include* && "$w" != *modulemeta* ]]; then
            wrole=F
        fi
        jqn=$(( jqn + 1 ))
        return 0
    fi
    case "$w" in
        --)
            jqdd=1 ;;
        --arg|--argjson)
            jqq=PP ;;
        --rawfile|--slurpfile|--argfile)
            jqq=PS ;;
        --indent)
            jqq=P ;;
        --library-path)
            jqq=S ;;
        --from-file)
            jqf=1 ;;
        --args|--jsonargs)
            jqa=1 ;;
        --*)
            known=' null-input raw-input slurp compact-output tab raw-output raw-output0 join-output ascii-output'
            known+=' sort-keys color-output monochrome-output unbuffered stream stream-errors seq exit-status binary '
            if [[ "$known" != *" ${w#--} "* ]]; then
                jqunk=1
            fi ;;
        *)
            c="${w#-}"
            n=${#c}
            i=0
            while (( i < n )); do
                case "${c:i:1}" in
                    f) jqf=1 ;;
                    L)
                        if (( i == n - 1 )); then
                            jqq=S
                        else
                            jqunk=1
                        fi ;;
                    [nrjasecCMSRhV]) : ;;
                    *) jqunk=1 ;;
                esac
                i=$(( i + 1 ))
            done ;;
    esac
}

# _jq_settle: in a jq stage that owns its roles, an unknown option voids them; with -f the first operand is the program
# file, not the filter.
_jq_settle() {
    if (( ! jqown )); then
        return 0
    fi
    if (( jqunk )); then
        _p_void
    elif (( jqf && spf )); then
        _snx "$spfw"
        spf=0
    fi
}

# _gt_word <word>: give a word of a git log, show or diff that is its stage's first command word its role in wrole: the
# value of a pickaxe, grep, author, date, count or format option is text (P); a revision, a pathspec, the file of -L and
# every word after -- are possible files. Any other word gets role x: git runs none of them, so a revision named HEAD is
# no head command.
_gt_word() {
    local w="$1"
    wrole=x
    if (( gtdd )); then
        return 0
    fi
    if [[ -n "$gtq" ]]; then
        if [[ "$gtq" == P ]]; then
            wrole=P
        fi
        gtq=""
        return 0
    fi
    case "$w" in
        --)
            gtdd=1 ;;
        -S|-G|-n|--grep|--author|--committer|--since|--until|--skip)
            gtq=P ;;
        -L)
            gtq=S ;;
        -S?*|-G?*|-n?*|--grep=*|--author=*|--committer=*|--format=*|--pretty=*|--since=*|--until=*|--skip=*)
            wrole=P ;;
        --*=*)
            : ;;
        --*)
            if [[ "$_GT_FLAGS" != *" ${w#--} "* ]]; then
                gtunk=1
            fi ;;
        -[0-9]*|-[MCBUl]*|-[pusRwbaiEFPzWmctr])
            : ;;
        -*|\\[xuU0-7]*)
            # A $'...' escape stays as written in the word (\x2d for -), so a leading one may be an option or --.
            gtunk=1 ;;
    esac
    if [[ "$gts" == diff ]]; then
        if [[ "$w" == -* && "$w" != -- ]]; then
            _gt_diff_opt "$w"
        elif [[ "$w" == *\\* ]]; then
            # shell_words decodes a backslash outside $'...' but leaves a $'...' escape (\x2d, \055, -) as
            # written, so such a word may decode to an option the walk cannot read.
            gdp=1
        fi
    fi
}

# _gt_diff_opt <option>: classify an option of a git diff. One that makes the output names and counts only (gdn) is no
# reader on its own; one that is neutral to that changes nothing; any other, an unknown one included, may print contents
# (gdp).
_gt_diff_opt() {
    case "$1" in
        --stat|--stat=*|--numstat|--shortstat|--name-only|--name-status|--summary|--dirstat|--dirstat=*|-s|\
        --no-patch|--quiet)
            gdn=1 ;;
        --cached|--staged|--merge-base|-M*|--find-renames|--find-renames=*|-C*|--find-copies|--find-copies=*|-B*|\
        --relative|--relative=*|--no-renames|--color|--color=*|--no-color|--no-ext-diff|--no-textconv|-R|\
        --diff-filter=*|--ignore-submodules|--ignore-submodules=*|-w|--ignore-all-space|--ignore-space-change|\
        --exit-code)
            : ;;
        *)
            gdp=1 ;;
    esac
}

# _gt_settle: in a git log, show or diff stage that owns its roles, an unknown option voids them. A diff that owns its
# roles is a reader unless a names-only option stands, no option may print contents, and nothing may reshape the words:
# a variable that holds a secret (V) is printed by git's own error for a word that names no revision or path.
_gt_settle() {
    if (( gtunk )); then
        _p_void
    fi
    if (( gdf )) && { (( ! gdn || gdp || gtunk )) || [[ "$sf" == *V* || -n "$vmq" ]]; }; then
        ngr=1
        if [[ "$sf" != *R* ]]; then
            rdn="git diff"
            sf+=R
        fi
        if [[ "$sf" == *X* && "$sf" != *Y* ]]; then sf+=Y; fi
    fi
}

# _mk_vsettle: a marked secret-shaped $ word is a V after all in a stage that re-parses its words, runs awk or sed, or
# feeds a pipe.
_mk_vsettle() {
    if [[ -z "$vmq" ]]; then
        return 0
    fi
    if (( ! srp && ! spipe )) && [[ -z "$ssa" ]]; then
        return 0
    fi
    if [[ "$sf" != *V* ]]; then
        vrw="$vmq"
        sf+=V
        if [[ -n "$ssa" ]]; then
            vsa=1
        fi
    fi
}

# _p_stage_reset: reset the per-stage quoted-word facts.
_p_stage_reset() {
    srp=0 ssa="" sgv=0 ssw=0 ssdd=0 ssn=0 ssl=1 sse=0 ssp="" ssix=-1 ssiv=0 ssvs=0 ssfv=0 awfv=0 awfw=0 ssunk=0
    sso=()
    wmq="" wmqn=0 vmq="" vsa=0 shd=0
    snx=0 spn=0 spf=0 ngr=0 gown=0 ghown=0 rdx="" spfw="" rrasg=0
    jqown=0 jqq="" jqf=0 jqa=0 jqn=0 jqdd=0 jqunk=0 jqfs=0 jqbad=0
    gtq="" gtdd=0 gtunk=0 gts="" gdf=0 gdn=0 gdp=0 cmv=0
    sin=0 sio=1 sfx=0 sfo=0
}
_p_stage_reset

# _stage_end: run the stage-end checks, record the fetch facts of a pipeline's first two stages, reset the stage.
_stage_end() {
    local msg sinok
    if [[ -n "$kvp" ]]; then
        if (( si > 0 )) || [[ "$sf" == *F* ]]; then
            _deny_reader "$ipw $kvp fed by a pipe or redirection"
        fi
        kvp=""
    fi
    if (( nw == 0 && nr == 0 )); then
        return 0
    fi
    _gt_settle
    _sed_settle
    _mk_settle
    if [[ -n "$act" ]]; then
        if [[ "$act" == *r* ]]; then
            _rr_settle
        fi
        if [[ "$act" == *E* ]]; then
            hook_deny "$ENV_NONE_MSG"
        fi
        if [[ "$act" == *D* ]]; then
            _dump_check
        fi
        # A shell or ssh read from one plain file on stdin runs that file, as it would given the file as a script.
        sinok=0
        if (( si == 0 && sin == 1 && sio && ! sfx && ! sfo )) && [[ "$sf" != *I* ]]; then
            sinok=1
        fi
        if [[ "$act" == *H* ]] && (( shq && ! sinok )) \
                && { (( si > 0 || sin > 0 || sfx )) || [[ "$sf" == *F* ]]; }; then
            if [[ "$act" == *M* ]]; then
                _deny_fed "$shn fed by a pipe or redirection" "$SSH_REMEDY"
            fi
            _deny_fed "$shn fed by a pipe or redirection"
        fi
        if [[ "$act" == *M* ]] && (( ! smc && ! sinok )) \
                && { (( si > 0 || sin > 0 || sfx )) || [[ "$sf" == *F* ]]; }; then
            _deny_fed "$smn fed by a pipe or redirection" "$SSH_REMEDY"
        fi
        if [[ "$act" == *N* && "$wpn" == parallel ]] && (( wpc != 1 )) && { (( si > 0 )) || [[ "$sf" == *F* ]]; }; then
            _deny_fed "parallel with no command, fed by a pipe or redirection"
        fi
        if [[ "$act" == *[KL]* && "$sf" == *I* ]]; then
            _deny_reader "$ipw <$ins"
        fi
        if [[ "$act" == *K* && -n "$kvf" ]]; then
            _deny_reader "$ipw $kvf with no script file"
        fi
        if [[ "$act" == *k* ]] && (( (kg && ks && ko) || (kx && ! kxt) )); then
            fetch_hit=1
        fi
        if [[ "$act" == *d* ]] && (( dcf )); then
            fetch_hit=1
        fi
        if [[ "$act" == *y* ]] && (( rmf && ! rmv )); then
            _deny_mount "doppler run --mount-format or --mount-template"
        fi
        if [[ "$act" == *l* ]]; then
            if (( lgl && cdsq )) && [[ "$sf" != *L* ]]; then
                _lg_env
            fi
            if (( lgl )) && [[ "$sf" == *L* ]]; then
                msg="SECRET-PATH BLOCK: this registry login stores its credentials in '$lga', which is not known to be"
                msg+=" in the vault, where they can be read into context. Point it into the vault ('--authfile"
                msg+=" \$CLAUDE_SECRET_DIR/<name>'), or leave the location at its default."
                hook_deny "$msg"
            fi
            if (( dcm == 2 )) && ! { (( dcn && ! dcx )) || (( dci && dce && ! dcb )); }; then
                msg="SECRET-ENV BLOCK: 'compose config' prints the project's configuration with the values of its"
                msg+=" .env interpolated. Use a names-only flag (--services, --images, --volumes, -q) or both"
                msg+=" --no-interpolate and --no-env-resolution."
                hook_deny "$msg"
            fi
            if (( dsk == 2 )); then
                msg="SECRET-ENV BLOCK: 'docker stack config' prints the stack's configuration with each env_file's"
                msg+=" contents and the environment's values resolved into it, --skip-interpolation included. Read the"
                msg+=" compose file itself instead."
                hook_deny "$msg"
            fi
        fi
        # A cd or pushd with no operand may go to $HOME (zsh's pushd under PUSHD_TO_HOME).
        if [[ "$act" == *c* && "$cdk" != popd ]] && (( cdn == 0 )) && { (( cdsq )) || _cd_names HOME; }; then
            _hold_cd "" "the command may set HOME"
        fi
    fi
    _jq_settle
    _mk_vsettle
    if [[ -n "$sf" ]]; then
        if [[ "$sf" == *R* && "$sf" == *S* ]] && ! _p_clear; then
            _deny_reader "$rdn ${rdx:-$rds}"
        fi
        if [[ "$sf" == *T* && "$sf" == *I* ]]; then
            _deny_reader "$tdn <$ins"
        fi
        if [[ "$sf" == *Y* && -n "$pipe_sec" ]]; then
            _deny_reader "$rdn $pipe_sec (through xargs)"
        fi
        # A copier after xargs or parallel copies the names its input carries, or a secret word of its own stage
        # (parallel's ::: inputs).
        if [[ "$sf" == *Q* ]]; then
            if [[ -n "$pipe_sec" ]]; then
                _deny_copier "$pipe_sec (through xargs)"
            elif [[ "$sf" == *S* ]]; then
                _deny_copier "$rds"
            fi
        fi
        if (( nw == 0 )) && [[ "$sf" == *I* ]]; then
            _deny_reader "<$ins"
        fi
        if [[ "$sf" == *V* ]] && [[ "$sf" == *P* || "$sf" == *R* ]]; then
            if (( vsa )); then
                msg="SECRET-ECHO BLOCK: '$vrw' is quoted, but a sed or awk program can run a shell (awk's system(),"
                msg+=" sed's e command), which would expand it into context. Write the program to a file and run"
                msg+=" 'sed -f <file>' or 'awk -f <file>'."
            else
                msg="SECRET-ECHO BLOCK: printing a secret-shaped variable ('$vrw') into context is not allowed. Write"
                msg+=" it to \$CLAUDE_TEMP_DIR from a script instead."
            fi
            hook_deny "$msg"
        fi
        if [[ "$sf" == *s* ]] && (( nw == setw )); then
            _deny_env "set"
        fi
        if [[ "$sf" == *S* && -z "$pipe_sec" ]]; then
            pipe_sec="$rds"
        fi
    fi
    # A reader after xargs reads what an earlier stage lists; a find -exec reader reads what this find lists; a reader
    # given a directory glob reads what it matches. A stage whose one reader names files only (srl) prints none of them.
    rquiet=0
    if (( nrd == 1 && srl )); then
        rquiet=1
    fi
    if [[ "$sf" == *Y* && -n "$pipe_find" ]] && (( ! rquiet )); then
        _find_roots "$pipe_find" "$rdn" xargs "$sxk"
    fi
    if [[ -n "$wpend" ]]; then
        if (( wgo )); then
            wpend+="!0"$'\x1f'glob$'\x1f\x1e'
        fi
        if [[ "$sf" == *R* ]]; then
            _find_roots "$wpend" "$rdn" own
        fi
        pipe_find+="$wpend"
    fi
    # A stage that does not read (echo */*) leaves the directories its wildcard words expand in to a reader after
    # xargs, which may read them recursively; a reading stage's words were expanded and tested in place.
    if [[ -n "$wpip" && "$sf" != *R* ]]; then
        pipe_find+="$wpip"
    fi
    if [[ -n "$wout" && "$sf" != *R* ]]; then
        pxn=$(( pxn + wxn ))
        if (( pxn <= 64 )); then
            pipe_xd+="$wout"
        elif [[ "$pipe_xd" != '!'* ]]; then
            pipe_xd="!0"$'\x1f'echo$'\x1f\x1e'"$pipe_xd"
        fi
    fi
    if (( ffs )); then
        _find_collect
        if (( fxr && ! rquiet )); then
            _find_roots "$FIND_ENTRIES" "" exec
        else
            pipe_find+="$FIND_ENTRIES"
        fi
    fi
    _np_end
    if (( wdd )); then
        pdd=1
    fi
    if (( si == 0 )); then
        s1_fd1=$fd1
        s1_vault=$fd1v
    elif (( si == 1 && lgok && lgpw )); then
        s2_login=1
    fi
    si=$(( si + 1 ))
    sf=""
    act=""
    nw=0
    nr=0
    cs=0
    pwrap=0
    ffs=0
    fxr=0
    wpend=""
    wgn=0
    wgo=0
    ecd=0
    srl=0
    nrd=0
    wpip=""
    wpq=0
    wout=""
    wxn=0
    rgr=0
    rgk=0
    rgt=""
    snp=0
    npk=""
    snm=0
    xo=0
    xov=""
    xrep=""
    xbr=0
    xaf=0
    xqr=0
    sxk=""
    wdd=0
    GW_ACTIVE=0
    sgp=0
    gev=0
    _p_stage_reset
}

# Brace expansion. The shell expands an unquoted brace before the command runs, so a word is also screened as each word
# it expands to. The expander follows bash's brace scanner (3.2 to 5.3 agree) and refuses what bash, zsh and the
# versions of bash differ on: BX_CAP words per word, BX_TOTAL per command, BX_DEPTH_MAX levels of nesting, BX_WORK_MAX
# characters of work, unpaired braces, and any sequence but plain integers and single letters of one case. A word that
# is longer than 256 characters has its quoting marker only when it holds a {.
BX_US=$'\x1f'
BX_CAP=64
BX_TOTAL=256
BX_DEPTH_MAX=8
BX_WORK_MAX=16000
BX_BAD_RE="[[:space:]'\"\`\\\\]|[\$][(]"
BX_CMDSUB_RE="[\`\\\\]|[\$][(]"
BX_PBRACE_RE='[$][{][^}]*[{]'
BX_WORK=0
BX_DEPTH=0
BX_DQ=""

# _bx_gob <text> <from> <stop>: scan <text> from <from> as bash's brace scanner does, with ${...} one nesting level
# unless BX_DQ says every $ is quoted; set BX_I to the first <stop> at depth 0 (a {, a ,, or a } once a , or an x..y was
# seen) or to the length. Returns 0 when one was found.
_bx_gob() {
    local t="$1" k="$2" stop="$3" n=${#1} lvl=0 commas=1 c
    if [[ "$stop" == '}' ]]; then
        commas=0
    fi
    while (( k < n )); do
        c="${t:k:1}"
        if [[ "$c" == '$' && "${t:k+1:1}" == '{' && -z "$BX_DQ" ]]; then
            lvl=$(( lvl + 1 ))
            k=$(( k + 2 ))
            continue
        fi
        if [[ "$c" == "$stop" ]] && (( lvl == 0 && commas > 0 )); then
            # An open brace that starts the text and is followed by a close brace stands for itself.
            if [[ "$c" == '{' ]] && (( k == 0 )) && [[ "${t:k+1:1}" == '}' ]]; then
                k=$(( k + 1 ))
                continue
            fi
            BX_I=$k
            return 0
        fi
        if [[ "$c" == '{' ]]; then
            lvl=$(( lvl + 1 ))
        elif [[ "$c" == '}' ]]; then
            if (( lvl > 0 )); then
                lvl=$(( lvl - 1 ))
            fi
        elif (( lvl == 0 )) && [[ "$stop" == '}' ]]; then
            if [[ "$c" == ',' ]]; then
                commas=$(( commas + 1 ))
            elif [[ "$c" == . && "${t:k+1:1}" == . && "${t:k+2:1}" != '}' ]]; then
                commas=$(( commas + 1 ))
            fi
        fi
        k=$(( k + 1 ))
    done
    BX_I=$n
    return 1
}

# _bx_seq <x..y>: set BX_R and BX_N to the items (each followed by BX_US) of a sequence bash 3.2, bash 5 and zsh expand
# alike: plain decimal integers of at most nine digits, or two letters of one case, at most BX_CAP items. Returns 1
# for any other text: a step, a plus sign, a leading zero, a mixed pair.
_bx_seq() {
    local x="${1%%..*}" y="${1#*..}" a b c step out="" alpha="" pa pb
    local num_re='^(0|-?[1-9][0-9]{0,8})$'
    BX_R=""
    BX_N=0
    if [[ "$1" != *..* || "$y" == *..* ]]; then
        return 1
    fi
    if [[ "$x" =~ $num_re && "$y" =~ $num_re ]]; then
        a=$x
        b=$y
    else
        alpha=abcdefghijklmnopqrstuvwxyz
        if [[ "$x" == [A-Z] && "$y" == [A-Z] ]]; then
            alpha=ABCDEFGHIJKLMNOPQRSTUVWXYZ
        elif [[ "$x" != [a-z] || "$y" != [a-z] ]]; then
            return 1
        fi
        pa="${alpha%%$x*}"
        pb="${alpha%%$y*}"
        a=${#pa}
        b=${#pb}
    fi
    if (( b >= a )); then
        step=1
        BX_N=$(( b - a + 1 ))
    else
        step=-1
        BX_N=$(( a - b + 1 ))
    fi
    if (( BX_N > BX_CAP )); then
        return 1
    fi
    c=$a
    while :; do
        if [[ -n "$alpha" ]]; then
            out+="${alpha:c:1}$BX_US"
        else
            out+="$c$BX_US"
        fi
        if (( c == b )); then
            break
        fi
        c=$(( c + step ))
    done
    BX_R="$out"
    return 0
}

# _bx_expand <text>: set BX_R to the brace expansions of <text> as bash makes them, each followed by BX_US, and BX_N to
# their number. Returns 1 when they cannot be followed: over BX_CAP words, nesting or work past the bounds, or a brace
# holding x..y that _bx_seq does not accept.
_bx_expand() {
    local t="$1" i=0 j pre amble post piece m p k e last mid="" mn=0 pr pn res="" rest r2
    BX_WORK=$(( BX_WORK + ${#t} + 1 ))
    if (( BX_WORK > BX_WORK_MAX )); then
        return 1
    fi
    while :; do
        if ! _bx_gob "$t" "$i" '{'; then
            BX_R="$t$BX_US"
            BX_N=1
            return 0
        fi
        i=$BX_I
        if _bx_gob "$t" "$(( i + 1 ))" '}'; then
            break
        fi
        i=$(( i + 1 ))
    done
    j=$BX_I
    pre="${t:0:i}"
    amble="${t:i+1:j-i-1}"
    post="${t:j+1}"
    if _bx_gob "$amble" 0 ','; then
        k=0
        last=""
        while [[ -z "$last" ]]; do
            if _bx_gob "$amble" "$k" ','; then
                e=$BX_I
            else
                e=${#amble}
                last=1
            fi
            piece="${amble:k:e-k}"
            BX_DEPTH=$(( BX_DEPTH + 1 ))
            if (( BX_DEPTH > BX_DEPTH_MAX )) || ! _bx_expand "$piece"; then
                return 1
            fi
            BX_DEPTH=$(( BX_DEPTH - 1 ))
            mid+="$BX_R"
            mn=$(( mn + BX_N ))
            if (( mn > BX_CAP )); then
                return 1
            fi
            k=$(( e + 1 ))
        done
    else
        # A comma only inside a nested brace: bash versions differ on it.
        if [[ "$amble" == *,* ]] || ! _bx_seq "$amble"; then
            return 1
        fi
        mid="$BX_R"
        mn=$BX_N
    fi
    if [[ -n "$post" ]]; then
        if ! _bx_expand "$post"; then
            return 1
        fi
        pr="$BX_R"
        pn=$BX_N
    else
        pr="$BX_US"
        pn=1
    fi
    if (( mn * pn > BX_CAP )); then
        return 1
    fi
    rest="$mid"
    while [[ -n "$rest" ]]; do
        m="${rest%%$BX_US*}"
        rest="${rest#*$BX_US}"
        r2="$pr"
        while [[ -n "$r2" ]]; do
            p="${r2%%$BX_US*}"
            r2="${r2#*$BX_US}"
            res+="$pre$m$p$BX_US"
        done
    done
    BX_R="$res"
    BX_N=$(( mn * pn ))
    return 0
}

# _bx_balanced <word>: 0 when the braces of <word> pair off and none holds an open integer sequence, which zsh reads
# without its braces ({1..} is 1..).
_bx_balanced() {
    local open_re='[{]-?[0-9]+[.][.][}]|[{][.][.]-?[0-9]+[}]' n=${#1} k=0 depth=0 c
    if [[ "$1" =~ $open_re ]]; then
        return 1
    fi
    while (( k < n )); do
        c="${1:k:1}"
        if [[ "$c" == '{' ]]; then
            depth=$(( depth + 1 ))
        elif [[ "$c" == '}' ]]; then
            depth=$(( depth - 1 ))
            if (( depth < 0 )); then
                return 1
            fi
        fi
        k=$(( k + 1 ))
    done
    (( depth == 0 ))
}

# _bx_splice: replace each word of SW_WORDS that carries an expandable brace, and each target of an input redirection,
# by the words it expands to, so the main loop screens the real argv: every expansion as the path it would be written
# as, in the place the shell puts it. Each carries the marker b (n: the part before the first = held the brace), which
# every check that holds a word holding a brace reads as one: a role walk voided by a brace, an assembled command word,
# git option or subcommand. A word's own secret-name screens still run, on an h element after its expansions that
# takes no place in a walk. A word the expander cannot follow stays as it was, with an ask held, as does a command
# past BX_TOTAL expansions. A variable an expansion keeps is screened as the written-out word is, with an ask held
# only when the marker says a quoted $ and a live one are mixed (q) or quoted text lies among the braces (x). Without
# x, a space or quote in the word is quoted text outside the braces and the dequoted word expands as the shell does;
# a backslash or a command substitution still holds an ask. A word whose marker says its glob characters are all
# quoted is left. A redirect target has no marker, so its braces count as live.
_bx_splice() {
    local el pend="" cm="" wd acc="" item its vacc rest why held=0 total=0 found=0 restore_glob=1 msg kind op mf r1
    for el in ${SW_WORDS[@]+"${SW_WORDS[@]}"}; do
        if [[ "$el" == [wpr]*\{* && "$el" == *\}* && ( "$el" == *,* || "$el" == *..* ) ]]; then
            found=1
            break
        fi
    done
    if (( ! found )); then
        return 0
    fi
    BX_WORK=0
    for el in ${SW_WORDS[@]+"${SW_WORDS[@]}"}; do
        kind=""
        case "$el" in
            m*)
                cm="${el:1}"
                pend="$el$BX_US"
                continue ;;
            [wp]*)
                kind=w
                wd="${el:1}" ;;
            r*)
                rest="${el:1}"
                op="${rest%% *}"
                if [[ "$op" == *'<' || "$op" == *'<>' ]] && [[ "$op" != *'<<'* ]]; then
                    kind=r
                    wd="${rest#* }"
                    cm=""
                fi ;;
        esac
        if [[ -z "$kind" || "$cm" == *g* || "$wd" != *\{* || "$wd" != *\}* ]] \
                || [[ "$wd" != *,* && "$wd" != *..* ]]; then
            acc+="$pend$el$BX_US"
            pend=""
            cm=""
            continue
        fi
        why=""
        its=""
        BX_WORK=$(( BX_WORK + ${#wd} ))
        if (( held )); then
            :
        elif (( BX_WORK > BX_WORK_MAX )); then
            why="the command's brace words are too long to expand"
        elif [[ "$wd" =~ $BX_CMDSUB_RE ]] || { [[ "$kind" != w || "$cm" == *x* ]] && [[ "$wd" =~ $BX_BAD_RE ]]; }; then
            why="it holds a quote, a space, a backquote or a backslash"
        elif ! _bx_balanced "$wd"; then
            why="its braces do not pair off, or open or close a sequence"
        else
            BX_DEPTH=0
            BX_DQ=""
            # With a quoted $ (d) or a quoted and a live one (q) the hook cannot tell which ${ opens a parameter
            # expansion, so each $ is text and a brace beside it is expanded; the expansion keeps its $ and asks.
            if [[ "$cm" == *[dq]* ]]; then
                BX_DQ=1
            fi
            if ! _bx_expand "$wd"; then
                why="it expands to more than $BX_CAP words, nests too deeply or holds a sequence the hook cannot expand"
            else
                r1="$BX_R"
                if [[ "$r1" != "$wd$BX_US" ]]; then
                    its="$r1"
                fi
            fi
            BX_DQ=""
            # An unquoted ${ is a parameter expansion, but one holding a brace of its own may be read as text.
            if [[ -z "$why" && "$cm" != *[dq]* && "$wd" =~ $BX_PBRACE_RE ]]; then
                why="a \${ holds a brace of its own, which may be read as text"
            fi
        fi
        vacc=""
        mf="b"
        if [[ "${wd%%=*}" == *\{* ]]; then
            mf+=n
        fi
        if [[ "$cm" == *d* ]]; then
            mf+=d
        fi
        rest="$its"
        while [[ -n "$rest" ]]; do
            item="${rest%%$BX_US*}"
            rest="${rest#*$BX_US}"
            if [[ -z "$item" ]]; then
                continue
            fi
            total=$(( total + 1 ))
            if (( total > BX_TOTAL )); then
                why="the command expands more than $BX_TOTAL words in all"
                held=1
                its=""
                vacc=""
                break
            fi
            if [[ "$kind" == w && "$item" == *'$'* && "$cm" == *[qx]* ]]; then
                why="an expansion keeps a variable"
            fi
            if [[ "$kind" == w ]]; then
                vacc+="m$mf$BX_US""w$item$BX_US"
            else
                vacc+="r$op $item$BX_US"
            fi
        done
        if [[ -n "$its" ]]; then
            acc+="$vacc"
            if [[ "$kind" == w ]]; then
                acc+="${pend}h$wd$BX_US"
            fi
        else
            acc+="$pend$el$BX_US"
        fi
        pend=""
        cm=""
        if [[ -n "$why" ]]; then
            msg="SECRET-SCAN ASK: '$wd' is a brace expansion the hook cannot follow ($why), so it cannot tell which"
            msg+=" files it names. Approve it only if that reads no secret file."
            hook_hold_ask "$msg"
        fi
    done
    if [[ "$-" == *f* ]]; then
        restore_glob=0
    fi
    set -f
    local IFS=$'\x1f'
    # shellcheck disable=SC2206  # split on \x1f with pathname expansion off
    SW_WORDS=($acc)
    if (( restore_glob )); then
        set +f
    fi
}
if [[ "$fetch_checked" == *\{* && "$fetch_checked" == *\}* ]] \
        && [[ "$fetch_checked" == *,* || "$fetch_checked" == *..* ]]; then
    _bx_splice
fi

sclean=0
ho=0
for el in ${SW_WORDS[@]+"${SW_WORDS[@]}"}; do
    case "$el" in
        m*)
            mk="${el:1}"
            continue ;;
        w*) ;;
        h*)
            # A word a brace expanded: only its secret-name screens run (below), as its expansions, which follow it,
            # take its place in every walk.
            ho=1 ;;
        p*)
            # A plain word changes nothing but the word count and command position, unless a word walk needs it (an awk
            # or sed stage walks them all: its program may be plain), or the fetch shapes do: they read every word of
            # a fetch's second stage (the login), or it may name a directory outside the cwd (/, ~, a .. segment) for
            # a recursive reader after xargs, or hold an escape or a brace for the name-producer check.
            if [[ -z "$act" && -z "$ssa" && "$el" != p[/~]* && "$el" != p..* && "$el" != *'/..'* \
                    && "$el" != *[\\\{]* ]] \
                    && (( si != 1 || ! ( fetch_hit || swf_stage >= 0 ) )); then
                nw=$(( nw + 1 ))
                cs=1
                pwrap=0
                continue
            fi ;;
        '|')
            # sclean: the last stage end was the fast one below and only plain words have come since, which change
            # nw, cs and pwrap alone. Every other value that fast end resets (and every condition it tests) is then
            # unchanged, so only the stage counter and those three are left to do. The fetch clause repeats the fast
            # end's own and is true whenever sclean is; it stays as a guard, so a change to that end cannot leave this
            # one skipping a fetch record.
            if (( sclean )) && (( si > 1 || ! ( fetch_hit || swf_stage >= 0 ) )); then
                pnu=1
                si=$(( si + 1 ))
                nw=0
                cs=0
                pwrap=0
                continue
            fi
            # With no walk running, no directory glob queued and none of the facts a stage-end check reads (S, I, V, s,
            # Y, Q), a stage ends with nothing to check, or to record for a fetch; only an echo there names paths the
            # hook models (_np_end).
            if [[ -z "$act" && -z "$wpend" && -z "$wpip" && -z "$wout" && -z "$wmq$vmq$ssp" \
                    && "$sf" != *[SIVsYQ]* ]] && (( ${#sso[@]} == 0 )) \
                    && (( si > 1 || ! ( fetch_hit || swf_stage >= 0 ) )); then
                if (( ! snp || rgr )); then
                    pnu=1
                fi
                if (( wdd )); then
                    pdd=1
                fi
                snp=0
                npk=""
                wdd=0
                si=$(( si + 1 ))
                sf=""
                nw=0
                nr=0
                cs=0
                pwrap=0
                ecd=0
                srl=0
                nrd=0
                rgr=0
                rgk=0
                rgt=""
                sgp=0
                gev=0
                _p_stage_reset
                sclean=1
                continue
            fi
            sclean=0
            scan_words=$(( scan_words + 1 ))
            if (( scan_words > SECRET_SCAN_WORD_BUDGET )); then
                hook_deny "$WORDS_MSG"
            fi
            spipe=1
            _stage_end
            continue ;;
        ';')
            sclean=0
            scan_words=$(( scan_words + 1 ))
            if (( scan_words > SECRET_SCAN_WORD_BUDGET )); then
                hook_deny "$WORDS_MSG"
            fi
            spipe=0
            _stage_end
            if (( si > 0 )); then nsep=$(( nsep + 1 )); fi
            cdsq=1
            si=0
            pipe_sec=""
            pipe_find=""
            pipe_xd=""
            pxn=0
            pnu=0
            pdd=0
            continue ;;
        r*)
            sclean=0
            nr=$(( nr + 1 ))
            scan_words=$(( scan_words + 1 ))
            if (( scan_words > SECRET_SCAN_WORD_BUDGET )); then
                hook_deny "$WORDS_MSG"
            fi
            op="${el%% *}"
            op="${op#r}"
            tgt="${el#* }"
            # shellcheck disable=SC2053  # _NAME_FOLD_ANY is an intentional pattern
            if (( ${#tgt} <= 4096 )) && [[ "$tgt" == $_NAME_FOLD_ANY ]]; then
                name_fold "$tgt"
                tgt="$NAME_FOLD"
            fi
            # The stage's stdin, for rg: a here-document or here-string (rgk 2), a file (1, rgt) or a duplicated fd
            # (0). Only an unprefixed < or a prefix of 0 counts: another prefix leaves rg's stdin, and its probe, alone.
            if [[ "$op" == *'<'* ]]; then
                fdi="${op%%[!0-9]*}"
                if [[ -z "$fdi" || "$fdi" == 0 ]]; then
                    rgr=1
                    case "$op" in
                        *'<<<'|*'<<'|*'<<-') rgk=2 ;;
                        *'<&') rgk=0 ;;
                        *) rgk=1; rgt="$tgt" ;;
                    esac
                fi
            fi
            # What feeds the stage's stdin: each unprefixed <, a prefix of zeros, or one of two or more digits (zsh
            # reads that as an argument plus the operator). The feed is one plain file when it is a single bare <
            # whose target is no input-naming path (_names_input: /dev/tcp, /dev/stdin, /proc/self/fd/0) and holds no
            # expansion.
            if [[ "$op" == *'<'* ]]; then
                sfd="${op%%[!0-9]*}"
                if [[ -z "$sfd" || "$sfd" != *[!0]* || ${#sfd} -gt 1 ]]; then
                    sin=$(( sin + 1 ))
                    if [[ "${op:${#sfd}}" != '<' || -z "$tgt" || ${#tgt} -gt 4096 ]]; then
                        sio=0
                    elif [[ "$tgt" == =* || "$tgt" == *[\$\`\\\*\?\[\{\(\)\<\>\|\&\;\"\']* ]] \
                            || _names_input "$tgt"; then
                        sio=0
                    elif [[ ${#sfd} -gt 1 && "$sfd" == *[!0]* ]]; then
                        sio=0
                    fi
                else
                    # Another fd's input (3</dev/tcp/h/80) may be duplicated onto fd 0 by a later redirection.
                    sfo=1
                fi
            elif [[ "$op" == *'>'* ]]; then
                # An output operator on fd 0 (0>/dev/tcp/h/80, 0>&3) or on a prefix zsh may read as fd 0 reaches the
                # shell's stdin in a way the count above does not see. Any other dup (&>, N>&M) leaves the one-file
                # allowance off, except a dup between fds 1 and 2 (2>&1), which touches no other fd.
                sfd="${op%%[!0-9]*}"
                if [[ -n "$sfd" ]] && [[ "$sfd" != *[!0]* || ${#sfd} -gt 1 ]]; then
                    sfx=1
                elif [[ "$op" == *'&'* ]]; then
                    if [[ "${op:${#sfd}}" != '>&' || "$sfd" == [3-9] || "$tgt" != [12] ]]; then
                        sfo=1
                    fi
                fi
            fi
            case "$op" in
                *'<<<')
                    if [[ "$sf" != *F* ]]; then sf+=F; fi
                    if [[ "$tgt" == *'$'* && "$tgt" =~ $secret_var_re ]]; then
                        msg="SECRET-ECHO BLOCK: a here-string of a secret-shaped variable ('$tgt') prints it into"
                        msg+=" context. Write it to \$CLAUDE_TEMP_DIR from a script instead."
                        hook_deny "$msg"
                    fi ;;
                *'<<'|*'<<-')
                    shd=1
                    if [[ "$sf" != *F* ]]; then sf+=F; fi ;;
                *'<&') ;;
                *'<'|*'<>')
                    if [[ "$sf" != *F* ]]; then sf+=F; fi
                    # shellcheck disable=SC2053  # the alternations are intentional patterns
                    if [[ "/$tgt" == $_SECRET_PATH_ANY && "/$tgt" != $_SECRET_ALLOW_ANY ]] \
                            || { (( ${#tgt} <= 4096 )) && [[ "$tgt" == *[=:\*\?\[]* || "$tgt" == -[!-]?* ]] \
                                && _secret_variant "$tgt"; }; then
                        if [[ "$sf" != *S* ]]; then rds="<$tgt"; sf+=S; fi
                        _snx "<$tgt"
                        if [[ "$sf" != *I* ]]; then ins="$tgt"; sf+=I; fi
                    fi ;;
            esac
            if [[ "$op" == *'>'* ]] && (( si == 0 )); then
                # Stdout is fd 1, however it is written: the operator after an fd prefix of at most 9 digits with its
                # leading zeros dropped (01>&2 is 1>&2), or &> and &>>; 1<> opens stdout read-write. zsh reads a prefix
                # of two or more digits (10>&1) as an argument plus the operator, which redirects stdout, so that
                # counts too.
                fdn="${op%%[!0-9]*}"
                fdl=${#fdn}
                opn="${op:${#fdn}}"
                if [[ -n "$fdn" ]]; then
                    fdn="${fdn#"${fdn%%[!0]*}"}"
                    fdn="${fdn:-0}"
                fi
                is1=0
                case "$opn" in
                    '>'|'>>'|'>|'|'>&')
                        if [[ -z "$fdn" || "$fdn" == 1 ]] || (( fdl > 1 )); then is1=1; fi ;;
                    '&>'|'&>>')
                        is1=1 ;;
                    '<>')
                        if [[ "$fdn" == 1 ]]; then is1=1; fi ;;
                esac
                if (( is1 )); then
                    fd1=$(( fd1 + 1 ))
                    fd1v=0
                    if [[ "$opn" == '>&' ]] && [[ "$tgt" == - || "$tgt" != *[!0-9]* ]]; then
                        :
                    elif _in_vault "$tgt"; then
                        fd1v=1
                    fi
                fi
            fi
            continue ;;
    esac
    sclean=0
    w="${el:1}"
    wmk="$mk"
    mk=""
    cw1=0 wrole="" wsx=0
    # A file system that folds case fully opens a name in a non-ASCII letter that folds to ASCII as its ASCII
    # spelling, so the word is screened as that spelling.
    # shellcheck disable=SC2053  # _NAME_FOLD_ANY is an intentional pattern
    if (( ${#w} <= 4096 )) && [[ "$w" == $_NAME_FOLD_ANY ]]; then
        name_fold "$w"
        w="$NAME_FOLD"
    fi
    nw=$(( nw + 1 ))
    scan_words=$(( scan_words + 1 ))
    if (( scan_words > SECRET_SCAN_WORD_BUDGET )); then
        hook_deny "$WORDS_MSG"
    fi
    if [[ "$w" == */* ]]; then
        wlast="${w%/*}"
        wlast="${w:${#wlast}+1}"
    else
        wlast="$w"
    fi
    # One case keeps the common word to a single test: a word holding = or : may set a command variable or name an
    # ext:: address (_cmd_var_word), and must be tested first (GIT_PAGER=/usr/bin/env is no env word); an env word
    # marks the stage (gev; _cmd_var_word marks one whose path holds = or :).
    case "$w" in
        *[=:]*) _cmd_var_word "$w" ;;
        [Ee][Nn][Vv]|*/[Ee][Nn][Vv]) gev=1 ;;
    esac
    wsec=0
    GPW=""
    if (( sgp )) && [[ "$w" == :* ]] && (( ${#w} <= 4096 )); then
        _git_ps_word "$w"
    fi
    # A word over 4096 characters (PATH_MAX on Linux) cannot be a path, so it gets only the whole-word test: the
    # variants' prefix removals are quadratic in the word's length.
    # shellcheck disable=SC2053  # the alternations are intentional patterns
    if [[ -n "$GPW" ]]; then
        wsec=$GPW
        wsx=1
    elif [[ "/$w" == $_SECRET_PATH_ANY && "/$w" != $_SECRET_ALLOW_ANY && "$w" != --exclude=* \
            && "$w" != --exclude-dir=* ]]; then
        wsec=1
    elif (( ${#w} <= 4096 )) && [[ "$w" == *[=:\*\?\[]* || "$w" == -[!-]?* ]] \
            && [[ "$w" == *[=:]* || "$w" == -[!-]?* || "$wlast" == *[!\*\?]* ]] && _secret_variant "$w"; then
        wsec=1
    fi
    # An awk program that can run a shell (system, getline, a | pipe, gawk's @) expands the stage's marked globs after
    # all. A sed stage is walked to its end, for its programs (_sed_settle) as well as for -f.
    case "$ho$ssa" in
        0s) _sed_word "$w" ;;
        0a)
            # Only an option word holding a letter the walk acts on, or the value one asked for, changes anything.
            if [[ "$w" == -*[efilEW]* || "$awfv$awfw" != 00 ]]; then
                _awk_file_word "$w"
            fi
            if (( ! sgv )); then
                _awk_word "$w"
            fi ;;
    esac
    if (( ! wsec )); then
        if [[ "$wmk" == *g* ]] && (( ! srp && ! sgv && wmqn < 64 )); then
            wmq+="$w"$'\x1e'
            wmqn=$(( wmqn + 1 ))
        elif _wild_check "$w"; then
            wsec=1
            wsx=1
        fi
    fi
    # A word that may name a directory outside the cwd: absolute, ~, a .. segment, a variable, or a pattern that may
    # match .. (wdd marks the last three, for a replacement string after xargs).
    if (( ${#w} <= 4096 )) && [[ "$w" == /* || "$w" == '~'* || "$w" == ..* || "$w" == */..* || "$w" == *'$'* \
            || "/$w" =~ $DOT_PAT_RE ]]; then
        _xd_word "$w"
        if [[ "$w" != /* && "$w" != '~'* ]] || [[ "$w" == */..* || "$w" == *'$'* || "/$w" =~ $DOT_PAT_RE ]]; then
            wdd=1
        fi
    fi
    if (( snp )) && [[ "$w" == *[\\\{]* || "$wmk" == *b* ]]; then
        snp=0
    fi
    if (( wsec )) && [[ "$sf" != *S* ]]; then
        rds="$w"
        sf+=S
    fi
    if (( ho )); then
        ho=0
        nw=$(( nw - 1 ))
        if (( wsec )); then
            _snx "$w"
        fi
        continue
    fi
    nm="$wlast"
    # A case-insensitive file system runs CAT as cat, so a name is classified lower-cased. No class name is longer
    # than 16 characters.
    if (( ${#nm} <= 16 )) && [[ "$nm" == *[ABCDEFGHIJKLMNOPQRSTUVWXYZ]* ]]; then
        ascii_lower "$nm"
        nm="$ASCII_LOWER"
    fi
    atcmd=0

    # Word walks started by an earlier word of this stage.
    if [[ -n "$act" ]]; then
        # find's ; (or a + right after {}) ends the executed command: an env walk still running had none, a pending dump
        # has its operands, a reader's probe walk ends, and the words after it are no longer at command position (unless
        # an earlier wrapper put them there). Any other + is an argument of the command, except that env still running
        # takes it for a command it cannot account for and is denied as having none.
        if [[ "$act" == *g* ]]; then
            fxe=0
            if [[ "$w" == ';' ]] || { [[ "$w" == '+' ]] && [[ "$fxp" == '{}' ]]; }; then
                fxe=1
            elif [[ "$w" == '+' && "$act" == *E* ]]; then
                hook_deny "$ENV_NONE_MSG"
            fi
            fxp="$w"
            if (( fxe )); then
                sgp=0
                if [[ "$act" == *r* ]]; then
                    _rr_settle
                fi
                act="${act//[gI]/}f"
                if [[ "$act" == *E* ]]; then
                    hook_deny "$ENV_NONE_MSG"
                fi
                if [[ "$act" == *D* ]]; then
                    _dump_check
                    act="${act//D/}"
                fi
                if (( fxa )); then sf="${sf//A/}"; fi
            fi
        fi
        if [[ "$act" == *r* ]]; then
            rrg=0
            if [[ "$wmk" == *g* ]]; then rrg=1; elif [[ "$wmk" == *b* ]]; then rrg=2; fi
            _rr_word "$w"
            if (( rrown )); then
                wrole="$RR_ROLE"
                # A word the shell may expand or split can add or reshape words, so no operand's role is known.
                if [[ "$w" == *[\*\?\[\{\$\`]* || "$wmk" == *b* ]] && _w_expands; then
                    rrunk=1
                    wrole=""
                fi
            fi
        fi
        if [[ "$act" == *c* ]]; then
            _cd_word "$w"
        fi
        # A registry login's credential location, matched anywhere in the stage whatever the tool (no per-tool option
        # table), and compose's words once compose (or *-compose) is seen, or docker stack's (a stack word may be a
        # global option's value, so compose and exec are still looked for after it). After run, create or exec (drc),
        # a stack word is the container's, until a nested docker; one after a global option taking a value (dpw is the
        # word before) may be that value, so it does not count.
        if [[ "$act" == *l* ]]; then
            if (( lgv )); then
                lgv=0
                _lg_auth "$w"
            else
                case "$w" in
                    login) lgl=1 ;;
                    --authfile|--compat-auth-file|--registry-config|--config) lgv=1 ;;
                    --authfile=*|--compat-auth-file=*|--registry-config=*|--config=*) _lg_auth "${w#*=}" ;;
                esac
                if (( dcm == 1 || dcm == 2 )); then
                    # compose exec and run are runners; one that may be an unknown option's value counts (fail
                    # closed).
                    if (( dcm == 1 && ! dcsk )) && [[ "$w" == exec || "$w" == run ]]; then
                        _run_wrap compose
                    fi
                    _dc_word "$w"
                elif (( dsk )); then
                    _ds_word "$w"
                elif (( dcm == 0 )) && [[ "$lgt" == docker || "$lgt" == podman || "$lgt" == nerdctl ]]; then
                    case "$w" in
                        compose) dcm=1 ;;
                        stack) if [[ "$lgt" == docker ]] && (( ! drc )); then dsk=1; fi ;;
                        run|create|exec)
                            case "$dpw" in
                                -c|--context|-H|--host|--config|-l|--log-level|--tlscacert|--tlscert|--tlskey) ;;
                                *) drc=1 ;;
                            esac
                            if [[ "$w" == exec ]]; then _run_wrap "$lgt"; fi ;;
                        docker|*/docker) drc=0 ;;
                    esac
                    dpw="$w"
                fi
            fi
        fi
        # The words heroku run and heroku local:run join for a shell (one holding whitespace or shell syntax is a
        # command string), doppler run's options up to --, and heroku local's start command (run by sh -c).
        if [[ "$act" == *y* ]]; then
            if (( ryh )) && [[ "$w" == *[[:space:]\;\&\|\<\>\(\)\$\`\\\"\'\{\}\*\?\[]* || "$wmk" == *b* ]]; then
                msg="SHELL-STRING BLOCK: $ryt passes '$w' to a shell, which parses it as a command"
                msg+=" string this hook cannot screen. Pass the command as separate unquoted words, with no shell"
                msg+=" syntax."
                hook_deny "$msg"
            fi
            if (( rym )); then
                rym=0
                _ry_mount "$w"
            elif (( ryd )); then
                case "$w" in
                    --) ryd=0 ;;
                    --command|--command=*) _deny_shell "doppler run $w" ;;
                    --mount) rym=1 ;;
                    --mount=*) _ry_mount "${w#*=}" ;;
                    --mount-format|--mount-format=*|--mount-template|--mount-template=*) rmf=1 ;;
                esac
            fi
            if (( ryl )); then
                case "$w" in
                    --start-cmd|--start-cmd=*) _deny_shell "heroku local $w" ;;
                esac
            fi
        fi
        # A runner's subcommand runs the words after it as a command (docker's family and compose: the l walk).
        # heroku local runs its Procfile's processes, and only its --start-cmd is a command.
        if [[ "$act" == *u* ]]; then
            case "$run_t:$w" in
                kubectl:exec|oc:exec|oc:rsh|oc:debug|doppler:run|heroku:run|heroku:run:*) _run_wrap "$run_t" ;;
                heroku:local:run) _run_wrap heroku-local ;;
                heroku:local|heroku:local:start)
                    act="${act//u/}"
                    _run_y l ;;
            esac
        fi
        if [[ "$act" == *n* ]]; then
            _np_word "$w"
        fi
        if [[ "$act" == *E* ]]; then
            if (( ! ewn )); then
                ewf="$w"
                ewn=1
            fi
            if (( ews )); then
                ews=0
            else
                case "$w" in
                    env) ;;
                    -C|--chdir) ewo=1; ews=1; ecd=1 ;;
                    -u|-P|--unset) ewo=1; ews=1 ;;
                    -i|-0|-v) ewo=1 ;;
                    --split-string|--split-string=*) hook_deny "$S_MSG" ;;
                    --chdir=*) ewo=1; ecd=1 ;;
                    -|--|--ignore-environment|--null|--debug|--unset=*) ewo=1 ;;
                    -*)
                        if [[ "$w" =~ ^-[0iv]*([uCPS])(.*)$ ]]; then
                            ewo=1
                            if [[ "${BASH_REMATCH[1]}" == C ]]; then
                                ecd=1
                            fi
                            if [[ "${BASH_REMATCH[1]}" == S ]]; then
                                hook_deny "$S_MSG"
                            elif [[ -z "${BASH_REMATCH[2]}" ]]; then
                                ews=1
                            fi
                        elif [[ "$w" =~ ^-[0iv]+$ ]]; then
                            ewo=1
                        else
                            ewu=1
                        fi ;;
                    [A-Za-z_]*=*) ;;
                    *)
                        # The unwrapped command. Unless env's first word was an assignment, a bare env, an
                        # unrecognised option or a runner after env runs a command this walk cannot account for.
                        act="${act//E/}"
                        atcmd=1
                        if [[ "$ewf" != *=* ]]; then
                            case "$nm" in
                                command|builtin|exec|nice|nohup|time|timeout|xargs|sudo|doas|stdbuf|ionice|sh|bash|\
                                zsh|dash|ksh)
                                    ewu=1 ;;
                            esac
                            if (( ewu || ! ewo )); then
                                msg="SECRET-ENV BLOCK: 'env' wrapping '$nm' runs a command this hook cannot screen."
                                hook_deny "$msg"
                            fi
                        fi ;;
                esac
            fi
        fi
        if [[ "$act" == *I* ]]; then
            _git_cmd_word "$w"
        fi
        if [[ "$act" == *t* ]]; then
            _gt_word "$w"
            # A word the shell may expand or split can add or reshape words, so no operand's role is known.
            if [[ "$w" == *[\*\?\[\{\$\`]* || "$wmk" == *b* ]] && _w_expands; then
                gtunk=1
                wrole=""
            fi
        fi
        if [[ "$act" == *G* ]]; then
            # git -C DIR -C SUB runs in DIR/SUB; a --git-dir, --work-tree or -c core or submodule setting changes what
            # git grep reads. A -c value passes only as one plain word, as many keys hold a command (an ! alias, a
            # pager, an ssh command, a filter driver); --config-env takes its value from a variable the hook cannot see.
            # A word the shell may assemble before the subcommand (an option's name, or the subcommand) may hide it.
            if (( ! GW_SKIP )) && [[ "$w" == *[\\\$\`\{\*\?\[]* || "$wmk" == *b* ]]; then
                if [[ "$w" == -* ]]; then
                    _asm_hold "${w%%=*}" "a git option"
                else
                    _asm_hold "$w" "the git subcommand"
                fi
            fi
            case "$gwp" in
                -C)
                    if [[ -n "$gcd" && "$w" != /* && "$w" != '~'* ]]; then gcd="$gcd/$w"; else gcd="$w"; fi ;;
                -c)
                    if [[ "$w" == [Cc][Oo][Rr][Ee].* || "$w" == [Ss][Uu][Bb][Mm][Oo][Dd][Uu][Ll][Ee].* ]]; then
                        gcore=1
                    fi
                    _git_cmd_value "git -c ${w%%=*}" "${w#*=}"
                    _git_cfg_key "git -c" "${w%%=*}" "$w"
                    if [[ "$w" == [Aa][Ll][Ii][Aa][Ss].?*=?* ]]; then
                        v="${w#*.}"
                        gal+="${v%%=*}=${w#*=} "
                    fi ;;
                --git-dir|--work-tree) gwt=1 ;;
            esac
            case "$w" in
                --git-dir=*|--work-tree=*) gwt=1 ;;
                --config-env|--config-env=*) _deny_shell "git --config-env" ;;
                --*-pathspecs) rr_gitps=1 ;;
            esac
            if [[ "$w" == *[\$\`\\\{\*\?\[]* || "$wmk" == *b* ]] && [[ "$gwp" != -C && "$gwp" != -c ]]; then
                rr_gitps=1
            fi
            gwp="$w"
            git_walk_word "$w"
            if (( ! GW_ACTIVE )); then
                act="${act//G/}"
                sgp=1
                if [[ "$npk" == git && -z "$npg" ]]; then
                    npg="$GW_SUB"
                fi
                if git_sub_reader "$GW_SUB"; then
                    if (( gown )) && [[ "$GW_SUB" == diff && "$act" != *t* ]]; then
                        # Whether this diff reads is settled at the stage end (_gt_settle), once its options are known;
                        # role x keeps the class lookup from counting the subcommand word as a reader meanwhile.
                        gdf=1
                        gdn=0
                        gdp=0
                        wrole=x
                    else
                        # grep and diff are class R names: the subcommand word is counted as a reader (nrd) in the
                        # class lookup that follows.
                        if [[ "$GW_SUB" != grep && "$GW_SUB" != diff ]]; then
                            ngr=1
                        fi
                        if [[ "$sf" != *R* ]]; then
                            rdn="git $GW_SUB"
                            sf+=R
                        fi
                        if [[ "$sf" == *X* && "$sf" != *Y* ]]; then sf+=Y; fi
                    fi
                fi
                case "$GW_SUB" in
                    grep) _rr_start 'git grep' ;;
                    diff) _rr_start 'git diff' ;;
                esac
                # Roles for log, show and diff, only when git is the stage's first command word; a leading assignment
                # may change how git reads its options.
                case "$GW_SUB" in
                    log|show|diff)
                        if (( gown )) && [[ "$act" != *t* ]]; then
                            act+=t
                            gtq=""
                            gtdd=0
                            gtunk=$rrasg
                            gts="$GW_SUB"
                        fi ;;
                esac
                # A -c alias (gal, case-insensitive as git's config keys are) stands for the subcommand it names,
                # through a chain of at most 8 aliases; a longer one is denied.
                gis="$GW_SUB"
                if [[ -n "$gal" ]]; then
                    v=" $gal"
                    if (( ${#v} <= 4096 )) && [[ "$v" == *[ABCDEFGHIJKLMNOPQRSTUVWXYZ]* ]]; then
                        ascii_lower "$v"
                        v="$ASCII_LOWER"
                    fi
                    if (( ${#gis} <= 64 )) && [[ "$gis" == *[ABCDEFGHIJKLMNOPQRSTUVWXYZ]* ]]; then
                        ascii_lower "$gis"
                        gis="$ASCII_LOWER"
                    fi
                    for (( gah = 0; gah < 8; gah++ )); do
                        if [[ "$v" != *" $gis="* ]]; then
                            break
                        fi
                        gav="${v##*" $gis="}"
                        gis="${gav%% *}"
                    done
                    if [[ "$v" == *" $gis="* ]]; then
                        _deny_shell "git -c alias chain"
                    fi
                fi
                _git_cmd_start "$gis"
            fi
        fi
        if [[ "$act" == *H* ]]; then
            # shv queues the words an option bundle takes as values, one letter each, in order: o an option name (-o;
            # xtrace and verbose are denied), O a shopt name, S a script (--rcfile). bash takes one value word for every
            # o or O in a bundle, wherever it sits (-oeo takes two).
            if [[ -n "$shv" ]]; then
                if [[ "$shv" == o* ]] && [[ "$w" == xtrace || "$w" == verbose ]]; then
                    _deny_shell "$shn -o $w"
                elif [[ "$shv" == S* ]] && (( wsec )); then
                    _deny_reader "$shn $w"
                fi
                shv="${shv:1}"
            elif [[ "$w" == --rcfile || "$w" == --init-file ]]; then
                shv=S
            elif [[ "$w" == --rcfile=* || "$w" == --init-file=* ]]; then
                if (( wsec )); then
                    _deny_reader "$shn $w"
                fi
            elif [[ "$w" == --verbose ]]; then
                _deny_shell "$shn $w"
            elif [[ "$w" == -[!-]* ]]; then
                if [[ "$w" == *[cxv]* ]] || (( ${#w} > 64 )); then
                    _deny_shell "$shn $w"
                fi
                if [[ "$w" == *s* ]]; then
                    shs=1
                fi
                shv="${w//[!oO]/}"
            elif [[ "$w" == +?* ]]; then
                if (( ${#w} > 64 )); then
                    _deny_shell "$shn $w"
                fi
                shv="${w//[!oO]/}"
                shv="${shv//o/O}"
            elif [[ "$w" != [-+]* ]]; then
                # The program: a shell reading a secret file as its script prints it in its errors. A path that may
                # name its own input (/dev/stdin, /DEV/fd/0, dev/stdin, a .. path: _names_input) is not a program, so a
                # shell given one stays unresolved (a fed one is denied at stage end). Every program word is still
                # read: one that names a secret is a reader deny either way.
                if (( wsec )); then
                    _deny_reader "$shn $w"
                fi
                # With -s the words after it are arguments and stdin is still the script, so the walk goes on.
                if (( ! shs )) && ! _names_input "$w" fd; then
                    act="${act//H/}"
                fi
            fi
        fi
        if [[ "$act" == *K* ]]; then
            if (( kpv )) && [[ "$w" != -* ]]; then
                # An option's value: never the program, but still a secret word if it names one, even in the vault,
                # since the option may take no value and the word be the program. A word that looks like an option
                # is not taken as one, so an inline-code bundle there still starts inline code.
                kpv=0
                if (( wsec )); then
                    _deny_reader "$ipw $w"
                fi
                if [[ -z "$ksub" ]] && [[ "$ipn" == bun || "$ipn" == deno ]]; then
                    _k_sub "$w" 1
                fi
            elif [[ "$w" != -* ]]; then
                if (( wsec )); then
                    _deny_reader "$ipw $w"
                fi
                if [[ -z "$ksub" ]] && [[ "$ipn" == bun || "$ipn" == deno ]]; then
                    _k_sub "$w" 0
                fi
                # A vault env file's program must be a script a plain literal word names, with no other option, none
                # from a NODE_OPTIONS the command may set either: node must be the stage's first word (an assignment
                # or wrapper before it may set one under a name no text test reads), with no sourced file, set -a or
                # sequence separator, and no NODE_OPTIONS named. Anything else may run code that prints what node
                # loaded. The stage end checks nothing feeds it.
                if [[ -n "$kvf" ]]; then
                    if (( kon || cdsq || ! kfst )) || [[ -z "$w" || "$w" == *[\$\`\\\*\?\[\{]* || "$wmk" == *b* ]] \
                            || _names_input "$w" fd \
                            || _cd_names NODE_OPTIONS || _k_env_sourced; then
                        _deny_reader "$ipw $kvf ... $w"
                    fi
                    kvp="$kvf"
                fi
                # bun and deno take a subcommand (run, eval, test, …), often followed by a program file, so a word
                # does not end their walk: every later word stays screened as theirs.
                if [[ "$ipn" != bun && "$ipn" != deno ]] && ! _names_input "$w" fd; then
                    act="${act//K/}"
                fi
            elif [[ "$w" == -?* && "$w" != -- ]]; then
                kpv=0
                kvw=0
                if (( wsec )); then
                    # A vault env file is allowed only for a script file: inline code or a program read from stdin
                    # could print what it loads, so it is held (kvf) until the program is known.
                    if _k_vault_value "$w"; then
                        kvf="$w"
                        kvw=1
                    else
                        _deny_reader "$ipw $w"
                    fi
                fi
                if (( ! kvw )); then
                    kon=1
                fi
                if [[ "$ipn:$ksub" == deno:task ]] && [[ "$w" == --eval || "$w" == --eval=* ]]; then
                    _deny_shell "deno task $w"
                fi
                if _k_inline "$w"; then
                    _k_code "$w"
                elif [[ "$w" == --* ]]; then
                    # Fail closed: any long option may take the next word as its value (node and ruby have dozens).
                    if [[ "$w" != *=* ]]; then
                        kpv=1
                    fi
                else
                    _k_valopt "$w"
                fi
            else
                # - or --.
                kon=1
            fi
        elif [[ "$act" == *L* ]] && (( wsec )); then
            _deny_reader "$ipw ... $w"
        fi
        if [[ "$act" == *C* ]]; then
            cptw=0
            if (( cptok && ! cptn )); then
                case "$w" in
                    --t*)
                        # GNU tools take any unambiguous prefix of a long option (--target, --target-dir=DIR); the
                        # name is at most 19 characters, so only that much of the word is cut.
                        cpo="${w:0:19}"
                        cpo="${cpo%%=*}"
                        if [[ --target-directory == "$cpo"* ]]; then cptw=1; fi ;;
                    --*) ;;
                    -*t*)
                        # The t is the flag only before any letter that takes a value (S; for install also g, m, o):
                        # that letter takes the rest of the bundle, so a t after it is part of the value.
                        cpo="${w%%t*}"
                        if [[ "$cpo" != *S* ]] && [[ "$cpn" != install || "$cpo" != *[gmo]* ]]; then cptw=1; fi ;;
                esac
            fi
            if (( cptn )); then
                cptn=0
            elif (( cptw )); then
                # The flag is the long option (the next word is the directory unless =DIR follows) or the first t of
                # a single-dash bundle (-t, -rt, -vt, -tDIR): the next word is the directory when nothing follows
                # the t, else the rest of the bundle is.
                if [[ "$w" == --* ]]; then
                    if [[ "$w" != *=* ]]; then cptn=1; fi
                elif [[ "$w" == -[!-]* && -z "${w#*t}" ]]; then
                    cptn=1
                fi
                # With a target directory every operand is a source, the one held back included.
                cpt=1
                if (( cph && cpps )); then _deny_copier "$cpp"; fi
                cph=0
            elif [[ "$w" == -* ]]; then
                if (( wsec )); then _deny_copier "$w"; fi
            elif (( cpt )); then
                if (( wsec )); then _deny_copier "$w"; fi
            else
                # Every operand but the last is a source: hold one back until the next shows it was not the last.
                if (( cph && cpps )); then _deny_copier "$cpp"; fi
                cpp="$w"
                cpps=$wsec
                cph=1
            fi
        fi
        if [[ "$act" == *D* ]]; then
            if [[ "$w" == -* ]]; then
                if [[ "$dk" != printenv && "$w" == -[!-]* && "$w" == *p* ]]; then dp=1; fi
                if [[ "$dk" == typeset && "$w" == -[!-]* && "$w" == *m* ]]; then dm=1; fi
            elif [[ "$dk" != printenv && "$w" == [A-Za-z_]*=* && "${w%%=*}" != *[!A-Za-z0-9_+]* ]]; then
                da=1
                if [[ "$dk" == export ]]; then dn=$(( dn + 1 )); fi
            else
                dn=$(( dn + 1 ))
                if [[ -z "$db" ]] && [[ "$w" == *[\$\*\?\[]* ]]; then
                    db="$w"
                elif [[ -z "$db" && "$dk" != export && "$w" =~ $secret_name_re ]]; then
                    db="$w"
                fi
            fi
        fi
        if [[ "$act" == *O* ]]; then
            act="${act//O/}"
            if [[ "$w" != -* && "$w" == *e* ]]; then
                _deny_env "ps $w"
            fi
        fi
        if [[ "$act" == *o* && "$w" == -[!-]* && "$w" == *E* ]]; then
            _deny_env "ps $w"
        fi
        if [[ "$act" == *J* ]]; then
            if [[ "$w" == *env* && "$w" =~ (^|[^A-Za-z0-9_.$])env([^A-Za-z0-9_]|$) ]] || [[ "$w" == *'$ENV'* ]]; then
                _deny_env "jq $w"
            fi
            _jq_mod_check "$w"
            if (( jqown )); then
                _jq_word "$w"
                if [[ "$w" == *[\*\?\[\{\$\`]* || "$wmk" == *b* ]] && _w_expands; then
                    jqunk=1
                    wrole=""
                fi
            fi
        fi
        if [[ "$act" == *W* && "$w" == *ENVIRON* ]]; then
            _deny_env "awk ENVIRON"
        fi
        if [[ "$act" == *U* && "$w" == -[!-]* && "$w" == *c* ]]; then
            _deny_shell "$sun $w"
        fi
        # watch and parallel run their words through a shell, which parses them again: a word holding whitespace or
        # shell syntax (quotes and backslashes included, as they would be removed there, and a leading =, zsh's command
        # expansion) is a command string. Every parallel word counts: with no command template its arguments are the
        # commands. In parallel's words a brace counts only outside a replacement string.
        if [[ "$act" == *N* ]]; then
            if [[ "$w" == *[[:space:]\;\&\|\<\>\(\)\$\`\\\"\'\*\?\[]* || "$w" == =* ]]; then
                _deny_shell "$wpn '$w'"
            elif [[ "$w" == *[\{\}]* || "$wmk" == *b* ]]; then
                if [[ "$wpn" != parallel ]] || ! _braces_are_replacements "$w"; then
                    _deny_shell "$wpn '$w'"
                fi
            fi
            # parallel with no command template reads its commands from its input: wpc marks the template's first
            # word. An option word with no = that ends in a letter takes the next word as its value (fail closed: the
            # value-taking options are too many to list).
            if [[ "$wpn" == parallel ]] && (( ! wpc )); then
                if (( wpo )); then
                    wpo=0
                elif [[ "$w" == ::: || "$w" == :::+ || "$w" == :::: || "$w" == ::::+ ]]; then
                    wpc=2
                elif [[ "$w" == -?* ]]; then
                    if [[ "$w" != *=* && "$w" == *[A-Za-z] ]]; then wpo=1; fi
                    # Its own replacement strings, and an argument file (-a, --arg-file and their abbreviations).
                    if [[ "$w" == -I* || "$w" == --*replace* || "$w" == --rpl* ]]; then xqr=1; fi
                    if [[ "$w" == -[!-]*a* || "$w" == --arg-f* ]]; then xaf=1; fi
                elif [[ -n "$w" ]]; then
                    wpc=1
                    # A command holding a replacement string is named by the input, and may be a shell.
                    if [[ "$w" == *'{'* || "$wmk" == *b* ]]; then
                        _deny_shell "parallel running the command its input names ('$w')"
                    fi
                fi
            fi
            if [[ "$wpn" == parallel && ( "$w" == :::: || "$w" == ::::+ ) ]]; then
                xaf=1
            fi
        fi
        # ssh joins its later words with spaces for the remote shell, which parses them again, so a word holding
        # whitespace or shell syntax is a command string; so is an option naming a local command (LocalCommand,
        # ProxyCommand, KnownHostsCommand: any ...command=). The first word that is neither an option nor an option's
        # value is the host, and the next such word (options are parsed after the host too) starts a remote command:
        # with none, ssh runs its input there. A letter that is not a known flag takes a value (fail closed).
        if [[ "$act" == *M* ]]; then
            if [[ "$w" == *[[:space:]\;\&\|\<\>\(\)\$\`\\\"\'\{\}\*\?\[]* || "$w" == =* || "$wmk" == *b* \
                    || "$w" == *[cC][oO][mM][mM][aA][nN][dD]=* ]]; then
                _deny_shell "$smn '$w'" "$SSH_REMEDY"
            fi
            # An option value naming this command's own input (-F /dev/stdin, -oX=/dev/fd/3) reads what the command
            # line supplies, and so may a config file (-F) named by a bare fd number; an empty word is no command, as
            # ssh joins it to nothing.
            if (( smc )); then
                :
            elif (( smo )); then
                smo=0
                if _names_input "$w" "$smf" || { [[ "$w" == *=* ]] && _names_input "${w#*=}"; }; then
                    _deny_shell "$smn option value '$w'"
                fi
            elif [[ "$w" == -?* ]]; then
                if [[ "$w" == *=* ]] && _names_input "${w#*=}"; then
                    _deny_shell "$smn option value '$w'"
                fi
                # A value-taking letter takes the rest of its bundle, or the next word when it ends the bundle.
                smx="${w#-}"
                while [[ -n "$smx" ]]; do
                    if [[ "${smx:0:1}" != [46AaCfGgKkMNnqsTtVvXxYy] ]]; then
                        smf=""
                        if [[ "${smx:0:1}" == F ]]; then smf=fd; fi
                        if (( ${#smx} == 1 )); then
                            smo=1
                        elif _names_input "${smx:1}" "$smf"; then
                            _deny_shell "$smn option value '$w'"
                        fi
                        break
                    fi
                    smx="${smx:1}"
                done
            elif [[ -z "$w" ]]; then
                :
            elif (( smh )); then
                smc=1
            else
                smh=1
            fi
        fi
        if [[ "$act" == *x* ]]; then
            if (( xo )); then
                _xargs_opt "$w"
            fi
            if (( xan )); then
                xan=0
                if (( wsec )); then _deny_reader "xargs -a $w"; fi
            elif [[ "$w" == -a || "$w" == --arg-file ]]; then
                xan=1
            elif [[ "$w" == -a?* || "$w" == --arg-file=* ]] && (( wsec )); then
                _deny_reader "xargs $w"
            fi
        fi
        if [[ "$act" == *Z* ]]; then
            act="${act//Z/}"
            case "$w" in
                --version|-v|--help|-h|help|version|status|whoami|lock|sync) ;;
                *)
                    if (( nsep > 0 || si > 0 )); then hook_deny "$FETCH_MSG"; fi
                    if (( swf_stage < 0 )); then swf_stage=$si; fi ;;
            esac
        fi
        if [[ "$act" == *f* ]]; then
            # find's roots: the words before its first expression word, past its leading options (-D and -S take a
            # value, -f names a root). bfs, the Bash tool's find, also takes a root anywhere later, so a later literal
            # word is kept as a word that may be a root.
            if (( fsk )); then
                if (( fsk == 2 )); then
                    _find_root_add "$w"
                fi
                fsk=0
            else
                if (( fpr )); then
                    case "$w" in
                        -L) fL=1 ;;
                        -H|-P|-E|-X|-s|-x|-d|-O?*|-j?*) ;;
                        -D|-S) fsk=1 ;;
                        -f) fsk=2 ;;
                        -*|'('|'!') fpr=0 ;;
                        *) _find_root_add "$w" ;;
                    esac
                fi
                if (( ! fpr )); then
                    _find_name_word "$w"
                    case "$w" in
                        -L|-follow) fL=1 ;;
                        -f) fsk=2 ;;
                        -files0-from) ffz=1 ;;
                        -*|'('|')'|'!'|','|';'|'+'|'{}') ;;
                        *)
                            if (( fcan >= 64 )); then
                                fco=1
                            elif [[ "$w" != *'$'* ]] && ! _rr_has_glob "$w"; then
                                fca+="$w"$'\x1e'
                                fcan=$(( fcan + 1 ))
                            fi ;;
                    esac
                fi
            fi
            case "$w" in
                -exec|-execdir|-ok|-okdir)
                    act="${act//f/}g"
                    cmv=0   # a command -v covers one command: this exec starts another
                    fxa=0
                    fxp=""
                    fxd=0
                    if [[ "$w" == -execdir || "$w" == -okdir ]]; then fxd=1; fi
                    if [[ "$sf" != *A* ]]; then sf+=A; fxa=1; fi ;;
            esac
        fi
        if [[ "$act" == *d* ]]; then
            case "$w" in
                --decrypt*) dcf=1 ;;
                --*) ;;
                -*d*) dcf=1 ;;
            esac
        fi
        if [[ "$act" == *k* ]]; then
            if (( kxv )); then
                kxv=0
                _k_extract_to "$w"
            else
                case "$w" in
                    get)
                        kg=1 ;;
                    -o|-o?*|--output|--output=*|--template|--template=*)
                        ko=1 ;;
                    --to)
                        kxv=1 ;;
                    --to=*)
                        _k_extract_to "${w#*=}" ;;
                    *[Ss][Ee][Cc][Rr][Ee][Tt]*)
                        if (( kg )) && [[ "$w" =~ ^(.*,)?[Ss][Ee][Cc][Rr][Ee][Tt][Ss]?([.,/].*)?$ ]]; then ks=1; fi ;;
                    extract)
                        if [[ "$kt" == oc ]]; then kx=1; fi ;;
                esac
            fi
        fi
        # gh's walk (ghs: 0 its subcommand due, 1 auth's, 2 auth status's options, 3 alias, 4 config). A fetch is auth
        # token or git-credential, auth status -t or --show-token (or a bundle holding t), an alias whose words name auth,
        # or a config key naming a token. gh takes options anywhere, and one without = may take the next word (ghp).
        if [[ "$act" == *a* ]]; then
            case "$ghs" in
                0|1)
                    if [[ "$w" == -* ]]; then
                        ghp=1
                        if [[ "$w" == *=* ]]; then ghp=0; fi
                    else
                        if [[ "$ghs" == 0 ]] && (( ghown )); then
                            wrole=x
                        fi
                        case "$ghs:$w" in
                            0:auth) ghs=1 ;;
                            0:alias) ghs=3 ;;
                            0:config) ghs=4 ;;
                            1:token|1:git-credential) ghs=9; fetch_hit=1 ;;
                            1:status) ghs=2 ;;
                            *) if (( ! ghp )); then ghs=9; fi ;;
                        esac
                        ghp=0
                    fi ;;
                2)
                    case "$w" in
                        --show-token*) ghs=9; fetch_hit=1 ;;
                        --*) ;;
                        -*t*) ghs=9; fetch_hit=1 ;;
                    esac ;;
                3)
                    if [[ "$w" == *auth* ]]; then ghs=9; fetch_hit=1; fi ;;
                4)
                    if [[ "$w" == *[Tt][Oo][Kk][Ee][Nn]* ]]; then ghs=9; fetch_hit=1; fi ;;
            esac
            if (( ghs == 9 )); then act="${act//a/}"; fi
        fi
    fi

    # An S word the walk gave a role (P, or F: the pattern unless an option gave one) is counted apart from the S words
    # that are files; a word whose S came from a pathspec or a wildcard, or that holds a glob character the shell
    # expands (not all quoted), is never a pattern.
    if (( wsec )); then
        if (( ! wsx )) && [[ "$w" == *[\*\?\[\{]* && "$wmk" != *g* ]]; then
            wsx=1
        fi
        case "$wrole" in
            P)
                if (( wsx )); then
                    _snx "$w"
                else
                    spn=$(( spn + 1 ))
                fi ;;
            F)
                if (( wsx )); then
                    _snx "$w"
                else
                    spf=1
                    if [[ -z "$spfw" ]]; then
                        spfw="$w"
                    fi
                fi ;;
            *) _snx "$w" ;;
        esac
    fi

    # Command position: the first word after leading assignments, the command an env walk unwrapped, or any word of
    # a stage whose command word is ! or a known wrapper. hok marks where the source builtin can run: the first command
    # word, or the word right after command, builtin, time, !, noglob or nocorrect (pwrap), past the options the first
    # three take and the assignments time and ! allow.
    hok=0
    if (( ! cs )); then
        if [[ "$w" != [A-Za-z_]*=* || "${w%%=*}" == *[!A-Za-z0-9_+]* ]]; then
            cs=1
            atcmd=1
            hok=1
            cw1=1
            _np_start
        else
            rrasg=1
        fi
    elif [[ "$sf" == *A* ]]; then
        atcmd=1
        hok=$pwrap
    fi
    # A command word: the stage's first, the one env unwraps, or any word of a wrapper's stage, as the hook cannot tell
    # a wrapper's option values and operands from the command it runs. The whole word is tested: a brace or glob in the
    # directory part (/{bin/cat,x/.env}) changes which program runs and what it reads. A held ask keeps its first
    # reason, so once one is held the test is skipped. A vault path is no exception: no scan proves the vault variable
    # unchanged.
    if (( atcmd && ! cmv )) && [[ -z "${_HOOK_HELD_ASK:-}" && ( "$w" == *[\\\$\`\{\*\?\[]* || "$wmk" == *b* ) \
            && "$w" != '[' && "$w" != '[[' ]]; then
        cwhat="the command word"
        if (( ! hok )) && [[ "$sf" == *A* ]]; then cwhat="a word of this wrapper's command"; fi
        if [[ "$w" == -* ]]; then
            _asm_hold "${w%%=*}" "$cwhat"
        else
            _asm_hold "$w" "$cwhat"
        fi
    fi
    kn=""
    kc=""
    if [[ -n "$wrole" ]]; then
        :
    elif [[ "$nm" != *[!a-z0-9]* ]]; then
        v="_nm_$nm"
        kn="${!v:-}"
        if (( atcmd )); then
            v="_cp_$nm"
            kc="${!v:-}"
        fi
    elif [[ "$nm" == '!' ]] && (( atcmd )); then
        kc=A
    elif [[ "$nm" == '{' ]] && (( atcmd )); then
        kc=b
    elif [[ "$nm" == . ]] && (( atcmd )); then
        kc=h
    elif [[ "$nm" == aws-vault ]] && (( atcmd )); then
        kc=A
    elif [[ "$nm" == docker-compose || "$nm" == podman-compose ]]; then
        kn=L
    fi
    # A versioned name with no class of its own (python3.12, node22, gpg2) is classed by its leading letters, which
    # then name it for its walk; nmw keeps the name as written for messages.
    nmw="$nm"
    if [[ -z "$kn$kc$wrole" && "$nm" == [a-z]*[0-9.] && "$nm" =~ $VER_NAME_RE ]]; then
        vb="${BASH_REMATCH[1]}"
        v="_nm_$vb"
        kn="${!v:-}"
        if (( atcmd )); then
            v="_cp_$vb"
            kc="${!v:-}"
        fi
        if [[ -n "$kn$kc" ]]; then
            nm="$vb"
        fi
    fi
    if [[ "$kn" == [HNQUBK] || "$kc" == [vM] ]]; then
        srp=1
    fi
    if (( atcmd )); then
        ssk=""
        case "$nm" in
            awk|gawk|mawk|nawk|awk[0-9]*|gawk[0-9]*|mawk[0-9]*|nawk[0-9]*)
                ssk=a ;;
            sed|gsed|sed[0-9]*|gsed[0-9]*)
                ssk=s ;;
        esac
        if [[ -z "$ssk" ]]; then
            :
        elif [[ -z "$ssa" ]]; then
            ssa="$ssk"
        elif [[ "$ssa" != "$ssk" ]]; then
            _deny_shell "sed and awk both at command position"
        elif [[ "$ssk" == s ]]; then
            _sed_rename "$w"
        fi
    fi
    if [[ "$kc" == h ]] && (( ! hok )); then
        kc=""
    fi
    if (( gh_soft && ! strun )) && [[ -z "$wrole" ]] \
            && [[ "$kn" == [BGHKNQUWX] || "$kc" == [Mhv] || "$nm" == sed ]]; then
        strun=1
    fi
    np=0
    if (( atcmd )); then
        if (( pwrap )); then
            case "$pwk" in
                command|builtin)
                    if [[ "$w" == -* ]]; then
                        np=1
                        # command -v and -V only name a command: the words after them run nothing.
                        if [[ "$pwk" == command && "$w" == -[pvV]* && "$w" != -*[!pvV]* && "$w" == *[vV]* ]]; then
                            cmv=1
                        fi
                    fi ;;
                time) if [[ "$w" == -* || "$w" == [A-Za-z_]*=* ]]; then np=1; fi ;;
                '!') if [[ "$w" == [A-Za-z_]*=* ]]; then np=1; fi ;;
            esac
        fi
        case "$w" in
            command|builtin|time|'!'|noglob|nocorrect) np=1; pwk="$w" ;;
        esac
    fi
    pwrap=$np
    if (( atcmd )) && [[ "$act" != *u* ]]; then
        case "$nm" in
            kubectl|oc|doppler|heroku)
                act+=u
                run_t="$nm" ;;
        esac
    fi
    if (( atcmd )); then
        case "$nm" in
            [Gg][Ii][Tt]-?*) _git_cmd_start "${nm:4}" ;;
        esac
    fi
    if [[ -n "$kc" ]]; then
        case "$kc" in
            A)
                if [[ "$sf" != *A* ]]; then sf+=A; fi ;;
            b)
                _deny_group "$nm" ;;
            M)
                if [[ "$sf" != *A* ]]; then sf+=A; fi
                if [[ "$act" != *M* ]]; then act+=M; fi
                smn="$nm"
                smo=0
                smf=""
                smh=0
                smc=0 ;;
            E)
                if [[ "$act" != *E* ]]; then
                    act+=E
                    ews=0
                    ewn=0
                    ewf=""
                    ewu=0
                    ewo=0
                fi ;;
            e)
                _dump_start export ;;
            s)
                if [[ "$sf" != *s* ]]; then sf+=s; fi
                setw=$nw ;;
            v)
                _deny_shell "eval" ;;
            Z)
                if [[ "$act" != *Z* ]]; then act+=Z; fi ;;
            f)
                if [[ "$act" != *f* ]]; then act+=f; fi
                # A find inside another's -exec adds to the first find's roots.
                if (( ! ffs )); then
                    ffs=1
                    fpr=1
                    fro=""
                    fron=0
                    fL=0
                    fsk=0
                    fca=""
                    fcan=0
                    fco=0
                    ffz=0
                    fnv=0
                    fnx=0
                    fnn=0
                    fmd=0
                    fng=""
                    fnr=""
                fi ;;
            c)
                act="${act//c/}"
                if _cd_count; then
                    act+=c
                    cdd=0
                    cdn=0
                    cdo=""
                    cdk="$nm"
                fi ;;
            k)
                if [[ "$act" != *k* ]]; then
                    act+=k
                    kt=""
                    kg=0
                    ks=0
                    ko=0
                    kx=0
                    kxt=0
                    kxv=0
                fi
                # An oc a kubectl exec runs counts too.
                if [[ "$nm" == oc ]]; then
                    kt=oc
                fi ;;
            d)
                if [[ "$act" != *d* ]]; then
                    act+=d
                    dcf=0
                fi ;;
            h)
                if [[ "$act" != *H* ]]; then
                    act+=H
                    shn="$nm"
                    shv=""
                    shs=0
                    shq=0
                fi ;;
        esac
    fi
    if [[ -n "$kn" ]]; then
        case "$kn" in
            R|J|W)
                if [[ "$sf" != *R* ]]; then rdn="$nmw"; sf+=R; fi
                if [[ "$sf" == *X* && "$sf" != *Y* ]]; then sf+=Y; fi
                if [[ "$act" == *g* ]]; then fxr=1; fi
                nrd=$(( nrd + 1 ))
                case "$nm" in
                    grep|egrep|fgrep|ggrep|ugrep|ug|rg|diff) _rr_start "$nm" ;;
                esac
                if [[ "$kn" == J && "$act" != *J* ]]; then
                    jqown=$cw1
                    jqq=""
                    jqf=0
                    jqa=0
                    jqn=0
                    jqdd=0
                    jqunk=$rrasg
                fi
                if [[ "$kn" != R && "$act" != *"$kn"* ]]; then act+=$kn; fi ;;
            G)
                if [[ "$act" != *G* ]]; then act+=G; fi
                gcd=""
                gwp=""
                gwt=0
                gcore=0
                gal=""
                gown=$cw1
                git_walk_start ;;
            H)
                # A shell name given as an argument (bash -s sh) must not reset what the first shell set.
                if [[ "$act" != *H* ]]; then
                    act+=H
                    shs=0
                    shq=$atcmd
                fi
                shn="$nmw"
                shv="" ;;
            K)
                # A later interpreter name is a word of bun's or deno's program, whose walk never ends: it goes on.
                if [[ "$act" != *K* ]] || [[ "$ipn" != bun && "$ipn" != deno ]]; then
                    act="${act//L/}"
                    if [[ "$act" != *K* ]]; then act+=K; fi
                    kpv=0
                    kvf=""
                    kon=0
                    kfst=0
                    if (( nw == 1 )); then kfst=1; fi
                    ipn="$nm"
                    ipw="$nmw"
                    ksub=""
                fi ;;
            C|Ct)
                if [[ "$act" != *C* ]]; then act+=C; fi
                if [[ "$sf" == *X* && "$sf" != *Q* ]]; then sf+=Q; fi
                cpn="$nm"
                cptok=0
                if [[ "$kn" == Ct ]]; then cptok=1; fi
                cpt=0
                cptn=0
                cph=0
                cpps=0
                cpp="" ;;
            D)
                _dump_start "$nm" ;;
            P)
                if [[ "$sf" != *P* ]]; then sf+=P; fi ;;
            T)
                if [[ "$sf" != *T* ]]; then tdn="tee"; sf+=T; fi ;;
            X)
                if [[ "$sf" != *T* ]]; then tdn="xargs"; sf+=T; fi
                if [[ "$sf" != *X* ]]; then sf+=X; fi
                if [[ "$act" != *x* ]]; then act+=x; fi
                xan=0
                xo=1
                xov="" ;;
            Q)
                if [[ "$sf" != *X* ]]; then sf+=X; fi
                if [[ "$act" != *N* ]]; then act+=N; fi
                # parallel's {} is the input; its other replacement strings ({.}, {//}) are other braces (xbr).
                if [[ -z "$xrep" ]]; then
                    xrep='{}'
                    xbr=1
                fi
                wpn=parallel
                wpo=0
                wpc=0 ;;
            N)
                if [[ "$act" != *N* ]]; then act+=N; fi
                wpn=watch ;;
            O)
                act="${act//[Oo]/}Oo" ;;
            U)
                if [[ "$act" != *U* ]]; then act+=U; fi
                sun="$nmw" ;;
            S)
                if (( si == 0 )); then sgs=1; fi ;;
            a)
                if [[ "$act" != *a* ]]; then act+=a; fi
                ghs=0
                ghp=0
                ghown=$cw1 ;;
            L)
                if (( atcmd )) && [[ "$act" != *l* ]]; then
                    act+=l
                    lgt="$nm"
                    lgl=0
                    lgv=0
                    dcm=0
                    dcn=0
                    dcx=0
                    dci=0
                    dce=0
                    dcb=0
                    dcsk=0
                    dcu=0
                    dsk=0
                    dsv=0
                    drc=0
                    dpw=""
                    if [[ "$nm" == *-compose ]]; then dcm=1; fi
                fi ;;
        esac
    fi
    # shellcheck disable=SC2053  # secret_var_glob is an intentional pattern
    if [[ "$w" == *'$'* && "$sf" != *V* && "$w" == $secret_var_glob && "$w" =~ $secret_var_re ]]; then
        # A marked word (every $ in it quoted) is text, so only the first is kept as vmq: _mk_vsettle makes it a V when
        # the stage re-parses its words, runs awk or sed, or feeds a pipe. An unmarked one is a V at once.
        if [[ "$wmk" == *d* ]]; then
            if [[ -z "$vmq" ]]; then vmq="$w"; fi
        else
            vrw="$w"
            sf+=V
        fi
    fi
    # An assignment of a variable that moves a registry login's credentials; += appends to a value it cannot see.
    if [[ "$w" == [DRHX]*=* ]]; then
        lgn="${w%%=*}"
        if [[ "$lg_names" == *" ${lgn%+} "* ]]; then
            if [[ "$lgn" == *+ ]]; then
                _lg_auth "+${w#*=}"
            else
                _lg_auth "${w#*=}"
            fi
        fi
    fi
    if (( si == 0 )); then
        if [[ "$w" == --debug || "$w" == --log-http || "$w" == -v || "$w" == --v || "$w" == -v[0-9]* \
                || "$w" == -v=* || "$w" == --v=* || "$w" == --verbosity=debug ]] \
                || [[ "$pw" == --verbosity && "$w" == debug ]]; then
            dbg=1
        fi
        if (( sgs )) && [[ "$w" == -[!-]* && "$w" == *g* ]]; then
            sgf=1
        fi
        pw="$w"
    elif (( si == 1 )); then
        # A registry login: docker/podman/oras login or helm registry login, behind assignments and wrappers.
        if [[ "$w" == --password-stdin ]]; then
            lgpw=1
        fi
        case "$lgst" in
            0)
                case "$nm" in
                    docker|podman|oras) lgst=1 ;;
                    helm) lgst=2 ;;
                    -*|*=*|sudo|doas|nice|nohup|time|timeout|command|exec|stdbuf|env) ;;
                    *) lgst=9 ;;
                esac ;;
            1)
                if [[ "$w" == login ]]; then lgok=1; lgst=8; elif [[ "$w" != -* ]]; then lgst=9; fi ;;
            2)
                if [[ "$w" == registry ]]; then lgst=1; elif [[ "$w" != -* ]]; then lgst=9; fi ;;
        esac
    fi
done
spipe=0
_stage_end

if (( gh_soft && strun )); then
    fetch_hit=1
fi

# A fetch is allowed in two shapes only: the whole command is the fetch with exactly one stdout redirection, into the
# vault (zsh MULTIOS copies stdout to every target and to a following pipe, so exactly one); or a two-stage pipeline
# whose second stage is a registry login reading --password-stdin. Neither may carry a debug flag or security -g,
# which prints the password on stderr.
if (( fetch_hit || swf_stage >= 0 )); then
    ok=0
    if (( nsep == 0 && ! dbg && ! sgf )); then
        if (( si == 1 && s1_fd1 == 1 && s1_vault )); then
            ok=1
        elif (( si == 2 && s1_fd1 == 0 && s2_login )); then
            ok=1
        fi
    fi
    if (( ! ok )); then
        hook_deny "$FETCH_MSG"
    fi
fi

# The directory probe, last: it lists the roots the walks collected, in one bounded pipeline.
if (( PROBE_N > 0 )); then
    prc=0
    dir_holds_secret || prc=$?
    if (( prc == 0 )); then
        _deny_probe "${PROBE_FORM[DHS_IDX]}" "$DHS_HITS"
    elif (( prc == 2 )); then
        _hold_probe "${PROBE_FORM[0]}" "$DHS_WHY"
    fi
fi

hook_pass
