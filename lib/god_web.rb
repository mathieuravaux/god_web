class GodWeb
  def initialize(config)
    @config = config
    setup
    ping
  end

  def self.watch(options = {})
    options[:port] ||= 8888
    options[:environment] ||= 'production'
    start_string = "god_web #{options[:config]} -e #{options[:environment]} -p #{options[:port]}"
    God.watch do |w|
      w.name              = "god_web"
      w.interval          = 1.minute
      w.start             = start_string
      w.start_grace       = 10.seconds
      w.restart_grace     = 10.seconds

      w.start_if do |start|
        start.condition(:process_running) do |c|
          c.running = false
        end
      end

      w.restart_if do |restart|
        restart.condition(:memory_usage) do |c|
          c.above = 20.megabytes
          c.times = [3, 5]
        end

        restart.condition(:cpu_usage) do |c|
          c.above = 25.percent
          c.times = 5
        end
      end

      w.lifecycle do |on|
        on.condition(:flapping) do |c|
          c.to_state = [:start, :restart]
          c.times = 5
          c.within = 5.minute
          c.transition = :unmonitored
          c.retry_in = 10.minutes
          c.retry_times = 5
          c.retry_within = 2.hours
        end
      end
    end
  end

  def setup
    DRb.start_service
    @server = DRbObject.new(nil, God::Socket.socket(@config['god_port']))
  end

  # ping server to ensure that it is responsive
  def ping
    tries = 3
    begin
      @server.ping
    rescue Exception => e
      if (tries -= 1) > 0
        retry
      end
      raise e, "The server is not available (or you do not have permissions to access it)"
    end
  end

  def last_log(watch)
    format_log(log_command(watch, true))
  end

  def self.possible_statuses(status)
    case status
    when :up
      return %w{stop restart unmonitor}
    when :unmonitored
      return %w{start monitor}
    else
      return %w{start stop restart}
    end
  end


private

  def method_missing(meth,*args)
    if %w{groups status log quit terminate}.include?(meth.to_s)
      ping
      send("#{meth}_command")
    elsif %w{start stop restart unmonitor monitor}.include?(meth.to_s)
      ping
      lifecycle_command(args.first, meth.to_s)
    else
      raise NoMethodError
    end
  end

  def groups_command
    groups = []
    @server.groups.each do |key, value|
      groups << key
    end
    groups.sort
  end

  def status_command
    @server.status
  end

  #
  # To make it look good (no horiz scrollbars) in the iphone
  #
  def format_log(raw)
    raw.split("\n").map do |l|
      # clean stuff we don't need
      l.gsub!(/I\s+|\(\w*\)|within bounds/, "") #        gsub(/\(\w*\)/, """)
      # if ok, span is green
      ok = l =~ /\[ok\]/
      # get some data we want...
      l.gsub(/\[\S*\s(\S*)\]\W+INFO: (\w*-?\w*)\s\[(\w*)\]/, "<span class='gray'>\\1</span> | <span class='#{ok ? 'green' : 'red'}'>\\3</span> |").
        # take only the integer from cpu
        gsub(/cpu/, "cpu %").gsub(/(\d{1,3})\.\d*%/, "\\1").
        # show mem usage in mb
        gsub(/memory/, "memory mb").gsub(/(\d*kb)/) { ($1.to_i / 1000).to_s }
     end.join("</br>")
  end

  #TODO
  def log_command(name, sample=false)
    begin
      Signal.trap('INT') { exit }
    #  name = @args[1]

      unless name
        puts "You must specify a Task or Group name"
        exit!
      end

      t = Time.at(0)
      if sample
        @server.running_log(name, t)
      else
        loop do
          @server.running_log(name, t)
          t = Time.now
          sleep 1
        end
      end
    rescue God::NoSuchWatchError
      puts "No such watch"
    rescue DRb::DRbConnError
      puts "The server went away"
    end
  end

  def quit_command
    begin
      @server.terminate
      return false
    rescue DRb::DRbConnError
      return true
    end
  end

  def terminate_command
    stopped_all = false
    if @server.stop_all
      stopped_all = true
    end

    begin
      @server.terminate
      return false
    rescue DRb::DRbConnError
      return stopped_all
    end
  end


  def lifecycle_command(*args)
    # get the name of the watch/group
    name = args.first
    command = args.last

    # send @command
    watches = @server.control(name, command)

    watches.empty? ? [] : watches
  end

end
