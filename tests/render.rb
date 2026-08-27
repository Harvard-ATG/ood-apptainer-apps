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
    form.each { |k| @values[k.to_s] = attributes[k.to_s] }
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
  else
    warn "unknown argument: #{flag}"
    exit 64
  end
end

if form.nil?
  warn 'usage: render.rb --form <subapp.yml.erb> [--template <file.erb>]'
  exit 64
end

_raw, doc = render_form(form)

case mode
when :form
  puts JSON.generate(doc)
when :template
  context = FormContext.new(doc['attributes'] || {}, doc['form'] || [])
  session = Session.new
  print ERB.new(File.read(template), trim_mode: '-').result(binding)
end
