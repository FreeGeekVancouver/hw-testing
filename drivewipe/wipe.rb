#!/usr/bin/ruby1.8

##############################################################################
## Wipe.rb prompts the user and sets up the text-based user interface.
## It then looks for drives on the system and starts wipe_device.rb on 
## each drive, displaying the progress of wipe_device for each drive.
##
## Written by Tyler Hamilton, modified by Cecilia Vargas April 2013.
##############################################################################

require 'ncurses'
require 'open4'

##############################################################################
## Method modal prompts for and returns user input.
##############################################################################

def modal(window, question)
  subwindow = displayMessage(window, question)
  str = ''
  subwindow.getstr(str)
  subwindow.clear
  subwindow.delwin
  return str
end

##############################################################################
## Displays message in a subwindow of window and returns subwindow.
##############################################################################

def displayMessage(window, message)
  width = window.getmaxx
  height = window.getmaxy
  q = message.gsub(/(.{1,#{width - 6}})(\s+|$)/, "\\1\n").strip
  lines = q.split("\n").count
  dwidth = lines > 1 ? width - 4 : [(width - 4), q.length + 2].min
  dheight = lines > 1 ? lines + 3 : 3

  win = window.subwin(dheight, dwidth,
                      Integer((height / 2) - (dheight / 2)),
                      Integer((width / 2) - (dwidth / 2)))
  win.clear  
  win.box(0, 0)
  if lines > 1
    i = 1
    q.split("\n").map do |l|
      win.mvaddstr(i, 1, l)
      i = i + 1
    end
    win.move(i, 1)
  else
    win.mvaddstr(0, 1, q)
    win.move(1,1)
  end

  win.refresh()
  return win
end

##############################################################################
## Method drives returns an array with all the drives in directory /sys/block,
## except for devices which aren't SCSI or IDE hard drives. There are block
## devices such as loopback mounts (files mounted as a block device) and
## various RAM devices in that directory that are excluded.
##############################################################################

def drives
  devices = Dir.entries('/sys/block')
  devices.reject! { |x| ['.', '..'].include?(x)}
  devices.reject! { |x| x !~ /^[sh]d/}
  return devices
end

##############################################################################
## A Device object is a device being wiped. When an object is created the
## script wipe_device starts running on it.
## test_plan    is the list of codes of the tests being performed on the device.
## current_test is a hash with the current test's info like the test name,
##              start and finish times, progress, status, and whether it passed.
## tests        is an array of hashes containing all the tests that have been
##              performed on the device so far, including the current one running.
##              It is an array of current_test's.
##############################################################################

class Device
  def initialize(name, window)
    @name   = name
    @window = window

    @started = false
    @done = false

    @model = 'Unknown'
    @size  = 'Unknown'
    @serial = 'Unknown'
    @buff_out = ''
    @buff_err = ''
    @current_test = nil
    @test_plan = []
    @tests = []

    @window.mvaddstr(0, 0, '[ ]')
    @window.mvaddstr(0, 4, @name)
    @window.mvaddstr(0, 8, 'Initializing...')

    @pid, @in, @out, @err = Open4::open4('./wipe_device.rb', name)
    self.update()
  end

##############################################################################
## Method update reads the output of wipe_device.rb, the script actually
## wiping the device, and reports on how the wiping is progressing or how
## it all ended.
##############################################################################

  def update

## Read into @buff_out 16KiB (or less) at a time, while data is
## waiting in @out. To avoid waiting, use read_nonblock instead
## of the regular read.

    while (IO.select([@out], nil, nil, 0))
      begin
        @buff_out << @out.read_nonblock(16384)
      rescue EOFError
        break
      end
    end

## Parse update from the program at the other end of @out.
## Updates are of the form type:data

    while idx = @buff_out.index("\n")
      line = @buff_out.slice!(0, idx + 1)
      if i = line.index(':')
        parse(line.slice!(0, i), line)
      else
        raise "Unknown input: '%s'" % line
      end
    end

## wipe.rb and its child wipe_device.rb are connected by pipes,
## which can only hold so much at once. If wipe_device tries to 
## write to a full stderr it will block; therefore wipe.rb needs 
## to read from stderr to allow wipe_device.rb to write to it.

    while (IO.select([@err], nil, nil, 0))
      begin
        @buff_err << @err.read_nonblock(16384)
      rescue EOFError
        break
      end
    end

    if @started and not @done
      prg = @current_test['progress']
      len = (20 * (prg / 100)).to_i
      pbar = '=' * len
      pbar << ' ' * (20 - len)
      @window.mvaddstr(1, 4,
                       "[%s]%6.2f%% %s" % [pbar, prg, @current_test['name']])
    end

    if @done
      c = @complete
      @window.attron(Ncurses.COLOR_PAIR(1))
      @window.mvaddstr(1, 4, 'Finished: ')
      @window.refresh
      case c[:color]
      when 'Red'
        @window.attron(Ncurses.COLOR_PAIR(2))
      when 'Yellow'
        @window.attron(Ncurses.COLOR_PAIR(4))
      when 'Green'
        @window.attron(Ncurses.COLOR_PAIR(3))
      end      
      @window.mvaddstr(1, 15, '%s - %s' % [c[:disposition], c[:destination]])
      @window.attron(Ncurses.COLOR_PAIR(1))
    end

    @window.refresh
  end

##############################################################################
## Method parse parses the output of wipe_device.rb, which is in the format
## type : value.
## Types:
##        Device     - model, serial number, and size of device being wiped
##        Test       - description of test that is starting
##        Result     - result of last test
##        Plan       - list of tests
##        Progress   - percentage indicator of progress
##        Complete   - testing is done, final result available
##############################################################################

  private

  def parse(type, value)
    case type
    when 'Device'
      if m = value.match(/m'([^']*)' s'([^']*)' z'([^']*)'/)
        @model = m[1]
        @serial = m[2]
        @size = m[3]
        @window.mvaddstr(0, 8, 'M:%s' % @model)
        @window.mvaddstr(0, 29, 'S:%s' % @serial)
        @window.mvaddstr(0, 50, 'Z:%s' % @size)
      end
    when 'Test'
      if m = value.match(/^: n'([^']*)' s'([^']*)' c'([^']*)'/)
        @started = true
        @progress = 0
        test = {
          'name' => m[1],
          'code' => m[2],
          'count' => m[3],
          'progress' => 0,
          'passed' => nil,
          'status' => nil
        }

        @current_test = test
        @tests << @current_test
        update_test_plan

        @window.move(1, 0)
        @window.clrtobot()
      end
    when 'Result'
      if m = value.match(/^: p'(true|false)' s'(\d+)' start'([^']+)' finish'([^']+)'/)
        @current_test['passed'] = (m[1] == 'true')
        @current_test['status'] = m[2]
        @current_test['start_time'] = m[3]
        @current_test['finish_time'] = m[4]
        update_test_plan
      end
    when 'Plan'
      value.slice!(/^:\s+/)
      @test_plan = value.split(', ')
      update_test_plan
    when 'Progress'
      if m = value.match(/^:\s+([\d\.]+)%/)
        @current_test['progress'] = m[1].to_f
      end
    when 'Complete'
      if m = value.match(/^: d'([^']*)' r'([^']*)' c'([^']*)' t'([^']*)'/)
        @complete = {
          :disposition => m[1],
          :reason => m[2],
          :color => m[3],
          :destination => m[4]
        }
        @done = true
        @window.move(1, 0)
        @window.clrtobot()
      end
    else
      raise "Unknown input: %s - %s" % [type, value]
    end
  end

##############################################################################
## Method update_test_plan updates the on-screen coloring of the test codes,
## which is usually a string like SM ST BB SM PT FM. It sets the current test
## to bright, failed tests to red, passed tests to green and pending tests as
## normal (gray).
##############################################################################

  def update_test_plan
    i = 0
    if @test_plan
      @test_plan.each do |t|
        if not @tests[i].nil?
          if not @tests[i]['passed'].nil?
            if @tests[i]['passed']
              @window.attron(Ncurses.COLOR_PAIR(3))
            else
              @window.attron(Ncurses.COLOR_PAIR(2))
            end
          else
            @window.attron(Ncurses.COLOR_PAIR(1) | Ncurses::A_BOLD)
          end
          @window.mvaddstr(0, 60 + (i * 3), "#{@tests[i]['code']}")
          @window.attroff(Ncurses::A_BOLD)
          @window.attron(Ncurses.COLOR_PAIR(1))
        else
          @window.mvaddstr(0, 60 + (i * 3), t)
        end

        i = i + 1
      end
    end
  end
end

##############################################################################
## Execution starts here. Set up user interface, find drives in system,
## and wipe each drive, showing how the wiping progresses.
##############################################################################
Ncurses.initscr

begin
  Ncurses.start_color
  Ncurses.init_pair(1, Ncurses::COLOR_WHITE, Ncurses::COLOR_BLACK)
  Ncurses.init_pair(2, Ncurses::COLOR_RED, Ncurses::COLOR_BLACK)
  Ncurses.init_pair(3, Ncurses::COLOR_GREEN, Ncurses::COLOR_BLACK)
  Ncurses.init_pair(4, Ncurses::COLOR_YELLOW, Ncurses::COLOR_BLACK)
  window = Ncurses::WINDOW.new(24, 80, 0, 0)
  window.box(0, 0)
  window.mvaddstr(0, 1, " FG Drive Wipe ")
  window.refresh
  id = modal(window, "Volunteer ID?")
  window.mvaddstr(0, 65, " UID: %6d " % id)
  window.refresh

## Gather in array devs all the drives in the system, and check
## that the number of drives found makes sense. 

  cnt = modal(window, "How many drives are attached?").to_i
  devs = drives
  window.refresh


  if devs.count != cnt
    win = displayMessage(window, "Expected #{cnt} drives but found #{devs.count} instead.\n"   +
                                 "I will sleep a bit in case attached drive(s) not awake yet," + 
                                 "unless you enter q anytime to quit or c to continue anyway." )
    devs = drives
    Ncurses.cbreak()
    Ncurses.noecho()
    window.timeout(5000)
    while devs.count != cnt
      ch = window.getch()
      if ch == ?q
        Ncurses.endwin
        exit(1)
      elsif ch == ?c
        break
      end
      devs = drives
    end
    win.clear
    win.refresh
    win.delwin
  end

  if devs.count > 7
    modal(window, "Wiping more than 7 devices is not supported")
    Ncurses.endwin
    exit(1)
  end

## Create an array with Device objects, one for each drive in array devs.
## The wiping script starts as soon as the object is created and initialized.

  devices = []
  i = 1
  devs.each do |dev|
    win = window.subwin(2, 78, i * 3, 1)
    device = Device.new(dev, win)
    devices.push(device)
    i = i + 1
  end

## Array devices now has all initialized Device objects. Iterate thru
## it to report how each drive's wiping is progressing.

  Ncurses.cbreak()
  Ncurses.noecho()
  window.timeout(1000)

  while true
    devices.each do |dev|
      dev.update()
    end

    ch = window.getch()
    if ch == ?q
      break
    elsif ch == ?s
      system '/sbin/poweroff'
    end
  end
 
  Ncurses.endwin
rescue
  Ncurses.endwin
  raise
end

exit(0)
