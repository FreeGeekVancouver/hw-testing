#!/usr/bin/ruby1.8
# -*- coding: utf-8 -*-

# Requires ubuntu packages:
# scsitools ruby-open4
require 'open3'
require 'open4'

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

  def initialize(device)
    super
    @progress = 0
  end

  def start
    super("/sbin/badblocks", '-t', 'random', '-t', '0', '-ws', @device.path)
  end

  def continue
    super do
        if m = @result.err.match(/(\d+.\d+)% done,/)
          @result.err = ''
          @progress = m[1].to_f / 100
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
    if (result.failing? or result.prefail? or
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
      return (now - @start) / @length
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

device = Device.new(ARGV[0])

puts("Device: m'#{device.model}' s'#{device.serial}' z'#{device.size}'")

def run(dev, test, header)
  puts("Test: #{header}")
  test = test.new(dev)
  progress = test.start()
  print("Progress: %5.2f\%\n" % 0)
  while progress < 1
    progress = test.continue()
    print("Progress: %5.2f\%\n" % (progress * 100))
    STDOUT.flush
    sleep(1)
  end
  result = test.finish()
  return result
end

result = run(device, SmartTest, "n'SMART One' s'SM' c'1/?'")

if result.cmd_line?
  raise "SMART Command line error"
end

puts("Result: p'#{result.passed}' s'#{result.status.exitstatus}'")

if result.identify? or result.checksum?
  # Assume the device is not smart capable
  puts("Complete: d'Unwiped' r'Doesnt support SMART'")
  exit(0)
else
  # The device is SMART capable, test it as such
  
  if (result.failing? or result.prefail? or
      result.past_prefail? or result.self_log?)
    # Device failed
    puts("Complete: d'Unwiped' r'SMART Failure'")
    exit(0)
  end

  puts("Plan: SM, ST, BB, SM, PT, FM")

  result = run(device, SmartSelfTest, "n'SMART SelfTest' s'ST' c'2/6'")
  puts("Result: r'#{result.passed}' s'#{result.status.exitstatus}'")
  if (result.failing? or result.prefail? or
      result.past_prefail? or result.self_log?)
    # Device failed
    puts("Complete: d'Unwiped' r'SMART Self-test Failure'")
    exit(0)
  end

  result = run(device, BadBlocksTest, "n'Badblocks' s'BB' c'3/6'")
  puts("Result: r'#{result.passed}' s'#{result.status.exitstatus}'")
  if not result.passed
    puts("Complete: d'Unwiped' r'Badblock failure'")
    exit(0)
  end
  
  result = run(device, SmartTest, "n'SMART Two' s'SM' c'4/6'")
  puts("Result: r'#{result.passed}' s'#{result.status.exitstatus}'")
  if (result.failing? or result.prefail? or
      result.past_prefail? or result.self_log?)
    # Device failed
    puts("Complete: d'Wiped' r'SMART Failure'")
    exit(0)
  end

  result = run(device, PartitionTest, "n'Partitioning' s'PT' c'5/6'")
  if not result.passed
    puts("Complete: d'Wiped' r'Partitioning failure'")
    exit(0)
  end

  result = run(device, FormatTest, "n'Formatting' s'FM' c'6/6'")
  if result.passed
    puts("Complete: d'Wiped' r'No errors'")
    exit(0)
  else
    puts("Complete: d'Wiped' r'Formatting failure'")
    exit(0)
  end
end
