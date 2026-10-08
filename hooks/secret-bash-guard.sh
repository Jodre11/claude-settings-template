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
# subcommands do not.
_ci ansible-vault
ci_ansible="$CI_RE"
_ci terraform
ci_tf="$CI_RE"
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
    'gh[[:space:]]+auth[[:space:]]+token'
    'gh[[:space:]]+auth[[:space:]]+status[[:space:]](.*[[:space:]])?(-t|--show-token)'
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
# The other tools' forms are matched only on a text that names one of them (tools_re): bash's regex engine takes time
# in proportion to the pattern's size for every character, so one pattern of them all would slow every command.
tools_re="(${ci_ansible}|${ci_tf}|${ci_npm}|${ci_doppler}|${ci_heroku}|${ci_launchctl}|${ci_av})"
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
# docker-compose and podman-compose). Command position: A wrapper (every later word is at command position too, and
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
    'nm W awk gawk'
    'nm G git'
    'nm H sh bash zsh dash ksh'
    'nm K python python3 perl ruby node php'
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
    'cp A sudo doas nice nohup time timeout command builtin exec noglob nocorrect xargs stdbuf ionice caffeinate'
    'cp A chronic flock unbuffer setsid direnv parallel'
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
plain_names='! . { -- --debug --v --log-http --verbosity debug docker-compose podman-compose aws-vault doppler heroku'
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

# _deny_shell <form>: deny a shell or command runner given a command string.
_deny_shell() {
    local msg="SHELL-STRING BLOCK: '$1' runs a command string this hook cannot screen. Write the commands to a"
    msg+=" script in \$CLAUDE_TEMP_DIR with the Write tool and run it with 'bash <file>' instead."
    hook_deny "$msg"
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
    if _rr_has_glob "$o"; then
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
# one reading only (tag m). Positional words after git's -- are tagged W. At most 65 positional and 64 m words are
# kept; the counts go on.
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
    rrops+="$t$2"$'\x1e'
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
                    if [[ "$c" == d && "$rrn" == grep ]]; then rrv=d; else rrv=v; fi
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
    local n="${1%%=*}" v="" eq=0 k
    if [[ "$1" == *=* ]]; then
        v="${1#*=}"
        eq=1
    fi
    k="${n#--}"
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
                if [[ "$k" == context || "$k" == group-separator ]]; then rrv=m; else rrv=v; fi
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
    local p="$rrv"
    if [[ -n "$p" ]]; then
        rrv=""
        case "$p" in
            v) return 0 ;;
            d) if [[ "$1" == recurse ]]; then rrec=1; fi; return 0 ;;
            i) _rr_inc "$1"; return 0 ;;
            x) _rr_exc "$1"; return 0 ;;
            X) _rr_xdir "$1"; return 0 ;;
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
        _rr_op w "$1"
    fi
    rrsup=0
}

