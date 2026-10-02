# shellcheck shell=bash
# shellcheck disable=SC2034  # read by guard-lib.sh and the hooks that source it
# Pattern sets and path exemptions for .githooks/pre-commit and .githooks/pre-push, sourced by .githooks/guard-lib.sh.
# Each pattern is a POSIX ERE, matched case-insensitively against each added line. .gitleaks.toml carries the same
# patterns; tests/test-pattern-sync.sh checks that the two stay in step.
#
# Replace the IDENTITY_PATTERNS placeholders with your organisation's markers, or keep them and put your markers in
# the optional, gitignored .githooks/identity-patterns.local instead, one ERE per line. The second way screens a
# public fork for names it must not publish without publishing the list. Secret-shaped literals of your own, such as
# account IDs, go in .githooks/always-patterns.local the same way.

# Secret-shaped values: they bite on every path.
ALWAYS_PATTERNS=(
    # A 12-digit number within 24 characters of the word "account", on either side, and an ARN carrying one
    'account[^0-9]{0,24}[0-9]{12}([^0-9]|$)'
    '(^|[^0-9])[0-9]{12}[^0-9]{1,24}account'
    'arn:aws[a-z-]*:[^:]*:[^:]*:[0-9]{12}:'

    # ECR registry hostnames
    '[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com'

    # Bedrock application inference profile IDs
    'application-inference-profile/[a-z0-9]{10,16}'

    # SSH private key markers
    '-----BEGIN.*PRIVATE KEY-----'

    # Tokens / PATs
    'YOUR_NUGET_PAT'
)

# Organisation and personal identity markers: placeholders to replace with your own.
IDENTITY_PATTERNS=(
    # SSO portal
    'yourorg\.awsapps\.com'

    # Active Directory
    'DC=your-domain'

    # Organisation
    'YourOrgEngineering'
    'yourorg'
    'your-company\.com'
    'your-stage\.com'
    'your-dev-server'
    'your-prod-server'
    'yourorgltd'
    'internal-project-1'
    'internal-project-2'
    'internal-project-3'
    'internal-project-4'
    'internal-project-5'

    # Personal
    'YourGitHubUser'
    '@your-company\.com'
    '@your-email\.co\.uk'
    'your\.name'
    '/Users/yourusername/'
)

# Paths exempt from IDENTITY_PATTERNS: Claude Code's per-project memory, which names real organisations and
# repositories by design. .gitignore keeps it out of git, so the exemption applies only once a private repository
# opts in there; a public one must not. Secret-shaped values still bite there.
IDENTITY_EXEMPT_RE='^projects/[^/]+/memory/'

# Paths exempt from identity-patterns.local: the same memory directories.
LOCAL_IDENTITY_EXEMPT_RE="$IDENTITY_EXEMPT_RE"

# Patterns of identity-patterns.local this repository disregards on every path, for a marker that is its own public
# identity. Each entry is the exact text of one line of that list; an entry that matches no line drops nothing, so a
# changed pattern bites again. always-patterns.local and the tracked patterns cannot be opted out of. None here.
LOCAL_IDENTITY_IGNORE=()

# Paths the built-ins pass skips: the secret firewall's pattern library, its tests' dummy vectors and its design doc,
# which necessarily match gitleaks' built-in rules and which .gitleaks.toml exempts from every rule. None holds a real
# credential. Each is named exactly, so a new file gets no exemption until it is added here, and to .gitleaks.toml, in
# a reviewed commit; do the same to clear a built-in false positive. An empty value, or one that never matches such as
# '^$.', exempts nothing.
BUILTINS_EXEMPT_RE='^hooks/secret-patterns\.sh$|^hooks/secret-patterns\.test\.sh$'
BUILTINS_EXEMPT_RE+='|^hooks/secret-bash-guard\.test\.sh$|^hooks/secret-breach-alarm\.test\.sh$'
BUILTINS_EXEMPT_RE+='|^hooks/secret-output-scrubber\.test\.sh$|^hooks/secret-path-guard\.test\.sh$'
BUILTINS_EXEMPT_RE+='|^hooks/secret-prompt-guard\.test\.sh$'
BUILTINS_EXEMPT_RE+='|^docs/superpowers/specs/2026-07-12-secret-context-firewall-design\.md$'

# Paths exempt from ALWAYS_PATTERNS: the same secret-firewall files, whose dummy vectors are secret-shaped by design.
# always-patterns.local and the identity patterns still apply there.
ALWAYS_EXEMPT_RE="$BUILTINS_EXEMPT_RE"
