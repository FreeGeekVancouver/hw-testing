#!/usr/bin/ruby1.8
# -*- coding: utf-8 -*-

##############################################################################
## wipe_device.rb performs a battery of tests on a device so that it is
## wiped clean and so that the user knows whether a drive is reusable or not.
## Written by Tyler Hamilton, modified by Cecilia Vargas May 2013.
##############################################################################

libdir = File.expand_path(File.join(File.dirname(__FILE__), 'lib'))
$:.unshift(libdir) unless
           $:.include?(File.join(File.dirname(__FILE__), 'lib')) ||
           $:.include?(libdir)

require 'cgi'
require 'net/http'
require 'open3'
require 'open4'
require 'optparse'
require 'uri'
require 'wipeTestClasses'
require 'multipart'
include TestClasses

options = {
  :dummy => false,
  :runid => "#{Time.now}-#{Process.pid}"
}
##############################################################################
## An instance of class Device represents the device to be wiped.
## It is initialized with the model, serial number, and size of the device.
##############################################################################
class Device
  attr_reader :model, :name, :serial, :size
  def initialize(name)
    @name = name

    if name =~ /^hd/
    then
      raise "Pure ATA devices (/dev/hd*) are not supported by this script"
      stdin, stdout, stderr = Open3.popen3(
                                        '/sbin/hdparm', '-I', "/dev/#{name}")

    else
      stdin, stdout, stderr = Open3.popen3(
                                     '/sbin/scsiinfo', '-is', "/dev/#{name}")
      data = ''
      until stdout.eof? or stdout.closed? or stderr.eof? or stderr.closed?
        data << stdout.read()
      end
      data << stdout.read()
      
      if m = data.match(/^Product:[\t\s]+([^\s].*)$/)
      then
        @model = m[1].strip
      end

      if m = data.match(/^Serial Number '(.*)'$/)
      then
        @serial = m[1].strip
      end

      file = open("/sys/block/#{@name}/size")
      @size = Integer(file.read().strip) * 512 / 1000000
      file.close()
    end
  end

  def path
    return "/dev/#{@name}"
  end
end

##############################################################################
# LogString objects are parameters to method Multipart::Post.prepare_query
##############################################################################
class LogString
  def initialize(name, content)
    @name = name
    @content = content
  end

  def path
    return @name
  end

  def read
    return @content
  end
end

##############################################################################
## Method run creates a test class and invokes methods start, continue,
## and finish on it.
##############################################################################
def run(dev, klass, count, options)
  test = nil
  if options[:dummy] and klass == BadBlocksTest
    test = klass.new(dev, 200000)
  else
    test = klass.new(dev)
  end
  puts("Test: n'#{test.description}' s'#{test.code}' c'#{count}'")
  progress = test.start()
  print("Progress: %5.2f\%\n" % 0)
  while progress < 1
    progress = test.continue()
    print("Progress: %5.2f\%\n" % (progress * 100))
    STDOUT.flush
    sleep(1)
  end
  result = test.finish()
  puts("Result: p'#{result.passed}' s'#{result.status.exitstatus}'" +
       " start'#{result.start_time}' finish'#{result.finish_time}'")

  url = URI.parse('http://build.shop.lan/scripts/wipe.cgi')
  data, headers = 
    Multipart::Post.prepare_query('device' => dev.path,
                                  'device_model' => dev.model,
                                  'device_serial' => dev.serial,
                                  'name' => test.description,
                                  'code' => test.code,
                                  'count' => count,
                                  'result' => result.passed.to_s,
                                  'runid' => options[:runid],
                                  'status' => result.status.exitstatus.to_s,
                                  'start' => result.start_time.to_s,
                                  'finish' => result.finish_time.to_s,
                                  'log_out' => LogString.new('log_out.txt',
                                                              result.out),
                                  'log_err' => LogString.new('log_err.txt',
                                                              result.err))
  http = Net::HTTP.new(url.host, url.port)
  res = http.start do |con|
    con.post(url.path, data, headers)
  end
  return result
end

##############################################################################
## Method complete prints out the very last line of output when all tests that
## can be run on the drive have completed.
## The line instructs the user to either reuse, destroy, or harvest the drive.
##############################################################################
def complete(disp, dest, reason)
  out = "Complete: d'#{disp.to_s.capitalize}' r'#{reason}'"
  case dest
  when :destroy
    out = out + " c'Red' t'Mark with large X for destruction'"
  when :harvest
    out = out + " c'Yellow' t'Mark with small H for controller harvest'"
  when :keep
    out = out + " c'Green' t'Mark with green dot for reuse'"
  end
  puts out
  exit(0)
end

##############################################################################
## Execution starts here. A new Device object is instantiated for the drive
## to be wiped, and then a series of tests are performed on that drive.
##############################################################################
OptionParser.new do |opts|
  opts.banner = "Usage: wipe_device.rb [--dummy] sda"

  opts.on('--dummy', 'Skip the self test and wipe 200 MiB only') do |v|
    options[:dummy] = v
  end
end.parse!

device = Device.new(ARGV[0])

puts("Device: m'#{device.model}' s'#{device.serial}' z'#{device.size}'")

result = run(device, SmartTest, '1/?', options)

if result.identify? or result.checksum? or result.cmd_line?
  # Assume the device is not smart capable
  puts("Plan: SM, BB, PT, FM")

  result = run(device, BadBlocksTest, '2/4', options)
  if not result.passed
    complete(:unwiped, :destroy, 'Badblocks failure')
  end
  
  result = run(device, PartitionTest, '3/4', options)
  if not result.passed
    complete(:wiped, :destroy, 'Partitioning failure')
  end

  result = run(device, FormatTest, '4/4', options)
  if result.passed
    complete(:wiped, :keep, 'No errors')
  else
    complete(:wiped, :destroy, 'Formatting failure')
  end
else
  # The device is SMART capable, test it as such
  
  if (result.failing? or result.prefail? or
      result.past_prefail? or result.self_log?)
    # Device failed
    complete(:unwiped, :harvest, 'SMART Failure')
  end

  puts("Plan: SM, ST, BB, SM, PT, FM")

  if not options[:dummy]
    result = run(device, SmartSelfTest, '2/6', options)
    if (result.failing? or result.prefail? or
        result.past_prefail? or result.self_log?)
      # Device failed
      complete(:unwiped, :harvest, 'SMART Self-test Failure')
    end
  end

  result = run(device, BadBlocksTest, '3/6', options)
  if not result.passed
    complete(:unwiped, :harvest, 'Badblock failure')
  end
  
  result = run(device, SmartTest, '4/6', options)
  if (result.failing? or result.prefail? or
      result.past_prefail? or result.self_log?)
    # Device failed
    complete(:wiped, :harvest, 'SMART Failure')
  end

  result = run(device, PartitionTest, '5/6', options)
  if not result.passed
    complete(:wiped, :harvest, 'Partitioning failure')
  end

  result = run(device, FormatTest, '6/6', options)
  if result.passed
    complete(:wiped, :keep, 'No errors')
  else
    complete(:wiped, :harvest, 'Formatting failure')
  end
end
