# == God config file
require 'yaml'

APPS_PATH = '/var/www'

class Watcher
  def initialize(app_path)
    @app_path = app_path
    @app_name = File.basename(@app_path)
  end
  
  def watch
    Dir[File.join(@app_path, 'config', 'god', '*.{yml,yaml}')].each do |filepath|
      add(filepath)
    end
  end
  
  def add(filepath, service = nil)
    config = YAML.load_file(filepath)
    
    if config['status']
      service ||= config['service']
      service ||= File.basename(File.basename(filepath), File.extname(filepath))
      
      case service.to_s.downcase
        when 'delayed_job' then watch_delayed_job(config)
        when 'sphinx'      then watch_sphinx(config)
        when 'thin'        then watch_thin(config)
      end
    end
  end
    
  private
  
    def watch_sphinx(config)
      sphinx_config = "#{@app_path}/config/#{config['environment']}.sphinx.conf"
      sphinx_pid = "#{@app_path}/log/searchd.#{config['environment']}.pid"

      if File.exists?(sphinx_config)
        God.watch do |w|
          w.group = @app_name
          w.name  = w.group + "-" + config['name']
          
          w.dir = @app_path
          w.log = File.join(@app_path, 'log', 'god.log')
          w.env = { 'RAILS_ENV' => config['environment'] }
          
          w.interval = 30.seconds
        
          #w.uid = app_config['user']
          #w.gid = app_config['group']
        
          w.start         = "searchd --config #{sphinx_config}"
          w.start_grace   = 10.seconds  
          w.stop          = "searchd --config #{sphinx_config} --stop"
          w.stop_grace    = 10.seconds  
          w.restart       = w.stop + " && " + w.start
          w.restart_grace = 15.seconds
        
          w.pid_file = File.join(sphinx_pid)
        
          w.behavior(:clean_pid_file)
        
          w.start_if do |start|
            start.condition(:process_running) do |c|
              c.interval  = 5.seconds
              c.running   = false
            end
          end
        
          w.restart_if do |restart|
            restart.condition(:memory_usage) do |c|
              c.above = 100.megabytes
              c.times = [3, 5] # 3 out of 5 intervals
            end
          end
        
          w.lifecycle do |on|
            on.condition(:flapping) do |c|
              c.to_state      = [:start, :restart]
              c.times         = 5
              c.within        = 5.minutes
              c.transition    = :unmonitored
              c.retry_in      = 10.minutes
              c.retry_times   = 5
              c.retry_within  = 2.hours
            end
          end
        end
      end
    end

    def watch_thin(config)
      num_servers = config["servers"] ||= 1      

      (0...num_servers).each do |i|
        # UNIX socket cluster use number 0 to 2 (for 3 servers)
        # and tcp cluster use port number 3000 to 3002.
        number = config['socket'] ? i : (config['port'] + i)
     
        God.watch do |w|
          w.group = @app_name
          w.name = w.group + "-" + config['name']
          
          w.dir = @app_path
          w.log = File.join(@app_path, 'log', 'god.log')
          w.env = { 'RAILS_ENV' => config['environment'] }
        
          w.interval = 20.seconds
          w.grace = 30.seconds
          
          #w.uid = config["user"]
          #w.gid = config["group"]

          w.start = "thin start -C #{file} -o #{number}"
          w.stop = "thin stop -C #{file} -o #{number}"
          w.restart = "thin restart -C #{file} -o #{number}"

          pid_path = File.join(@app_path, config["pid"])
          ext = File.extname(pid_path)

          w.pid_file = pid_path.gsub(/#{ext}$/, ".#{number}#{ext}")
          w.behavior(:clean_pid_file)

          #
          # determine the state on startup
          w.transition(:init, { true => :up, false => :start }) do |on|
            on.condition(:process_running) do |c|
              c.running = true
            end
          end

          #
          # determine when process has finished starting
          w.transition([:start, :restart], :up) do |on|
            on.condition(:process_running) do |c|
              c.running = true
            end

            # failsafe
            on.condition(:tries) do |c|
              c.times = 6
              c.within = 2.minutes
              c.transition = :start
            end
          end

    #      w.start_if do |start|
    #       start.condition(:process_running) do |c|
    #          c.interval = 5.seconds
    #          c.running = false
    #        end
    #      end

    #
          # start if process is not running
          w.transition(:up, :start) do |on|
            on.condition(:process_running) do |c|
              c.interval = 10.seconds
              c.running = false
            end
          end

          #
          # restart if memory or cpu is too high
          w.transition(:up, :restart) do |on|
            on.condition(:memory_usage) do |c|
              c.interval = 20
              c.above = 90.megabytes
              c.times = [2, 3]
            end

            on.condition(:cpu_usage) do |c|
              c.interval = 10
              c.above = 60.percent
              c.times = [3, 5]
            end
          end

          #
          # lifecycle
          w.lifecycle do |on|
            on.condition(:flapping) do |c|
              c.to_state = [:start, :restart]
              c.times = 5
              c.within = 5.minutes
              c.transition = :unmonitored
              c.retry_in = 10.minutes
              c.retry_times = 5
              c.retry_within = 2.hours
            end
          end
        end
      end
    end

    def watch_delayed_job(config)
      workers = config['workers'] ||= 1 
      
      workers.to_i.times do |num|
        God.watch do |w|
          w.group = @app_name
          w.name = w.group + '-' + config['name'] + "-#{num}"
          
          w.dir = @app_path
          w.log = File.join(@app_path, 'log', 'god.log')
          w.env = { 'RAILS_ENV' => config['environment'] }
          
          w.interval = 30.seconds
          w.start = "rake -f #{@app_path}/Rakefile jobs:work"

          #w.uid = 'git'
          #w.gid = 'git'

          # retart if memory gets too high
          w.transition(:up, :restart) do |on|
            on.condition(:memory_usage) do |c|
              c.above = 300.megabytes
              c.times = 2
            end
          end

          # determine the state on startup
          w.transition(:init, { true => :up, false => :start }) do |on|
            on.condition(:process_running) do |c|
              c.running = true
            end
          end
        
          # determine when process has finished starting
          w.transition([:start, :restart], :up) do |on|
            on.condition(:process_running) do |c|
              c.running = true
              c.interval = 5.seconds
            end
          
            # failsafe
            on.condition(:tries) do |c|
              c.times = 5
              c.transition = :start
              c.interval = 5.seconds
            end
          end
        
          # start if process is not running
          w.transition(:up, :start) do |on|
            on.condition(:process_running) do |c|
              c.running = false
            end
          end
        end # God.watch
      end # workers
    end # watch_delayed_job
end


Dir[File.join(APPS_PATH, '*')].select { |dir| File.directory?(dir) }.each do |app_path|
  Watcher.new(app_path).watch
end
