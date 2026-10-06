#!/usr/bin/env bash
# secret-bash-guard.sh — PreToolUse hook for Bash. Denies a command that would print a secret into context: a reader
# given a secret-bearing file, a dump of the environment or of a secret-named variable, a secret fetch that does not go
# into the vault ($CLAUDE_SECRET_DIR), a copy out of a secret path, or a shell given a command string this hook cannot
# see into. bash-guard.sh denies every compound form except a pipeline, so this hook tokenises the command
# (shell_words) and screens every word of every stage. Hooks run in parallel; deny wins. A script may still use a
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
# A secret-named variable: one whose name holds a word below, or any ${!…} indirection. secret_var_glob is a cheap
# necessary condition for secret_var_re (bash compiles a regex on every [[ =~ ]]), derived from the same words.
secret_name_re=""
secret_var_glob='*${!*'
for n in SECRET TOKEN PASSWORD PASSWD CREDENTIAL PRIVATE_KEY API_KEY ACCESS_KEY; do
    secret_name_re+="${secret_name_re:+|}$n"
    secret_var_glob+="|*$n*"
done
secret_name_re="($secret_name_re)"
secret_var_re='\$\{?[A-Za-z_]*'"${secret_name_re}"'|\$\{!'
secret_var_glob="@($secret_var_glob)"

# 1. Secret fetches, matched on the raw command with the commit-message heredoc removed (a message may name a fetch),
# and, when it holds a quote or backslash, on a copy with those removed too: they can split a form's words without
# changing what runs. kubectl get prints secrets when a resource that is or lists secrets and -o come in either
# order; [^|;&]* keeps the match inside one pipeline stage.
kube_get='kubectl[[:space:]]([^|;&]*[[:space:]])?get[[:space:]]([^|;&]*[[:space:]])?'
kube_res='([^[:space:]|;&]*,)?[Ss][Ee][Cc][Rr][Ee][Tt][Ss]?([.,/][^[:space:]|;&]*)?'
kube_out='(-o|--output|--template)[^[:space:]]*'
kube_mid='[[:space:]]([^|;&]*[[:space:]])?'
# aws takes its global options between the service and the operation; [^|;&]* keeps them inside one pipeline stage.
# configure, a word of ordinary prose, allows only option-shaped words there: any run of options, each with at most one
# value.
aws_gap='[[:space:]]([^|;&]*[[:space:]])?'
aws_opts='([[:space:]]+-[^[:space:]|;&]*([[:space:]]+[^-[:space:]|;&][^[:space:]|;&]*)?)*[[:space:]]+'
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
    'kubectl[[:space:]](.*[[:space:]])?config[[:space:]]+view[[:space:]](.*[[:space:]])?--raw'
    'kubectl[[:space:]](.*[[:space:]])?create[[:space:]]+token'
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
fetch_hit=0
fetch_dequoted=""
fetch_checked=$(strip_commit_heredoc "$cmd")
# A commit-message heredoc the strip left whole (the words before -m are not plain, or the message would end the
# substitution early under bash 3.2) is denied here, as bash-guard denies it: tokenising its quotes could desync.
if [[ "$fetch_checked" == "$cmd" && "$cmd" == *$'-m "$(cat <<\'EOF\'\n'* ]]; then
    hook_deny "$HEREDOC_MSG"
fi
if [[ "$fetch_checked" =~ $fetch_re ]]; then
    fetch_hit=1
