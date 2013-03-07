#!/usr/bin/ruby1.8
# -*- coding: utf-8 -*-

# Requires ubuntu packages:
# scsitools ruby-open4
require 'cgi'
require 'net/http'
require 'open3'
require 'open4'
require 'optparse'
require 'uri'

options = {
  :dummy => false,
  :runid => "#{Time.now}-#{Process.pid}"
}

module Multipart
  VERSION = "1.0.0" unless const_defined?(:VERSION)

  # Formats a given hash as a multipart form post
  # If a hash value responds to :string or :read messages, then it is
  # interpreted as a file and processed accordingly; otherwise, it is assumed
  # to be a string
  class Post
    USERAGENT = "Multipart::Post v#{VERSION}" unless const_defined?(:USERAGENT)

    unless const_defined?(:BOUNDARY)
      BOUNDARY = "0123456789ABLEWASIEREISAWELBA9876543210" 
    end

    unless const_defined?(:CONTENT_TYPE)
      CONTENT_TYPE = "multipart/form-data; boundary=#{ BOUNDARY }"
    end

    HEADER = {
      "Content-Type" => CONTENT_TYPE,
      "User-Agent" => USERAGENT
    } unless const_defined?(:HEADER)

    def self.prepare_query(params)
      fp = []

      params.each do |k, v|
        # Are we trying to make a file parameter?
        if v.respond_to?(:path) and v.respond_to?(:read) then
          fp.push(FileParam.new(k, v))
        # We must be trying to make a regular parameter
        else
          fp.push(StringParam.new(k, v))
        end
      end

      # Assemble the request body using the special multipart format
      query = fp.collect {|p|
        "--" + BOUNDARY + "\r\n" + p.to_multipart
      }.join("")  + "--" + BOUNDARY + "--"
      
      return query, HEADER
    end
  end

  private

  # Formats a basic string key/value pair for inclusion with a multipart post
  class StringParam
    attr_accessor :k, :v

    def initialize(k, v)
      @k = k
      @v = v
    end

    def to_multipart
      return "Content-Disposition: form-data; " +
        "name=\"#{CGI::escape(k)}\"\r\n\r\n#{v}\r\n"
    end
  end

  # Formats the contents of a file or string for inclusion with a multipart
  # form post
  class FileParam
    attr_accessor :k, :filename, :content

    def initialize(k, f)
      @k = k
      @filename = f.path
      @content = f.read
    end

    def to_multipart
      # If we can tell the possible mime-type from the filename, use the
      # first in the list; otherwise, use "application/octet-stream"
      return "Content-Disposition: form-data; " +
        "name=\"#{CGI::escape(k)}\"; filename=\"#{ filename }\"\r\n" +
        "Content-Type: application/octet-stream\r\n\r\n#{ content }\r\n"
    end
  end
end

class Device
  attr_reader :model, :name, :serial, :size
  def initialize(name)
    @name = name

    if name =~ /^hd/
    then
      raise "Pure ATA devices (/dev/hd*) are not supported by this script"
      stdin, stdout, stderr = Open3.popen3('/sbin/hdparm', '-I', "/dev/#{name}")

    else
      stdin, stdout, stderr = Open3.popen3('/sbin/scsiinfo', '-is', "/dev/#{name}")
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

class TestResult
  attr_accessor :status, :in, :out, :err, :start_time, :finish_time, :passed

  def initialize
    @status = nil
    @in = ''
    @out = ''
    @err = ''
    @start_time = Time.now()
    @finish_time = nil
    @passed = false
  end

  def finish(result)
    @finish_time = Time.now()
    @passed = result
  end
end

class SmartResult < TestResult
  # Bit 0: Command line did not parse.
  def cmd_line?
    @status.exitstatus & (1 << 0) != 0
  end

  # Bit 1: Device  open  failed,  device  did  not  return an IDENTIFY
  #  DEVICE structure, or device is in  a  low-power  mode  (see
  #  ´-n´ option above).
  def identify?
    @status.exitstatus & (1 << 1) != 0
  end

  # Bit 2: Some  SMART  command  to  the  disk  failed, or there was a
  #  checksum error in a SMART data structure (see  ´-b´  option
  #  above).
  def checksum?
    @status.exitstatus & (1 << 2) != 0
  end

  # Bit 3: SMART status check returned "DISK FAILING".
  def failing?
    @status.exitstatus & (1 << 3) != 0
  end

  # Bit 4: We found prefail Attributes <= threshold.
  def prefail?
    @status.exitstatus & (1 << 4) != 0
  end

  # Bit 5: SMART  status  check  returned  "DISK OK" but we found that
  #  some (usage or prefail) Attributes have been  <=  threshold
  #  at some time in the past.
  def past_prefail?
    @status.exitstatus & (1 << 5) != 0
  end

  # Bit 6: The device error log contains records of errors.
  def error_log?
    @status.exitstatus & (1 << 6) != 0
  end

  # Bit 7: The  device self-test log contains records of errors.  [ATA
  #  only] Failed self-tests  outdated  by  a  newer  successful
  #  extended self-test are ignored.
  def self_log?
    @status.exitstatus & (1 << 7) != 0
  end
end

