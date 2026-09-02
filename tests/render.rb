#!/usr/bin/env ruby
# ERB render harness standing in for OOD's template binding.
#
# Reproduces the three OOD-supplied objects our templates use:
#   OodSupport::User  - group membership, driven by FAKE_GROUPS
#   session           - staged_root, driven by FAKE_STAGED_ROOT
#   context           - form attributes, built ONLY from the sub-app's form:
#                       list, because that is what OOD actually passes through
require 'erb'
require 'yaml'
require 'json'

# OOD hands a template the value a user SUBMITTED, never the widget
# declaration. An attribute written as a widget hash therefore arrives as a
# plain string: its value: entry, or -- for a select that declares no value: --
# the first option, which is what the form pre-selects. An option is either a
# bare string (label and value are the same) or a [label, value, ...] array.
#
# Without this, a template reading an attribute declared as a widget renders
# the Ruby Hash itself into the launch script, and nothing errors.
def submitted_value(raw)
  return raw unless raw.is_a?(Hash)
  return raw['value'] if raw.key?('value')

  first = (raw['options'] || []).first
  first.is_a?(Array) ? first[1] : first
end

module OodSupport
  Group = Struct.new(:id, :name)

  class User
    def groups
      (ENV['FAKE_GROUPS'] || '').split(',').reject(&:empty?)
        .each_with_index.map { |name, i| Group.new(1000 + i, name) }
    end
  end
end

class Session
  def staged_root
    require 'pathname'
    Pathname.new(ENV.fetch('FAKE_STAGED_ROOT', '/tmp/staged-root'))
  end
end

# Mimics OOD's binding: only form:-listed attributes exist. Anything else
# raises loudly rather than rendering as empty, which is how this class of bug
# reaches production unnoticed.
class FormContext
  def initialize(attributes, form)
    @values = {}
    form.each { |k| @values[k.to_s] = submitted_value(attributes[k.to_s]) }
    @declared_but_unlisted = attributes.keys.map(&:to_s) - @values.keys
  end

  def respond_to?(name, include_all = false)
    @values.key?(name.to_s) || super
  end

  def respond_to_missing?(name, include_all = false)
    @values.key?(name.to_s) || super
  end

  def method_missing(name, *args)
    key = name.to_s
    return @values[key] if @values.key?(key)

    if @declared_but_unlisted.include?(key)
      warn "ERROR: template uses context.#{key}, which is set under " \
           "attributes: but is not listed under form:. OOD passes only " \
           "form:-listed attributes into the template context, so this " \
           "silently renders as nothing in production."
      exit 2
    end
    warn "ERROR: template uses context.#{key}, which no sub-app defines."
    exit 2
  end
end

# ActiveSupport's blank?, which the dashboard provides and every sibling
# submit.yml.erb uses. Reproduced rather than depended on, so this harness needs
# no gems beyond the standard library.
class Object
  def blank?
    respond_to?(:empty?) ? !!empty? : !self
  end
end

class NilClass
  def blank?
    true
  end
end

# ActiveSupport's String#blank? checks for whitespace-only content, not merely
# zero length -- Object#empty? alone would call "  " (a realistic OOD form
# value: a field a user left as spaces) non-blank, which is wrong.
class String
  def blank?
    /\A[[:space:]]*\z/.match?(self)
  end
end

# OOD hands submit.yml.erb the form values as BARE LOCALS, not through context,
# and every value arrives as a string, because it came back from an HTML form.
def submit_binding(doc)
  values = {}
  (doc['form'] || []).each do |key|
    raw = submitted_value((doc['attributes'] || {})[key.to_s])
    values[key.to_s] = raw.nil? ? '' : raw.to_s
  end
  b = binding
  values.each { |k, v| b.local_variable_set(k.to_sym, v) }
  b
end

# OOD renders view.html.erb with the connection details as BARE LOCALS -- host,
# port and password -- not through `context`, and not from the sub-app's form:
# list, which is why this needs its own binding rather than reusing either of
# the two above. The values are driven by the environment, the same way
# FAKE_GROUPS and FAKE_STAGED_ROOT drive the other two doubles.
def view_binding
  host     = ENV.fetch('FAKE_VIEW_HOST', 'node1')
  port     = ENV.fetch('FAKE_VIEW_PORT', '7123')
  password = ENV.fetch('FAKE_VIEW_PASSWORD', 'view-plaintext-secret')
  binding
end

def render_form(path)
  src = File.read(path)
  out = ERB.new(src, trim_mode: '-').result(binding)
  [out, YAML.safe_load(out)]
end

mode = nil
template = nil
form = nil

args = ARGV.dup
until args.empty?
  case (flag = args.shift)
  when '--form'     then form = args.shift; mode ||= :form
  when '--template' then template = args.shift; mode = :template
  when '--submit'   then template = args.shift; mode = :submit
  when '--view'     then template = args.shift; mode = :view
  else
    warn "unknown argument: #{flag}"
    exit 64
  end
end

# --view is the one mode that needs no sub-app: OOD binds bare connection
# locals into view.html.erb, never form attributes.
if form.nil? && mode != :view
  warn 'usage: render.rb --form <subapp.yml.erb> [--template <file.erb>] | --view <view.html.erb>'
  exit 64
end

doc = form.nil? ? nil : render_form(form).last

case mode
when :form
  puts JSON.generate(doc)
when :template
  context = FormContext.new(doc['attributes'] || {}, doc['form'] || [])
  session = Session.new
  print ERB.new(File.read(template), trim_mode: '-').result(binding)
when :submit
  print ERB.new(File.read(template), trim_mode: '-').result(submit_binding(doc))
when :view
  print ERB.new(File.read(template), trim_mode: '-').result(view_binding)
end
