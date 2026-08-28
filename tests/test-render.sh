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

it "submit mode provides blank?, which OOD's siblings all rely on"
cat > /tmp/tpl-blank.erb <<'ERB'
blank=<%= bc_queue.blank? %>
ERB
out=$(FAKE_GROUPS='canvas170681-999' ruby render.rb --submit /tmp/tpl-blank.erb --form "$SUB")
assert_contains "$out" "blank=false"

it "submit mode rejects a local that no sub-app defines"
# Same failure mode the template context already guards: a typo must be loud,
# not an empty string that becomes a malformed Slurm argument.
cat > /tmp/tpl-typo.erb <<'ERB'
oops=<%= custom_num_core %>
ERB
out=$(FAKE_GROUPS='canvas170681-999' ruby render.rb --submit /tmp/tpl-typo.erb --form "$SUB" 2>&1)
assert_contains "$out" "custom_num_core"

it "submit mode rejects an attribute set but not listed under form:"
cat > /tmp/tpl-unlisted.erb <<'ERB'
oops=<%= unlisted_attr %>
ERB
out=$(FAKE_GROUPS='canvas170681-999' ruby render.rb --submit /tmp/tpl-unlisted.erb --form "$SUB" 2>&1)
assert_contains "$out" "unlisted_attr"

rm -f /tmp/tpl-submit.erb /tmp/tpl-blank.erb /tmp/tpl-typo.erb /tmp/tpl-unlisted.erb
finish