class BaseTest
  class << self
    attr_reader :code, :description
  end

  def code
    self.class.code
  end

  def description
    self.class.description
  end

  def initialize(device)
    @device = device
    @result = nil
    @length = 0
    @progress = 0
  end
  
  def start(*args)
    @result = TestResult.new()
    @pid, @in, @out, @err = Open4.open4(*args)
    return self.continue()
  end

  def continue
    o = false
    e = false
    while (IO.select([@out], nil, nil, 0))
      begin
        @result.out << @out.read_nonblock(16384)
      rescue EOFError
        o = true
        break
      end
    end

    while (IO.select([@err], nil, nil, 0))
      begin
        @result.err << @err.read_nonblock(16384)
      rescue EOFError
        e = true
        break
      end
    end
    
    yield if block_given?

    if o and e
      return 1
    else
      return @progress
    end
  end

  def finish
    # These may be already closed, for example to signal that no more commands
    # are pending for a program.
    @in.closed? or @in.close()
    @out.closed? or @out.close()
    @err.closed? or @err.close()
    ignored, @result.status = Process::waitpid2(@pid)
    if @result.status.exitstatus == 0
      @result.finish(true)
    else
      @result.finish(false)
    end
    return @result
  end
end

class BadBlocksTest < BaseTest
  @description = 'Destructive badblocks'
  @code        = 'BB'

  def initialize(device, size=nil)
    super(device)
    @size = size
    @progress = 0
    @stage_progress = 0
    @write_patterns = ['random', '0']
    @stage = 1
  end

  def start
    args = ["/sbin/badblocks"]
    @write_patterns.each do |p|
      args << '-t'
      args << p
    end
    args << '-ws'
    args << @device.path

    if not @size.nil?
      args << @size.to_s
    end
    super(*args)
  end

  def continue
    super do
        if m = @result.err.match(/(\d+.\d+)% done,/)
          @result.err = ''

          # Badblocks reports progress for the current stage,
          # each write pass is followed by a read pass
          prog = m[1].to_f / (@write_patterns.count * 200)
          if prog < @stage_progress
            @stage = @stage + 1
          end
          @stage_progress = prog

          # Specify constants using decimal to allow a non integer result
          @progress = prog + ((@stage - 1.0) * 
                              (1.0 / (@write_patterns.count * 2.0)))
        end
    end
  end
end

class FormatTest < BaseTest
  @description = 'Format'
  @code        = 'FM'
  
  def start
    super("/sbin/mkfs.vfat", @device.path + "1")
  end
end

class PartitionTest < BaseTest
  @description = 'Partition'
  @code        = 'PT'

  def initialize(device)
    super
    @length = 10
  end

  def start
    progress = super("/sbin/sfdisk", '-q', @device.path)
    @in.write("0,,b\n")
    @in.close
    return progress
  end
end

class SmartTest < BaseTest
  @description = 'SMART'
  @code        = 'SM'

  def start
    progress = super("/usr/sbin/smartctl", '-a', @device.path)
    @result = SmartResult.new()
    return progress
  end

  def finish
    result = super
    if (result.identify? or result.checksum? or
        result.failing? or result.prefail? or
        result.past_prefail? or result.self_log?)
      result.passed = false
    else
      result.passed = true
    end
    return result
  end
end

class SmartSelfTest
  @description = 'SMART short self-test'
  @code        = 'ST'
  class << self
    attr_reader :code, :description
  end

  def code
    self.class.code
  end

  def description
    self.class.description
  end

  def initialize(device)
    @device = device
    @result = nil
    @test = SmartTest.new(device)
    @started = false
    @counter = 0
    @start = nil
    @finish = nil
    @length = 315
  end

  def start
    @start = Time.now
    output = `/usr/sbin/smartctl -t short #{@device.path}`
    
    length = 300
    if m = output.match('/Please wait (\d+) minutes for the test to complete/')
      length = m[1] * 60 + 15
    end
    @length = length
    @finish = Time.now() + length
    return 0
  end

  def continue
    now = Time.now
    if now < @finish
      prog = (now - @start) / @length
      return prog if prog < 1
      return 0.99
    end

    unless @started
      @test.start()
      @started = true
    end
    
    progress = @test.continue
    if progress == 1
      return 1
    else
      return 0.99
    end
  end

  def finish
    @result = @test.finish
    return @result
  end
end

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

OptionParser.new do |opts|
  opts.banner = "Usage: wipe_device.rb [--dummy] sda"

  opts.on('--dummy', 'Skip the self test and wipe 200 MiB only') do |v|
    options[:dummy] = v
  end
end.parse!

device = Device.new(ARGV[0])

puts("Device: m'#{device.model}' s'#{device.serial}' z'#{device.size}'")

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
                                  'log_out' => LogString.new('log_out.txt', result.out),
                                  'log_err' => LogString.new('log_err.txt', result.err))
  http = Net::HTTP.new(url.host, url.port)
  res = http.start do |con|
    con.post(url.path, data, headers)
  end
  return result
end

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

result = run(device, SmartTest, '1/?', options)

if result.cmd_line?
  raise "SMART Command line error"
end

if result.identify? or result.checksum?
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
