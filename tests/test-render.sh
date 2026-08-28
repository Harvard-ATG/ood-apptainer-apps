#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/assert.sh
. lib/assert.sh

SUB=fixtures/sample-subapp.yml.erb

render_form() { FAKE_GROUPS="$1" ruby render.rb --form "$SUB"; }

it "enrolled student gets cluster '*'"
assert_contains "$(render_form 'canvas170681-999,students')" '"cluster":"*"'

it "admin gets cluster '*'"
assert_contains "$(render_form 'ondemand-admins-1025174')" '"cluster":"*"'

it "unrelated student is denied"
assert_contains "$(render_form 'canvas999999-1,students')" '"cluster":"disable_this_app"'

it "user with no groups is denied"
assert_contains "$(render_form '')" '"cluster":"disable_this_app"'

it "title and cacheable survive parsing"
out=$(render_form 'canvas170681-999')
assert_contains "$out" '"title":"Jupyter Lab - COMPSCI 1090A"'

it "cacheable is false"
assert_contains "$(render_form 'canvas170681-999')" '"cacheable":false'

it "a form-listed attribute reaches context"
cat > /tmp/tpl-ok.erb <<'ERB'
image=<%= context.imagefile %>
ERB
out=$(FAKE_GROUPS='canvas170681-999' ruby render.rb --template /tmp/tpl-ok.erb --form "$SUB")
assert_contains "$out" "image=jupyter-codeserver-ai/jupyterlab-20260827T000000Z-abc1234.sif"

it "an attribute missing from form: is rejected, not silently empty"
cat > /tmp/tpl-bad.erb <<'ERB'
oops=<%= context.unlisted_attr %>
ERB
out=$(FAKE_GROUPS='canvas170681-999' ruby render.rb --template /tmp/tpl-bad.erb --form "$SUB" 2>&1)
assert_contains "$out" "not listed under form:"

it "respond_to? is false for an attribute missing from form:"
cat > /tmp/tpl-resp.erb <<'ERB'
has=<%= context.respond_to?('unlisted_attr') %>
ERB
out=$(FAKE_GROUPS='canvas170681-999' ruby render.rb --template /tmp/tpl-resp.erb --form "$SUB")
assert_contains "$out" "has=false"

it "session.staged_root is available to templates"
cat > /tmp/tpl-sess.erb <<'ERB'
root=<%= session.staged_root %>
ERB
out=$(FAKE_STAGED_ROOT=/tmp/staged FAKE_GROUPS='canvas170681-999' \
      ruby render.rb --template /tmp/tpl-sess.erb --form "$SUB")
assert_contains "$out" "root=/tmp/staged"

rm -f /tmp/tpl-ok.erb /tmp/tpl-bad.erb /tmp/tpl-resp.erb /tmp/tpl-sess.erb

it "submit mode exposes form attributes as bare locals"
cat > /tmp/tpl-submit.erb <<'ERB'
cores=<%= custom_num_cores %> hours=<%= bc_num_hours %> mem=<%= mem_per_cpu %>
ERB
out=$(FAKE_GROUPS='canvas170681-999' ruby render.rb --submit /tmp/tpl-submit.erb --form "$SUB")
assert_contains "$out" "cores=1 hours=2 mem=4G"

it "submit mode takes the value: of a widget attribute, not the widget hash"
assert_not_contains "$out" "number_field"

it "submit mode's blank? matches ActiveSupport for empty, whitespace-only, nil, and present strings"
# ActiveSupport treats a whitespace-only string as blank, not merely a
# zero-length one -- a field a user leaves as spaces is an ordinary OOD form
# scenario, so all four cases are covered here rather than just "present".
cat > /tmp/tpl-blank.erb <<'ERB'
empty=<%= ''.blank? %> whitespace=<%= '  '.blank? %> missing=<%= nil.blank? %> present=<%= bc_queue.blank? %>
ERB
out=$(FAKE_GROUPS='canvas170681-999' ruby render.rb --submit /tmp/tpl-blank.erb --form "$SUB")
assert_contains "$out" "empty=true whitespace=true missing=true present=false"

it "submit mode rejects a local that no sub-app defines"
# Same failure mode the template context already guards: a typo must be loud,
# not an empty string that becomes a malformed Slurm argument. A bare
# substring check on the identifier is defeatable: a handler that rescues the
# NameError and logs "known attributes: ..., custom_num_cores, ..." would
# still match "custom_num_core" as a substring while silently rendering the
# bug. Assert the render actually failed AND that it never produced the
# rendered line at all.
cat > /tmp/tpl-typo.erb <<'ERB'
oops=<%= custom_num_core %>
ERB
FAKE_GROUPS='canvas170681-999' assert_failure ruby render.rb --submit /tmp/tpl-typo.erb --form "$SUB"

it "submit mode's typo rejection names the identifier and renders nothing"
out=$(FAKE_GROUPS='canvas170681-999' ruby render.rb --submit /tmp/tpl-typo.erb --form "$SUB" 2>&1)
assert_contains "$out" "custom_num_core"
assert_not_contains "$out" "oops="

it "submit mode rejects an attribute set but not listed under form:"
# Same scrutiny as the typo case above: exit status and absence of the
# rendered line, not just a substring of the diagnostic.
cat > /tmp/tpl-unlisted.erb <<'ERB'
oops=<%= unlisted_attr %>
ERB
FAKE_GROUPS='canvas170681-999' assert_failure ruby render.rb --submit /tmp/tpl-unlisted.erb --form "$SUB"

it "submit mode's unlisted-attribute rejection names the identifier and renders nothing"
out=$(FAKE_GROUPS='canvas170681-999' ruby render.rb --submit /tmp/tpl-unlisted.erb --form "$SUB" 2>&1)
assert_contains "$out" "unlisted_attr"
assert_not_contains "$out" "oops="

rm -f /tmp/tpl-submit.erb /tmp/tpl-blank.erb /tmp/tpl-typo.erb /tmp/tpl-unlisted.erb
finish
