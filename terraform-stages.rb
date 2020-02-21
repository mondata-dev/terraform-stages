#!/usr/bin/env ruby

require "fileutils"
require "yaml"
require "net/http"

if ARGV.empty? || (ARGV[0] != "apply" && ARGV[0] != "destroy")
  puts 'Usage: terraform-stages.rb <apply | destroy> [-build-dir=path/to/dir]'
  exit(1)
end
cmd = ARGV.shift

curdir = File.expand_path(".")
build_dir_arg = ARGV.find { |a| a.start_with?("-build-dir=") }
CONFIG = {
  curdir: curdir,
  build_dir: build_dir_arg.nil? ? curdir : File.expand_path(build_dir_arg.split("=")[1..-1].join),
}.freeze
yaml = YAML.safe_load(File.read("terraform-stages.yaml"))

class Stage
  def initialize(name, depends_on)
    @name = name
    @depends_on = depends_on
    @outputs = {}
  end

  def to_s
    @name
  end

  def terraform_cmd(cmd, init, args)
    state_dir = "#{CONFIG[:build_dir]}/#{@name}"
    Dir.mkdir(state_dir) unless File.directory?(state_dir)

    s = "cd #{CONFIG[:curdir]}/#{@name} && "
    s += 'terraform init && ' if init
    s + "terraform #{cmd} -state=#{state_dir}/terraform.tfstate #{args.join(' ')}"
  end

  def inputs
    inputs = {}

    Dir["#{CONFIG[:build_dir]}/*.tfvars"].each { |f| inputs[f] = nil }
    Dir["#{CONFIG[:build_dir]}/#{@name}/*.tfvars"].each { |f| inputs[f] = nil }

    @depends_on.each do |d|
      next if !d.is_a?(StageDependency) || d.variables.empty?

      inputs[d.stage] = d.variables
    end

    inputs
  end

  def update_outputs!
    @outputs.keys.each do |k|
      @outputs[k] = `#{terraform_cmd('output', false, [k])}`.chomp
    end
  end

  attr_reader :name, :depends_on, :outputs
end

def replace_vars(str, varmap)
  str.gsub(/\$\{([\w_]+)\}/) { varmap[$1] }
end

class StageDependency
  def initialize(stage, variables)
    @stage = stage
    @variables = variables
  end

  def met?(plan)
    plan.any? { |s| s.name == @stage }
  end

  attr_reader :stage, :variables
end

class UrlDependency
  def initialize(url, timeout)
    @url = url
    @timeout = timeout
  end

  def met?(rep_url)
    uri = URI.parse(rep_url)
    req = Net::HTTP::Get.new(uri.to_s)

    begin
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.request(req)
      end

      true
    rescue Errno::ECONNRESET
      false
    rescue EOFError
      # There seems to be something there at least :)
      true
    end
  end

  def wait_to_be_met(varmap)
    rep_url = replace_vars(@url, varmap)

    i = 0
    until met?(rep_url)
      print "Waiting for #{rep_url}"
      print "  [#{i}s]" if i > 0
      puts '...'
      sleep 5
      i += 5
      raise "Timout waiting for #{rep_url}" if i >= @timeout
    end
  end
end

stages = yaml.keys.map do |k|
  deps = (yaml[k]["depends_on"] || []).map do |d|
    if d["stage"]
      StageDependency.new(d["stage"], d["variables"] || [])
    elsif d["url"]
      UrlDependency.new(d["url"], d["timeout"] || 120)
    else
      puts "Unknown dependency: #{d}"
      exit(2)
    end
  end

  Stage.new(k, deps)
end

plan = []
until stages.empty?
  # find first stage that is executable
  found_idx = nil

  stages.each_with_index do |s,i|
    if s.depends_on.all? { |d| !d.is_a?(StageDependency) || d.met?(plan) }
      # add required outputs to dependend stages
      s.depends_on.each do |d|
        next if !d.is_a?(StageDependency) || d.variables.empty?

        dep_stage = plan.find { |s2| s2.name == d.stage }
        d.variables.each do |v|
          dep_stage.outputs[v] = nil
        end
      end

      plan.push(s)
      found_idx = i
      break
    end
  end

  if found_idx.nil?
    puts 'Dependencies of the following stages cannot be fulfilled:'
    stages.each do |s|
      puts s.name
    end
    exit(3)
  else
    stages.delete_at(found_idx)
  end
end

plan.reverse! if cmd == "destroy"

puts 'Planning complete. I will run the stages in the following order:'
puts
plan.each_with_index do |s, i|
  puts "#{i+1}. #{s.name}"

  unless s.inputs.empty?
    puts "   inputs:"
    s.inputs.each do |k,v|
      if v.nil?
        puts "   - var-file: #{k}"
      else
        puts "   - #{v.join(', ')} from #{k}"
      end
    end
  end

  unless s.outputs.empty?
    puts "   outputs:"
    s.outputs.keys.each do |k|
      puts "   - #{k}"
    end
  end
end

puts
print 'To continue please confirm with "yes": '
answer = STDIN.gets.chomp

exit(0) unless answer == 'yes'
puts

# calculate values of input variables coming from dependend stages
def calc_dep_inputs(plan, stage_idx)
  dep_inputs = {}
  plan[stage_idx].inputs.each do |k, v|
    next if v.nil?

    dep_stage = plan[0...stage_idx].find { |s| s.name == k }
    v.each do |e|
      dep_inputs[e] = dep_stage.outputs[e]
    end
  end

  dep_inputs
end

def calc_args(stage, dep_inputs)
  args = []
  stage.inputs.each do |k, v|
    next unless v.nil?

    args.push("-var-file=#{k}")
  end
  dep_inputs.each do |var, val|
    args.push("-var")
    args.push("#{var}=#{val}")
  end
  args
end

if cmd == "apply"
  # start applying
  plan.each_with_index do |s, i|
    puts "Stage #{i+1}: #{s.name}"
    puts

    dep_inputs = calc_dep_inputs(plan, i)

    s.depends_on.each do |d|
      if d.is_a? StageDependency
        next
      elsif d.is_a? UrlDependency
        d.wait_to_be_met(dep_inputs)
      end
    end

    cmd = s.terraform_cmd('apply', true, calc_args(s, dep_inputs))
    puts cmd
    puts

    r = system(cmd)

    s.update_outputs!

    unless r
      puts 'terraform exited with non-zero exit code. Aborting.'
      break
    end
  end
elsif cmd == "destroy"
  puts "Pre-phase: calculate dependency inputs..."
  args = {}
  plan.reverse.each_with_index do |s, i|
    puts s.name
    args[s] = calc_args(s, calc_dep_inputs(plan.reverse, i))
    s.update_outputs!
  end
  puts

  # start destroying
  puts "Let's start destroying stuff..."
  puts

  plan.each_with_index do |s, i|
    puts "Stage #{i+1}: #{s.name}"
    puts

    cmd = s.terraform_cmd('destroy', true, args[s])
    puts cmd
    puts

    r = system(cmd)

    unless r
      puts 'terraform exited with non-zero exit code. Aborting.'
      break
    end
  end
end
