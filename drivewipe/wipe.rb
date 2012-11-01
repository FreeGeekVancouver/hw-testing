#!/usr/bin/ruby1.8

# Requires packages:
# ruby-ncurses smartmontools

require 'ncurses'
require 'open4'

def modal(window, question)
  width = window.getmaxx
  height = window.getmaxy
  q = question.gsub(/(.{1,#{width - 6}})(\s+|$)/, "\\1\n").strip
  lines = q.split("\n").count
  dwidth = lines > 1 ? width - 4 : [(width - 4), q.length + 2].min
  dheight = lines > 1 ? lines + 3 : 3

  win = window.subwin(dheight, dwidth,
                      Integer((height / 2) - (dheight / 2)),
                      Integer((width / 2) - (dwidth / 2)))
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
  str = ''
  win.getstr(str)
  win.clear
  win.refresh
  win.delwin
  return str
end

def drives
  devices = Dir.entries('/sys/block')
  devices.reject! { |x| ['.', '..'].include?(x)}
  devices.reject! { |x| x !~ /^[sh]d/}
  return devices
end

class Device
  def initialize(name, window)
    @name   = name
    @window = window

    @started = false
    @done = false

    @model = 'Unknown'
    @size  = 'Unknown'
    @serial = 'Unknown'
    @selected = false
    @status = 'Unknown'
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

  def done?
    return @done
  end

  def update
    while (IO.select([@out], nil, nil, 0))
      begin
        @buff_out << @out.read_nonblock(16384)
      rescue EOFError
        o = true
        break
      end
    end

    while idx = @buff_out.index("\n")
      line = @buff_out.slice!(0, idx + 1)
      if i = line.index(':')
        parse(line.slice!(0, i), line)
      else
        raise "Unknown input: '%s'" % line
      end
    end

    while (IO.select([@err], nil, nil, 0))
      begin
        @buff_err << @err.read_nonblock(16384)
      rescue EOFError
        e = true
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
      @window.mvaddstr(1, 4,
                       'Finished: %s because %s' % [@disposition, @reason])
    end

    @window.refresh
  end

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
      if m = value.match(/^: d'([^']*)' r'([^']*)'/)
        @disposition = m[1]
        @reason = m[2]
        @done = true
        @window.move(1, 0)
        @window.clrtobot()
      end
    else
      raise "Unknown input: %s - %s" % [type, value]
    end
  end

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

Ncurses.initscr

begin
  Ncurses.start_color
  Ncurses.init_pair(1, Ncurses::COLOR_WHITE, Ncurses::COLOR_BLACK)
  Ncurses.init_pair(2, Ncurses::COLOR_RED, Ncurses::COLOR_BLACK)
  Ncurses.init_pair(3, Ncurses::COLOR_GREEN, Ncurses::COLOR_BLACK)
  window = Ncurses::WINDOW.new(24, 80, 0, 0)
  window.box(0, 0)
  window.mvaddstr(0, 1, " FG Drive Wipe ")
  window.refresh
  id = modal(window, "Volunteer ID?")
  window.mvaddstr(0, 65, " UID: %6d " % id)
  window.refresh

  devs = drives
  cnt = modal(window, "Number of drives?").to_i
  window.refresh

  if devs.count != cnt
    a = modal(window, "Expected #{cnt} drives, got #{devs.count}")
  end

  if devs.count > 7
    modal(window, "Wiping more than 7 devices is not supported")
    Ncurses.endwin
    exit(1)
  end

  devices = []
  i = 1
  devs.each do |dev|
    win = window.subwin(2, 78, i * 3, 1)
    device = Device.new(dev, win)
    devices.push(device)
    i = i + 1
  end

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
    end
  end

  Ncurses.endwin
rescue
  Ncurses.endwin
  raise
end

exit(0)