# _rr_settle: end the probe walk (_rr_settle_walk), then restore the globals the walk's probes read.
_rr_settle() {
    _rr_settle_walk
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

# _rr_settle_walk: a reader that prints contents has each operand probed (the first is its pattern unless -e or -f gave
# one; diff and git diff --no-index have none, and probe every operand); a recursive one with no operand naming an
# existing path probes its working directory (git -C's, for git), except an rg whose stdin it reads. A reader after
# xargs takes more words from its input, so neither shortcut applies there. Inside find -exec, a {} operand is find's
# and, under -execdir, a relative root holds an ask. A names-only reader queues its roots for a reader after xargs and
# marks the stage (srl). A git grep operand that is no path may be a revision, and a pathspec with magic may reach past
# the root: each holds an ask. After xargs or parallel, a recursive reader's operand holding the replacement string
# has the directory before it probed, following links (xk), as grep -r follows a link it is given.
_rr_settle_walk() {
    local rest="$rrops" o t first=1 any=0 kind=find form="$rrd" inc="" exc="" xd="" pslot=1 n deep="$rrec" xk
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
        o="${o:1}"
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
            if [[ "$o" == :* ]]; then
                _rr_hold "$form" "the pathspec '$o' holds magic the hook does not resolve"
                any=1
                continue
            fi
            if [[ "$t" == w ]] && (( ! rrnoi && ! rrunt )) && [[ "$o" != *'$'* ]] && ! _rr_has_glob "$o" \
                    && ! _rr_exists "$o"; then
                _rr_hold "$form" "'$o' may name a revision, whose files the hook cannot list"
                any=1
                continue
            fi
        fi
        if _rr_root "$form" "$kind" "$o" "$inc" "$exc" "$xd"; then
            any=1
        fi
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
    local w="$1" d c pat msg wrc=0 rest wd
    if [[ "$w" == */* ]]; then
        d="${w%/*}"
        c="${w:${#d}+1}"
        d="${d:-/}"
    else
        d=.
        c="$w"
    fi
    if _rr_has_glob "$d"; then
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
    if _rr_has_glob "$d"; then
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
    if _rr_has_glob "$d"; then
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
    if [[ "$cdo$w" == *[\$\*\?\[\{~]* ]]; then
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
# e E p n c r m (php's also B or R), node's --eval or --print, or php's --run or --process-begin, -code or -end.
_k_inline() {
    case "$1" in
        --*)
            case "$ipn:${1%%=*}" in
                node:--eval|node:--print|php:--run|php:--process-begin|php:--process-code|php:--process-end)
                    return 0 ;;
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
# that takes the next word as its value: python -W -X, perl -I -M -x, ruby -I -C, node -C, php -d -S -t -z. A letter
# before the end takes the rest of the bundle. perl's -M and -x take only an attached value, so reading the next word
# as theirs fails closed: that word is then never the program.
_k_valopt() {
    local b="${1#-}" kvl=""
    case "$ipn" in
        python|python3) kvl=WX ;;
        perl) kvl=IMx ;;
        ruby) kvl=IC ;;
        node) kvl=C ;;
        php) kvl=dStz ;;
    esac
    # Two glob tests, not a walk over the letters: a bundle may be 64 KiB long.
    if [[ -n "$kvl" && "$b" == *["$kvl"] && "${b%?}" != *["$kvl"]* ]]; then
        kpv=1
    fi
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
# running (E env options, G git subcommand, H shell program, K interpreter program, L interpreter inline code, C copier
# operands, D dump operands, O ps bundle, o ps options, J jq, W awk, U su/script/flock, N watch/parallel, Z a
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
# word, and kvp holds a vault env file whose script was seen, for the stage end's check that nothing feeds the stage.
kpv=0
kvf=""
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
GW_ACTIVE=0
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
# before, gwt marks a --git-dir or --work-tree and gcore a -c core or submodule setting; the _wild_ strings hold the
# patterns expanded so far and those that matched a secret; wpend holds this stage's ** and brace globs (wgn of them,
# wgo past 64); ecd marks a stage that changes directory first (env -C).
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

# _stage_end: run the stage-end checks, record the fetch facts of a pipeline's first two stages, reset the stage.
_stage_end() {
    local msg
    if [[ -n "$kvp" ]]; then
        if (( si > 0 )) || [[ "$sf" == *F* ]]; then
            _deny_reader "$ipn $kvp fed by a pipe or redirection"
        fi
        kvp=""
    fi
    if (( nw == 0 && nr == 0 )); then
        return 0
    fi
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
        if [[ "$act" == *H* ]] && (( shq )) && { (( si > 0 )) || [[ "$sf" == *F* ]]; }; then
            _deny_shell "$shn fed by a pipe or redirection"
        fi
        if [[ "$act" == *M* ]] && (( ! smc )) && { (( si > 0 )) || [[ "$sf" == *F* ]]; }; then
            _deny_shell "$smn fed by a pipe or redirection"
        fi
        if [[ "$act" == *N* && "$wpn" == parallel ]] && (( wpc != 1 )) && { (( si > 0 )) || [[ "$sf" == *F* ]]; }; then
            _deny_shell "parallel with no command, fed by a pipe or redirection"
        fi
        if [[ "$act" == *[KL]* && "$sf" == *I* ]]; then
            _deny_reader "$ipn <$ins"
        fi
        if [[ "$act" == *K* && -n "$kvf" ]]; then
            _deny_reader "$ipn $kvf with no script file"
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
        fi
        # A cd or pushd with no operand may go to $HOME (zsh's pushd under PUSHD_TO_HOME).
        if [[ "$act" == *c* && "$cdk" != popd ]] && (( cdn == 0 )) && { (( cdsq )) || _cd_names HOME; }; then
            _hold_cd "" "the command may set HOME"
        fi
    fi
    if [[ -n "$sf" ]]; then
        if [[ "$sf" == *R* && "$sf" == *S* ]]; then
            _deny_reader "$rdn $rds"
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
            msg="SECRET-ECHO BLOCK: printing a secret-shaped variable ('$vrw') into context is not allowed. Write"
            msg+=" it to \$CLAUDE_TEMP_DIR from a script instead."
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
}

for el in ${SW_WORDS[@]+"${SW_WORDS[@]}"}; do
    case "$el" in
        w*) ;;
        p*)
            # A plain word changes nothing but the word count and command position, unless a word walk needs it, or
            # the fetch shapes do: they read every word of a fetch's second stage (the login), or it may name a
            # directory outside the cwd (/, ~, a .. segment) for a recursive reader after xargs, or hold an escape or
            # a brace for the name-producer check.
            if [[ -z "$act" && "$el" != p[/~]* && "$el" != p..* && "$el" != *'/..'* && "$el" != *[\\\{]* ]] \
                    && (( si != 1 || ! ( fetch_hit || swf_stage >= 0 ) )); then
                nw=$(( nw + 1 ))
                cs=1
                pwrap=0
                continue
            fi ;;
        '|')
            # With no walk running, no directory glob queued and none of the facts a stage-end check reads (S, I, V, s,
            # Y, Q), a stage ends with nothing to check, or to record for a fetch; only an echo there names paths the
            # hook models (_np_end).
            if [[ -z "$act" && -z "$wpend" && -z "$wpip" && -z "$wout" && "$sf" != *[SIVsYQ]* ]] \
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
                continue
            fi
            scan_words=$(( scan_words + 1 ))
            if (( scan_words > SECRET_SCAN_WORD_BUDGET )); then
                hook_deny "$WORDS_MSG"
            fi
            _stage_end
            continue ;;
        ';')
            scan_words=$(( scan_words + 1 ))
            if (( scan_words > SECRET_SCAN_WORD_BUDGET )); then
                hook_deny "$WORDS_MSG"
            fi
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
            case "$op" in
                *'<<<')
                    if [[ "$sf" != *F* ]]; then sf+=F; fi
                    if [[ "$tgt" == *'$'* && "$tgt" =~ $secret_var_re ]]; then
                        msg="SECRET-ECHO BLOCK: a here-string of a secret-shaped variable ('$tgt') prints it into"
                        msg+=" context. Write it to \$CLAUDE_TEMP_DIR from a script instead."
                        hook_deny "$msg"
                    fi ;;
                *'<<'|*'<<-')
                    if [[ "$sf" != *F* ]]; then sf+=F; fi ;;
                *'<&') ;;
                *'<'|*'<>')
                    if [[ "$sf" != *F* ]]; then sf+=F; fi
                    # shellcheck disable=SC2053  # the alternations are intentional patterns
                    if [[ "/$tgt" == $_SECRET_PATH_ANY && "/$tgt" != $_SECRET_ALLOW_ANY ]] \
                            || { (( ${#tgt} <= 4096 )) && [[ "$tgt" == *[=:\*\?\[]* || "$tgt" == -[!-]?* ]] \
                                && _secret_variant "$tgt"; }; then
                        if [[ "$sf" != *S* ]]; then rds="<$tgt"; sf+=S; fi
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
    w="${el:1}"
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
    wsec=0
    # A word over 4096 characters (PATH_MAX on Linux) cannot be a path, so it gets only the whole-word test: the
    # variants' prefix removals are quadratic in the word's length.
    # shellcheck disable=SC2053  # the alternations are intentional patterns
    if [[ "/$w" == $_SECRET_PATH_ANY && "/$w" != $_SECRET_ALLOW_ANY && "$w" != --exclude=* \
            && "$w" != --exclude-dir=* ]]; then
        wsec=1
    elif (( ${#w} <= 4096 )) && [[ "$w" == *[=:\*\?\[]* || "$w" == -[!-]?* ]] && _secret_variant "$w"; then
        wsec=1
    fi
    # A wildcard-only last component (cat *, cat ~/.aws/*) is expanded where the command will run, and a pattern in a
    # directory part (cat */*) queues its directory for the stage end. The test that the word ends in a wildcard or
    # holds a pattern before a / keeps the function call off the glob-heavy hot path (cat a1* a2* …).
    if (( ! wsec )) && (( ${#w} <= 4096 )) && [[ "$w" == *[\*\?] || "$w" == *[\*\?\[\{]*/* ]]; then
        if [[ "$w" == */* ]]; then
            wc="${w%/*}"
            wc="${w:${#wc}+1}"
        else
            wc="$w"
        fi
        if [[ "$w" == *[\*\?\[\{]*/* || "$wc" != *[!\*\?]* ]] && _wild_word "$w"; then
            wsec=1
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
    if (( snp )) && [[ "$w" == *[\\\{]* ]]; then
        snp=0
    fi
    if (( wsec )) && [[ "$sf" != *S* ]]; then
        rds="$w"
        sf+=S
    fi
    if [[ "$w" == */* ]]; then
        nm="${w%/*}"
        nm="${w:${#nm}+1}"
    else
        nm="$w"
    fi
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
                if [[ "$act" == *r* ]]; then
                    _rr_settle
                fi
                act="${act//g/}f"
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
            _rr_word "$w"
        fi
        if [[ "$act" == *c* ]]; then
            _cd_word "$w"
        fi
        # A registry login's credential location, matched anywhere in the stage whatever the tool (no per-tool option
        # table), and compose's words once compose (or *-compose) is seen.
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
                elif (( dcm == 0 )) && [[ "$lgt" == docker || "$lgt" == podman || "$lgt" == nerdctl ]]; then
                    case "$w" in
                        compose) dcm=1 ;;
                        exec) _run_wrap "$lgt" ;;
                    esac
                fi
            fi
        fi
        # The words heroku run and heroku local:run join for a shell (one holding whitespace or shell syntax is a
        # command string), doppler run's options up to --, and heroku local's start command (run by sh -c).
        if [[ "$act" == *y* ]]; then
            if (( ryh )) && [[ "$w" == *[[:space:]\;\&\|\<\>\(\)\$\`\\\"\'\{\}\*\?\[]* ]]; then
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
        if [[ "$act" == *G* ]]; then
            # git -C DIR -C SUB runs in DIR/SUB; a --git-dir, --work-tree or -c core or submodule setting changes what
            # git grep reads.
            case "$gwp" in
                -C)
                    if [[ -n "$gcd" && "$w" != /* && "$w" != '~'* ]]; then gcd="$gcd/$w"; else gcd="$w"; fi ;;
                -c)
                    if [[ "$w" == [Cc][Oo][Rr][Ee].* || "$w" == [Ss][Uu][Bb][Mm][Oo][Dd][Uu][Ll][Ee].* ]]; then
                        gcore=1
                    fi ;;
                --git-dir|--work-tree) gwt=1 ;;
            esac
            case "$w" in
                --git-dir=*|--work-tree=*) gwt=1 ;;
            esac
            gwp="$w"
            git_walk_word "$w"
            if (( ! GW_ACTIVE )); then
                act="${act//G/}"
                if [[ "$npk" == git && -z "$npg" ]]; then
                    npg="$GW_SUB"
                fi
                if git_sub_reader "$GW_SUB"; then
                    if [[ "$sf" != *R* ]]; then
                        rdn="git $GW_SUB"
                        sf+=R
                    fi
                    if [[ "$sf" == *X* && "$sf" != *Y* ]]; then sf+=Y; fi
                fi
                case "$GW_SUB" in
                    grep) _rr_start 'git grep' ;;
                    diff) _rr_start 'git diff' ;;
                esac
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
                if [[ "$w" == *[csxv]* ]] || (( ${#w} > 64 )); then
                    _deny_shell "$shn $w"
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
                if ! _names_input "$w" fd; then
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
                    _deny_reader "$ipn $w"
                fi
            elif [[ "$w" != -* ]]; then
                if (( wsec )); then
                    _deny_reader "$ipn $w"
                fi
                # A vault env file's program must be a script a plain literal word names, with no other option, none
                # from a NODE_OPTIONS the command may set either: node must be the stage's first word (an assignment
                # or wrapper before it may set one under a name no text test reads), with no sourced file, set -a or
                # sequence separator, and no NODE_OPTIONS named. Anything else may run code that prints what node
                # loaded. The stage end checks nothing feeds it.
                if [[ -n "$kvf" ]]; then
                    if (( kon || cdsq || ! kfst )) || [[ -z "$w" || "$w" == *[\$\`\\\*\?\[\{]* ]] \
                            || _names_input "$w" fd \
                            || _cd_names NODE_OPTIONS || _k_env_sourced; then
                        _deny_reader "$ipn $kvf ... $w"
                    fi
                    kvp="$kvf"
                fi
                if ! _names_input "$w" fd; then
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
                        _deny_reader "$ipn $w"
                    fi
                fi
                if (( ! kvw )); then
                    kon=1
                fi
                if _k_inline "$w"; then
                    if [[ -n "$kvf" ]]; then
                        _deny_reader "$ipn $kvf ... $w"
                    fi
                    act="${act//K/}L"
                    if [[ "$sf" == *X* && "$sf" != *Y* ]]; then
                        if [[ "$sf" != *R* ]]; then rdn="$ipn"; fi
                        sf+=Y
                    fi
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
            _deny_reader "$ipn ... $w"
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
            elif [[ "$w" == *[\{\}]* ]]; then
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
                    if [[ "$w" == *'{'* ]]; then
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
            if [[ "$w" == *[[:space:]\;\&\|\<\>\(\)\$\`\\\"\'\{\}\*\?\[]* || "$w" == =* \
                    || "$w" == *[cC][oO][mM][mM][aA][nN][dD]=* ]]; then
                _deny_shell "$smn '$w'"
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
            _np_start
        fi
    elif [[ "$sf" == *A* ]]; then
        atcmd=1
        hok=$pwrap
    fi
    kn=""
    kc=""
    if [[ "$nm" != *[!a-z0-9]* ]]; then
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
    if [[ "$kc" == h ]] && (( ! hok )); then
        kc=""
    fi
    np=0
    if (( atcmd )); then
        if (( pwrap )); then
            case "$pwk" in
                command|builtin) if [[ "$w" == -* ]]; then np=1; fi ;;
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
                    shq=0
                fi ;;
        esac
    fi
    if [[ -n "$kn" ]]; then
        case "$kn" in
            R|J|W)
                if [[ "$sf" != *R* ]]; then rdn="$nm"; sf+=R; fi
                if [[ "$sf" == *X* && "$sf" != *Y* ]]; then sf+=Y; fi
                if [[ "$act" == *g* ]]; then fxr=1; fi
                nrd=$(( nrd + 1 ))
                case "$nm" in
                    grep|egrep|fgrep|ggrep|ugrep|ug|rg|diff) _rr_start "$nm" ;;
                esac
                if [[ "$kn" != R && "$act" != *"$kn"* ]]; then act+=$kn; fi ;;
            G)
                if [[ "$act" != *G* ]]; then act+=G; fi
                gcd=""
                gwp=""
                gwt=0
                gcore=0
                git_walk_start ;;
            H)
                if [[ "$act" != *H* ]]; then act+=H; fi
                shn="$nm"
                shv=""
                shq=$atcmd ;;
            K)
                act="${act//L/}"
                if [[ "$act" != *K* ]]; then act+=K; fi
                kpv=0
                kvf=""
                kon=0
                kfst=0
                if (( nw == 1 )); then kfst=1; fi
                ipn="$nm" ;;
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
                sun="$nm" ;;
            S)
                if (( si == 0 )); then sgs=1; fi ;;
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
                    if [[ "$nm" == *-compose ]]; then dcm=1; fi
                fi ;;
        esac
    fi
    # shellcheck disable=SC2053  # secret_var_glob is an intentional pattern
    if [[ "$w" == *'$'* && "$sf" != *V* && "$w" == $secret_var_glob && "$w" =~ $secret_var_re ]]; then
        vrw="$w"
        sf+=V
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
_stage_end

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
