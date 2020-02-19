#!/usr/bin/env ruby

require "fileutils"
require "yaml"
require "socket"
require "timeout"
require "net/http"

curdir = File.expand_path(".")
yaml = YAML.safe_load(File.read("terraform-stages.yaml"))

class Stage
  def initialize(name, depends_on)
    @name = name
    @depends_on = depends_on
  end

  def to_s
    @name
  end

  attr_reader :name, :depends_on
end

class StageDependency
  def initialize(stage)
    @stage = stage
  end

  def met?(plan)
    plan.any? { |s| s.name == @stage }
  end
end

class UrlDependency
  def initialize(url, timeout)
    @url = url
    @timeout = timeout
  end

  def met?
    uri = URI.parse(@url)
    req = Net::HTTP::Get.new(uri.to_s)

    begin
      res = Net::HTTP.start(uri.host, uri.port) do |http|
        http.request(req)
      end
      puts res
      puts res.body

      true
    rescue Errno::ECONNRESET => e
      puts e
      false
    rescue EOFError => e
      # There seems to be something there at least :)
      true
    end
  end

  def wait_to_be_met
    i = 0
    until met?
      print "Waiting for #@url"
      print "  [#{i}s]" if i > 0
      puts '...'
      sleep 5
      i += 5
      raise "Timout waiting for #@url" if i >= @timeout
    end
  end
end

stages = yaml.keys.map do |k|
  deps = (yaml[k]["depends_on"] || []).map do |d|
    if d["stage"]
      StageDependency.new(d["stage"])
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

puts 'Planning complete. I will run the stages in the following order:'
puts
plan.each_with_index do |s, i|
  puts "#{i+1}. #{s.name}"
end

puts
print 'To continue please confirm with "yes": '
answer = STDIN.gets.chomp

# exit(0) unless answer == 'yes'

# start applying
puts

plan.each_with_index do |s, i|
  puts "Stage #{i+1}: #{s.name}"
  puts

  s.depends_on.each do |d|
    if d.is_a? StageDependency
      next
    elsif d.is_a? UrlDependency
      d.wait_to_be_met
    end
  end

  args = ARGV.map{ |a|
    if a =~ /^-var-file=(.+)/
      "'-var-file=#{curdir}/#{$1}'"
    else
      "'#{a}'"
    end
  }.join(" ")
  cmd = "cd #{curdir}/#{s.name} && terraform init && terraform apply #{args}"
  puts cmd
  puts

  r = system(cmd)

  unless r
    puts 'terraform exited with non-zero exit code. Aborting.'
    break
  end
end