elif [[ "$fetch_checked" == *[\"\'\\]* ]]; then
    fetch_dequoted=$(printf '%s' "$fetch_checked" | LC_ALL=C tr -d "\"'\\\\") || fetch_dequoted=""
    if [[ "$fetch_dequoted" =~ $fetch_re ]]; then
        fetch_hit=1
    fi
fi
if (( fetch_hit )); then
    # No allowed shape is possible without the vault or a --password-stdin login, so deny without tokenising.
    fetch_marked=0
    for fetch_text in "$fetch_checked" "$fetch_dequoted"; do
        if [[ "$fetch_text" == *CLAUDE_SECRET_DIR* || "$fetch_text" == *-vault/secrets/* \
                || "$fetch_text" == *--password-stdin* ]]; then
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
# X xargs, Q parallel, N watch, O ps, U su/script/flock, S security, L a registry login command. Command position: A
# wrapper (every later word is at command position too), E env, e export, s set, v eval, Z a single-word fetch tool,
# f find (-exec starts a wrapper), k kubectl, d gpg and age, h source and the . builtin (a shell reading a script), b
# { or repeat (a zsh group or loop: denied), M ssh (a wrapper whose later words a remote shell parses again).
# Every name also goes into plain_names, so shell_words never marks it plain, as do the words the fetch shapes read in
# the first stage.
word_classes=(
    'nm R cat less more head tail xxd hexdump strings od nl tac bat grep egrep fgrep rg sed yq base64 base32 sort'
    'nm R uniq cut paste diff cmp comm join fold rev tr column pr fmt expand unexpand iconv look dd openssl tar zip'
    'nm R gzip bzip2 xz zstd zcat'
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
    'nm L docker podman helm oras'
    'cp A sudo doas nice nohup time timeout command builtin exec noglob nocorrect xargs stdbuf ionice caffeinate'
    'cp A chronic flock unbuffer setsid direnv parallel'
    'cp b repeat'
    'cp E env'
    'cp e export'
    'cp s set'
    'cp v eval'
    'cp Z op vault bw rbw'
    'cp f find'
    'cp k kubectl'
    'cp d gpg age'
    'cp h source'
    'cp M ssh slogin'
)
plain_names='! . { -- --debug --v --log-http --verbosity debug'
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

# _no_program <word>: 0 if a shell or interpreter given <word> reads its own input or a special file rather than a
# program: anything under /dev/ or /proc/ in any spelling of the leading slashes (fail closed, no list of names).
_no_program() {
    local re='^/+(\./+)*(dev|proc)/'
    [[ "$1" =~ $re ]]
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

# Per-stage state. sf holds one letter per fact the stage-end checks read (R reader, S secret word, I secret input
# redirection, T tee or xargs, X xargs or parallel, Y a reader after xargs, P a printer, V a secret-named variable,
# F fed by an input redirection, A every word at command position, s a set at command position); act holds one letter
# per word walk still running (E env options, G git subcommand, H shell program, K interpreter program, L interpreter
# inline code, C copier operands, D dump operands, O ps bundle, o ps options, J jq, W awk, U su/script/flock, N
# watch/parallel, Z a single-word fetch tool's subcommand, x an xargs -a value, f find up to its -exec, g find's
# executed command, d gpg or age, whose decrypt flag (dcf) makes the stage a fetch, k kubectl, whose get, secret
# resource and output flag (kg, ks, ko) make the stage a fetch). Each
# letter is added at most once, so neither string grows with the command. A value beside a letter is read only while
# the letter is set, so a stage resets in a few assignments.
sf=""
act=""
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

# _stage_end: run the stage-end checks, record the fetch facts of a pipeline's first two stages, reset the stage.
_stage_end() {
    local msg
    if (( nw == 0 && nr == 0 )); then
        return 0
    fi
    if [[ -n "$act" ]]; then
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
        if [[ "$act" == *k* ]] && (( kg && ks && ko )); then
            fetch_hit=1
        fi
        if [[ "$act" == *d* ]] && (( dcf )); then
            fetch_hit=1
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
    GW_ACTIVE=0
}

for el in ${SW_WORDS[@]+"${SW_WORDS[@]}"}; do
    case "$el" in
        w*) ;;
        p*)
            # A plain word changes nothing but the word count and command position, unless a word walk needs it, or
            # the fetch shapes do: they read every word of a fetch's second stage (the login).
            if [[ -z "$act" ]] && (( si != 1 || ! ( fetch_hit || swf_stage >= 0 ) )); then
                nw=$(( nw + 1 ))
                cs=1
                pwrap=0
                continue
            fi ;;
        '|')
            # With no walk running and none of the facts a stage-end check reads (S, I, V, s, Y), a stage ends with
            # nothing to check, or to record for a fetch.
            if [[ -z "$act" && "$sf" != *[SIVsY]* ]] && (( si > 1 || ! ( fetch_hit || swf_stage >= 0 ) )); then
                si=$(( si + 1 ))
                sf=""
                nw=0
                nr=0
                cs=0
                pwrap=0
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
            si=0
            pipe_sec=""
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
                    else
                        # The vault: $CLAUDE_SECRET_DIR, or its literal path with no / in the session segment.
                        vt=0
                        if [[ "$tgt" == '$CLAUDE_SECRET_DIR/'?* || "$tgt" == '${CLAUDE_SECRET_DIR}/'?* ]]; then
                            vt=1
                        elif [[ "$tgt" == /tmp/claude-*-vault/secrets/?* ]]; then
                            vm="${tgt#/tmp/claude-}"
                            vm="${vm%%-vault/secrets/*}"
                            if [[ "$vm" != */* ]]; then vt=1; fi
                        fi
                        if (( vt )) && [[ "/$tgt/" != */../* ]]; then fd1v=1; fi
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
        # has its operands, and the words after it are no longer at command position (unless an earlier wrapper put
        # them there). Any other + is an argument of the command, except that env still running takes it for a command
        # it cannot account for and is denied as having none.
        if [[ "$act" == *g* ]]; then
            fxe=0
            if [[ "$w" == ';' ]] || { [[ "$w" == '+' ]] && [[ "$fxp" == '{}' ]]; }; then
                fxe=1
            elif [[ "$w" == '+' && "$act" == *E* ]]; then
                hook_deny "$ENV_NONE_MSG"
            fi
            fxp="$w"
            if (( fxe )); then
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
                    -u|-C|-P|--unset|--chdir) ewo=1; ews=1 ;;
                    -i|-0|-v) ewo=1 ;;
                    --split-string|--split-string=*) hook_deny "$S_MSG" ;;
                    -|--|--ignore-environment|--null|--debug|--unset=*|--chdir=*) ewo=1 ;;
                    -*)
                        if [[ "$w" =~ ^-[0iv]*([uCPS])(.*)$ ]]; then
                            ewo=1
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
            git_walk_word "$w"
            if (( ! GW_ACTIVE )); then
                act="${act//G/}"
                if git_sub_reader "$GW_SUB"; then
                    if [[ "$sf" != *R* ]]; then
                        rdn="git $GW_SUB"
                        sf+=R
                    fi
                    if [[ "$sf" == *X* && "$sf" != *Y* ]]; then sf+=Y; fi
                fi
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
                # The program: a shell reading a secret file as its script prints it in its errors. A path under /dev/
                # or /proc/ (/dev/stdin, /dev/fd/0) is the shell's own input, not a program, so a shell given one stays
                # unresolved (a fed one is denied at stage end). Every program word is still read: one that names
                # a secret is a reader deny either way.
                if (( wsec )); then
                    _deny_reader "$shn $w"
                fi
                if ! _no_program "$w"; then
                    act="${act//H/}"
                fi
            fi
        fi
        if [[ "$act" == *K* ]]; then
            if [[ "$w" == -[!-]* ]]; then
                if [[ "$w" == *[eEpncrm]* ]]; then
                    act="${act//K/}L"
                    if [[ "$sf" == *X* && "$sf" != *Y* ]]; then
                        if [[ "$sf" != *R* ]]; then rdn="$ipn"; fi
                        sf+=Y
                    fi
                fi
            elif [[ "$w" != -* ]]; then
                if (( wsec )); then
                    _deny_reader "$ipn $w"
                fi
                if ! _no_program "$w"; then
                    act="${act//K/}"
                fi
            fi
        elif [[ "$act" == *L* && "$w" != -* ]] && (( wsec )); then
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
                else
                    wpc=1
                fi
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
            if (( smc )); then
                :
            elif (( smo )); then
                smo=0
            elif [[ "$w" == -?* ]]; then
                # A value-taking letter takes the rest of its bundle, or the next word when it ends the bundle.
                smx="${w#-}"
                while [[ -n "$smx" ]]; do
                    if [[ "${smx:0:1}" != [46AaCfGgKkMNnqsTtVvXxYy] ]]; then
                        if (( ${#smx} == 1 )); then smo=1; fi
                        break
                    fi
                    smx="${smx:1}"
                done
            elif (( smh )); then
                smc=1
            else
                smh=1
            fi
        fi
        if [[ "$act" == *x* ]]; then
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
            case "$w" in
                -exec|-execdir|-ok|-okdir)
                    act="${act//f/}g"
                    fxa=0
                    fxp=""
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
            case "$w" in
                get)
                    kg=1 ;;
                -o|-o?*|--output|--output=*|--template|--template=*)
                    ko=1 ;;
                *[Ss][Ee][Cc][Rr][Ee][Tt]*)
                    if (( kg )) && [[ "$w" =~ ^(.*,)?[Ss][Ee][Cc][Rr][Ee][Tt][Ss]?([.,/].*)?$ ]]; then ks=1; fi ;;
            esac
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
                if [[ "$act" != *f* ]]; then act+=f; fi ;;
            k)
                if [[ "$act" != *k* ]]; then
                    act+=k
                    kg=0
                    ks=0
                    ko=0
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
                if [[ "$kn" != R && "$act" != *"$kn"* ]]; then act+=$kn; fi ;;
            G)
                if [[ "$act" != *G* ]]; then act+=G; fi
                git_walk_start ;;
            H)
                if [[ "$act" != *H* ]]; then act+=H; fi
                shn="$nm"
                shv=""
                shq=$atcmd ;;
            K)
                act="${act//L/}"
                if [[ "$act" != *K* ]]; then act+=K; fi
                ipn="$nm" ;;
            C|Ct)
                if [[ "$act" != *C* ]]; then act+=C; fi
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
                xan=0 ;;
            Q)
                if [[ "$sf" != *X* ]]; then sf+=X; fi
                if [[ "$act" != *N* ]]; then act+=N; fi
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
        esac
    fi
    # shellcheck disable=SC2053  # secret_var_glob is an intentional pattern
    if [[ "$w" == *'$'* && "$sf" != *V* && "$w" == $secret_var_glob && "$w" =~ $secret_var_re ]]; then
        vrw="$w"
        sf+=V
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

hook_pass
