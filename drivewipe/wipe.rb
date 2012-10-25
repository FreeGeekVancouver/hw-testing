#!/usr/bin/ruby1.8

# Requires packages:
# ruby-ncurses smartmontools

require 'ncurses'
require 'open4'

def modal(window, question)
  width = window.getmaxx
  height = window.getmaxy
  win = window.subwin(3, 20,
                      Integer((height / 2) - 2),
                      Integer((width / 2) - 10))
  win.box(0, 0)
  win.mvaddstr(0, 1, question)
  win.move(1,1)
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
      len = (20 * (@progress / 100)).to_i
      pbar = '=' * len
      pbar << ' ' * (20 - len)
      @window.mvaddstr(1, 4,
                       "[%s]%6.2f%% %s" % [pbar, @progress, @test])
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
        @test = m[1]
        @short = m[2]
        @window.move(1, 0)
        @window.clrtobot()
      end
    when 'Result'
      if m = value.match(/^: p'(true|false)' s'(\d+)'/)
      end
    when 'Plan'
      # Do nothing for now
    when 'Progress'
      if m = value.match(/^:\s+([\d\.]+)%/)
        @progress = m[1].to_f
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
end

Ncurses.initscr
begin
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

  devices = []
  i = 1
  devs.each do |dev|
    win = window.subwin(2, 78, i * 3, 1)
    device = Device.new(dev, win)
    devices.push(device)
    i = i + 1
    if i > 7
      raise "Too many devices detected"
    end
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
