# -*- coding: utf-8 -*-

##############################################################################
## This module contains all the test classes for the tests performed
## when a device is wiped.
## Written by Tyler Hamilton, modified by Cecilia Vargas May 2013.
##############################################################################
module TestClasses

  ############################################################################
  ## A TestResult object holds the result information for a test.
  ## Variable status is an instance of Process::Status, and this variable
  ## is set by the call to Process::waitpid2 in method finish of BaseTest.
  ############################################################################
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

  ############################################################################
  ## The methods in class SmartResult interpret the exit status from smartctl.
  ############################################################################
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

  ############################################################################
  ## Class BaseTest is the parent of all test classes, except for
  ## SmartSelfTest. Its 3 methods start, continue, and finish perform the
  ## corresponding test. A child process is spun off in method start to
  ## run the appropriate command.
  ############################################################################
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
      # These may be already closed, for example to signal that
      # no more commands are pending for a program.
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

  ############################################################################
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

  ############################################################################
  class FormatTest < BaseTest
    @description = 'Format'
    @code        = 'FM'

    def start
      super("/sbin/mkfs.vfat", @device.path + "1")
    end
  end

  ############################################################################
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

  ############################################################################
  ## This test and SmartSelfTest execute /usr/sbin/smartctl, the Control and
  ## Monitor Utility for SMART Disks. It controls the Self-Monitoring,
  ## Analysis and Reporting Technology (SMART) built into many hard drives.
  ############################################################################
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

  ############################################################################
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
      if m = output.match(
                    '/Please wait (\d+) minutes for the test to complete/')
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
end
