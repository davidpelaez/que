module Que
  class Locker
    attr_reader :thread, :workers

    def initialize(options = {})
      @queue_name   = options[:queue] || ''
      @job_queue    = JobQueue.new
      @result_queue = ResultQueue.new

      @workers = (options[:worker_count] || 4).times.map do
        Worker.new :job_queue    => @job_queue,
                   :result_queue => @result_queue
      end

      @thread = Thread.new { work_loop }
    end

    def stop
      @stop = true
      @thread.join
    end

    private

    def work_loop
      Que.adapter.checkout do |connection|
        begin
          # A previous locker that didn't exit cleanly may have left behind
          # a bad locker record, so clean up before doing anything.
          Que.execute :clean_lockers

          pid = Que.execute("SELECT pg_backend_pid()").first[:pg_backend_pid].to_i

          Que.execute "LISTEN que_locker_#{pid}"
          Que.execute :register_locker, [@queue_name, @workers.count, Process.pid, Socket.gethostname]

          loop do
            connection.wait_for_notify(0.001) do |channel, pid, payload|
              pk = Que.indifferentiate(JSON_MODULE.load(payload))

              if Que.execute("SELECT pg_try_advisory_lock($1)", [pk[:job_id].to_i]).first[:pg_try_advisory_lock] == 't'
                @job_queue.push(pk)
              end
            end

            while id = @result_queue.shift
              Que.execute "SELECT pg_advisory_unlock($1)", [id]
            end

            break if @stop
          end
        ensure
          Que.execute "UNLISTEN *"
          # Get rid of the remaining notifications before returning the connection to the pool.
          {} while connection.notifies
          Que.execute "DELETE FROM que_lockers WHERE pid = $1", [pid]
        end
      end
    end
  end
end