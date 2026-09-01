#!/usr/bin/env bash
# The three app-surface files OOD renders or parses that no other suite touches:
#
#   view.html.erb  the session card's Connect control, rendered with the live
#                  connection details as bare locals
#   info.md.erb    the card's body text
#   manifest.yml   how OOD discovers and registers the app at all
#
# ood/codeserver-ai/view.html.erb is the one with real Ruby in it -- a require,
# a SHA-256, and a JS template literal -- and a syntax error there breaks the
# session card for every student with a running job, silently, until someone
# with a session complains.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh

# The plaintext the card posts. Long enough that the leak assertions below
# cannot match by accident against hex or a path.
VIEW_PASSWORD='view-plaintext-secret-9f3a'
VIEW_HOST='holy7c12345.rc.fas.harvard.edu'
VIEW_PORT='7123'

# The cookie code-server needs, computed here independently of the template.
# Asserting the DIGEST rather than the presence of the word "key" is the whole
# point: a template that wrote the cookie with the plaintext, or with the wrong
# input, would still contain "key=".
EXPECTED_KEY=$(printf '%s' "$VIEW_PASSWORD" | sha256sum | awk '{print $1}')

render_view() {  # <app dir name>
    FAKE_VIEW_HOST="$VIEW_HOST" FAKE_VIEW_PORT="$VIEW_PORT" \
    FAKE_VIEW_PASSWORD="$VIEW_PASSWORD" \
        ruby render.rb --view "../ood/$1/view.html.erb" 2>&1
}

manifest_field() {  # <app dir name> <top-level key>
    ruby -ryaml -e \
        'print(YAML.safe_load(File.read(ARGV[0]))[ARGV[1]].to_s)' \
        "../ood/$1/manifest.yml" "$2" 2>&1
}

# shellcheck source=scripts/lib/app-dirs.sh
. ../scripts/lib/app-dirs.sh
apps=$(ood_app_dirs) || { it "app discovery"; _fail "ood_app_dirs failed"; finish; exit 1; }

for app in $apps; do
    it "$app: view.html.erb renders without raising"
    # The consequence, not the output: an ERB or Ruby error here is a broken
    # Connect button on a live session card.
    assert_success ruby render.rb --view "../ood/$app/view.html.erb"

    it "$app: manifest.yml parses as YAML"
    assert_success ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]))' "../ood/$app/manifest.yml"

    it "$app: manifest.yml declares role: batch_connect"
    # Parsed, not grepped: OOD reads this key to decide the app is an
    # interactive app at all, and a role in a comment or nested one level too
    # deep would still satisfy a substring check.
    assert_eq "$(manifest_field "$app" role)" "batch_connect"

    it "$app: manifest.yml declares a category, so the app is reachable in the dashboard"
    assert_eq "$(manifest_field "$app" category)" "Interactive Apps"

    it "$app: info.md.erb renders without raising"
    assert_success ruby render.rb --view "../ood/$app/info.md.erb"

    it "$app: info.md.erb is not empty"
    # A card whose body renders to nothing looks like a broken session.
    info=$(ruby render.rb --view "../ood/$app/info.md.erb" 2>&1)
    assert_eq "$([ ${#info} -gt 100 ] && echo long || echo short)" "long"
done

it "jupyterlab: manifest name is the one render-forms.sh validates sub-app titles against"
# scripts/render-forms.sh reads this value to check every sub-app title, so it
# is load-bearing beyond the dashboard listing.
assert_eq "$(manifest_field jupyterlab-ai name)" "Jupyter Lab"

it "codeserver: manifest name is the one render-forms.sh validates sub-app titles against"
assert_eq "$(manifest_field codeserver-ai name)" "Code Server"

# --- JupyterLab's card: the plain node proxy.
JL_VIEW=$(render_view jupyterlab-ai)

it "jupyterlab: the Connect form posts through the /node/ proxy path"
assert_contains "$JL_VIEW" "action=\"/node/${VIEW_HOST}/${VIEW_PORT}/login\""

it "jupyterlab: it does NOT use the /rnode/ raw-proxy path, which is code-server's"
# The two apps' proxy paths are not interchangeable: /node/ rewrites the
# response body, /rnode/ does not. Swapping them yields a card that connects to
# nothing.
assert_not_contains "$JL_VIEW" "/rnode/"

it "jupyterlab: the form carries the password JupyterLab's login endpoint expects"
assert_contains "$JL_VIEW" "value=\"${VIEW_PASSWORD}\""

it "jupyterlab: the card sets no cookie -- only code-server needs one"
assert_not_contains "$JL_VIEW" "document.cookie"

# --- code-server's card: the raw proxy, plus the cookie its login flow needs.
CS_VIEW=$(render_view codeserver-ai)

it "codeserver: the Connect form posts through the /rnode/ raw-proxy path"
assert_contains "$CS_VIEW" "action=\"/rnode/${VIEW_HOST}/${VIEW_PORT}/login?to=\""

it "codeserver: it does NOT use the /node/ rewriting-proxy path, which is JupyterLab's"
# Not a check for the absence of "/node/": that substring is inside "/rnode/".
# The form action is where the difference is real.
assert_not_contains "$CS_VIEW" "action=\"/node/"

it "codeserver: the card sets the 'key' cookie code-server hardcodes upstream"
# Without this cookie the session bounces straight back to the login page,
# which reads to a student as "the password does not work".
assert_contains "$CS_VIEW" "key=${EXPECTED_KEY}"

it "codeserver: the cookie holds the SHA-256 of the password, not the password"
assert_not_contains "$CS_VIEW" "key=${VIEW_PASSWORD}"

it "codeserver: the cookie is scoped to this session's own proxy path, not to /"
# A cookie at path=/ would be sent to every other app on the portal, and
# overwritten by the next code-server session the student opens.
assert_contains "$CS_VIEW" "\"path=/rnode/\" + \"${VIEW_HOST}\" + \"/\" + \"${VIEW_PORT}/\""

it "codeserver: the cookie is marked secure"
assert_contains "$CS_VIEW" ";secure"

it "codeserver: the form still carries the password its login endpoint expects"
assert_contains "$CS_VIEW" "value=\"${VIEW_PASSWORD}\""

finish
